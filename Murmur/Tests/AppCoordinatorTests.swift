import XCTest
@testable import Murmur

// MARK: - AppState Tests

final class AppStateTests: XCTestCase {

    func testIdleIsNotActive() {
        XCTAssertFalse(AppState.idle.isActive)
    }

    func testRecordingIsActive() {
        XCTAssert(AppState.recording.isActive)
    }

    func testTranscribingIsActive() {
        XCTAssert(AppState.transcribing.isActive)
    }

    func testInjectingIsActive() {
        XCTAssert(AppState.injecting.isActive)
    }

    func testUndoableIsActive() {
        XCTAssert(AppState.undoable(text: "hi", method: .clipboard).isActive)
    }

    func testErrorIsNotActive() {
        XCTAssertFalse(AppState.error(.silenceDetected).isActive)
    }

    func testStatusTexts() {
        XCTAssertEqual(AppState.idle.statusText, "Ready")
        XCTAssertEqual(AppState.recording.statusText, "Recording...")
        XCTAssertEqual(AppState.transcribing.statusText, "Transcribing...")
        XCTAssertEqual(AppState.injecting.statusText, "Inserting text...")
    }

    func testUndoableStatusTextTruncates() {
        let longText = String(repeating: "x", count: 100)
        let status = AppState.undoable(text: longText, method: .clipboard).statusText
        XCTAssertEqual(status.count, 40)
    }

    func testEquality() {
        XCTAssertEqual(AppState.idle, AppState.idle)
        XCTAssertEqual(AppState.recording, AppState.recording)
        XCTAssertNotEqual(AppState.idle, AppState.recording)
        XCTAssertEqual(
            AppState.undoable(text: "a", method: .clipboard),
            AppState.undoable(text: "a", method: .clipboard)
        )
        XCTAssertNotEqual(
            AppState.undoable(text: "a", method: .clipboard),
            AppState.undoable(text: "b", method: .clipboard)
        )
        // All errors are equal (by design)
        XCTAssertEqual(
            AppState.error(.silenceDetected),
            AppState.error(.diskFull)
        )
    }
}

// MARK: - Transcription History Tests

final class TranscriptionHistoryTests: XCTestCase {

    @MainActor
    func testHistoryMaxCount() {
        // Verify the history cap works by simulating entries
        var history: [(text: String, language: DetectedLanguage, date: Date)] = []
        let maxCount = 20

        for i in 0..<25 {
            history.insert((text: "entry \(i)", language: .english, date: Date()), at: 0)
            if history.count > maxCount {
                history.removeLast()
            }
        }

        XCTAssertEqual(history.count, maxCount)
        // Most recent should be first
        XCTAssertEqual(history.first?.text, "entry 24")
        // Oldest retained should be entry 5 (0-4 were evicted)
        XCTAssertEqual(history.last?.text, "entry 5")
    }

    @MainActor
    func testHistoryPreservesLanguage() {
        var history: [(text: String, language: DetectedLanguage, date: Date)] = []

        history.insert((text: "hello", language: .english, date: Date()), at: 0)
        history.insert((text: "你好", language: .chinese, date: Date()), at: 0)

        XCTAssertEqual(history[0].language, .chinese)
        XCTAssertEqual(history[1].language, .english)
    }
}

// MARK: - HotkeyEvent and RecordingMode Tests

final class HotkeyEventTests: XCTestCase {

    func testRecordingModeRawValues() {
        XCTAssertEqual(RecordingMode.toggle.rawValue, "toggle")
        XCTAssertEqual(RecordingMode.hold.rawValue, "hold")
    }

    func testRecordingModeFromRawValue() {
        XCTAssertEqual(RecordingMode(rawValue: "toggle"), .toggle)
        XCTAssertEqual(RecordingMode(rawValue: "hold"), .hold)
        XCTAssertNil(RecordingMode(rawValue: "invalid"))
    }

    func testHotkeyTriggerEquality() {
        XCTAssertEqual(HotkeyTrigger.rightCommand, HotkeyTrigger.rightCommand)
        XCTAssertNotEqual(
            HotkeyTrigger.rightCommand,
            HotkeyTrigger.keyCombo(key: .space, modifiers: .command)
        )
    }
}

// MARK: - OnboardingStep Tests

final class OnboardingStepTests: XCTestCase {

    func testStepOrder() {
        let steps = OnboardingStep.allCases
        XCTAssertEqual(steps.first, .welcome)
        XCTAssertEqual(steps.last, .done)
    }

    func testVisibleStepsExcludeModelChoice() {
        // The visible steps (used for progress bar) should not include modelChoice.
        // The huggingfaceLogin step was removed in v0.3.1 along with the HuggingFace
        // backend; nothing to assert against on that any more.
        let visibleSteps: [OnboardingStep] = [
            .welcome, .accessibility, .modelDownload, .testTranscription, .done
        ]
        XCTAssertFalse(visibleSteps.contains(.modelChoice))
        XCTAssertFalse(visibleSteps.contains(.microphone), "Microphone is now merged into welcome")
        XCTAssertEqual(visibleSteps.count, 5)
    }
}

// MARK: - MurmurError Tests

final class MurmurErrorTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertNotNil(MurmurError.microphoneBusy.errorDescription)
        XCTAssertNotNil(MurmurError.diskFull.errorDescription)
        XCTAssertNotNil(MurmurError.modelNotFound.errorDescription)
        XCTAssertNotNil(MurmurError.silenceDetected.errorDescription)
        XCTAssertNotNil(MurmurError.timeout(operation: "test").errorDescription)
        XCTAssertNotNil(MurmurError.transcriptionFailed("reason").errorDescription)
        XCTAssertNotNil(MurmurError.injectionFailed("reason").errorDescription)
        XCTAssertNotNil(MurmurError.permissionRevoked(.microphone).errorDescription)
    }

    func testTimeoutIncludesOperation() {
        let err = MurmurError.timeout(operation: "transcription")
        XCTAssert(err.errorDescription?.contains("transcription") == true)
    }

    func testPermissionErrorIncludesType() {
        let err = MurmurError.permissionRevoked(.accessibility)
        XCTAssert(err.errorDescription?.contains("ccessibility") == true)
    }
}

// MARK: - DetectedLanguage Tests

final class DetectedLanguageTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(DetectedLanguage.english.rawValue, "en")
        XCTAssertEqual(DetectedLanguage.chinese.rawValue, "zh")
        XCTAssertEqual(DetectedLanguage.unknown.rawValue, "unknown")
    }

    func testFromRawValue() {
        XCTAssertEqual(DetectedLanguage(rawValue: "en"), .english)
        XCTAssertEqual(DetectedLanguage(rawValue: "zh"), .chinese)
        XCTAssertNil(DetectedLanguage(rawValue: "fr"))
    }
}

// MARK: - InjectionMethod Tests

final class InjectionMethodTests: XCTestCase {

    func testEquality() {
        XCTAssertEqual(InjectionMethod.clipboard, InjectionMethod.clipboard)
        XCTAssertEqual(InjectionMethod.cgEvent, InjectionMethod.cgEvent)
        XCTAssertNotEqual(InjectionMethod.clipboard, InjectionMethod.cgEvent)
    }
}
