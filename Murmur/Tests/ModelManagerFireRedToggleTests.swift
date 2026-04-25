import XCTest
import Combine
@testable import Murmur

@MainActor
final class ModelManagerFireRedToggleTests: XCTestCase {

    private let key = "useFireRedForChinese"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func test_default_isFalse_whenUserDefaultsUnset() {
        let mm = ModelManager()
        XCTAssertFalse(mm.useFireRedForChinese)
    }

    func test_initial_readsPersistedTrue() {
        UserDefaults.standard.set(true, forKey: key)
        let mm = ModelManager()
        if FileManager.default.fileExists(atPath: mm.modelDirectory(for: .fireRed).path) {
            XCTAssertTrue(mm.useFireRedForChinese)
        } else {
            XCTAssertFalse(mm.useFireRedForChinese,
                           "Toggle must be downgraded to false when FireRed model is missing on disk")
        }
    }

    func test_setUseFireRedForChinese_false_alwaysSucceeds() {
        UserDefaults.standard.set(true, forKey: key)
        let mm = ModelManager()
        let ok = mm.setUseFireRedForChinese(false)
        XCTAssertTrue(ok)
        XCTAssertFalse(mm.useFireRedForChinese)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
    }

    func test_setUseFireRedForChinese_true_refused_whenFireRedNotDownloaded() {
        let mm = ModelManager()
        let ok = mm.setUseFireRedForChinese(true)
        XCTAssertFalse(ok, "Toggle ON must be refused if FireRed model is missing")
        XCTAssertFalse(mm.useFireRedForChinese)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
    }

    func test_setUseFireRedForChinese_true_refused_duringActiveDownload() {
        let mm = ModelManager()
        mm.__testing_setState(.downloading(progress: 0.5, bytesPerSec: 0))
        let ok = mm.setUseFireRedForChinese(true)
        XCTAssertFalse(ok)
    }

    func test_committedChange_firesOnFalseToggle() {
        UserDefaults.standard.set(true, forKey: key)
        let mm = ModelManager()
        var received: [Bool] = []
        let cancellable = mm.committedUseFireRedChange.sink { received.append($0) }
        defer { cancellable.cancel() }
        // If init downgraded the toggle to false (model not present), there's nothing
        // to flip. Use the explicit setter result to drive the assertion.
        if mm.useFireRedForChinese {
            _ = mm.setUseFireRedForChinese(false)
            XCTAssertEqual(received, [false])
        } else {
            // When toggle starts at false, calling setter with false short-circuits;
            // verify no spurious emission.
            _ = mm.setUseFireRedForChinese(false)
            XCTAssertEqual(received, [], "Setter must short-circuit when state is unchanged")
        }
    }

    func test_committedChange_doesNotFire_whenAlreadyAtTargetState() {
        let mm = ModelManager()
        var received: [Bool] = []
        let cancellable = mm.committedUseFireRedChange.sink { received.append($0) }
        defer { cancellable.cancel() }
        _ = mm.setUseFireRedForChinese(false)
        XCTAssertEqual(received, [], "Setter must short-circuit when state is unchanged")
    }
}
