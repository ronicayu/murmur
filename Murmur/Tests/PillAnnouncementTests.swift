import XCTest
@testable import Murmur

final class PillAnnouncementTests: XCTestCase {

    func test_nothingIsSaid_whileTheMicrophoneIsOpen() {
        XCTAssertNil(FloatingPillController.announcement(for: .recording))
        XCTAssertNil(FloatingPillController.announcement(for: .streaming(chunkCount: 3)))
    }

    func test_nothingIsSaid_forIdleOrTheShortInsertingStep() {
        XCTAssertNil(FloatingPillController.announcement(for: .idle))
        XCTAssertNil(FloatingPillController.announcement(for: .injecting))
    }

    func test_theEndOfADictation_isSaid() {
        XCTAssertEqual(FloatingPillController.announcement(for: .transcribing), "Transcribing")
        XCTAssertEqual(
            FloatingPillController.announcement(for: .undoable(text: "hello", method: .clipboard)),
            "Inserted"
        )
    }

    func test_anError_isSaidWithItsMessage() throws {
        let text = try XCTUnwrap(FloatingPillController.announcement(for: .error(.diskFull)))

        XCTAssertTrue(text.hasPrefix("Error: "))
        XCTAssertTrue(text.contains(MurmurError.diskFull.shortMessage))
    }

    // MARK: - Menu-bar item name

    func test_menuBarName_saysTheStateTheIconShows() {
        XCTAssertEqual(AppState.idle.menuBarAccessibilityName, "Murmur")
        XCTAssertEqual(AppState.recording.menuBarAccessibilityName, "Murmur, recording")
        XCTAssertEqual(AppState.streaming(chunkCount: 2).menuBarAccessibilityName, "Murmur, recording")
        XCTAssertEqual(AppState.transcribing.menuBarAccessibilityName, "Murmur, transcribing")
        XCTAssertEqual(AppState.injecting.menuBarAccessibilityName, "Murmur, inserting text")
        XCTAssertEqual(
            AppState.error(.diskFull).menuBarAccessibilityName,
            "Murmur, error: \(MurmurError.diskFull.shortMessage)"
        )
    }

    func test_menuBarName_doesNotReadOutTheInsertedText() {
        let state = AppState.undoable(text: "a private sentence", method: .clipboard)
        XCTAssertEqual(state.menuBarAccessibilityName, "Murmur")
    }
}
