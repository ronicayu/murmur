import AVFoundation
import Accelerate
import Foundation
import OnnxRuntimeBindings
import os

// MARK: - Protocol & Result

struct LIDResult: Sendable, Equatable {
    /// Whisper language code (e.g. "en", "zh", "ja"). May be any Whisper language;
    /// caller decides whether it is in the supported transcription set.
    let code: String
    /// Softmax probability of `code` over the language-token subspace, in [0, 1].
    let confidence: Float
}

protocol LanguageIdentifying: Sendable {
    func identify(audioURL: URL) async throws -> LIDResult
    func preload() async throws
    func unload() async
    func setModelPath(_ url: URL) async
}

// MARK: - Language token map

/// Maps a Whisper language code → ID of its `<|LANG|>` token in the multilingual
/// Whisper vocabulary. Derived from openai/whisper's tokenizer.py: first language
/// token ID is 50259 (en), subsequent IDs follow the fixed LANGUAGES key order.
enum WhisperLanguageTokens {
    static let languageCodes: [String] = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr",
        "pl", "ca", "nl", "ar", "sv", "it", "id", "hi", "fi", "vi",
        "iw", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no",
        "th", "ur", "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk",
        "te", "fa", "lv", "bn", "sr", "az", "sl", "kn", "et", "mk",
        "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw",
        "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc",
        "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo",
        "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl",
        "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su",
    ]

    /// Inclusive ID range of the contiguous language-token block.
    static let firstID: Int32 = 50259
    static var lastID: Int32 { firstID + Int32(languageCodes.count) - 1 }
    static let startOfTranscript: Int32 = 50258

    static func code(for tokenID: Int32) -> String? {
        let idx = Int(tokenID - firstID)
        guard idx >= 0, idx < languageCodes.count else { return nil }
        return languageCodes[idx]
    }
}

/// Maps a Whisper language code to the Cohere-supported code used by the
/// transcription backend, or nil if the detected language is outside Cohere's
/// 14-language set. Centralises the "what can the transcriber actually use"
/// decision in one place.
enum CohereLanguageMapping {
    static let supported: Set<String> = [
        "en", "zh", "ja", "ko", "fr", "de", "es", "pt",
        "it", "nl", "pl", "el", "ar", "vi",
    ]

    /// Returns the Cohere code if `whisperCode` is directly supported, else nil.
    static func map(_ whisperCode: String) -> String? {
        supported.contains(whisperCode) ? whisperCode : nil
    }
}

// MARK: - Service

