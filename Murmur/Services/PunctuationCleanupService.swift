import Foundation
import os

// MARK: - Protocol

/// Transforms raw transcription text by improving punctuation and casing.
/// Implementations are always `Sendable` so they can be stored on the
/// `@MainActor`-isolated `AppCoordinator` and called from async contexts.
///
/// v0.3.0 contract:
/// - English: sentence-initial capitalisation, terminal period, standalone "i" → "I", whitespace trim.
/// - Chinese: terminal full-width period, ASCII-to-full-width terminal conversion, whitespace trim.
/// - Japanese / Korean: passthrough — no rules applied.
/// - Unknown language codes: passthrough.
///
/// v0.3.1 will replace the rule-based implementations with an ONNX classifier
/// that handles EN + ZH (and adds JA/KO) via the SentencePiece tokenizer path.
protocol TranscriptionCleanup: Sendable {
    /// Improve `text` according to the rules for `language` (BCP-47 primary subtag,
    /// e.g. `"en"`, `"zh"`, `"ja"`).
    ///
    /// - Parameters:
    ///   - text: Raw transcription text as emitted by the ASR engine.
    ///   - language: Resolved BCP-47 primary language code.
    /// - Returns: Cleaned text, or the original `text` when no rules apply.
    /// - Throws: Any error from a backing model (not applicable to the rule-based
    ///   implementation, but callers must be prepared for classifier errors in v0.3.1).
    func improve(_ text: String, language: String) async throws -> String
}

// MARK: - Rule-based implementation (v0.3.0)

