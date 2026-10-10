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

// MARK: MockTextInjectionService

final class MockTextInjectionService: TextInjectionServiceProtocol,
                                       StreamingTextInjectionProtocol,
                                       @unchecked Sendable {
    var stubbedInjectMethod: InjectionMethod = .clipboard
    var stubbedAppendText: (() -> Void)?
    var stubbedReplaceRange: (() -> Void)?
    var stubbedError: Error?

    private(set) var appendedTexts: [String] = []
    private(set) var replaceRangeCalls: [(start: Int, length: Int, text: String)] = []

    func inject(text: String) async throws -> InjectionMethod {
        if let err = stubbedError { throw err }
        return stubbedInjectMethod
    }

    func undoLastInjection() async throws {}

    func appendText(_ text: String) async throws {
        if let err = stubbedError { throw err }
        guard !text.isEmpty else { return }   // mirrors real implementation guard
        appendedTexts.append(text)
        stubbedAppendText?()
    }

    func replaceRange(start: Int, length: Int, with text: String) async throws {
        if let err = stubbedError { throw err }
        replaceRangeCalls.append((start: start, length: length, text: text))
        stubbedReplaceRange?()
    }
}
