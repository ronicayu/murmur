import AVFoundation
import XCTest
@testable import Murmur

/// File transcription reads the recording from disk a piece at a time. These
/// tests hold that reading to the in-memory functions it replaced: the same
/// samples, the same paragraphs and the same cuts.
final class LongAudioSourceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("long-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: Fixtures

    /// Speech-like audio: bursts of a tone whose loudness changes every
    /// 0.25 s, with the given silences (seconds from, seconds long) cut in.
    private func makeSamples(seconds: Double, silences: [(at: Double, length: Double)] = []) -> [Float] {
        let rate = 16_000
        var samples = [Float](repeating: 0, count: Int(seconds * Double(rate)))
        for i in samples.indices {
            let block = i / (rate / 4)
            let level = Float((block * 37) % 9 + 1) / 20
            samples[i] = level * sin(Float(i) * 0.05)
        }
        for silence in silences {
            let from = Int(silence.at * Double(rate))
            let to = min(samples.count, from + Int(silence.length * Double(rate)))
            for i in from..<to { samples[i] = 0 }
        }
        return samples
    }

    private func write(_ samples: [Float], sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1,
                       settings: [String: Any]? = nil, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: settings ?? format.settings)
        let frames = samples.count
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![channel].update(from: source.baseAddress!, count: frames)
            }
        }
        try file.write(from: buffer)
        return url
    }

    // MARK: Reading

    func test_read_returnsTheSamplesOfTheRange() throws {
        let samples = makeSamples(seconds: 3)
        let source = try LongAudioSource(url: try write(samples, name: "a.wav"))

        XCTAssertEqual(source.count, samples.count)
        XCTAssertEqual(try source.read(0..<100), Array(samples[0..<100]))
        XCTAssertEqual(try source.read(20_000..<20_750), Array(samples[20_000..<20_750]))
        // Reading backwards after reading forwards.
        XCTAssertEqual(try source.read(5..<10), Array(samples[5..<10]))
    }

    func test_read_clampsToTheRecording() throws {
        let samples = makeSamples(seconds: 1)
        let source = try LongAudioSource(url: try write(samples, name: "a.wav"))

        XCTAssertEqual(try source.read(15_990..<17_000), Array(samples[15_990...]))
        XCTAssertEqual(try source.read(16_000..<16_100), [])
    }

    func test_forEachBlock_coversTheWholeRecordingInOrder() throws {
        let samples = makeSamples(seconds: 2.3)
        let source = try LongAudioSource(url: try write(samples, name: "a.wav"))
        var joined: [Float] = []
        var sizes: [Int] = []

        try source.forEachBlock(of: 16_000) { block in
            joined += block
            sizes.append(block.count)
        }

        XCTAssertEqual(joined, samples)
        XCTAssertEqual(sizes, [16_000, 16_000, 4_800])
    }

    func test_emptyFile_throws() throws {
        let url = try write([], name: "empty.wav")
        XCTAssertThrowsError(try LongAudioSource(url: url))
    }

    // MARK: Conversion

    func test_fileInAnotherFormat_isConvertedTo16kMono_andTheCopyIsDeleted() throws {
        // 44.1 kHz stereo 16-bit: what a music app would export.
        let seconds = 2.0
        let original = [Float](repeating: 0.25, count: Int(44_100 * seconds))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let url = try write(original, sampleRate: 44_100, channels: 2, settings: settings, name: "stereo.wav")
        let temporaryFilesBefore = try murmurTemporaryFiles()

        var source: LongAudioSource? = try LongAudioSource(url: url)
        let count = try XCTUnwrap(source).count
        let middle = try XCTUnwrap(source).read(8_000..<8_100)

        XCTAssertEqual(Double(count), 16_000 * seconds, accuracy: 400)
        XCTAssertEqual(middle.count, 100)
        for value in middle { XCTAssertEqual(value, 0.25, accuracy: 0.01) }
        XCTAssertEqual(try murmurTemporaryFiles().subtracting(temporaryFilesBefore).count, 1,
                       "Precondition: the converted copy exists while the source is in use")

        source = nil

        XCTAssertEqual(try murmurTemporaryFiles(), temporaryFilesBefore,
                       "The converted copy holds the user's audio and must not be left behind")
    }

    private func murmurTemporaryFiles() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("murmur_long_") })
    }

    // MARK: Same spans and cuts as the in-memory functions

    func test_spansFromDisk_equalSpansFromMemory() throws {
        // Silences on and off frame and block edges; 2 s is the paragraph gap,
        // 1 s a pause that ends a span of 10 s or more.
        let samples = makeSamples(seconds: 47.37, silences: [
            (at: 3.0, length: 2.5), (at: 9.95, length: 2.2), (at: 20.0, length: 1.5), (at: 23.4, length: 1.1),
            (at: 31.13, length: 4.0),
        ])
        let source = try LongAudioSource(url: try write(samples, name: "a.wav"))

        let fromDisk = Qwen3TranscriptionService.speechSpans(
            loud: try Qwen3TranscriptionService.loudFrames(of: source), sampleCount: source.count, sampleRate: 16_000)
        let fromMemory = Qwen3TranscriptionService.speechSpans(samples: samples, sampleRate: 16_000)

        XCTAssertEqual(fromDisk, fromMemory)
        XCTAssertEqual(fromMemory.count, 5, "Precondition: the fixture has spans to compare")
    }

    func test_cutsFromDisk_equalCutsFromMemory() throws {
        // Longer than three pieces, so several cuts are searched.
        let samples = makeSamples(seconds: 131.7, silences: [(at: 35.2, length: 0.6), (at: 71.0, length: 0.4)])
        let source = try LongAudioSource(url: try write(samples, name: "a.wav"))

        let fromDisk = try Qwen3TranscriptionService.segmentRanges(of: 0..<source.count, in: source)
        let fromMemory = Qwen3TranscriptionService.segmentRanges(samples: samples, sampleRate: 16_000)

        XCTAssertEqual(fromDisk, fromMemory)
        XCTAssertGreaterThan(fromMemory.count, 3, "Precondition: the fixture needs several cuts")
    }

    func test_cutsFromDisk_forAPartOfTheRecording_areOffsetsIntoTheRecording() throws {
        let samples = makeSamples(seconds: 120, silences: [(at: 50.0, length: 0.5)])
        let source = try LongAudioSource(url: try write(samples, name: "a.wav"))
        let part = 160_000..<1_760_000   // 10 s ..< 110 s

        let fromDisk = try Qwen3TranscriptionService.segmentRanges(of: part, in: source)
        let fromMemory = Qwen3TranscriptionService.segmentRanges(samples: Array(samples[part]), sampleRate: 16_000)
            .map { ($0.lowerBound + part.lowerBound)..<($0.upperBound + part.lowerBound) }

        XCTAssertEqual(fromDisk, fromMemory)
    }

    func test_cutsFromDisk_shortPart_isOnePiece() throws {
        let samples = makeSamples(seconds: 12)
        let source = try LongAudioSource(url: try write(samples, name: "a.wav"))

        XCTAssertEqual(try Qwen3TranscriptionService.segmentRanges(of: 100..<90_000, in: source), [100..<90_000])
    }
}