/// Rule-based punctuation cleaner for English and Chinese transcription output.
///
/// Rules applied when `language == "en"` (in application order):
/// 1. Trim leading/trailing whitespace.
/// 2. Early-return on empty/whitespace-only string.
/// 3. Replace standalone `i` (word-boundary match, case-insensitive) with `I`.
///    No other word substitutions — DA 102 #B prohibits a proper-noun gazetteer.
/// 4. Capitalise the first character of the trimmed text.
/// 5. After `.`, `?`, `!` followed by one or more whitespace characters,
///    capitalise the immediately following letter.
/// 6. Append a terminal `.` if the text does not end in `.?!…:;`.
///    Quote characters are not in the suppression set — see `terminalPunctuation`.
///
/// Rules applied when `language == "zh"` (in application order):
/// 1. Trim leading/trailing whitespace (including the U+3000 ideographic space).
/// 2. Early-return on empty/whitespace-only string.
/// 3. If the final character is an ASCII terminal `.` `?` or `!`, replace it
///    with the full-width Chinese equivalent (`。` `？` `！`). Mid-text ASCII
///    punctuation is left alone — it may belong to embedded Latin text
///    (e.g. "我用 Python 3.11").
/// 4. Append `。` if the text does not already end in a recognised terminal
///    character (CJK or Western terminal punctuation, or a closing CJK
///    quote/bracket — see `zhTerminalPunctuation`).
///
/// `ja`, `ko`, and any other language code passthrough unchanged. JA support
/// is plausible (uses the same `。` and `？！`) but reserved for the v0.3.1
/// classifier sweep.
///
/// All operations are pure Swift — no regex libraries, no network, no disk I/O.
actor PunctuationCleanupService: TranscriptionCleanup {
    private static let log = Logger(subsystem: "com.murmur.app", category: "cleanup")

    /// Characters that suppress the auto-appended terminal period in EN cleanup.
    /// Quotes are intentionally excluded: `"hello"` → `"hello".` is more
    /// readable than `"hello"` with no terminal period. Quoted dialog is rare
    /// in dictation output, and ending without a period looks worse than an
    /// extra one inside the closing quote (American-style placement).
    private static let terminalPunctuation: Set<Character> = [
        ".", "?", "!", "…", ":", ";",
    ]

    /// Characters that suppress the auto-appended `。` in ZH cleanup.
    /// Includes full-width CJK terminals, Western terminals (in case
    /// the source text already mixed scripts), and closing CJK
    /// quotes/brackets where appending `。` would be visually awkward.
    private static let zhTerminalPunctuation: Set<Character> = [
        // Full-width CJK terminals
        "。", "？", "！", "…", "：", "；",
        // Western terminals (mixed-script input)
        ".", "?", "!", ":", ";",
        // Closing CJK quotes / brackets — treat as terminal
        "」", "』", "）", "】", "》", "〉",
    ]

    /// Map ASCII-terminal characters to their full-width CJK equivalents.
    /// Applied only at end-of-text in ZH cleanup; mid-text positions are
    /// handled by `asciiToFullWidthMidText` with a CJK-context check so
    /// embedded Latin numerics like "Python 3.11" stay intact.
    private static let asciiToFullWidthTerminal: [Character: Character] = [
        ".": "。",
        "?": "？",
        "!": "！",
    ]

    /// Map ASCII punctuation that appears MID-TEXT to its full-width CJK
    /// equivalent. Includes comma, semicolon, and colon in addition to the
    /// terminal characters because these are common clause separators that
    /// Cohere sometimes emits as ASCII when transcribing Chinese.
    private static let asciiToFullWidthMidText: [Character: Character] = [
        ",": "，",
        ".": "。",
        "?": "？",
        "!": "！",
        ";": "；",
        ":": "：",
    ]

    /// Sentence-final particles that mark a question in Mandarin. When a
    /// Chinese sentence with no explicit terminal punctuation ends with one
    /// of these, the appended terminal must be `？`, not `。`. These three
    /// particles are unambiguously interrogative in sentence-final position.
    private static let zhSentenceFinalQuestionParticles: Set<Character> = [
        "吗",   // standard yes/no
        "呢",   // continuing/follow-up question
        "么",   // informal yes/no (eg 是么, 真么)
    ]

    /// Multi-character interrogative words. If any of these appears anywhere
    /// in the sentence and there is no explicit terminal punctuation, treat
    /// the sentence as a question. Single-character question words (谁, 哪,
    /// 几) are deliberately excluded — too many false positives in compounds
    /// like 几乎 / 哪怕 / 谁知道 (rhetorical).
    private static let zhMultiCharQuestionWords: [String] = [
        "什么", "怎么", "怎样", "为什么", "为何",
        "多少", "哪里", "哪儿", "哪个", "哪些",
        "是不是", "对不对", "有没有", "行不行", "好不好", "可不可以", "能不能",
    ]

    func improve(_ text: String, language: String) async throws -> String {
        switch language {
        case "en":
            return applyEnglishRules(to: text)
        case "zh":
            return applyChineseRules(to: text)
        default:
            // ja, ko, and unknown codes passthrough in v0.3.0.
            return text
        }
    }

    // MARK: - Private helpers

    /// Applies all EN rules to `text` and returns the cleaned result.
    private func applyEnglishRules(to text: String) -> String {
        // Rule 1: Trim whitespace.
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // Rule 2: Empty / whitespace-only → return early (no period, no casing).
        guard !trimmed.isEmpty else { return trimmed }

        // Rule 3: Replace standalone "i" with "I".
        var working = replaceStandaloneI(in: trimmed)

        // Rule 4: Sentence-initial capitalisation.
        working = capitalizeFirst(of: working)

        // Rule 5: Capitalise first letter after terminal punctuation + whitespace.
        working = capitalizeAfterTerminalPunctuation(in: working)

        // Rule 6: Append terminal period if needed.
        working = appendTerminalPeriodIfNeeded(to: working)

        return working
    }

    /// Replaces each occurrence of the standalone word "i" (any case) with "I".
    ///
    /// "Standalone" means the character is not part of a longer word: preceded by
    /// start-of-string or a non-word character, and followed by end-of-string or a
    /// non-word character. We walk the string character by character so we never
    /// touch "in", "it", "this", etc.
    private func replaceStandaloneI(in text: String) -> String {
        var result = text
        var searchRange = result.startIndex..<result.endIndex

        while !searchRange.isEmpty {
            // Find the next occurrence of "i" or "I" in the remaining range.
            guard let iRange = result.range(
                of: "i",
                options: [.caseInsensitive],
                range: searchRange
            ) else { break }

            let before = iRange.lowerBound
            let after = iRange.upperBound

            // Check left boundary: start-of-string or a non-word character.
            let leftOK: Bool
            if before == result.startIndex {
                leftOK = true
            } else {
                let prevIndex = result.index(before: before)
                leftOK = !result[prevIndex].isLetter && !result[prevIndex].isNumber
            }

            // Check right boundary: end-of-string or a non-word character.
            let rightOK: Bool
            if after == result.endIndex {
                rightOK = true
            } else {
                rightOK = !result[after].isLetter && !result[after].isNumber
            }

            if leftOK && rightOK {
                result.replaceSubrange(iRange, with: "I")
                // After replacement the range is 1 character wide ("I") — move past it.
                searchRange = result.index(iRange.lowerBound, offsetBy: 1)..<result.endIndex
            } else {
                // Not standalone; skip past this character.
                searchRange = after..<result.endIndex
            }
        }
        return result
    }

    /// Capitalises the first Unicode scalar of `text` that is a letter.
    private func capitalizeFirst(of text: String) -> String {
        guard let firstIndex = text.indices.first else { return text }
        let firstChar = text[firstIndex]
        let upper = String(firstChar).uppercased()
        return upper + text[text.index(after: firstIndex)...]
    }

    /// Capitalises the first letter that follows `.`, `?`, or `!` and one or
    /// more whitespace characters.
    ///
    /// Walks the string manually to avoid importing any regex library.
    private func capitalizeAfterTerminalPunctuation(in text: String) -> String {
        // Terminal punctuation characters that trigger sentence-initial casing.
        let sentenceEnders: Set<Character> = [".", "?", "!"]

        var chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if sentenceEnders.contains(c) {
                // Skip any following whitespace.
                var j = i + 1
                while j < chars.count && chars[j].isWhitespace {
                    j += 1
                }
                // Capitalise the first letter we find.
                if j < chars.count && chars[j].isLetter {
                    let upper = String(chars[j]).uppercased()
                    // FIXME(v0.3.1): String.uppercased() can produce multi-scalar output
                    // (e.g. ß → SS); current code drops the second character. EN-only
                    // transcription output makes this practically unreachable, but the
                    // classifier path in v0.3.1 should not rely on this.
                    if let first = upper.first {
                        chars[j] = first
                    }
                }
                i = j
            } else {
                i += 1
            }
        }
        return String(chars)
    }

    /// Appends "." to `text` if its last non-whitespace character is not already
    /// a recognised terminal punctuation character.
    private func appendTerminalPeriodIfNeeded(to text: String) -> String {
        // Find the last non-whitespace character.
        guard let lastChar = text.last(where: { !$0.isWhitespace }) else { return text }
        if Self.terminalPunctuation.contains(lastChar) { return text }
        return text + "."
    }

    /// Applies all ZH rules to `text` and returns the cleaned result.
    private func applyChineseRules(to text: String) -> String {
        // Rule 1: Trim whitespace. `.whitespacesAndNewlines` covers the U+3000
        // ideographic space that occasionally leaks through from CJK-locale ASR.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Rule 2: Empty / whitespace-only → return early.
        guard !trimmed.isEmpty else { return trimmed }

        // Rule 3: Convert ASCII punctuation to its full-width CJK equivalent
        // at any position where BOTH adjacent non-whitespace characters are
        // CJK ideographs. This catches Cohere outputs like "我去北京,然后吃饭"
        // → "我去北京，然后吃饭" while leaving "Python 3.11" and "Mr. Smith"
        // alone (their punctuation is between Latin/digit characters).
        var working = convertMidTextAsciiPunctuation(in: trimmed)

        // Rule 4: Replace ASCII terminal `.?!` at end-of-text with full-width
        // equivalent. (Mid-text occurrences were already handled by Rule 3
        // when surrounded by CJK; this catches the end-of-text case where
        // there's only one neighbour to inspect.)
        // Special case: if the text reads as a question but Cohere put a
        // period, upgrade `.` → `？` instead of `。`.
        if let last = working.last,
           let fullWidth = Self.asciiToFullWidthTerminal[last] {
            working.removeLast()
            if last == "." && Self.looksLikeChineseQuestion(working) {
                working.append("？")
            } else {
                working.append(fullWidth)
            }
        }

        // Rule 5: Append a terminal punctuation if the text does not already
        // end in one (CJK, Western, or closing quote/bracket). Pick `？` for
        // questions, `。` for statements.
        if let last = working.last, !Self.zhTerminalPunctuation.contains(last) {
            working.append(Self.looksLikeChineseQuestion(working) ? "？" : "。")
        }

        return working
    }

    /// Heuristic: does this Chinese text end / read as a question? Used to
    /// pick `？` over `。` when appending a missing terminal.
    ///
    /// Two conservative signals — only one needs to fire:
    /// 1. Last non-whitespace character is a sentence-final question
    ///    particle (吗 / 呢 / 么).
    /// 2. The text contains an unambiguous multi-character interrogative
    ///    (什么, 怎么, 为什么, 是不是, 有没有, …). Single-char question
    ///    words like 谁/哪/几 are NOT included because compounds (几乎,
    ///    哪怕, 谁知道) generate too many false positives.
    static func looksLikeChineseQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let last = trimmed.last, zhSentenceFinalQuestionParticles.contains(last) {
            return true
        }
        for word in zhMultiCharQuestionWords where trimmed.contains(word) {
            return true
        }
        return false
    }

    /// Walks `text` and converts each ASCII punctuation character (`, . ? ! ; :`)
    /// to its full-width CJK equivalent IFF the immediately preceding and
    /// following non-whitespace characters are CJK ideographs. Single-side
    /// CJK neighbour is not enough — that protects against false positives
    /// at script boundaries (e.g. `我用 Python` should keep `Python` intact;
    /// `Python.` at end of a Chinese sentence is handled by Rule 4 instead).
    private func convertMidTextAsciiPunctuation(in text: String) -> String {
        let chars = Array(text)
        var result: [Character] = []
        result.reserveCapacity(chars.count)

        for i in 0..<chars.count {
            let c = chars[i]
            guard let fullWidth = Self.asciiToFullWidthMidText[c] else {
                result.append(c)
                continue
            }
            // Walk outward through whitespace to find the nearest non-whitespace
            // neighbours on both sides. Whitespace between a CJK char and ASCII
            // punctuation is rare but possible.
            let prevCJK = nearestNonWhitespace(chars: chars, from: i, direction: -1).map(Self.isCJKIdeograph) ?? false
            let nextCJK = nearestNonWhitespace(chars: chars, from: i, direction: +1).map(Self.isCJKIdeograph) ?? false
            if prevCJK && nextCJK {
                result.append(fullWidth)
            } else {
                result.append(c)
            }
        }
        return String(result)
    }

    /// Look up the nearest non-whitespace character in `chars` starting from
    /// `from + direction`. Returns nil if we run off the array.
    private func nearestNonWhitespace(chars: [Character], from: Int, direction: Int) -> Character? {
        var i = from + direction
        while i >= 0 && i < chars.count {
            if !chars[i].isWhitespace { return chars[i] }
            i += direction
        }
        return nil
    }

    /// True for characters in the main CJK Unified Ideographs blocks. Does
    /// NOT include CJK punctuation, hiragana/katakana, or Hangul — we only
    /// want to identify "this is Chinese-text context."
    private static func isCJKIdeograph(_ c: Character) -> Bool {
        for scalar in c.unicodeScalars {
            let v = scalar.value
            if (v >= 0x4E00 && v <= 0x9FFF) ||         // CJK Unified Ideographs
               (v >= 0x3400 && v <= 0x4DBF) ||         // CJK Ext A
               (v >= 0x20000 && v <= 0x2A6DF) ||       // CJK Ext B
               (v >= 0xF900 && v <= 0xFAFF) {          // CJK Compatibility
                return true
            }
        }
        return false
    }
}
