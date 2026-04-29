import AVFoundation
import Foundation
import OnnxRuntimeBindings
import os

/// Native Swift transcription service using ONNX Runtime.
/// Replaces the Python subprocess for the ONNX backend.
actor NativeTranscriptionService: TranscriptionServiceProtocol {
    private let logger = Logger(subsystem: "com.murmur.app", category: "native-transcription")
    private var modelPath: URL
    private var backend: ONNXTranscriptionBackend?
    private var tokenizer: BPETokenizerDecoder?
    private var _isModelLoaded = false

    /// Path to the Silero VAD ONNX, when configured. Set by
    /// `MurmurApp` once the model is on disk; nil reverts `transcribeLong`
    /// to fixed 30 s + 5 s overlap chunking.
    private var vadModelURL: URL?

    /// Long-audio chunking constants (Phase 5).
    /// - `vadMaxWindowSeconds`: cap on a merged-segment window so the ASR
    ///   gets at most this much audio per inference. Matches the model's
    ///   30 s training context.
    /// - `paragraphBreakGapSeconds`: gap between speech windows that
    ///   triggers a paragraph break in the assembled transcript. Matches
    ///   the heuristic in `docs/specs/meeting-transcription.md:184`.
    private static let vadMaxWindowSeconds: Double = 30
    private static let paragraphBreakGapSeconds: Double = 2.0

    // Conservative: always attempt preload check inside actor.
    nonisolated var isModelLoaded: Bool { false }

    func killProcess() async {
        await unloadModel()
    }

    init(modelPath: URL) {
        self.modelPath = modelPath
    }

    func setModelPath(_ newPath: URL) {
        if modelPath != newPath {
            modelPath = newPath
            backend = nil
            tokenizer = nil
            _isModelLoaded = false
        }
    }

    /// Configure (or clear) the Silero VAD model used by `transcribeLong`.
    /// Pass nil to revert to fixed-size chunking.
    func setVadModelURL(_ url: URL?) {
        self.vadModelURL = url
    }

    // MARK: - Protocol

    func preloadModel() async throws {
        guard !_isModelLoaded else { return }
        let t0 = CFAbsoluteTimeGetCurrent()

        let tokenizerPath = modelPath.appendingPathComponent("tokenizer.json")
        tokenizer = try BPETokenizerDecoder(tokenizerJSONPath: tokenizerPath)
        logger.info("Tokenizer loaded")

        backend = try ONNXTranscriptionBackend(modelDirectory: modelPath)
        logger.info("ORT sessions loaded in \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - t0))s")

        _isModelLoaded = true
    }

    func unloadModel() async {
        backend = nil
        tokenizer = nil
        _isModelLoaded = false
        logger.info("Model unloaded")
    }

    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult {
        let (b, t) = try await ensureComponents()

        let start = CFAbsoluteTimeGetCurrent()

        let samples = try loadAudio(url: audioURL)
        guard !samples.isEmpty else { throw MurmurError.silenceDetected }
        logger.info("Audio: \(samples.count) samples, \(String(format: "%.2f", Double(samples.count) / 16000))s")

        let t0 = CFAbsoluteTimeGetCurrent()
        let (melFeatures, frameCount) = try b.extractMelFeatures(samples: samples)
        logger.info("Mel: \(frameCount) frames in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0))s")

        let t0e = CFAbsoluteTimeGetCurrent()
        let encoderHidden: ORTValue
        do {
            encoderHidden = try b.encodeFromMel(melFeatures)
        } catch {
            logger.error("Encoder failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        logger.info("Encoder: \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0e))s")

        let t1 = CFAbsoluteTimeGetCurrent()
        let prompt = ONNXTranscriptionBackend.decoderPrompt(for: language)
        let tokenIds: [Int32]
        do {
            tokenIds = try b.decode(
                encoderHidden: encoderHidden,
                decoderPrompt: prompt,
                eosTokenId: ONNXTranscriptionBackend.eosTokenId,
                maxTokens: ONNXTranscriptionBackend.maxTokens)
        } catch {
            logger.error("Decoder failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        logger.info("Decoder: \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t1))s, \(tokenIds.count) tokens")

        // Strip decoder prompt prefix — only decode the generated tokens
        let outputTokens = Array(tokenIds.dropFirst(prompt.count))
        let text = t.decode(outputTokens, skipSpecialTokens: true)
        logger.info("Transcription: '\(text.prefix(200))'")

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        return TranscriptionResult(text: text, language: detectLanguage(text), durationMs: elapsedMs)
    }

    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        let (b, t) = try await ensureComponents()

        let start = CFAbsoluteTimeGetCurrent()
        let allSamples = try loadAudio(url: audioURL)
        let sampleRate = 16_000

        // VAD-driven chunking when a Silero model is configured.
        // Falls through to the fixed-size path if VAD construction fails.
        var windows: [VadWindow] = []
        var usedVad = false
        if let vadURL = vadModelURL {
            do {
                windows = try Self.computeVadWindows(
                    samples: allSamples,
                    sampleRate: sampleRate,
                    modelURL: vadURL
                )
                usedVad = true
                logger.info("VAD: \(windows.count) window(s) from \(allSamples.count) samples")
            } catch {
                logger.warning("VAD chunking failed (\(String(describing: error), privacy: .public)) — falling back to fixed chunks")
            }
        }

        if !usedVad {
            // Legacy fixed 30 s + 5 s overlap. Preserved for the
            // model-missing case and any environment where the VAD pass
            // can't run.
            let chunkLen = 30 * sampleRate
            let overlapLen = 5 * sampleRate
            let stepLen = chunkLen - overlapLen

            var offset = 0
            while offset < allSamples.count {
                let end = min(offset + chunkLen, allSamples.count)
                windows.append(VadWindow(startSample: offset, endSample: end, samples: Array(allSamples[offset..<end])))
                offset += stepLen
                if end == allSamples.count { break }
            }
        }

        var fullText = ""
        var lastWindowEndSample: Int? = nil
        let paragraphGapSamples = Int(Self.paragraphBreakGapSeconds * Double(sampleRate))
        for (idx, window) in windows.enumerated() {
            try Task.checkCancellation()

            let (melFeatures, _) = try b.extractMelFeatures(samples: window.samples)
            let encoderHidden = try b.encodeFromMel(melFeatures)
            let prompt = ONNXTranscriptionBackend.decoderPrompt(for: language)
            let tokenIds = try b.decode(
                encoderHidden: encoderHidden,
                decoderPrompt: prompt,
                eosTokenId: ONNXTranscriptionBackend.eosTokenId,
                maxTokens: ONNXTranscriptionBackend.maxTokens)
            let outputTokens = Array(tokenIds.dropFirst(prompt.count))
            let text = t.decode(outputTokens, skipSpecialTokens: true)

            if !fullText.isEmpty && !text.isEmpty {
                let separator: String
                if usedVad,
                   let lastEnd = lastWindowEndSample,
                   window.startSample - lastEnd >= paragraphGapSamples {
                    separator = "\n\n"
                } else {
                    separator = " "
                }
                fullText += separator
            }
            fullText += text
            lastWindowEndSample = window.endSample

            onProgress(TranscriptionProgress(
                currentChunk: idx + 1, totalChunks: windows.count, partialText: fullText))
        }

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        return TranscriptionResult(text: fullText, language: detectLanguage(fullText), durationMs: elapsedMs)
    }

    /// One transcription unit produced by either the VAD pass (merged
    /// speech segments, silence dropped) or the fixed-size fallback.
    /// `startSample` / `endSample` are absolute offsets into the loaded
    /// audio — used for paragraph-break decisions, not for re-decoding.
    private struct VadWindow {
        let startSample: Int
        let endSample: Int
        let samples: [Float]
    }

    /// Run a one-shot VAD pass over the whole loaded audio and merge
    /// consecutive speech segments into windows up to
    /// `vadMaxWindowSeconds` long. Silence between segments (within and
    /// across windows) is dropped from the audio fed to the ASR; gap
    /// length between windows is preserved via `startSample` /
    /// `endSample` so paragraph-break detection still works.
    nonisolated private static func computeVadWindows(
        samples: [Float],
        sampleRate: Int,
        modelURL: URL
    ) throws -> [VadWindow] {
        let vad = try VadService(
            modelURL: modelURL,
            sampleRate: sampleRate,
            // Long-audio passes can produce tens of MB of audio; bump
            // the ring buffer headroom so a single segment never gets
            // truncated by the buffer wrapping.
            bufferSeconds: Float(vadMaxWindowSeconds * 2),
            // Allow speakers' natural sentence-end pauses (~0.4-0.6 s)
            // without splitting a sentence. Phase 4 streaming uses the
            // 0.25 s default; long-audio is more tolerant.
            minSilenceDurationSeconds: 0.5,
            maxSpeechDurationSeconds: Float(vadMaxWindowSeconds)
        )

        // Feed in 1-second blocks. Smaller is fine but adds overhead;
        // larger risks the C buffer growing if popSegments isn't drained
        // promptly.
        let block = sampleRate
        var offset = 0
        while offset < samples.count {
            let end = min(offset + block, samples.count)
            vad.feed(Array(samples[offset..<end]))
            offset = end
        }
        let segments = vad.endOfStream()

        let maxWindowSamples = Int(vadMaxWindowSeconds * Double(sampleRate))
        var windows: [VadWindow] = []
        var current: VadWindow?
        for seg in segments {
            if let c = current,
               (seg.endSample - c.startSample) <= maxWindowSamples {
                // Concatenate speech samples; silence between segments
                // is dropped. The window's `endSample` tracks the
                // original timeline, not the dropped-silence timeline.
                var merged = c.samples
                merged.append(contentsOf: seg.samples)
                current = VadWindow(
                    startSample: c.startSample,
                    endSample: seg.endSample,
                    samples: merged
                )
            } else {
                if let c = current { windows.append(c) }
                current = VadWindow(
                    startSample: seg.startSample,
                    endSample: seg.endSample,
                    samples: seg.samples
                )
            }
        }
        if let c = current { windows.append(c) }
        return windows
    }

    // MARK: - Helpers

    private func ensureComponents() async throws -> (ONNXTranscriptionBackend, BPETokenizerDecoder) {
        if !_isModelLoaded { try await preloadModel() }
        guard let b = backend, let t = tokenizer else {
            throw MurmurError.transcriptionFailed("Model not loaded")
        }
        return (b, t)
    }

    /// Load WAV/audio file as 16kHz mono Float32 samples.
    private func loadAudio(url: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let srcFormat = audioFile.processingFormat
        logger.info("loadAudio: sr=\(srcFormat.sampleRate, privacy: .public) ch=\(srcFormat.channelCount, privacy: .public) fmt=\(srcFormat.commonFormat.rawValue, privacy: .public) len=\(audioFile.length, privacy: .public)")

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false)!

        if srcFormat.sampleRate == 16000 && srcFormat.channelCount == 1
            && srcFormat.commonFormat == .pcmFormatFloat32 {
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
                throw MurmurError.transcriptionFailed("Failed to create audio buffer")
            }
            try audioFile.read(into: buffer)
            guard let data = buffer.floatChannelData?[0] else {
                throw MurmurError.transcriptionFailed("No audio data")
            }
            return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }

        // Convert to 16kHz mono Float32, accumulating chunks for arbitrary-length files
        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw MurmurError.transcriptionFailed("Cannot create audio converter")
        }

        let inputBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: 4096)!
        var allSamples = [Float]()
        var convertError: NSError?

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            do {
                inputBuffer.frameLength = 0
                try audioFile.read(into: inputBuffer)
                if inputBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
        }

        var status: AVAudioConverterOutputStatus
        repeat {
            let chunkBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096)!
            status = converter.convert(to: chunkBuffer, error: &convertError, withInputFrom: inputBlock)
            if let data = chunkBuffer.floatChannelData?[0], chunkBuffer.frameLength > 0 {
                allSamples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(chunkBuffer.frameLength)))
            }
        } while status == .haveData

        if allSamples.isEmpty {
            throw MurmurError.transcriptionFailed("No audio data after conversion")
        }
        return allSamples
    }

    private func detectLanguage(_ text: String) -> DetectedLanguage {
        let chineseChars = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let totalAlpha = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        if totalAlpha > 0 && Double(chineseChars) / Double(totalAlpha) > 0.3 {
            return .chinese
        }
        return .english
    }
}
