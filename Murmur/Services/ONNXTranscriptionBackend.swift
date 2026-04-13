import Foundation
import Accelerate
import OnnxRuntimeBindings

// MARK: - ONNXTranscriptionBackend

/// Pure-Swift ONNX inference backend for CohereASR models.
///
/// Loads the quantised encoder and decoder ONNX models and runs greedy
/// autoregressive decoding entirely in-process, with no Python subprocess.
///
/// Thread-safety: instances are not thread-safe; callers must serialise access
/// (e.g. wrap in a Swift actor or dispatch queue).
final class ONNXTranscriptionBackend {

    // MARK: - Constants

    static let numDecoderLayers = 8
    static let numHeads = 8
    static let headDim = 128
    static let vocabSize = 16384

    static let decoderStartTokenId: Int32 = 13764
    static let eosTokenId: Int32 = 3
    static let maxTokens = 448

    private static let melBins = 128

    // MARK: - Language token IDs

    static let languageTokenIds: [String: Int32] = [
        "en": 62, "zh": 50, "ja": 97, "ko": 118,
        "fr": 69, "de": 76, "es": 169, "pt": 148,
        "it": 92, "nl": 61, "pl": 147, "el": 78,
        "ar": 20, "vi": 193,
    ]

    // MARK: - Prompt Construction

    static func decoderPrompt(for language: String) -> [Int32] {
        let langToken = languageTokenIds[language] ?? languageTokenIds["en"]!
        return [13764, 7, 4, 16, langToken, langToken, 5, 9, 11, 13]
    }

    // MARK: - Properties

    private let env: ORTEnv
    private let melSession: ORTSession
    private let encoderSession: ORTSession
    private let decoderSession: ORTSession

    // MARK: - Initialization

    init(modelDirectory: URL) throws {
        let melPath = modelDirectory
            .appendingPathComponent("onnx/mel_extractor.onnx").path
        let encoderPath = modelDirectory
            .appendingPathComponent("onnx/encoder_model_q4f16.onnx").path
        let decoderPath = modelDirectory
            .appendingPathComponent("onnx/decoder_model_merged_q4f16.onnx").path

        let fm = FileManager.default
        guard fm.fileExists(atPath: melPath) else { throw MurmurError.modelNotFound }
        guard fm.fileExists(atPath: encoderPath) else { throw MurmurError.modelNotFound }
        guard fm.fileExists(atPath: decoderPath) else { throw MurmurError.modelNotFound }

        let ortEnv = try ORTEnv(loggingLevel: .warning)
        let melOpts = try ONNXTranscriptionBackend.makeSessionOptions()
        let encoderOpts = try ONNXTranscriptionBackend.makeSessionOptions()
        let decoderOpts = try ONNXTranscriptionBackend.makeSessionOptions()

        self.env = ortEnv
        self.melSession = try ORTSession(env: ortEnv, modelPath: melPath, sessionOptions: melOpts)
        self.encoderSession = try ORTSession(env: ortEnv, modelPath: encoderPath, sessionOptions: encoderOpts)
        self.decoderSession = try ORTSession(env: ortEnv, modelPath: decoderPath, sessionOptions: decoderOpts)
    }

    // MARK: - Mel Feature Extraction

    /// Extract mel spectrogram features from raw audio samples using the ONNX mel extractor.
    /// - Parameter samples: 16kHz mono Float32 audio samples.
    /// - Returns: `ORTValue` containing mel features of shape `[1, num_frames, 128]`.
    func extractMelFeatures(samples: [Float]) throws -> (ORTValue, Int) {
        let audioTensor = try makeFloat32Tensor(values: samples, shape: [1, samples.count])
        let inputs: [String: ORTValue] = ["audio": audioTensor]
        let outputNames: Set<String> = ["mel_features"]
        let results = try melSession.run(withInputs: inputs, outputNames: outputNames, runOptions: nil)
        guard let melFeatures = results["mel_features"] else {
            throw MurmurError.transcriptionFailed("Mel extractor output not found")
        }
        // Get frame count from tensor shape
        let shapeInfo = try melFeatures.tensorTypeAndShapeInfo()
        let shape = shapeInfo.shape  // expected [1, num_frames, 128]
        guard shape.count >= 2 else {
            throw MurmurError.transcriptionFailed("Unexpected mel shape: \(shape)")
        }
        let frameCount = shape[1].intValue
        return (melFeatures, frameCount)
    }

    // MARK: - Encode

