import Foundation
import os

/// Wraps the vendored sherpa-onnx CT-Transformer punctuation model.
/// Adds Chinese / English punctuation (，。？！) to bare ASR transcripts at
/// roughly 1 ms per clip on Apple Silicon. The model is BERT-style and never
/// paraphrases — it only inserts punctuation marks, so it cannot reach the
/// safety-rail trip wires that LLM correction can.
///
/// Lifetime: the underlying C session is held for the actor's lifetime to
/// avoid the ~200 ms model load on each request. Actor-isolated because the
/// C session is not thread-safe.
actor ASRPunctuationService {

    private let logger = Logger(subsystem: "com.murmur.app", category: "asr-punc")
    private let recognizer: SherpaOnnxOfflinePunctuationWrapper

    /// - Parameter modelDirectory: directory containing `model.onnx` and
    ///   `tokens.json` from the
    ///   `csukuangfj/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12`
    ///   HF repo.
    /// - Throws: `MurmurError.modelNotFound` if the ONNX file is missing.
    init(modelDirectory: URL) throws {
        let modelPath = modelDirectory.appendingPathComponent("model.onnx").path
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw MurmurError.modelNotFound
        }

        let modelConfig = sherpaOnnxOfflinePunctuationModelConfig(
            ctTransformer: modelPath,
            numThreads: 4,
            debug: 0,
            provider: "cpu"
        )
        var config = sherpaOnnxOfflinePunctuationConfig(model: modelConfig)
        self.recognizer = withUnsafePointer(to: &config) { ptr in
            SherpaOnnxOfflinePunctuationWrapper(config: ptr)
        }
    }

    /// Add punctuation to bare text.
    ///
    /// Idempotent on already-punctuated input (the model is conservative —
    /// won't over-punctuate already-clean text). Returns the original text
    /// unchanged if it's empty or whitespace-only.
    func addPunctuation(to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let result = recognizer.addPunct(text: trimmed)
        logger.debug("punc: \(trimmed.prefix(60), privacy: .public) → \(result.prefix(60), privacy: .public)")
        return result
    }
}
