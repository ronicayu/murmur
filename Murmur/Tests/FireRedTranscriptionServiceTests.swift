import XCTest
@testable import Murmur
import AVFoundation

/// Skip-if-model-missing tests against the sherpa-onnx FireRed v2 AED int8 model.
/// Mirrors the pattern in NativeTranscriptionTests: tests run only on dev machines
/// where the user has actually downloaded the FireRed model under
/// ~/Library/Application Support/Murmur/Models-FireRed/.
final class FireRedTranscriptionServiceTests: XCTestCase {

    private var fixtureDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("test_fixtures")
    }

    private var modelDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Models-FireRed")
    }

    private lazy var refs: [String: Any] = {
        let url = fixtureDir.appendingPathComponent("firered_refs.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

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

    func test_transcribe_cnEnMixed_matchesSpikeReference() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path),
                          "FireRed model not installed at \(modelDir.path) — run the app, enable the toggle, let the download finish")
        let wavURL = fixtureDir.appendingPathComponent("test_chinese_en.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavURL.path))

        let svc = try FireRedTranscriptionService(modelDirectory: modelDir)
        let samples = try loadSamples(url: wavURL)
        let text = try await svc.transcribe(samples: samples, sampleRate: 16000)

        let refDict = refs["test_chinese_en_wav_zh"] as! [String: Any]
        let expected = refDict["text"] as! String
        XCTAssertEqual(text, expected,
                       "FireRed output drifted from spike reference. Update firered_refs.json only if you've intentionally changed model/version.")
    }

    func test_transcribe_shortChineseHello_containsExpected() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path))
        let wavURL = fixtureDir.appendingPathComponent("test_chinese.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavURL.path))

        let svc = try FireRedTranscriptionService(modelDirectory: modelDir)
        let samples = try loadSamples(url: wavURL)
        let text = try await svc.transcribe(samples: samples, sampleRate: 16000)

        XCTAssertTrue(text.contains("你好"),
                      "Expected '你好' in FireRed output, got: \(text)")
        XCTAssertFalse(text.isEmpty)
    }

    func test_init_throwsWhenModelDirMissing() {
        let bogus = URL(fileURLWithPath: "/tmp/this-firered-dir-does-not-exist-\(UUID().uuidString)")
        XCTAssertThrowsError(try FireRedTranscriptionService(modelDirectory: bogus))
    }
}
