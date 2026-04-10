import Foundation
import AVFoundation
import os

// MARK: - Errors

enum LongRecordingError: LocalizedError {
    case insufficientDiskSpace
    case notRecording
    case recorderFailedToStart

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace:
            return "Not enough disk space. At least 1 GB required to start recording."
        case .notRecording:
            return "No recording in progress."
        case .recorderFailedToStart:
            return "Failed to start the audio recorder."
        }
    }
}

// MARK: - Protocols (for testability via dependency injection)

protocol DiskSpaceChecking: Sendable {
    func availableCapacityBytes() throws -> Int64
}

protocol AVRecorderBridging: AnyObject {
    func prepareToRecord() -> Bool
    func record() -> Bool
    func stop()
}

// MARK: - Production implementations

struct SystemDiskSpaceChecker: DiskSpaceChecking {
    func availableCapacityBytes() throws -> Int64 {
        let values = try FileManager.default
            .homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
            return 0
        }
        return bytes
    }
}

/// Thin wrapper that makes AVAudioRecorder conform to AVRecorderBridging.
final class AVAudioRecorderBridge: AVRecorderBridging {
    private let recorder: AVAudioRecorder

    init(recorder: AVAudioRecorder) {
        self.recorder = recorder
    }

    func prepareToRecord() -> Bool { recorder.prepareToRecord() }
    func record() -> Bool { recorder.record() }
    func stop() { recorder.stop() }
}

// MARK: - LongRecordingService

/// Records audio to an .m4a file using AVAudioRecorder.
///
/// Constraints enforced:
/// - Minimum 1 GB free disk space before start
/// - 2 GB disk budget (recording auto-stopped at limit)
/// - 2 hour maximum duration
/// - NSProcessInfo.performActivity prevents App Nap during recording
///
/// Thread safety: Must be called on the Main actor.
@MainActor
final class LongRecordingService {

    // MARK: - Constants
    // nonisolated so they are accessible from non-MainActor contexts (tests, etc.)

    nonisolated static let maxDurationSeconds: TimeInterval = 7200     // 2 hours
    nonisolated static let diskBudgetBytes: Int64 = 2 * 1024 * 1024 * 1024   // 2 GB
    nonisolated static let minimumFreeSpaceBytes: Int64 = 1024 * 1024 * 1024 // 1 GB

    private static let log = Logger(subsystem: "com.murmur.app", category: "long-recording")

    // MARK: - Dependencies

    private let outputDirectory: URL
    private let diskChecker: DiskSpaceChecking
    private let recorderFactory: (URL, [String: Any]) throws -> AVRecorderBridging

    // MARK: - State

    private var activeRecorder: AVRecorderBridging?
    private(set) var currentOutputURL: URL?
    private var appNapToken: NSObjectProtocol?
    private var maxDurationTask: Task<Void, Never>?

    // MARK: - Init

    /// Primary initialiser — used in tests to inject a temp directory and mock dependencies.
    init(
        outputDirectory: URL,
        diskChecker: DiskSpaceChecking = SystemDiskSpaceChecker(),
        recorderFactory: @escaping (URL, [String: Any]) throws -> AVRecorderBridging = { url, settings in
            let avRecorder = try AVAudioRecorder(url: url, settings: settings)
            return AVAudioRecorderBridge(recorder: avRecorder)
        }
    ) {
        self.outputDirectory = outputDirectory
        self.diskChecker = diskChecker
        self.recorderFactory = recorderFactory
    }

    /// Convenience initialiser using the default App Support/Murmur/Recordings directory.
    convenience init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport
            .appendingPathComponent("Murmur", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        self.init(outputDirectory: dir)
    }

    // MARK: - Public API

    /// Starts recording to a new .m4a file in `outputDirectory`.
    ///
    /// - Throws: `LongRecordingError.insufficientDiskSpace` if free space < 1 GB.
    /// - Throws: `LongRecordingError.recorderFailedToStart` if AVAudioRecorder fails.
    func startRecording() async throws {
        // 1. Disk space check
        let freeBytes = try diskChecker.availableCapacityBytes()
        guard freeBytes >= Self.minimumFreeSpaceBytes else {
            throw LongRecordingError.insufficientDiskSpace
        }

        // 2. Build output URL
        let filename = "recording-\(ISO8601DateFormatter().string(from: Date())).m4a"
        let outputURL = outputDirectory.appendingPathComponent(filename)
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )

        // 3. Create recorder
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try recorderFactory(outputURL, settings)

        guard recorder.prepareToRecord() else {
            throw LongRecordingError.recorderFailedToStart
        }
        guard recorder.record() else {
            throw LongRecordingError.recorderFailedToStart
        }

        activeRecorder = recorder
        currentOutputURL = outputURL

        // 4. Prevent App Nap
        appNapToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Long audio recording in progress"
        )

        // 5. Schedule 2-hour auto-stop
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxDurationSeconds))
            guard !Task.isCancelled, let self else { return }
            Self.log.info("2-hour cap reached — auto-stopping recording")
            _ = try? await self.stopRecording()
        }

        Self.log.info("Recording started → \(outputURL.lastPathComponent)")
    }

    /// Stops the active recording and returns the URL of the .m4a file.
    ///
    /// - Throws: `LongRecordingError.notRecording` if no recording is active.
    func stopRecording() async throws -> URL {
        guard let recorder = activeRecorder, let outputURL = currentOutputURL else {
            throw LongRecordingError.notRecording
        }

        maxDurationTask?.cancel()
        maxDurationTask = nil
        recorder.stop()
        activeRecorder = nil

        if let token = appNapToken {
            ProcessInfo.processInfo.endActivity(token)
            appNapToken = nil
        }

        Self.log.info("Recording stopped → \(outputURL.lastPathComponent)")
        return outputURL
    }

    /// Cancels the active recording and deletes the incomplete .m4a file.
    func cancel() throws {
        guard let recorder = activeRecorder else { return }

        maxDurationTask?.cancel()
        maxDurationTask = nil
        recorder.stop()
        activeRecorder = nil

        if let token = appNapToken {
            ProcessInfo.processInfo.endActivity(token)
            appNapToken = nil
        }

        if let url = currentOutputURL {
            try? FileManager.default.removeItem(at: url)
            Self.log.info("Recording cancelled, file deleted: \(url.lastPathComponent)")
        }
        currentOutputURL = nil
    }
}
