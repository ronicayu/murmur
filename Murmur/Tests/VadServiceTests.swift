import XCTest
@testable import Murmur

/// Tests for `VadService`. Anything that actually instantiates the Silero
/// session is heavy (loads the ~2 MB ONNX) and gated behind
/// `TestHeavyGate.requireOptIn()`. Light tests (init failure paths) run
/// unconditionally.
final class VadServiceTests: XCTestCase {

    // MARK: - Light tests (no model required)

    func test_init_throwsForMissingFile() {
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).onnx")
        XCTAssertThrowsError(try VadService(modelURL: bogus)) { err in
            guard case MurmurError.modelNotFound = err else {
                return XCTFail("expected MurmurError.modelNotFound, got \(err)")
            }
        }
    }

    func test_init_rejectsNon16kSampleRate() {
        // Even with a valid path, the service refuses non-16k rates because
        // Silero v5 only operates at 16 kHz. Use any path that exists so we
        // hit the rate check first.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vad-rate-test-\(UUID().uuidString).onnx")
        FileManager.default.createFile(atPath: tmp.path, contents: Data([0x00]))
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertThrowsError(try VadService(modelURL: tmp, sampleRate: 8_000))
    }

    // MARK: - Heavy tests (require the Silero model on disk)

    /// Drives a synthetic silence → speech-burst → silence signal through
    /// the VAD and asserts at least one segment is emitted whose offsets
    /// roughly match the burst location. Synthetic audio: 1 s silence,
    /// 1 s 200 Hz sine + harmonics (loud enough to fool a frame-level
    /// energy/probability detector), 1 s silence.
    func test_detectsSpeechBurstInSilence() throws {
        try TestHeavyGate.requireOptIn()
        let modelURL = try requireSileroModelURL()

        let vad = try VadService(
            modelURL: modelURL,
            minSilenceDurationSeconds: 0.1,
            minSpeechDurationSeconds: 0.1
        )

        let sampleRate = 16_000
        let silence = [Float](repeating: 0, count: sampleRate)               // 1 s
        let burst = synthesizeVoicedBurst(sampleRate: sampleRate, durationSeconds: 1.0)
        let signal = silence + burst + silence                                // 3 s total

        // Feed in 32 ms chunks (512 samples at 16k) — Silero's window size.
        let frame = 512
        var offset = 0
        while offset < signal.count {
            let end = min(offset + frame, signal.count)
            vad.feed(Array(signal[offset..<end]))
            offset = end
        }
        let segments = vad.endOfStream()

        XCTAssertFalse(segments.isEmpty, "expected at least one speech segment")
        // The burst sits in [1.0 s, 2.0 s]. Allow 200 ms slop on either
        // side because Silero's open/close decisions lag the boundary.
        let burstStart = sampleRate
        let burstEnd = 2 * sampleRate
        let slop = sampleRate / 5  // 200 ms
        let any = segments.contains { seg in
            seg.startSample < burstEnd + slop && seg.endSample > burstStart - slop
        }
        XCTAssertTrue(any, "no segment overlaps the burst region; got \(segments)")
    }

    // MARK: - Helpers

    /// Locate the Silero VAD ONNX on disk. Returns the path if present;
    /// throws `XCTSkip` otherwise so dev machines without the model just
    /// skip rather than fail. To populate, run the app once with VAD
    /// enabled, or invoke `ModelManager.downloadAuxiliary(.sileroVad)`.
    private func requireSileroModelURL() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let candidate = appSupport
            .appendingPathComponent(AuxiliaryModel.sileroVad.modelSubdirectory)
            .appendingPathComponent("onnx/model.onnx")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw XCTSkip("Silero VAD model not present at \(candidate.path). Download via ModelManager first.")
        }
        return candidate
    }

    /// Build a synthetic voiced waveform: a fundamental at 200 Hz plus the
    /// first three harmonics, scaled to ~0.5 amplitude. Strong enough that
    /// any reasonable VAD threshold (Silero default 0.5) will fire.
    private func synthesizeVoicedBurst(sampleRate: Int, durationSeconds: Double) -> [Float] {
        let n = Int(Double(sampleRate) * durationSeconds)
        var out = [Float](repeating: 0, count: n)
        let f0: Double = 200
        for i in 0..<n {
            let t = Double(i) / Double(sampleRate)
            let s =
                sin(2 * .pi * f0 * t) * 0.45
                + sin(2 * .pi * 2 * f0 * t) * 0.25
                + sin(2 * .pi * 3 * f0 * t) * 0.15
            out[i] = Float(s)
        }
        return out
    }
}
