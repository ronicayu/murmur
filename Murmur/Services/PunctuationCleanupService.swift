import Foundation
import os

// MARK: - Protocol

/// Transforms raw transcription text by improving punctuation and casing.
/// Implementations are always `Sendable` so they can be stored on the
/// `@MainActor`-isolated `AppCoordinator` and called from async contexts.
///
/// v0.3.0 contract:
/// - English: sentence-initial capitalisation, terminal period, standalone "i" → "I", whitespace trim.
/// - Chinese / Japanese / Korean: passthrough — no rules applied.
/// - Unknown language codes: passthrough.
///
/// v0.3.1 will replace the rule-based implementation with an ONNX classifier
/// that handles EN + ZH via the SentencePiece tokenizer path.
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

/// Rule-based English punctuation and casing cleaner.
///
/// Rules applied when `language == "en"` (in application order):
/// 1. Trim leading/trailing whitespace.
/// 2. Early-return on empty/whitespace-only string.
/// 3. Replace standalone `i` (word-boundary match, case-insensitive) with `I`.
///    No other word substitutions — DA 102 #B prohibits a proper-noun gazetteer.
/// 4. Capitalise the first character of the trimmed text.
/// 5. After `.`, `?`, `!` followed by one or more whitespace characters,
///    capitalise the immediately following letter.
/// 6. Append a terminal `.` if the text does not end in `.?!…:;` or a
///    typographic/ASCII quote character.
///
/// For `zh`, `ja`, `ko`, or any other language code the input is returned
/// unchanged. ZH rules land in v0.3.1 with the ONNX classifier.
///
/// All operations are pure Swift — no regex libraries, no network, no disk I/O.
actor PunctuationCleanupService: TranscriptionCleanup {
    private static let log = Logger(subsystem: "com.murmur.app", category: "cleanup")

    /// Characters that suppress the auto-appended terminal period.
    /// Includes ASCII and typographic variants of quotes.
    private static let terminalPunctuation: Set<Character> = [
        ".", "?", "!", "…", ":", ";",
        "\"", "'",
        "\u{201C}", "\u{201D}",  // " "
        "\u{2018}", "\u{2019}",  // ' '
    ]

    func improve(_ text: String, language: String) async throws -> String {
        // Only English rules are applied in v0.3.0. Every other language is a
        // passthrough; ZH support lands in v0.3.1 once the ONNX classifier and
        // SentencePiece tokenizer are integrated.
        guard language == "en" else { return text }
        return applyEnglishRules(to: text)
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
}
