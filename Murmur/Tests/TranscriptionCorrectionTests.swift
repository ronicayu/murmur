import XCTest
@testable import Murmur

// MARK: - Safety rails

/// Unit tests for `CorrectionSafetyRails.validate`. These rules are the last
/// line of defence against a hallucinating or refusing LLM; they must be
/// deterministic and not depend on Foundation Models availability.
final class CorrectionSafetyRailsTests: XCTestCase {

    func test_empty_fallsBackToRaw() {
        let raw = "hello world"
        XCTAssertEqual(CorrectionSafetyRails.validate(candidate: "", raw: raw), raw)
    }

    func test_whitespaceOnly_fallsBackToRaw() {
        let raw = "hello world"
        XCTAssertEqual(CorrectionSafetyRails.validate(candidate: "   \n\t", raw: raw), raw)
    }

    func test_withinRatio_returnsCandidate() {
        // 11 chars raw, 13 chars candidate → ratio 1.18, inside 1.5 cap.
        XCTAssertEqual(
            CorrectionSafetyRails.validate(candidate: "Hello World!!", raw: "hello world"),
            "Hello World!!"
        )
    }

    func test_tooLong_fallsBackToRaw() {
        // Raw 11 chars, candidate 30 → ratio 2.7, exceeds 1.6 cap.
        let raw = "hello world"
        let candidate = "hello everyone how are you all"
        XCTAssertEqual(CorrectionSafetyRails.validate(candidate: candidate, raw: raw), raw)
    }

    func test_tooShort_fallsBackToRaw() {
        // Raw 20 chars, candidate 5 → ratio 0.25, below 0.5 floor.
        let raw = "hello world good day"
        XCTAssertEqual(CorrectionSafetyRails.validate(candidate: "hello", raw: raw), raw)
    }

    func test_refusalEnglish_fallsBackToRaw() {
        XCTAssertEqual(
            CorrectionSafetyRails.validate(candidate: "I cannot help with that.", raw: "write some code"),
            "write some code"
        )
    }

    func test_refusalContraction_fallsBackToRaw() {
        XCTAssertEqual(
            CorrectionSafetyRails.validate(candidate: "I can't fulfill that request.", raw: "write some code"),
            "write some code"
        )
    }

    func test_refusalMetacommentary_fallsBackToRaw() {
        XCTAssertEqual(
            CorrectionSafetyRails.validate(
                candidate: "As an AI language model I cannot assist.",
                raw: "just a sentence we speak"
            ),
            "just a sentence we speak"
        )
    }

    func test_refusalChinese_fallsBackToRaw() {
        let raw = "帮我写一段代码的描述"
        let candidate = "抱歉，我不能帮你做这件事。"
        XCTAssertEqual(CorrectionSafetyRails.validate(candidate: candidate, raw: raw), raw)
    }

    func test_candidateTrimmed_whitespaceStrippedFromResult() {
        XCTAssertEqual(
            CorrectionSafetyRails.validate(candidate: "  hello  ", raw: "hello"),
            "hello"
        )
    }

    func test_homophoneCorrection_returnsCandidate() {
        // Typical ASR homophone fix: "write" → "right", same length.
        XCTAssertEqual(
            CorrectionSafetyRails.validate(candidate: "you are right", raw: "you are write"),
            "you are right"
        )
    }

    func test_chineseCharacterFix_returnsCandidate() {
        // Chinese character substitution: 北经 → 北京, same count.
        XCTAssertEqual(
            CorrectionSafetyRails.validate(candidate: "我要去北京", raw: "我要去北经"),
            "我要去北京"
        )
    }
}

// MARK: - NoOp corrector

final class NoOpCorrectorTests: XCTestCase {

    func test_noop_returnsInputVerbatim_english() async throws {
        let result = try await NoOpCorrector().correct("hello world", language: "en")
        XCTAssertEqual(result, "hello world")
    }

    func test_noop_returnsInputVerbatim_chinese() async throws {
        let result = try await NoOpCorrector().correct("你好世界", language: "zh")
        XCTAssertEqual(result, "你好世界")
    }

    func test_noop_preservesWhitespace() async throws {
        let result = try await NoOpCorrector().correct("  hello  ", language: "en")
        XCTAssertEqual(result, "  hello  ")
    }
}

// MARK: - Coordinator integration

