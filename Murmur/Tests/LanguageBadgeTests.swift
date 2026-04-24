import XCTest
@testable import Murmur

final class LanguageBadgeTests: XCTestCase {

    // MARK: - LanguageBadge.format(code:isAuto:)

    func test_format_fixedKnownCode_returnsUppercaseOnly() {
        XCTAssertEqual(LanguageBadge.format(code: "en", isAuto: false), "EN")
        XCTAssertEqual(LanguageBadge.format(code: "zh", isAuto: false), "ZH")
        XCTAssertEqual(LanguageBadge.format(code: "ja", isAuto: false), "JA")
        XCTAssertEqual(LanguageBadge.format(code: "ko", isAuto: false), "KO")
        XCTAssertEqual(LanguageBadge.format(code: "ar", isAuto: false), "AR")
    }

    func test_format_autoKnownCode_returnsUppercaseWithMiddleDot() {
        XCTAssertEqual(LanguageBadge.format(code: "en", isAuto: true), "EN·")
        XCTAssertEqual(LanguageBadge.format(code: "zh", isAuto: true), "ZH·")
        XCTAssertEqual(LanguageBadge.format(code: "ja", isAuto: true), "JA·")
    }

    func test_format_unknownCode_returnsQuestionMarks() {
        XCTAssertEqual(LanguageBadge.format(code: "xx", isAuto: false), "??")
    }

    func test_format_unknownCodeAutoMode_returnsQuestionMarksWithDot() {
        XCTAssertEqual(LanguageBadge.format(code: "xx", isAuto: true), "??·")
    }

    func test_format_allSupportedCodesAreRecognized() {
        let supported = ["en", "zh", "ja", "ko", "fr", "de", "es", "pt", "it", "nl", "pl", "el", "ar", "vi"]
        for code in supported {
            let result = LanguageBadge.format(code: code, isAuto: false)
            XCTAssertNotEqual(result, "??", "Expected \(code) to be a recognized code")
        }
    }

    // MARK: - LanguageBadge.badgeText(resolvedCode:storedSetting:)

    func test_badgeText_fixedLanguage_noAutoSuffix() {
        // stored = "en" (fixed) → isAuto = false → no dot
        let result = LanguageBadge.badgeText(resolvedCode: "en", storedSetting: "en")
        XCTAssertEqual(result, "EN")
    }

    func test_badgeText_autoSetting_hasDotSuffix() {
        // stored = "auto" → isAuto = true → dot
        let result = LanguageBadge.badgeText(resolvedCode: "en", storedSetting: "auto")
        XCTAssertEqual(result, "EN·")
    }

    func test_badgeText_autoSettingZh_returnsZhDot() {
        let result = LanguageBadge.badgeText(resolvedCode: "zh", storedSetting: "auto")
        XCTAssertEqual(result, "ZH·")
    }

    func test_badgeText_autoSettingUnknownCode_returnsQuestionMarksDot() {
        let result = LanguageBadge.badgeText(resolvedCode: "xx", storedSetting: "auto")
        XCTAssertEqual(result, "??·")
    }

    // MARK: - FloatingPillView.isRecordingState guard

    func test_isRecordingState_trueForRecordingAndStreaming() {
        // Arrange & Act
        let recordingView = FloatingPillView(state: .recording, audioLevel: 0, languageBadge: "EN")
        let streamingView = FloatingPillView(state: .streaming(chunkCount: 3), audioLevel: 0, languageBadge: "ZH·")
        // Assert
        XCTAssertTrue(recordingView.isRecordingState)
        XCTAssertTrue(streamingView.isRecordingState)
    }

    func test_isRecordingState_falseForAllNonRecordingStates() {
        // Arrange
        let states: [AppState] = [
            .idle,
            .transcribing,
            .injecting,
            .undoable(text: "hello", method: .clipboard),
            .error(.silenceDetected),
        ]
        // Act & Assert
        for state in states {
            let view = FloatingPillView(state: state, audioLevel: 0, languageBadge: "EN")
            XCTAssertFalse(view.isRecordingState, "Expected isRecordingState == false for state \(state)")
        }
    }

    // MARK: - FloatingPillView.isLanguageBadgeVisible (UT #3 / CR NC-2 fix)

    /// Badge must be visible during recording, streaming, AND transcribing so
    /// the LID-updated badge remains on-screen while Cohere processes the audio.
    func test_isLanguageBadgeVisible_trueForRecordingStreamingAndTranscribing() {
        // Arrange & Act
        let recording = FloatingPillView(state: .recording, audioLevel: 0, languageBadge: "EN")
        let streaming = FloatingPillView(state: .streaming(chunkCount: 1), audioLevel: 0, languageBadge: "ZH·")
        let transcribing = FloatingPillView(state: .transcribing, audioLevel: 0, languageBadge: "ZH·")

        // Assert
        XCTAssertTrue(recording.isLanguageBadgeVisible,
                      ".recording must show the language badge")
        XCTAssertTrue(streaming.isLanguageBadgeVisible,
                      ".streaming must show the language badge")
        XCTAssertTrue(transcribing.isLanguageBadgeVisible,
                      ".transcribing must show the language badge (LID override is visible during transcription)")
    }

    func test_isLanguageBadgeVisible_falseForNonActiveStates() {
        // Arrange
        let states: [AppState] = [
            .idle,
            .injecting,
            .undoable(text: "hi", method: .clipboard),
            .error(.silenceDetected),
        ]
        // Act & Assert
        for state in states {
            let view = FloatingPillView(state: state, audioLevel: 0, languageBadge: "EN")
            XCTAssertFalse(view.isLanguageBadgeVisible,
                           "Expected isLanguageBadgeVisible == false for state \(state)")
        }
    }
}
