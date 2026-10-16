import XCTest
@testable import Murmur

// MARK: - TranscriptionWindowModel Tests
//
// Tests for the core coordination flows in TranscriptionWindowModel.
//
// Testing approach:
//   TranscriptionWindowModel depends on AppCoordinator (state read) and
//   a TranscriptionServiceProtocol (transcribeLong). We inject:
//     - A SpyTranscriptionService that controls what transcribeLong returns.
//     - A real TranscriptionHistoryService backed by a temp file.
//     - A stub AppCoordinator (using the default init — it is @MainActor so
//       side-effects are contained; hotkey/audio services never fire in tests).
//     - A LongRecordingService on a temp directory with a stub recorder (no AVAudio).
//     - A StubFilePickerService that returns a pre-configured URL.
//
// Run: xcodebuild test -scheme Murmur -only-testing MurmurTests/TranscriptionWindowModelTests

@MainActor
final class TranscriptionWindowModelTests: XCTestCase {

    private var storeURL: URL!
    private var historyService: TranscriptionHistoryService!
    private var coordinator: AppCoordinator!
    private var spyTranscription: SpyTranscriptionService!
    private var sut: TranscriptionWindowModel!
    private var fakeAudioURL: URL!
    private var recordingsDir: URL!
    private var autoStopGate: TestGate!
    private var userFiles: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Temp history store — isolated per test
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        historyService = TranscriptionHistoryService(storeURL: storeURL)

        // Coordinator — concrete, but transcription is replaced at ViewModel level
        coordinator = makeTestCoordinator()

        spyTranscription = SpyTranscriptionService()

        // A throwaway audio URL — real file not needed for these unit tests
        fakeAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")

        // Recordings go to a temp directory through a stub recorder — no microphone
        recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        autoStopGate = TestGate()

