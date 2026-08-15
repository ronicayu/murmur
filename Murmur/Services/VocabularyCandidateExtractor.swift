import Foundation
import NaturalLanguage

/// One observed correction: the recognizer heard `heard`, and a later, more
/// authoritative pass produced `corrected`.
struct VocabularyCandidate: Equatable, Hashable {
    /// What the speech recognizer produced.
    let heard: String
    /// The authoritative spelling that replaced it.
    let corrected: String
}

/// Extracts vocabulary-correction candidates from a (before, after) text pair.
///
/// Two pipeline steps already produce exactly this shape of evidence:
///   • the LLM corrector rewriting a raw transcript, and
///   • the streaming finalize pass replacing streamed text.
///
/// Most of those diffs are punctuation, casing of ordinary words, or
/// paraphrase — noise for our purposes. What we want is the narrow case where a
/// *term* was mis-recognised and then fixed: "奥凯阿" → "OKR", "对其" → "对齐",
/// "cuber netties" → "kubernetes". Those are worth proposing for the glossary,
/// because a glossary entry makes the fix authoritative and consistent instead
/// of dependent on the corrector guessing right every time.
///
/// This type is pure: no storage, no I/O, no UserDefaults. It answers one
/// question — "which substitutions in this diff look like vocabulary?" — so the
/// filtering rules can be tested exhaustively.
enum VocabularyCandidateExtractor {

    /// Maximum tokens on the *mis-heard* side. Deliberately looser than the
    /// corrected side: a term the recognizer did not know often comes back
    /// fragmented — the system tokenizer splits the nonsense "奥凯阿" into three
    /// single characters, and "kubernetes" can arrive as "cuber netties".
    private static let maxHeardSpanTokens = 4
    /// Maximum tokens on the corrected side. A real term is one or two words;
    /// more than that is paraphrase or restructuring.
    private static let maxCorrectedSpanTokens = 2
    /// Longest term we will ever propose. Guards against a whole clause being
    /// captured as a "term".
    private static let maxTermLength = 40

