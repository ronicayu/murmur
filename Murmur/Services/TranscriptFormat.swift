import Foundation

/// Text forms of a time-stamped transcript.
enum TranscriptFormat {
    /// `UserDefaults` key: show and export time stamps with a transcript.
    static let showTimestampsKey = "transcriptShowTimestamps"

    /// `mm:ss`, or `h:mm:ss` when `withHours` (any time in the transcript
    /// reaches an hour, so all stamps line up).
    static func timestamp(_ seconds: TimeInterval, withHours: Bool) -> String {
        let total = max(0, Int(seconds))
        return withHours
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// One line per segment, `[mm:ss] text`, with a blank line before each
    /// paragraph.
    static func timestampedText(_ segments: [TranscriptSegment]) -> String {
        let withHours = (segments.last?.start ?? 0) >= 3600
        var lines: [String] = []
        for segment in segments {
            if segment.startsParagraph, !lines.isEmpty { lines.append("") }
            lines.append("[\(timestamp(segment.start, withHours: withHours))] \(segment.text)")
        }
        return lines.joined(separator: "\n")
    }

    /// The transcript as SubRip subtitles: one cue per segment.
    static func srt(_ segments: [TranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(srtTime(segment.start)) --> \(srtTime(max(segment.end, segment.start)))\n\(segment.text)\n"
        }.joined(separator: "\n")
    }

    /// `hh:mm:ss,mmm`
    static func srtTime(_ seconds: TimeInterval) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}

extension TranscriptionEntry {
    /// Whether the entry has time stamps to show.
    var hasTimestamps: Bool { !(segments ?? []).isEmpty }

    /// The text to show, copy and export: time-stamped when asked for and
    /// the entry has time stamps, otherwise the plain transcript.
    func displayText(withTimestamps: Bool) -> String {
        guard withTimestamps, let segments, !segments.isEmpty else { return text }
        return TranscriptFormat.timestampedText(segments)
    }
}
