import Foundation
import os
import CryptoKit

enum ModelState: Sendable, Equatable {
    case notDownloaded
    case downloading(progress: Double, bytesPerSec: Int64)
    case verifying
    case ready
    case corrupt
    case error(String)

    static func == (lhs: ModelState, rhs: ModelState) -> Bool {
        switch (lhs, rhs) {
        case (.notDownloaded, .notDownloaded),
             (.verifying, .verifying),
             (.ready, .ready),
             (.corrupt, .corrupt):
            return true
        case (.downloading(let a, let b), .downloading(let c, let d)):
            return a == c && b == d
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

protocol ModelManagerProtocol {
    var state: ModelState { get }
    var modelPath: URL? { get }
    func download() async throws
    func cancelDownload()
    func verify() async throws -> Bool
    func delete() throws
    func checkDiskSpace() throws
}

@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var state: ModelState = .notDownloaded
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var downloadSpeed: Int64 = 0 // bytes/sec
    @Published private(set) var statusMessage: String = ""

    private let logger = Logger(subsystem: "com.murmur.app", category: "model")
    private var downloadTask: Task<Void, Never>?
    private var urlSession: URLSession?
    private var resumeData: Data?

    // HuggingFace model info
    private let modelRepo = "CohereLabs/cohere-transcribe-03-2026"
    private let requiredDiskSpace: Int64 = 6_000_000_000 // 6 GB

    var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Models")
    }

    var modelPath: URL? {
        let dir = modelDirectory
        let configPath = dir.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: configPath.path) ? dir : nil
    }

