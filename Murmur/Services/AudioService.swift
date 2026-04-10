import AVFoundation
import os

protocol AudioServiceProtocol {
    func startRecording() async throws
    func stopRecording() async throws -> URL
    func cancelRecording()
    var audioLevel: AsyncStream<Float> { get }
    /// URL of the in-progress WAV file (nil if not recording).
    var currentRecordingURL: URL? { get }
    /// Attach a streaming accumulator to receive audio buffers during recording.
    func attachStreamingAccumulator(_ accumulator: AudioBufferAccumulator?)
    /// Detach any streaming accumulator (called when streaming is cancelled or stopped).
    func detachStreamingAccumulator()
}

final class AudioService: AudioServiceProtocol {
    private let engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private var tempURL: URL?
    private var rmsAccumulator: [Float] = []
    private let logger = Logger(subsystem: "com.murmur.app", category: "audio")
    private let maxDuration: TimeInterval = 120
    private var recordingStart: Date?
    private var maxDurationTask: Task<Void, Never>?

    /// V3: optional streaming accumulator attached during a streaming session.
    private var streamingAccumulator: AudioBufferAccumulator?

    /// URL of the WAV file currently being written (nil when not recording).
    private(set) var currentRecordingURL: URL?

    /// Protects mutable state accessed from the audio tap thread.
    private let lock = NSLock()

    let audioLevel: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation
    /// Continuation yielded when max duration is reached.
    private let maxDurationContinuation: AsyncStream<Void>.Continuation
    let maxDurationReached: AsyncStream<Void>

    init() {
        (audioLevel, levelContinuation) = AsyncStream.makeStream(
            of: Float.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        (maxDurationReached, maxDurationContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    // MARK: - V3 Streaming Accumulator

    func attachStreamingAccumulator(_ accumulator: AudioBufferAccumulator?) {
        lock.lock()
        streamingAccumulator = accumulator
        lock.unlock()
    }

    func detachStreamingAccumulator() {
        lock.lock()
        streamingAccumulator = nil
        lock.unlock()
    }

    // MARK: - Recording

    func startRecording() async throws {
        guard !engine.isRunning else { return }

        try checkDiskSpace()

        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("murmur_\(UUID().uuidString).wav")
        currentRecordingURL = url

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            throw MurmurError.microphoneBusy
        }

        let recordFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: format, to: recordFormat) else {
            throw MurmurError.microphoneBusy
        }

        let file = try AVAudioFile(forWriting: url, settings: recordFormat.settings)

        lock.lock()
        outputFile = file
        tempURL = url
        rmsAccumulator = []
        lock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000 / format.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: recordFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil, convertedBuffer.frameLength > 0 {
                self.lock.lock()
                try? self.outputFile?.write(from: convertedBuffer)
                let rms = self.computeRMS(convertedBuffer)
                self.rmsAccumulator.append(rms)
                // V3 dual-output: feed streaming accumulator (if attached)
                let acc = self.streamingAccumulator
                self.lock.unlock()
                self.levelContinuation.yield(rms)
                // Invoke outside the lock to prevent deadlock inside onChunkReady
                acc?.append(convertedBuffer)
            }
        }

        try engine.start()
        recordingStart = Date()
        logger.info("Recording started")

        // Max duration enforcement
        maxDurationTask = Task { [weak self, maxDuration] in
            try? await Task.sleep(for: .seconds(maxDuration))
            guard !Task.isCancelled else { return }
            self?.logger.info("Max recording duration reached")
            self?.maxDurationContinuation.yield()
        }
    }

    func stopRecording() async throws -> URL {
        guard engine.isRunning else {
            throw MurmurError.transcriptionFailed("No active recording")
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        maxDurationTask?.cancel()
        maxDurationTask = nil

        lock.lock()
        let url = tempURL
        let accum = rmsAccumulator
        outputFile = nil
        streamingAccumulator = nil
        lock.unlock()
        currentRecordingURL = nil

        guard let url else {
            throw MurmurError.transcriptionFailed("No active recording")
        }

        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        logger.info("Recording stopped, duration: \(duration, format: .fixed(precision: 1))s")

        // VAD: check if audio was silence
        let avgRMS = accum.isEmpty ? Float(-100) : accum.reduce(0, +) / Float(accum.count)
        let dbRMS = 20 * Foundation.log10(max(avgRMS, 1e-10))
        logger.info("Audio RMS: \(dbRMS) dB (threshold: -60 dB)")
        if dbRMS < -60 {
            logger.info("Silence detected")
            try? FileManager.default.removeItem(at: url)
            throw MurmurError.silenceDetected
        }

        return url
    }

    func cancelRecording() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        maxDurationTask?.cancel()
        maxDurationTask = nil

        lock.lock()
        outputFile = nil
        let url = tempURL
        tempURL = nil
        streamingAccumulator = nil
        lock.unlock()
        currentRecordingURL = nil

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        logger.info("Recording cancelled")
    }

    private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count {
            sum += channelData[i] * channelData[i]
        }
        return sqrt(sum / max(Float(count), 1))
    }

    private func checkDiskSpace() throws {
        let attrs = try FileManager.default.attributesOfFileSystem(
            forPath: NSTemporaryDirectory()
        )
        if let freeSpace = attrs[.systemFreeSize] as? Int64, freeSpace < 500_000_000 {
            throw MurmurError.diskFull
        }
    }

    deinit {
        levelContinuation.finish()
        maxDurationContinuation.finish()
    }
}
