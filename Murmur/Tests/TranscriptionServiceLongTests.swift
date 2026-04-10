import XCTest
import Foundation
@testable import Murmur

// MARK: - TranscriptionServiceLong Tests
//
// Tests for TranscriptionService.transcribeLong() — chunked long-audio transcription.
//
// Testing approach:
//   TranscriptionService is an actor wrapping a Python subprocess. To avoid
//   spawning a real Python process in tests, we test the protocol boundary via
//   a fake pipe: we inject synthetic stdout data and verify the Swift layer
//   parses it correctly and calls the right callbacks.
//
//   The test harness uses TranscriptionService's init(pythonPath:scriptPath:)
//   injection points together with a helper that writes JSON lines into the
//   service's stdin pipe from outside, simulating Python responses.
//
// Run: xcodebuild test -scheme Murmur -only-testing MurmurTests/TranscriptionServiceLongTests

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

// MARK: - PipeSimulator
//
// Drives a TranscriptionService through a synthetic pipe without a real Python
// process. The simulator:
//   1. Creates a Pipe pair.
//   2. Passes the read-end to TranscriptionService as its stdout pipe.
//   3. Writes JSON lines into the write-end to simulate Python output.
//
// Because TranscriptionService's subprocess management is private, we use
// a subclass hook approach: TranscriptionServiceTestable exposes a method
// to prime its pipe with test data. See implementation below.

/// Drives JSON lines into a pipe that a TranscriptionService reads from.
///
/// Usage:
///   let sim = PipeSimulator()
///   sim.writeLines([
///       #"{"type":"progress","chunk":1,"total":3,"text":"Hello"}"#,
///       #"{"type":"result","text":"Hello world","language":"en","duration_ms":500,"chunks":3}"#
///   ])
///   sim.closeWrite()  // signals EOF to the reading side
final class PipeSimulator {
    let pipe = Pipe()

    func writeLine(_ json: String) {
        let data = (json + "\n").data(using: .utf8)!
        try? pipe.fileHandleForWriting.write(contentsOf: data)
    }

    func writeLines(_ lines: [String]) {
        lines.forEach { writeLine($0) }
    }

    func closeWrite() {
        try? pipe.fileHandleForWriting.close()
    }
}

// MARK: - TranscriptionServiceTestable
//
// An actor subclass (identical API to TranscriptionService) that bypasses real
// subprocess creation and instead uses injected Pipe objects.
// This lets us test sendLong / transcribeLong without Python.

// NOTE: Because TranscriptionService is a non-open actor, we cannot subclass it.
// Instead, TranscriptionServiceTestable is a parallel actor that re-implements
// only the parts under test and is driven by the same JSON protocol.
// The real TranscriptionService integration (actual subprocess) is validated
// by integration tests that require Python — those live in separate test targets.

// MARK: - sendLong parsing tests

final class SendLongParsingTests: XCTestCase {

    // MARK: Helpers

    /// Build a JSON line for a progress event.
    private func progressLine(chunk: Int, total: Int, text: String) -> String {
        #"{"type":"progress","chunk":\#(chunk),"total":\#(total),"text":"\#(text)"}"#
    }

    /// Build a JSON line for a result event.
    private func resultLine(text: String, language: String = "en", durationMs: Int = 500, chunks: Int = 3) -> String {
        #"{"type":"result","text":"\#(text)","language":"\#(language)","duration_ms":\#(durationMs),"chunks":\#(chunks)}"#
    }

    // MARK: Tests

    /// sendLong must invoke onProgress for every progress-type JSON line.
    func test_sendLong_callsOnProgressForEachProgressEvent() async throws {
        // Arrange
        let sim = PipeSimulator()
        let parser = JSONLineParser(pipe: sim.pipe)

        let lines = [
            progressLine(chunk: 1, total: 3, text: "Hello"),
            progressLine(chunk: 2, total: 3, text: "Hello world"),
            progressLine(chunk: 3, total: 3, text: "Hello world again"),
            resultLine(text: "Hello world again"),
        ]
        sim.writeLines(lines)
        sim.closeWrite()

        var progressEvents: [TranscriptionProgress] = []

        // Act
        let result = try await parser.readUntilResult(onProgress: { event in
            progressEvents.append(event)
        })

        // Assert — three progress callbacks before final result
        XCTAssertEqual(progressEvents.count, 3)
        XCTAssertEqual(progressEvents[0].currentChunk, 1)
        XCTAssertEqual(progressEvents[1].currentChunk, 2)
        XCTAssertEqual(progressEvents[2].currentChunk, 3)
        XCTAssertEqual(progressEvents[2].partialText, "Hello world again")
        XCTAssertEqual(result.text, "Hello world again")
    }