    var pythonEnvPath: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Python")
    }

    init() {
        if modelPath != nil {
            state = .ready
        } else {
            // Check for partial download (for resume)
            let partialSize = directorySize(modelDirectory)
            if partialSize > 0 {
                downloadProgress = min(Double(partialSize) / Double(requiredDiskSpace), 0.99)
            }
        }
    }

    func checkDiskSpace() throws {
        let attrs = try FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        )
        if let freeSpace = attrs[.systemFreeSize] as? Int64, freeSpace < requiredDiskSpace {
            throw MurmurError.diskFull
        }
    }

    func download() async throws {
        try checkDiskSpace()

        state = .downloading(progress: 0, bytesPerSec: 0)
        downloadProgress = 0
        downloadSpeed = 0

        // Create model directory
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )

        logger.info("Starting model download from HuggingFace: \(self.modelRepo)")

        statusMessage = "Setting up Python environment..."

        // Ensure bundled Python env exists with all dependencies
        let pythonBin = try await ensurePythonEnv()

        statusMessage = "Downloading model from HuggingFace..."

        let downloadScript = """
        import sys, json, os
        from huggingface_hub import snapshot_download

        try:
            path = snapshot_download(
                "\(modelRepo)",
                local_dir="\(modelDirectory.path)",
            )
            print(json.dumps({"status": "ok", "path": path}), flush=True)
        except Exception as e:
            msg = str(e)
            # Provide helpful messages for common errors
            if "401" in msg or "gated" in msg.lower() or "restricted" in msg.lower():
                msg = "This model requires access approval. Visit https://huggingface.co/\(modelRepo) to request access, then run: huggingface-cli login"
            elif "404" in msg:
                msg = "Model not found on HuggingFace: \(modelRepo)"
            print(json.dumps({"status": "error", "error": msg}), flush=True)
        """

        let process = Process()
        process.executableURL = pythonBin
        process.arguments = ["-c", downloadScript]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Monitor download progress with smoothed speed (rolling average of last 5 samples)
        let monitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastSize: Int64 = 0
            var speedSamples: [Int64] = []
            let maxSamples = 5

            while !Task.isCancelled && process.isRunning {
                try? await Task.sleep(for: .seconds(1))
                let currentSize = self.directorySize(self.modelDirectory)
                let progress = min(Double(currentSize) / Double(self.requiredDiskSpace), 0.99)

                let instantSpeed = currentSize - lastSize
                speedSamples.append(instantSpeed)
                if speedSamples.count > maxSamples { speedSamples.removeFirst() }
                let smoothedSpeed = speedSamples.reduce(0, +) / Int64(speedSamples.count)

                self.downloadProgress = progress
                self.downloadSpeed = smoothedSpeed
                self.state = .downloading(progress: progress, bytesPerSec: smoothedSpeed)
                let sizeMB = currentSize / 1_000_000
                let totalMB = self.requiredDiskSpace / 1_000_000
                self.statusMessage = "Downloading model: \(sizeMB) / \(totalMB) MB"
                lastSize = currentSize
            }
        }

        // Wait for process on a background thread (M2 fix: don't block main actor)
        let exitStatus: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
        }
        monitorTask.cancel()

        // Read stdout for JSON result (our script always prints JSON)
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outputStr = String(data: outputData, encoding: .utf8) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

        // Try to parse JSON response from our script
        if let jsonLine = outputStr.components(separatedBy: "\n").last(where: { $0.contains("{") }),
           let data = jsonLine.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            if let error = json["error"] as? String {
                logger.error("Model download error: \(error)")
                statusMessage = "Error: \(error)"
                state = .error(String(error.prefix(200)))
                throw MurmurError.transcriptionFailed(error)
            }

            if json["status"] as? String == "ok" {
                logger.info("Model downloaded, verifying...")
                statusMessage = "Verifying model..."
                downloadProgress = 1.0
                let valid = try await verify()
                guard valid else {
                    statusMessage = "Error: Model integrity check failed"
                    state = .corrupt
                    throw MurmurError.transcriptionFailed("Model integrity check failed")
                }
                statusMessage = "Model ready"
                return
            }
        }

        // Fallback: no JSON parsed, check exit status
        if exitStatus != 0 {
            let shortErr = String(stderrStr.suffix(200))
            logger.error("Model download failed: \(shortErr)")
            statusMessage = "Error: \(shortErr)"
            state = .error("Download failed")
            throw MurmurError.transcriptionFailed("Model download failed: \(shortErr)")
        }

        // Process exited 0 but no JSON — check if files exist
        if modelPath != nil {
            statusMessage = "Model ready"
            state = .ready
        } else {
            statusMessage = "Error: Download completed but model files missing"
            state = .error("Model files missing after download")
            throw MurmurError.transcriptionFailed("Model files missing")
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        // Keep partial downloads — huggingface_hub resumes from where it left off
        let partialSize = directorySize(modelDirectory)
        if partialSize > 0 {
            state = .notDownloaded
            downloadProgress = min(Double(partialSize) / Double(requiredDiskSpace), 0.99)
            logger.info("Download cancelled, \(partialSize) bytes preserved for resume")
        } else {
            state = .notDownloaded
            downloadProgress = 0
        }
        logger.info("Download cancelled")
    }

    func verify() async throws -> Bool {
        state = .verifying
        logger.info("Verifying model...")

        // Check that key model files exist
        let requiredFiles = ["config.json", "preprocessor_config.json"]
        for file in requiredFiles {
            let path = modelDirectory.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: path.path) {
                logger.warning("Missing model file: \(file)")
                state = .corrupt
                return false
            }
        }

        // SHA-256 verification of config.json as a basic integrity check
        let configPath = modelDirectory.appendingPathComponent("config.json")
        if let configData = try? Data(contentsOf: configPath) {
            let hash = SHA256.hash(data: configData)
            let hashStr = hash.map { String(format: "%02x", $0) }.joined()
            logger.info("config.json SHA-256: \(hashStr)")

            // If we have a stored expected hash, verify it
            let storedHash = UserDefaults.standard.string(forKey: "modelConfigHash")
            if let storedHash, storedHash != hashStr {
                logger.warning("Config hash mismatch: expected \(storedHash), got \(hashStr)")
                state = .corrupt
                return false
            }
            // Store hash on first verification for future comparisons
            if storedHash == nil {
                UserDefaults.standard.set(hashStr, forKey: "modelConfigHash")
            }
        }

        state = .ready
        logger.info("Model verification passed")
        return true
    }

    func delete() throws {
        if FileManager.default.fileExists(atPath: modelDirectory.path) {
            try FileManager.default.removeItem(at: modelDirectory)
        }
        state = .notDownloaded
        downloadProgress = 0
        logger.info("Model deleted")
    }

    // MARK: - Helpers

    /// Creates the bundled Python venv and installs all dependencies.
    private func ensurePythonEnv() async throws -> URL {
        let bundledPython = pythonEnvPath.appendingPathComponent("bin/python3")

        if FileManager.default.fileExists(atPath: bundledPython.path) {
            statusMessage = "Checking Python environment..."
            let check = try await runProcess(bundledPython, args: ["-c", "import huggingface_hub; print('ok')"])
            if check.status == 0 {
                statusMessage = "Python environment ready"
                return bundledPython
            }
            statusMessage = "Installing missing packages..."
        }

        guard let systemPython = findSystemPython() else {
            statusMessage = "Error: Python3 not found"
            state = .error("Python3 not found. Install via: brew install python3")
            throw MurmurError.transcriptionFailed("Python3 not found")
        }

        // Create venv
        if !FileManager.default.fileExists(atPath: bundledPython.path) {
            statusMessage = "Creating Python environment..."
            let venvResult = try await runProcess(systemPython, args: ["-m", "venv", pythonEnvPath.path])
            if venvResult.status != 0 {
                statusMessage = "Error: Failed to create Python env"
                state = .error("Failed to create Python env")
                throw MurmurError.transcriptionFailed("venv creation failed: \(venvResult.stderr.prefix(200))")
            }
        }

        // Install packages one by one for progress visibility
        let pip = pythonEnvPath.appendingPathComponent("bin/pip3")
        let packages = [
            ("huggingface_hub", "Downloading: huggingface_hub..."),
            ("transformers", "Downloading: transformers..."),
            ("torch", "Downloading: PyTorch (~2GB, this takes a few minutes)..."),
            ("soundfile", "Downloading: soundfile..."),
            ("librosa", "Downloading: librosa..."),
        ]

        for (pkg, message) in packages {
            statusMessage = message
            let result = try await runProcessWithLiveOutput(pip, args: ["install", pkg])
            if result != 0 {
                statusMessage = "Error: Failed to install \(pkg)"
                state = .error("Failed to install \(pkg)")
                throw MurmurError.transcriptionFailed("pip install \(pkg) failed")
            }
        }

        statusMessage = "Python environment ready"
        return bundledPython
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func runProcess(_ executable: URL, args: [String]) async throws -> ProcessResult {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()

        let status: Int32 = await withCheckedContinuation { continuation in
            proc.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus)
            }
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            status: status,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// Runs a process and streams stderr lines to statusMessage for live progress.
    private func runProcessWithLiveOutput(_ executable: URL, args: [String]) async throws -> Int32 {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = args

        let stderrPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = stderrPipe

        try proc.run()

        // Stream stderr lines to update status
        let streamTask = Task { @MainActor [weak self] in
            let handle = stderrPipe.fileHandleForReading
            while let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty, !Task.isCancelled {
                // Show the last meaningful line (pip progress)
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    // Extract just the last line for display
                    if let lastLine = trimmed.components(separatedBy: "\n").last, !lastLine.isEmpty {
                        self?.statusMessage = String(lastLine.prefix(80))
                    }
                }
            }
        }

        let status: Int32 = await withCheckedContinuation { continuation in
            proc.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus)
            }
        }
        streamTask.cancel()

        return status
    }

    private func findSystemPython() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
