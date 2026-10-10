import Foundation

/// Pure, stateless filter for transcription history.
///
/// Extracted from the sidebar view so it can be unit-tested independently
/// without instantiating any SwiftUI views. Both history surfaces use the
/// same matching semantics: the transcription window's sidebar (persisted
/// `TranscriptionEntry` records) and the menu-bar Recent window (the
/// coordinator's in-memory list).
enum TranscriptionHistoryFilter {

    /// Whether `query` matches any of `fields`.
    ///
    /// - An empty or whitespace-only query matches everything (callers show
    ///   the unfiltered list).
    /// - Matching is case-insensitive and diacritic-insensitive substring
    ///   search, so "cafe" finds "café" and "HELLO" finds "hello".
    ///
    /// Taking several fields lets a caller search both the injected text and
    /// the pre-correction raw text — a user searching for what they *said*
    /// should find the entry even when the corrector rewrote it.
    static func matches(query: String, in fields: String?...) -> Bool {
        matches(query: query, inFields: fields)
    }

    /// Array-taking form, for callers that build the field list dynamically.
    static func matches(query: String, inFields fields: [String?]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return fields.contains { field in
            guard let field else { return false }
            return field.range(
                of: trimmed,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    /// Filter persisted `entries` by `query`.
    ///
    /// - Returns all entries when query is empty or whitespace-only.
    /// - Performs a case-insensitive, diacritic-insensitive substring search
    ///   against `entry.text`.
    /// - Preserves original order.
    static func filter(
        _ entries: [TranscriptionEntry],
        query: String
    ) -> [TranscriptionEntry] {
        entries.filter { matches(query: query, in: $0.text) }
    }
}
