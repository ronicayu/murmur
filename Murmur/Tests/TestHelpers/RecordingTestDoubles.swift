import XCTest
@testable import Murmur

// Test doubles for the recording and file-transcription flows. They live here
// because more than one test file uses them.

final class MockAVRecorderBridge: AVRecorderBridging {
    var didStart = false
    var didStop = false

    func prepareToRecord() -> Bool { true }
    func record() -> Bool {
        didStart = true
        return true
    }
    func stop() {
        didStop = true
    }
}

/// Controllable transcription service for ViewModel tests.
/// Uses @unchecked Sendable + nonisolated(unsafe) properties so @MainActor test
/// methods can configure the stub without actor-isolation errors.
/// Safe because test methods run sequentially on the main actor before any Task
/// that reads these values is created.
final class SpyTranscriptionService: TranscriptionServiceProtocol, @unchecked Sendable {
    nonisolated var isModelLoaded: Bool { true }

    nonisolated(unsafe) var stubbedResult: TranscriptionResult = TranscriptionResult(
        text: "spy result",
        language: .english,
        durationMs: 10
    )
    nonisolated(unsafe) var stubbedError: Error? = nil
    /// When true, transcribeLong suspends until cancelled — used to test cancel paths.
    nonisolated(unsafe) var shouldBlock: Bool = false

    /// The pieces asked for with `transcribePiece`, in order.
    nonisolated(unsafe) var piecesAsked: [Range<Int>] = []

    func preloadModel() async throws {}
    func unloadModel() async {}

    func transcribePiece(audioURL: URL, range: Range<Int>, language: String) async throws -> String {
        if let error = stubbedError { throw error }
        piecesAsked.append(range)
        return "piece \(range.lowerBound)"
    }

    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult {
        if shouldBlock {
            // Surface the C1-guard error — real TranscriptionService throws this
            throw MurmurError.transcriptionFailed("Long transcription in progress")
        }
        if let error = stubbedError { throw error }
        return stubbedResult
    }

    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        if shouldBlock {
            // Suspend until task is cancelled
            try await withTaskCancellationHandler {
                try await Task.sleep(nanoseconds: 10 * NSEC_PER_SEC)
            } onCancel: {}
        }
        if let error = stubbedError { throw error }
        onProgress(TranscriptionProgress(currentChunk: 1, totalChunks: 1, partialText: "partial"))
        return stubbedResult
    }
}

/// DiskSpaceChecking stub that returns a configurable number of free bytes.
final class StubDiskSpaceChecker: DiskSpaceChecking {
    private let freeBytes: Int64
    init(freeBytes: Int64) { self.freeBytes = freeBytes }
    func availableCapacityBytes() throws -> Int64 { freeBytes }
}

/// A gate a test opens by hand, so that asynchronous work ends exactly when
/// the test says — no timers. `wait()` ignores task cancellation on purpose:
/// it models work that keeps running for a while after it was cancelled.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// A LongRecordingService that records into `outputDirectory` through a stub
/// recorder (which writes a small file where AVAudioRecorder would), with
/// plenty of free disk. The duration cap is reached when `autoStopGate` opens;
/// without a gate the real 2-hour sleep applies, i.e. never in a test.
@MainActor
func makeStubRecordingService(
    outputDirectory: URL,
    autoStopGate: TestGate? = nil
) -> LongRecordingService {
    let disk = StubDiskSpaceChecker(freeBytes: 10 * 1024 * 1024 * 1024)
    let factory: (URL, [String: Any]) throws -> AVRecorderBridging = { url, _ in
        FileManager.default.createFile(atPath: url.path, contents: Data("recorded".utf8))
        return MockAVRecorderBridge()
    }
    guard let autoStopGate else {
        return LongRecordingService(
            outputDirectory: outputDirectory, diskChecker: disk, recorderFactory: factory
        )
    }
    return LongRecordingService(
        outputDirectory: outputDirectory,
        diskChecker: disk,
        recorderFactory: factory,
        autoStopSleep: { _ in await autoStopGate.wait() }
    )
}

/// Drives the model's real record → stop flow and returns the recording it
/// offers for transcription. The model must use a stub recording service.
@MainActor
func recordOwnAudio(with model: TranscriptionWindowModel) async throws -> URL {
    model.startRecording()
    await settleMainActor()
    model.stopRecording()
    await settleMainActor()
    guard case .recordingConfirm(_, _, let url) = model.windowState else {
        XCTFail("Expected .recordingConfirm after record → stop but got \(model.windowState)")
        throw CancellationError()
    }
    return url
}

/// Lets Tasks queued on the main actor run. The 200 ms cover the detached
/// audio-duration read that the model does before it changes state.
@MainActor
private func settleMainActor() async {
    await Task.yield()
    try? await Task.sleep(nanoseconds: 200_000_000)
    await Task.yield()
}
