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
    /// Applied only at end-of-text in ZH cleanup; mid-text positions are left
    /// alone to avoid mangling embedded Latin numerics like "Python 3.11".
    private static let asciiToFullWidthTerminal: [Character: Character] = [
        ".": "。",
        "?": "？",
        "!": "！",
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

        // Rule 3: Replace ASCII terminal `.?!` at end-of-text with full-width
        // equivalent. We deliberately do not touch mid-text ASCII punctuation
        // because it may belong to an embedded Latin fragment (e.g. version
        // numbers, English brand names).
        var working = trimmed
        if let last = working.last,
           let fullWidth = Self.asciiToFullWidthTerminal[last] {
            working.removeLast()
            working.append(fullWidth)
        }

        // Rule 4: Append `。` if text does not already end in a terminal
        // (CJK, Western, or closing quote/bracket).
        if let last = working.last, !Self.zhTerminalPunctuation.contains(last) {
            working.append("。")
        }

        return working
    }
}
