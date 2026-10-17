import XCTest
@testable import Murmur

// Tests for the hold the Transcription window takes on the engine: when a
// file may start, who releases the hold, how a hotkey press is refused under
// it, and the model preload that a recording start no longer cancels.
//
// Everything here runs without a microphone, a model or the real pill.

// MARK: - Test doubles

/// An engine whose `preloadModel` waits for a gate, then records whether its
/// task was cancelled meanwhile.
private final class GatedPreloadEngine: TranscriptionServiceProtocol, @unchecked Sendable {
    let gate = TestGate()
    private let lock = NSLock()
    private var cancelledFlags: [Bool] = []

    /// One entry per finished preload: whether its task was cancelled.
    var preloadsCancelled: [Bool] {
        lock.withLock { cancelledFlags }
    }

    var isModelLoaded: Bool { false }

    func preloadModel() async throws {
        await gate.wait()
        let cancelled = Task.isCancelled
        lock.withLock { cancelledFlags.append(cancelled) }
    }

    func unloadModel() async {}

    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult {
        TranscriptionResult(text: "dictated", language: .english, durationMs: 1)
    }

    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        TranscriptionResult(text: "file", language: .english, durationMs: 1)
    }
}

/// An engine that fits a dictation in between the pieces of a long
/// transcription, as the engine process does.
private final class YieldingEngine: TranscriptionServiceProtocol, @unchecked Sendable {
    var isModelLoaded: Bool { true }
    var yieldsToDictationDuringLongTranscription: Bool { true }
    func preloadModel() async throws {}
    func unloadModel() async {}
    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult {
        TranscriptionResult(text: "dictated", language: .english, durationMs: 1)
    }
    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        TranscriptionResult(text: "file", language: .english, durationMs: 1)
    }
}

/// A shown pill that says voice input is paused for a file. `AppState`'s ==
/// treats all errors as equal, so the case is matched by hand.
private func isVoiceInputPaused(_ call: SpyPillController.ShowCall) -> Bool {
    if case .error(let error) = call.state, case .voiceInputPaused = error { return true }
    return false
}

private func isMicrophoneBusy(_ call: SpyPillController.ShowCall) -> Bool {
    if case .error(let error) = call.state, case .microphoneBusy = error { return true }
    return false
}

// MARK: - Tests

@MainActor
final class CoordinatorHoldTests: XCTestCase {

