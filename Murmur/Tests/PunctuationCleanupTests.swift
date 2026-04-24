import XCTest
@testable import Murmur

// MARK: - Rule-based EN tests

final class PunctuationCleanupServiceENTests: XCTestCase {

    private var sut: PunctuationCleanupService!

    override func setUp() {
        super.setUp()
        sut = PunctuationCleanupService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: Empty / whitespace edge cases

    func test_en_emptyString_returnsEmpty() async throws {
        // Arrange
        let input = ""

        // Act
        let result = try await sut.improve(input, language: "en")

        // Assert
        XCTAssertEqual(result, "")
    }

    func test_en_whitespaceOnly_returnsUnchanged() async throws {
        // Arrange — a whitespace-only string has nothing to clean up;
        // the spec says skip terminal period on empty/whitespace-only.
        let input = "   "

        // Act
        let result = try await sut.improve(input, language: "en")

        // Assert — trimmed to empty (or whitespace-only, both acceptable per spec)
        XCTAssertTrue(result.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: Capitalization + terminal period

    func test_en_singleWord_capitalizesAndAddsPeriod() async throws {
        // Arrange
        let input = "hello"

        // Act
        let result = try await sut.improve(input, language: "en")

        // Assert
        XCTAssertEqual(result, "Hello.")
    }

    func test_en_multiSentence_capitalizesEachAfterTerminalPunctuation() async throws {
        // Arrange
        let input = "hello world. how are you"

        // Act
        let result = try await sut.improve(input, language: "en")

        // Assert — first letter capitalised, post-period letter capitalised, trailing period added
        XCTAssertEqual(result, "Hello world. How are you.")
    }

    func test_en_preservesExistingPunctuation() async throws {
        // Arrange — text already ends in "!" so no extra period should be appended
        let input = "I'm fine, thanks!"

        // Act
        let result = try await sut.improve(input, language: "en")

        // Assert
        XCTAssertEqual(result, "I'm fine, thanks!")
    }

    func test_en_doesNotDoubleTerminalPeriod() async throws {
        // Arrange — already ends in "."
        let input = "okay."

        // Act
        let result = try await sut.improve(input, language: "en")

        // Assert
        XCTAssertEqual(result, "Okay.")
    }

    // MARK: Pronoun "I" standalone

    func test_en_standalonePronounI_capitalizes() async throws {
        // Arrange
        let input = "i think i can"

        // Act
        let result = try await sut.improve(input, language: "en")

        // Assert — standalone "i" → "I", terminal period added, first letter capitalised
        XCTAssertEqual(result, "I think I can.")
    }

    func test_en_wordsContainingI_notCapitalized() async throws {
        // Arrange — "this", "is" etc. contain 'i' but are not standalone "i"
        let input = "this is fine"

        // Act
        let result = try await sut.improve(input, language: "en")

        // Assert
        XCTAssertEqual(result, "This is fine.")
    }

    // MARK: Terminal punctuation edge cases

    func test_en_endingInEllipsis_noExtraPeriod() async throws {
        // Arrange — U+2026 HORIZONTAL ELLIPSIS counts as terminal punctuation
        let input = "what\u{2026}"

        // Act
        let result = try await sut.improve(input, language: "en")

        // Assert
        XCTAssertEqual(result, "What\u{2026}")
    }

    func test_en_endingInQuestion_preserved() async throws {
        // Arrange
        let input = "what?"

        // Act
        let result = try await sut.improve(input, language: "en")

        // Assert
        XCTAssertEqual(result, "What?")
    }

    // MARK: Whitespace trimming

    func test_en_trimsWhitespace() async throws {
        // Arrange — leading/trailing spaces
        let input = "  hello  "

        // Act
        let result = try await sut.improve(input, language: "en")

        // Assert — trimmed, capitalised, period added
        XCTAssertEqual(result, "Hello.")
    }

    // MARK: Quote-ending behaviour

    func test_en_textEndingInClosingQuote_appendsTerminalPeriod() async throws {
        // Arrange — closing quote is NOT a terminal-punctuation suppressor;
        // `he said "hello"` should receive a trailing period so it reads as
        // a complete sentence. See PunctuationCleanupService.terminalPunctuation.
        let input = "he said \"hello\""

        // Act
        let result = try await sut.improve(input, language: "en")

        // Assert — period appended after the closing quote
        XCTAssertEqual(result, "He said \"hello\".")
    }
}

// MARK: - Passthrough for non-EN languages

final class PunctuationCleanupServicePassthroughTests: XCTestCase {

    private var sut: PunctuationCleanupService!

    override func setUp() {
        super.setUp()
        sut = PunctuationCleanupService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    func test_zh_passthrough_returnsInputUnchanged() async throws {
        // Arrange
        let input = "你好世界"

        // Act
        let result = try await sut.improve(input, language: "zh")

        // Assert — ZH is passthrough in v0.3.0
        XCTAssertEqual(result, "你好世界")
    }

    func test_ja_passthrough() async throws {
        // Arrange
        let input = "こんにちは世界"

        // Act
        let result = try await sut.improve(input, language: "ja")

        // Assert
        XCTAssertEqual(result, "こんにちは世界")
    }

    func test_ko_passthrough() async throws {
        // Arrange
        let input = "안녕하세요"

        // Act
        let result = try await sut.improve(input, language: "ko")

        // Assert
        XCTAssertEqual(result, "안녕하세요")
    }

    func test_unknownLanguage_passthrough() async throws {
        // Arrange — an arbitrary unsupported language code
        let input = "some text"

        // Act
        let result = try await sut.improve(input, language: "xx")

        // Assert
        XCTAssertEqual(result, "some text")
    }
}

// MARK: - Integration: AppCoordinator cleanup hook

/// Spy that conforms to TranscriptionCleanup. Exposes call arguments and can be
/// configured to succeed, throw, or sleep past the coordinator's timeout so tests
/// can exercise each branch in stopAndTranscribeV1.
actor SpyCleanupService: TranscriptionCleanup {
    enum Behaviour {
        case success(String)
        case failure(Error)
        /// Sleep for `seconds` before returning — used to trigger timeout.
        case slowSuccess(String, seconds: TimeInterval)
    }

    var behaviour: Behaviour = .success("")

    private(set) var callCount = 0
    private(set) var receivedText: String?
    private(set) var receivedLanguage: String?

    func setBehaviour(_ b: Behaviour) {
        behaviour = b
    }

    func improve(_ text: String, language: String) async throws -> String {
        callCount += 1
        receivedText = text
        receivedLanguage = language

        switch behaviour {
        case .success(let cleaned):
            return cleaned
        case .failure(let error):
            throw error
        case .slowSuccess(let cleaned, _):
            // Block indefinitely without a wall-clock dependency so the
            // coordinator's withTimeout always fires before this resumes.
            // Task.sleep(nanoseconds:) throws CancellationError when the
            // enclosing task group cancels this task — deterministic.
            _ = cleaned  // result is intentionally never returned
            try await Task.sleep(nanoseconds: UInt64.max)
            return cleaned  // unreachable; satisfies the compiler
        }
    }
}

// ---------------------------------------------------------------------------
// NOTE: The coordinator integration tests exercise stopAndTranscribeV1 via the
// internal testable hook `stopAndTranscribeV1ForTesting(wav:lang:)` that we
// will add to AppCoordinator under #if DEBUG. This avoids having to stand up
// real audio hardware. The spy transcription service (from
// TranscriptionWindowModelTests.swift) is reused here.
// ---------------------------------------------------------------------------

@MainActor
final class CoordinatorCleanupTests: XCTestCase {

    private var spyTranscription: SpyTranscriptionService!
    private var spyPill: SpyPillController!
    private var spyCleanup: SpyCleanupService!
    private var coordinator: AppCoordinator!

    override func setUp() {
        super.setUp()
        spyTranscription = SpyTranscriptionService()
        spyPill = SpyPillController()
        spyCleanup = SpyCleanupService()
        coordinator = AppCoordinator(
            transcription: spyTranscription,
            pill: spyPill
        )
        coordinator.skipAccessibilityCheck = true
    }

    override func tearDown() {
        coordinator = nil
        spyCleanup = nil
        spyPill = nil
        spyTranscription = nil
        super.tearDown()
    }

    // MARK: Cleanup enabled

    func test_coordinator_cleanupEnabled_callsCleanupWithTranscribedText_andLanguage() async throws {
        // Arrange
        let rawText = "hello world"
        let cleanedText = "Hello world."
        UserDefaults.standard.set(true, forKey: "cleanupTranscription")
        defer { UserDefaults.standard.removeObject(forKey: "cleanupTranscription") }

        spyTranscription.stubbedResult = TranscriptionResult(
            text: rawText, language: .english, durationMs: 500
        )
        await spyCleanup.setBehaviour(.success(cleanedText))
        coordinator.cleanup = spyCleanup

        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: wav) }

        // Act
        await coordinator.stopAndTranscribeV1ForTesting(wav: wav, lang: "en")

        // Assert — cleanup was invoked with the raw transcription text and language
        let count = await spyCleanup.callCount
        let receivedText = await spyCleanup.receivedText
        let receivedLang = await spyCleanup.receivedLanguage
        XCTAssertEqual(count, 1)
        XCTAssertEqual(receivedText, rawText)
        XCTAssertEqual(receivedLang, "en")
        // The injected text should be the cleaned version
        XCTAssertEqual(coordinator.lastTranscription, cleanedText)
    }

    // MARK: Cleanup disabled

    func test_coordinator_cleanupDisabled_skipsCleanup_injectsRawText() async throws {
        // Arrange
        let rawText = "hello world"
        UserDefaults.standard.set(false, forKey: "cleanupTranscription")
        defer { UserDefaults.standard.removeObject(forKey: "cleanupTranscription") }

        spyTranscription.stubbedResult = TranscriptionResult(
            text: rawText, language: .english, durationMs: 500
        )
        await spyCleanup.setBehaviour(.success("should not be called"))
        coordinator.cleanup = spyCleanup

        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: wav) }

        // Act
        await coordinator.stopAndTranscribeV1ForTesting(wav: wav, lang: "en")

        // Assert — cleanup was NOT called; raw text was injected
        let count = await spyCleanup.callCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(coordinator.lastTranscription, rawText)
    }

