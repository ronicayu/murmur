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
}


// Default no-op implementations for test mocks.
extension TranscriptionServiceProtocol {
    func setModelPath(_ newPath: URL) async {}
    func killProcess() async {}
}
