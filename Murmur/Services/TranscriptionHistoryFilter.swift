import Foundation

/// Pure, stateless filter for TranscriptionEntry collections.
///
/// Extracted from the sidebar view so it can be unit-tested independently
/// without instantiating any SwiftUI views.
enum TranscriptionHistoryFilter {

    /// Filter `entries` by `query`.
    ///
    /// - Returns all entries when query is empty or whitespace-only.
    /// - Performs a case-insensitive, diacritic-insensitive substring search
    ///   against `entry.text`.
    /// - Preserves original order.
    static func filter(
        _ entries: [TranscriptionEntry],
        query: String
    ) -> [TranscriptionEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { entry in
            entry.text.range(
                of: trimmed,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }
}