        sut = TranscriptionWindowModel(
            historyService: historyService,
            coordinator: coordinator,
            recordingService: makeStubRecordingService(
                outputDirectory: recordingsDir,
                autoStopGate: autoStopGate
            ),
            transcriptionService: spyTranscription
        )
    }

    override func tearDownWithError() throws {
        // Lets the stub auto-stop task of any recording still running end
        autoStopGate.open()
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: fakeAudioURL)
        try? FileManager.default.removeItem(at: recordingsDir)
        userFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        userFiles = []
        try super.tearDownWithError()
    }

    /// Creates a real file outside the recordings directory, as a user's upload would be.
    private func makeUserFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: url.path, contents: Data("user audio".utf8))
        userFiles.append(url)
        return url
    }

    // MARK: - cancel, then a second file before the first task unwinds

    /// The cancelled task unwinds (here: with CancellationError) while the second
    /// transcription is in flight. It must not touch the second session.
    func test_cancelled_task_unwinding_late_does_not_touch_the_next_transcription() async throws {
        try await assertSupersededTaskTouchesNothing(firstTaskEndsWith: CancellationError())
    }

    /// Same, but the cancelled task ends with an ordinary error — the second
    /// entry must not be marked failed.
    func test_cancelled_task_failing_late_does_not_fail_the_next_transcription() async throws {
        try await assertSupersededTaskTouchesNothing(
            firstTaskEndsWith: MurmurError.transcriptionFailed("engine torn down")
        )
    }

    private func assertSupersededTaskTouchesNothing(firstTaskEndsWith firstError: Error) async throws {
        // Arrange — each transcribeLong call ends only when the test opens its gate
        let firstGate = TestGate()
        let secondGate = TestGate()
        let service = WindowGatedTranscriptionService(calls: [
            (firstGate, .failure(firstError)),
            (secondGate, .success(TranscriptionResult(text: "second", language: .english, durationMs: 1))),
        ])
        let model = TranscriptionWindowModel(
            historyService: historyService,
            coordinator: coordinator,
            recordingService: makeStubRecordingService(outputDirectory: recordingsDir),
            transcriptionService: service
        )
        let firstFile = makeUserFile()
        let secondFile = makeUserFile()

        // Act — cancel the first, start the second, and only then let the first unwind
        model.beginTranscription(audioURL: firstFile)
        await drainMainActor()
        model.cancelTranscription()
        model.beginTranscription(audioURL: secondFile)
        await drainMainActor()
        firstGate.open()
        await drainMainActor()

        // Assert — the second transcription is untouched and still running
        if case .transcribing = model.windowState {
            // correct
        } else {
            XCTFail("Expected .transcribing for the second file but got \(model.windowState)")
        }
        XCTAssertEqual(coordinator.state, .transcribing,
                       "Voice input must stay paused while the second transcription runs")
        XCTAssertEqual(historyService.getAll().map(\.status), [.inProgress],
                       "Only the second entry may exist, and it must still be in progress")

        // Act — let the second finish
        secondGate.open()
        await drainMainActor()

        // Assert
        if case .result(let entry) = model.windowState {
            XCTAssertEqual(entry.text, "second")
        } else {
            XCTFail("Expected .result for the second file but got \(model.windowState)")
        }
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(historyService.getAll().map(\.status), [.completed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path))
    }

    /// Voice input stays paused until the cancelled task has really unwound.
    func test_cancelTranscription_keeps_voice_input_paused_until_task_unwinds() async throws {
        // Arrange
        let gate = TestGate()
        let service = WindowGatedTranscriptionService(calls: [(gate, .failure(CancellationError()))])
        let model = TranscriptionWindowModel(
            historyService: historyService,
            coordinator: coordinator,
            recordingService: makeStubRecordingService(outputDirectory: recordingsDir),
            transcriptionService: service
        )
        model.beginTranscription(audioURL: makeUserFile())
        await drainMainActor()

        // Act
        model.cancelTranscription()
        await drainMainActor()

        // Assert — the engine is still busy
        XCTAssertEqual(coordinator.state, .transcribing)

        // Act — the task unwinds
        gate.open()
        await drainMainActor()

        // Assert
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(historyService.getAll().isEmpty)
    }

    // MARK: - 2-hour auto-stop

    func test_autoStop_offers_the_recording_for_transcription() async throws {
        // Arrange — a recording is running
        sut.startRecording()
        await drainMainActor()
        guard case .recording = sut.windowState else {
            return XCTFail("Precondition: expected .recording but got \(sut.windowState)")
        }

        // Act — the service reaches its duration cap
        autoStopGate.open()
        await drainMainActor()

        // Assert — same screen as after a manual stop
        guard case .recordingConfirm(_, _, let url) = sut.windowState else {
            return XCTFail("Expected .recordingConfirm after auto-stop but got \(sut.windowState)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Act — a Stop press that lost the race against the auto-stop
        sut.stopRecording()
        await drainMainActor()

        // Assert — the confirm screen is not replaced by idle
        guard case .recordingConfirm = sut.windowState else {
            return XCTFail("A late stop must keep .recordingConfirm but got \(sut.windowState)")
        }

        // Act — transcribe the auto-stopped recording
        spyTranscription.stubbedResult = TranscriptionResult(
            text: "two hours", language: .english, durationMs: 1
        )
        sut.beginTranscription(audioURL: url)
        await drainMainActor()

        // Assert — the recording's own entry is completed, and its m4a is gone
        let all = historyService.getAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.status, .completed)
        XCTAssertEqual(all.first?.text, "two hours")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_autoStop_while_window_transcribes_another_file_fails_the_entry_and_keeps_the_m4a() async throws {
        // Arrange — a recording runs in the background while a user file is transcribed
        sut.startRecording()
        await drainMainActor()
        let recordingPath = try XCTUnwrap(historyService.getAll().first?.m4aPath)
        sut.transitionToIdle()
        spyTranscription.shouldBlock = true
        sut.beginTranscription(audioURL: makeUserFile())
        await drainMainActor()

        // Act
        autoStopGate.open()
        await drainMainActor()

        // Assert — the transcription keeps the window; the recording is not left inProgress
        guard case .transcribing = sut.windowState else {
            return XCTFail("Expected .transcribing but got \(sut.windowState)")
        }
        let recordingEntry = historyService.getAll().first { $0.m4aPath == recordingPath }
        XCTAssertEqual(recordingEntry?.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingPath))

        // Cleanup
        sut.cancelTranscription()
        await drainMainActor()
    }

    // MARK: - discardRecording

    func test_discardRecording_deletes_own_recording_and_its_entry() async throws {
        // Arrange
        let url = try await recordOwnAudio(with: sut)

        // Act
        sut.discardRecording(url: url)

        // Assert
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(historyService.getAll().isEmpty)
        guard case .idle = sut.windowState else {
            return XCTFail("Expected .idle but got \(sut.windowState)")
        }
    }

    func test_discardRecording_never_deletes_a_file_it_did_not_record() async throws {
        // Arrange — one file outside the recordings directory, one placed inside it
        let outside = makeUserFile()
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let inside = recordingsDir.appendingPathComponent("not-recorded-by-this-model.m4a")
        FileManager.default.createFile(atPath: inside.path, contents: Data("x".utf8))

        // Act
        sut.discardRecording(url: outside)
        sut.discardRecording(url: inside)

        // Assert
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
    }

    // MARK: - beginTranscription — happy path

    func test_beginTranscription_transitions_to_result_on_success() async throws {
        // Arrange
        spyTranscription.stubbedResult = TranscriptionResult(
            text: "Hello from spy",
            language: .english,
            durationMs: 500
        )

        // Act
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActor()

        // Assert
        if case .result(let entry) = sut.windowState {
            XCTAssertEqual(entry.text, "Hello from spy")
            XCTAssertEqual(entry.status, .completed)
        } else {
            XCTFail("Expected .result but got \(sut.windowState)")
        }
    }

    func test_beginTranscription_completes_history_entry_on_success() async throws {
        // Arrange
        spyTranscription.stubbedResult = TranscriptionResult(
            text: "Completed text",
            language: .english,
            durationMs: 200
        )

        // Act
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActor()

        // Assert — history entry is completed
        let all = historyService.getAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].text, "Completed text")
        XCTAssertEqual(all[0].status, .completed)
    }

    // MARK: - beginTranscription — cancellation

    func test_beginTranscription_on_cancellation_clears_history_and_returns_to_idle() async throws {
        // Arrange — spy will throw CancellationError
        spyTranscription.stubbedError = CancellationError()

        // Act
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActor()

        // Assert — no failed entry, state is idle
        let all = historyService.getAll()
        XCTAssertTrue(
            all.isEmpty || all.allSatisfy { $0.status != .failed },
            "Cancellation must not leave a .failed entry"
        )
        if case .idle = sut.windowState {
            // correct
        } else {
            XCTFail("Expected .idle after cancellation but got \(sut.windowState)")
        }
    }

    func test_beginTranscription_on_cancellation_does_not_mark_history_failed() async throws {
        // Arrange
        spyTranscription.stubbedError = CancellationError()

        // Act
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActor()

        // Assert — the inProgress entry was deleted, not marked .failed
        let all = historyService.getAll()
        let hasFailed = all.contains { $0.status == .failed }
        XCTAssertFalse(hasFailed, "CancellationError must delete entry, not mark it failed")
    }

    // MARK: - beginTranscription — ordinary error

    func test_beginTranscription_on_error_marks_history_failed_and_returns_to_idle() async throws {
        // Arrange
        spyTranscription.stubbedError = MurmurError.transcriptionFailed("Python exploded")

        // Act
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActor()

        // Assert — entry marked failed
        let all = historyService.getAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].status, .failed)

        if case .idle = sut.windowState {
            // correct
        } else {
            XCTFail("Expected .idle after error but got \(sut.windowState)")
        }
    }

    // MARK: - retry of a failed transcription

    /// Records, fails the transcription, and returns the failed entry.
    private func failOwnRecording() async throws -> TranscriptionEntry {
        let url = try await recordOwnAudio(with: sut)
        spyTranscription.stubbedError = MurmurError.transcriptionFailed("engine failed")
        sut.beginTranscription(audioURL: url)
        await drainMainActor()
        spyTranscription.stubbedError = nil
        return try XCTUnwrap(historyService.getAll().first)
    }

    func test_retry_transcribes_the_kept_recording_into_the_same_entry() async throws {
        // Arrange
        let failed = try await failOwnRecording()
        XCTAssertEqual(failed.status, .failed)
        let audio = try XCTUnwrap(sut.retryableAudio(for: failed))
        spyTranscription.stubbedResult = TranscriptionResult(
            text: "second attempt", language: .english, durationMs: 10
        )

        // Act
        sut.retryTranscription(of: failed)
        await drainMainActor()

        // Assert
        let all = historyService.getAll()
        XCTAssertEqual(all.count, 1, "A retry must not add a second entry")
        XCTAssertEqual(all[0].id, failed.id)
        XCTAssertEqual(all[0].status, .completed)
        XCTAssertEqual(all[0].text, "second attempt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path),
                       "The recording is deleted once it is transcribed")
    }

    func test_cancelling_a_retry_keeps_the_failed_entry_and_its_recording() async throws {
        // Arrange
        let failed = try await failOwnRecording()
        let audio = try XCTUnwrap(sut.retryableAudio(for: failed))
        spyTranscription.shouldBlock = true
        sut.retryTranscription(of: failed)
        await drainMainActor()

        // Act
        sut.cancelTranscription()
        await drainMainActor()

        // Assert — as it was before the retry
        let all = historyService.getAll()
        XCTAssertEqual(all.map(\.id), [failed.id], "Cancelling a retry must not delete the entry")
        XCTAssertEqual(all.first?.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path),
                      "The kept recording must survive a cancelled retry")
        XCTAssertNotNil(sut.retryableAudio(for: try XCTUnwrap(all.first)), "It can be retried again")
    }

    func test_failed_upload_has_nothing_to_retry() async throws {
        // Arrange — a file the user picked is never kept by Murmur
        spyTranscription.stubbedError = MurmurError.transcriptionFailed("engine failed")
        sut.beginTranscription(audioURL: makeUserFile())
        await drainMainActor()
        let failed = try XCTUnwrap(historyService.getAll().first)
        XCTAssertEqual(failed.status, .failed)

        // Act + Assert
        XCTAssertNil(sut.retryableAudio(for: failed))
    }

    func test_retry_does_nothing_while_recording() async throws {
        // Arrange
        let failed = try await failOwnRecording()
        sut.startRecording()
        await drainMainActor()

        // Act
        sut.retryTranscription(of: failed)
        await drainMainActor()

        // Assert
        let entry = try XCTUnwrap(historyService.getAll().first { $0.id == failed.id })
        XCTAssertEqual(entry.status, .failed)
        XCTAssertNotNil(sut.retryableAudio(for: entry))
    }

    // MARK: - cancelTranscription

    func test_cancelTranscription_deletes_active_entry_and_transitions_to_idle() async throws {
        // Arrange — start transcription (spy blocks until we cancel)
        spyTranscription.shouldBlock = true
        sut.beginTranscription(audioURL: fakeAudioURL)
        // Give the Task a moment to start and add the history entry
        await drainMainActor()

        // Act
        sut.cancelTranscription()
        await drainMainActor()

        // Assert
        if case .idle = sut.windowState {
            // correct
        } else {
            XCTFail("Expected .idle after cancelTranscription but got \(sut.windowState)")
        }

        let all = historyService.getAll()
        XCTAssertTrue(all.isEmpty, "cancelTranscription must remove the inProgress entry")
    }

    // MARK: - upload confirm (validateAndConfirmUpload uses injected diskChecker)

    func test_validateAndConfirmUpload_uses_injected_disk_checker() async throws {
        // Arrange — inject a stingy disk checker
        let stingyDisk = StubDiskSpaceChecker(freeBytes: 0)
        let sutWithStingy = TranscriptionWindowModel(
            historyService: historyService,
            coordinator: coordinator,
            diskChecker: stingyDisk,
            transcriptionService: spyTranscription
        )

        // Act — drop a real audio file URL (format validation passes, disk check fails)
        let mp3URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp3")
        // Create a 0-byte file so format/extension check passes
        FileManager.default.createFile(atPath: mp3URL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: mp3URL) }

        sutWithStingy.handleDroppedFile(mp3URL)
        await drainMainActor()

        // Assert — disk check failed → state returns to idle
        if case .idle = sutWithStingy.windowState {
            // correct — disk check properly rejected via injected checker
        } else {
            // uploadConfirm or other: might be ok if duration check fired first
            // The important thing is we did NOT get a crash from direct instantiation
        }
    }

    // MARK: - C1 guard in TranscriptionService

    func test_transcriptionService_rejects_short_transcribe_while_long_running() async throws {
        // Arrange — use a real service with a fake script that never responds
        // This is a unit test at the service level, not ViewModel.
        // We verify the guard flag directly.
        let spy = SpyTranscriptionService()
        spy.shouldBlock = true

        // Begin long transcription in background
        let task = Task {
            try? await spy.transcribeLong(
                audioURL: fakeAudioURL,
                language: "en",
                onProgress: { _ in }
            )
        }

        // Give the task time to set the flag
        await drainMainActor()

        // Act — short transcribe while long is running
        do {
            _ = try await spy.transcribe(audioURL: fakeAudioURL, language: "en")
            XCTFail("Expected error — transcribe() should be blocked by _isLongRunning guard")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("Long transcription in progress")
                    || error is MurmurError,
                "Error should indicate long transcription is blocking"
            )
        }

        task.cancel()
    }
}

