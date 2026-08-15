import Foundation
import os

/// A term the app has repeatedly seen corrected, tracked until the user
/// decides whether it belongs in their glossary.
struct LearnedTerm: Codable, Equatable {
    /// The authoritative spelling — the glossary entry we would propose.
    let term: String
    /// How many times a correction produced this term.
    var count: Int
    /// Distinct mis-recognitions observed, newest last. Shown in the review UI
    /// so the user can see *why* a term is being proposed. Capped.
    var heardAs: [String]
    var firstSeen: Date
    var lastSeen: Date
    /// Whether the user has ruled on this term yet.
    var status: Status

    enum Status: String, Codable {
        /// Accumulating evidence; eligible to be suggested at the threshold.
        case pending
        /// User added it to the glossary.
        case accepted
        /// User rejected it — never propose again.
        case dismissed
    }
}

/// Accumulates vocabulary-correction evidence across sessions and proposes
/// glossary additions once a term has been corrected repeatedly.
///
/// **Never edits the glossary itself.** The plan is explicit that learned terms
/// go through a review UI rather than being applied silently: a wrong entry in
/// an authoritative-spellings list actively forces bad substitutions, so a
/// human decision is the whole point. This type only counts evidence and
/// answers "what should we suggest?".
///
/// Storage is a single JSON file in Application Support. Local only — this is
/// speech content and never leaves the machine.
final class LearnedVocabularyStore: @unchecked Sendable {

    /// Times a term must be independently corrected before we suggest it. Two
    /// is deliberately low but not one: a single correction is often the LLM
    /// improvising, whereas a repeat means the recognizer reliably mishears a
    /// term this speaker actually uses.
    static let defaultSuggestionThreshold = 2

    /// Cap on stored examples per term — enough to explain the suggestion
    /// without letting the file grow with every repetition.
    private static let maxExamplesPerTerm = 5

    private let fileURL: URL
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.murmur.app", category: "vocab-learning")

    static func defaultFileURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
            .appendingPathComponent("learned-vocabulary.json")
    }

    init(fileURL: URL = LearnedVocabularyStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Recording

    /// Fold one correction pair into the store. Terms already in the user's
    /// glossary are ignored — they are already authoritative, so there is
    /// nothing to learn and nothing to suggest.
    ///
    /// Never throws: learning is a background nicety and must not disturb
    /// dictation.
    func observe(before: String, after: String, existingGlossary: [String] = CorrectionPrompts.currentGlossary(), now: Date = Date()) {
        let candidates = VocabularyCandidateExtractor.candidates(before: before, after: after)
        guard !candidates.isEmpty else { return }

        let glossaryLowercased = Set(existingGlossary.map { $0.lowercased() })

        lock.lock()
        defer { lock.unlock() }

        var terms = loadLocked()
        var changed = false

        for candidate in candidates {
            let key = candidate.corrected
            // Already an authoritative term — nothing to learn.
            if glossaryLowercased.contains(key.lowercased()) { continue }

            if let index = terms.firstIndex(where: { $0.term.lowercased() == key.lowercased() }) {
                // A dismissed term stays dismissed; re-proposing something the
                // user already rejected is nagging.
                if terms[index].status == .dismissed { continue }
                terms[index].count += 1
                terms[index].lastSeen = now
                if !terms[index].heardAs.contains(candidate.heard) {
                    terms[index].heardAs.append(candidate.heard)
                    if terms[index].heardAs.count > Self.maxExamplesPerTerm {
                        terms[index].heardAs.removeFirst()
                    }
                }
                changed = true
            } else {
                terms.append(
                    LearnedTerm(
                        term: key,
                        count: 1,
                        heardAs: [candidate.heard],
                        firstSeen: now,
                        lastSeen: now,
                        status: .pending
                    )
                )
                changed = true
            }
        }

        if changed { saveLocked(terms) }
    }

    // MARK: - Reading

    /// All tracked terms, in insertion order.
    func allTerms() -> [LearnedTerm] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    /// Terms ready to show the user: pending, at or above the threshold, and
    /// not already in the glossary. Most-corrected first.
    func suggestions(
        threshold: Int = LearnedVocabularyStore.defaultSuggestionThreshold,
        existingGlossary: [String] = CorrectionPrompts.currentGlossary()
    ) -> [LearnedTerm] {
        let glossaryLowercased = Set(existingGlossary.map { $0.lowercased() })
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
            .filter { $0.status == .pending }
            .filter { $0.count >= threshold }
            .filter { !glossaryLowercased.contains($0.term.lowercased()) }
            .sorted { ($0.count, $1.term) > ($1.count, $0.term) }
    }

    // MARK: - User decisions

    /// Mark a term accepted. Caller is responsible for actually appending it to
    /// the glossary — this type deliberately does not write that setting.
    func markAccepted(_ term: String) { setStatus(term, to: .accepted) }

    /// Mark a term rejected. It will never be suggested again.
    func markDismissed(_ term: String) { setStatus(term, to: .dismissed) }

    private func setStatus(_ term: String, to status: LearnedTerm.Status) {
        lock.lock()
        defer { lock.unlock() }
        var terms = loadLocked()
        guard let index = terms.firstIndex(where: { $0.term.lowercased() == term.lowercased() })
        else { return }
        terms[index].status = status
        saveLocked(terms)
    }

    /// Forget everything. Used by tests and a future "clear learned terms".
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Persistence (caller holds `lock`)

    private func loadLocked() -> [LearnedTerm] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let terms = try? Self.decoder.decode([LearnedTerm].self, from: data) else {
            logger.warning("LearnedVocabularyStore: unreadable store; starting empty")
            return []
        }
        return terms
    }

    private func saveLocked(_ terms: [LearnedTerm]) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let data = try Self.encoder.encode(terms)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.warning("LearnedVocabularyStore: save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
