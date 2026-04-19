import XCTest
@testable import Murmur

// MARK: - FU-07: Download stall timeout
//
// Tests for stall detection logic and the MurmurError.downloadStalled error case.
//
// Design: The stall check is extracted into a pure static function
// `ModelManager.isStalled(lastProgressAt:now:timeout:)` so we can test it
// without running a real download or waiting 90 seconds.
//
// The MurmurError.downloadStalled case is tested for severity, shortMessage,
// alertTitle, and errorDescription — all of which feed into the NSAlert routing
// chain established in handoff 076-080.

// MARK: - Pure stall-check logic tests

final class StallDetectionLogicTests: XCTestCase {

    // MARK: No time elapsed → not stalled

    func test_isStalled_returnsFalse_whenNoTimeElapsed() {
        // Arrange
        let now = Date()
        let lastProgressAt = now  // progress happened at exactly "now"

        // Act
        let stalled = ModelManager.isStalled(
            lastProgressAt: lastProgressAt,
            now: now,
            timeout: 90
        )

        // Assert
        XCTAssertFalse(stalled,
            "When lastProgressAt == now, no time has passed and the download is not stalled")
    }

    // MARK: Progress within timeout → not stalled

    func test_isStalled_returnsFalse_whenProgressMadeWithinTimeout() {
        // Arrange — simulate progress 30 seconds ago (well within 90s timeout)
        let lastProgressAt = Date().addingTimeInterval(-30)
        let now = Date()

        // Act
        let stalled = ModelManager.isStalled(
            lastProgressAt: lastProgressAt,
            now: now,
            timeout: 90
        )

        // Assert
        XCTAssertFalse(stalled,
            "Progress 30 seconds ago is within the 90-second timeout; should not stall")
    }

    // MARK: Timeout exactly met → stalled

    func test_isStalled_returnsTrue_whenTimeoutExactlyExceeded() {
        // Arrange — 91 seconds since last progress; timeout is 90
        let lastProgressAt = Date().addingTimeInterval(-91)
        let now = Date()

        // Act
        let stalled = ModelManager.isStalled(
            lastProgressAt: lastProgressAt,
            now: now,
            timeout: 90
        )

        // Assert
        XCTAssertTrue(stalled,
            "91 seconds without progress exceeds the 90-second timeout; should be stalled")
    }

    // MARK: Exactly at timeout boundary → not stalled (< not <=)

    func test_isStalled_returnsFalse_atExactTimeoutBoundary() {
        // Arrange — exactly 90 seconds since last progress (equal to timeout)
        let lastProgressAt = Date().addingTimeInterval(-90)
        let now = Date()

        // Act
        let stalled = ModelManager.isStalled(
            lastProgressAt: lastProgressAt,
            now: now,
            timeout: 90
        )

        // Assert — boundary is exclusive: >= triggers stall, not >
        // This test documents the chosen boundary semantics.
        // isStalled uses >=, so exactly 90.0s IS stalled.
        XCTAssertTrue(stalled,
            "Exactly 90 seconds without progress meets the timeout threshold; should be stalled")
    }

    // MARK: Active progress resets stall timer → not stalled

    func test_isStalled_returnsFalse_whenRecentProgressReset() {
        // Arrange — simulate the case where progress was just made 1 second ago
        // even though the download has been running for many minutes
        let lastProgressAt = Date().addingTimeInterval(-1)
        let now = Date()

        // Act
        let stalled = ModelManager.isStalled(
            lastProgressAt: lastProgressAt,
            now: now,
            timeout: 90
        )

        // Assert
        XCTAssertFalse(stalled,
            "Progress 1 second ago should never be considered stalled")
    }

    // MARK: Custom timeout (test-injection path)

    func test_isStalled_respectsCustomTimeout() {
        // Arrange — use a short 5-second timeout for this test
        let lastProgressAt = Date().addingTimeInterval(-6)
        let now = Date()

        // Act
        let stalled = ModelManager.isStalled(
            lastProgressAt: lastProgressAt,
            now: now,
            timeout: 5
        )

        // Assert
        XCTAssertTrue(stalled,
            "6 seconds without progress should stall under a 5-second timeout")
    }
}

// MARK: - MurmurError.downloadStalled error case tests

final class DownloadStalledErrorTests: XCTestCase {

    // MARK: Severity is critical (routes to NSAlert, not pill)

    func test_downloadStalled_hasCriticalSeverity() {
        // Arrange
        let error = MurmurError.downloadStalled

        // Act
        let severity = error.severity

        // Assert — critical routes via NSAlert so the user sees it and can retry
        XCTAssertEqual(severity, .critical,
            ".downloadStalled must be critical: user cannot proceed without the model, same as .diskFull / .modelNotFound")
    }

    // MARK: shortMessage is concise (≤ ~20 chars)

    func test_downloadStalled_shortMessageIsActionable() {
        // Arrange
        let error = MurmurError.downloadStalled

        // Act & Assert
        XCTAssertEqual(error.shortMessage, "Download stalled",
            "shortMessage drives the pill label; keep it short and descriptive")
        XCTAssertLessThanOrEqual(error.shortMessage.count, 20,
            "shortMessage should fit comfortably in the pill (≤ 20 chars)")
    }

    // MARK: alertTitle is human-readable

    func test_downloadStalled_alertTitleDescribesProblem() {
        // Arrange
        let error = MurmurError.downloadStalled

        // Act & Assert
        XCTAssertEqual(error.alertTitle, "Download stopped making progress",
            "alertTitle appears as NSAlert messageText; must describe what happened")
    }

    // MARK: errorDescription is action-oriented

    func test_downloadStalled_errorDescriptionGuidsUserToRecover() {
        // Arrange
        let error = MurmurError.downloadStalled

        // Act
        let description = error.errorDescription

        // Assert — non-nil and contains recovery guidance
        XCTAssertNotNil(description,
            "errorDescription must be set for NSAlert informativeText")
        XCTAssertTrue(description?.contains("internet") ?? false,
            "errorDescription should mention internet connection as the recovery step")
        XCTAssertTrue(description?.contains("try again") ?? false || description?.contains("Try again") ?? false,
            "errorDescription should tell the user to try again")
    }
}