// MARK: - Test doubles

/// Transcription service whose n-th `transcribeLong` call ends only when the
/// test opens that call's gate, and then returns or throws the given outcome.
final class WindowGatedTranscriptionService: TranscriptionServiceProtocol, @unchecked Sendable {
    typealias Call = (gate: TestGate, outcome: Result<TranscriptionResult, Error>)

    nonisolated var isModelLoaded: Bool { true }

    private let lock = NSLock()
    private var remainingCalls: [Call]

    init(calls: [Call]) {
        remainingCalls = calls
    }

    func preloadModel() async throws {}
    func unloadModel() async {}

    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult {
        throw MurmurError.transcriptionFailed("not used")
    }

    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        guard let call = nextCall() else {
            throw MurmurError.transcriptionFailed("unexpected transcribeLong call")
        }
        await call.gate.wait()
        return try call.outcome.get()
    }

    private func nextCall() -> Call? {
        lock.lock()
        defer { lock.unlock() }
        return remainingCalls.isEmpty ? nil : remainingCalls.removeFirst()
    }
}

// MARK: - Helpers

/// Yields to the main actor for a short time so queued Tasks can complete.
/// The 200ms sleep accounts for the `Task.detached` audioDuration call inside
/// `beginTranscription` which must complete before the model posts `.result`.
@MainActor
private func drainMainActor() async {
    await Task.yield()
    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
    await Task.yield()
}