/// Spy corrector for exercising the coordinator's correction hook without
/// invoking Apple Foundation Models. Mirrors `SpyCleanupService`.
actor SpyCorrector: TranscriptionCorrection {
    enum Behaviour {
        case success(String)
        case failure(Error)
        /// Sleep forever so the coordinator's timeout always fires.
        /// `Task.sleep(nanoseconds:)` throws `CancellationError` on cancel,
        /// which the coordinator catches and treats as a timeout.
        case hang
    }

    var behaviour: Behaviour = .success("")

    private(set) var callCount = 0
    private(set) var receivedText: String?
    private(set) var receivedLanguage: String?

    func setBehaviour(_ b: Behaviour) {
        behaviour = b
    }

    func correct(_ text: String, language: String) async throws -> String {
        callCount += 1
        receivedText = text
        receivedLanguage = language

        switch behaviour {
        case .success(let corrected):
            return corrected
        case .failure(let error):
            throw error
        case .hang:
            try await Task.sleep(nanoseconds: UInt64.max)
            return text  // unreachable; satisfies the compiler
        }
    }
}

#if DEBUG

@MainActor
final class CoordinatorCorrectionTests: XCTestCase {

    private var spyTranscription: SpyTranscriptionService!
    private var spyPill: SpyPillController!
    private var spyCorrection: SpyCorrector!
    private var coordinator: AppCoordinator!

    override func setUp() {
        super.setUp()
        spyTranscription = SpyTranscriptionService()
        spyPill = SpyPillController()
        spyCorrection = SpyCorrector()
        coordinator = AppCoordinator(
            transcription: spyTranscription,
            pill: spyPill
        )
        coordinator.correction = spyCorrection
        coordinator.skipAccessibilityCheck = true
        // Isolate correction from cleanup by defaulting cleanup off.
        UserDefaults.standard.set(false, forKey: "cleanupTranscription")
    }

    override func tearDown() {
        coordinator = nil
        spyCorrection = nil
        spyPill = nil
        spyTranscription = nil
        UserDefaults.standard.removeObject(forKey: "correctTranscription")
        UserDefaults.standard.removeObject(forKey: "cleanupTranscription")
        super.tearDown()
    }

    private func writeDummyWav() -> URL {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("corr-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data())
        return wav
    }

    func test_correctionEnabled_callsCorrectorWithRawText_andLanguage() async throws {
        spyTranscription.stubbedResult = TranscriptionResult(
            text: "hello world",
            language: .english,
            durationMs: 10
        )
        await spyCorrection.setBehaviour(.success("Hello, world."))
        UserDefaults.standard.set(true, forKey: "correctTranscription")

        await coordinator.stopAndTranscribeV1ForTesting(wav: writeDummyWav(), lang: "en")

        let count = await spyCorrection.callCount
        let text = await spyCorrection.receivedText
        let lang = await spyCorrection.receivedLanguage
        XCTAssertEqual(count, 1)
        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(lang, "en")
        XCTAssertEqual(coordinator.lastTranscription, "Hello, world.")
    }

    func test_correctionDisabled_skipsCorrector_usesRawText() async throws {
        spyTranscription.stubbedResult = TranscriptionResult(
            text: "hello world",
            language: .english,
            durationMs: 10
        )
        await spyCorrection.setBehaviour(.success("should not be used"))
        UserDefaults.standard.set(false, forKey: "correctTranscription")

        await coordinator.stopAndTranscribeV1ForTesting(wav: writeDummyWav(), lang: "en")

        let count = await spyCorrection.callCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(coordinator.lastTranscription, "hello world")
    }

    func test_correctionThrows_fallsBackToRaw_noErrorState() async throws {
        spyTranscription.stubbedResult = TranscriptionResult(
            text: "hello world",
            language: .english,
            durationMs: 10
        )
        struct Boom: Error {}
        await spyCorrection.setBehaviour(.failure(Boom()))
        UserDefaults.standard.set(true, forKey: "correctTranscription")

        await coordinator.stopAndTranscribeV1ForTesting(wav: writeDummyWav(), lang: "en")

        XCTAssertEqual(coordinator.lastTranscription, "hello world")
        // State never enters `.error` on a correction throw — the failure
        // silently falls back to raw. Downstream transition() collapses
        // `.undoable` to `.idle` when the `undoAfterTranscription` UserDefault
        // is off (test default), so either outcome is acceptable here.
        if case .error = coordinator.state {
            XCTFail("correction throw must not surface as an error state")
        }
    }

    func test_correctionHangsPastTimeout_fallsBackToRaw() async throws {
        spyTranscription.stubbedResult = TranscriptionResult(
            text: "hello world",
            language: .english,
            durationMs: 10
        )
        await spyCorrection.setBehaviour(.hang)
        UserDefaults.standard.set(true, forKey: "correctTranscription")

        let start = Date()
        await coordinator.stopAndTranscribeV1ForTesting(wav: writeDummyWav(), lang: "en")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(coordinator.lastTranscription, "hello world")
        // 2.5 s spec cap + slack for scheduling. If this regresses, the timeout
        // chain is not reaching the spy's `Task.sleep`.
        XCTAssertLessThan(elapsed, 3.5, "correction timeout must fire within budget + slack")
    }

    func test_nilCorrector_skipsCorrection_usesRawText() async throws {
        spyTranscription.stubbedResult = TranscriptionResult(
            text: "hello world",
            language: .english,
            durationMs: 10
        )
        coordinator.correction = nil
        UserDefaults.standard.set(true, forKey: "correctTranscription")

        await coordinator.stopAndTranscribeV1ForTesting(wav: writeDummyWav(), lang: "en")

        XCTAssertEqual(coordinator.lastTranscription, "hello world")
    }
}

#endif

// MARK: - CorrectionPrompts façade

/// Tests for the `CorrectionPrompts` façade — the indirection between callers
/// (the two corrector backends) and the user's optional Settings overrides.
/// These tests touch real `UserDefaults`, so each test cleans up the keys it
/// writes to keep the suite hermetic.
final class CorrectionPromptsTests: XCTestCase {

