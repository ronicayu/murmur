import XCTest
@testable import Murmur

final class MicrophoneModeTests: XCTestCase {

    func test_offeredOncePerVersion_whileVoiceIsolationIsOff() {
        XCTAssertTrue(MicrophoneMode.shouldOffer(
            isVoiceIsolationOn: false, remindersOn: true, remindedVersion: nil, currentVersion: "0.5.2"))
        XCTAssertTrue(MicrophoneMode.shouldOffer(
            isVoiceIsolationOn: false, remindersOn: true, remindedVersion: "0.5.1", currentVersion: "0.5.2"),
            "An update resets the mode, so it is offered again")
        XCTAssertFalse(MicrophoneMode.shouldOffer(
            isVoiceIsolationOn: false, remindersOn: true, remindedVersion: "0.5.2", currentVersion: "0.5.2"),
            "Not again for the same version: the user may prefer Standard")
    }

    func test_notOffered_whenOnOrWhenTheUserTurnedTheReminderOff() {
        XCTAssertFalse(MicrophoneMode.shouldOffer(
            isVoiceIsolationOn: true, remindersOn: true, remindedVersion: nil, currentVersion: "0.5.2"))
        XCTAssertFalse(MicrophoneMode.shouldOffer(
            isVoiceIsolationOn: false, remindersOn: false, remindedVersion: nil, currentVersion: "0.5.2"))
    }
}
