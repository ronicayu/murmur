import XCTest
@testable import Murmur

// MARK: - Mock LID

/// Test double for LanguageIdentifying. Can be configured to return a canned
/// result or throw. `identify` ignores the audio URL — we never need to feed
/// real audio through the Whisper pipeline in unit tests.
final class MockLanguageIdentifier: LanguageIdentifying, @unchecked Sendable {
    enum Behaviour {
        case success(code: String, confidence: Float)
        case failure(Error)
    }

    var behaviour: Behaviour = .success(code: "en", confidence: 0.95)
    private(set) var callCount = 0

    func identify(audioURL: URL) async throws -> LIDResult {
        callCount += 1
        switch behaviour {
        case .success(let code, let conf):
            return LIDResult(code: code, confidence: conf)
        case .failure(let err):
            throw err
        }
    }

    func preload() async throws {}
    func unload() async {}
    func setModelPath(_ url: URL) async {}
}

// MARK: - Mapping & token table

final class CohereLanguageMappingTests: XCTestCase {
    func testSupportedMapsToSelf() {
        XCTAssertEqual(CohereLanguageMapping.map("en"), "en")
        XCTAssertEqual(CohereLanguageMapping.map("zh"), "zh")
        XCTAssertEqual(CohereLanguageMapping.map("vi"), "vi")
    }

    func testUnsupportedMapsToNil() {
        XCTAssertNil(CohereLanguageMapping.map("th"))   // Thai — Whisper has it, Cohere does not
        XCTAssertNil(CohereLanguageMapping.map("ru"))   // Russian — Whisper has it, Cohere does not
        XCTAssertNil(CohereLanguageMapping.map("xx"))   // Nonsense
    }
}

final class WhisperLanguageTokenTests: XCTestCase {
    func testFirstTokenIsEnglish() {
        XCTAssertEqual(WhisperLanguageTokens.code(for: 50259), "en")
    }

    func testSecondTokenIsChinese() {
        XCTAssertEqual(WhisperLanguageTokens.code(for: 50260), "zh")
    }

    func testCohereSetMaps() {
        // Smoke-check that every Cohere-supported language is within the
        // Whisper language-token range. If someone adds a code to the Cohere
        // set that Whisper doesn't support, this test catches it up front.
        for cohereCode in CohereLanguageMapping.supported {
            XCTAssertNotNil(
                WhisperLanguageTokens.languageCodes.firstIndex(of: cohereCode),
                "Cohere-supported code \(cohereCode) missing from Whisper language table"
            )
        }
    }

    func testOutOfRangeReturnsNil() {
        XCTAssertNil(WhisperLanguageTokens.code(for: 50258))                // start-of-transcript, not a language
        XCTAssertNil(WhisperLanguageTokens.code(for: 50259 + 1000))         // past last language
    }
}

// MARK: - resolveTranscriptionLanguageAsync

/// Drives the coordinator's async language resolution against a mocked LID.
/// Each test scopes its UserDefaults mutations and restores them on tearDown,
/// so the shared defaults store is not leaked between cases.
@MainActor
final class ResolveTranscriptionLanguageAsyncTests: XCTestCase {

