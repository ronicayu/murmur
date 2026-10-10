import Foundation

/// LocalAgreement-2 stable-prefix aggregator for streaming ASR.
///
/// Streaming transcription re-transcribes a *growing* audio window and feeds each
/// successive full hypothesis here via `ingest(_:)`. The aggregator emits only the
/// text that two consecutive hypotheses agree on (the "stable prefix"), beyond what
/// it has already emitted. Unstable tail tokens are withheld until a later pass
/// confirms them.
///
/// Why: transcribing each VAD segment once, in isolation, lets a single-pass
/// hallucination (a phantom phrase on a breath, a mis-heard boundary word) reach the
/// cursor with nothing to cross-check it. Requiring two consecutive passes to agree
/// before emitting suppresses those one-pass errors — exactly the "small chunks ->
/// more false detections" failure mode.
///
/// Tokenisation is mixed-script aware: each CJK / kana / Hangul character is its own
/// token; maximal runs of Latin letters+digits are one token. Agreement is compared
/// case-insensitively, but emitted text is sliced verbatim from the current
/// hypothesis, so original spacing, punctuation and casing are preserved — and the
/// concatenation of all emitted deltas (plus the final `flushAndReset`) exactly
/// reproduces the last hypothesis prefix.
///
/// Punctuation and symbols never take part in the agreement check. Models that
/// punctuate (Qwen3-ASR) move commas and full stops between passes of the same
/// audio — "所有，只要" then "所有只要" — and counting those as disagreement stalls
/// output for seconds even though every word is stable. Punctuation is still
/// emitted, verbatim, as part of the slice that follows the word before it.
struct StablePrefixAggregator {

    /// One word token (a CJK character or a Latin run) plus the exclusive end
    /// offset (in Characters) of its span in the hypothesis it was tokenised from.
    private struct Token { let value: String; let charEnd: Int }

    /// Words already emitted in this window, in order. Locked — only ever extended.
    private var confirmedValues: [String] = []
    /// Confirmed text accumulated for the current window (== concatenation of deltas).
    private(set) var confirmedText = ""
    /// Previous hypothesis tokens (for the LocalAgreement comparison).
    private var previousTokens: [Token] = []
    /// Index in `previousTokens` of the first word not yet emitted, or nil when
    /// the previous hypothesis could not be lined up with the emitted words.
    private var previousContinuation: Int? = 0
    /// Previous hypothesis as a Character array (for tail slicing on flush).
    private var previousChars: [Character] = []
    /// True when the latest pass matched the one before it word for word — the
    /// speaker has paused, so the window can be closed without cutting a word.
    private(set) var lastPassFullyAgreed = false

    /// How many trailing emitted words are searched for in a new hypothesis to
    /// find where its not-yet-emitted part begins.
    private static let anchorLength = 5

    // MARK: - API

    /// Feed the latest full-window hypothesis. Returns the text newly confirmed by
    /// this pass (empty if nothing new stabilised — always empty on the first pass,
    /// since LocalAgreement-2 needs two passes to agree).
    ///
    /// Each hypothesis is lined up with the words already emitted by *content*
    /// (the last few emitted words are located in it), not by word count. A later
    /// pass often revises earlier audio — inserts, drops or merges a word — and
    /// counting positions would then re-emit words already typed or skip new ones.
    @discardableResult
    mutating func ingest(_ hypothesis: String) -> String {
        let chars = Array(hypothesis)
        let current = Self.tokenize(chars)
        let continuation = continuationStart(in: current)

        var delta = ""
        var agreed = 0
        var fullyAgreed = false
        if let continuation, let previousContinuation {
            let previousRest = previousTokens[previousContinuation...]
            let currentRest = current[continuation...]
            agreed = Self.commonPrefixLength(previousRest, currentRest)
            fullyAgreed = !current.isEmpty
                && agreed == currentRest.count && agreed == previousRest.count
            if agreed > 0 {
                let startChar = continuation == 0 ? 0 : current[continuation - 1].charEnd
                let endChar = current[continuation + agreed - 1].charEnd
                delta = String(chars[startChar..<endChar])
                confirmedValues += current[continuation..<(continuation + agreed)].map(\.value)
            }
        }

        lastPassFullyAgreed = fullyAgreed
        confirmedText += delta
        previousTokens = current
        previousContinuation = continuation.map { $0 + agreed }
        previousChars = chars
        return delta
    }

