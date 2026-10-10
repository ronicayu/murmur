import Foundation
import os

/// Wraps the vendored sherpa-onnx Swift API to transcribe 16 kHz mono Float32 audio
/// with Qwen3-ASR-0.6B int8.
///
/// Thread-safety: actor-isolated. The underlying `SherpaOnnxOfflineRecognizer` C
/// session is not thread-safe, so all transcribe calls serialise here.
///
/// Lifetime: holds the recognizer for the lifetime of the service. Loading the
/// three ONNX graphs takes ~1 s on a Mac M-series, so we avoid reloading per request.
actor Qwen3TranscriptionService {

    private let logger = Logger(subsystem: "com.murmur.app", category: "qwen3")
    private let recognizer: SherpaOnnxOfflineRecognizer

    /// - Parameter modelDirectory: directory containing `conv_frontend.onnx`,
    ///   `encoder.int8.onnx`, `decoder.int8.onnx`, and `tokenizer/` from the
    ///   `csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25` HF repo.
    /// - Throws: `MurmurError.modelNotFound` if any required file is missing.
    init(modelDirectory: URL) throws {
        let fm = FileManager.default
        let allPresent = ModelBackend.qwen3.requiredFiles.allSatisfy {
            fm.fileExists(atPath: modelDirectory.appendingPathComponent($0).path)
        }
        guard allPresent else {
            throw MurmurError.modelNotFound
        }

        // maxTotalLen caps prompt + audio + generated tokens; the audio encoder
        // emits ~13 tokens per second, so 2048 covers roughly two minutes of
        // speech plus its transcript. Hotwords are deliberately left empty: in
        // benchmarking, a fixed term list made mixed zh-en output worse and
        // occasionally sent the decoder into a repetition loop.
        let qwen3Asr = sherpaOnnxOfflineQwen3ASRModelConfig(
            convFrontend: modelDirectory.appendingPathComponent("conv_frontend.onnx").path,
            encoder: modelDirectory.appendingPathComponent("encoder.int8.onnx").path,
            decoder: modelDirectory.appendingPathComponent("decoder.int8.onnx").path,
            tokenizer: modelDirectory.appendingPathComponent("tokenizer").path,
            maxTotalLen: 2048,
            maxNewTokens: 512
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: "",
            numThreads: 4,
            provider: "cpu",
            debug: 0,
            qwen3Asr: qwen3Asr
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 128)
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig, modelConfig: modelConfig
        )

        self.recognizer = SherpaOnnxOfflineRecognizer(config: &config)
    }

    /// Strips chat-template debris from raw model output.
    ///
    /// Qwen3-ASR is a language model that answers in the form
    /// `language Chinese<asr_text>…text…<|im_end|>`. sherpa-onnx normally returns
    /// only the text, but on some clips the scaffolding leaks through — e.g.
    /// `<asr_text>system没有…` — and would be typed at the cursor.
    nonisolated static func cleaned(_ raw: String) -> String {
        var text = raw
        // Generation past an end marker is the model continuing on its own.
        for endMarker in ["<|im_end|>", "<|endoftext|>"] {
            if let range = text.range(of: endMarker) {
                text = String(text[..<range.lowerBound])
            }
        }
        var sawScaffolding = false
        if let range = text.range(of: "<asr_text>", options: .backwards) {
            text = String(text[range.upperBound...])
            sawScaffolding = true
        }
        let tagPattern = "<\\|[^|>]*\\|>|</?asr_text>"
        if text.range(of: tagPattern, options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: tagPattern, with: "", options: .regularExpression)
            sawScaffolding = true
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A chat role name left stranded where a marker was removed.
        if sawScaffolding {
            for role in ["system", "assistant", "user"] where text.hasPrefix(role) {
                text = String(text.dropFirst(role.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return text
    }

    /// Transcribe a clip and return text. Unlike FireRed, Qwen3-ASR emits
    /// punctuation and natural casing itself, so the output is returned as-is
    /// apart from trimming.
    func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        precondition(sampleRate == 16000,
                     "Qwen3TranscriptionService requires 16 kHz audio; got \(sampleRate)")

        let result = recognizer.decode(samples: samples, sampleRate: sampleRate)
        let text = Self.cleaned(result.text)
        logger.info("Qwen3 text: \(text.prefix(200), privacy: .public)")
        return text
    }
}
