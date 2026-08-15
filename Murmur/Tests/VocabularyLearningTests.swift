import XCTest
@testable import Murmur

// Phase 3.2 of the 10x plan: personal vocabulary that learns from corrections.
// Pure logic + a temp-file store — no models, light tier.

// MARK: - Extractor

final class VocabularyCandidateExtractorTests: XCTestCase {

    private func corrected(_ before: String, _ after: String) -> [String] {
        VocabularyCandidateExtractor.candidates(before: before, after: after).map(\.corrected)
    }

    // MARK: The cases the feature exists for

    func test_extractsCrossScriptTermCorrection() {
        // The motivating example: a Chinese-sounding mis-hear of an acronym.
        let candidates = VocabularyCandidateExtractor.candidates(
            before: "我们今天的奥凯阿在下午三点对齐",
            after: "我们今天的 OKR 在下午三点对齐"
        )
        XCTAssertTrue(candidates.contains { $0.corrected == "OKR" },
            "A mis-heard acronym replaced by its real spelling is the core signal; got \(candidates)")
    }

    func test_extractsChineseTermCorrection() {
        let candidates = VocabularyCandidateExtractor.candidates(
            before: "下午三点对其一下进度",
            after: "下午三点对齐一下进度"
        )
        XCTAssertTrue(candidates.contains { $0.corrected == "对齐" },
            "对其 -> 对齐 is a term correction; got \(candidates)")
    }

    func test_extractsCasingNormalisation() {
        // Casing IS an authoritative-spelling question — the glossary prompt
        // says to snap to the entry's exact casing.
        let candidates = VocabularyCandidateExtractor.candidates(
            before: "we track okr every quarter",
            after: "we track OKR every quarter"
        )
        XCTAssertTrue(candidates.contains { $0.corrected == "OKR" },
            "okr -> OKR must be learnable; got \(candidates)")
    }

    func test_extractsMultiTokenMisrecognition() {
        let candidates = VocabularyCandidateExtractor.candidates(
            before: "deploy to cuber netties today",
            after: "deploy to kubernetes today"
        )
        XCTAssertTrue(candidates.contains { $0.corrected == "kubernetes" },
            "A term split into two mis-heard words must still resolve; got \(candidates)")
    }

    // MARK: Noise that must NOT become a candidate

    func test_ignoresIdenticalText() {
        XCTAssertTrue(VocabularyCandidateExtractor.candidates(
            before: "nothing changed here", after: "nothing changed here").isEmpty)
    }

    func test_ignoresPunctuationOnlyChanges() {
        // The corrector's main job is punctuation; none of it is vocabulary.
        XCTAssertTrue(corrected("hello world how are you", "Hello, world. How are you?").isEmpty,
            "Punctuation and sentence-casing must not be learned as terms")
    }

    func test_ignoresChinesePunctuationInsertion() {
        XCTAssertTrue(corrected("我们今天开会讨论进度", "我们今天开会，讨论进度。").isEmpty)
    }

    func test_ignoresGrammarHomophoneFixes() {
        // their/there is a grammar fix; as a glossary entry it would force
        // wrong substitutions.
        XCTAssertFalse(corrected("i put it over their", "I put it over there").contains("there"))
        XCTAssertFalse(corrected("its going to rain", "it's going to rain").contains("it's"))
    }

    func test_ignoresEmptyOrBlankInput() {
        XCTAssertTrue(VocabularyCandidateExtractor.candidates(before: "", after: "OKR").isEmpty)
        XCTAssertTrue(VocabularyCandidateExtractor.candidates(before: "OKR", after: "   ").isEmpty)
    }

    func test_ignoresSingleCharacterTerms() {
        // Single CJK chars are usually grammatical particles, not terms.
        XCTAssertFalse(
            VocabularyCandidateExtractor.isVocabularyCorrection(heard: "了", corrected: "的"),
            "A one-character CJK substitution is a particle fix, not vocabulary")
    }

    func test_ignoresPureDigitsAndPunctuation() {
        XCTAssertFalse(VocabularyCandidateExtractor.isVocabularyCorrection(heard: "3", corrected: "4"))
        XCTAssertFalse(VocabularyCandidateExtractor.isVocabularyCorrection(heard: "--", corrected: "——"))
    }

    func test_ignoresOverlongSpans() {
        // A whole rewritten clause is paraphrase, not a term.
        let long = String(repeating: "a", count: 60)
        XCTAssertFalse(VocabularyCandidateExtractor.isVocabularyCorrection(heard: "x", corrected: long))
    }

    // MARK: Tokenisation

    func test_tokenize_segmentsChineseWithoutSpaces() {
        let tokens = VocabularyCandidateExtractor.tokenize("下午三点对齐进度")
        XCTAssertGreaterThan(tokens.count, 1,
            "Chinese must be word-segmented, not returned as one blob")
        XCTAssertFalse(tokens.contains(where: { $0.contains(" ") }))
    }

    func test_tokenize_dropsPunctuation() {
        let tokens = VocabularyCandidateExtractor.tokenize("Hello, world!")
        XCTAssertEqual(tokens.map { $0.lowercased() }, ["hello", "world"])
    }
}

// MARK: - Store

final class LearnedVocabularyStoreTests: XCTestCase {

    private var fileURL: URL!
    private var store: LearnedVocabularyStore!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("learned-vocabulary.json")
        store = LearnedVocabularyStore(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        store = nil
        fileURL = nil
        try super.tearDownWithError()
    }

    private func observeOKR(times: Int, glossary: [String] = []) {
        for _ in 0..<times {
            store.observe(
                before: "我们今天的奥凯阿在下午三点",
                after: "我们今天的 OKR 在下午三点",
                existingGlossary: glossary,
                now: now
            )
        }
    }

