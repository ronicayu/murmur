import XCTest
@testable import Murmur

final class IdleTriggerTests: XCTestCase {

    func test_actionRuns_afterTheIdleTime() async {
        let ran = expectation(description: "action ran")
        let trigger = IdleTrigger(seconds: 0.05) { ran.fulfill() }

        trigger.touch()

        await fulfillment(of: [ran], timeout: 5)
    }

    func test_cancel_stopsTheCountdown() async throws {
        let runs = LockedCounter()
        let trigger = IdleTrigger(seconds: 0.2) { runs.increment() }

        trigger.touch()
        trigger.cancel()
        try await Task.sleep(for: .seconds(0.6))

        XCTAssertEqual(runs.value, 0)
    }

    func test_touchAgain_replacesTheCountdown_soTheActionRunsOnce() async throws {
        let runs = LockedCounter()
        let trigger = IdleTrigger(seconds: 0.2) { runs.increment() }

        trigger.touch()
        trigger.touch()
        trigger.touch()
        try await Task.sleep(for: .seconds(0.8))

        XCTAssertEqual(runs.value, 1)
    }

    func test_nothingRuns_withoutATouch() async throws {
        let runs = LockedCounter()
        let trigger = IdleTrigger(seconds: 0.05) { runs.increment() }

        try await Task.sleep(for: .seconds(0.3))

        XCTAssertEqual(runs.value, 0)
        trigger.cancel()
    }
}