    /// sendLong must return a TranscriptionResult from the type=result line.
    func test_sendLong_returnsResultFromFinalResultLine() async throws {
        // Arrange
        let sim = PipeSimulator()
        let parser = JSONLineParser(pipe: sim.pipe)

        sim.writeLines([
            progressLine(chunk: 1, total: 1, text: "Partial"),
            resultLine(text: "Final text", language: "zh", durationMs: 12345, chunks: 1),
        ])
        sim.closeWrite()

        // Act
        let result = try await parser.readUntilResult(onProgress: { _ in })

        // Assert
        XCTAssertEqual(result.text, "Final text")
        XCTAssertEqual(result.language, .chinese)
        XCTAssertEqual(result.durationMs, 12345)
    }

    /// sendLong must throw when Python sends an error field.
    func test_sendLong_throwsWhenResultContainsErrorField() async throws {
        // Arrange
        let sim = PipeSimulator()
        let parser = JSONLineParser(pipe: sim.pipe)

        sim.writeLine(#"{"error":"Model not loaded"}"#)
        sim.closeWrite()

        // Act + Assert
        do {
            _ = try await parser.readUntilResult(onProgress: { _ in })
            XCTFail("Expected throw but no error was thrown")
        } catch let error as MurmurError {
            if case .transcriptionFailed(let msg) = error {
                XCTAssertTrue(msg.contains("Model not loaded"), "Error message should contain Python error text")
            } else {
                XCTFail("Expected transcriptionFailed, got \(error)")
            }
        }
    }

    /// sendLong must throw when stdout closes before a result event arrives.
    func test_sendLong_throwsWhenStdoutClosesPrematurely() async throws {
        // Arrange
        let sim = PipeSimulator()
        let parser = JSONLineParser(pipe: sim.pipe)

        // Write only a progress event, then close (no result)
        sim.writeLine(progressLine(chunk: 1, total: 3, text: "Partial"))
        sim.closeWrite()

        // Act + Assert
        do {
            _ = try await parser.readUntilResult(onProgress: { _ in })
            XCTFail("Expected throw due to premature EOF")
        } catch {
            // Any error is acceptable — the important thing is it doesn't hang
            XCTAssertNotNil(error)
        }
    }

    /// sendLong must handle a result that arrives with no preceding progress events.
    func test_sendLong_handlesResultWithNoProgressEvents() async throws {
        // Arrange
        let sim = PipeSimulator()
        let parser = JSONLineParser(pipe: sim.pipe)

        sim.writeLine(resultLine(text: "Direct result", durationMs: 100, chunks: 1))
        sim.closeWrite()

        var progressCount = 0

        // Act
        let result = try await parser.readUntilResult(onProgress: { _ in progressCount += 1 })

        // Assert
        XCTAssertEqual(progressCount, 0, "No progress events should be reported for a single-chunk result")
        XCTAssertEqual(result.text, "Direct result")
    }

    /// sendLong must forward partialText from the progress event correctly.
    func test_sendLong_progressEventContainsCorrectPartialText() async throws {
        // Arrange
        let sim = PipeSimulator()
        let parser = JSONLineParser(pipe: sim.pipe)

        let expectedPartial = "The quick brown fox"
        sim.writeLines([
            progressLine(chunk: 1, total: 2, text: expectedPartial),
            resultLine(text: "The quick brown fox jumps"),
        ])
        sim.closeWrite()

        var capturedProgress: TranscriptionProgress?

        // Act
        _ = try await parser.readUntilResult(onProgress: { event in
            capturedProgress = event
        })

        // Assert
        XCTAssertEqual(capturedProgress?.partialText, expectedPartial)
        XCTAssertEqual(capturedProgress?.totalChunks, 2)
    }
}

// MARK: - JSONLineParser
//
// Extracted read-until-result logic, testable independently of the actor.
// TranscriptionService.sendLong() will delegate to this same logic.
//
// This is a value-type helper that operates on a Pipe's reading handle.
// It lives here (alongside tests) for now; implementation moves to
// TranscriptionService.swift in GREEN phase.

// NOTE: The parser stub is declared here so the RED phase tests compile
// with an expected failure. The real implementation is in TranscriptionService.swift.

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
