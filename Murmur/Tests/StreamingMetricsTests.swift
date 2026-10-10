import AVFoundation
import XCTest
@testable import Murmur

// Phase 5: the streaming coordinator's own measurements. These assert the
// accessors AppCoordinator snapshots at end-of-session — no models, no audio
// engine, light tier.

@MainActor
final class StreamingMetricsTests: XCTestCase {

    private func makeCoordinator() -> StreamingTranscriptionCoordinator {
        StreamingTranscriptionCoordinator(
            transcription: MockTranscriptionService()
        )
    }

    private func createMinimalWAV(at url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buf.frameLength = 160
        try file.write(from: buf)
    }

    func test_timeToFirstWord_isNil_beforeAnySession() {
        let coord = makeCoordinator()
        XCTAssertNil(coord.timeToFirstWordMs,
            "No session has run, so there is no measurement to report")
    }

    func test_editDistanceRatio_isNil_beforeFullPass() {
        let coord = makeCoordinator()
        XCTAssertNil(coord.lastEditDistanceRatio,
            "Edit distance is only known once the closing full pass runs")
    }

    func test_timeToFirstWord_isNil_whenSessionStreamedNothing() throws {
        // A session that begins but never confirms a stable prefix (too short,
        // or CPU fallback) must report nil rather than a bogus 0.
        let coord = makeCoordinator()
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("metrics_\(UUID().uuidString).wav")
        try createMinimalWAV(at: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        _ = coord.beginSession(
            language: "en", fullWavURL: wav,
            onPreviewText: { _ in }
        )

        XCTAssertNotNil(coord.sessionStartedAt,
            "beginSession must stamp the session start")
        XCTAssertNil(coord.firstDeltaAt,
            "Nothing was streamed yet")
        XCTAssertNil(coord.timeToFirstWordMs,
            "Time-to-first-word is undefined until a delta actually lands")
    }

    func test_beginSession_resetsMeasurementsFromPriorSession() throws {
        let coord = makeCoordinator()
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("metrics_\(UUID().uuidString).wav")
        try createMinimalWAV(at: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        _ = coord.beginSession(
            language: "en", fullWavURL: wav,
            onPreviewText: { _ in }
        )
        let firstStart = coord.sessionStartedAt
        coord.cancelSession()
        coord.resetToIdle()

        _ = coord.beginSession(
            language: "en", fullWavURL: wav,
            onPreviewText: { _ in }
        )

        XCTAssertNotNil(coord.sessionStartedAt)
        XCTAssertNotEqual(coord.sessionStartedAt, firstStart,
            "A new session must re-stamp its start, not inherit the previous one")
        XCTAssertNil(coord.lastEditDistanceRatio,
            "Stale edit distance from a prior session must not leak forward")
        XCTAssertNil(coord.timeToFirstWordMs)
    }

    func test_finalizingStartedAt_isNotInheritedFromPriorSession() async throws {
        let coord = makeCoordinator()
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("metrics_\(UUID().uuidString).wav")
        try createMinimalWAV(at: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        _ = coord.beginSession(
            language: "en", fullWavURL: wav,
            onPreviewText: { _ in }
        )
        coord.endSession()
        let done = await pollUntil(timeout: 5) { coord.sessionState == .done }
        XCTAssertTrue(done)
        XCTAssertNotNil(coord.finalizingStartedAt,
            "endSession must stamp the start of the finalizing phase")
        coord.resetToIdle()

        // The second session is cancelled before it ever finalises.
        _ = coord.beginSession(
            language: "en", fullWavURL: wav,
            onPreviewText: { _ in }
        )
        coord.cancelSession()

        XCTAssertNil(coord.finalizingStartedAt,
            "A session that never finalised must not report the previous session's value")
    }

}
