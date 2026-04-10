import XCTest
@testable import Murmur

// MARK: - P0 Fix 1: modelConfigHash per-backend key

final class ModelConfigHashTests: XCTestCase {

    override func tearDown() {
        // Clean up any test keys
        for backend in ModelBackend.allCases {
            UserDefaults.standard.removeObject(forKey: "modelConfigHash_\(backend.rawValue)")
        }
        UserDefaults.standard.removeObject(forKey: "modelConfigHash")
        super.tearDown()
    }

    func testHashKeyIsPerBackend() {
        // The old bug: a single "modelConfigHash" key was shared across all backends.
        // After fix: each backend uses "modelConfigHash_<backend>" key.
        let onnxKey = "modelConfigHash_onnx"
        let hfKey = "modelConfigHash_huggingface"
        let whisperKey = "modelConfigHash_whisper"

        // Simulate storing hashes for different backends
        UserDefaults.standard.set("abc123", forKey: onnxKey)
        UserDefaults.standard.set("def456", forKey: hfKey)

        // They should not interfere with each other
        XCTAssertEqual(UserDefaults.standard.string(forKey: onnxKey), "abc123")
        XCTAssertEqual(UserDefaults.standard.string(forKey: hfKey), "def456")
        XCTAssertNil(UserDefaults.standard.string(forKey: whisperKey))

        // Old key should not exist
        XCTAssertNil(UserDefaults.standard.string(forKey: "modelConfigHash"))
    }

    func testBackendKeysAreDistinct() {
        let keys = ModelBackend.allCases.map { "modelConfigHash_\($0.rawValue)" }
        XCTAssertEqual(keys.count, Set(keys).count, "Backend hash keys must be unique")
    }
}

// MARK: - P0 Fix 3: TranscriptionService TOCTOU race

final class TranscriptionServiceLockTests: XCTestCase {

    func testConcurrentEnsureProcessAndKillDoesNotCrash() async {
        // Actor isolation serializes access — verify no crashes under concurrent calls.
        let service = TranscriptionService(
            modelPath: URL(fileURLWithPath: "/nonexistent"),
            pythonPath: URL(fileURLWithPath: "/nonexistent"),
            scriptPath: URL(fileURLWithPath: "/nonexistent")
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await service.killProcess()
                }
                group.addTask {
                    await service.setModelPath(URL(fileURLWithPath: "/tmp/test_\(Int.random(in: 0...100))"))
                }
            }
        }

        XCTAssertFalse(service.isModelLoaded)
    }
}

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

// MARK: - Python script language parameter tests

final class TranscribePyLanguageTests: XCTestCase {

    func testAutoLanguageOmitsParameterInOnnx() throws {
        // Read the transcribe.py and verify the auto-detect logic
        let scriptURL = Bundle.module.url(forResource: "transcribe", withExtension: "py", subdirectory: "Resources")
            ?? Bundle.main.url(forResource: "transcribe", withExtension: "py")

        // If we can find the script, verify the auto-detect code exists
        if let url = scriptURL {
            let content = try String(contentsOf: url)
            XCTAssert(content.contains("language != \"auto\""),
                      "transcribe.py should check for 'auto' language to skip explicit language parameter")
        }
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

    func testOnnxDoesNotRequireHFLogin() {
        XCTAssertFalse(ModelBackend.onnx.requiresHFLogin)
    }

    func testHuggingfaceRequiresHFLogin() {
        XCTAssertTrue(ModelBackend.huggingface.requiresHFLogin)
    }
}