    /// Grammatical words whose correction is a grammar fix, not a vocabulary
    /// one. The corrector's sound-alike rule handles these (their/there,
    /// its/it's); putting them in a glossary of authoritative spellings would
    /// be useless at best and would force wrong substitutions at worst.
    private static let grammaticalWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by",
        "for", "from", "had", "has", "have", "he", "her", "here", "hers",
        "him", "his", "hour", "i", "in", "is", "it", "its", "it's", "me",
        "my", "no", "not", "of", "on", "or", "our", "ours", "she", "so",
        "than", "that", "the", "their", "theirs", "them", "then", "there",
        "these", "they", "they're", "this", "those", "to", "too", "two",
        "us", "was", "we", "were", "what", "when", "where", "which", "who",
        "why", "will", "with", "would", "you", "your", "you're", "yours",
    ]

    /// Extract candidates from a correction pair. Returns an empty array when
    /// the texts are equal, when either is blank, or when nothing in the diff
    /// looks like a term substitution.
    static func candidates(before: String, after: String) -> [VocabularyCandidate] {
        guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              before != after else { return [] }

        let beforeTokens = tokenize(before)
        let afterTokens = tokenize(after)
        guard !beforeTokens.isEmpty, !afterTokens.isEmpty else { return [] }

        return substitutions(from: beforeTokens, to: afterTokens)
            .compactMap { sub in
                let heard = joinTokens(sub.before)
                let corrected = joinTokens(sub.after)
                guard isVocabularyCorrection(heard: heard, corrected: corrected) else { return nil }
                return VocabularyCandidate(heard: heard, corrected: corrected)
            }
    }

    /// Re-join tokens into a term. CJK is written without inter-word spaces, so
    /// joining "奥","凯","阿" with spaces would invent a spelling the user never
    /// said; space-delimited scripts keep their spaces.
    private static func joinTokens(_ tokens: [String]) -> String {
        let anyLatin = tokens.contains { token in
            token.unicodeScalars.contains { $0.isASCII && CharacterSet.letters.contains($0) }
        }
        return tokens.joined(separator: anyLatin ? " " : "")
    }

    // MARK: - Filtering

    /// Whether a substitution looks like a vocabulary correction worth
    /// proposing, as opposed to punctuation, grammar, or paraphrase.
    static func isVocabularyCorrection(heard: String, corrected: String) -> Bool {
        guard heard != corrected else { return false }
        guard corrected.count <= maxTermLength, heard.count <= maxTermLength else { return false }

        // The authoritative side must be a real term: at least two characters
        // and containing a letter or ideograph. This drops punctuation-only
        // diffs, bare numbers, and single CJK characters (usually grammatical
        // particles like 的 / 了 rather than terms).
        let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        guard trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return false
        }

        // Grammar fixes are the corrector's job, not the glossary's.
        if grammaticalWords.contains(trimmed.lowercased()) { return false }
        if grammaticalWords.contains(heard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return false
        }

        // Same letters, differing only in case and/or spacing.
        if normalisedForComparison(heard) == normalisedForComparison(corrected) {
            // A joining fix ("k 8 s" -> "k8s") is a genuine spelling-authority
            // question, so keep it.
            let heardJoined = heard.replacingOccurrences(of: " ", with: "")
            let correctedJoined = corrected.replacingOccurrences(of: " ", with: "")
            if heardJoined.lowercased() != correctedJoined.lowercased() { return true }
            if heardJoined != correctedJoined, heardJoined.lowercased() == correctedJoined.lowercased() {
                // Casing-only. Distinguish a term's own capitalisation ("okr" ->
                // "OKR", "trpc" -> "tRPC", "ios" -> "iOS") from ordinary
                // sentence capitalisation ("hello" -> "Hello"), which the
                // corrector applies to the first word of every sentence and
                // which says nothing about vocabulary. Only the former has an
                // uppercase letter beyond the first character.
                return hasInternalUppercase(correctedJoined)
            }
            // Spacing-only difference with identical joined forms.
            return heardJoined != correctedJoined
        }

        return true
    }

    /// Whether the term carries an uppercase letter after its first character —
    /// the signature of an acronym or a deliberately-cased product name, as
    /// opposed to sentence-initial capitalisation.
    private static func hasInternalUppercase(_ s: String) -> Bool {
        s.dropFirst().contains { $0.isUppercase }
    }

    /// Lowercased, punctuation- and whitespace-stripped form used for
    /// "is this actually the same string?" comparisons.
    private static func normalisedForComparison(_ s: String) -> String {
        s.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    // MARK: - Tokenisation

    /// Split into words using the system tokenizer, which segments Chinese and
    /// Japanese (no spaces between words) as well as space-delimited scripts.
    /// Punctuation falls out because we only take `.word` ranges.
    static func tokenize(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { out.append(token) }
            return true
        }
        return out
    }

    // MARK: - Diff

    private struct Substitution {
        let before: [String]
        let after: [String]
    }

    /// Walk an LCS alignment and collect contiguous replaced blocks. Pure
    /// insertions and deletions are ignored — a term the corrector *added* or
    /// *removed* outright is not evidence of a mis-spelling.
    private static func substitutions(from a: [String], to b: [String]) -> [Substitution] {
        let common = longestCommonSubsequence(a, b)

        var result: [Substitution] = []
        var i = 0, j = 0
        for anchor in common + [nil] {
            var beforeRun: [String] = []
            var afterRun: [String] = []
            while i < a.count, anchor == nil || !matches(a[i], anchor) {
                beforeRun.append(a[i]); i += 1
                if anchor == nil && i >= a.count { break }
            }
            while j < b.count, anchor == nil || !matches(b[j], anchor) {
                afterRun.append(b[j]); j += 1
                if anchor == nil && j >= b.count { break }
            }
            if !beforeRun.isEmpty, !afterRun.isEmpty,
               beforeRun.count <= maxHeardSpanTokens, afterRun.count <= maxCorrectedSpanTokens {
                result.append(Substitution(before: beforeRun, after: afterRun))
            }
            if anchor != nil {
                if i < a.count { i += 1 }
                if j < b.count { j += 1 }
            }
        }
        return result
    }

    private static func matches(_ token: String, _ anchor: String?) -> Bool {
        guard let anchor else { return false }
        // Must use the same equality as the LCS below, or the walk desynchronises
        // from its own anchors.
        return token == anchor
    }

    /// Standard LCS, compared case-sensitively so a casing-only change does NOT
    /// anchor and instead surfaces as a substitution — "okr" -> "OKR" is exactly
    /// the kind of authoritative-spelling fix a glossary encodes. Ordinary
    /// sentence capitalisation is filtered later, in `isVocabularyCorrection`.
    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for x in stride(from: a.count - 1, through: 0, by: -1) {
            for y in stride(from: b.count - 1, through: 0, by: -1) {
                if a[x] == b[y] {
                    table[x][y] = table[x + 1][y + 1] + 1
                } else {
                    table[x][y] = max(table[x + 1][y], table[x][y + 1])
                }
            }
        }
        var out: [String] = []
        var x = 0, y = 0
        while x < a.count, y < b.count {
            if a[x] == b[y] {
                out.append(a[x]); x += 1; y += 1
            } else if table[x + 1][y] >= table[x][y + 1] {
                x += 1
            } else {
                y += 1
            }
        }
        return out
    }
}
