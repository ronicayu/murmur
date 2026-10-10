import XCTest
import AppKit
@testable import Murmur

// Tests for the coordinator-side review fixes: a timeout that really times
// out, delivery of empty transcripts, deletion of the voice recording, the
// hotkey service staying in step with the coordinator, the queued recording,
// sleep handling and the clipboard after a failed paste.
//
// Everything here runs without a microphone, a model or the real clipboard.

// MARK: - Test doubles

/// Blocks its caller until `open()` — and, unlike `Task.sleep`, does not
/// react to task cancellation. Stands in for an audio-engine or model call.
private final class UncancellableGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
    }
}

/// Collects values from any thread.
private final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    var values: [Element] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func append(_ item: Element) {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
    }
}

private final class StubDictationEngine: TranscriptionServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<TranscriptionResult, Error>
    private var unloads = 0

    init(text: String) {
        result = .success(TranscriptionResult(text: text, language: .english, durationMs: 10))
    }

    init(error: Error) {
        result = .failure(error)
    }

    var isModelLoaded: Bool { true }

    var unloadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return unloads
    }

    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult {
        try result.get()
    }

    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        try result.get()
    }

    func preloadModel() async throws {}

    func unloadModel() async {
        lock.lock(); defer { lock.unlock() }
        unloads += 1
    }
}

private struct StubFailure: Error {}

// MARK: - withTimeout

final class WithTimeoutTests: XCTestCase {

    /// The old task-group version waited for the body before it reported the
    /// timeout, so with a body that ignores cancellation it never timed out.
    func test_timesOut_whileBodyIsStillRunning_andReportsTheLateResult() async {
        let gate = UncancellableGate()
        let late = LockedList<Int>()

        do {
            _ = try await withTimeout(seconds: 0.05, operation: "stuck call", onLateCompletion: { result in
                if case .success(let value) = result { late.append(value) }
            }) { () async throws -> Int in
                await gate.wait()
                return 7
            }
            XCTFail("The body is still blocked, so only a timeout can end the call")
        } catch MurmurError.timeout(let operation) {
            XCTAssertEqual(operation, "stuck call")
        } catch {
            XCTFail("Expected a timeout, got \(error)")
        }
        XCTAssertTrue(late.values.isEmpty, "The body has not finished yet")

        gate.open()
        let reported = await pollUntil { late.values == [7] }
        XCTAssertTrue(reported, "The body's eventual result must reach onLateCompletion")
    }

    func test_returnsTheBodyValue_withoutLateCompletion() async throws {
        let late = LockedList<Int>()
        let value = try await withTimeout(seconds: 30, operation: "fast call", onLateCompletion: { _ in
            late.append(1)
        }) { 42 }

        XCTAssertEqual(value, 42)
        XCTAssertTrue(late.values.isEmpty)
    }

    func test_rethrowsTheBodyError() async {
        do {
            _ = try await withTimeout(seconds: 30, operation: "failing call") { () async throws -> Int in
                throw StubFailure()
            }
            XCTFail("Expected the body's error")
        } catch is StubFailure {
            // expected
        } catch {
            XCTFail("Expected StubFailure, got \(error)")
        }
    }
}

// MARK: - Delivery (real pipeline, paste replaced)

final class CoordinatorDeliveryTests: XCTestCase {

    private var pill: SpyPillController!
    private var wav: URL!

    override func setUp() {
        super.setUp()
        pill = SpyPillController()
        wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-fix-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data([0]))
        for key in ["cleanupTranscription", "correctTranscription", "undoAfterTranscription"] {
            UserDefaults.standard.set(false, forKey: key)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: wav)
        for key in ["cleanupTranscription", "correctTranscription", "undoAfterTranscription"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        pill = nil
        wav = nil
        super.tearDown()
    }

    @MainActor
    func test_text_isPastedOnce_andRecordedInHistory() async {
        let coordinator = AppCoordinator(transcription: StubDictationEngine(text: "hello world"), pill: pill)
        let pasted = LockedList<String>()

        await coordinator.stopAndTranscribeV1ForTesting(wav: wav, lang: "en") { text in
            pasted.append(text)
            return .clipboard
        }

        XCTAssertEqual(pasted.values, ["hello world"])
        XCTAssertEqual(coordinator.lastTranscription, "hello world")
        XCTAssertEqual(coordinator.transcriptionHistory.map(\.text), ["hello world"])
        XCTAssertTrue(pill.showCalls.contains { $0.state == .injecting })
    }

    @MainActor
    func test_emptyTranscript_isNotPasted_andNotRecorded() async {
        let coordinator = AppCoordinator(transcription: StubDictationEngine(text: " \n"), pill: pill)
        let pasted = LockedList<String>()

        await coordinator.stopAndTranscribeV1ForTesting(wav: wav, lang: "en") { text in
            pasted.append(text)
            return .clipboard
        }

        XCTAssertTrue(pasted.values.isEmpty, "An empty paste would replace the user's selection with nothing")
        XCTAssertNil(coordinator.lastTranscription)
        XCTAssertTrue(coordinator.transcriptionHistory.isEmpty, "Recent must not get an empty entry")
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(pill.showCalls.contains { $0.state == .injecting }, "Nothing was inserted")
    }

    @MainActor
    func test_failedPaste_entersErrorState_andRecordsNothing() async {
        let coordinator = AppCoordinator(transcription: StubDictationEngine(text: "hello world"), pill: pill)

        await coordinator.stopAndTranscribeV1ForTesting(wav: wav, lang: "en") { _ in
            throw MurmurError.injectionFailed("no target")
        }

        XCTAssertEqual(coordinator.state, .error(.injectionFailed("")))
        XCTAssertTrue(coordinator.transcriptionHistory.isEmpty)
    }

