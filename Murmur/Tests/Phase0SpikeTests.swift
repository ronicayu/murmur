import XCTest
import AppKit

// MARK: - Phase 0 Spike — Swift Tests #8 and #9
//
// Test 8: activationPolicy switching (.accessory <-> .regular)
// Test 9: App Nap prevention via NSProcessInfo.performActivity
//
// These tests are informal validation — they verify the macOS API surface
// behaves as expected. They do NOT require the full Murmur target to compile.
// Run with: xcodebuild test -scheme Murmur -only-testing MurmurTests/Phase0SpikeTests

final class Phase0SpikeTests: XCTestCase {

    // MARK: - Test 8: activationPolicy switching

    /// Verify NSApplication can switch from .accessory to .regular without crashing.
    /// Exit criteria: no exception thrown; policy is .regular after the call.
    func test_activationPolicy_switchToRegular_succeeds() {
        // Arrange
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()

        // Act
        let switched = app.setActivationPolicy(.regular)

        // Assert — API must not crash and must report the policy as accepted.
        // setActivationPolicy returns true if the change took effect.
        XCTAssertTrue(switched, "setActivationPolicy(.regular) must return true")
        XCTAssertEqual(app.activationPolicy(), .regular,
                       "activationPolicy must be .regular after switching")

        // Cleanup — restore so other tests are not affected
        app.setActivationPolicy(originalPolicy)
    }

    /// Verify NSApplication can switch from .regular back to .accessory.
    /// Exit criteria: policy is .accessory; Dock icon must disappear (not testable here,
    /// but the API call must succeed without throwing).
    func test_activationPolicy_switchToAccessory_succeeds() {
        // Arrange
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        defer { app.setActivationPolicy(originalPolicy) }  // always restore

        _ = app.setActivationPolicy(.regular)  // start from known state

        // Act
        let switched = app.setActivationPolicy(.accessory)

        // Assert
        XCTAssertTrue(switched, "setActivationPolicy(.accessory) must return true")
        XCTAssertEqual(app.activationPolicy(), .accessory,
                       "activationPolicy must be .accessory after switching")
    }

    /// Round-trip: .accessory -> .regular -> .accessory stays coherent.
    /// Validates the strategy used by AppCoordinator for window show/hide.
    func test_activationPolicy_roundTrip_remainsCoherent() {
        // Arrange
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        defer { app.setActivationPolicy(originalPolicy) }  // always restore even if assertions fail

        // Act
        _ = app.setActivationPolicy(.accessory)
        let afterAccessory = app.activationPolicy()

        _ = app.setActivationPolicy(.regular)
        let afterRegular = app.activationPolicy()

        _ = app.setActivationPolicy(.accessory)
        let afterReturnToAccessory = app.activationPolicy()

        // Assert
        XCTAssertEqual(afterAccessory, .accessory)
        XCTAssertEqual(afterRegular, .regular)
        XCTAssertEqual(afterReturnToAccessory, .accessory)
        // defer handles cleanup
    }

    /// Verify that .prohibited policy is rejected (macOS does not allow LSUIElement apps
    /// to use .prohibited from a standard XCTest host process, but the API must not crash).
    func test_activationPolicy_switchToProhibited_doesNotCrash() {
        // Arrange / Act / Assert — just verify no crash
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()

        _ = app.setActivationPolicy(.prohibited)
        // No assertion on success — .prohibited behaviour is context-dependent

        // Cleanup
        app.setActivationPolicy(originalPolicy)
    }

    // MARK: - Test 9: App Nap prevention via NSProcessInfo.performActivity

    /// Verify NSProcessInfo.performActivity(_:reason:using:) can be invoked with
    /// .userInitiated | .idleSystemSleepDisabled without throwing.
    /// Exit criteria: block executes; no exception.
    func test_appNap_performActivity_userInitiated_executesBlock() {
        // Arrange
        let processInfo = ProcessInfo.processInfo
        var blockExecuted = false
        let expectation = self.expectation(description: "Activity block executed")

        // Act
        let options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
        processInfo.performActivity(options: options, reason: "Phase0 spike test") {
            blockExecuted = true
            expectation.fulfill()
        }

        // Assert
        wait(for: [expectation], timeout: 5.0)
        XCTAssertTrue(blockExecuted, "performActivity block must execute")
    }

    /// Verify that beginActivity / endActivity token lifecycle does not crash.
    /// This is the pattern Murmur will use for long transcription sessions.
    func test_appNap_beginEndActivity_tokenLifecycle_doesNotCrash() {
        // Arrange
        let processInfo = ProcessInfo.processInfo

        // Act
        let options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
        let token = processInfo.beginActivity(options: options, reason: "Phase0 transcription session")

        // Assert — token must be non-nil (NSObject)
        XCTAssertNotNil(token, "beginActivity must return a non-nil token")

        // End activity — must not crash
        processInfo.endActivity(token)
    }

    /// Verify .background option (lower priority) also works for background transcription.
    func test_appNap_performActivity_background_executesBlock() {
        // Arrange
        let processInfo = ProcessInfo.processInfo
        var blockExecuted = false
        let expectation = self.expectation(description: "Background activity block executed")

        // Act
        let options: ProcessInfo.ActivityOptions = [.background, .idleSystemSleepDisabled]
        processInfo.performActivity(options: options, reason: "Phase0 background transcription") {
            blockExecuted = true
            expectation.fulfill()
        }

        // Assert
        wait(for: [expectation], timeout: 5.0)
        XCTAssertTrue(blockExecuted, "performActivity background block must execute")
    }

    /// Stress test: begin/end 10 activity tokens in sequence.
    /// Validates no resource leak or crash from repeated calls during long transcription.
    func test_appNap_repeatedBeginEnd_doesNotCrash() {
        // Arrange
        let processInfo = ProcessInfo.processInfo
        let options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]

        // Act + Assert — each iteration must complete without crash
        for i in 0..<10 {
            let token = processInfo.beginActivity(
                options: options,
                reason: "Phase0 repeated activity \(i)"
            )
            XCTAssertNotNil(token, "Token \(i) must be non-nil")
            processInfo.endActivity(token)
        }
    }
}
