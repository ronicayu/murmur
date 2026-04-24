import XCTest
@testable import Murmur

// MARK: - Test doubles

/// Spy for PillControlling. Records the last call to `show` so tests can assert
/// what badge / state was displayed without standing up a real NSWindow.
final class SpyPillController: PillControlling, @unchecked Sendable {
    private(set) var showCallCount = 0
    private(set) var lastState: AppState?
    private(set) var lastBadge: String?
    private(set) var hideCallCount = 0

    func show(state: AppState, audioLevel: Float, languageBadge: String?, onCancel: (() -> Void)?) {
        showCallCount += 1
        lastState = state
        lastBadge = languageBadge
    }

    func hide(after delay: TimeInterval) {
        hideCallCount += 1
    }
}

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

    func testAutoDetectOn_silenceDetected_fallsBackSilently() async {
        // When LID throws silenceDetected, the coordinator must NOT show an error
        // pill and must return the fallback language. Silence is a normal user
        // action (accidental press), not an error condition.
        UserDefaults.standard.set(true, forKey: "autoDetectLanguage")
        UserDefaults.standard.set("de", forKey: "transcriptionLanguage")
        coordinator.lid = mock
        mock.behaviour = .failure(MurmurError.silenceDetected)

        let lang = await coordinator.resolveTranscriptionLanguageAsync(audioURL: dummyURL)
        XCTAssertEqual(lang, "de", "silenceDetected must fall through to the picker value, not surface an error")
    }

    // MARK: - Badge update when LID overrides IME (DA fix #3)

    /// Verifies that resolveTranscriptionLanguageAsync returns the LID-detected
    /// language code when confidence is above threshold (the input to badge update).
    ///
    /// CR NC-2 note: the stopAndTranscribeV1 badge-update block (lines 664–669 in
    /// AppCoordinator) requires live AudioService to invoke; it is not reachable
    /// from unit tests without a full audio stack. That path is covered at
    /// integration / UAT level. This test validates the resolver output — the
    /// value stopAndTranscribeV1 consumes when computing the new badge.
    func test_resolvedLanguage_isLIDCode_whenConfidenceAboveThreshold() async {
        // Arrange: IME/picker is "auto" (so activeBadge starts as "EN·" from
        // resolveTranscriptionLanguage at record-start). LID returns zh @ 0.90.
        UserDefaults.standard.set(true, forKey: "autoDetectLanguage")
        UserDefaults.standard.set("auto", forKey: "transcriptionLanguage")
        coordinator.lid = mock
        mock.behaviour = .success(code: "zh", confidence: 0.90)

        // Act
        let resolvedLang = await coordinator.resolveTranscriptionLanguageAsync(audioURL: dummyURL)

        // Assert: resolver returns "zh" — this is the value stopAndTranscribeV1
        // feeds into LanguageBadge.badgeText to produce "ZH·".
        XCTAssertEqual(resolvedLang, "zh",
                       "resolveTranscriptionLanguageAsync must return the LID-detected language when confidence is above threshold")
    }

    // MARK: - LID model detached notification (UT #5a)

    /// When the LID model is removed while the user has auto-detect enabled,
    /// notifyLIDModelDetached must post a pill error toast so the user sees
    /// that their preference was silently reset — not discover it later.
    func test_notifyLIDModelDetached_showsPillWithDisabledMessage() {
        // Arrange: inject a spy pill so we can observe show calls without NSWindow.
        let spy = SpyPillController()
        let coord = AppCoordinator(pill: spy)

        // Act: simulate MurmurApp's `!lidReady, coordinator.lid != nil` branch.
        coord.notifyLIDModelDetached()

        // Assert: pill was shown with an error state mentioning the disabled
        // auto-detect, then scheduled to auto-hide.
        XCTAssertEqual(spy.showCallCount, 1,
                       "notifyLIDModelDetached must call pill.show exactly once")
        XCTAssertEqual(spy.hideCallCount, 1,
                       "notifyLIDModelDetached must schedule pill.hide")
        if case .error(let err) = spy.lastState {
            let description = err.errorDescription ?? err.shortMessage
            XCTAssertTrue(
                description.lowercased().contains("auto-detect") ||
                description.lowercased().contains("language"),
                "Error description must mention auto-detect or language; got: \(description)"
            )
        } else {
            XCTFail("pill.show must be called with an .error state; got \(String(describing: spy.lastState))")
        }
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

    // MARK: - QA P0-1: auxiliaryManifestIsValid truthy path

    /// T1: A well-formed manifest with matching file sizes must return true.
    /// Closes QA P0-1: the truthy path of auxiliaryManifestIsValid was never exercised.
    func test_auxiliaryManifestIsValid_returnsTrue_whenManifestAndSizesMatch() throws {
        // Arrange
        let (mm, tmp) = makeSandboxedManager()
        let onnxDir = tmp.appendingPathComponent("onnx")
        try FileManager.default.createDirectory(at: onnxDir, withIntermediateDirectories: true)

        let fileContent = Data(repeating: 0xAB, count: 8)
        let relPath = "onnx/encoder_model_quantized.onnx"
        try fileContent.write(to: tmp.appendingPathComponent(relPath))

        try writeAuxManifest(to: tmp, files: [relPath: Int64(fileContent.count)])

        // Act + Assert
        XCTAssertTrue(mm.auxiliaryManifestIsValid(.lidWhisperTiny),
                      "auxiliaryManifestIsValid must return true when manifest and file sizes match")
        XCTAssertTrue(mm.isAuxiliaryDownloaded(.lidWhisperTiny),
                      "isAuxiliaryDownloaded must be true when manifest is valid")
    }

    // MARK: - QA P0-2: auxiliaryModelPath nil / non-nil

    /// T2a: No manifest on disk → auxiliaryModelPath returns nil.
    func test_auxiliaryModelPath_returnsNil_whenManifestAbsent() {
        // Arrange: temp dir exists but is empty (no manifest)
        let (mm, _) = makeSandboxedManager()

        // Act + Assert
        XCTAssertNil(mm.auxiliaryModelPath(.lidWhisperTiny),
                     "auxiliaryModelPath must be nil when no manifest exists")
    }

    /// T2b: Valid manifest → auxiliaryModelPath returns the model directory.
    func test_auxiliaryModelPath_returnsDirectory_whenManifestValid() throws {
        // Arrange
        let (mm, tmp) = makeSandboxedManager()
        let onnxDir = tmp.appendingPathComponent("onnx")
        try FileManager.default.createDirectory(at: onnxDir, withIntermediateDirectories: true)

        let fileContent = Data(repeating: 0xCD, count: 16)
        let relPath = "onnx/encoder_model_quantized.onnx"
        try fileContent.write(to: tmp.appendingPathComponent(relPath))
        try writeAuxManifest(to: tmp, files: [relPath: Int64(fileContent.count)])

        // Act
        let path = mm.auxiliaryModelPath(.lidWhisperTiny)

        // Assert
        XCTAssertNotNil(path, "auxiliaryModelPath must return the directory URL when the manifest is valid")
        XCTAssertEqual(path?.path, tmp.path)
    }

    // MARK: - QA P0-3: deleteAuxiliary clears state and directory

    /// T3: After deleteAuxiliary, the directory must be gone and the state reset.
    func test_deleteAuxiliary_clearsFilesAndResetsStateTotNotDownloaded() throws {
        // Arrange: seed a valid fixture
        let (mm, tmp) = makeSandboxedManager()
        let onnxDir = tmp.appendingPathComponent("onnx")
        try FileManager.default.createDirectory(at: onnxDir, withIntermediateDirectories: true)

        let fileContent = Data(repeating: 0xFF, count: 4)
        let relPath = "onnx/encoder_model_quantized.onnx"
        try fileContent.write(to: tmp.appendingPathComponent(relPath))
        try writeAuxManifest(to: tmp, files: [relPath: Int64(fileContent.count)])
        mm.__testing_setAuxiliaryState(.ready, for: .lidWhisperTiny)

        // Confirm precondition
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))

        // Act
        try mm.deleteAuxiliary(.lidWhisperTiny)

        // Assert: directory gone
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path),
                       "deleteAuxiliary must remove the model directory from disk")
        // Assert: state reset
        XCTAssertEqual(mm.auxiliaryState(for: .lidWhisperTiny), .notDownloaded,
                       "deleteAuxiliary must reset auxiliaryStates to .notDownloaded")
        // Assert: isAuxiliaryDownloaded follows
        XCTAssertFalse(mm.isAuxiliaryDownloaded(.lidWhisperTiny),
                       "isAuxiliaryDownloaded must be false after delete")
    }

    // MARK: - QA P0-4: refreshAuxiliaryState transitions

    /// T4a: Valid manifest on disk → refreshAuxiliaryState sets state to .ready.
    func test_refreshAuxiliaryState_setsReady_whenValidManifest() throws {
        // Arrange
        let (mm, tmp) = makeSandboxedManager()
        let onnxDir = tmp.appendingPathComponent("onnx")
        try FileManager.default.createDirectory(at: onnxDir, withIntermediateDirectories: true)

        let fileContent = Data(repeating: 0x01, count: 12)
        let relPath = "onnx/encoder_model_quantized.onnx"
        try fileContent.write(to: tmp.appendingPathComponent(relPath))
        try writeAuxManifest(to: tmp, files: [relPath: Int64(fileContent.count)])

        // State not yet set
        XCTAssertEqual(mm.auxiliaryState(for: .lidWhisperTiny), .notDownloaded)

        // Act
        mm.refreshAuxiliaryState(.lidWhisperTiny)

        // Assert
        XCTAssertEqual(mm.auxiliaryState(for: .lidWhisperTiny), .ready,
                       "refreshAuxiliaryState must set state to .ready when a valid manifest exists")
    }

    /// T4b: No manifest on disk → refreshAuxiliaryState sets state to .notDownloaded.
    func test_refreshAuxiliaryState_setsNotDownloaded_whenNoManifest() {
        // Arrange: empty temp dir, no manifest
        let (mm, _) = makeSandboxedManager()
        mm.__testing_setAuxiliaryState(.ready, for: .lidWhisperTiny) // prime a stale state

        // Act
        mm.refreshAuxiliaryState(.lidWhisperTiny)

        // Assert
        XCTAssertEqual(mm.auxiliaryState(for: .lidWhisperTiny), .notDownloaded,
                       "refreshAuxiliaryState must set state to .notDownloaded when no manifest exists")
    }

    // MARK: - Helpers

    /// Returns a fresh ModelManager redirected to an isolated temp directory,
    /// cleaning up automatically via addTeardownBlock.
    private func makeSandboxedManager() -> (ModelManager, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lid-aux-\(UUID().uuidString)")
        // Create the directory so the manager can write into it.
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let mm = ModelManager()
        mm.__testing_setAuxiliaryDirectory(tmp, for: .lidWhisperTiny)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tmp)
        }
        return (mm, tmp)
    }

    /// Writes a minimal valid manifest.json into `dir` for the auxiliary model.
    /// `files` maps relative paths to their byte sizes — the manifest is authoritative
    /// for size-based validity checks in `auxiliaryManifestIsValid`.
    private func writeAuxManifest(to dir: URL, files: [String: Int64]) throws {
        var fileEntries: [String: [String: Any]] = [:]
        for (path, size) in files {
            fileEntries[path] = ["sha256": "deadbeef", "size": size]
        }
        let manifest: [String: Any] = [
            "version": 1,
            "backend": "lidWhisperTiny",
            "createdAt": "2026-01-01T00:00:00Z",
            "files": fileEntries,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: dir.appendingPathComponent("manifest.json"))
    }
}
