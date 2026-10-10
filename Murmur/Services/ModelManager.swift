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

/// The speech model Murmur runs. There is one engine today; the enum keeps the
/// per-model metadata (repo, files, on-disk location) in one place and leaves
/// room for another model without reshaping `ModelManager`.
enum ModelBackend: String, CaseIterable, Identifiable, Sendable {
    case qwen3

    var id: String { rawValue }

    var displayName: String { "Qwen3-ASR" }

    var shortName: String { "Qwen3-ASR" }

    var modelRepo: String { "csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25" }

    /// The commit of `modelRepo` that Murmur downloads. Pinned so the files
    /// and their checksums cannot change under a shipped app; moving to newer
    /// model files is a deliberate edit of this line.
    var modelRevision: String { "68818b2313fe77bd06f6a7c5068ff3ef59d02b8a" }

    var requiredDiskSpace: Int64 { 1_050_000_000 }  // ~0.99 GB rounded up

    var modelSubdirectory: String { "Murmur/Models-Qwen3ASR" }

    /// HuggingFace download filter patterns (nil = download everything)
    var allowPatterns: [String]? {
        ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx", "tokenizer/*"]
    }

    /// Files that must exist for the model to be considered valid
    var requiredFiles: [String] {
        [
            "conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx",
            "tokenizer/vocab.json", "tokenizer/merges.txt", "tokenizer/tokenizer_config.json",
        ]
    }

    /// Whether this model requires a HuggingFace token (gated model).
    var requiresHFLogin: Bool { false }

    var sizeDescription: String { "~0.99 GB" }

    var description: String {
        "Chinese, English and mixed speech, with punctuation. Runs entirely on this Mac."
    }

    /// Model folders left behind by engines that Murmur no longer ships
    /// (Cohere Transcribe, FireRedASR2, and their add-ons), relative to
    /// Application Support. They are never read; the user can delete them.
    static let legacySubdirectories = [
        "Murmur/Models-ONNX", "Murmur/Models-FireRed", "Murmur/Models",
        "Murmur/Models-Whisper", "Murmur/Models-PuncCT", "Murmur/Models-LID",
        "Murmur/Python",
    ]
}

// MARK: - Auxiliary Model

/// Small, optional models that live alongside the speech model. Unlike
/// `ModelBackend`, there is no notion of an "active" auxiliary — each one is
/// downloaded and managed independently on demand.
enum AuxiliaryModel: String, CaseIterable, Identifiable, Sendable {
    /// Silero VAD v5 (ONNX). Used by `VadService` to drive endpointing
    /// across live PTT, hands-free, and long-audio chunking. Pulled from the
    /// `onnx-community/silero-vad` mirror — the same Silero v5 graph that
    /// sherpa-onnx uses internally.
    case sileroVad

    var id: String { rawValue }

    var displayName: String { "Voice Activity Detection Model" }

    var modelRepo: String { "onnx-community/silero-vad" }

    /// The pinned commit of `modelRepo`; see `ModelBackend.modelRevision`.
    var modelRevision: String { "e71cae966052b992a7eca6b17738916ce0eca4ec" }

    var modelSubdirectory: String { "Murmur/Models-SileroVAD" }

    var requiredDiskSpace: Int64 { 10_000_000 }  // ~2.2 MB ONNX + headroom

    var sizeDescription: String { "~2 MB" }

    /// Just the unquantised ONNX — sherpa-onnx loads the Silero v5 graph directly.
    var allowPatterns: [String] { ["onnx/model.onnx"] }

    var requiredFiles: [String] { ["onnx/model.onnx"] }
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

@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var state: ModelState = .notDownloaded
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var downloadSpeed: Int64 = 0 // bytes/sec
    @Published private(set) var downloadedBytes: Int64 = 0 // total bytes written so far
    @Published private(set) var statusMessage: String = ""

    /// The speech model in use. Fixed today — there is a single model.
    let activeBackend: ModelBackend = .qwen3

    /// Per-auxiliary-model state. Only keys the user has interacted with appear.
    /// Reads go through `auxiliaryState(for:)` which returns `.notDownloaded` for
    /// absent keys, so consumers never need to nil-coalesce.
    @Published private(set) var auxiliaryStates: [AuxiliaryModel: ModelState] = [:]
    @Published private(set) var auxiliaryProgress: [AuxiliaryModel: Double] = [:]
    @Published private(set) var auxiliarySpeed: [AuxiliaryModel: Int64] = [:]
    @Published private(set) var auxiliaryDownloadedBytes: [AuxiliaryModel: Int64] = [:]
    @Published private(set) var auxiliaryStatusMessage: [AuxiliaryModel: String] = [:]

    /// Whether the Silero VAD model should be wired into the audio
    /// pipelines (live PTT silence gate, hands-free auto-stop, V3
    /// streaming chunk boundaries, long-audio chunking + paragraph
    /// breaks). OFF by default; flipping ON downloads the ~2 MB model if
    /// it isn't already on disk. Callers MUST go through `setUseVAD(_:)` —
    /// direct assignment is not exposed so the gating logic (download active,
    /// model not downloaded) runs every time.
    @Published private(set) var useVAD: Bool

    /// Emits when `setUseVAD(_:)` actually commits a change.
    let committedUseVADChange = PassthroughSubject<Bool, Never>()

    /// Attempt to set the Silero VAD toggle.
    ///
    /// - Parameter newValue: desired toggle state.
    /// - Returns: `true` if accepted; `false` if a primary download is in
    ///   progress (newValue=true rejected) or the VAD model isn't on disk
    ///   yet (caller must trigger `downloadAuxiliary(.sileroVad)` first).
    @discardableResult
    func setUseVAD(_ newValue: Bool) -> Bool {
        guard newValue != useVAD else { return true }

        if newValue == true {
            guard !isDownloadActive else {
                logger.warning("Refused VAD toggle ON — primary download in progress")
                return false
            }
            let dir = auxiliaryModelDirectory(.sileroVad)
            let allPresent = AuxiliaryModel.sileroVad.requiredFiles.allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            guard allPresent else {
                logger.warning("Refused VAD toggle ON — model not downloaded")
                return false
            }
        }

        useVAD = newValue
        UserDefaults.standard.set(newValue, forKey: "useVAD")
        committedUseVADChange.send(newValue)
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

    // The subprocess is cancelled via activeDownloadProcess.terminate() + SIGKILL escalation.
    private var activeDownloadProcess: Process?

    /// Identifies the current download attempt. `download()` and
    /// `cancelDownload()` both advance it; a `download()` that finds a
    /// different value after an `await` was cancelled and must stop without
    /// touching the published state, which now belongs to the canceller or to
    /// a newer attempt.
    private var downloadEpoch = 0

    /// The download's contact points with the outside world. Production uses
    /// the defaults; tests replace them to run `download()` without a network.
    struct DownloadEnvironment {
        /// Returns the body of the Hugging Face file listing at the given URL.
        var fetchListing: @MainActor (URL) async throws -> Data = ModelManager.fetchListing(_:)
        /// Builds (but does not start) the subprocess for `HFDownload.curlArguments`.
        var makeProcess: @MainActor ([String]) -> Process = ModelManager.makeCurlProcess(arguments:)
        // FU-07: Stall timeout — if downloadedBytes does not increase for this many
        // seconds, the download is considered stalled. HuggingFace downloads on a
        // normal connection always make some progress every 60s, even on a slow link.
        // 90s gives a grace period for momentary network hiccups without leaving the
        // user stuck indefinitely.
        var stallTimeout: TimeInterval = 90
    }
    private var downloadEnvironment = DownloadEnvironment()

    /// Present in a model directory from the start of a download until its
    /// files have passed verification. Hidden, so `buildManifest` skips it.
    private static let incompleteMarker = ".download-incomplete"

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
    /// found, excluding `manifest.json` itself and hidden files.
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

        // Canonicalise the root path so relative-path stripping works even when
        // the enumerator yields a symlink-resolved variant (e.g. test tempdirs
        // where `/var/folders/...` resolves to `/private/var/folders/...`).
        let rootPath = dir.resolvingSymlinksInPath().path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

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
            let resolvedPath = fileURL.resolvingSymlinksInPath().path
            let relative: String
            if resolvedPath.hasPrefix(rootPrefix) {
                relative = String(resolvedPath.dropFirst(rootPrefix.count))
            } else {
                // Defensive: if the enumerator surfaces an out-of-tree path,
                // fall back to the filename so the entry still roundtrips
                // through manifestIsValid rather than being keyed to garbage.
                relative = fileURL.lastPathComponent
            }
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
    /// disk (curl writes them incrementally).
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
        // Files of a download that never passed verification must not be
        // blessed with a manifest; the next download() checks and completes them.
        guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent(Self.incompleteMarker).path) else { return }
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

    init() {
        // Downgrade the VAD toggle to OFF if its model is not actually on disk —
        // guards against stale state when the folder was deleted by hand.
        let persistedVAD = UserDefaults.standard.bool(forKey: "useVAD")
        let vadDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AuxiliaryModel.sileroVad.modelSubdirectory)
        let vadFilesPresent = AuxiliaryModel.sileroVad.requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: vadDir.appendingPathComponent($0).path)
        }
        let effectiveVAD = persistedVAD && vadFilesPresent
        if persistedVAD && !effectiveVAD {
            UserDefaults.standard.set(false, forKey: "useVAD")
        }
        self.useVAD = effectiveVAD

        // FU-04 manifest migration: if existing downloads predate the manifest
        // system, generate the manifest from on-disk files so users are not
        // forced to redownload 1.5–4 GB. Runs once per backend, noop thereafter.
        for backend in ModelBackend.allCases {
            migrateToManifestIfNeeded(for: backend)
        }

        refreshState()

        for aux in AuxiliaryModel.allCases {
            refreshAuxiliaryState(aux)
        }
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
        guard !isDownloadActive else {
            logger.info("download(): already in progress")
            return
        }
        let backend = activeBackend
        try checkDiskSpace()

        let directory = modelDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent(Self.incompleteMarker).path, contents: nil
        )

        downloadEpoch += 1
        let epoch = downloadEpoch
        state = .downloading(progress: 0, bytesPerSec: 0)
        downloadProgress = 0
        downloadSpeed = 0

        logger.info("Starting model download from HuggingFace: \(backend.modelRepo)@\(backend.modelRevision) (backend: \(backend.rawValue))")

        statusMessage = "Preparing download..."

        // Model files are fetched with the system curl. Both URLSession (file
        // listing) and /usr/bin/curl (SecureTransport) trust the macOS keychain,
        // so TLS-intercepting clients such as Cloudflare WARP work without a
        // custom CA bundle.
        let files: [HFDownload.File]
        do {
            files = try await listFiles(
                repo: backend.modelRepo, revision: backend.modelRevision,
                patterns: backend.allowPatterns, required: backend.requiredFiles, into: directory
            )
        } catch {
            try throwIfCancelled(epoch)
            let message = Self.downloadListingErrorMessage(error)
            logger.error("Model file listing failed: \(String(describing: error))")
            statusMessage = "Error: \(message)"
            state = .error(String(message.prefix(200)))
            throw MurmurError.transcriptionFailed(message)
        }
        try throwIfCancelled(epoch)

        // A file already on disk is kept only when its content matches the
        // listed checksum; a matching size alone proves nothing. Partial files
        // are resumed, and wrong ones are deleted so curl starts them over.
        let statuses = await Self.localStatuses(of: files, in: directory)
        try throwIfCancelled(epoch)
        let plan = HFDownload.plan(for: files, statuses: statuses)
        Self.remove(plan.delete, from: directory)

        if !plan.fetch.isEmpty {
            statusMessage = "Downloading speech model..."

            let transfers = plan.fetch.map {
                HFDownload.transfer(for: $0, repo: backend.modelRepo, revision: backend.modelRevision, into: directory)
            }
            let process = downloadEnvironment.makeProcess(HFDownload.curlArguments(for: transfers))
            let stallTimeout = downloadEnvironment.stallTimeout

            // Monitor download activity: show downloaded size and speed.
            // The progress is indeterminate; 100% is only set once curl has
            // finished. Returns true when it stopped the download for a stall.
            let monitorTask = Task { @MainActor [weak self] () -> Bool in
                guard let self else { return false }
                var lastSize: Int64 = 0
                var speedSamples: [Int64] = []
                let maxSamples = 5
                // FU-07: Track when bytes last increased. Initialise to "now" so the
                // first poll interval doesn't immediately fire a false stall.
                var lastProgressAt = Date()

                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    // Re-check after the sleep: a cancel or the subprocess exit can
                    // land during it, and without this guard we'd post one final
                    // .downloading state write AFTER the state has moved on,
                    // leaving the UI stuck on "Downloading".
                    guard !Task.isCancelled, self.downloadEpoch == epoch else { break }
                    let modelSize = self.directorySize(directory)

                    let instantSpeed = modelSize - lastSize
                    speedSamples.append(instantSpeed)
                    if speedSamples.count > maxSamples { speedSamples.removeFirst() }
                    let smoothedSpeed = speedSamples.reduce(0, +) / Int64(speedSamples.count)

                    // FU-07: Reset the stall clock whenever bytes increase.
                    if modelSize > lastSize {
                        lastProgressAt = Date()
                    }

                    // FU-07: If no bytes have arrived for stallTimeout, cancel
                    // the subprocess and surface a recoverable error. We cancel the
                    // process first (which stops writes), then set .error so the user
                    // sees the NSAlert rather than returning to .notDownloaded silently.
                    if Self.isStalled(lastProgressAt: lastProgressAt, now: Date(), timeout: stallTimeout) {
                        self.logger.warning("Download stalled — no progress for \(stallTimeout)s; cancelling subprocess")
                        self.cancelDownload()
                        // cancelDownload() sets state to .notDownloaded; override with the
                        // stall error so the existing NSAlert routing chain shows recovery UI.
                        self.state = .error(MurmurError.downloadStalled.shortMessage)
                        self.statusMessage = MurmurError.downloadStalled.alertTitle
                        return true
                    }

                    self.downloadSpeed = smoothedSpeed
                    self.downloadedBytes = modelSize
                    // Use indeterminate progress (-1) so the UI shows a spinner, not a stuck bar
                    self.state = .downloading(progress: -1, bytesPerSec: smoothedSpeed)
                    let sizeMB = modelSize / 1_000_000
                    self.statusMessage = "Downloading: \(sizeMB) MB"
                    lastSize = modelSize
                }
                return false
            }

            // Store the reference so cancelDownload() can terminate the process immediately.
            let (end, stderr) = await run(process) { activeDownloadProcess = process }

            monitorTask.cancel()
            if await monitorTask.value {
                // The monitor has already published the stall error; keep it.
                throw MurmurError.downloadStalled
            }
            try throwIfCancelled(epoch)
            activeDownloadProcess = nil

            if let message = HFDownload.failureMessage(for: end, stderr: stderr) {
                logger.error("Model download error: \(message)")
                statusMessage = "Error: \(message)"
                state = .error(String(message.prefix(200)))
                throw MurmurError.transcriptionFailed(message)
            }
        }

        // curl's exit status is not proof: every fetched file must now have
        // the listed size and checksum.
        logger.info("Model downloaded, verifying...")
        state = .verifying
        statusMessage = "Verifying model..."
        downloadProgress = 1.0
        let fetchedStatuses = await Self.localStatuses(of: plan.fetch, in: directory)
        try throwIfCancelled(epoch)
        let fetched = HFDownload.plan(for: plan.fetch, statuses: fetchedStatuses)
        Self.remove(fetched.delete, from: directory)

        switch HFDownload.rejection(afterFetch: fetched) {
        case .corrupt(let message):
            logger.error("Model verification failed: \(message)")
            statusMessage = "Error: \(message)"
            state = .corrupt
            throw MurmurError.transcriptionFailed(message)
        case .incomplete(let message):
            logger.error("Model download incomplete: \(message)")
            statusMessage = "Error: \(message)"
            state = .error(String(message.prefix(200)))
            throw MurmurError.transcriptionFailed(message)
        case nil:
            break
        }

        // Record what was verified. This replaces any older manifest: the
        // pinned listing, not the previous contents of the folder, is the reference.
        do {
            let sha256 = plan.verified.merging(fetched.verified) { $1 }
            try writeManifest(Self.manifest(named: backend.rawValue, files: files, sha256: sha256), for: backend)
        } catch {
            logger.error("Failed to write model manifest: \(error)")
            statusMessage = "Error: Could not save the model manifest"
            state = .error("Could not save the model manifest")
            throw error
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.incompleteMarker))

        state = .ready
        statusMessage = "Model ready"
        logger.info("Model ready (\(backend.rawValue)): \(files.count) files verified")
    }

    /// Throws when `cancelDownload()` has run since the download attempt
    /// identified by `epoch` started.
    private func throwIfCancelled(_ epoch: Int) throws {
        if epoch != downloadEpoch { throw CancellationError() }
    }

    func cancelDownload() {
        // --- Subprocess termination with SIGKILL escalation ---
        //
        // Process.terminate() sends SIGTERM asynchronously. curl normally exits at
        // once, but until it has, it may still be writing to the model directory,
        // which could corrupt the partial-file state (see C6 in handoff 066).
        //
        // Strategy:
        //   1. Send SIGTERM synchronously (curl exits at its next write).
        //   2. Synchronously reset UI state so isDownloadActive is false immediately.
        //   3. In a background Task, wait up to 2 seconds for the process to exit.
        //      If it hasn't, escalate to SIGKILL via Darwin.kill to guarantee no
        //      further file writes. The background Task owns cleanup of the model
        //      directory after the process is confirmed dead.
        //
        // QA integration note: the SIGKILL path is not exercised by unit tests
        // (activeDownloadProcess is nil in the test harness). A real-subprocess
        // integration test is tracked in handoff 068_QA_EN_b3-b4-integration-ask.md.

        // Tell a download() that is suspended (listing, hashing, or waiting
        // for curl) that it has been cancelled, whether or not curl is running.
        downloadEpoch += 1

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
                    // — we only spawn one download subprocess at a time), we would send
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
        // (e.g. the setUseVAD guard, or a new download()) will see the updated state.
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

    // MARK: - Leftovers from removed engines

    private var legacyURLs: [URL] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ModelBackend.legacySubdirectories.map { appSupport.appendingPathComponent($0) }
            + [appSupport.appendingPathComponent("Murmur/cabundle.pem")]
    }

    /// Bytes on disk still held by models and tooling of engines Murmur no
    /// longer ships. Zero when there is nothing to clean up.
    func legacyDataSize() -> Int64 {
        legacyURLs.reduce(0) { total, url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return total }
            if isDirectory.boolValue { return total + directorySize(url) }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            return total + (size ?? 0)
        }
    }

    /// Delete the leftovers counted by `legacyDataSize()`.
    func deleteLegacyData() {
        for url in legacyURLs where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                logger.info("Removed legacy data at \(url.path, privacy: .public)")
            } catch {
                logger.warning("Could not remove legacy data at \(url.path, privacy: .public): \(error.localizedDescription)")
            }
        }
        objectWillChange.send()
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
    ///   - timeout: Stall threshold in seconds.
    /// - Returns: `true` if no progress has been made for at least `timeout` seconds.
    nonisolated static func isStalled(lastProgressAt: Date, now: Date, timeout: TimeInterval) -> Bool {
        return now.timeIntervalSince(lastProgressAt) >= timeout
    }

    // MARK: - HuggingFace download (native)

    /// Lists the files of `repo` at `revision` that match `patterns`. Every
    /// name in `required` must be among them, so a short or paged listing
    /// fails here instead of producing a model with files missing.
    private func listFiles(
        repo: String, revision: String, patterns: [String]?, required: [String], into directory: URL
    ) async throws -> [HFDownload.File] {
        guard let url = HFDownload.listingURL(repo: repo, revision: revision) else {
            throw MurmurError.transcriptionFailed("Invalid model repository: \(repo)")
        }
        let data = try await downloadEnvironment.fetchListing(url)
        let files = try HFDownload.parseListing(data, patterns: patterns, into: directory)
        if let missing = required.first(where: { name in !files.contains { $0.path == name } }) {
            throw MurmurError.transcriptionFailed("\(missing) is not in the file listing of \(repo)")
        }
        return files
    }

    nonisolated static func fetchListing(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw MurmurError.transcriptionFailed("huggingface.co returned HTTP \(status) when listing model files")
        }
        return data
    }

    nonisolated static func makeCurlProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        return process
    }

    /// Checks each file on disk against its listing entry. Runs detached:
    /// hashing the model takes seconds and must not hold the main actor.
    private nonisolated static func localStatuses(
        of files: [HFDownload.File], in directory: URL
    ) async -> [HFDownload.LocalStatus] {
        await Task.detached {
            files.map { HFDownload.localStatus(of: $0, in: directory) }
        }.value
    }

    private nonisolated static func remove(_ files: [HFDownload.File], from directory: URL) {
        for file in files {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.path))
        }
    }

    /// The manifest of a download whose files all passed verification.
    private nonisolated static func manifest(
        named name: String, files: [HFDownload.File], sha256: [String: String]
    ) -> ModelManifest {
        var entries: [String: ManifestFileEntry] = [:]
        for file in files {
            if let hash = sha256[file.path] {
                entries[file.path] = ManifestFileEntry(sha256: hash, size: file.size)
            }
        }
        return ModelManifest(
            version: 1,
            backend: name,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            files: entries
        )
    }

    /// Runs `process` to its end without blocking the main actor and returns
    /// how it ended together with its stderr. `onLaunch` runs once the
    /// process has started.
    private func run(
        _ process: Process, onLaunch: () -> Void = {}
    ) async -> (end: HFDownload.ProcessEnd, stderr: String) {
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        // Stream stderr to the logger as it arrives, so a hung transfer (e.g.
        // waiting on a TLS handshake under WARP) is visible while it happens.
        let logger = self.logger
        let stderrText = Task { () -> String in
            var lines: [String] = []
            do {
                for try await line in stderr.fileHandleForReading.bytes.lines {
                    lines.append(line)
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        logger.info("curl! \(trimmed)")
                    }
                }
            } catch {}
            return lines.joined(separator: "\n")
        }

        // Race fix: attach terminationHandler BEFORE process.run() so that a
        // subprocess that exits in milliseconds never escapes the handler.
        // ResumeGuard ensures the handler (background queue) and the post-run
        // defensive check (calling actor) cannot both resume the same continuation.
        let resumeGuard = ResumeGuard()
        let end: HFDownload.ProcessEnd = await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                if resumeGuard.claim() {
                    continuation.resume(returning: HFDownload.ProcessEnd(proc))
                }
            }

            do {
                try process.run()
            } catch {
                if resumeGuard.claim() {
                    continuation.resume(returning: .launchFailed)
                }
                return
            }

            onLaunch()

            // Defensive: if the subprocess already exited before we got here
            // (race between handler attach and run completion), resume now.
            if !process.isRunning, resumeGuard.claim() {
                continuation.resume(returning: HFDownload.ProcessEnd(process))
            }
        }

        // Our copy of the write end must be closed for the reader to see EOF
        // (it is still open when the launch failed).
        try? stderr.fileHandleForWriting.close()
        return (end, await stderrText.value)
    }

    /// User-facing explanation for a failure while listing the model files.
    nonisolated static func downloadListingErrorMessage(_ error: Error) -> String {
        if case MurmurError.transcriptionFailed(let message) = error { return message }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid, .secureConnectionFailed:
                return "TLS certificate verification failed for huggingface.co. If you use Cloudflare WARP / Zero Trust, make sure its root certificate is trusted in Keychain Access."
            default:
                return "Could not reach huggingface.co (\(urlError.localizedDescription))."
            }
        }
        return "Could not list model files: \(error.localizedDescription)"
    }

    // MARK: - Helpers

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

    // MARK: - Auxiliary Models

    /// Current state of an auxiliary model. Returns `.notDownloaded` for any
    /// key that has never been mutated; `downloadAuxiliary` / `deleteAuxiliary`
    /// / constructor migration populates the dictionary lazily.
    func auxiliaryState(for aux: AuxiliaryModel) -> ModelState {
        auxiliaryStates[aux] ?? .notDownloaded
    }

    func auxiliaryModelDirectory(_ aux: AuxiliaryModel) -> URL {
        #if DEBUG
        if let override = auxiliaryDirectoryOverrides[aux] {
            return override
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(aux.modelSubdirectory)
    }

    /// Manifest path for an auxiliary model — stored inside its own directory
    /// alongside the ONNX files, same scheme as the primary backends.
    private func auxiliaryManifestURL(_ aux: AuxiliaryModel) -> URL {
        auxiliaryModelDirectory(aux).appendingPathComponent(ModelManifest.filename)
    }

    /// Cheap validity check — same semantics as `manifestIsValid(for:)` but for
    /// an auxiliary model. Required by `isAuxiliaryDownloaded` so UI can render
    /// the row without hashing.
    func auxiliaryManifestIsValid(_ aux: AuxiliaryModel) -> Bool {
        let url = auxiliaryManifestURL(aux)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data)
        else { return false }
        let dir = auxiliaryModelDirectory(aux)
        for (relative, entry) in manifest.files {
            let fileURL = dir.appendingPathComponent(relative)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let fileSize = attrs[.size] as? Int64,
                  fileSize == entry.size
            else { return false }
        }
        return true
    }

    func isAuxiliaryDownloaded(_ aux: AuxiliaryModel) -> Bool {
        // While a download or verification is in flight, report false so the
        // UI offers the correct next action (e.g. "Cancel" rather than "Use").
        switch auxiliaryState(for: aux) {
        case .downloading, .verifying:
            return false
        case .ready, .notDownloaded, .corrupt, .error:
            // Manifest on disk is authoritative — .notDownloaded covers the
            // cold-launch case where refreshAuxiliaryState hasn't yet run.
            return auxiliaryManifestIsValid(aux)
        }
    }

    func auxiliaryModelPath(_ aux: AuxiliaryModel) -> URL? {
        guard auxiliaryManifestIsValid(aux) else { return nil }
        return auxiliaryModelDirectory(aux)
    }

    /// Recompute the auxiliary state on startup based on on-disk manifest.
    /// Mirrors `refreshState()` for the primary backend.
    func refreshAuxiliaryState(_ aux: AuxiliaryModel) {
        if auxiliaryManifestIsValid(aux) {
            auxiliaryStates[aux] = .ready
            auxiliaryStatusMessage[aux] = ""
        } else {
            auxiliaryStates[aux] = .notDownloaded
            auxiliaryStatusMessage[aux] = ""
        }
        auxiliaryProgress[aux] = 0
        auxiliaryDownloadedBytes[aux] = 0
        auxiliarySpeed[aux] = 0
    }

    /// Download an auxiliary model. Shares the listing, curl and verification
    /// steps with the primary download but runs its own subprocess, so the
    /// user can fetch it without interrupting a primary download.
    func downloadAuxiliary(_ aux: AuxiliaryModel) async throws {
        // Guard: already downloading / verifying this aux model.
        switch auxiliaryState(for: aux) {
        case .downloading, .verifying:
            logger.info("downloadAuxiliary(\(aux.rawValue)): already in progress")
            return
        default:
            break
        }

        // Disk space: use the auxiliary's own requirement, not the active backend's.
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        if let free = attrs[.systemFreeSize] as? Int64, free < aux.requiredDiskSpace {
            throw MurmurError.diskFull
        }

        let dir = auxiliaryModelDirectory(aux)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        auxiliaryStates[aux] = .downloading(progress: 0, bytesPerSec: 0)
        auxiliaryProgress[aux] = 0
        auxiliarySpeed[aux] = 0
        auxiliaryDownloadedBytes[aux] = 0
        auxiliaryStatusMessage[aux] = "Preparing download..."

        func fail(_ message: String, state: ModelState? = nil) -> Error {
            auxiliaryStatusMessage[aux] = "Error: \(message)"
            auxiliaryStates[aux] = state ?? .error(String(message.prefix(200)))
            return MurmurError.transcriptionFailed(message)
        }

        let files: [HFDownload.File]
        do {
            files = try await listFiles(
                repo: aux.modelRepo, revision: aux.modelRevision,
                patterns: aux.allowPatterns, required: aux.requiredFiles, into: dir
            )
        } catch {
            throw fail(Self.downloadListingErrorMessage(error))
        }

        let statuses = await Self.localStatuses(of: files, in: dir)
        let plan = HFDownload.plan(for: files, statuses: statuses)
        Self.remove(plan.delete, from: dir)

        if !plan.fetch.isEmpty {
            auxiliaryStatusMessage[aux] = "Downloading..."

            let transfers = plan.fetch.map {
                HFDownload.transfer(for: $0, repo: aux.modelRepo, revision: aux.modelRevision, into: dir)
            }
            let process = downloadEnvironment.makeProcess(HFDownload.curlArguments(for: transfers))

            let monitorTask = Task { @MainActor [weak self] in
                guard let self else { return }
                var lastSize: Int64 = 0
                var samples: [Int64] = []
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { break }
                    let size = self.directorySize(dir)
                    let instant = size - lastSize
                    samples.append(instant)
                    if samples.count > 5 { samples.removeFirst() }
                    let smoothed = samples.reduce(0, +) / Int64(samples.count)
                    self.auxiliarySpeed[aux] = smoothed
                    self.auxiliaryDownloadedBytes[aux] = size
                    self.auxiliaryStates[aux] = .downloading(progress: -1, bytesPerSec: smoothed)
                    self.auxiliaryStatusMessage[aux] = "Downloading: \(size / 1_000_000) MB"
                    lastSize = size
                }
            }
            let (end, stderr) = await run(process)
            monitorTask.cancel()

            if let message = HFDownload.failureMessage(for: end, stderr: stderr) {
                throw fail(message)
            }
        }

        auxiliaryStatusMessage[aux] = "Verifying..."
        auxiliaryStates[aux] = .verifying
        let fetchedStatuses = await Self.localStatuses(of: plan.fetch, in: dir)
        let fetched = HFDownload.plan(for: plan.fetch, statuses: fetchedStatuses)
        Self.remove(fetched.delete, from: dir)

        switch HFDownload.rejection(afterFetch: fetched) {
        case .corrupt(let message):
            throw fail(message, state: .corrupt)
        case .incomplete(let message):
            throw fail(message)
        case nil:
            break
        }

        // Same manifest format as the primary backend.
        do {
            let sha256 = plan.verified.merging(fetched.verified) { $1 }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Self.manifest(named: aux.rawValue, files: files, sha256: sha256))
                .write(to: auxiliaryManifestURL(aux), options: .atomic)
        } catch {
            throw fail("Could not save the model manifest")
        }

        auxiliaryStates[aux] = .ready
        auxiliaryStatusMessage[aux] = "Ready"
    }

    func deleteAuxiliary(_ aux: AuxiliaryModel) throws {
        let dir = auxiliaryModelDirectory(aux)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        auxiliaryStates[aux] = .notDownloaded
        auxiliaryStatusMessage[aux] = ""
        auxiliaryProgress[aux] = 0
        auxiliaryDownloadedBytes[aux] = 0
        logger.info("Auxiliary model deleted: \(aux.rawValue)")
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
    private var auxiliaryDirectoryOverrides: [AuxiliaryModel: URL] = [:]

    func __testing_setAuxiliaryDirectory(_ url: URL, for aux: AuxiliaryModel) {
        assert(
            NSClassFromString("XCTestCase") != nil,
            "__testing_setAuxiliaryDirectory invoked outside XCTest"
        )
        auxiliaryDirectoryOverrides[aux] = url
    }

    func __testing_setAuxiliaryState(_ state: ModelState, for aux: AuxiliaryModel) {
        assert(
            NSClassFromString("XCTestCase") != nil,
            "__testing_setAuxiliaryState invoked outside XCTest"
        )
        auxiliaryStates[aux] = state
    }

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
    /// Replace the listing fetcher, the subprocess factory and the stall
    /// timeout, so tests can run `download()` end to end without a network.
    ///
    /// NEVER call this from non-test code.
    func __testing_setDownloadEnvironment(_ environment: DownloadEnvironment) {
        assert(
            NSClassFromString("XCTestCase") != nil,
            "__testing_setDownloadEnvironment invoked outside XCTest — this is a test seam and must only be called from unit tests"
        )
        downloadEnvironment = environment
    }

    /// True from the launch of `download()`'s subprocess until that
    /// subprocess is cancelled or has ended.
    var __testing_hasActiveDownloadProcess: Bool { activeDownloadProcess != nil }

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

private extension HFDownload.ProcessEnd {
    /// The end of a process that has terminated.
    init(_ process: Process) {
        self = process.terminationReason == .exit
            ? .exit(process.terminationStatus)
            : .signal(process.terminationStatus)
    }
}
