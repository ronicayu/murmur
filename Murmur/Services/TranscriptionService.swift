import Foundation
import os

// MARK: - os_unfair_lock helpers (Swift-friendly wrappers)

/// A non-recursive unfair lock wrapping os_unfair_lock.
/// Used to guard single-shot continuation resume (prevents double-resume UB).
private final class UnfairLock: @unchecked Sendable {
    private var _lock = os_unfair_lock()

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return try body()
    }
}

enum DetectedLanguage: String, Sendable {
    case english = "en"
    case chinese = "zh"
    case unknown
}

struct TranscriptionResult: Sendable {
    let text: String
    let language: DetectedLanguage
    let durationMs: Int
}

/// Reports per-chunk progress during a long transcription.
struct TranscriptionProgress: Sendable {
    let currentChunk: Int
    let totalChunks: Int
    let partialText: String
}

protocol TranscriptionServiceProtocol {
    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult
    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult
    func preloadModel() async throws
    func unloadModel() async
    var isModelLoaded: Bool { get }
}

// MARK: - JSONLineParser
//
// Reads newline-delimited JSON from a Pipe until it receives a `{"type":"result",...}` line.
// Each `{"type":"progress",...}` line triggers the onProgress callback.
// This helper is extracted from the actor so it can be unit-tested independently.

struct JSONLineParser {
    let pipe: Pipe

    /// Read JSON lines from the pipe's stdout handle until a type=result arrives.
    /// Calls onProgress for each type=progress line.
    /// Throws MurmurError.transcriptionFailed on error fields or premature EOF.
    ///
    /// Thread-safety: the `didResume` flag (guarded by `resumeLock`) ensures the
    /// continuation is fulfilled exactly once even when Task cancellation and a
    /// concurrent EOF on the DispatchQueue thread race to resume it.
    func readUntilResult(
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        return try await withCheckedThrowingContinuation { continuation in
            // P0 fix: guard against double-resume from concurrent cancellation
            // handler (killProcessFromOutside) + DispatchQueue EOF path.
            let resumeLock = UnfairLock()
            var didResume = false

            func safeResume(with result: Result<TranscriptionResult, Error>) {
                resumeLock.withLock {
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(with: result)
                }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let handle = pipe.fileHandleForReading
                var buffer = Data()

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        // EOF before result — process was killed or pipe was closed
                        safeResume(with: .failure(MurmurError.transcriptionFailed(
                            "Python stdout closed before result event"
                        )))
                        return
                    }
                    buffer.append(chunk)

                    // Process all complete lines in buffer
                    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<newlineIndex]
                        buffer.removeSubrange(buffer.startIndex...newlineIndex)

                        guard !lineData.isEmpty else { continue }

                        guard
                            let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                        else {
                            safeResume(with: .failure(MurmurError.transcriptionFailed(
                                "Invalid JSON from Python"
                            )))
                            return
                        }

                        // Error from Python
                        if let errMsg = json["error"] as? String {
                            safeResume(with: .failure(MurmurError.transcriptionFailed(errMsg)))
                            return
                        }

                        let eventType = json["type"] as? String

                        if eventType == "progress" {
                            let progress = TranscriptionProgress(
                                currentChunk: json["chunk"] as? Int ?? 0,
                                totalChunks: json["total"] as? Int ?? 0,
                                partialText: json["text"] as? String ?? ""
                            )
                            onProgress(progress)

                        } else if eventType == "result" {
                            guard let text = json["text"] as? String else {
                                safeResume(with: .failure(MurmurError.transcriptionFailed(
                                    "No text in result event"
                                )))
                                return
                            }
                            let langStr = json["language"] as? String ?? "unknown"
                            let language = DetectedLanguage(rawValue: langStr) ?? .unknown
                            let durationMs = json["duration_ms"] as? Int ?? 0
                            safeResume(with: .success(TranscriptionResult(
                                text: text,
                                language: language,
                                durationMs: durationMs
                            )))
                            return

                        } else {
                            // P2-1 fix: unknown event type — log and continue rather
                            // than crashing. Keeps forward-compatibility with new
                            // Python-side diagnostic events (e.g. heartbeat).
                            // swiftlint:disable:next no_direct_standard_out_logs
                            os_log(
                                .info,
                                "JSONLineParser: unknown event type '%{public}@' — skipping",
                                eventType ?? "<nil>"
                            )
                            // continue inner while loop
                        }
                    }
                }
            }
        }
    }
}