/// Whisper-tiny based language identifier. Runs the ONNX encoder on a short probe
/// of the input audio, then one decoder step whose first logit row is softmaxed
/// over the Whisper language-token block to produce (code, confidence).
///
/// Thread-safety: actor-isolated. `identify` must not be called before
/// `setModelPath` / `preload` has succeeded.
actor LanguageIdentificationService: LanguageIdentifying {
    private let logger = Logger(subsystem: "com.murmur.app", category: "lid")
    private var modelPath: URL
    private let melExtractor = WhisperMelExtractor()
    private var env: ORTEnv?
    private var encoderSession: ORTSession?
    private var decoderSession: ORTSession?
    private var loaded = false

    /// First N seconds of audio passed to mel extraction. The encoder always runs
    /// on a fixed 30-second mel window padded with zeros; trimming audio here
    /// replaces seconds 5–30 with silence. This keeps the probe cheap at the cost
    /// of potential accuracy loss on short or late-starting utterances (e.g. a user
    /// who pauses before speaking). See docs/handoffs/096_EN_PM_lid-deferrals.md
    /// for the tonal-language reliability discussion.
    private static let probeSeconds: Double = 5.0

    init(modelPath: URL) {
        self.modelPath = modelPath
    }

    func setModelPath(_ url: URL) async {
        if modelPath != url {
            modelPath = url
            await unload()
        }
    }

    func preload() async throws {
        guard !loaded else { return }
        let encoderPath = modelPath.appendingPathComponent("onnx/encoder_model_quantized.onnx").path
        let decoderPath = modelPath.appendingPathComponent("onnx/decoder_model_quantized.onnx").path

        let fm = FileManager.default
        guard fm.fileExists(atPath: encoderPath), fm.fileExists(atPath: decoderPath) else {
            throw MurmurError.modelNotFound
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let e = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        try opts.setIntraOpNumThreads(2)
        try opts.setGraphOptimizationLevel(.all)
        env = e
        encoderSession = try ORTSession(env: e, modelPath: encoderPath, sessionOptions: opts)
        decoderSession = try ORTSession(env: e, modelPath: decoderPath, sessionOptions: opts)
        loaded = true
        logger.info("LID sessions loaded in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0))s")
    }

    func unload() async {
        encoderSession = nil
        decoderSession = nil
        env = nil
        loaded = false
    }

    func identify(audioURL: URL) async throws -> LIDResult {
        if !loaded { try await preload() }
        guard let encoder = encoderSession, let decoder = decoderSession else {
            throw MurmurError.transcriptionFailed("LID model not loaded")
        }

        let samples = try loadProbeSamples(url: audioURL)
        guard !samples.isEmpty else {
            throw MurmurError.silenceDetected
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let melTensor = try melExtractor.extract(samples: samples)

        let encoderOut = try encoder.run(
            withInputs: ["input_features": melTensor],
            outputNames: ["last_hidden_state"],
            runOptions: nil
        )
        guard let hidden = encoderOut["last_hidden_state"] else {
            throw MurmurError.transcriptionFailed("LID encoder produced no hidden state")
        }

        // Single decoder step with <|startoftranscript|> — the next-token logits
        // at position 0 carry the language distribution for multilingual Whisper.
        let inputIds = try makeInt64Tensor(
            values: [Int64(WhisperLanguageTokens.startOfTranscript)],
            shape: [1, 1]
        )
        let decoderOut = try decoder.run(
            withInputs: [
                "input_ids": inputIds,
                "encoder_hidden_states": hidden,
            ],
            outputNames: ["logits"],
            runOptions: nil
        )
        guard let logitsTensor = decoderOut["logits"] else {
            throw MurmurError.transcriptionFailed("LID decoder produced no logits")
        }

        let result = try argmaxOverLanguages(logitsTensor)
        logger.info("LID: \(result.code, privacy: .public) @ \(String(format: "%.2f", result.confidence)) in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0))s")
        return result
    }

    // MARK: - Audio loading

    /// Load WAV/audio file as 16 kHz mono Float32, trimmed to the first probe window.
    private func loadProbeSamples(url: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let srcFormat = audioFile.processingFormat

        let maxSamples = Int(Self.probeSeconds * 16000)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        if srcFormat.sampleRate == 16000 && srcFormat.channelCount == 1
            && srcFormat.commonFormat == .pcmFormatFloat32 {
            let totalFrames = Int(audioFile.length)
            let frameCount = AVAudioFrameCount(min(totalFrames, maxSamples))
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
                return []
            }
            try audioFile.read(into: buffer, frameCount: frameCount)
            guard let data = buffer.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw MurmurError.transcriptionFailed("LID cannot create audio converter")
        }

        let inputBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: 4096)!
        var allSamples = [Float]()
        allSamples.reserveCapacity(maxSamples)
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
                let want = maxSamples - allSamples.count
                let take = min(Int(chunkBuffer.frameLength), want)
                allSamples.append(contentsOf: UnsafeBufferPointer(start: data, count: take))
                if allSamples.count >= maxSamples { break }
            }
        } while status == .haveData

        // AVAudioConverter's contract: the error pointer is written ONLY on
        // failure, never cleared on success — so a single shared `convertError`
        // variable across loop iterations is safe (CR NC-1).
        if let err = convertError {
            throw MurmurError.transcriptionFailed("LID audio conversion error: \(err.localizedDescription)")
        }

        return allSamples
    }

    // MARK: - Logits → language

    /// Given the decoder logits tensor, softmax over only the Whisper
    /// language-token block and return the argmax code + its probability.
    /// The confidence is probability within the language subspace, not over the
    /// full vocabulary (language tokens are forced, so full-vocab softmax would
    /// dilute the signal with unrelated token mass).
    private func argmaxOverLanguages(_ logitsTensor: ORTValue) throws -> LIDResult {
        let info = try logitsTensor.tensorTypeAndShapeInfo()
        let shape = info.shape.map { $0.intValue }
        // Expected shape: [batch=1, seq_len=1, vocab]. The decoder may return
        // seq_len > 1 if the model is the non-merged variant; we always read the
        // last position.
        guard shape.count >= 2, let vocab = shape.last else {
            throw MurmurError.transcriptionFailed("LID logits has unexpected shape \(shape)")
        }

        let data = try logitsTensor.tensorData() as Data
        let elementType = info.elementType
        let lastRow = try readLastLogitRow(data: data, vocab: vocab, elementType: elementType)

        let first = Int(WhisperLanguageTokens.firstID)
        let last = Int(WhisperLanguageTokens.lastID)
        guard last < lastRow.count else {
            throw MurmurError.transcriptionFailed("LID logits vocab=\(lastRow.count) too small for language tokens")
        }

        // Numerically stable softmax over the language-token range only.
        let langLogits = Array(lastRow[first...last])
        let maxLogit = langLogits.max() ?? 0
        var exps = [Float](repeating: 0, count: langLogits.count)
        var sum: Float = 0
        for i in 0..<langLogits.count {
            let e = exp(langLogits[i] - maxLogit)
            exps[i] = e
            sum += e
        }
        guard sum > 0, let bestIdx = exps.indices.max(by: { exps[$0] < exps[$1] }) else {
            throw MurmurError.transcriptionFailed("LID softmax produced no valid result")
        }
        let confidence = exps[bestIdx] / sum
        let code = WhisperLanguageTokens.languageCodes[bestIdx]
        return LIDResult(code: code, confidence: confidence)
    }

    /// Reads the final `[vocab]` slice of the logits tensor, converting from
    /// whatever element type the model emitted to `[Float]`.
    private func readLastLogitRow(
        data: Data,
        vocab: Int,
        elementType: ORTTensorElementDataType
    ) throws -> [Float] {
        switch elementType {
        case .float:
            let stride = vocab * MemoryLayout<Float>.stride
            guard data.count >= stride else {
                throw MurmurError.transcriptionFailed("LID logits data too short for fp32")
            }
            let offset = data.count - stride
            let slice = data.subdata(in: offset..<data.count)
            return slice.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: Float.self).baseAddress else { return [] }
                return Array(UnsafeBufferPointer(start: base, count: vocab))
            }
        case .float16:
            let stride = vocab * 2
            guard data.count >= stride else {
                throw MurmurError.transcriptionFailed("LID logits data too short for fp16")
            }
            let offset = data.count - stride
            let slice = data.subdata(in: offset..<data.count)
            return float16ToFloat32(slice, count: vocab)
        default:
            throw MurmurError.transcriptionFailed("LID logits element type \(elementType.rawValue) unsupported")
        }
    }

    private func float16ToFloat32(_ data: Data, count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            guard let srcBase = raw.baseAddress else { return }
            let srcMutable = UnsafeMutableRawPointer(mutating: srcBase)
            var srcBuf = vImage_Buffer(
                data: srcMutable, height: 1,
                width: vImagePixelCount(count), rowBytes: count * 2
            )
            result.withUnsafeMutableBytes { dstRaw in
                guard let dstBase = dstRaw.baseAddress else { return }
                var dstBuf = vImage_Buffer(
                    data: dstBase, height: 1,
                    width: vImagePixelCount(count), rowBytes: count * 4
                )
                vImageConvert_Planar16FtoPlanarF(&srcBuf, &dstBuf, 0)
            }
        }
        return result
    }

    private func makeInt64Tensor(values: [Int64], shape: [Int]) throws -> ORTValue {
        let data = NSMutableData(bytes: values, length: values.count * MemoryLayout<Int64>.stride)
        let nsShape = shape.map { NSNumber(value: $0) }
        return try ORTValue(tensorData: data, elementType: .int64, shape: nsShape)
    }
}

