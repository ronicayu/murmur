import XCTest
@testable import Murmur

@MainActor
final class UndoWindowTests: XCTestCase {

    func test_expires_whenNotCancelled() async {
        let window = UndoWindow()
        let expired = expectation(description: "onExpire called")

        window.open(seconds: 0.05, onUndoSeen: {}, onExpire: { expired.fulfill() })

        await fulfillment(of: [expired], timeout: 5)
    }

    func test_cancel_stopsTheExpiry() async throws {
        let window = UndoWindow()
        var expiredCount = 0

        window.open(seconds: 0.2, onUndoSeen: {}, onExpire: { expiredCount += 1 })
        window.cancel()
        try await Task.sleep(for: .seconds(0.6))

        XCTAssertEqual(expiredCount, 0)
    }

    func test_isOpen_untilItExpiresOrIsCancelled() async {
        let window = UndoWindow()
        XCTAssertFalse(window.isOpen)

        window.open(seconds: 5, onUndoSeen: {}, onExpire: {})
        XCTAssertTrue(window.isOpen)
        window.cancel()
        XCTAssertFalse(window.isOpen)

        let expired = expectation(description: "onExpire called")
        var openWhenExpired: Bool?
        window.open(seconds: 0.05, onUndoSeen: {}, onExpire: {
            openWhenExpired = window.isOpen
            expired.fulfill()
        })
        await fulfillment(of: [expired], timeout: 5)
        XCTAssertEqual(openWhenExpired, false)
        XCTAssertFalse(window.isOpen)
    }

    func test_openingAgain_replacesTheFirstWindow() async throws {
        let window = UndoWindow()
        var firstExpired = 0
        let secondExpired = expectation(description: "second onExpire called")

        window.open(seconds: 0.2, onUndoSeen: {}, onExpire: { firstExpired += 1 })
        window.open(seconds: 0.3, onUndoSeen: {}, onExpire: { secondExpired.fulfill() })

        await fulfillment(of: [secondExpired], timeout: 5)
        XCTAssertEqual(firstExpired, 0)
    }
}
