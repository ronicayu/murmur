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

    /// Voice activity detector for the current recording session. Set via
    /// `setVad(_:)` from the coordinator once the Silero model is on disk
    /// and ready. When non-nil, replaces the post-recording RMS gate with
    /// model-based silence detection. When nil, AudioService falls back
    /// to the legacy peak-RMS gate (handles cold-start before the model
    /// has been downloaded).
    ///
    /// Lifetime: the same `VadService` instance is reused across
    /// recordings — `endOfStream()` resets internal state so a session
    /// can't leak into the next.
    private var vad: VadService?
    /// Whether VAD was active for the current session (i.e., we fed
    /// samples in). Used by `stopRecording` to decide whether to consult
    /// VAD or fall back to RMS.
    private var vadActive = false

    /// Trailing silence window for hands-free auto-stop, or nil if
    /// hands-free is off. When set AND a vad is attached, `startRecording`
    /// spawns a polling task that invokes `onAutoStop` after this many
    /// seconds of consecutive non-speech (gated on at least one speech
    /// segment having been seen, so a silent start doesn't auto-fire
    /// instantly).
    private var handsFreeTrailingSilence: TimeInterval?
    private var handsFreeTask: Task<Void, Never>?

    /// True if VAD emitted any closed speech segment during the current
    /// recording. The hands-free polling task pops segments to drive its
    /// silence timer — that drains them out of Silero's queue, so by
    /// stop time `endOfStream()` only sees the residual in-progress
    /// segment (or nothing). The post-recording silence gate consults
    /// this flag in addition to `endOfStream()` to decide whether the
    /// recording was empty. Reset on `startRecording`.
    private var hadAnySpeechSegment = false

    /// URL of the WAV file currently being written (nil when not recording).
    private(set) var currentRecordingURL: URL?

    /// Protects mutable state accessed from the audio tap thread.
    private let lock = NSLock()

    let audioLevel: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation
    /// Invoked when either the 120 s max-duration timer or the hands-free
    /// trailing-silence threshold fires. Replaces the previous AsyncStream-
    /// based signal — back-to-back recordings race on the iterator
    /// lifecycle (cancelled task's iterator can grab the next yield before
    /// the new task's iterator is active, so the event silently disappears).
    /// A plain callback removes the iterator entirely.
    /// Set by the coordinator on every `startRecording*Flow`; cleared on
    /// stop/cancel. Always invoked from a non-MainActor context — caller
    /// is responsible for hopping to the actor it needs.
    var onAutoStop: (@Sendable () -> Void)?

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

    /// Inject (or clear) the VAD service used by the next recording.
    /// Pass nil to disable VAD entirely and revert to the RMS gate.
    func setVad(_ vad: VadService?) {
        lock.lock()
        self.vad = vad
        lock.unlock()
    }

    /// Configure hands-free auto-stop. Pass `nil` to disable. The window
    /// applies from the first speech segment onward — silent starts don't
    /// trigger an instant stop. Requires a `VadService` attached via
    /// `setVad(_:)`; without one the setter is a no-op at recording time
    /// (logged once per session).
    func setHandsFreeAutoStop(trailingSilenceSeconds: TimeInterval?) {
        lock.lock()
        handsFreeTrailingSilence = trailingSilenceSeconds
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
        // Reset VAD state for this recording. If a vad is present, we'll
        // feed it inside the tap; if not, we fall back to RMS at stop.
        vad?.reset()
        vadActive = (vad != nil)
        hadAnySpeechSegment = false
        lock.unlock()

        // Read the hardware format live at start-time and pass it explicitly
        // to installTap. A sample rate of 0 means no input device is currently
        // available — fail early with a clear message rather than letting the
        // engine throw -10868 later.
        let inputNode = engine.inputNode

        // We deliberately do NOT call `setVoiceProcessingEnabled` here.
        // The AVAudioEngine voice-processing IO unit is fragile on macOS —
        // multiple device / route combinations (notably AirPods and EarPods,
        // verified on a user's M-series Mac) return all-zero buffers, which
        // manifests as VAD firing silenceDetected on every recording.
        // For noise reduction in noisy environments, point users at
        // macOS-system Voice Isolation (Control Center → Microphone Mode)
        // — see README. That path is OS-level, applies to any input, and
        // does not break our audio pipeline.

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
                let vad = self.vad
                let vadIsActive = self.vadActive
                self.lock.unlock()
                self.levelContinuation.yield(rms)
                // Invoke outside the lock to prevent deadlock inside onChunkReady
                acc?.append(convertedBuffer)
                if vadIsActive, let vad {
                    self.feedVad(vad, buffer: convertedBuffer)
                }
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
            self?.onAutoStop?()
        }

        // Hands-free auto-stop. Only meaningful with a VAD attached; if
        // the user picked hands-free without the model, log and skip —
        // recording still works, it just behaves like .toggle.
        lock.lock()
        let trailing = handsFreeTrailingSilence
        let activeVad = vad
        lock.unlock()
        if let trailing, let activeVad {
            handsFreeTask = Task { [weak self] in
                await self?.runHandsFreeAutoStop(vad: activeVad, trailingSilence: trailing)
            }
        } else if trailing != nil {
            logger.info("Hands-free requested but VAD not attached — falling back to manual stop")
        }
    }

    /// Poll the VAD's live speech state at 10 Hz. Once we see speech at
    /// least once, start a stopwatch on every transition into silence;
    /// invoke `onAutoStop` if silence persists for `trailingSilence`.
    /// Resets the stopwatch on any speech frame. Cancellation propagates
    /// from `stopRecording` / `cancelRecording`.
    ///
    /// Drive the trailing-silence timer off Silero's *segment-close*
    /// events, not RMS or `isCurrentlySpeech` polls.
    ///
    /// Why: prior versions polled `isCurrentlySpeech` and/or compared
    /// instantaneous RMS to an adaptive noise floor. Both signals are
    /// jittery — `isCurrentlySpeech` flickers within a single phrase,
    /// RMS in a between-word pause looks like silence even though the
    /// user isn't done. So the timer either fired mid-utterance or never
    /// fired at all, depending on how chatty the noise floor was.
    ///
    /// Silero already does the right inference: it groups consecutive
    /// frames into a segment and only closes the segment after
    /// `minSilenceDuration` of low-probability frames. That's *the*
    /// "user just finished a thought" signal we want.
    ///
    /// Algorithm: poll `popSegments` at 10 Hz. Update
    /// `lastSegmentEndTime` whenever segments come out. Fire when (a)
    /// at least one segment has closed, (b) Silero is not currently in
    /// a segment, and (c) `trailingSilence` seconds have elapsed since
    /// the last segment close. Going back into speech (Silero opens a
    /// new segment) implicitly defers the timer because the segment
    /// hasn't closed yet — `lastSegmentEndTime` doesn't advance until
    /// it does.
    private func runHandsFreeAutoStop(vad: VadService, trailingSilence: TimeInterval) async {
        let pollInterval: Duration = .milliseconds(100)
        var lastSegmentEndTime: Date?
        var sawAnySegment = false
        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { return }
            let segments = vad.popSegments()
            if !segments.isEmpty {
                sawAnySegment = true
                lastSegmentEndTime = Date()
                lock.lock()
                hadAnySpeechSegment = true
                lock.unlock()
                continue
            }
            guard sawAnySegment, let lastEnd = lastSegmentEndTime else { continue }
            // Don't fire while a new segment is currently being collected
            // — the user is talking again and the timer should defer
            // until that segment closes.
            if vad.isCurrentlySpeech {
                lastSegmentEndTime = nil
                continue
            }
            let elapsed = Date().timeIntervalSince(lastEnd)
            if elapsed >= trailingSilence {
                logger.info("Hands-free auto-stop: \(trailingSilence, format: .fixed(precision: 2))s since last segment close")
                onAutoStop?()
                return
            }
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
        handsFreeTask?.cancel()
        handsFreeTask = nil

        lock.lock()
        let url = tempURL
        let accum = rmsAccumulator
        let activeVad = vad
        let vadWasActive = vadActive
        let priorSegmentSeen = hadAnySpeechSegment
        outputFile = nil
        streamingAccumulator = nil
        vadActive = false
        lock.unlock()
        currentRecordingURL = nil

        guard let url else {
            throw MurmurError.transcriptionFailed("No active recording")
        }

        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        logger.info("Recording stopped, duration: \(duration, format: .fixed(precision: 1))s")

        // RMS log line stays for telemetry — useful when debugging mic /
        // route issues even when the VAD path is the gate.
        let avgRMS = accum.isEmpty ? Float(-100) : accum.reduce(0, +) / Float(accum.count)
        let peakRMS = accum.max() ?? 0
        let dbAvg = 20 * Foundation.log10(max(avgRMS, 1e-10))
        let dbPeak = 20 * Foundation.log10(max(peakRMS, 1e-10))
        logger.info("Audio RMS avg: \(dbAvg, format: .fixed(precision: 1)) dB, peak: \(dbPeak, format: .fixed(precision: 1)) dB (frames=\(accum.count))")

        // Decide silence by VAD when it was active for this session;
        // otherwise fall back to the legacy peak-RMS gate. The fallback
        // covers cold-start before the Silero model has been downloaded.
        if vadWasActive, let activeVad {
            let segments = activeVad.endOfStream()
            // hands-free polling drains segments during recording, so an
            // empty endOfStream doesn't mean nothing was said. The flag
            // covers that case.
            if segments.isEmpty && !priorSegmentSeen {
                // Short-utterance backstop: Silero requires 0.25 s of
                // sustained ≥ 0.5 prob frames to *open* a segment, so a
                // quick "yes" / "好" / "ok" can fly under the radar even
                // though there's clearly a word in there. If the
                // recording is short (≤ 2 s) and peak RMS is at or above
                // whisper level, transcribe anyway and let Cohere decide.
                // Long recordings with no VAD segment really are empty.
                let shortUtteranceMaxDuration: TimeInterval = 2.0
                let speechFloorDB: Float = -50
                if duration <= shortUtteranceMaxDuration && dbPeak > speechFloorDB {
                    logger.info("VAD empty but short+loud — transcribing anyway (duration \(duration, format: .fixed(precision: 1))s, peak \(dbPeak, format: .fixed(precision: 1)) dB)")
                    return url
                }
                logger.info("Silence detected (VAD: no speech segments; peak \(dbPeak, format: .fixed(precision: 1)) dB)")
                try? FileManager.default.removeItem(at: url)
                throw MurmurError.silenceDetected
            }
            let totalSpeechSamples = segments.reduce(0) { $0 + $1.sampleCount }
            logger.info("VAD: \(segments.count) speech segment(s), \(totalSpeechSamples) samples")
        } else {
            // Legacy peak-RMS gate (see commit history for rationale —
            // peak-only because voice-processing AGC ruins the average).
            // Whisper-tier whispering still peaks above -50 dB; -65 dB is
            // "mic muted / wrong device / accidental hotkey press."
            if dbPeak < -65 {
                logger.info("Silence detected (peak \(dbPeak, format: .fixed(precision: 1)) dB, RMS fallback)")
                try? FileManager.default.removeItem(at: url)
                throw MurmurError.silenceDetected
            }
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
        handsFreeTask?.cancel()
        handsFreeTask = nil

        lock.lock()
        outputFile = nil
        let url = tempURL
        tempURL = nil
        streamingAccumulator = nil
        vad?.reset()
        vadActive = false
        lock.unlock()
        currentRecordingURL = nil

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        logger.info("Recording cancelled")
    }

    /// Push a 16 kHz mono float32 buffer into the VAD detector. Called
    /// from the audio tap thread — VadService serialises internally.
    private func feedVad(_ vad: VadService, buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
        vad.feed(samples)
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
    }
}
