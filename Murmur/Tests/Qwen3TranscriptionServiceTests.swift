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

    /// 16 kHz samples, loud (0.1) inside each `(start, end)` in seconds and silent elsewhere.
    private func speech(_ parts: [(Double, Double)], seconds: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * 16000))
        for (start, end) in parts {
            for i in Int(start * 16000)..<Int(end * 16000) { samples[i] = 0.1 }
        }
        return samples
    }

    func test_speechSpans_breakAtEveryLongSilence_andAtAPauseOnlyAfterTenSeconds() {
        // 1.2 s pause after 5 s of speech: too early. 1.5 s pause after 14 s: a
        // break. 2.5 s silence after 4.5 s: a paragraph break.
        let samples = speech([(0, 5), (6.2, 14), (15.5, 20), (22.5, 24)], seconds: 24)

        let spans = Qwen3TranscriptionService.speechSpans(samples: samples, sampleRate: 16000)

        XCTAssertEqual(spans.map(\.speech), [0..<(14 * 16000), (15.5 * 16000).asInt..<(20 * 16000), (22.5 * 16000).asInt..<(24 * 16000)])
        XCTAssertEqual(spans.map(\.startsParagraph), [false, false, true])
    }

    func test_speechSpans_decodeAMarginAroundTheSpeech() {
        let samples = speech([(1, 12), (13.5, 20)], seconds: 21)

        let spans = Qwen3TranscriptionService.speechSpans(samples: samples, sampleRate: 16000)

        XCTAssertEqual(spans.map(\.range), [(0.7 * 16000).asInt..<(12.3 * 16000).asInt, (13.2 * 16000).asInt..<(20.3 * 16000).asInt])
    }

    func test_speechSpans_silenceOnlyAudioHasNone() {
        let samples = [Float](repeating: 0, count: 16000 * 5)
        XCTAssertTrue(Qwen3TranscriptionService.speechSpans(samples: samples, sampleRate: 16000).isEmpty)
    }

    func test_segmentBuilder_timesComeFromTheSpeechAtTheEdgesAndFromTheCutsInside() {
        typealias Span = Qwen3TranscriptionService.SpeechSpan
        // A 70 s span (speech 1–71 s, decoded with a 0.3 s margin) cut at 40.7 s.
        let span = Span(range: 11_200..<1_140_800, speech: 16_000..<1_136_000, startsParagraph: false)
        var builder = Qwen3TranscriptionService.SegmentBuilder(sampleRate: 16_000)

        builder.add("one", piece: 11_200..<651_200, index: 0, of: 2, in: span)
        builder.add("two", piece: 651_200..<1_140_800, index: 1, of: 2, in: span)

        XCTAssertEqual(builder.segments.map(\.start), [1.0, 40.7])
        XCTAssertEqual(builder.segments.map(\.end), [40.7, 71.0])
    }

    func test_segmentBuilder_paragraphBreakSurvivesASpanThatDecodesToNothing() {
        typealias Span = Qwen3TranscriptionService.SpeechSpan
        let first = Span(range: 0..<160_000, speech: 0..<160_000, startsParagraph: false)
        let cough = Span(range: 200_000..<210_000, speech: 200_000..<210_000, startsParagraph: true)
        let next = Span(range: 230_000..<300_000, speech: 230_000..<300_000, startsParagraph: false)
        var builder = Qwen3TranscriptionService.SegmentBuilder(sampleRate: 16_000)

        builder.add("Before the break.", piece: first.range, index: 0, of: 1, in: first)
        builder.add("", piece: cough.range, index: 0, of: 1, in: cough)
        builder.add("After the break.", piece: next.range, index: 0, of: 1, in: next)

        XCTAssertEqual(builder.segments.map(\.startsParagraph), [false, true])
    }

    func test_textOfSegments_blankLineBeforeEachParagraph() {
        let segments = [
            TranscriptSegment(start: 0, end: 4, text: "Hello there."),
            TranscriptSegment(start: 5, end: 9, text: "How are you?"),
            TranscriptSegment(start: 12, end: 14, text: "我很好。", startsParagraph: true),
        ]
        XCTAssertEqual(Qwen3TranscriptionService.text(of: segments), "Hello there. How are you?\n\n我很好。")
    }
}

private extension Double {
    var asInt: Int { Int(self.rounded()) }
}
