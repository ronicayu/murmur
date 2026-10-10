import Foundation
@testable import Murmur

// Test doubles for the streaming flow. They live here because more than one
// test file uses them.

// MARK: MockTranscriptionService

final class MockTranscriptionService: TranscriptionServiceProtocol, @unchecked Sendable {
    var stubbedResult: TranscriptionResult = TranscriptionResult(
        text: "mock text",
        language: .english,
        durationMs: 500
    )
    var stubbedError: Error?
    var isModelLoaded: Bool = false
    /// Optional per-call override — returns a different result for each sequential call.
    var onTranscribe: ((URL) throws -> TranscriptionResult)?

    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult {
        if let err = stubbedError { throw err }
        // Clean up the temp file like the real service does
        try? FileManager.default.removeItem(at: audioURL)
        if let handler = onTranscribe {
            return try handler(audioURL)
        }
        return stubbedResult
    }

    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        if let err = stubbedError { throw err }
        return stubbedResult
    }

    func preloadModel() async throws {}
    func unloadModel() async {}
}

// MARK: PreviewRecorder

/// Records what a streaming session reports to its preview. Each report is
/// the whole streamed text so far.
final class PreviewRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [String] = []

    var texts: [String] { lock.withLock { reports } }
    var latest: String { lock.withLock { reports.last ?? "" } }

    func record(_ text: String) {
        lock.withLock { reports.append(text) }
    }
}
