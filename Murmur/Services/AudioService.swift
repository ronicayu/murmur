import AVFoundation
import AppKit
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

    /// Set by route-change / wake observers; consumed on next startRecording.
    /// Protected by `lock`.
    private var needsReset = false
    private var configChangeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init() {
        (audioLevel, levelContinuation) = AsyncStream.makeStream(
            of: Float.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        (maxDurationReached, maxDurationContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.markNeedsReset(reason: "configuration change")
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.markNeedsReset(reason: "system wake")
        }
    }

    private func markNeedsReset(reason: String) {
        lock.lock()
        needsReset = true
        lock.unlock()
        logger.info("Audio engine flagged for reset: \(reason, privacy: .public)")
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

    /// Tracks whether we have an active tap installed on the input node.
    private var tapInstalled = false

    func startRecording() async throws {
        // Tear down any prior session to prevent SIGABRT from duplicate tap.
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            tapInstalled = false
        } else if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        // If the audio route changed or the system woke since last record,
        // the input node's cached format is stale and `installTap` + `start`
        // will hit error -10868 (kAudioUnitErr_FormatNotSupported). Reset
        // the engine to rebuild the node graph against current hardware.
        lock.lock()
        let shouldReset = needsReset
        needsReset = false
        lock.unlock()
        if shouldReset {
            engine.reset()
            logger.info("Audio engine reset before start")
        }

        try checkDiskSpace()

        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("murmur_\(UUID().uuidString).wav")
        currentRecordingURL = url

        let recordFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        let file = try AVAudioFile(forWriting: url, settings: recordFormat.settings)

        lock.lock()
        outputFile = file
        tempURL = url
        rmsAccumulator = []
        lock.unlock()

        // Read the hardware format live at start-time and pass it explicitly
        // to installTap. A sample rate of 0 means no input device is currently
        // available — fail early with a clear message rather than letting the
        // engine throw -10868 later.
        let inputNode = engine.inputNode

        // Voice processing — Apple's built-in noise suppression + echo
        // cancellation + AGC, the same audio unit FaceTime / Zoom use.
        // Significant quality gain in noisy environments. MUST be set before
        // `engine.start()` and BEFORE the format is read (the IO unit forces
        // the input format to 16 kHz mono when enabled, which is exactly
        // what we want for ASR anyway).
        let voiceProcessingEnabled = UserDefaults.standard.object(forKey: "voiceProcessingEnabled") as? Bool ?? true
        do {
            try inputNode.setVoiceProcessingEnabled(voiceProcessingEnabled)
        } catch {
            // Non-fatal: log and proceed with raw input. Older external USB
            // mics occasionally refuse the voice-processing unit; we'd
            // rather record imperfectly than hard-fail.
            logger.warning("setVoiceProcessingEnabled(\(voiceProcessingEnabled)) failed: \(String(describing: error))")
        }

        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            logger.error("No audio input available (sampleRate=\(hardwareFormat.sampleRate), channels=\(hardwareFormat.channelCount))")
            throw MurmurError.transcriptionFailed("No audio input available")
        }
        guard let converter = AVAudioConverter(from: hardwareFormat, to: recordFormat) else {
            throw MurmurError.transcriptionFailed("Cannot create audio converter")
        }
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let actualFormat = buffer.format
            let conv = converter

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000 / actualFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: recordFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            conv.convert(to: convertedBuffer, error: &error) { _, outStatus in
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

        tapInstalled = true
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
        tapInstalled = false
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

        // VAD — peak-only because Apple's voice-processing AGC ruins the
        // average. With voice processing on, a normal utterance's average
        // RMS can land around -75 dB while individual speech frames still
        // peak at -25 dB or louder. Average-based silence detection
        // false-fires on real speech in that regime. Switch to peak-only
        // with a very permissive threshold — anything quieter than -65 dB
        // peak is "absolute silence" (mic muted, wrong device, accidental
        // hotkey press). Whisper-tier whispering still peaks above -50 dB.
        let avgRMS = accum.isEmpty ? Float(-100) : accum.reduce(0, +) / Float(accum.count)
        let peakRMS = accum.max() ?? 0
        let dbAvg = 20 * Foundation.log10(max(avgRMS, 1e-10))
        let dbPeak = 20 * Foundation.log10(max(peakRMS, 1e-10))
        logger.info("Audio RMS avg: \(dbAvg, format: .fixed(precision: 1)) dB, peak: \(dbPeak, format: .fixed(precision: 1)) dB (frames=\(accum.count))")

        if dbPeak < -65 {
            logger.info("Silence detected (peak \(dbPeak, format: .fixed(precision: 1)) dB)")
            try? FileManager.default.removeItem(at: url)
            throw MurmurError.silenceDetected
        }

        return url
    }

    func cancelRecording() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
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
        if let token = configChangeObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        levelContinuation.finish()
        maxDurationContinuation.finish()
    }
}
