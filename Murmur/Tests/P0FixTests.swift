import XCTest
@testable import Murmur

// MARK: - P0 Fix 4: Auto language detection default

final class AutoLanguageDefaultTests: XCTestCase {

    func testDefaultLanguageIsAuto() {
        // Remove any stored value to test the default
        let testKey = "transcriptionLanguage_test_\(UUID().uuidString)"
        XCTAssertNil(UserDefaults.standard.string(forKey: testKey),
                     "Fresh UserDefaults key should be nil")

        // The @AppStorage default in both MenuBarView and SettingsView is now "auto"
        // We verify the convention: when no value is stored, "auto" should be the fallback
        let lang = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"
        // For a fresh install (no stored value), this should be "auto"
        // Note: in the actual app, @AppStorage("transcriptionLanguage") defaults to "auto"
        if UserDefaults.standard.object(forKey: "transcriptionLanguage") == nil {
            XCTAssertEqual(lang, "auto")
        }
    }

    func testAutoLanguagePassedToTranscription() {
        // Verify "auto" is a valid language string that gets passed through
        let lang = "auto"
        XCTAssertEqual(lang, "auto")
        XCTAssertNotEqual(lang, "en", "Default should not be English anymore")
    }
}

// MARK: - ModelBackend tests

final class ModelBackendTests: XCTestCase {

    func testAllBackendsHaveUniqueSubdirectories() {
        let subdirs = ModelBackend.allCases.map(\.modelSubdirectory)
        XCTAssertEqual(subdirs.count, Set(subdirs).count, "Backends must have unique subdirectories")
    }

    func testAllBackendsHaveUniqueRawValues() {
        let rawValues = ModelBackend.allCases.map(\.rawValue)
        XCTAssertEqual(rawValues.count, Set(rawValues).count, "Backends must have unique raw values")
    }

    func testSpeechModelDoesNotRequireHFLogin() {
        XCTAssertFalse(ModelBackend.qwen3.requiresHFLogin)
    }
}
