import AVFoundation
import XCTest
@testable import Murmur

/// Phase 4: AudioBufferAccumulator emits one `onChunkReady` per Silero
/// speech segment when constructed with a `VadService`. Heavy — needs the
/// Silero ONNX on disk. Skipped by default (`MURMUR_RUN_HEAVY_TESTS=1`)
/// and skipped automatically when the model isn't present.
final class AudioBufferAccumulatorVadTests: XCTestCase {

    func test_vadDrivenChunking_emitsOneChunkPerBurst() throws {
        try TestHeavyGate.requireOptIn()
        let modelURL = try requireSileroModelURL()

        let detector = try VadService(
            modelURL: modelURL,
            minSilenceDurationSeconds: 0.1,
            minSpeechDurationSeconds: 0.1
        )
        let sampleRate: Double = 16_000
        // V3Phase0Tests.swift declares a file-level test-only
        // AudioBufferAccumulator stub — qualify with the module name so
        // we hit the production type.
        let acc = Murmur.AudioBufferAccumulator(
            samplesPerChunk: Int(sampleRate * 3),
            sampleRate: sampleRate,
            vad: detector
        )

        let collected = Collected()
        acc.onChunkReady = { buffer in collected.append(buffer) }

        // 1 s silence → 1 s burst → 1 s silence → 1 s burst → 1 s silence.
        // Two distinct speech regions; expect ≥ 2 chunks.
        let silence = [Float](repeating: 0, count: Int(sampleRate))
        let burst = synthesizeVoicedBurst(sampleRate: Int(sampleRate), durationSeconds: 1.0)
        let signal = silence + burst + silence + burst + silence

        // Feed in 32 ms frames mimicking a real tap.
        let frameSize = 512
        var offset = 0
        while offset < signal.count {
            let end = min(offset + frameSize, signal.count)
            guard let buffer = makeBuffer(samples: Array(signal[offset..<end]), sampleRate: sampleRate) else {
                return XCTFail("could not allocate buffer")
            }
            acc.append(buffer)
            offset = end
        }
        _ = acc.flush()

        XCTAssertGreaterThanOrEqual(
            collected.count,
            2,
            "expected at least one chunk per burst, got \(collected.count)"
        )
    }

    // MARK: - Helpers

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [AVAudioPCMBuffer] = []
        func append(_ b: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            buffers.append(b)
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return buffers.count
        }
    }

    private func requireSileroModelURL() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let candidate = appSupport
            .appendingPathComponent(AuxiliaryModel.sileroVad.modelSubdirectory)
            .appendingPathComponent("onnx/model.onnx")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw XCTSkip("Silero VAD model not present at \(candidate.path).")
        }
        return candidate
    }

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

    private func makeBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buf.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                channelData[0].assign(from: src.baseAddress!, count: samples.count)
            }
        }
        return buf
    }
}
