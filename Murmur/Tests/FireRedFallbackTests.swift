import XCTest
@testable import Murmur

@MainActor
final class FireRedFallbackTests: XCTestCase {

    func test_fireRedInitFailure_throwsModelNotFound() {
        let bogusURL = URL(fileURLWithPath: "/tmp/nope-firered-\(UUID().uuidString)")
        do {
            _ = try FireRedTranscriptionService(modelDirectory: bogusURL)
            XCTFail("Expected init to throw modelNotFound")
        } catch let err as MurmurError {
            if case .modelNotFound = err { return }
            XCTFail("Expected .modelNotFound, got \(err)")
        } catch {
            XCTFail("Expected MurmurError.modelNotFound, got \(error)")
        }
    }

    /// Toggle flips back to OFF when the user enables it but the model isn't
    /// downloaded and no download has been kicked off.
    func test_setUseFireRedForChinese_whenModelMissing_returnsFalseAndStaysOff() {
        UserDefaults.standard.removeObject(forKey: "useFireRedForChinese")
        let mm = ModelManager()
        XCTAssertFalse(mm.useFireRedForChinese)
        let ok = mm.setUseFireRedForChinese(true)
        XCTAssertFalse(ok)
        XCTAssertFalse(mm.useFireRedForChinese)
    }
}
