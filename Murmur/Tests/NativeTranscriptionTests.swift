import XCTest
@testable import Murmur
import AVFoundation
import OnnxRuntimeBindings

/// Comprehensive tests for the native ONNX transcription pipeline.
/// Covers: BPETokenizerDecoder, ONNXTranscriptionBackend,
/// language routing, and full pipeline for EN/ZH/mixed.
///
/// Heavy: every test in this class loads a real ONNX session
/// (~hundreds of MB RAM) when the model directory is present.
/// Gated behind `MURMUR_RUN_HEAVY_TESTS=1` — see `TestHeavyGate`.
final class NativeTranscriptionTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        try TestHeavyGate.requireOptIn()
    }

    // MARK: - Fixtures

    private var fixtureDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("test_fixtures")
    }

    private var modelDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Models-ONNX")
    }

    private lazy var refs: [String: Any] = {
        let url = fixtureDir.appendingPathComponent("transcription_refs.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func ref(_ key: String) -> [String: Any] {
        refs[key] as! [String: Any]
    }

    // MARK: - ONNX Mel Extraction Tests

    func testONNXMelExtraction() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path))
        let wavURL = fixtureDir.appendingPathComponent("test_2s_sine.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavURL.path))

        let backend = try ONNXTranscriptionBackend(modelDirectory: modelDir)
        let samples = try loadTestAudio(url: wavURL)
        let (_, frameCount) = try backend.extractMelFeatures(samples: samples)
        XCTAssertGreaterThan(frameCount, 0)
    }

    // MARK: - BPETokenizerDecoder Tests

    func testTokenizerLoads() throws {
        let path = modelDir.appendingPathComponent("tokenizer.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path.path))
        let tokenizer = try BPETokenizerDecoder(tokenizerJSONPath: path)
        _ = tokenizer // no crash
    }

    func testTokenizerDecodeEnglish() throws {
        let tokenizer = try makeTokenizer()
        // "Thank you." token IDs from Python reference
        let ids: [Int32] = [13764, 7, 4, 16, 62, 62, 5, 9, 11, 13, 1691, 573, 13785, 3]
        let text = tokenizer.decode(ids, skipSpecialTokens: true)
        XCTAssertEqual(text, "Thank you.")
    }

    func testTokenizerDecodeChinese() throws {
        let tokenizer = try makeTokenizer()
        // "你好呀" — token IDs from Python reference
        let ids: [Int32] = [13764, 7, 4, 16, 50, 50, 5, 9, 11, 13, 5856, 14263, 14808, 3]
        let text = tokenizer.decode(ids, skipSpecialTokens: true)
        XCTAssertTrue(text.contains("你好"), "Expected Chinese text, got: \(text)")
    }

    func testTokenizerDecodeChineseEnglishMixed() throws {
        let tokenizer = try makeTokenizer()
        // Simulate mixed: "你好 Thank you" — combine Chinese + English token IDs
        let zhIds: [Int32] = [5856, 14263, 14808]  // 你好呀
        let enIds: [Int32] = [1691, 573]  // Thank you
        let allIds: [Int32] = [13764, 7, 4, 16, 50, 50, 5, 9, 11, 13] + zhIds + enIds + [3]
        let text = tokenizer.decode(allIds, skipSpecialTokens: true)
        XCTAssertTrue(text.contains("你好"), "Missing Chinese: \(text)")
        XCTAssertTrue(text.contains("Thank"), "Missing English: \(text)")
    }

    func testTokenizerSkipSpecialTokens() throws {
        let tokenizer = try makeTokenizer()
        // Only special tokens → empty
        let ids: [Int32] = [13764, 7, 4, 16, 62, 62, 5, 9, 11, 13, 3]
        let text = tokenizer.decode(ids, skipSpecialTokens: true)
        XCTAssertTrue(text.isEmpty, "Should be empty when only special tokens, got: '\(text)'")
    }

    func testTokenizerKeepSpecialTokens() throws {
        let tokenizer = try makeTokenizer()
        let ids: [Int32] = [1691, 573]  // Thank you
        let text = tokenizer.decode(ids, skipSpecialTokens: false)
        XCTAssertTrue(text.contains("Thank"))
    }

    func testTokenizerEmptyInput() throws {
        let tokenizer = try makeTokenizer()
        let text = tokenizer.decode([], skipSpecialTokens: true)
        XCTAssertTrue(text.isEmpty)
    }

    // MARK: - Decoder Prompt Tests

    func testDecoderPromptEnglish() {
        let prompt = ONNXTranscriptionBackend.decoderPrompt(for: "en")
        XCTAssertEqual(prompt, [13764, 7, 4, 16, 62, 62, 5, 9, 11, 13])
    }

    func testDecoderPromptChinese() {
        let prompt = ONNXTranscriptionBackend.decoderPrompt(for: "zh")
        XCTAssertEqual(prompt, [13764, 7, 4, 16, 50, 50, 5, 9, 11, 13])
    }

    func testDecoderPromptJapanese() {
        let prompt = ONNXTranscriptionBackend.decoderPrompt(for: "ja")
        XCTAssertEqual(prompt, [13764, 7, 4, 16, 97, 97, 5, 9, 11, 13])
    }

    func testDecoderPromptKorean() {
        let prompt = ONNXTranscriptionBackend.decoderPrompt(for: "ko")
        XCTAssertEqual(prompt, [13764, 7, 4, 16, 118, 118, 5, 9, 11, 13])
    }

    func testDecoderPromptAllLanguages() {
        let langs = ["en", "zh", "ja", "ko", "fr", "de", "es", "pt", "it", "nl", "pl", "el", "ar", "vi"]
        for lang in langs {
            let prompt = ONNXTranscriptionBackend.decoderPrompt(for: lang)
            XCTAssertEqual(prompt.count, 10, "Prompt length wrong for \(lang)")
            XCTAssertEqual(prompt[0], 13764, "Start token wrong for \(lang)")
            // Language tokens at positions 4 and 5 should match
            XCTAssertEqual(prompt[4], prompt[5], "Language tokens should be same for \(lang)")
            XCTAssertNotNil(ONNXTranscriptionBackend.languageTokenIds[lang], "Missing lang: \(lang)")
        }
    }

    func testDecoderPromptUnknownFallsToEnglish() {
        let prompt = ONNXTranscriptionBackend.decoderPrompt(for: "xx")
        let enPrompt = ONNXTranscriptionBackend.decoderPrompt(for: "en")
        XCTAssertEqual(prompt, enPrompt, "Unknown language should fall back to English")
    }

    // MARK: - Encoder Tests

    func testEncoderProducesOutput() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path))
        let backend = try ONNXTranscriptionBackend(modelDirectory: modelDir)

        let samples = [Float](repeating: 0.1, count: 16000)
        let (melFeatures, _) = try backend.extractMelFeatures(samples: samples)
        let output = try backend.encodeFromMel(melFeatures)
        let data = try output.tensorData()
        XCTAssertGreaterThan(data.count, 0, "Encoder output should not be empty")
    }

    func testEncoderRejectsWrongFeatureCount() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path))
        let backend = try ONNXTranscriptionBackend(modelDirectory: modelDir)

        XCTAssertThrowsError(try backend.encode(features: [1.0, 2.0], frameCount: 1)) { error in
            XCTAssertTrue("\(error)".contains("expected"), "Should mention expected count")
        }
    }

    // MARK: - Full Pipeline Tests

    func testFullPipeline_English() throws {
        let wavURL = fixtureDir.appendingPathComponent("test_2s_sine.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavURL.path))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path))

        let (text, tokenIds) = try runPipeline(wavURL: wavURL, language: "en")
        print("EN pipeline: '\(text)' tokens=\(tokenIds)")

        let expectedText = (ref("english_wav_en")["text"] as! String)
        XCTAssertEqual(text, expectedText, "EN transcription mismatch")
    }

    func testFullPipeline_Chinese() throws {
        let wavURL = fixtureDir.appendingPathComponent("test_chinese.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavURL.path))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path))

        let (text, tokenIds) = try runPipeline(wavURL: wavURL, language: "zh")
        print("ZH pipeline: '\(text)' tokens=\(tokenIds)")

        let expectedText = ref("chinese_wav_zh")["text"] as! String

        // Text-level comparison (token IDs may differ by trailing eos token)
        XCTAssertEqual(text, expectedText, "ZH text mismatch: Swift='\(text)' Python='\(expectedText)'")
    }

    func testFullPipeline_ChineseWavWithEnglishPrompt() throws {
        // Demonstrates that wrong language prompt degrades output
        let wavURL = fixtureDir.appendingPathComponent("test_chinese.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavURL.path))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path))

        let (textZh, _) = try runPipeline(wavURL: wavURL, language: "zh")
        let (textEn, _) = try runPipeline(wavURL: wavURL, language: "en")

        print("ZH prompt → '\(textZh)'")
        print("EN prompt → '\(textEn)'")

        // Both should produce valid non-empty transcriptions
        XCTAssertFalse(textZh.isEmpty)
        XCTAssertFalse(textEn.isEmpty)
    }

    // MARK: - Language Detection Tests

    func testDetectLanguageChinese() {
        // 70% Chinese chars → should detect as Chinese
        XCTAssertEqual(detectLang("你好世界hello"), .chinese)
    }

    func testDetectLanguageEnglish() {
        XCTAssertEqual(detectLang("Hello world"), .english)
    }

    func testDetectLanguageMixed_MostlyChinese() {
        // > 30% Chinese → Chinese. Note: CharacterSet.letters includes CJK,
        // so "你好hello" = 2 Chinese / 7 letters = 28% < 30% = English.
        // Need more Chinese chars to cross threshold.
        XCTAssertEqual(detectLang("你好世界你好hello"), .chinese)
    }

    func testDetectLanguageMixed_MostlyEnglish() {
        // < 30% Chinese → English
        XCTAssertEqual(detectLang("Hello world 你"), .english)
    }

    func testDetectLanguageEmpty() {
        XCTAssertEqual(detectLang(""), .english)
    }

    // MARK: - Audio Loading Tests

    func testLoadAudioPreservesLength() throws {
        let wavURL = fixtureDir.appendingPathComponent("test_2s_sine.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavURL.path))

        let refURL = fixtureDir.appendingPathComponent("test_2s_sine_mel_ref.json")
        let refData = try Data(contentsOf: refURL)
        let refJSON = try JSONSerialization.jsonObject(with: refData) as! [String: Any]
        let expectedSamples = refJSON["num_samples"] as! Int

        let samples = try loadTestAudio(url: wavURL)
        XCTAssertEqual(samples.count, expectedSamples,
                       "Audio loading should preserve exact sample count")
    }

    // MARK: - Integration: NativeTranscriptionService

    func testNativeServicePreloadAndTranscribe() async throws {
        let wavURL = fixtureDir.appendingPathComponent("test_2s_sine.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavURL.path))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path))

        let service = NativeTranscriptionService(modelPath: modelDir)
        try await service.preloadModel()

        let result = try await service.transcribe(audioURL: wavURL, language: "en")
        XCTAssertFalse(result.text.isEmpty, "Should produce non-empty text")
        XCTAssertGreaterThan(result.durationMs, 0)
        print("Service result: '\(result.text)' lang=\(result.language) \(result.durationMs)ms")
    }

    // MARK: - Helpers

    private func makeTokenizer() throws -> BPETokenizerDecoder {
        let path = modelDir.appendingPathComponent("tokenizer.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path.path))
        return try BPETokenizerDecoder(tokenizerJSONPath: path)
    }

    private func runPipeline(wavURL: URL, language: String) throws -> (String, [Int32]) {
        let backend = try ONNXTranscriptionBackend(modelDirectory: modelDir)
        let tokenizer = try BPETokenizerDecoder(
            tokenizerJSONPath: modelDir.appendingPathComponent("tokenizer.json"))

        let samples = try loadTestAudio(url: wavURL)
        let (melFeatures, _) = try backend.extractMelFeatures(samples: samples)
        let encoderHidden = try backend.encodeFromMel(melFeatures)
        let prompt = ONNXTranscriptionBackend.decoderPrompt(for: language)
        let tokenIds = try backend.decode(
            encoderHidden: encoderHidden,
            decoderPrompt: prompt,
            eosTokenId: ONNXTranscriptionBackend.eosTokenId,
            maxTokens: ONNXTranscriptionBackend.maxTokens)
        let text = tokenizer.decode(tokenIds, skipSpecialTokens: true)
        return (text, tokenIds)
    }

    private func detectLang(_ text: String) -> DetectedLanguage {
        let chineseChars = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let totalAlpha = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        if totalAlpha > 0 && Double(chineseChars) / Double(totalAlpha) > 0.3 {
            return .chinese
        }
        return .english
    }

    private func loadTestAudio(url: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

        if format.sampleRate == 16000 && format.channelCount == 1 {
            let srcBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            try audioFile.read(into: srcBuffer)

            if format.commonFormat == .pcmFormatFloat32 {
                guard let data = srcBuffer.floatChannelData?[0] else {
                    throw MurmurError.transcriptionFailed("No float data")
                }
                return Array(UnsafeBufferPointer(start: data, count: Int(srcBuffer.frameLength)))
            }

            // Convert e.g. Int16 → Float32
            let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)!
            guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
                throw MurmurError.transcriptionFailed("Cannot create converter")
            }
            var error: NSError?
            converter.convert(to: outBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return srcBuffer
            }
            guard let data = outBuffer.floatChannelData?[0] else {
                throw MurmurError.transcriptionFailed("No converted data")
            }
            return Array(UnsafeBufferPointer(start: data, count: Int(outBuffer.frameLength)))
        }
        throw MurmurError.transcriptionFailed("Test fixture must be 16kHz mono")
    }
}