/// Manages a long-lived Python subprocess for transcription.
/// Protocol: JSON lines over stdin/stdout.
/// Actor isolation serializes all subprocess access — no manual locking needed.
actor TranscriptionService: TranscriptionServiceProtocol {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let logger = Logger(subsystem: "com.murmur.app", category: "transcription")
    private var modelPath: URL
    private let scriptPath: URL
    private let pythonPath: URL
    private var _isModelLoaded = false
    /// Thread-safe process reference for cancellation handler (Process.terminate is thread-safe)
    nonisolated(unsafe) private var _processRef: Process?

    nonisolated var isModelLoaded: Bool {
        // This is inherently racy when called from outside the actor,
        // but it's only used as a hint (preloadModel rechecks under isolation).
        false // Conservative: always attempt preload check inside actor
    }

    /// Update the model path (e.g. when switching backends). Forces reload on next transcription.
    func setModelPath(_ newPath: URL) {
        let changed = modelPath != newPath
        modelPath = newPath
        if changed {
            killProcess()
        }
    }

    init(
        modelPath: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Models-ONNX"),
        pythonPath: URL? = nil,
        scriptPath: URL? = nil
    ) {
        self.modelPath = modelPath

        // Find Python: bundled venv > system python
        if let pythonPath {
            self.pythonPath = pythonPath
        } else {
            let bundled = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Murmur/Python/bin/python3")
            if FileManager.default.fileExists(atPath: bundled.path) {
                self.pythonPath = bundled
            } else {
                let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
                self.pythonPath = URL(fileURLWithPath: candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/python3")
            }
        }

        // Find transcribe.py: bundle resource > next to executable > app support.
        // When a newer source copy is found, sync it to App Support so the
        // deployed script stays up-to-date across builds.
        if let scriptPath {
            self.scriptPath = scriptPath
        } else {
            let fm = FileManager.default
            let appSupportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Murmur", isDirectory: true)
            let appSupport = appSupportDir.appendingPathComponent("transcribe.py")
            let bundleResource = Bundle.main.url(forResource: "transcribe", withExtension: "py")
            let nextToExe = Bundle.main.executableURL?.deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources/transcribe.py")

            // Pick the best available source copy
            let sourceURL: URL? = {
                if let bundleResource, fm.fileExists(atPath: bundleResource.path) {
                    return bundleResource
                }
                if let nextToExe, fm.fileExists(atPath: nextToExe.path) {
                    return nextToExe
                }
                return nil
            }()

            if let sourceURL {
                // Sync source → App Support if source is newer or App Support is missing
                try? fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
                let shouldCopy: Bool
                if !fm.fileExists(atPath: appSupport.path) {
                    shouldCopy = true
                } else {
                    let srcMod = (try? fm.attributesOfItem(atPath: sourceURL.path)[.modificationDate] as? Date) ?? .distantPast
                    let dstMod = (try? fm.attributesOfItem(atPath: appSupport.path)[.modificationDate] as? Date) ?? .distantPast
                    shouldCopy = srcMod > dstMod
                }
                if shouldCopy {
                    try? fm.removeItem(at: appSupport)
                    try? fm.copyItem(at: sourceURL, to: appSupport)
                }
                self.scriptPath = appSupport
            } else if fm.fileExists(atPath: appSupport.path) {
                self.scriptPath = appSupport
            } else {
                self.scriptPath = appSupport
            }
        }

        // Ignore SIGPIPE so writing to a dead pipe doesn't kill the app
        signal(SIGPIPE, SIG_IGN)
    }

    func preloadModel() async throws {
        guard !_isModelLoaded else { return }
        try ensureProcessRunning()
        let response = try await send(command: [
            "cmd": "load",
            "model_path": modelPath.path
        ])
        guard response["status"] as? String == "ok" else {
            let err = response["error"] as? String ?? "Unknown error"
            throw MurmurError.transcriptionFailed("Model load failed: \(err)")
        }
        _isModelLoaded = true
        logger.info("Model loaded from \(self.modelPath.path)")
    }

    func transcribe(audioURL: URL, language: String = "en") async throws -> TranscriptionResult {
        // C1 guard: reject short transcription while a long transcription holds the pipe.
        // Concurrent access would interleave stdin writes and corrupt the JSON protocol.
        guard !_isLongRunning else {
            throw MurmurError.transcriptionFailed("Long transcription in progress")
        }

        if !_isModelLoaded {
            try await preloadModel()
        }

        let response: [String: Any]
        do {
            response = try await send(command: [
                "cmd": "transcribe",
                "wav_path": audioURL.path,
                "language": language
            ])
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            throw error
        }

        try? FileManager.default.removeItem(at: audioURL)

        if let error = response["error"] as? String {
            throw MurmurError.transcriptionFailed(error)
        }

        guard let text = response["text"] as? String else {
            throw MurmurError.transcriptionFailed("No text in response")
        }

        guard !text.isEmpty else {
            throw MurmurError.silenceDetected
        }

        let sanitizedText = String(text.prefix(10_000))
        let langStr = response["language"] as? String ?? "unknown"
        let language = DetectedLanguage(rawValue: langStr) ?? .unknown
        let durationMs = response["duration_ms"] as? Int ?? 0

        logger.info("Transcribed: \(sanitizedText.prefix(50))... (\(language.rawValue), \(durationMs)ms)")
        return TranscriptionResult(text: sanitizedText, language: language, durationMs: durationMs)
    }

    func unloadModel() async {
        guard _isModelLoaded else { return }
        _ = try? await send(command: ["cmd": "unload"])
        _isModelLoaded = false
        logger.info("Model unloaded")
    }

    // MARK: - Long Transcription

    /// True while a transcribeLong call is in flight. Enforces max-1 concurrency.
    private var _isLongRunning = false

    /// Transcribe a long audio file using chunked processing.
    ///
    /// Sends `{"cmd":"transcribe_long",...}` to Python and reads multiple JSON
    /// lines until a `{"type":"result",...}` arrives. Each `{"type":"progress",...}`
    /// line triggers `onProgress`.
    ///
    /// - Parameters:
    ///   - audioURL: Path to the audio file (wav, m4a, mp3, etc.)
    ///   - language: BCP-47 language code, or "auto"
    ///   - onProgress: Called on each chunk completion with partial text.
    /// - Returns: Final `TranscriptionResult` when all chunks are done.
    /// - Throws: `MurmurError.transcriptionFailed("transcribeLong already running")` if
    ///   another long transcription is already in flight.
    ///   `MurmurError.transcriptionFailed(...)` on Python errors or protocol violations.
    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        guard !_isLongRunning else {
            throw MurmurError.transcriptionFailed("transcribeLong already running")
        }
        _isLongRunning = true
        defer { _isLongRunning = false }

        if !_isModelLoaded {
            try await preloadModel()
        }

        try ensureProcessRunning()

        guard let stdinPipe, let stdoutPipe else {
            throw MurmurError.transcriptionFailed("No pipe to Python process")
        }

        let command: [String: Any] = [
            "cmd": "transcribe_long",
            "audio_path": audioURL.path,
            "language": language,
            "chunk_sec": 30,
            "overlap_sec": 5,
        ]

        let data = try JSONSerialization.data(withJSONObject: command)
        var line = data
        line.append(contentsOf: [0x0A]) // newline

        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: line)
        } catch {
            killProcess()
            throw MurmurError.transcriptionFailed("Python process died unexpectedly")
        }

        logger.info("transcribeLong: sent command for \(audioURL.lastPathComponent)")

        let parser = JSONLineParser(pipe: stdoutPipe)

        return try await withTaskCancellationHandler {
            let result = try await parser.readUntilResult(onProgress: onProgress)
            // P2-2 fix: truncate to 10_000 chars, consistent with transcribe()
            let sanitizedText = String(result.text.prefix(10_000))
            logger.info("transcribeLong: complete — \(sanitizedText.prefix(80))")
            return TranscriptionResult(
                text: sanitizedText,
                language: result.language,
                durationMs: result.durationMs
            )
        } onCancel: { [weak self] in
            self?.killProcessFromOutside()
        }
    }

    // MARK: - Subprocess Management

    private func ensureProcessRunning() throws {
        if process?.isRunning == true { return }
        try launchProcess()
    }

    private func launchProcess() throws {
        guard FileManager.default.fileExists(atPath: pythonPath.path) else {
            throw MurmurError.modelNotFound
        }

        let proc = Process()
        proc.executableURL = pythonPath
        proc.arguments = ["-u", scriptPath.path]
        proc.environment = [
            "PYTHONUNBUFFERED": "1",
            "KMP_DUPLICATE_LIB_OK": "TRUE",
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()

        self.process = proc
        self._processRef = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self._isModelLoaded = false

        logger.info("Python subprocess started (pid: \(proc.processIdentifier))")
    }

    private func send(command: [String: Any]) async throws -> [String: Any] {
        try ensureProcessRunning()

        guard let stdinPipe, let stdoutPipe else {
            throw MurmurError.transcriptionFailed("No pipe to Python process")
        }

        let data = try JSONSerialization.data(withJSONObject: command)
        var line = data
        line.append(contentsOf: [0x0A]) // newline

        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: line)
        } catch {
            killProcess()
            throw MurmurError.transcriptionFailed("Python process died unexpectedly")
        }

        // Read one JSON line from stdout using buffered reads (not byte-by-byte).
        // Kill the process on cancellation to unblock the read thread.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let handle = stdoutPipe.fileHandleForReading
                    var buffer = Data()

                    // Read in chunks instead of byte-by-byte (fewer syscalls)
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            continuation.resume(throwing: MurmurError.transcriptionFailed("Python process closed stdout"))
                            return
                        }
                        buffer.append(chunk)

                        // Check if we have a complete line
                        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                            let lineData = buffer[buffer.startIndex..<newlineIndex]
                            do {
                                guard let json = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                                    continuation.resume(throwing: MurmurError.transcriptionFailed("Invalid JSON from Python"))
                                    return
                                }
                                continuation.resume(returning: json)
                            } catch {
                                continuation.resume(throwing: MurmurError.transcriptionFailed("JSON parse error: \(error)"))
                            }
                            return
                        }
                    }
                }
            }
        } onCancel: { [weak self] in
            // Kill the process to unblock the read thread.
            // The process will be relaunched on next use.
            self?.killProcessFromOutside()
        }
    }

    /// Non-isolated kill for use in cancellation handlers.
    /// Uses the atomic process reference to terminate without actor isolation.
    nonisolated func killProcessFromOutside() {
        _processRef?.terminate()
    }

    func killProcess() {
        process?.terminate()
        process = nil
        _processRef = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        _isModelLoaded = false
    }
}