    override func tearDownWithError() throws {
        for key in ["correctTranscription", "undoAfterTranscription"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try super.tearDownWithError()
    }

    func test_fileTranscriptionMayStart_isTrueOnlyWhenNoDictationUsesTheEngine() {
        let allowed: [AppState] = [
            .idle,
            .error(.transcriptionFailed("")),
            .undoable(text: "x", method: .clipboard),
        ]
        let refused: [AppState] = [
            .recording,
            .streaming(chunkCount: 0),
            .transcribing,
            .injecting,
        ]
        for state in allowed {
            XCTAssertTrue(AppCoordinator.fileTranscriptionMayStart(during: state), "\(state)")
        }
        for state in refused {
            XCTAssertFalse(AppCoordinator.fileTranscriptionMayStart(during: state), "\(state)")
        }
    }

    /// Without the hold, .transcribing belongs to a dictation. Ending a file
    /// transcription must not reset it, and a file must not start under it.
    func test_endWindowTranscription_withoutAHold_leavesADictationsTranscribingAlone() {
        let coordinator = makeTestCoordinator()
        coordinator.forceStateForTesting(.transcribing)

        coordinator.endWindowTranscription()

        XCTAssertEqual(coordinator.state, .transcribing)
        XCTAssertFalse(coordinator.beginWindowTranscription())
        XCTAssertFalse(coordinator.isFileTranscriptionActive)
        coordinator.stop()
    }

    /// A file may start while the last dictation can still be undone. Its
    /// Undo window ends: its timer and its Cmd+Z monitor have nothing left
    /// to act on under the hold.
    func test_beginWindowTranscription_duringTheUndoWindow_takesTheHold() async throws {
        UserDefaults.standard.set(false, forKey: "correctTranscription")
        UserDefaults.standard.set(true, forKey: "undoAfterTranscription")
        let coordinator = makeTestCoordinator()
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("hold-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: wav) }

        // A real dictation, so the Undo window and its timer are open.
        await coordinator.stopAndTranscribeV1ForTesting(wav: wav, lang: "en")
        guard case .undoable = coordinator.state else {
            return XCTFail("Precondition: expected .undoable but got \(coordinator.state)")
        }
        XCTAssertTrue(coordinator.isUndoWindowOpenForTesting, "Precondition: the Undo window is open")

        XCTAssertTrue(coordinator.beginWindowTranscription())
        XCTAssertEqual(coordinator.state, .transcribing)
        XCTAssertTrue(coordinator.isFileTranscriptionActive)
        XCTAssertFalse(coordinator.isUndoWindowOpenForTesting, "The file must end the Undo window")

        coordinator.endWindowTranscription()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.isFileTranscriptionActive)
        coordinator.stop()
    }

    func test_hotkeyPressDuringAFileTranscription_isRefusedAtOnce() async {
        let pill = SpyPillController()
        let coordinator = makeTestCoordinator(pill: pill)
        let preflights = LockedCounter()
        coordinator.startPreflightOverride = {
            preflights.increment()
            return .microphoneBusy
        }
        XCTAssertTrue(coordinator.beginWindowTranscription())

        coordinator.hotkey.handleKeyDown()
        let refused = await pollUntil { pill.showCalls.contains(where: isVoiceInputPaused) }

        XCTAssertTrue(refused, "The pill must say why the press did nothing")
        XCTAssertEqual(preflights.value, 0, "No pre-flight, so no microphone prompt")
        XCTAssertFalse(coordinator.pendingRecording)
        XCTAssertEqual(coordinator.state, .transcribing)

        // The hotkey service was put back in step: the next press is a start,
        // and is refused the same way.
        coordinator.hotkey.handleKeyDown()
        let refusedAgain = await pollUntil { pill.showCalls.filter(isVoiceInputPaused).count == 2 }
        XCTAssertTrue(refusedAgain)
        XCTAssertEqual(preflights.value, 0)

        coordinator.endWindowTranscription()
        coordinator.stop()
    }

    /// The press reached the pre-flight before the file started, for
    /// example while the microphone prompt was open. It must not start a
    /// recording, nor queue one, when the pre-flight returns.
    func test_holdThatBeginsDuringThePreflight_refusesThePress() async {
        let pill = SpyPillController()
        let coordinator = makeTestCoordinator(pill: pill)
        let gate = TestGate()
        let entered = LockedCounter()
        coordinator.startPreflightOverride = {
            entered.increment()
            await gate.wait()
            return nil
        }

        coordinator.hotkey.handleKeyDown()
        let inPreflight = await pollUntil { entered.value == 1 }
        XCTAssertTrue(inPreflight, "Precondition: the press must reach the pre-flight")

        XCTAssertTrue(coordinator.beginWindowTranscription())
        gate.open()
        let refused = await pollUntil { pill.showCalls.contains(where: isVoiceInputPaused) }

        XCTAssertTrue(refused, "The press must be refused once the pre-flight returns")
        XCTAssertFalse(coordinator.pendingRecording)
        XCTAssertEqual(coordinator.state, .transcribing)
        XCTAssertFalse(pill.showCalls.contains { $0.state == .recording }, "No recording may start")

        coordinator.endWindowTranscription()
        coordinator.stop()
    }

    /// The press reached the pre-flight before the file started, and the
    /// pre-flight failed. Under the hold the failure is not shown: an error
    /// state would recover to idle while the file runs. The press is refused
    /// like any other.
    func test_preflightThatFailsAfterTheHoldBegan_refusesThePress_withoutAnError() async {
        let pill = SpyPillController()
        let coordinator = makeTestCoordinator(pill: pill)
        let gate = TestGate()
        let entered = LockedCounter()
        coordinator.startPreflightOverride = {
            entered.increment()
            await gate.wait()
            return .microphoneBusy
        }

        coordinator.hotkey.handleKeyDown()
        let inPreflight = await pollUntil { entered.value == 1 }
        XCTAssertTrue(inPreflight, "Precondition: the press must reach the pre-flight")

        XCTAssertTrue(coordinator.beginWindowTranscription())
        gate.open()
        let refused = await pollUntil { pill.showCalls.contains(where: isVoiceInputPaused) }

        XCTAssertTrue(refused, "The press must be refused once the pre-flight returns")
        XCTAssertFalse(pill.showCalls.contains(where: isMicrophoneBusy), "No error may be shown under the hold")
        XCTAssertEqual(coordinator.state, .transcribing)
        XCTAssertTrue(coordinator.isFileTranscriptionActive)
        XCTAssertFalse(coordinator.pendingRecording)

        coordinator.endWindowTranscription()
        coordinator.stop()
    }

    /// A recording that failed to start leaves its pill for the error
    /// recovery to hide, and the recovery does nothing under the hold. The
    /// file start hides it.
    func test_beginWindowTranscription_afterAnError_hidesThePill() {
        let pill = SpyPillController()
        let coordinator = makeTestCoordinator(pill: pill)
        coordinator.forceStateForTesting(.error(.microphoneBusy))
        pill.reset()

        XCTAssertTrue(coordinator.beginWindowTranscription())

        XCTAssertEqual(pill.hideCalls, [0])
        XCTAssertEqual(coordinator.state, .transcribing)
        coordinator.endWindowTranscription()
        coordinator.stop()
    }

    // MARK: With an engine that gives way between pieces

    /// The file takes the hold but not the state: voice input stays on.
    func test_yieldingEngine_fileLeavesTheStateAndVoiceInputOn() async {
        let pill = SpyPillController()
        let coordinator = makeTestCoordinator(transcription: YieldingEngine(), pill: pill)
        let preflights = LockedCounter()
        coordinator.startPreflightOverride = {
            preflights.increment()
            // Ends the press here, before the microphone.
            return .microphoneBusy
        }

        XCTAssertTrue(coordinator.beginWindowTranscription())
        XCTAssertTrue(coordinator.isFileTranscriptionActive)
        XCTAssertEqual(coordinator.state, .idle, "The menu bar shows dictation states, not the file")

        coordinator.hotkey.handleKeyDown()
        let reachedPreflight = await pollUntil { preflights.value == 1 }
        XCTAssertTrue(reachedPreflight, "A press during the file must go on to start a recording")
        XCTAssertFalse(pill.showCalls.contains(where: isVoiceInputPaused), "Nothing is refused")

        coordinator.endWindowTranscription()
        XCTAssertFalse(coordinator.isFileTranscriptionActive)
        coordinator.stop()
    }

    /// The end of the file leaves a dictation that is being transcribed alone.
    func test_yieldingEngine_endWindowTranscription_leavesADictationsTranscribing() {
        let coordinator = makeTestCoordinator(transcription: YieldingEngine())
        XCTAssertTrue(coordinator.beginWindowTranscription())
        coordinator.forceStateForTesting(.transcribing)

        coordinator.endWindowTranscription()

        XCTAssertEqual(coordinator.state, .transcribing)
        XCTAssertFalse(coordinator.isFileTranscriptionActive)
        coordinator.stop()
    }

    /// A file still waits for a dictation under way: its first piece would
    /// slow the dictation's final pass.
    func test_yieldingEngine_fileDoesNotStartDuringADictation() {
        let coordinator = makeTestCoordinator(transcription: YieldingEngine())
        coordinator.forceStateForTesting(.recording)

        XCTAssertFalse(coordinator.beginWindowTranscription())
        XCTAssertFalse(coordinator.isFileTranscriptionActive)
        coordinator.stop()
    }

    /// No state is left, so nothing of it is cleaned up: an error pill stays
    /// for its own recovery.
    func test_yieldingEngine_fileStartLeavesAnErrorAsItIs() {
        let pill = SpyPillController()
        let coordinator = makeTestCoordinator(transcription: YieldingEngine(), pill: pill)
        coordinator.forceStateForTesting(.error(.microphoneBusy))
        pill.reset()

        XCTAssertTrue(coordinator.beginWindowTranscription())

        XCTAssertEqual(pill.hideCalls, [])
        guard case .error = coordinator.state else {
            return XCTFail("The error must stay, but the state is \(coordinator.state)")
        }
        coordinator.endWindowTranscription()
        coordinator.stop()
    }

    /// Each recording start asks for a preload. A second one must not cancel
    /// the first: with the engine helper, a cancelled request ends the helper.
    func test_preload_isNotCancelledByTheNextRecordingStart() async {
        let engine = GatedPreloadEngine()
        let coordinator = makeTestCoordinator(transcription: engine)

        coordinator.preloadModelInBackground()
        coordinator.preloadModelInBackground()
        engine.gate.open()
        let finished = await pollUntil { engine.preloadsCancelled.count == 2 }

        XCTAssertTrue(finished, "Both preloads must run to the end")
        XCTAssertEqual(engine.preloadsCancelled, [false, false])
        coordinator.stop()
    }
}
