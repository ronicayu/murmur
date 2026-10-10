import XCTest
@testable import Murmur
import AVFoundation

/// Skip-if-model-missing tests against the sherpa-onnx Qwen3-ASR-0.6B int8 model.
/// Same pattern as FireRedTranscriptionServiceTests: the transcription tests run
/// only on dev machines where the model has been downloaded under
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

    func test_init_throwsModelNotFoundWhenModelDirMissing() {
        let bogus = URL(fileURLWithPath: "/tmp/this-qwen3-dir-does-not-exist-\(UUID().uuidString)")
        XCTAssertThrowsError(try Qwen3TranscriptionService(modelDirectory: bogus)) { error in
            guard case MurmurError.modelNotFound = error else {
                return XCTFail("Expected MurmurError.modelNotFound, got \(error)")
            }
        }
    }

    func test_init_throwsWhenTokenizerMissing() throws {
        // A directory holding the three graphs but no tokenizer/ must be rejected
        // up front rather than crashing inside sherpa-onnx.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen3-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        XCTAssertThrowsError(try Qwen3TranscriptionService(modelDirectory: dir))
    }

    func test_transcribe_cnEnMixed_keepsEnglishTermsAndPunctuates() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path),
                          "Qwen3-ASR model not installed at \(modelDir.path) — select it in Settings and download")
        let wavURL = fixtureDir.appendingPathComponent("test_chinese_en.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavURL.path))

        let svc = try Qwen3TranscriptionService(modelDirectory: modelDir)
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

        let svc = try Qwen3TranscriptionService(modelDirectory: modelDir)
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

    func test_looksCorrupt_flagsDebrisWrongScriptAndNearEmptyOutput() {
        // Undecodable bytes left over from leaked template text.
        XCTAssertTrue(Qwen3TranscriptionService.looksCorrupt(raw: "\u{FFFD}斯系统", cleaned: "\u{FFFD}斯系统", speechSeconds: 30))
        // A script this engine is never routed.
        XCTAssertTrue(Qwen3TranscriptionService.looksCorrupt(raw: "สั่งฟรี", cleaned: "สั่งฟรี", speechSeconds: 2))
        // Four characters for thirty seconds of speech.
        XCTAssertTrue(Qwen3TranscriptionService.looksCorrupt(raw: "好的好的", cleaned: "好的好的", speechSeconds: 30))
    }

    func test_looksCorrupt_acceptsNormalAndShortUtterances() {
        XCTAssertFalse(Qwen3TranscriptionService.looksCorrupt(
            raw: "所有，只要处理data，不管你是做machine learning。",
            cleaned: "所有，只要处理data，不管你是做machine learning。", speechSeconds: 8))
        // A one-word reply is short, but so is its audio.
        XCTAssertFalse(Qwen3TranscriptionService.looksCorrupt(raw: "好。", cleaned: "好。", speechSeconds: 0.6))
        // Silence legitimately transcribes to nothing.
        XCTAssertFalse(Qwen3TranscriptionService.looksCorrupt(raw: "", cleaned: "", speechSeconds: 0))
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
}
