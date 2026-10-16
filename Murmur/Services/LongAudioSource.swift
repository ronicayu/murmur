import AVFoundation

/// A recording as 16 kHz mono Float32 samples that stay on disk: callers read
/// one range at a time, so a two-hour file never sits in memory.
///
/// A file that is already 16 kHz mono linear PCM is read in place. Anything
/// else (compressed, another rate, stereo) is converted once, in small
/// pieces, to a temporary WAV. The WAV is deleted as soon as it is open: the
/// open file stays readable, and the system frees it when the source goes
/// away, however the process ends.
final class LongAudioSource {
    static let sampleRate = 16_000

    /// Number of samples.
    let count: Int

    private let file: AVAudioFile

    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!

    init(url: URL) throws {
        let original = try AVAudioFile(forReading: url)
        let description = original.fileFormat.streamDescription.pointee
        let readableInPlace = description.mFormatID == kAudioFormatLinearPCM
            && original.processingFormat.sampleRate == Double(Self.sampleRate)
            && original.processingFormat.channelCount == 1
            && original.processingFormat.commonFormat == .pcmFormatFloat32
        if readableInPlace {
            file = original
        } else {
            let converted = FileManager.default.temporaryDirectory
                .appendingPathComponent("murmur_long_\(UUID().uuidString).wav")
            // The copy holds the user's audio. Deleted here, it cannot be
            // left behind when the engine process is ended mid-transcription.
            defer { try? FileManager.default.removeItem(at: converted) }
            try Self.convert(original, to: converted)
            file = try AVAudioFile(forReading: converted)
        }
        count = Int(file.length)
        if count == 0 {
            throw MurmurError.transcriptionFailed("No audio data")
        }
    }

    /// The samples in `range`, clamped to the recording.
    func read(_ range: Range<Int>) throws -> [Float] {
        let lower = max(0, range.lowerBound)
        let upper = min(count, range.upperBound)
        guard upper > lower else { return [] }
        let wanted = upper - lower
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(wanted)) else {
            throw MurmurError.transcriptionFailed("Failed to create audio buffer")
        }
        var samples = [Float]()
        samples.reserveCapacity(wanted)
        file.framePosition = AVAudioFramePosition(lower)
        while samples.count < wanted {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(wanted - samples.count))
            guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        return samples
    }

    /// Calls `body` with consecutive blocks that together are the whole
    /// recording. Every block but the last holds `blockSize` samples.
    func forEachBlock(of blockSize: Int, _ body: ([Float]) throws -> Void) throws {
        var start = 0
        while start < count {
            let end = min(start + blockSize, count)
            try body(try read(start..<end))
            start = end
        }
    }

    private static func convert(_ source: AVAudioFile, to destination: URL) throws {
        let sourceFormat = source.processingFormat
        if sourceFormat.sampleRate == format.sampleRate, sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32 {
            // Compressed, but already 16 kHz mono once decoded: copy the
            // decoded samples as they are. A converter would round them.
            let output = try AVAudioFile(forWriting: destination, settings: format.settings)
            let block = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 16_384)!
            var copied: AVAudioFramePosition = 0
            while copied < source.length {
                do {
                    try source.read(into: block)
                } catch {
                    // A compressed file can hold fewer frames than its header
                    // says; reading past them is an error, not an empty read.
                    if copied > 0 { break }
                    throw error
                }
                guard block.frameLength > 0 else { break }
                try output.write(from: block)
                copied += AVAudioFramePosition(block.frameLength)
            }
            return
        }
        guard let converter = AVAudioConverter(from: source.processingFormat, to: format) else {
            throw MurmurError.transcriptionFailed("Cannot create audio converter")
        }
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096)!
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            input.frameLength = 0
            try? source.read(into: input)
            if input.frameLength == 0 {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }
        let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var status: AVAudioConverterOutputStatus
        repeat {
            var convertError: NSError?
            chunk.frameLength = 0
            status = converter.convert(to: chunk, error: &convertError, withInputFrom: inputBlock)
            if let convertError { throw convertError }
            if chunk.frameLength > 0 { try output.write(from: chunk) }
        } while status == .haveData
    }
}