    private var coordinator: AppCoordinator!
    private var mock: MockLanguageIdentifier!
    private var dummyURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        coordinator = AppCoordinator()
        mock = MockLanguageIdentifier()
        // Any valid URL works — the mock ignores it.
        dummyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lid-test-\(UUID().uuidString).wav")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "autoDetectLanguage")
        UserDefaults.standard.removeObject(forKey: "transcriptionLanguage")
        coordinator = nil
        mock = nil
        dummyURL = nil
        try await super.tearDown()
    }

    func testAutoDetectOff_fallsBackToPickerValue() async {
        UserDefaults.standard.set(false, forKey: "autoDetectLanguage")
        UserDefaults.standard.set("en", forKey: "transcriptionLanguage")
        coordinator.lid = mock
        mock.behaviour = .success(code: "zh", confidence: 0.99)

        let lang = await coordinator.resolveTranscriptionLanguageAsync(audioURL: dummyURL)
        XCTAssertEqual(lang, "en")
        XCTAssertEqual(mock.callCount, 0, "LID must not run when toggle is off")
    }

    func testAutoDetectOn_noLID_fallsBackToPicker() async {
        UserDefaults.standard.set(true, forKey: "autoDetectLanguage")
        UserDefaults.standard.set("ja", forKey: "transcriptionLanguage")
        coordinator.lid = nil

        let lang = await coordinator.resolveTranscriptionLanguageAsync(audioURL: dummyURL)
        XCTAssertEqual(lang, "ja", "Missing LID model must fall through to Picker value")
    }

    func testAutoDetectOn_highConfidenceSupported_returnsDetected() async {
        UserDefaults.standard.set(true, forKey: "autoDetectLanguage")
        UserDefaults.standard.set("en", forKey: "transcriptionLanguage")
        coordinator.lid = mock
        mock.behaviour = .success(code: "zh", confidence: 0.92)

        let lang = await coordinator.resolveTranscriptionLanguageAsync(audioURL: dummyURL)
        XCTAssertEqual(lang, "zh", "High-confidence detection must override Picker")
        XCTAssertEqual(mock.callCount, 1)
    }

    func testAutoDetectOn_lowConfidence_fallsBackToPicker() async {
        UserDefaults.standard.set(true, forKey: "autoDetectLanguage")
        UserDefaults.standard.set("en", forKey: "transcriptionLanguage")
        coordinator.lid = mock
        mock.behaviour = .success(code: "zh", confidence: 0.30)

        let lang = await coordinator.resolveTranscriptionLanguageAsync(audioURL: dummyURL)
        XCTAssertEqual(lang, "en", "Below-threshold detection must not override Picker")
    }

    func testAutoDetectOn_exactThreshold_usesDetected() async {
        // The threshold is a `>=` check — exactly 0.60 trusts the detection.
        // If this test fails because the threshold was tuned, update both
        // sides together in the source.
        UserDefaults.standard.set(true, forKey: "autoDetectLanguage")
        UserDefaults.standard.set("en", forKey: "transcriptionLanguage")
        coordinator.lid = mock
        mock.behaviour = .success(code: "fr", confidence: 0.60)

        let lang = await coordinator.resolveTranscriptionLanguageAsync(audioURL: dummyURL)
        XCTAssertEqual(lang, "fr")
    }

    func testAutoDetectOn_highConfidenceUnsupported_fallsBackToPicker() async {
        UserDefaults.standard.set(true, forKey: "autoDetectLanguage")
        UserDefaults.standard.set("en", forKey: "transcriptionLanguage")
        coordinator.lid = mock
        // Thai is high-confidence but outside Cohere's set — must fall back.
        mock.behaviour = .success(code: "th", confidence: 0.97)

        let lang = await coordinator.resolveTranscriptionLanguageAsync(audioURL: dummyURL)
        XCTAssertEqual(lang, "en")
    }

    func testAutoDetectOn_inferenceFailure_fallsBackToPicker() async {
        UserDefaults.standard.set(true, forKey: "autoDetectLanguage")
        UserDefaults.standard.set("de", forKey: "transcriptionLanguage")
        coordinator.lid = mock
        mock.behaviour = .failure(MurmurError.transcriptionFailed("simulated"))

        let lang = await coordinator.resolveTranscriptionLanguageAsync(audioURL: dummyURL)
        XCTAssertEqual(lang, "de")
    }

    func testAutoDetectOn_pickerIsAuto_usesInputSourceHeuristic() async {
        // When the Picker is "auto" and detection is below threshold, we fall
        // through to the input-source heuristic. This test just asserts the
        // resolver doesn't crash and returns a valid code; the exact value
        // depends on the test runner's active keyboard layout, which we can't
        // safely mutate from a unit test.
        UserDefaults.standard.set(true, forKey: "autoDetectLanguage")
        UserDefaults.standard.set("auto", forKey: "transcriptionLanguage")
        coordinator.lid = mock
        mock.behaviour = .success(code: "xx", confidence: 0.10)

        let lang = await coordinator.resolveTranscriptionLanguageAsync(audioURL: dummyURL)
        XCTAssertFalse(lang.isEmpty)
        XCTAssertEqual(lang.count, 2, "Fallback must be a two-letter language code")
    }
}

// MARK: - AuxiliaryModel + ModelManager glue

@MainActor
final class AuxiliaryModelStateTests: XCTestCase {

    func testDefaultsToNotDownloaded() {
        let mm = ModelManager()
        // Redirect the aux dir so we never look at the real Application Support
        // path from CI; isAuxiliaryDownloaded reads the manifest on disk.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lid-\(UUID().uuidString)")
        mm.__testing_setAuxiliaryDirectory(tmp, for: .lidWhisperTiny)
        XCTAssertFalse(mm.isAuxiliaryDownloaded(.lidWhisperTiny))
        XCTAssertEqual(mm.auxiliaryState(for: .lidWhisperTiny), .notDownloaded)
    }

    func testBusyStatesReportNotDownloaded() {
        let mm = ModelManager()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lid-\(UUID().uuidString)")
        mm.__testing_setAuxiliaryDirectory(tmp, for: .lidWhisperTiny)
        mm.__testing_setAuxiliaryState(.downloading(progress: -1, bytesPerSec: 0), for: .lidWhisperTiny)
        XCTAssertFalse(mm.isAuxiliaryDownloaded(.lidWhisperTiny),
                       "In-flight download must not be reported as downloaded")
        mm.__testing_setAuxiliaryState(.verifying, for: .lidWhisperTiny)
        XCTAssertFalse(mm.isAuxiliaryDownloaded(.lidWhisperTiny))
    }

    func testAuxiliaryModelMetadata() {
        let aux = AuxiliaryModel.lidWhisperTiny
        XCTAssertEqual(aux.modelSubdirectory, "Murmur/Models-LID")
        XCTAssertFalse(aux.requiredFiles.isEmpty)
        XCTAssertTrue(aux.allowPatterns.contains { $0.contains("encoder_model") })
    }
}
