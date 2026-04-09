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
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
    func preloadModel() async throws
    func unloadModel() async
    var isModelLoaded: Bool { get }
}

/// Manages a long-lived Python subprocess for transcription.
/// Protocol: JSON lines over stdin/stdout.
/// All mutable state is protected by `lock`.
final class TranscriptionService: TranscriptionServiceProtocol {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let logger = Logger(subsystem: "com.murmur.app", category: "transcription")
    private let modelPath: URL
    private let scriptPath: URL
    private let pythonPath: URL
    private let lock = NSLock()
    private var _isModelLoaded = false

    var isModelLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isModelLoaded
    }

    init(
        modelPath: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Models"),
        pythonPath: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Python/bin/python3"),
        scriptPath: URL? = nil
    ) {
        self.modelPath = modelPath
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath ?? Bundle.main.url(forResource: "transcribe", withExtension: "py")
            ?? URL(fileURLWithPath: "/dev/null")

        // Ignore SIGPIPE so writing to a dead pipe doesn't kill the app
        signal(SIGPIPE, SIG_IGN)
    }

    func preloadModel() async throws {
        try ensureProcessRunning()
        let response = try await send(command: [
            "cmd": "load",
            "model_path": modelPath.path
        ])
        guard response["status"] as? String == "ok" else {
            let err = response["error"] as? String ?? "Unknown error"
            throw MurmurError.transcriptionFailed("Model load failed: \(err)")
        }
        lock.lock()
        _isModelLoaded = true
        lock.unlock()
        logger.info("Model loaded from \(self.modelPath.path)")
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        if !isModelLoaded {
            try await preloadModel()
        }

        let response: [String: Any]
        do {
            response = try await send(command: [
                "cmd": "transcribe",
                "wav_path": audioURL.path
            ])
        } catch {
            // Clean up temp file even on error (B6 fix)
            try? FileManager.default.removeItem(at: audioURL)
            throw error
        }

        // Clean up temp audio file
        try? FileManager.default.removeItem(at: audioURL)

        if let error = response["error"] as? String {
            throw MurmurError.transcriptionFailed(error)
        }

        guard let text = response["text"] as? String else {
            throw MurmurError.transcriptionFailed("No text in response")
        }

        // Length limit on injected text (S2 mitigation)
        let sanitizedText = String(text.prefix(10_000))

        let langStr = response["language"] as? String ?? "unknown"
        let language = DetectedLanguage(rawValue: langStr) ?? .unknown
        let durationMs = response["duration_ms"] as? Int ?? 0

        logger.info("Transcribed: \(sanitizedText.prefix(50))... (\(language.rawValue), \(durationMs)ms)")
        return TranscriptionResult(text: sanitizedText, language: language, durationMs: durationMs)
    }

    func unloadModel() async {
        guard isModelLoaded else { return }
        _ = try? await send(command: ["cmd": "unload"])
        lock.lock()
        _isModelLoaded = false
        lock.unlock()
        logger.info("Model unloaded")
    }

    // MARK: - Subprocess Management

    private func ensureProcessRunning() throws {
        lock.lock()
        let running = process?.isRunning ?? false
        lock.unlock()
        if running { return }
        try launchProcess()
    }

    private func launchProcess() throws {
        guard FileManager.default.fileExists(atPath: pythonPath.path) else {
            throw MurmurError.modelNotFound
        }

        let proc = Process()
        proc.executableURL = pythonPath
        proc.arguments = ["-u", scriptPath.path]
        proc.environment = ["PYTHONUNBUFFERED": "1"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        proc.terminationHandler = { [weak self] p in
            self?.logger.warning("Python process exited with code \(p.terminationStatus)")
            self?.lock.lock()
            self?._isModelLoaded = false
            self?.lock.unlock()
        }

        try proc.run()

        lock.lock()
        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        lock.unlock()

        logger.info("Python subprocess started (pid: \(proc.processIdentifier))")
    }

    private func send(command: [String: Any]) async throws -> [String: Any] {
        try ensureProcessRunning()

        lock.lock()
        let stdin = stdinPipe
        let stdout = stdoutPipe
        lock.unlock()

        guard let stdinPipe = stdin, let stdoutPipe = stdout else {
            throw MurmurError.transcriptionFailed("No pipe to Python process")
        }

        let data = try JSONSerialization.data(withJSONObject: command)
        var line = data
        line.append(contentsOf: [0x0A]) // newline

        // Write to stdin — SIGPIPE is ignored at process level, so this won't kill us
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: line)
        } catch {
            // Process is dead, clean up and report
            killProcess()
            throw MurmurError.transcriptionFailed("Python process died unexpectedly")
        }

        // Read one line from stdout with cancellation safety
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let handle = stdoutPipe.fileHandleForReading
                    var buffer = Data()

                    while true {
                        let byte = handle.readData(ofLength: 1)
                        if byte.isEmpty {
                            continuation.resume(throwing: MurmurError.transcriptionFailed("Python process closed stdout"))
                            return
                        }
                        if byte[0] == 0x0A { break }
                        buffer.append(byte)
                    }

                    do {
                        guard let json = try JSONSerialization.jsonObject(with: buffer) as? [String: Any] else {
                            continuation.resume(throwing: MurmurError.transcriptionFailed("Invalid JSON from Python"))
                            return
                        }
                        continuation.resume(returning: json)
                    } catch {
                        continuation.resume(throwing: MurmurError.transcriptionFailed("JSON parse error: \(error)"))
                    }
                }
            }
        } onCancel: {
            // Don't kill the process on cancel — just let the read complete naturally.
            // The timeout in AppCoordinator will handle the overall flow.
        }
    }

    func killProcess() {
        lock.lock()
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        _isModelLoaded = false
        lock.unlock()
    }

    deinit {
        killProcess()
    }
}
