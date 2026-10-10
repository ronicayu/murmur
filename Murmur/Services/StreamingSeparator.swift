import Foundation

/// Pure decision for whether a streaming delta needs a leading space when it is
/// injected at a window boundary.
///
/// Stable-prefix deltas carry their own intra-window spacing (sliced verbatim
/// from the hypothesis). The only place a separator can be missing is across a
/// window-cap boundary, where the aggregator was reset: the first delta of the
/// new window is a fresh hypothesis prefix with no leading space, but it may
/// need one to not run into the previous window's last word.
///
/// Rule: add a single leading space only when
///   1. we are at a window boundary (the aggregator was just reset), AND
///   2. text has already been injected this session (nothing to separate from
///      otherwise), AND
///   3. the delta begins a Latin word (ASCII letter).
///
/// CJK / kana / Hangul, punctuation, and symbols need no separator — Chinese
/// and Japanese text is written without inter-word spaces, and a leading space
/// before a comma or period would be wrong. (Latin words that begin with a
/// digit — "3D" — also get no space; that is a rare boundary case and adding a
/// space mid-number would be worse than joining.)
enum StreamingSeparator {
    static func needsLeadingSpace(
        delta: String,
        atWindowBoundary: Bool,
        hasPriorText: Bool
    ) -> Bool {
        guard atWindowBoundary, hasPriorText, let first = delta.first else {
            return false
        }
        return first.isASCII && first.isLetter
    }
}
