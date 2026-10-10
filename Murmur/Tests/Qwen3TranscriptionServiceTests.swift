import XCTest
@testable import Murmur
import AVFoundation

/// Skip-if-model-missing tests against the sherpa-onnx Qwen3-ASR-0.6B int8 model.
/// The transcription tests run only on dev machines where the model has been downloaded under
/// ~/Library/Application Support/Murmur/Models-Qwen3ASR/.
final class Qwen3TranscriptionServiceTests: XCTestCase {

    private var fixtureDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("test_fixtures")
    }

    private var modelDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Models-Qwen3ASR")
    }

    private func loadSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        if format.commonFormat == .pcmFormatFloat32 && format.sampleRate == 16000 && format.channelCount == 1 {
            guard let data = buffer.floatChannelData?[0] else {
                XCTFail("No float channel data in test wav")
                return []
            }
            return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        XCTFail("Test fixtures must be 16 kHz mono Float32 wav")
        return []
    }

    func test_preload_throwsModelNotFoundWhenModelDirMissing() async {
        let bogus = URL(fileURLWithPath: "/tmp/this-qwen3-dir-does-not-exist-\(UUID().uuidString)")
        let svc = Qwen3TranscriptionService(modelDirectory: bogus)
        do {
            try await svc.preloadModel()
            XCTFail("Expected preloadModel to throw modelNotFound")
        } catch MurmurError.modelNotFound {
            // expected
        } catch {
            XCTFail("Expected MurmurError.modelNotFound, got \(error)")
        }
    }

    func test_preload_throwsWhenTokenizerMissing() async throws {
        // A directory holding the three graphs but no tokenizer/ must be rejected
        // up front rather than crashing inside sherpa-onnx.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen3-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let svc = Qwen3TranscriptionService(modelDirectory: dir)
        do {
            try await svc.preloadModel()
            XCTFail("Expected preloadModel to throw when tokenizer files are missing")
        } catch {
            // expected
        }
    }

    func test_transcribeFile_withoutModel_throwsModelNotFound() async {
        let svc = Qwen3TranscriptionService(
            modelDirectory: URL(fileURLWithPath: "/tmp/no-qwen3-model-\(UUID().uuidString)"))
        let wavURL = fixtureDir.appendingPathComponent("test_chinese.wav")
        do {
            _ = try await svc.transcribe(audioURL: wavURL, language: "zh")
            XCTFail("Expected transcribe to throw without a model")
        } catch MurmurError.modelNotFound {
            // expected
        } catch {
            XCTFail("Expected MurmurError.modelNotFound, got \(error)")
        }
    }

    func test_transcribe_cnEnMixed_keepsEnglishTermsAndPunctuates() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path),
                          "Qwen3-ASR model not installed at \(modelDir.path) — select it in Settings and download")
        let wavURL = fixtureDir.appendingPathComponent("test_chinese_en.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavURL.path))

        let svc = Qwen3TranscriptionService(modelDirectory: modelDir)
        let text = try await svc.transcribe(samples: try loadSamples(url: wavURL), sampleRate: 16000)

        let lower = text.lowercased()
        XCTAssertTrue(lower.contains("machine learning"), "got: \(text)")
        XCTAssertTrue(lower.contains("deep learning"), "got: \(text)")
        XCTAssertTrue(text.contains("基本功"), "got: \(text)")
        XCTAssertTrue(text.contains("，") || text.contains("。"),
                      "Qwen3-ASR should emit its own punctuation, got: \(text)")
    }

    func test_transcribe_shortChineseHello_containsExpected() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path))
        let wavURL = fixtureDir.appendingPathComponent("test_chinese.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavURL.path))

        let svc = Qwen3TranscriptionService(modelDirectory: modelDir)
        let text = try await svc.transcribe(samples: try loadSamples(url: wavURL), sampleRate: 16000)

        XCTAssertTrue(text.contains("你好"), "Expected '你好' in Qwen3 output, got: \(text)")
    }

    // MARK: - Output cleaning and corruption checks (no model needed)

    func test_cleaned_stripsTemplateScaffolding() {
        XCTAssertEqual(Qwen3TranscriptionService.cleaned("language Chinese<asr_text>你好。"), "你好。")
        XCTAssertEqual(Qwen3TranscriptionService.cleaned("<asr_text>system没有诊断修复。"), "没有诊断修复。")
        XCTAssertEqual(Qwen3TranscriptionService.cleaned("会有更多。<|endoftext|>Human Rights Watch"), "会有更多。")
    }

    func test_cleaned_keepsOrdinaryTextThatStartsWithARoleWord() {
        XCTAssertEqual(Qwen3TranscriptionService.cleaned("  system design 很重要 "), "system design 很重要")
    }

    func test_detectLanguage_tagsByScript() {
        XCTAssertEqual(Qwen3TranscriptionService.detectLanguage("你好呀，现在可以了吗？"), .chinese)
        XCTAssertEqual(Qwen3TranscriptionService.detectLanguage("Hello there, how are you?"), .english)
        XCTAssertEqual(Qwen3TranscriptionService.detectLanguage("我们用 Python 写 machine learning 的代码"), .chinese)
        XCTAssertEqual(Qwen3TranscriptionService.detectLanguage("こんにちは"), .unknown)
        XCTAssertEqual(Qwen3TranscriptionService.detectLanguage("。。。"), .unknown)
    }

    func test_detectLanguage_japaneseWithManyKanjiIsNotChinese() {
        // Over a third of these letters are characters Chinese also uses.
        XCTAssertEqual(
            Qwen3TranscriptionService.detectLanguage("抜群の運動神経を持ち合わせ、どんな要求にも応えてきた。"),
            .unknown
        )
    }

    func test_segmentRanges_shortAudioIsOneRange() {
        let samples = [Float](repeating: 0.1, count: 16000 * 20)
        XCTAssertEqual(Qwen3TranscriptionService.segmentRanges(samples: samples, sampleRate: 16000), [0..<samples.count])
    }

    func test_segmentRanges_longAudioIsCutAtThePause() {
        // 100 s of "speech" with one 1 s pause at 35–36 s.
        var samples = [Float](repeating: 0.1, count: 16000 * 100)
        for i in (16000 * 35)..<(16000 * 36) { samples[i] = 0 }
        let ranges = Qwen3TranscriptionService.segmentRanges(samples: samples, sampleRate: 16000)

        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, samples.count)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(a.upperBound, b.lowerBound, "ranges must tile the audio with no gap or overlap")
        }
        let limit = Int(Qwen3TranscriptionService.maxSegmentSeconds * 16000)
        XCTAssertTrue(ranges.allSatisfy { $0.count <= limit })
        let firstCut = ranges[0].upperBound
        XCTAssertTrue((16000 * 35...16000 * 36).contains(firstCut), "first cut should land inside the pause, got \(firstCut)")
    }

    func test_joined_spacesOnlyBetweenLatinWords() {
        XCTAssertEqual(Qwen3TranscriptionService.joined(["你好。", "现在可以了吗？"]), "你好。现在可以了吗？")
        XCTAssertEqual(Qwen3TranscriptionService.joined(["Hello there.", "How are you?"]), "Hello there. How are you?")
        XCTAssertEqual(Qwen3TranscriptionService.joined(["我们用", "Python"]), "我们用Python")
    }

    func test_paragraphRanges_splitAtLongSilenceOnly() {
        // speech 0–5 s, 1 s pause, speech 6–10 s, 3 s silence, speech 13–16 s
        var samples = [Float](repeating: 0, count: 16000 * 16)
        for range in [0..<5, 6..<10, 13..<16] {
            for i in (16000 * range.lowerBound)..<(16000 * range.upperBound) { samples[i] = 0.1 }
        }
        let ranges = Qwen3TranscriptionService.paragraphRanges(samples: samples, sampleRate: 16000)

        XCTAssertEqual(ranges.count, 2, "only the 3 s silence is a paragraph break")
        // First paragraph spans both utterances, including the 1 s pause between them.
        XCTAssertLessThanOrEqual(ranges[0].lowerBound, 0)
        XCTAssertGreaterThanOrEqual(ranges[0].upperBound, 16000 * 10)
        XCTAssertLessThan(ranges[0].upperBound, 16000 * 11)
        // Second paragraph starts just before the last utterance.
        XCTAssertLessThanOrEqual(ranges[1].lowerBound, 16000 * 13)
        XCTAssertGreaterThan(ranges[1].lowerBound, 16000 * 12)
        XCTAssertEqual(ranges[1].upperBound, samples.count)
    }

    func test_paragraphRanges_silenceOnlyAudioHasNoParagraphs() {
        let samples = [Float](repeating: 0, count: 16000 * 5)
        XCTAssertTrue(Qwen3TranscriptionService.paragraphRanges(samples: samples, sampleRate: 16000).isEmpty)
    }
}
