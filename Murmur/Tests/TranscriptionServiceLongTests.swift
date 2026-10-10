import XCTest
import Foundation
@testable import Murmur

// MARK: - Long transcription: protocol surface and concurrency gate
//
// These tests exercise `transcribeLong` through `TranscriptionServiceProtocol`
// with in-memory fakes; no speech model is loaded.

// MARK: - TranscriptionProgress Sendability

final class TranscriptionProgressSendableTests: XCTestCase {

    /// TranscriptionProgress must be Sendable so it can cross actor boundaries.
    func test_transcriptionProgress_isSendable() {
        // Arrange & Act — constructing a value and capturing it in a detached Task
        // exercises the Sendable constraint at compile time.
        let progress = TranscriptionProgress(
            currentChunk: 3,
            totalChunks: 12,
            partialText: "Hello world"
        )
        let expectation = self.expectation(description: "Sendable across Task boundary")

        Task.detached {
            // This compiles only if TranscriptionProgress: Sendable
            let _ = progress.currentChunk
            expectation.fulfill()
        }

        // Assert — no crash; Sendable conformance is a compile-time property.
        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(progress.currentChunk, 3)
        XCTAssertEqual(progress.totalChunks, 12)
        XCTAssertEqual(progress.partialText, "Hello world")
    }

    /// TranscriptionProgress fields map correctly to their JSON source fields.
    func test_transcriptionProgress_fieldsAreCorrect() {
        // Arrange
        let currentChunk = 7
        let totalChunks = 20
        let partialText = "Transcribed text so far"

        // Act
        let progress = TranscriptionProgress(
            currentChunk: currentChunk,
            totalChunks: totalChunks,
            partialText: partialText
        )

        // Assert
        XCTAssertEqual(progress.currentChunk, currentChunk)
        XCTAssertEqual(progress.totalChunks, totalChunks)
        XCTAssertEqual(progress.partialText, partialText)
    }
}

// MARK: - TranscriptionService Protocol Extension

final class TranscriptionServiceProtocolLongTests: XCTestCase {

    /// TranscriptionServiceProtocol must declare transcribeLong so callers
    /// can depend on the abstraction, not the concrete actor.
    func test_transcriptionServiceProtocol_declaresTranscribeLong() {
        // Arrange — FakeTranscriptionService implements the full protocol
        let service: any TranscriptionServiceProtocol = FakeTranscriptionService()

        // Act — calling transcribeLong via protocol reference must compile
        // (this is a static test; if it compiles, the protocol is correct)
        let expectation = self.expectation(description: "transcribeLong callable via protocol")
        Task {
            _ = try? await service.transcribeLong(
                audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
                language: "en",
                onProgress: { _ in }
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }
}

// MARK: - FakeTranscriptionService (test double)

/// A minimal fake that satisfies TranscriptionServiceProtocol.
/// Used only for protocol-shape tests above; not used for pipe-level tests.
private actor FakeTranscriptionService: TranscriptionServiceProtocol {
    nonisolated var isModelLoaded: Bool { true }

    func preloadModel() async throws {}
    func unloadModel() async {}

    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult {
        TranscriptionResult(text: "fake", language: .english, durationMs: 1)
    }

    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        onProgress(TranscriptionProgress(currentChunk: 1, totalChunks: 1, partialText: "partial"))
        return TranscriptionResult(text: "fake long", language: .english, durationMs: 100)
    }
}

// MARK: - Concurrency guard tests

final class TranscriptionLongConcurrencyTests: XCTestCase {

    /// Only one transcribeLong may run at a time; a second concurrent call
    /// must throw MurmurError.transcriptionFailed("already running").
    func test_transcribeLong_rejectsSecondConcurrentCall() async throws {
        // Arrange
        // P2-3 fix: use a CheckedContinuation as a gate signal so the second
        // call is only issued *after* the first has provably acquired the lock.
        // Previously relied on a 10ms sleep, which is fragile under load.
        let fakeLong = FakeLongTranscriptionGateSignaling()

        // Act — fire first call and wait for it to signal "inside critical section"
        async let first: TranscriptionResult = fakeLong.transcribeLong(
            audioURL: URL(fileURLWithPath: "/tmp/a.wav"),
            language: "en",
            onProgress: { _ in }
        )

        // Wait until first call has entered the gate (no sleep required)
        await fakeLong.waitUntilInside()

        var secondError: Error?
        do {
            _ = try await fakeLong.transcribeLong(
                audioURL: URL(fileURLWithPath: "/tmp/b.wav"),
                language: "en",
                onProgress: { _ in }
            )
        } catch {
            secondError = error
        }

        // Let the first finish
        _ = try await first

        // Assert
        XCTAssertNotNil(secondError, "Second concurrent transcribeLong must throw")
        if let murmurErr = secondError as? MurmurError,
           case .transcriptionFailed(let msg) = murmurErr {
            XCTAssertTrue(
                msg.lowercased().contains("already") || msg.lowercased().contains("running"),
                "Error message should indicate a call is already running, got: \(msg)"
            )
        } else {
            XCTFail("Expected MurmurError.transcriptionFailed, got \(String(describing: secondError))")
        }
    }

    /// After a transcribeLong completes, a subsequent call must succeed (gate released).
    func test_transcribeLong_gateReleasedAfterCompletion() async throws {
        // Arrange
        let fakeLong = FakeLongTranscriptionGate()

        // Act — sequential calls
        _ = try await fakeLong.transcribeLong(
            audioURL: URL(fileURLWithPath: "/tmp/a.wav"),
            language: "en",
            onProgress: { _ in }
        )
        let result = try await fakeLong.transcribeLong(
            audioURL: URL(fileURLWithPath: "/tmp/b.wav"),
            language: "en",
            onProgress: { _ in }
        )

        // Assert — second call must succeed
        XCTAssertEqual(result.text, "fake")
    }
}

// MARK: - FakeLongTranscriptionGate
//
// A minimal actor that implements only the concurrency guard logic being tested.
// Mirrors the guard that TranscriptionService will use.

private actor FakeLongTranscriptionGate {
    private var isLongRunning = false

    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        guard !isLongRunning else {
            throw MurmurError.transcriptionFailed("transcribeLong already running")
        }
        isLongRunning = true
        defer { isLongRunning = false }

        // Simulate async work
        try await Task.sleep(for: .milliseconds(20))
        return TranscriptionResult(text: "fake", language: .english, durationMs: 20)
    }
}

// MARK: - FakeLongTranscriptionGateSignaling
//
// P2-3 fix: same guard logic as FakeLongTranscriptionGate but with an explicit
// "inside critical section" signal. Test uses this to avoid sleep-based timing.

private actor FakeLongTranscriptionGateSignaling {
    private var isLongRunning = false

    /// Continuation fulfilled when the first call enters the critical section.
    /// Nillable so it is only signalled once.
    private var insideContinuation: CheckedContinuation<Void, Never>?
    private var hasSignalled = false

    /// Suspends until the first transcribeLong call has acquired the guard.
    func waitUntilInside() async {
        guard !hasSignalled else { return }
        await withCheckedContinuation { cont in
            insideContinuation = cont
        }
    }

    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        guard !isLongRunning else {
            throw MurmurError.transcriptionFailed("transcribeLong already running")
        }
        isLongRunning = true
        defer { isLongRunning = false }

        // Signal the test that we are now inside the critical section
        if !hasSignalled {
            hasSignalled = true
            insideContinuation?.resume()
            insideContinuation = nil
        }

        // Simulate async work
        try await Task.sleep(for: .milliseconds(20))
        return TranscriptionResult(text: "fake", language: .english, durationMs: 20)
    }
}