    /// Run encoder on mel features ORTValue directly (from mel extractor output).
    func encodeFromMel(_ melFeatures: ORTValue) throws -> ORTValue {
        let inputs: [String: ORTValue] = ["input_features": melFeatures]
        let outputNames: Set<String> = ["last_hidden_state"]
        let results = try encoderSession.run(withInputs: inputs, outputNames: outputNames, runOptions: nil)
        guard let hiddenStates = results["last_hidden_state"] else {
            throw MurmurError.transcriptionFailed("Encoder output 'last_hidden_state' not found")
        }
        return hiddenStates
    }

    func encode(features: [Float], frameCount: Int) throws -> ORTValue {
        let elementCount = frameCount * ONNXTranscriptionBackend.melBins
        guard features.count == elementCount else {
            throw MurmurError.transcriptionFailed(
                "encode: expected \(elementCount) floats, got \(features.count)")
        }

        let inputTensor = try makeFloat32Tensor(
            values: features, shape: [1, frameCount, ONNXTranscriptionBackend.melBins])

        let inputs: [String: ORTValue] = ["input_features": inputTensor]
        let outputNames: Set<String> = ["last_hidden_state"]
        let results = try encoderSession.run(
            withInputs: inputs, outputNames: outputNames, runOptions: nil)

        guard let hiddenStates = results["last_hidden_state"] else {
            throw MurmurError.transcriptionFailed("Encoder output 'last_hidden_state' not found")
        }
        return hiddenStates
    }

    // MARK: - Decode

    func decode(
        encoderHidden: ORTValue,
        decoderPrompt: [Int32],
        eosTokenId: Int32,
        maxTokens: Int
    ) throws -> [Int32] {
        var generatedTokens: [Int32] = decoderPrompt
        var pastKeyValues = try makeInitialKVCache()

        // Step 0: full prompt
        let (logits0, presentKV0) = try runDecoderStep(
            inputIds: decoderPrompt.map { Int64($0) },
            pastKeyValues: pastKeyValues,
            encoderHidden: encoderHidden,
            pastLen: 0)
        pastKeyValues = presentKV0

        let nextToken0 = try argmaxFloat16Logits(logits0)
        if nextToken0 == eosTokenId { return generatedTokens }
        generatedTokens.append(nextToken0)

        // Subsequent steps: one token at a time
        var pastLen = decoderPrompt.count

        for _ in 0..<(maxTokens - 1) {
            guard let currentToken = generatedTokens.last else { break }
            let (logits, presentKV) = try runDecoderStep(
                inputIds: [Int64(currentToken)],
                pastKeyValues: pastKeyValues,
                encoderHidden: encoderHidden,
                pastLen: pastLen)
            pastKeyValues = presentKV
            pastLen += 1

            let nextToken = try argmaxFloat16Logits(logits)
            if nextToken == eosTokenId { break }
            generatedTokens.append(nextToken)
        }

        return generatedTokens
    }

    // MARK: - Private: Decoder Step

    private func runDecoderStep(
        inputIds: [Int64],
        pastKeyValues: [String: ORTValue],
        encoderHidden: ORTValue,
        pastLen: Int
    ) throws -> (ORTValue, [String: ORTValue]) {
        let curLen = inputIds.count

        let inputIdsTensor = try makeInt64Tensor(values: inputIds, shape: [1, curLen])

        let maskLen = pastLen + curLen
        let attentionMask = try makeInt64Tensor(
            values: [Int64](repeating: 1, count: maskLen), shape: [1, maskLen])

        let positionIds = try makeInt64Tensor(
            values: (pastLen..<(pastLen + curLen)).map { Int64($0) }, shape: [1, curLen])

        let numLogitsToKeep = try makeInt64Scalar(value: 1)

        var inputs: [String: ORTValue] = [
            "input_ids": inputIdsTensor,
            "attention_mask": attentionMask,
            "position_ids": positionIds,
            "num_logits_to_keep": numLogitsToKeep,
            "encoder_hidden_states": encoderHidden,
        ]
        for (key, value) in pastKeyValues {
            inputs[key] = value
        }

        var outputNames = Set<String>()
        outputNames.insert("logits")
        for i in 0..<ONNXTranscriptionBackend.numDecoderLayers {
            for suffix in ["decoder.key", "decoder.value", "encoder.key", "encoder.value"] {
                outputNames.insert("present.\(i).\(suffix)")
            }
        }

        let results = try decoderSession.run(
            withInputs: inputs, outputNames: outputNames, runOptions: nil)

        guard let logits = results["logits"] else {
            throw MurmurError.transcriptionFailed("Decoder output 'logits' not found")
        }

        var nextPastKeyValues: [String: ORTValue] = [:]
        for i in 0..<ONNXTranscriptionBackend.numDecoderLayers {
            for suffix in ["decoder.key", "decoder.value", "encoder.key", "encoder.value"] {
                let presentKey = "present.\(i).\(suffix)"
                let pastKey = "past_key_values.\(i).\(suffix)"
                guard let presentValue = results[presentKey] else {
                    throw MurmurError.transcriptionFailed("Missing decoder output: \(presentKey)")
                }
                nextPastKeyValues[pastKey] = presentValue
            }
        }

        return (logits, nextPastKeyValues)
    }