    @MainActor
    func test_recording_isDeleted_afterSuccessfulTranscription() async {
        let coordinator = AppCoordinator(transcription: StubDictationEngine(text: "hello world"), pill: pill)

        await coordinator.stopAndTranscribeV1ForTesting(wav: wav, lang: "en")

        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path),
            "The recording of the user's voice must not stay in the temp directory")
    }

    @MainActor
    func test_recording_isDeleted_afterFailedTranscription() async {
        let coordinator = AppCoordinator(
            transcription: StubDictationEngine(error: MurmurError.transcriptionFailed("boom")),
            pill: pill
        )

        await coordinator.stopAndTranscribeV1ForTesting(wav: wav, lang: "en")

        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertEqual(coordinator.state, .error(.transcriptionFailed("")))
    }
}

// MARK: - Hotkey service in step with the coordinator

@MainActor
final class CoordinatorHotkeySyncTests: XCTestCase {

    /// The hotkey service counts a key press as a recording before the
    /// coordinator decides. When the coordinator refuses to start, the next
    /// press must be another start, not a swallowed "stop".
    func test_refusedStart_leavesTheNextPressAStart() async {
        let coordinator = AppCoordinator(transcription: StubDictationEngine(text: ""), pill: SpyPillController())
        let attempts = LockedCounter()
        coordinator.startPreflightOverride = {
            attempts.increment()
            return .microphoneBusy
        }

        coordinator.hotkey.handleKeyDown()
        let first = await pollUntil { attempts.value == 1 }
        XCTAssertTrue(first, "The first press must reach the start pre-flight")

        coordinator.hotkey.handleKeyDown()
        let second = await pollUntil { attempts.value == 2 }
        XCTAssertTrue(second, "The press after a refused start must be a start again")

        coordinator.stop()
    }

    /// A press during a file transcription queues a recording. Ending the file
    /// transcription must drop it, or the microphone opens by itself after
    /// the next, unrelated dictation.
    func test_endWindowTranscription_dropsTheQueuedRecording() async {
        let coordinator = AppCoordinator(transcription: StubDictationEngine(text: ""), pill: SpyPillController())
        let attempts = LockedCounter()
        coordinator.startPreflightOverride = {
            attempts.increment()
            // First press: allowed, and queued behind the file transcription.
            // Later presses: refused, so the test never opens the microphone.
            return attempts.value == 1 ? nil : .microphoneBusy
        }

        coordinator.beginWindowTranscription()
        coordinator.hotkey.handleKeyDown()
        let queued = await pollUntil { coordinator.pendingRecording }
        XCTAssertTrue(queued, "A press during a file transcription queues a recording")

        coordinator.endWindowTranscription()
        XCTAssertFalse(coordinator.pendingRecording)
        XCTAssertEqual(coordinator.state, .idle)

        coordinator.hotkey.handleKeyDown()
        let startedAgain = await pollUntil { attempts.value == 2 }
        XCTAssertTrue(startedAgain, "The hotkey must be back in step: the next press is a start")

        coordinator.stop()
    }

    func test_stopEvent_takesBackTheQueuedRecording() async {
        let coordinator = AppCoordinator(transcription: StubDictationEngine(text: ""), pill: SpyPillController())
        coordinator.startPreflightOverride = { nil }

        coordinator.beginWindowTranscription()
        coordinator.hotkey.emit(.startRecording)
        let queued = await pollUntil { coordinator.pendingRecording }
        XCTAssertTrue(queued)

        coordinator.hotkey.emit(.stopRecording)
        let takenBack = await pollUntil { !coordinator.pendingRecording }
        XCTAssertTrue(takenBack, "Releasing or pressing the hotkey again must cancel the queued recording")

        coordinator.endWindowTranscription()
        coordinator.stop()
    }
}

// MARK: - Sleep

@MainActor
final class CoordinatorSleepTests: XCTestCase {

    /// `NSWorkspace.willSleepNotification` is posted on the workspace's own
    /// notification center only; an observer on the default center never runs.
    func test_modelIsUnloaded_whenTheWorkspaceAnnouncesSleep() async {
        let engine = StubDictationEngine(text: "")
        let coordinator = AppCoordinator(transcription: engine, pill: SpyPillController())

        // The coordinator registers its observers on the next main-actor
        // turn, so keep announcing until one of them has run.
        let unloaded = await pollUntil {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            return engine.unloadCount > 0
        }

        XCTAssertTrue(unloaded)
        coordinator.stop()
    }
}

// MARK: - Clipboard after a failed paste

final class ClipboardInjectionTests: XCTestCase {

    func test_failedPaste_putsTheUsersClipboardBack() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("the user's clipboard", forType: .string)

        do {
            try await TextInjectionService().injectViaClipboard(
                text: "dictated text",
                pasteboard: pasteboard,
                postPaste: { throw StubFailure() }
            )
            XCTFail("Expected the paste failure to be rethrown")
        } catch {
            XCTAssertTrue(error is StubFailure)
        }

        XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard")
    }

    func test_postedPaste_leavesTheTextOnTheClipboardForTheTargetApp() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("the user's clipboard", forType: .string)

        try await TextInjectionService().injectViaClipboard(
            text: "dictated text",
            pasteboard: pasteboard,
            postPaste: {}
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "dictated text")
    }
}
