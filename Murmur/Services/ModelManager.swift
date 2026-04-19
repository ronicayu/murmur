import Foundation
import Darwin
import os
import Combine
import CryptoKit

/// Ensures a CheckedContinuation is resumed at most once, even when the
/// resume can be triggered from multiple concurrent contexts (Process.terminationHandler
/// fires on a background queue; the post-run defensive check runs on the calling actor).
/// Reference-type so closures can capture & mutate the flag without tripping
/// Swift's concurrent-capture diagnostics.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    /// Atomically claim the single resume opportunity. Returns true the first time,
    /// false on every subsequent call. Caller is responsible for the actual `continuation.resume(...)`.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}

// MARK: - Model Backend

enum ModelBackend: String, CaseIterable, Identifiable, Sendable {
    case onnx
    case huggingface
    case whisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onnx: return "Standard (Recommended)"
        case .huggingface: return "High Quality"
        case .whisper: return "Whisper"
        }
    }

    var shortName: String {
        switch self {
        case .onnx: return "Standard"
        case .huggingface: return "High Quality"
        case .whisper: return "Whisper"
        }
    }

    var modelRepo: String {
        switch self {
        case .onnx: return "onnx-community/cohere-transcribe-03-2026-ONNX"
        case .huggingface: return "CohereLabs/cohere-transcribe-03-2026"
        case .whisper: return "openai/whisper-large-v3-turbo"
        }
    }

    var requiredDiskSpace: Int64 {
        switch self {
        case .onnx: return 1_600_000_000       // ~1.5 GB
        case .huggingface: return 4_200_000_000 // ~4.1 GB
        case .whisper: return 1_600_000_000     // ~1.6 GB
        }
    }

    var modelSubdirectory: String {
        switch self {
        case .onnx: return "Murmur/Models-ONNX"
        case .huggingface: return "Murmur/Models"
        case .whisper: return "Murmur/Models-Whisper"
        }
    }

    /// HuggingFace download filter patterns (nil = download everything)
    var allowPatterns: [String]? {
        switch self {
        case .onnx: return ["onnx/encoder_model_q4f16*", "onnx/decoder_model_merged_q4f16*", "*.json"]
        case .huggingface, .whisper: return nil
        }
    }

    /// Files that must exist for the model to be considered valid
    var requiredFiles: [String] {
        switch self {
        case .onnx: return ["config.json", "onnx/encoder_model_q4f16.onnx", "onnx/decoder_model_merged_q4f16.onnx"]
        case .huggingface, .whisper: return ["config.json", "model.safetensors"]
        }
    }

    /// Whether this backend requires a HuggingFace token (gated model)
    var requiresHFLogin: Bool {
        switch self {
        case .onnx, .whisper: return false
        case .huggingface: return true
        }
    }

    var sizeDescription: String {
        switch self {
        case .onnx: return "~1.5 GB"
        case .huggingface: return "~4 GB"
        case .whisper: return "~1.6 GB"
        }
    }

    var description: String {
        switch self {
        case .onnx: return "Smaller download, fast and lightweight. Great for most users."
        case .huggingface: return "Uses your Mac's GPU for faster transcription. Larger download, requires a free account."
        case .whisper: return "OpenAI's Whisper model. Uses your Mac's GPU, great multilingual support. No account needed."
        }
    }
}

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
    @Published private(set) var downloadedBytes: Int64 = 0 // total bytes written so far
    @Published private(set) var statusMessage: String = ""

    /// The currently selected backend. Use `setActiveBackend(_:)` to change it;
    /// direct assignment is intentionally not exposed so callers must go through
    /// the guard that refuses switches during active downloads.
    @Published private(set) var activeBackend: ModelBackend

    /// Emits only when a backend switch is *accepted* (i.e. not refused by the
    /// download-in-progress guard). Observers that need to react to a committed
    /// backend change — such as `MurmurApp` replacing the transcription service —
    /// should subscribe here instead of `$activeBackend`, to avoid acting on
    /// attempted-but-reverted switches.
    let committedBackendChange = PassthroughSubject<ModelBackend, Never>()

    /// Attempt to switch the active backend.
    ///
    /// - Returns: `true` if the switch was accepted and persisted; `false` if a
    ///   download or verification is in progress and the switch was refused.
    @discardableResult
    func setActiveBackend(_ backend: ModelBackend) -> Bool {
        // Short-circuit: same backend requested — nothing to do. Return true because
        // the desired state is already in effect. Do NOT fire committedBackendChange;
        // any observer (e.g. MurmurApp.onReceive) would tear down and rebuild the
        // transcription service unnecessarily, wasting resources and potentially
        // killing an in-flight preload.
        guard backend != activeBackend else { return true }
        guard !isDownloadActive else {
            logger.warning("Refused backend switch \(self.activeBackend.rawValue) → \(backend.rawValue) — download in progress")
            return false
        }
        activeBackend = backend
        UserDefaults.standard.set(backend.rawValue, forKey: "modelBackend")
        committedBackendChange.send(backend)
        refreshState()
        return true
    }

    /// True while a download or verification is in progress.
    /// Use this to lock UI controls that must not run concurrently with a download.
    var isDownloadActive: Bool {
        switch state {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    private let logger = Logger(subsystem: "com.murmur.app", category: "model")

    // FU-07: Stall timeout — if downloadedBytes does not increase for this many
    // seconds, the download is considered stalled. HuggingFace downloads on a
    // normal connection always make some progress every 60s, even on a slow link.
    // 90s gives a grace period for momentary network hiccups without leaving the
    // user stuck indefinitely.
    private static let stallTimeoutSeconds: TimeInterval = 90

    // Note: downloadTask was removed (M3 — it was never assigned by download() so
    // downloadTask?.cancel() in cancelDownload() was always a no-op). The actual
    // subprocess is cancelled via activeDownloadProcess.terminate() + SIGKILL escalation.
    private var activeDownloadProcess: Process?
    private var urlSession: URLSession?
    private var resumeData: Data?

    var modelDirectory: URL {
        modelDirectory(for: activeBackend)
    }

    func modelDirectory(for backend: ModelBackend) -> URL {
        #if DEBUG
        if let override = modelDirectoryOverrides[backend] {
            return override
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(backend.modelSubdirectory)
    }

    var modelPath: URL? {
        modelPath(for: activeBackend)
    }

    // MARK: - Manifest (FU-04)

    /// File-level entry recorded in the manifest for integrity checking.
    struct ManifestFileEntry: Codable {
        let sha256: String
        let size: Int64
    }

    /// Persisted manifest written to `manifest.json` after a successful download.
    ///
    /// `isModelDownloaded(for:)` reads this file on the hot path (size-only check).
    /// `verify()` recomputes SHA-256 on every entry on the cold path.
    struct ModelManifest: Codable {
        let version: Int
        let backend: String
        let createdAt: String
        let files: [String: ManifestFileEntry]

        /// Relative path of the manifest file inside the model directory.
        static let filename = "manifest.json"
    }

    func manifestURL(for backend: ModelBackend) -> URL {
        modelDirectory(for: backend).appendingPathComponent(ModelManifest.filename)
    }

    /// Loads the manifest for `backend` from disk, or nil if absent / unreadable.
    func loadManifest(for backend: ModelBackend) -> ModelManifest? {
        let url = manifestURL(for: backend)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data)
        else { return nil }
        return manifest
    }

    /// Walks `modelDirectory(for:)` and computes a manifest entry for every file
    /// found, excluding `manifest.json` itself. Does NOT exclude `.cache/` prefixes
    /// because HF doesn't write a `.cache` subdir into local_dir.
    ///
    /// - Throws: if a file cannot be read.
    func buildManifest(for backend: ModelBackend) throws -> ModelManifest {
        let dir = modelDirectory(for: backend)
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var entries: [String: ManifestFileEntry] = [:]
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }

            // Skip the manifest file itself
            guard fileURL.lastPathComponent != ModelManifest.filename else { continue }

            let data = try Data(contentsOf: fileURL)
            let hash = SHA256.hash(data: data)
            let hashStr = hash.map { String(format: "%02x", $0) }.joined()
            let size = Int64(values.fileSize ?? 0)
            let relative = fileURL.path.replacingOccurrences(of: dir.path + "/", with: "")
            entries[relative] = ManifestFileEntry(sha256: hashStr, size: size)
        }

        let iso8601 = ISO8601DateFormatter()
        return ModelManifest(
            version: 1,
            backend: backend.rawValue,
            createdAt: iso8601.string(from: Date()),
            files: entries
        )
    }

    /// Writes `manifest` to `manifest.json` in the model directory.
    func writeManifest(_ manifest: ModelManifest, for backend: ModelBackend) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(for: backend), options: .atomic)
    }

    /// Hot-path validation: returns true only if `manifest.json` exists AND
    /// every listed file exists with the exact size recorded in the manifest.
    /// Does NOT hash — size check is cheap enough for frequent calls.
    func manifestIsValid(for backend: ModelBackend) -> Bool {
        guard let manifest = loadManifest(for: backend) else { return false }
        let dir = modelDirectory(for: backend)
        let fm = FileManager.default
        for (relative, entry) in manifest.files {
            let url = dir.appendingPathComponent(relative)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let fileSize = attrs[.size] as? Int64,
                  fileSize == entry.size
            else { return false }
        }
        return true
    }

    func modelPath(for backend: ModelBackend) -> URL? {
        let dir = modelDirectory(for: backend)
        guard manifestIsValid(for: backend) else { return nil }
        return dir
    }

    /// Check if a specific backend's model is downloaded.
    ///
    /// For the active backend, the state machine is authoritative: returns false
    /// while a download or verification is in progress, even if files exist on
    /// disk (HuggingFace writes files incrementally before the copy completes).
    /// For inactive backends, manifest validity is the signal.
    func isModelDownloaded(for backend: ModelBackend) -> Bool {
        if backend == activeBackend {
            // The state machine is authoritative for the active backend.
            // Only .ready means the model is usable; all other states — including
            // in-progress (.downloading, .verifying) and failed (.corrupt, .error)
            // — must show as not-downloaded so the UI offers the right action.
            switch state {
            case .ready:
                return manifestIsValid(for: backend)
            default:
                return false
            }
        }
        return manifestIsValid(for: backend)
    }

    /// One-time migration: if required files exist on disk but no manifest is
    /// present, compute hashes and write the manifest so the user is not forced
    /// into a redownload. Logs clearly and sets state to .ready on success.
    /// Falls through to .notDownloaded if hashing fails or files are absent.
    func migrateToManifestIfNeeded(for backend: ModelBackend) {
        guard loadManifest(for: backend) == nil else { return }

        let dir = modelDirectory(for: backend)
        let requiredFilesPresent = backend.requiredFiles.allSatisfy { file in
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path)
        }
        guard requiredFilesPresent else { return }

        logger.info("Manifest migration: hashing existing files for \(backend.rawValue)…")
        do {
            let manifest = try buildManifest(for: backend)
            try writeManifest(manifest, for: backend)
            logger.info("Manifest migration complete for \(backend.rawValue): \(manifest.files.count) files recorded")
        } catch {
            logger.error("Manifest migration failed for \(backend.rawValue): \(error) — will require redownload")
        }
    }

    var pythonEnvPath: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Python")
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "modelBackend")
            .flatMap(ModelBackend.init(rawValue:)) ?? .onnx
        // Assign directly here — we are in init, no guard needed, and setActiveBackend
        // is not callable before self is fully initialized.
        self.activeBackend = saved

        // One-time migration: move the old shared "modelConfigHash" key to the
        // per-backend key so that existing hash verifications keep working.
        let oldKey = "modelConfigHash"
        if let oldHash = UserDefaults.standard.string(forKey: oldKey) {
            let perBackendKey = "modelConfigHash_\(saved.rawValue)"
            if UserDefaults.standard.string(forKey: perBackendKey) == nil {
                UserDefaults.standard.set(oldHash, forKey: perBackendKey)
            }
            UserDefaults.standard.removeObject(forKey: oldKey)
        }

        // FU-04 manifest migration: if existing downloads predate the manifest
        // system, generate the manifest from on-disk files so users are not
        // forced to redownload 1.5–4 GB. Runs once per backend, noop thereafter.
        for backend in ModelBackend.allCases {
            migrateToManifestIfNeeded(for: backend)
        }

        refreshState()
    }

    /// Re-evaluate state based on current activeBackend
    func refreshState() {
        if modelPath != nil {
            state = .ready
            downloadProgress = 0
            downloadedBytes = 0
            statusMessage = ""
        } else {
            state = .notDownloaded
            downloadProgress = 0
            downloadedBytes = 0
            let partialSize = directorySize(modelDirectory)
            if partialSize > 0 {
                statusMessage = "Partial download: \(partialSize / 1_000_000) MB on disk"
            } else {
                statusMessage = ""
            }
        }
    }

    func checkDiskSpace() throws {
        let attrs = try FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        )
        if let freeSpace = attrs[.systemFreeSize] as? Int64, freeSpace < activeBackend.requiredDiskSpace {
            throw MurmurError.diskFull
        }
    }

    func download() async throws {
        let backend = activeBackend
        try checkDiskSpace()

        state = .downloading(progress: 0, bytesPerSec: 0)
        downloadProgress = 0
        downloadSpeed = 0

        // Create model directory
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )

        logger.info("Starting model download from HuggingFace: \(backend.modelRepo) (backend: \(backend.rawValue))")

        statusMessage = "Preparing first-time setup..."

        // Ensure bundled Python env exists with all dependencies
        let pythonBin = try await ensurePythonEnv()

        statusMessage = "Downloading speech model..."

        let allowPatternsArg: String
        if let patterns = backend.allowPatterns {
            let quoted = patterns.map { "\"\($0)\"" }.joined(separator: ", ")
            allowPatternsArg = "allow_patterns=[\(quoted)],"
        } else {
            allowPatternsArg = ""
        }

        let downloadScript = """
        import sys, json, os
        from huggingface_hub import snapshot_download

        try:
            path = snapshot_download(
                "\(backend.modelRepo)",
                local_dir="\(modelDirectory.path)",
                \(allowPatternsArg)
            )
            print(json.dumps({"status": "ok", "path": path}), flush=True)
        except Exception as e:
            msg = str(e)
            if "401" in msg or "gated" in msg.lower() or "restricted" in msg.lower():
                msg = "Access denied. Please log in and request access at huggingface.co first."
            elif "404" in msg:
                msg = "Model not found. Please check your internet connection and try again."
            print(json.dumps({"status": "error", "error": msg}), flush=True)
        """

        let process = Process()
        process.executableURL = pythonBin
        process.arguments = ["-c", downloadScript]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Monitor download activity: show downloaded size and speed.
        // We don't know the exact total, so we show an indeterminate progress
        // and only set 100% when the process confirms success.
        // Scope size tracking to the model directory only — the HF cache dir
        // can contain unrelated prior downloads and would report misleadingly
        // large numbers.
        let monitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastSize: Int64 = 0
            var speedSamples: [Int64] = []
            let maxSamples = 5
            // FU-07: Track when bytes last increased. Initialise to "now" so the
            // first poll interval doesn't immediately fire a false stall.
            var lastProgressAt = Date()

            while !Task.isCancelled && process.isRunning {
                try? await Task.sleep(for: .seconds(1))
                // Re-check after the sleep: cancel() or subprocess-exit can land
                // during the sleep, and without this guard we'd post one final
                // .downloading state write AFTER download() has set .ready or
                // .verifying, leaving the UI stuck on "Downloading".
                guard !Task.isCancelled, process.isRunning else { break }
                let modelSize = self.directorySize(self.modelDirectory)

                let instantSpeed = modelSize - lastSize
                speedSamples.append(instantSpeed)
                if speedSamples.count > maxSamples { speedSamples.removeFirst() }
                let smoothedSpeed = speedSamples.reduce(0, +) / Int64(speedSamples.count)

                // FU-07: Reset the stall clock whenever bytes increase.
                if modelSize > lastSize {
                    lastProgressAt = Date()
                }

                // FU-07: If no bytes have arrived for stallTimeoutSeconds, cancel
                // the subprocess and surface a recoverable error. We cancel the
                // process first (which stops writes), then set .error so the user
                // sees the NSAlert rather than returning to .notDownloaded silently.
                if Self.isStalled(lastProgressAt: lastProgressAt, now: Date(), timeout: Self.stallTimeoutSeconds) {
                    self.logger.warning("Download stalled — no progress for \(Self.stallTimeoutSeconds)s; cancelling subprocess")
                    self.cancelDownload()
                    // cancelDownload() sets state to .notDownloaded; override with the
                    // stall error so the existing NSAlert routing chain shows recovery UI.
                    self.state = .error(MurmurError.downloadStalled.shortMessage)
                    self.statusMessage = MurmurError.downloadStalled.alertTitle
                    break
                }

                self.downloadSpeed = smoothedSpeed
                self.downloadedBytes = modelSize
                // Use indeterminate progress (-1) so the UI shows a spinner, not a stuck bar
                self.state = .downloading(progress: -1, bytesPerSec: smoothedSpeed)
                let sizeMB = modelSize / 1_000_000
                // Always report as "Downloading" — verify() will set "Verifying" when
                // it actually runs, so we never show a misleading "Finalizing" mid-transfer.
                self.statusMessage = "Downloading: \(sizeMB) MB"
                lastSize = modelSize
            }
        }

        // Race fix: attach terminationHandler BEFORE process.run() so that a
        // cache-hit subprocess that exits in milliseconds never escapes the handler.
        // ResumeGuard ensures the handler (background queue) and the post-run
        // defensive check (calling actor) cannot both resume the same continuation.
        let resumeGuard = ResumeGuard()

        // Wait for process exit (M2 fix: don't block main actor).
        // Handler is attached first, then run() is called, then we do a defensive
        // check in case the process already exited before we finished setting up.
        let exitStatus: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                if resumeGuard.claim() {
                    continuation.resume(returning: proc.terminationStatus)
                }
            }

            do {
                try process.run()
            } catch {
                if resumeGuard.claim() {
                    continuation.resume(returning: Int32(-1))
                }
                return
            }

            // Store reference so cancelDownload() can terminate the process immediately.
            activeDownloadProcess = process

            // Defensive: if the subprocess already exited before we got here
            // (race between handler attach and run completion), resume now.
            if !process.isRunning, resumeGuard.claim() {
                continuation.resume(returning: process.terminationStatus)
            }
        }

        monitorTask.cancel()
        activeDownloadProcess = nil

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
        // --- Subprocess termination with SIGKILL escalation ---
        //
        // Process.terminate() sends SIGTERM asynchronously. Python cannot service
        // the signal until the current C-extension call returns (TLS read, file I/O,
        // zlib), which can take 1-3 seconds. During that window the process is still
        // writing to the model directory, which could corrupt the partial-file state
        // (see C6 in handoff 066).
        //
        // Strategy:
        //   1. Send SIGTERM synchronously (unblocks Python on next bytecode dispatch).
        //   2. Synchronously reset UI state so isDownloadActive is false immediately.
        //   3. In a background Task, wait up to 2 seconds for the process to exit.
        //      If it hasn't, escalate to SIGKILL via Darwin.kill to guarantee no
        //      further file writes. The background Task owns cleanup of the model
        //      directory after the process is confirmed dead.
        //
        // QA integration note: the SIGKILL path is not exercised by unit tests
        // (activeDownloadProcess is nil in the test harness). A real-subprocess
        // integration test is tracked in handoff 068_QA_EN_b3-b4-integration-ask.md.

        let capturedBackend = activeBackend
        let capturedModelDir = modelDirectory(for: capturedBackend)

        if let proc = activeDownloadProcess, proc.isRunning {
            let pid = proc.processIdentifier
            proc.terminate()
            logger.info("Sent SIGTERM to download process (pid: \(pid))")

            // Background Task: wait for exit, escalate to SIGKILL, then clean up
            // the partial model directory so isModelDownloaded(for:) cannot
            // falsely return true for an incomplete download (H5 mitigation).
            Task.detached { [weak self, logger] in
                let exited = await Self.waitForProcessExit(proc, timeoutSeconds: 2.0)
                if !exited {
                    // Process survived SIGTERM window — force-kill to guarantee no
                    // further writes to the model directory.
                    //
                    // PID-reuse note (M6): there is a sub-millisecond window between
                    // the last `proc.isRunning` poll inside waitForProcessExit and
                    // this Darwin.kill call. In theory the process could exit and
                    // the kernel could recycle its PID for an unrelated process
                    // during that window. In practice, if the recycled PID belongs
                    // to another user's process, kill() returns EPERM and is a no-op.
                    // If the recycled PID is another Murmur child (extremely unlikely
                    // — we only spawn one python subprocess at a time), we would send
                    // SIGKILL to it; that subprocess would also require cleanup, so
                    // this is an accepted risk given the narrow window. For a cleaner
                    // design, replace the poll loop with a kqueue EVFILT_PROC wait in
                    // a future refactor.
                    Darwin.kill(pid, SIGKILL)
                    logger.warning("Escalated to SIGKILL for download process (pid: \(pid))")
                    // Brief grace period for the OS to reclaim file handles before
                    // we attempt directory removal.
                    try? await Task.sleep(for: .milliseconds(100))
                } else {
                    logger.info("Download process exited cleanly after SIGTERM (pid: \(pid))")
                }

                await self?.removePartialModelDirectory(capturedModelDir, backend: capturedBackend)
            }
        }
        activeDownloadProcess = nil

        // Set state synchronously before returning so isDownloadActive is false
        // immediately — callers that check isDownloadActive right after cancel
        // (e.g. setActiveBackend guard) will see the updated state.
        state = .notDownloaded
        downloadProgress = 0
        downloadedBytes = 0
        statusMessage = ""
        logger.info("Download cancelled (subprocess cleanup running in background)")
    }

    /// Polls until `proc.isRunning` is false or `timeoutSeconds` elapses.
    ///
    /// `Process.waitUntilExit()` is a blocking call and must not be called on the
    /// main actor. This helper polls at 100ms intervals on a non-isolated context
    /// so callers can await it safely from a `Task.detached` block.
    ///
    /// - Returns: `true` if the process exited within the timeout, `false` otherwise.
    private static func waitForProcessExit(_ proc: Process, timeoutSeconds: Double) async -> Bool {
        let pollInterval = Duration.milliseconds(100)
        let maxIterations = Int(timeoutSeconds * 10) // 10 polls per second
        for _ in 0..<maxIterations {
            if !proc.isRunning { return true }
            try? await Task.sleep(for: pollInterval)
        }
        return !proc.isRunning
    }

    /// Removes the partial model directory for a cancelled download, but only if no
    /// new download has started for the same backend in the interim.
    ///
    /// This guard (C8 fix) closes the race between the cleanup Task (which runs for
    /// up to ~2.1s after `cancelDownload()`) and a user-triggered redownload of the
    /// same backend during that window. Without this check, `removeItem` would delete
    /// files the new subprocess is actively writing, corrupting the new download.
    ///
    /// The check hops to `@MainActor` to read `isDownloadActive` atomically with
    /// respect to state mutations, which always happen on the main actor.
    private func removePartialModelDirectory(_ modelDir: URL, backend: ModelBackend) async {
        // C8: hop to MainActor to read isDownloadActive atomically. If a new download
        // has started (same or different backend), skip the rmdir — the new download
        // owns the directory from this point forward.
        let shouldSkip = await MainActor.run { isDownloadActive }
        guard !shouldSkip else {
            logger.info(
                "Skipping partial-dir cleanup for \(backend.rawValue) — new download in progress; new download owns the directory"
            )
            return
        }

        // H5 mitigation: delete partial model directory now that the subprocess is
        // guaranteed dead, no new download is active, and no further writes can occur.
        // This prevents isModelDownloaded(for: backend) from falsely returning true
        // if the partial write happened to include all required file names (they may
        // still be corrupt/truncated).
        do {
            if FileManager.default.fileExists(atPath: modelDir.path) {
                try FileManager.default.removeItem(at: modelDir)
                logger.info("Removed partial model directory after cancel: \(modelDir.path)")
            }
        } catch {
            logger.error("Failed to remove partial model directory: \(error)")
        }
    }

    func verify() async throws -> Bool {
        let backend = activeBackend
        state = .verifying
        logger.info("Verifying model (\(backend.rawValue))…")

        let dir = modelDirectory(for: backend)

        // Check that required files exist before attempting to hash.
        for file in backend.requiredFiles {
            let path = dir.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: path.path) {
                logger.warning("Missing required model file: \(file)")
                state = .corrupt
                statusMessage = "Corrupt: missing \(file)"
                return false
            }
        }

        // Cold path: build a fresh manifest from disk, compare against stored manifest.
        // If no manifest exists yet (first download), write one and trust it.
        let freshManifest: ModelManifest
        do {
            freshManifest = try buildManifest(for: backend)
        } catch {
            logger.error("verify() failed to hash model files: \(error)")
            state = .corrupt
            statusMessage = "Corrupt: could not read model files"
            return false
        }

        if let storedManifest = loadManifest(for: backend) {
            // Compare SHA-256 of every file in the stored manifest against fresh hashes.
            var mismatches: [String] = []
            for (relative, storedEntry) in storedManifest.files {
                if let freshEntry = freshManifest.files[relative] {
                    if freshEntry.sha256 != storedEntry.sha256 {
                        mismatches.append(relative)
                        logger.warning("SHA-256 mismatch: \(relative) stored=\(storedEntry.sha256) actual=\(freshEntry.sha256)")
                    }
                } else {
                    mismatches.append(relative)
                    logger.warning("File in manifest but missing on disk: \(relative)")
                }
            }
            if !mismatches.isEmpty {
                let firstMismatch = mismatches.first ?? "unknown"
                state = .corrupt
                statusMessage = "Corrupt: hash mismatch in \(firstMismatch)"
                return false
            }
            logger.info("verify(): all \(storedManifest.files.count) files match stored manifest")
        } else {
            // No manifest yet — write one from the freshly computed hashes.
            do {
                try writeManifest(freshManifest, for: backend)
                logger.info("verify(): wrote initial manifest for \(backend.rawValue) with \(freshManifest.files.count) files")
            } catch {
                logger.error("verify(): failed to write manifest: \(error)")
                // Non-fatal: verification still passes; next call will retry migration.
            }
        }

        state = .ready
        logger.info("Model verification passed (\(backend.rawValue))")
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

    // MARK: - Stall Detection

    /// Pure predicate: returns true when the elapsed time since the last byte-count
    /// increase meets or exceeds `timeout`. Extracted from the monitor loop so it
    /// can be unit-tested without running a real download.
    ///
    /// Marked `nonisolated` because it is a pure computation with no access to
    /// actor-isolated state — callers can invoke it from any concurrency context.
    ///
    /// - Parameters:
    ///   - lastProgressAt: The timestamp when `downloadedBytes` last increased.
    ///   - now: The reference "current" time (injectable for testing).
    ///   - timeout: Stall threshold in seconds; defaults to `stallTimeoutSeconds`.
    /// - Returns: `true` if no progress has been made for at least `timeout` seconds.
    nonisolated static func isStalled(lastProgressAt: Date, now: Date, timeout: TimeInterval) -> Bool {
        return now.timeIntervalSince(lastProgressAt) >= timeout
    }

    // MARK: - Helpers

    /// Creates the bundled Python venv and installs all dependencies.
    private func ensurePythonEnv() async throws -> URL {
        let bundledPython = pythonEnvPath.appendingPathComponent("bin/python3")

        if FileManager.default.fileExists(atPath: bundledPython.path) {
            statusMessage = "Checking setup..."
            let check = try await runProcess(bundledPython, args: ["-c", "import huggingface_hub, onnxruntime, transformers, torch, opencc; print('ok')"])
            if check.status == 0 {
                statusMessage = "Ready"
                return bundledPython
            }
            statusMessage = "Installing missing components..."
        }

        guard let systemPython = findSystemPython() else {
            statusMessage = "Error: Python is required but not installed"
            state = .error("Python3 not found. Install it from python.org or via Homebrew: brew install python3")
            throw MurmurError.transcriptionFailed("Python3 not found")
        }

        // Create venv
        if !FileManager.default.fileExists(atPath: bundledPython.path) {
            statusMessage = "Preparing environment..."
            let venvResult = try await runProcess(systemPython, args: ["-m", "venv", pythonEnvPath.path])
            if venvResult.status != 0 {
                statusMessage = "Error: Failed to set up environment"
                state = .error("Setup failed — could not create environment")
                throw MurmurError.transcriptionFailed("venv creation failed: \(venvResult.stderr.prefix(200))")
            }
        }

        // Install all packages from pinned requirements.txt
        let pip = pythonEnvPath.appendingPathComponent("bin/pip3")
        statusMessage = "Setting up: installing components..."

        // Find requirements.txt — it lives alongside transcribe.py in the app bundle Resources
        let requirementsPath: String? = {
            if let bundlePath = Bundle.main.path(forResource: "requirements", ofType: "txt") {
                return bundlePath
            }
            // Fallback: resolve relative to the bundle's Resources directory
            if let resourcesURL = Bundle.main.resourceURL {
                let candidate = resourcesURL.appendingPathComponent("requirements.txt")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate.path
                }
            }
            return nil
        }()

        if let reqPath = requirementsPath {
            let result = try await runProcessWithLiveOutput(pip, args: ["install", "-r", reqPath])
            if result != 0 {
                // Fall back to individual pinned installs if the requirements file approach fails
                let packages: [(String, String)] = [
                    ("huggingface_hub==0.30.2", "Setting up: downloading components (1/8)..."),
                    ("transformers==4.52.4", "Setting up: downloading components (2/8)..."),
                    ("torch==2.7.0", "Setting up: downloading components (3/8, this may take a minute)..."),
                    ("onnxruntime==1.21.1", "Setting up: downloading components (4/8)..."),
                    ("soundfile==0.13.1", "Setting up: downloading components (5/8)..."),
                    ("librosa==0.11.0", "Setting up: downloading components (6/8)..."),
                    ("accelerate==1.7.0", "Setting up: downloading components (7/8)..."),
                    ("opencc-python-reimplemented==0.1.7", "Setting up: downloading components (8/8)..."),
                ]
                for (pkg, message) in packages {
                    statusMessage = message
                    let pkgResult = try await runProcessWithLiveOutput(pip, args: ["install", pkg])
                    if pkgResult != 0 {
                        statusMessage = "Error: Setup failed. Please check your internet connection."
                        state = .error("Setup failed — could not install required components")
                        throw MurmurError.transcriptionFailed("pip install \(pkg) failed")
                    }
                }
            }
        } else {
            // requirements.txt not found in bundle — fall back to individual pinned installs
            let packages: [(String, String)] = [
                ("huggingface_hub==0.30.2", "Setting up: downloading components (1/8)..."),
                ("transformers==4.52.4", "Setting up: downloading components (2/8)..."),
                ("torch==2.7.0", "Setting up: downloading components (3/8, this may take a minute)..."),
                ("onnxruntime==1.21.1", "Setting up: downloading components (4/8)..."),
                ("soundfile==0.13.1", "Setting up: downloading components (5/8)..."),
                ("librosa==0.11.0", "Setting up: downloading components (6/8)..."),
                ("accelerate==1.7.0", "Setting up: downloading components (7/8)..."),
                ("opencc-python-reimplemented==0.1.7", "Setting up: downloading components (8/8)..."),
            ]
            for (pkg, message) in packages {
                statusMessage = message
                let result = try await runProcessWithLiveOutput(pip, args: ["install", pkg])
                if result != 0 {
                    statusMessage = "Error: Setup failed. Please check your internet connection."
                    state = .error("Setup failed — could not install required components")
                    throw MurmurError.transcriptionFailed("pip install \(pkg) failed")
                }
            }
        }

        statusMessage = "Setup complete"
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

        // Same race fix as download(): attach handler before run(). See ResumeGuard.
        let resumeGuard = ResumeGuard()
        let status: Int32 = await withCheckedContinuation { continuation in
            proc.terminationHandler = { p in
                if resumeGuard.claim() {
                    continuation.resume(returning: p.terminationStatus)
                }
            }
            do { try proc.run() } catch {
                if resumeGuard.claim() {
                    continuation.resume(returning: Int32(-1))
                }
                return
            }
            if !proc.isRunning, resumeGuard.claim() {
                continuation.resume(returning: proc.terminationStatus)
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

        // Same race fix: attach handler before run(). See ResumeGuard.
        let resumeGuard = ResumeGuard()
        let status: Int32 = await withCheckedContinuation { continuation in
            proc.terminationHandler = { p in
                if resumeGuard.claim() {
                    continuation.resume(returning: p.terminationStatus)
                }
            }
            do { try proc.run() } catch {
                if resumeGuard.claim() {
                    continuation.resume(returning: Int32(-1))
                }
                return
            }
            if !proc.isRunning, resumeGuard.claim() {
                continuation.resume(returning: proc.terminationStatus)
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

    // MARK: - Test Seams (DEBUG only)
    //
    // These functions are compiled only in DEBUG builds and are intentionally
    // named with a `__testing_` prefix to make misuse obvious at call sites.
    //
    // Access guard (C7): each seam asserts at runtime that it is being called
    // from within an XCTest run. This prevents accidental invocation from debug
    // menus, LLDB scripts, or future features in non-test Debug code paths.
    // The check is `NSClassFromString("XCTestCase") != nil`, which is true only
    // when the XCTest framework is loaded (i.e. during `swift test` runs).
    //
    // This is "option (b)" from handoff 066 C7: keeps `internal` access level
    // (required for @testable import) but adds a structural safety check so the
    // guard is enforced at runtime, not just by convention.

#if DEBUG
    /// Override the model directory resolved by `modelDirectory(for:)` for a
    /// specific backend. Integration tests use this to redirect file operations
    /// to a temp directory instead of the user's real Application Support path.
    ///
    /// NEVER call this from non-test code.
    private var modelDirectoryOverrides: [ModelBackend: URL] = [:]

    func __testing_setModelDirectory(_ url: URL, for backend: ModelBackend) {
        assert(
            NSClassFromString("XCTestCase") != nil,
            "__testing_setModelDirectory invoked outside XCTest — this is a test seam and must only be called from unit tests"
        )
        modelDirectoryOverrides[backend] = url
    }

    /// Inject a pre-launched Process as the active download process, so that
    /// integration tests can exercise the SIGTERM → poll → SIGKILL → cleanup
    /// path without running a real model download.
    ///
    /// The process must already be running (proc.run() called) before injection.
    /// NEVER call this from non-test code.
    func __testing_injectDownloadProcess(_ proc: Process) {
        assert(
            NSClassFromString("XCTestCase") != nil,
            "__testing_injectDownloadProcess invoked outside XCTest — this is a test seam and must only be called from unit tests"
        )
        self.activeDownloadProcess = proc
    }

    /// Force the internal state to a specific value for unit testing.
    ///
    /// This is the *only* way tests can drive the manager into `.downloading`,
    /// `.verifying`, `.corrupt`, or `.error` without running a real download.
    /// NEVER call this from non-test code. The runtime assertion below enforces
    /// this structurally in all Debug builds.
    func __testing_setState(_ newState: ModelState) {
        assert(
            NSClassFromString("XCTestCase") != nil,
            "__testing_setState invoked outside XCTest — this is a test seam and must only be called from unit tests"
        )
        state = newState
    }

    /// Force the activeBackend without going through the download guard.
    ///
    /// Used by tests that need to set up a specific backend without triggering
    /// refreshState() side-effects that would require real files on disk.
    /// NEVER call this from non-test code.
    func __testing_setActiveBackend(_ backend: ModelBackend) {
        assert(
            NSClassFromString("XCTestCase") != nil,
            "__testing_setActiveBackend invoked outside XCTest — this is a test seam and must only be called from unit tests"
        )
        activeBackend = backend
    }

    /// Directly invokes the post-cancel cleanup logic for deterministic unit testing
    /// of the C8 race-condition fix.
    ///
    /// This bypasses the subprocess lifecycle (SIGTERM / poll / SIGKILL) that is not
    /// exercisable in unit tests without a real Process. It lets tests set up a known
    /// state (e.g. `isDownloadActive == true`) and verify that cleanup correctly skips
    /// `removeItem` when a new download is in progress.
    ///
    /// NEVER call this from non-test code.
    func __testing_runCleanupAfterCancel(for backend: ModelBackend) async {
        assert(
            NSClassFromString("XCTestCase") != nil,
            "__testing_runCleanupAfterCancel invoked outside XCTest — this is a test seam and must only be called from unit tests"
        )
        let modelDir = modelDirectory(for: backend)
        await removePartialModelDirectory(modelDir, backend: backend)
    }
#endif
}