    // MARK: - Private: Argmax on Float16 Logits

    private func argmaxFloat16Logits(_ logitsTensor: ORTValue) throws -> Int32 {
        let rawData = try logitsTensor.tensorData() as Data

        let vocab = ONNXTranscriptionBackend.vocabSize
        let expectedBytes = vocab * 2
        guard rawData.count >= expectedBytes else {
            throw MurmurError.transcriptionFailed(
                "Logits tensor too small: \(rawData.count) bytes, need \(expectedBytes)")
        }

        // Take last vocabSize values (final position in sequence dimension)
        let offset = rawData.count - expectedBytes
        let logitsSlice = Data(rawData[offset...])
        let float32Logits = float16ToFloat32(logitsSlice, count: vocab)

        guard let maxIndex = float32Logits.indices.max(by: { float32Logits[$0] < float32Logits[$1] }) else {
            throw MurmurError.transcriptionFailed("Empty logits array")
        }
        return Int32(maxIndex)
    }

    // MARK: - Private: Float16 Conversion

    private func float16ToFloat32(_ data: Data, count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            guard let srcBase = raw.baseAddress else { return }
            let srcMutable = UnsafeMutableRawPointer(mutating: srcBase)
            var srcBuffer = vImage_Buffer(
                data: srcMutable, height: 1,
                width: vImagePixelCount(count), rowBytes: count * 2)
            result.withUnsafeMutableBytes { dstRaw in
                guard let dstBase = dstRaw.baseAddress else { return }
                var dstBuffer = vImage_Buffer(
                    data: dstBase, height: 1,
                    width: vImagePixelCount(count), rowBytes: count * 4)
                vImageConvert_Planar16FtoPlanarF(&srcBuffer, &dstBuffer, 0)
            }
        }
        return result
    }

    // MARK: - Private: KV Cache Initialization

    private func makeInitialKVCache() throws -> [String: ORTValue] {
        var kv: [String: ORTValue] = [:]
        let emptyData = NSMutableData()
        let shape: [NSNumber] = [
            1, NSNumber(value: ONNXTranscriptionBackend.numHeads),
            0, NSNumber(value: ONNXTranscriptionBackend.headDim),
        ]

        for i in 0..<ONNXTranscriptionBackend.numDecoderLayers {
            for suffix in ["decoder.key", "decoder.value", "encoder.key", "encoder.value"] {
                let key = "past_key_values.\(i).\(suffix)"
                let tensor = try ORTValue(tensorData: emptyData, elementType: .float16, shape: shape)
                kv[key] = tensor
            }
        }
        return kv
    }

    // MARK: - Private: Tensor Factories

    private func makeFloat32Tensor(values: [Float], shape: [Int]) throws -> ORTValue {
        let data = NSMutableData(bytes: values, length: values.count * MemoryLayout<Float>.stride)
        let nsShape = shape.map { NSNumber(value: $0) }
        return try ORTValue(tensorData: data, elementType: .float, shape: nsShape)
    }

    private func makeInt64Tensor(values: [Int64], shape: [Int]) throws -> ORTValue {
        let data = NSMutableData(bytes: values, length: values.count * MemoryLayout<Int64>.stride)
        let nsShape = shape.map { NSNumber(value: $0) }
        return try ORTValue(tensorData: data, elementType: .int64, shape: nsShape)
    }

    private func makeInt64Scalar(value: Int64) throws -> ORTValue {
        var scalar = value
        let data = NSMutableData(bytes: &scalar, length: MemoryLayout<Int64>.stride)
        return try ORTValue(tensorData: data, elementType: .int64, shape: [])
    }

    // MARK: - Private: Session Options

    private static func makeSessionOptions() throws -> ORTSessionOptions {
        let opts = try ORTSessionOptions()
        try opts.setIntraOpNumThreads(4)
        try opts.setGraphOptimizationLevel(.all)
        return opts
    }
}
