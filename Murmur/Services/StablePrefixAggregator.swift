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

    /// Count of word tokens confirmed (already emitted). Locked — only ever extended
    /// within a window.
    private var confirmedCount = 0
    /// Confirmed text accumulated for the current window (== concatenation of deltas).
    private(set) var confirmedText = ""
    /// Previous hypothesis tokens (for the LocalAgreement comparison).
    private var previousTokens: [Token] = []
    /// Previous hypothesis as a Character array (for tail slicing on flush).
    private var previousChars: [Character] = []
    /// True when the latest pass matched the one before it word for word — the
    /// speaker has paused, so the window can be closed without cutting a word.
    private(set) var lastPassFullyAgreed = false

    // MARK: - API

    /// Feed the latest full-window hypothesis. Returns the text newly confirmed by
    /// this pass (empty if nothing new stabilised — always empty on the first pass,
    /// since LocalAgreement-2 needs two passes to agree).
    @discardableResult
    mutating func ingest(_ hypothesis: String) -> String {
        let chars = Array(hypothesis)
        let current = Self.tokenize(chars)

        // Confirmed words are locked, so only the words after them need to agree.
        // Comparing the locked region again would let a homophone flip there
        // (科隆 / 克隆) block everything that follows it.
        let locked = min(confirmedCount, previousTokens.count, current.count)
        let agreed = locked + Self.commonPrefixLength(
            previousTokens[locked...], current[locked...]
        )
        lastPassFullyAgreed = !current.isEmpty
            && agreed == current.count && agreed == previousTokens.count
        let newConfirmed = min(max(confirmedCount, agreed), current.count)

        let delta = Self.slice(chars: chars, tokens: current,
                               from: confirmedCount, to: newConfirmed)

        confirmedCount = newConfirmed
        confirmedText += delta
        previousTokens = current
        previousChars = chars
        return delta
    }

    /// Confirm the withheld tail of the latest hypothesis (call on a genuine
    /// sentence-final pause or when the window is force-closed) and reset for the
    /// next window. Returns the tail text to inject.
    @discardableResult
    mutating func flushAndReset() -> String {
        // Everything after the last confirmed word, including trailing punctuation.
        var tail = ""
        if confirmedCount <= previousTokens.count {
            let startChar = confirmedCount == 0 ? 0 : previousTokens[confirmedCount - 1].charEnd
            var endChar = previousChars.count
            while endChar > startChar && previousChars[endChar - 1].isWhitespace { endChar -= 1 }
            if startChar < endChar { tail = String(previousChars[startChar..<endChar]) }
        }
        lastPassFullyAgreed = false
        confirmedCount = 0
        confirmedText = ""
        previousTokens = []
        previousChars = []
        return tail
    }

    // MARK: - Tokenisation + slicing

    private static func slice(chars: [Character], tokens: [Token],
                              from: Int, to: Int) -> String {
        guard to > from, from >= 0, to <= tokens.count else { return "" }
        let startChar = from == 0 ? 0 : tokens[from - 1].charEnd
        let endChar = tokens[to - 1].charEnd
        guard startChar <= endChar, endChar <= chars.count else { return "" }
        return String(chars[startChar..<endChar])
    }

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