// MARK: - Whisper mel spectrogram extractor

/// Computes the 80-mel log-spectrogram in the format Whisper's encoder expects:
///   - sample rate 16 kHz, n_fft = 400, hop = 160, Hann window
///   - HTK-style mel scale (not Slaney — diverges from Cohere's extractor)
///   - log10 of power, clipped to max − 8, then (x + 4) / 4
///   - padded / truncated to exactly 3000 frames, producing shape [1, 80, 3000]
///
/// Shares no code with `MelSpectrogramExtractor` because nearly every knob
/// (nMels, window length vs n_fft, mel scale, normalisation, transpose layout)
/// is different between Cohere ASR and Whisper.
final class WhisperMelExtractor {
    static let sampleRate = 16000
    static let nFFT = 400
    static let hopLength = 160
    static let nMels = 80
    static let targetFrames = 3000
    static let targetSamples = 16000 * 30   // 480 000

    private lazy var filterbank: [Float] = buildHTKMelFilterbank()
    private lazy var window: [Float] = buildHannWindow(length: Self.nFFT)

    /// Extract mel features and return an ORT tensor of shape [1, 80, 3000].
    func extract(samples: [Float]) throws -> ORTValue {
        let padded = padOrTruncate(samples, to: Self.targetSamples)
        let power = try stftPower(signal: padded)
        let mel = applyFilterbank(power: power)
        let normed = Self.logAndNormalise(mel)
        let data = NSMutableData(bytes: normed, length: normed.count * MemoryLayout<Float>.stride)
        let shape: [NSNumber] = [1, NSNumber(value: Self.nMels), NSNumber(value: Self.targetFrames)]
        return try ORTValue(tensorData: data, elementType: .float, shape: shape)
    }