    /// Confirm the withheld tail of the latest hypothesis (call on a genuine
    /// sentence-final pause or when the window is force-closed) and reset for the
    /// next window. Returns the tail text to inject.
    @discardableResult
    mutating func flushAndReset() -> String {
        // Everything after the last emitted word, including trailing punctuation.
        // If the last hypothesis could not be lined up with the emitted words,
        // nothing is flushed: guessing a position risks repeating typed text.
        var tail = ""
        if let start = previousContinuation {
            let startChar = start == 0 ? 0 : previousTokens[start - 1].charEnd
            var endChar = previousChars.count
            while endChar > startChar && previousChars[endChar - 1].isWhitespace { endChar -= 1 }
            if startChar < endChar { tail = String(previousChars[startChar..<endChar]) }
        }
        lastPassFullyAgreed = false
        confirmedValues = []
        confirmedText = ""
        previousTokens = []
        previousContinuation = 0
        previousChars = []
        return tail
    }

    /// How many of the last emitted words may be missing from a new hypothesis
    /// before it is treated as unrelated to what was emitted.
    private static let maxRevisedWords = 2

    /// Index in `tokens` of the first word after the already-emitted ones, found
    /// by locating the last few emitted words in `tokens`. Tries a shorter run
    /// when the full one is absent (the model revised one of those words), and
    /// prefers the match nearest to where the emitted words would end by count.
    ///
    /// When the model revised the *last* emitted word ("their" -> "there"), no
    /// run that ends with it can match again. The run just before it is then
    /// searched for, and the word that replaced it is stepped over: it stands
    /// where a word was already emitted, so emitting it would repeat that word.
    /// Up to `maxRevisedWords` trailing words are given up this way. If those
    /// words turn out to be present after all, a little further on (the model
    /// inserted a word before them), the continuation starts after them.
    ///
    /// Returns nil when the hypothesis shares no such run with the emitted words.
    private func continuationStart(in tokens: [Token]) -> Int? {
        for revised in 0...Self.maxRevisedWords where revised <= confirmedValues.count {
            let anchorWords = confirmedValues.dropLast(revised)
            // Every emitted word was revised: nothing is left to search for,
            // so the only position to go by is the count of emitted words.
            if anchorWords.isEmpty { return min(revised, tokens.count) }
            let longest = min(Self.anchorLength, anchorWords.count)
            let shortest = min(2, anchorWords.count)
            var length = longest
            while length >= shortest {
                let needle = anchorWords.suffix(length)
                let expected = anchorWords.count - length
                var best: Int?
                if tokens.count >= length {
                    for start in 0...(tokens.count - length) {
                        var matches = true
                        for (offset, value) in needle.enumerated() where tokens[start + offset].value != value {
                            matches = false
                            break
                        }
                        if matches, best == nil || abs(start - expected) < abs(best! - expected) {
                            best = start
                        }
                    }
                }
                if let best {
                    let afterAnchor = best + length
                    // The given-up words may not have been revised at all: the
                    // model may have inserted a word in front of them ("brown
                    // fox" -> "brown red fox"). If they still follow the anchor
                    // within a few words, continue after them. Stepping over a
                    // fixed count instead would land on "fox" and emit it twice.
                    if revised > 0 {
                        let dropped = Array(confirmedValues.suffix(revised))
                        let lastStart = min(afterAnchor + 2, tokens.count - revised)
                        if lastStart >= afterAnchor {
                            for start in afterAnchor...lastStart
                            where zip(dropped, tokens[start..<(start + revised)]).allSatisfy({ $0 == $1.value }) {
                                return start + revised
                            }
                        }
                    }
                    // A hypothesis that ends inside the revised words has nothing new.
                    return min(afterAnchor + revised, tokens.count)
                }
                length -= 1
            }
        }
        return nil
    }

    // MARK: - Tokenisation + slicing

    private static func commonPrefixLength(_ a: ArraySlice<Token>, _ b: ArraySlice<Token>) -> Int {
        var i = 0
        while i < a.count && i < b.count
            && a[a.startIndex + i].value == b[b.startIndex + i].value { i += 1 }
        return i
    }

    private static func tokenize(_ chars: [Character]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        let n = chars.count
        while i < n {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if isLatinWordChar(c) {
                var j = i
                while j < n && isLatinWordChar(chars[j]) { j += 1 }
                tokens.append(Token(value: String(chars[i..<j]).lowercased(), charEnd: j))
                i = j
            } else {
                // CJK / kana / Hangul -> single-char token. Punctuation and
                // symbols are skipped: they are emitted with the surrounding
                // slice but do not vote on agreement.
                if c.isLetter || c.isNumber {
                    tokens.append(Token(value: String(c).lowercased(), charEnd: i + 1))
                }
                i += 1
            }
        }
        return tokens
    }

    /// A Latin word character: ASCII letter/digit, or an internal apostrophe/hyphen
    /// ("don't", "state-of-the-art" stay single tokens). CJK/kana/Hangul are not
    /// Latin word chars, so each becomes its own token.
    private static func isLatinWordChar(_ c: Character) -> Bool {
        if c == "'" || c == "-" { return true }
        guard c.unicodeScalars.count == 1 else { return false }
        return c.isASCII && (c.isLetter || c.isNumber)
    }
}