    private let promptKey = CorrectionPrompts.systemPromptKey
    private let glossaryKey = CorrectionPrompts.glossaryKey

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: promptKey)
        UserDefaults.standard.removeObject(forKey: glossaryKey)
        super.tearDown()
    }

    // MARK: current — system prompt resolution

    func test_current_returnsDefault_whenUnset() {
        UserDefaults.standard.removeObject(forKey: promptKey)
        XCTAssertEqual(CorrectionPrompts.current, CorrectionPrompts.defaultSystemPrompt)
    }

    func test_current_returnsDefault_whenEmptyString() {
        UserDefaults.standard.set("", forKey: promptKey)
        XCTAssertEqual(CorrectionPrompts.current, CorrectionPrompts.defaultSystemPrompt)
    }

    func test_current_returnsDefault_whenWhitespaceOnly() {
        UserDefaults.standard.set("   \n\t  ", forKey: promptKey)
        XCTAssertEqual(CorrectionPrompts.current, CorrectionPrompts.defaultSystemPrompt)
    }

    func test_current_returnsTrimmedOverride_whenSet() {
        UserDefaults.standard.set("  custom prompt body  ", forKey: promptKey)
        XCTAssertEqual(CorrectionPrompts.current, "custom prompt body")
    }

    // MARK: currentGlossary — comma-split + trim + drop empties

    func test_currentGlossary_returnsEmpty_whenUnset() {
        UserDefaults.standard.removeObject(forKey: glossaryKey)
        XCTAssertEqual(CorrectionPrompts.currentGlossary(), [])
    }

    func test_currentGlossary_returnsEmpty_whenEmptyString() {
        UserDefaults.standard.set("", forKey: glossaryKey)
        XCTAssertEqual(CorrectionPrompts.currentGlossary(), [])
    }

    func test_currentGlossary_splitsAndTrims() {
        UserDefaults.standard.set("OKR, shipping ,  对齐, k8s", forKey: glossaryKey)
        XCTAssertEqual(
            CorrectionPrompts.currentGlossary(),
            ["OKR", "shipping", "对齐", "k8s"]
        )
    }

    func test_currentGlossary_dropsEmptyEntries() {
        UserDefaults.standard.set(",, OKR ,,  ,k8s,", forKey: glossaryKey)
        XCTAssertEqual(CorrectionPrompts.currentGlossary(), ["OKR", "k8s"])
    }

    func test_currentGlossary_acceptsFullWidthComma() {
        // CJK IMEs emit U+FF0C; treat it as equivalent to ASCII ','.
        UserDefaults.standard.set("OKR，对齐，k8s", forKey: glossaryKey)
        XCTAssertEqual(CorrectionPrompts.currentGlossary(), ["OKR", "对齐", "k8s"])
    }

    func test_currentGlossary_acceptsMixedCommas() {
        UserDefaults.standard.set("OKR, 对齐，shipping ,k8s", forKey: glossaryKey)
        XCTAssertEqual(
            CorrectionPrompts.currentGlossary(),
            ["OKR", "对齐", "shipping", "k8s"]
        )
    }

    // MARK: defaultSystemPrompt — sanity invariants

    func test_defaultSystemPrompt_isNonEmpty() {
        XCTAssertFalse(CorrectionPrompts.defaultSystemPrompt.isEmpty)
    }

    func test_defaultSystemPrompt_mentionsGlossary() {
        XCTAssertTrue(CorrectionPrompts.defaultSystemPrompt.contains("Glossary"),
                      "Default prompt must explain the Glossary field so the rule is grounded")
    }
}