    // MARK: Helpers

    private func padOrTruncate(_ samples: [Float], to length: Int) -> [Float] {
        if samples.count == length { return samples }
        if samples.count > length { return Array(samples.prefix(length)) }
        var out = samples
        out.append(contentsOf: [Float](repeating: 0, count: length - samples.count))
        return out
    }

    /// Short-time Fourier transform power spectrum using reflect-padding centring
    /// (pad = nFFT / 2 on each side), producing exactly 3000 frames for a
    /// 480 000-sample input. Output is `[nFreqs × nFrames]` row-major where
    /// `nFreqs = nFFT / 2 + 1 = 201`.
    private func stftPower(signal: [Float]) throws -> [Float] {
        let nFFT = Self.nFFT
        let hop = Self.hopLength
        let pad = nFFT / 2
        let padded = reflectPad(signal, padSize: pad)
        let nFreqs = nFFT / 2 + 1
        let nFrames = 1 + (padded.count - nFFT) / hop

        var power = [Float](repeating: 0, count: nFreqs * nFrames)

        let log2n = vDSP_Length(log2(Float(nFFT)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw MurmurError.transcriptionFailed("LID vDSP_create_fftsetup failed (log2n=\(log2n))")
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var real = [Float](repeating: 0, count: nFFT / 2)
        var imag = [Float](repeating: 0, count: nFFT / 2)

        for frame in 0..<nFrames {
            let start = frame * hop
            var windowed = [Float](repeating: 0, count: nFFT)
            padded.withUnsafeBufferPointer { sigPtr in
                window.withUnsafeBufferPointer { winPtr in
                    vDSP_vmul(sigPtr.baseAddress! + start, 1,
                              winPtr.baseAddress!, 1,
                              &windowed, 1,
                              vDSP_Length(nFFT))
                }
            }

            real.withUnsafeMutableBufferPointer { rPtr in
                imag.withUnsafeMutableBufferPointer { iPtr in
                    var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    windowed.withUnsafeBufferPointer { wPtr in
                        wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nFFT / 2) { cPtr in
                            vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(nFFT / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                    // vDSP packs DC in realp[0] and Nyquist in imagp[0].
                    // The conventional FFT output is half-scaled; for LID we
                    // only need relative magnitudes, so we skip the 0.5 scale.
                    let dc = rPtr[0]
                    power[0 * nFrames + frame] = dc * dc
                    for k in 1..<(nFFT / 2) {
                        let re = rPtr[k]
                        let im = iPtr[k]
                        power[k * nFrames + frame] = re * re + im * im
                    }
                    let nyq = iPtr[0]
                    power[(nFFT / 2) * nFrames + frame] = nyq * nyq
                }
            }
        }

        // Whisper pads/truncates to exactly 3000 frames.
        if nFrames == Self.targetFrames { return power }
        var fixed = [Float](repeating: 0, count: nFreqs * Self.targetFrames)
        let copyFrames = min(nFrames, Self.targetFrames)
        for k in 0..<nFreqs {
            for t in 0..<copyFrames {
                fixed[k * Self.targetFrames + t] = power[k * nFrames + t]
            }
        }
        return fixed
    }

    private func applyFilterbank(power: [Float]) -> [Float] {
        let nFreqs = Self.nFFT / 2 + 1
        let nFrames = Self.targetFrames
        let nMels = Self.nMels
        var mel = [Float](repeating: 0, count: nMels * nFrames)
        filterbank.withUnsafeBufferPointer { fb in
            power.withUnsafeBufferPointer { ps in
                mel.withUnsafeMutableBufferPointer { ms in
                    vDSP_mmul(
                        fb.baseAddress!, 1,
                        ps.baseAddress!, 1,
                        ms.baseAddress!, 1,
                        vDSP_Length(nMels),
                        vDSP_Length(nFrames),
                        vDSP_Length(nFreqs)
                    )
                }
            }
        }
        return mel
    }

    /// Applies Whisper's log-mel normalisation:
    ///     log_spec = log10(max(mel, 1e-10))
    ///     log_spec = max(log_spec, log_spec.max() - 8.0)
    ///     log_spec = (log_spec + 4.0) / 4.0
    /// Returned layout is `[1, 80, 3000]` (row-major in mel, then frame).
    private static func logAndNormalise(_ mel: [Float]) -> [Float] {
        var out = mel
        let eps: Float = 1e-10
        var lower = eps
        vDSP_vthr(out, 1, &lower, &out, 1, vDSP_Length(out.count))
        var n = Int32(out.count)
        // log10 in-place via log then scale by 1/ln(10) is cheaper than vvlog10f,
        // but vvlog10f is accurate and negligible cost at this size.
        vvlog10f(&out, out, &n)

        var globalMax: Float = 0
        vDSP_maxv(out, 1, &globalMax, vDSP_Length(out.count))
        var floorVal = globalMax - 8.0
        vDSP_vthr(out, 1, &floorVal, &out, 1, vDSP_Length(out.count))

        var addFour: Float = 4.0
        vDSP_vsadd(out, 1, &addFour, &out, 1, vDSP_Length(out.count))
        var invFour: Float = 0.25
        vDSP_vsmul(out, 1, &invFour, &out, 1, vDSP_Length(out.count))
        return out
    }

    private func reflectPad(_ signal: [Float], padSize: Int) -> [Float] {
        let n = signal.count
        if padSize <= 0 || n < 2 { return signal }
        var out = [Float](repeating: 0, count: n + 2 * padSize)
        for i in 0..<padSize {
            out[i] = signal[min(padSize - i, n - 1)]
        }
        for i in 0..<n { out[padSize + i] = signal[i] }
        for i in 0..<padSize {
            out[n + padSize + i] = signal[max(n - 2 - i, 0)]
        }
        return out
    }

    private func buildHannWindow(length: Int) -> [Float] {
        var w = [Float](repeating: 0, count: length)
        for i in 0..<length {
            // Periodic (DFT-even) Hann window — matches numpy.hanning(N) used by
            // Whisper's training preprocessing. Divide by `length`, not `length - 1`.
            w[i] = 0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / Float(length)))
        }
        return w
    }

    /// HTK-style mel filterbank — Whisper's reference implementation (transformers'
    /// WhisperFeatureExtractor) uses HTK mel (not Slaney) with `norm='slaney'`
    /// shape-only normalisation. Empirically produces triangular filters with
    /// `2 / (f_hi - f_lo)` peak normalisation matching librosa's `slaney` norm.
    private func buildHTKMelFilterbank() -> [Float] {
        let sr = Double(Self.sampleRate)
        let nFFT = Self.nFFT
        let nMels = Self.nMels
        let nFreqs = nFFT / 2 + 1
        let fMin: Double = 0.0
        let fMax: Double = sr / 2.0

        let melMin = hzToMelHTK(fMin)
        let melMax = hzToMelHTK(fMax)
        let nPoints = nMels + 2
        var melPoints = [Double](repeating: 0, count: nPoints)
        for i in 0..<nPoints {
            melPoints[i] = melMin + Double(i) * (melMax - melMin) / Double(nPoints - 1)
        }
        let hzPoints = melPoints.map { melToHzHTK($0) }
        let binPoints = hzPoints.map { $0 * Double(nFFT) / sr }

        var fb = [Float](repeating: 0, count: nMels * nFreqs)
        for m in 0..<nMels {
            let lo = binPoints[m]
            let center = binPoints[m + 1]
            let hi = binPoints[m + 2]
            let norm = 2.0 / (hzPoints[m + 2] - hzPoints[m])
            for k in 0..<nFreqs {
                let kd = Double(k)
                var w = 0.0
                if kd >= lo && kd <= center {
                    w = (kd - lo) / (center - lo)
                } else if kd > center && kd <= hi {
                    w = (hi - kd) / (hi - center)
                }
                fb[m * nFreqs + k] = Float(w * norm)
            }
        }
        return fb
    }

    private func hzToMelHTK(_ hz: Double) -> Double {
        return 2595.0 * log10(1.0 + hz / 700.0)
    }

    private func melToHzHTK(_ mel: Double) -> Double {
        return 700.0 * (pow(10.0, mel / 2595.0) - 1.0)
    }
}
