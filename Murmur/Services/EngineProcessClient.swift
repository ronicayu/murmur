import Foundation
import os

/// The speech engine, running in a process of its own (`MurmurEngine`).
///
/// The model and the working memory of the runtime take 2 to 4 GB, and the
/// runtime keeps most of that for as long as its process lives. In a helper
/// process the app can give all of it back: the helper is started at the
/// first request and ended after `idleSeconds` without one.
///
/// The client sends the helper one request at a time; the rest wait in the
/// client. Cancelling a waiting request removes it. Cancelling the request
/// the helper is running ends the helper, since a decode cannot be
/// interrupted, and the waiting requests continue in a new one.
///
/// A long file goes to the helper a piece at a time (`transcribeLong`), and
/// a dictation's requests go ahead of the file's waiting ones: a dictation
/// made during a file transcription waits only for the piece the helper is
/// decoding.
actor EngineProcessClient: TranscriptionServiceProtocol {

    /// How to start the engine process.
    struct Launch: Sendable {
        let executable: URL
        let arguments: [String]
    }

    /// Which waiting request the helper gets next.
    private enum Priority {
        /// A dictation: sent before any waiting `.file` request.
        case dictation
        /// A piece of a long file.
        case file
    }

    private struct Request {
        let id: Int
        /// The encoded request, with its newline.
        let line: Data
        let priority: Priority
        let continuation: CheckedContinuation<EngineReply, Error>
    }

    private let launch: Launch
    private let idleSeconds: TimeInterval
    private let logger = Logger(subsystem: "com.murmur.app", category: "engine-process")

    private var helper: RunningHelper?
    /// Changes with every start and stop, so that output and the exit of an
    /// earlier process are not taken for the current one's.
    private var generation = 0
    private var nextID = 1
    /// Requests not yet sent to the helper, oldest first.
    private var queue: [Request] = []
    /// The one request the helper has. Only `pump` sends, and only when this
    /// is nil, so the helper never holds a second request behind a decode
    /// that a cancel would have to end.
    private var running: Request?
    private var idleStop: IdleTrigger?
    private var lastUse = Date.distantPast
    /// `unloadModel` came while the client was busy: the helper ends when
    /// the last request finishes.
    private var stopWhenDone = false
    /// Long transcriptions under way. Between two of its pieces a long
    /// transcription has no request in the helper or the queue, and the
    /// helper must not be ended in that gap.
    private var activeLongTranscriptions = 0

    /// A request running or waiting, or a long transcription between pieces.
    private var isBusy: Bool { running != nil || !queue.isEmpty || activeLongTranscriptions > 0 }

    // The app does not know whether the helper has the model loaded.
    nonisolated var isModelLoaded: Bool { false }

    nonisolated var yieldsToDictationDuringLongTranscription: Bool { true }

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
        _ = try await perform(.preload, audioURL: nil, language: nil, priority: .dictation)
    }

    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult {
        try await result(of: perform(.transcribe, audioURL: audioURL, language: language, priority: .dictation))
    }

    /// Transcribes a long file a piece at a time. The app converts the file
    /// to a 16 kHz WAV and cuts it (`LongPlan`), off this actor, so that the
    /// helper is never busy for more than one piece; then each piece is a
    /// request of its own, and a dictation's requests go ahead of the next.
    ///
    /// Cancelling it lets the piece the helper is decoding finish (seconds),
    /// rather than end the helper and unload the model the next dictation
    /// needs; the transcription stops before the next piece.
    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        let start = Date()
        activeLongTranscriptions += 1
        defer {
            activeLongTranscriptions -= 1
            endHelperIfUnloadIsDue()
        }
        // The model first, so a missing model is reported before minutes of
        // conversion.
        _ = try await perform(.preload, audioURL: nil, language: nil, priority: .file)
        let prepared = try await Self.prepare(audioURL)
        defer { prepared.discard() }

        let pieces = prepared.plan.pieces
        var segments = Qwen3TranscriptionService.SegmentBuilder(sampleRate: LongAudioSource.sampleRate)
        for (done, piece) in pieces.enumerated() {
            try Task.checkCancellation()
            let reply = try await perform(
                .transcribePiece, audioURL: prepared.wav, language: language, range: piece.range, priority: .file
            )
            segments.add(reply.text ?? "", piece: piece.range, index: piece.index, of: piece.count, in: piece.span)
            onProgress(TranscriptionProgress(
                currentChunk: done + 1,
                totalChunks: pieces.count,
                partialText: Qwen3TranscriptionService.text(of: segments.segments)
            ))
        }

        let text = Qwen3TranscriptionService.text(of: segments.segments)
        return TranscriptionResult(
            text: text,
            language: Qwen3TranscriptionService.detectLanguage(text),
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            segments: segments.segments
        )
    }

    /// A long file made ready for the helper: a WAV it can read by path, and
    /// where to cut it.
    private struct PreparedFile: Sendable {
        let wav: URL
        let isTemporary: Bool
        let plan: LongPlan

        /// Deletes the converted copy, which holds the user's audio.
        func discard() {
            if isTemporary { try? FileManager.default.removeItem(at: wav) }
        }
    }

    /// Converts and cuts `url` in a task of its own: on the actor the
    /// conversion of a long file would hold up every dictation request.
    private nonisolated static func prepare(_ url: URL) async throws -> PreparedFile {
        let work = Task.detached(priority: .userInitiated) { () throws -> PreparedFile in
            let (wav, isTemporary) = try LongAudioSource.preparedWAV(for: url)
            do {
                let plan = try LongPlan(source: try LongAudioSource(url: wav))
                try Task.checkCancellation()
                return PreparedFile(wav: wav, isTemporary: isTemporary, plan: plan)
            } catch {
                if isTemporary { try? FileManager.default.removeItem(at: wav) }
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Releases the model by ending the helper. Work under way finishes
    /// first, a long transcription to its last piece: the Mac going to sleep
    /// must not throw away an hour of file transcription.
    func unloadModel() async {
        if isBusy {
            stopWhenDone = true
        } else {
            endHelper()
        }
    }

    private func endHelperIfUnloadIsDue() {
        guard stopWhenDone, !isBusy else { return }
        logger.info("Speech engine process ended after the work under way")
        endHelper()
    }

    /// Ends the helper at once, failing the running request and the waiting ones.
    func killProcess() async {
        let error = MurmurError.transcriptionFailed("The speech engine was stopped")
        if let current = running {
            running = nil
            current.continuation.resume(throwing: error)
        }
        failAll(error)
        endHelper()
    }

    /// True while the helper process is running. For tests and diagnostics.
    var isRunning: Bool { helper != nil }

    /// The requests waiting for the helper to finish the running one. For
    /// tests and diagnostics.
    var queuedRequestCount: Int { queue.count }

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
        range: Range<Int>? = nil,
        priority: Priority
    ) async throws -> EngineReply {
        // A task cancelled before it got here is never sent. Its cancellation
        // handler would only run once the request had reached the helper, and
        // would then end the helper for nothing.
        try Task.checkCancellation()
        let id = nextID
        nextID += 1
        var request = EngineRequest(id: id, operation: operation)
        request.path = audioURL?.path
        request.language = language
        request.range = range
        let line = try EngineWire.line(request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Request(id: id, line: line, priority: priority, continuation: continuation))
                pump()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Sends the next waiting request when the helper has none, starting the
    /// helper if needed. The only place that writes to the helper.
    private func pump() {
        guard running == nil, !queue.isEmpty else { return }
        do {
            try startIfNeeded()
        } catch {
            // Nothing was sent, and there is no helper to send to. With no
            // helper and nothing waiting, a pending `unloadModel` is done:
            // left set, it would end the next helper after its first reply.
            stopWhenDone = false
            failAll(error)
            return
        }
        // The oldest dictation request, else the oldest of the rest.
        let next = queue.remove(at: queue.firstIndex { $0.priority == .dictation } ?? 0)
        running = next
        do {
            try helper?.send(next.line)
        } catch {
            // The helper exited, most likely between its last reply and this
            // write. That is a crash like any other: only this request fails,
            // and the waiting ones go on in a new helper.
            logger.warning("Speech engine process could not be written to: \(String(describing: error), privacy: .public)")
            running = nil
            next.continuation.resume(throwing: MurmurError.transcriptionFailed("The speech engine could not be reached"))
            restartForTheQueue()
        }
    }

    /// A waiting request is only taken out of the queue; the helper does not
    /// know of it. The helper cannot abandon a decode, so cancelling the
    /// running request ends the helper, and the waiting requests go on in a
    /// new one.
    private func cancel(_ id: Int) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index).continuation.resume(throwing: CancellationError())
            return
        }
        // Not waiting and not running: it has already finished.
        guard let current = running, current.id == id else { return }
        // A piece of a file takes seconds. Its reply ends it as usual, and
        // the long transcription stops before the next piece; ending the
        // helper would only unload the model.
        if current.priority == .file { return }
        running = nil
        current.continuation.resume(throwing: CancellationError())
        restartForTheQueue()
    }

    /// Ends the running request, then sends the next one.
    private func finish(_ outcome: Result<EngineReply, Error>) {
        guard let current = running else { return }
        running = nil
        current.continuation.resume(with: outcome)
        if stopWhenDone, !isBusy {
            logger.info("Speech engine process ended after the work under way")
            endHelper()
        } else {
            noteUse()
            pump()
        }
    }

    // MARK: - The process

    private func startIfNeeded() throws {
        guard helper == nil else { return }
        let started = try RunningHelper(launch)
        generation += 1
        let generation = self.generation
        helper = started
        logger.info("Speech engine process started (pid \(started.processIdentifier))")

        let lines = started.lines
        Task { [weak self] in
            for await line in lines {
                await self?.receive(line, generation: generation)
            }
            await self?.outputEnded(generation: generation)
        }
    }

    private func receive(_ line: String, generation: Int) {
        guard generation == self.generation,
              let reply = try? EngineWire.decode(EngineReply.self, from: line) else { return }
        // A reply to anything but the running request is stale or unknown.
        guard running?.id == reply.id else { return }
        switch reply.kind {
        case .ready, .result:
            finish(.success(reply))
        case .failure:
            finish(.failure(reply.error))
        }
    }

    /// The helper closed its output: it exited or crashed. Only the running
    /// request fails; the waiting ones go on in a new helper. Each of them
    /// gets one attempt per crash, so a helper that always crashes empties
    /// the queue instead of starting again and again.
    private func outputEnded(generation: Int) {
        guard generation == self.generation else { return }
        logger.warning("Speech engine process ended by itself")
        if let current = running {
            running = nil
            current.continuation.resume(throwing: MurmurError.transcriptionFailed("The speech engine stopped unexpectedly"))
        }
        restartForTheQueue()
    }

    /// Ends the helper after its running request went away, and sends the
    /// waiting requests to a new one. A pending `unloadModel` still applies
    /// to them.
    private func restartForTheQueue() {
        let keepStopping = stopWhenDone
        endHelper()
        stopWhenDone = keepStopping && isBusy
        pump()
    }

    /// Ends the process. Leaves the running request and the queue alone.
    private func endHelper() {
        generation += 1
        stopWhenDone = false
        idleStop?.cancel()
        helper = nil   // ends the process
    }

    /// Fails every waiting request. For when no helper can be had at all:
    /// `killProcess`, and a helper that cannot be started.
    private func failAll(_ error: Error) {
        let waiting = queue
        queue = []
        for request in waiting { request.continuation.resume(throwing: error) }
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
        guard helper != nil, !isBusy, Date().timeIntervalSince(lastUse) >= idleSeconds else { return }
        logger.info("Speech engine process ended after \(Int(self.idleSeconds)) s without use")
        endHelper()
    }
}

