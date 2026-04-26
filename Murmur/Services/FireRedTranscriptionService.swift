import Foundation
import os

/// Wraps the vendored sherpa-onnx Swift API to transcribe 16 kHz mono Float32 audio
/// with FireRedASR2-AED int8.
///
/// Thread-safety: actor-isolated. The underlying `SherpaOnnxOfflineRecognizer` C
/// session is not thread-safe, so all transcribe calls serialise here.
///
/// Lifetime: holds the recognizer for the lifetime of the service. Loading the int8
/// encoder + decoder + tokens takes ~1.3 s on a Mac M-series in spike measurements,
/// so we avoid reloading per request.
actor FireRedTranscriptionService {

    private let logger = Logger(subsystem: "com.murmur.app", category: "firered")
    private let recognizer: SherpaOnnxOfflineRecognizer

    /// - Parameter modelDirectory: directory containing `encoder.int8.onnx`,
    ///   `decoder.int8.onnx`, and `tokens.txt` from the
    ///   `csukuangfj2/sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26` HF repo.
    /// - Throws: `MurmurError.modelNotFound` if any required file is missing.
    init(modelDirectory: URL) throws {
        let encoder = modelDirectory.appendingPathComponent("encoder.int8.onnx").path
        let decoder = modelDirectory.appendingPathComponent("decoder.int8.onnx").path
        let tokens = modelDirectory.appendingPathComponent("tokens.txt").path

        let fm = FileManager.default
        guard fm.fileExists(atPath: encoder),
              fm.fileExists(atPath: decoder),
              fm.fileExists(atPath: tokens)
        else {
            throw MurmurError.modelNotFound
        }

        let fireRedAsr = sherpaOnnxOfflineFireRedAsrModelConfig(
            encoder: encoder, decoder: decoder
        )
        // numThreads=4 is the measured sweet spot on the FireRedASR2-AED int8 ONNX
        // (~17% faster than the default 1 on the 14.7 s benchmark clip). 8 threads
        // is *slower* than 4 due to perf-cluster contention; provider="coreml"
        // is dramatically slower (~15×) because the int8 ops can't be delegated
        // and the EP falls back to a slow path. See run_speed_sweep.py in spike.
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokens,
            numThreads: 4,
            provider: "cpu",
            debug: 0,
            fireRedAsr: fireRedAsr
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig, modelConfig: modelConfig
        )

        self.recognizer = SherpaOnnxOfflineRecognizer(config: &config)
    }

    /// Transcribe a clip and return text. Mirrors the official asr.py post-processing:
    /// the raw model output is uppercase; we lowercase to match the spike reference.
    func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        precondition(sampleRate == 16000,
                     "FireRedTranscriptionService requires 16 kHz audio; got \(sampleRate)")

        // Vendored SherpaOnnx.swift exposes a one-shot helper at line 789:
        //   func decode(samples: [Float], sampleRate: Int = 16_000) -> SherpaOnnxOfflineRecongitionResult
        // which internally creates a stream, accepts the waveform, decodes, and
        // returns the result. Match the spike's call exactly.
        let result = recognizer.decode(samples: samples, sampleRate: sampleRate)
        let text = result.text.lowercased()
        logger.info("FireRed text: \(text.prefix(200), privacy: .public)")
        return text
    }
}
