import Foundation

enum DetectedLanguage: String, Sendable {
    case english = "en"
    case chinese = "zh"
    case unknown
}

struct TranscriptionResult: Sendable {
    let text: String
    let language: DetectedLanguage
    let durationMs: Int
    /// Where each part of `text` was said. Only long transcriptions have them.
    var segments: [TranscriptSegment] = []
}

/// One stretch of speech in a long transcription, with its place in the audio.
struct TranscriptSegment: Codable, Equatable, Sendable {
    /// Seconds from the start of the audio to the first speech of the segment.
    let start: TimeInterval
    /// Seconds from the start of the audio to the end of the segment's speech.
    let end: TimeInterval
    let text: String
    /// A long silence comes before this segment, so its text starts a paragraph.
    var startsParagraph = false
}

/// Reports per-chunk progress during a long transcription.
struct TranscriptionProgress: Sendable {
    let currentChunk: Int
    let totalChunks: Int
    let partialText: String
}

protocol TranscriptionServiceProtocol {
    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult
    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult
    func preloadModel() async throws
    func unloadModel() async
    func setModelPath(_ newPath: URL) async
    func killProcess() async
    var isModelLoaded: Bool { get }
    /// Decodes `range` of a 16 kHz mono WAV: one piece of a long recording.
    func transcribePiece(audioURL: URL, range: Range<Int>, language: String) async throws -> String
    /// Whether a dictation can be transcribed while `transcribeLong` runs:
    /// the long transcription gives way between its pieces. When false,
    /// voice input is paused for the whole of a file transcription.
    var yieldsToDictationDuringLongTranscription: Bool { get }
}


// Default no-op implementations for test mocks.
extension TranscriptionServiceProtocol {
    func setModelPath(_ newPath: URL) async {}
    func killProcess() async {}
    func transcribePiece(audioURL: URL, range: Range<Int>, language: String) async throws -> String {
        throw MurmurError.transcriptionFailed("This engine does not decode pieces")
    }
    var yieldsToDictationDuringLongTranscription: Bool { false }
}
