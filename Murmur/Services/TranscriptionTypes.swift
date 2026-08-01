import Foundation

// Shared transcription value types and the service protocol. These used to
// live in TranscriptionService.swift alongside the Python-subprocess bridge;
// they were relocated here when that bridge was deleted so every backend
// (NativeTranscriptionService, FireRedTranscriptionService, test doubles) can
// share them without carrying the dead subprocess code.

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

// Default no-op implementations. Native/FireRed backends load models in-process
// and have no subprocess to swap or kill, so they inherit these; test doubles
// do too. (The historical Python bridge overrode them with real subprocess
// management — that bridge is gone.)
extension TranscriptionServiceProtocol {
    func setModelPath(_ newPath: URL) async {}
    func killProcess() async {}
}