    // MARK: Cleanup throws — fallback to raw text, no pill error

    func test_coordinator_cleanupThrows_fallsBackToRawText_noPill() async throws {
        // Arrange
        let rawText = "hello world"
        UserDefaults.standard.set(true, forKey: "cleanupTranscription")
        defer { UserDefaults.standard.removeObject(forKey: "cleanupTranscription") }

        spyTranscription.stubbedResult = TranscriptionResult(
            text: rawText, language: .english, durationMs: 500
        )
        struct CleanupError: Error {}
        await spyCleanup.setBehaviour(.failure(CleanupError()))
        coordinator.cleanup = spyCleanup

        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: wav) }

        // Act
        await coordinator.stopAndTranscribeV1ForTesting(wav: wav, lang: "en")

        // Assert — raw text injected despite cleanup failure; state is NOT error
        XCTAssertEqual(coordinator.lastTranscription, rawText)
        if case .error = coordinator.state {
            XCTFail("Coordinator must not enter error state on cleanup failure")
        }
    }

    // MARK: Cleanup timeout — fallback to raw text, no pill error

    func test_coordinator_cleanupTimeout_fallsBackToRawText_noPill() async throws {
        // Arrange — spy sleeps 1 s; coordinator's cleanup timeout is 250 ms
        let rawText = "hello world"
        UserDefaults.standard.set(true, forKey: "cleanupTranscription")
        defer { UserDefaults.standard.removeObject(forKey: "cleanupTranscription") }

        spyTranscription.stubbedResult = TranscriptionResult(
            text: rawText, language: .english, durationMs: 500
        )
        // Sleep well beyond the 250 ms cap
        await spyCleanup.setBehaviour(.slowSuccess("should not appear", seconds: 1.0))
        coordinator.cleanup = spyCleanup

        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: wav) }

        // Act
        await coordinator.stopAndTranscribeV1ForTesting(wav: wav, lang: "en")

        // Assert — raw text was injected (cleanup result ignored); no error state
        XCTAssertEqual(coordinator.lastTranscription, rawText)
        if case .error = coordinator.state {
            XCTFail("Coordinator must not enter error state on cleanup timeout")
        }
    }
}
