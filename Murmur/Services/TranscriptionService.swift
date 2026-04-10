import Foundation
import os

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

protocol TranscriptionServiceProtocol {
    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult
    func preloadModel() async throws
    func unloadModel() async
    var isModelLoaded: Bool { get }
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

        // Find transcribe.py: bundle resource > app support > next to executable
        if let scriptPath {
            self.scriptPath = scriptPath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Murmur/transcribe.py")
            let bundleResource = Bundle.main.url(forResource: "transcribe", withExtension: "py")
            let nextToExe = Bundle.main.executableURL?.deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources/transcribe.py")

            if let bundleResource, FileManager.default.fileExists(atPath: bundleResource.path) {
                self.scriptPath = bundleResource
            } else if let nextToExe, FileManager.default.fileExists(atPath: nextToExe.path) {
                self.scriptPath = nextToExe
            } else if FileManager.default.fileExists(atPath: appSupport.path) {
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