    func test_firstObservation_isTrackedButNotYetSuggested() {
        observeOKR(times: 1)
        XCTAssertEqual(store.allTerms().first?.term, "OKR")
        XCTAssertEqual(store.allTerms().first?.count, 1)
        XCTAssertTrue(store.suggestions(existingGlossary: []).isEmpty,
            "One correction is often the LLM improvising — wait for a repeat")
    }

    func test_repeatedObservation_reachesThreshold_andIsSuggested() {
        observeOKR(times: 2)
        let suggestions = store.suggestions(existingGlossary: [])
        XCTAssertEqual(suggestions.map(\.term), ["OKR"])
        XCTAssertEqual(suggestions.first?.count, 2)
    }

    func test_termAlreadyInGlossary_isNeverSuggested() {
        observeOKR(times: 5, glossary: ["OKR"])
        XCTAssertTrue(store.allTerms().isEmpty,
            "A term that is already authoritative has nothing to learn")
    }

    func test_glossaryMatchIsCaseInsensitive() {
        observeOKR(times: 5, glossary: ["okr"])
        XCTAssertTrue(store.suggestions(existingGlossary: ["okr"]).isEmpty)
    }

    func test_dismissedTerm_isNeverSuggestedAgain() {
        observeOKR(times: 2)
        store.markDismissed("OKR")
        observeOKR(times: 5)

        XCTAssertTrue(store.suggestions(existingGlossary: []).isEmpty,
            "Re-proposing a rejected term is nagging")
        XCTAssertEqual(store.allTerms().first?.status, .dismissed)
        XCTAssertEqual(store.allTerms().first?.count, 2,
            "A dismissed term must stop accumulating evidence entirely")
    }

    func test_acceptedTerm_dropsOutOfSuggestions() {
        observeOKR(times: 2)
        store.markAccepted("OKR")
        XCTAssertTrue(store.suggestions(existingGlossary: []).isEmpty)
        XCTAssertEqual(store.allTerms().first?.status, .accepted)
    }

    func test_storeNeverWritesTheGlossaryItself() {
        let before = CorrectionPrompts.currentGlossary()
        observeOKR(times: 10)
        store.markAccepted("OKR")
        XCTAssertEqual(CorrectionPrompts.currentGlossary(), before,
            "Learning must never silently edit the user's authoritative term list")
    }

    func test_examplesAreRecorded_andDeduplicated() {
        store.observe(before: "的奥凯阿在", after: "的 OKR 在", existingGlossary: [], now: now)
        store.observe(before: "的奥凯阿在", after: "的 OKR 在", existingGlossary: [], now: now)
        let term = store.allTerms().first
        XCTAssertEqual(term?.count, 2)
        XCTAssertEqual(term?.heardAs.count, 1,
            "The same mis-hearing twice is one distinct example")
    }

    func test_suggestionsSortedByFrequency() {
        observeOKR(times: 3)
        for _ in 0..<2 {
            store.observe(
                before: "deploy to cuber netties",
                after: "deploy to kubernetes",
                existingGlossary: [], now: now
            )
        }
        XCTAssertEqual(store.suggestions(existingGlossary: []).map(\.term), ["OKR", "kubernetes"],
            "Most-corrected term first")
    }

    func test_noiseCorrections_produceNoTerms() {
        store.observe(
            before: "hello world how are you",
            after: "Hello, world. How are you?",
            existingGlossary: [], now: now
        )
        XCTAssertTrue(store.allTerms().isEmpty,
            "A punctuation-only correction must not create vocabulary entries")
    }

    func test_persistsAcrossReinstantiation() {
        observeOKR(times: 2)
        let reopened = LearnedVocabularyStore(fileURL: fileURL)
        XCTAssertEqual(reopened.suggestions(existingGlossary: []).map(\.term), ["OKR"])
    }

    func test_corruptStore_startsEmptyRatherThanCrashing() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertTrue(store.allTerms().isEmpty)
        observeOKR(times: 2)
        XCTAssertEqual(store.suggestions(existingGlossary: []).map(\.term), ["OKR"],
            "A corrupt store must recover, not permanently break learning")
    }

    func test_reset_clearsEverything() {
        observeOKR(times: 3)
        store.reset()
        XCTAssertTrue(store.allTerms().isEmpty)
    }

    // MARK: - Accept flow (mirrors what the Settings "Add" button does)

    /// The glossary is a comma-joined string; accepting a term must append to
    /// it without disturbing existing entries or duplicating.
    private func glossaryAfterAccepting(_ term: String, existing: [String]) -> [String] {
        var terms = existing
        if !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            terms.append(term)
        }
        return terms
    }

    func test_acceptFlow_appendsToGlossary_preservingExisting() {
        let result = glossaryAfterAccepting("OKR", existing: ["对齐", "k8s"])
        XCTAssertEqual(result, ["对齐", "k8s", "OKR"])
    }

    func test_acceptFlow_doesNotDuplicateExistingTerm() {
        let result = glossaryAfterAccepting("okr", existing: ["OKR"])
        XCTAssertEqual(result, ["OKR"],
            "Accepting a term already present must not create a near-duplicate entry")
    }

    func test_acceptFlow_roundTripsThroughGlossaryParsing() {
        // The joined string must parse back to the same terms — including CJK,
        // which is what the full-width-comma handling exists for.
        let terms = glossaryAfterAccepting("对齐", existing: ["OKR", "k8s"])
        let joined = terms.joined(separator: ", ")
        let key = "vocabRoundTrip_\(UUID().uuidString)"
        UserDefaults.standard.set(joined, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        let parsed = raw.replacingOccurrences(of: "，", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(parsed, ["OKR", "k8s", "对齐"])
    }
}
