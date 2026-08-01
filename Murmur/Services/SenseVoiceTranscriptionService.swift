import Foundation
import os

/// Wraps the vendored sherpa-onnx Swift API to transcribe 16 kHz mono Float32 audio
/// with SenseVoice-Small int8 (zh / en / ja / ko / yue).
///
/// SPIKE: this service exists to benchmark SenseVoice against the current Cohere
/// streaming path. It is *not* wired into `ModelManager` / onboarding / Settings yet —
/// point it at a manually-downloaded model directory. Mirrors
/// `FireRedTranscriptionService` so the eventual integration is a copy-paste.
///
/// Thread-safety: actor-isolated. The underlying `SherpaOnnxOfflineRecognizer` C
/// session is not thread-safe, so all transcribe calls serialise here.
///
/// Lifetime: holds the recognizer for the service lifetime — avoid per-request reloads.
actor SenseVoiceTranscriptionService {

    private let logger = Logger(subsystem: "com.murmur.app", category: "sensevoice")
    private let recognizer: SherpaOnnxOfflineRecognizer

    /// Result of a transcription: the text plus SenseVoice's per-utterance metadata.
    struct Transcript {
        let text: String
        /// Detected language: zh / en / ja / ko / yue (SenseVoice LID). Empty if auto failed.
        let language: String
        let emotion: String
    }

    /// - Parameters:
    ///   - modelDirectory: directory containing `model.int8.onnx` and `tokens.txt` from the
    ///     `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17` release.
    ///   - language: force a language ("zh"/"en"/"ja"/"ko"/"yue") or "" for auto-LID (default).
    ///   - useInverseTextNormalization: ITN — spoken numbers/dates → digits ("二零二四"→"2024").
    ///     On by default; matches what a dictation app wants at the cursor.
    /// - Throws: `MurmurError.modelNotFound` if any required file is missing.
    init(
        modelDirectory: URL,
        language: String = "",
        useInverseTextNormalization: Bool = true
    ) throws {
        let model = modelDirectory.appendingPathComponent("model.int8.onnx").path
        let tokens = modelDirectory.appendingPathComponent("tokens.txt").path

        let fm = FileManager.default
        guard fm.fileExists(atPath: model), fm.fileExists(atPath: tokens) else {
            throw MurmurError.modelNotFound
        }

        let senseVoice = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: model,
            language: language,
            useInverseTextNormalization: useInverseTextNormalization
        )
        // Match FireRed's tuning: numThreads=4 is the M-series sweet spot for these
        // int8 ONNX graphs; provider="coreml" falls back to a slow path for int8 ops
        // (~15× slower in the FireRed spike). Re-confirm in the SenseVoice sweep.
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokens,
            numThreads: 4,
            provider: "cpu",
            debug: 0,
            senseVoice: senseVoice
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig, modelConfig: modelConfig
        )

        self.recognizer = SherpaOnnxOfflineRecognizer(config: &config)
    }

    /// Transcribe a clip. SenseVoice's rich-transcription tags (LID / emotion / event)
    /// are parsed by sherpa-onnx into `result.lang` / `.emotion` / `.event`; `result.text`
    /// is already clean, so no tag stripping is needed here.
    func transcribe(samples: [Float], sampleRate: Int) async throws -> Transcript {
        precondition(sampleRate == 16000,
                     "SenseVoiceTranscriptionService requires 16 kHz audio; got \(sampleRate)")

        let result = recognizer.decode(samples: samples, sampleRate: sampleRate)
        let transcript = Transcript(
            text: result.text,
            language: result.lang,
            emotion: result.emotion
        )
        logger.info("SenseVoice [\(transcript.language, privacy: .public)] \(transcript.text.prefix(200), privacy: .public)")
        return transcript
    }
}
