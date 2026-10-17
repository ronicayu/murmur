import Foundation

/// One piece of a long recording, decoded in one go.
struct LongPiece: Equatable, Sendable {
    /// The samples to decode.
    let range: Range<Int>
    /// The stretch of speech the piece belongs to: its speech gives the
    /// segment times, its flag the paragraph break.
    let span: Qwen3TranscriptionService.SpeechSpan
    /// The piece's place among the `count` pieces of its span.
    let index: Int
    let count: Int
}

/// Where a long recording is cut: stretches of speech split at pauses
/// (`speechSpans`), each split into pieces short enough for one decode
/// (`segmentRanges`). The in-process engine and the engine-process client
/// both cut the same way, so their transcripts and time stamps agree.
struct LongPlan: Equatable, Sendable {
    let pieces: [LongPiece]

    init(source: LongAudioSource) throws {
        let loud = try Qwen3TranscriptionService.loudFrames(of: source)
        var pieces: [LongPiece] = []
        for span in Qwen3TranscriptionService.speechSpans(
            loud: loud, sampleCount: source.count, sampleRate: LongAudioSource.sampleRate
        ) {
            try Task.checkCancellation()
            let ranges = try Qwen3TranscriptionService.segmentRanges(of: span.range, in: source)
            for (index, range) in ranges.enumerated() {
                pieces.append(LongPiece(range: range, span: span, index: index, count: ranges.count))
            }
        }
        self.pieces = pieces
    }
}
