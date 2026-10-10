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

        // One decode is bounded by `maxTotalLen`; a long recording would be
        // cut off part-way. Decode it in pieces split at quiet points instead.
        var pieces: [String] = []
        for range in Self.segmentRanges(samples: samples, sampleRate: sampleRate) {
            let piece = decodeWithRetry(Array(samples[range]), sampleRate: sampleRate)
            if !piece.isEmpty { pieces.append(piece) }
        }
        let text = Self.joined(pieces)
        logger.info("Qwen3 text: \(text.prefix(200), privacy: .public)")
        return text
    }

    /// Start offsets (in samples) tried in turn when a decode looks corrupt.
    private static let retryOffsets = [0, 160, 320, 480]

    /// Decode one segment, retrying from a slightly later start if the output
    /// looks corrupt.
    ///
    /// The int8 model has a rare failure where a clip of ordinary speech comes
    /// back as a few characters of chat-template debris (`�斯系统`,
    /// `<asr_text>system…`) or in an unrelated script. It is deterministic for
    /// a given input but chaotic — moving the start by a single sample gives a
    /// correct transcript — so shifting by 10 ms and decoding again recovers it.
    private func decodeWithRetry(_ samples: [Float], sampleRate: Int) -> String {
        let speechSeconds = Self.speechSeconds(samples, sampleRate: sampleRate)
        var fallback = ""
        for offset in Self.retryOffsets where offset < samples.count {
            let clip = offset == 0 ? samples : Array(samples[offset...])
            let raw = recognizer.decode(samples: clip, sampleRate: sampleRate).text
            let text = Self.cleaned(raw)
            if !Self.looksCorrupt(raw: raw, cleaned: text, speechSeconds: speechSeconds) {
                if offset > 0 { logger.info("Qwen3 decode recovered after retry at +\(offset) samples") }
                return text
            }
            logger.warning("Qwen3 decode looks corrupt at +\(offset) samples: \(raw.prefix(60), privacy: .public)")
            // Never fall back to template debris or a wrong-script transcript;
            // a merely short result is still the best guess if every retry fails.
            if !Self.hasDebris(raw: raw, cleaned: text), text.count > fallback.count { fallback = text }
        }
        return fallback
    }

    /// Seconds of `samples` whose 100 ms frames reach whisper level (≈ −50 dBFS).
    nonisolated static func speechSeconds(_ samples: [Float], sampleRate: Int) -> Double {
        let frame = max(1, sampleRate / 10)
        var loud = 0
        var start = 0
        while start < samples.count {
            let end = min(start + frame, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            if (sum / Float(end - start)).squareRoot() >= 0.00316 { loud += 1 }
            start = end
        }
        return Double(loud) / 10
    }

    /// Template markers, undecodable bytes, or text in a script this engine is
    /// never routed (it only receives Chinese and English audio).
    nonisolated static func hasDebris(raw: String, cleaned: String) -> Bool {
        if raw.contains("<asr_text>") || raw.contains("<|") || raw.contains("\u{FFFD}") { return true }
        return cleaned.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0000...0x024F,   // ASCII, Latin-1, Latin Extended
                 0x2000...0x206F,   // general punctuation
                 0x20A0...0x20CF,   // currency
                 0x2100...0x214F,   // letterlike (℃, №)
                 0x3000...0x303F,   // CJK punctuation
                 0x3400...0x4DBF,   // CJK extension A
                 0x4E00...0x9FFF,   // CJK unified
                 0xFF00...0xFFEF:   // full-width forms
                return false
            default:
                return true
            }
        }
    }

    /// True when a decode should not be trusted: it contains debris, or it
    /// produced almost no text for several seconds of audible speech (normal
    /// speech runs at 3–5 characters per second; under 0.5 means the model
    /// gave up).
    nonisolated static func looksCorrupt(raw: String, cleaned: String, speechSeconds: Double) -> Bool {
        if hasDebris(raw: raw, cleaned: cleaned) { return true }
        return speechSeconds >= 4 && Double(cleaned.count) < speechSeconds * 0.5
    }

    /// Longest stretch decoded in one go.
    static let maxSegmentSeconds = 40.0
    /// How far back from that limit to look for a quiet point to cut at.
    static let splitSearchSeconds = 10.0

    /// Splits `samples` into ranges of at most `maxSegmentSeconds`, each cut at
    /// the quietest 0.3 s within the last `splitSearchSeconds` of the limit so
    /// a cut lands in a pause rather than through a word. Audio that already
    /// fits is returned as a single range.
    nonisolated static func segmentRanges(samples: [Float], sampleRate: Int) -> [Range<Int>] {
        let maxLength = Int(maxSegmentSeconds * Double(sampleRate))
        guard samples.count > maxLength else { return [0..<samples.count] }

        let search = Int(splitSearchSeconds * Double(sampleRate))
        let frame = max(1, sampleRate * 3 / 10)
        let hop = max(1, frame / 3)
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLength {
            let limit = start + maxLength
            var bestCut = limit
            var bestEnergy = Float.greatestFiniteMagnitude
            var position = limit - search
            while position + frame <= limit {
                var energy: Float = 0
                for i in position..<(position + frame) { energy += samples[i] * samples[i] }
                if energy < bestEnergy {
                    bestEnergy = energy
                    bestCut = position + frame / 2
                }
                position += hop
            }
            ranges.append(start..<bestCut)
            start = bestCut
        }
        ranges.append(start..<samples.count)
        return ranges
    }

    /// Joins per-segment transcripts. A space is added only between two Latin
    /// words; CJK text and punctuation need none.
    nonisolated static func joined(_ pieces: [String]) -> String {
        var text = ""
        for piece in pieces {
            if let last = text.last, let first = piece.first,
               last.isASCII, first.isASCII,
               last.isLetter || last.isNumber || ".,!?".contains(last),
               first.isLetter || first.isNumber {
                text += " "
            }
            text += piece
        }
        return text
    }
}