/// One run of the helper process. Letting go of this object ends the process,
/// so a client that goes away cannot leave a helper, and its gigabytes, behind.
private final class RunningHelper: @unchecked Sendable {
    /// The helper's output, a line at a time. Ends when the helper closes
    /// its output: it exited, or it was ended.
    let lines: AsyncStream<String>

    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle

    var processIdentifier: Int32 { process.processIdentifier }

    init(_ launch: EngineProcessClient.Launch) throws {
        let toHelper = Pipe()
        let fromHelper = Pipe()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        // The speech library logs its configuration there.
        process.standardError = FileHandle.nullDevice
        input = toHelper.fileHandleForWriting
        output = fromHelper.fileHandleForReading

        // Not `FileHandle.bytes.lines`: every `AsyncBytes` in a process reads
        // on one shared serial queue, so a read that waits for this helper
        // would hold up every other one.
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        self.lines = lines
        let splitter = LineSplitter()
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in splitter.lines(adding: data) { continuation.yield(line) }
        }

        do {
            try process.run()
        } catch {
            output.readabilityHandler = nil
            continuation.finish()
            throw error
        }
    }

    func send(_ line: Data) throws {
        try input.write(contentsOf: line)
    }

    deinit {
        if process.isRunning { process.terminate() }
        try? input.close()
    }
}

/// Cuts a stream of bytes into lines. A line can arrive in several pieces.
final class LineSplitter {
    private var buffer = Data()

    /// The complete lines that `data` finishes, without their newline.
    func lines(adding data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}
