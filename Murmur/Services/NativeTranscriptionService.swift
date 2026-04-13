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
        let sampleRate = 16000

        let chunkLen = 30 * sampleRate
        let overlapLen = 5 * sampleRate
        let stepLen = chunkLen - overlapLen

        var chunks: [(start: Int, end: Int)] = []
        var offset = 0
        while offset < allSamples.count {
            let end = min(offset + chunkLen, allSamples.count)
            chunks.append((start: offset, end: end))
            offset += stepLen
            if end == allSamples.count { break }
        }

        var fullText = ""
        for (idx, chunk) in chunks.enumerated() {
            try Task.checkCancellation()

            let chunkSamples = Array(allSamples[chunk.start..<chunk.end])
            let (melFeatures, _) = try b.extractMelFeatures(samples: chunkSamples)
            let encoderHidden = try b.encodeFromMel(melFeatures)
            let prompt = ONNXTranscriptionBackend.decoderPrompt(for: language)
            let tokenIds = try b.decode(
                encoderHidden: encoderHidden,
                decoderPrompt: prompt,
                eosTokenId: ONNXTranscriptionBackend.eosTokenId,
                maxTokens: ONNXTranscriptionBackend.maxTokens)
            let outputTokens = Array(tokenIds.dropFirst(prompt.count))
            let text = t.decode(outputTokens, skipSpecialTokens: true)

            if !fullText.isEmpty && !text.isEmpty { fullText += " " }
            fullText += text

            onProgress(TranscriptionProgress(
                currentChunk: idx + 1, totalChunks: chunks.count, partialText: fullText))
        }

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        return TranscriptionResult(text: fullText, language: detectLanguage(fullText), durationMs: elapsedMs)
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
