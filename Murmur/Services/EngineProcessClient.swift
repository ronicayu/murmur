import Foundation
import os

/// The speech engine, running in a process of its own (`MurmurEngine`).
///
/// The model and the working memory of the runtime take 2 to 4 GB, and the
/// runtime keeps most of that for as long as its process lives. In a helper
/// process the app can give all of it back: the helper is started at the
/// first request and ended after `idleSeconds` without one.
///
/// Ending the helper is also how a request is cancelled, so a cancelled or
/// timed-out transcription stops using the CPU at once.
actor EngineProcessClient: TranscriptionServiceProtocol {

    /// How to start the engine process.
    struct Launch: Sendable {
        let executable: URL
        let arguments: [String]
    }

    private struct Pending {
        let continuation: CheckedContinuation<EngineReply, Error>
        let onProgress: ((TranscriptionProgress) -> Void)?
    }

    private let launch: Launch
    private let idleSeconds: TimeInterval
    private let logger = Logger(subsystem: "com.murmur.app", category: "engine-process")

    private var process: Process?
    private var input: FileHandle?
    /// Changes with every start and stop, so that output and the exit of an
    /// earlier process are not taken for the current one's.
    private var generation = 0
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var idleStop: IdleTrigger?
    private var lastUse = Date.distantPast

    // The app does not know whether the helper has the model loaded.
    nonisolated var isModelLoaded: Bool { false }

    init(launch: Launch, idleSeconds: TimeInterval = 300) {
        self.launch = launch
        self.idleSeconds = idleSeconds
        // A write to a helper that has just exited must be an error, not the
        // signal that ends the app.
        signal(SIGPIPE, SIG_IGN)
    }

    /// The engine for the app: the helper next to the app's own executable
    /// when it is there, the engine inside the app's process when it is not
    /// (a build that did not package the helper).
    static func makeDefault(modelDirectory: URL) -> any TranscriptionServiceProtocol {
        guard let helper = helperExecutable() else {
            return Qwen3TranscriptionService(modelDirectory: modelDirectory)
        }
        return EngineProcessClient(launch: Launch(executable: helper, arguments: [modelDirectory.path]))
    }

    static let helperName = "MurmurEngine"

    static func helperExecutable(
        bundle: Bundle = .main,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        let candidates = [
            bundle.url(forAuxiliaryExecutable: helperName),
            bundle.executableURL?.deletingLastPathComponent().appendingPathComponent(helperName),
        ]
        return candidates.compactMap { $0 }.first { isExecutable($0.path) }
    }

    // MARK: - TranscriptionServiceProtocol

    func preloadModel() async throws {
        _ = try await perform(.preload, audioURL: nil, language: nil, onProgress: nil)
    }

    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult {
        try await result(of: perform(.transcribe, audioURL: audioURL, language: language, onProgress: nil))
    }

    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        try await result(of: perform(.transcribeLong, audioURL: audioURL, language: language, onProgress: onProgress))
    }

    func unloadModel() async {
        stop(failingPendingWith: MurmurError.transcriptionFailed("The speech engine was stopped"))
    }

    func killProcess() async {
        await unloadModel()
    }

    /// True while the helper process is running. For tests and diagnostics.
    var isRunning: Bool { process != nil }

    // MARK: - Requests

    private func result(of reply: EngineReply) throws -> TranscriptionResult {
        guard let result = reply.transcriptionResult else {
            throw MurmurError.transcriptionFailed("The speech engine sent no transcript")
        }
        return result
    }

    private func perform(
        _ operation: EngineRequest.Operation,
        audioURL: URL?,
        language: String?,
        onProgress: ((TranscriptionProgress) -> Void)?
    ) async throws -> EngineReply {
        let id = nextID
        nextID += 1
        var request = EngineRequest(id: id, operation: operation)
        request.path = audioURL?.path
        request.language = language

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try startIfNeeded()
                    pending[id] = Pending(continuation: continuation, onProgress: onProgress)
                    try input?.write(contentsOf: try EngineWire.line(request))
                } catch {
                    pending[id] = nil
                    continuation.resume(throwing: error)
                    // The helper is of no use if it cannot be written to.
                    stop(failingPendingWith: MurmurError.transcriptionFailed("The speech engine could not be reached"))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// The helper cannot abandon a decode, so a cancelled request ends the
    /// helper. Other requests waiting in it fail; the next one starts it again.
    private func cancel(_ id: Int) {
        guard let cancelled = pending.removeValue(forKey: id) else { return }
        cancelled.continuation.resume(throwing: CancellationError())
        stop(failingPendingWith: MurmurError.transcriptionFailed("The speech engine was stopped"))
    }

    private func finish(_ id: Int, with outcome: Result<EngineReply, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(with: outcome)
        noteUse()
    }

    // MARK: - The process

    private func startIfNeeded() throws {
        guard process == nil else { return }
        let process = Process()
        let toHelper = Pipe()
        let fromHelper = Pipe()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        // The speech library logs its configuration there.
        process.standardError = FileHandle.nullDevice
        try process.run()

        generation += 1
        let generation = self.generation
        self.process = process
        self.input = toHelper.fileHandleForWriting
        logger.info("Speech engine process started (pid \(process.processIdentifier))")

        let output = fromHelper.fileHandleForReading
        Task.detached { [weak self] in
            do {
                for try await line in output.bytes.lines {
                    await self?.receive(line, generation: generation)
                }
            } catch {
                // Treated like the end of the output, below.
            }
            await self?.outputEnded(generation: generation)
        }
    }

    private func receive(_ line: String, generation: Int) {
        guard generation == self.generation,
              let reply = try? EngineWire.decode(EngineReply.self, from: line) else { return }
        switch reply.kind {
        case .progress:
            guard let current = reply.currentChunk, let total = reply.totalChunks else { return }
            pending[reply.id]?.onProgress?(TranscriptionProgress(
                currentChunk: current, totalChunks: total, partialText: reply.partialText ?? ""
            ))
        case .ready, .result:
            finish(reply.id, with: .success(reply))
        case .failure:
            finish(reply.id, with: .failure(reply.error))
        }
    }

    /// The helper closed its output: it exited or crashed.
    private func outputEnded(generation: Int) {
        guard generation == self.generation else { return }
        logger.warning("Speech engine process ended by itself")
        stop(failingPendingWith: MurmurError.transcriptionFailed("The speech engine stopped unexpectedly"))
    }

    private func stop(failingPendingWith error: Error) {
        generation += 1
        idleStop?.cancel()
        if let process, process.isRunning { process.terminate() }
        try? input?.close()
        process = nil
        input = nil
        let waiting = pending
        pending = [:]
        for request in waiting.values { request.continuation.resume(throwing: error) }
    }

    // MARK: - Idle

    private func noteUse() {
        lastUse = Date()
        if idleStop == nil {
            idleStop = IdleTrigger(seconds: idleSeconds) { [weak self] in
                await self?.stopIfIdle()
            }
        }
        idleStop?.touch()
    }

    private func stopIfIdle() {
        guard process != nil, pending.isEmpty, Date().timeIntervalSince(lastUse) >= idleSeconds else { return }
        logger.info("Speech engine process ended after \(Int(self.idleSeconds)) s without use")
        stop(failingPendingWith: MurmurError.transcriptionFailed("The speech engine was stopped"))
    }
}
