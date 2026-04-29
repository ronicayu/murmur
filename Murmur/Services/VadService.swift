import Foundation
import os

/// Voice Activity Detection segment in absolute sample offsets relative to
/// the start of the stream (sample 0 = first sample fed via `feed`). Also
/// carries the segment's audio samples so streaming consumers can emit
/// them directly without re-buffering — Sherpa already keeps a copy in
/// the segment struct, so exposing it here is free.
public struct VadSegment: Sendable, Equatable {
    public let startSample: Int
    public let endSample: Int
    public let samples: [Float]

    public var sampleCount: Int { samples.count }

    public func durationSeconds(sampleRate: Int) -> Double {
        Double(sampleCount) / Double(sampleRate)
    }
}

/// Wraps the vendored sherpa-onnx Silero VAD detector.
///
/// Lifetime: holds the underlying C session for the instance's lifetime to
/// avoid the per-call model load cost. A class with an internal lock
/// (rather than an actor) so the audio-tap thread can call `feed` and
/// `popSegments` synchronously without an async hop — same pattern as
/// `AudioBufferAccumulator`. Sherpa's C session is not reentrant, so all
/// calls must be serialised through the lock.
///
/// Call shape:
///   `init` → repeated `feed(samples)` → `popSegments()` (any time) →
///   on stream end, `endOfStream()` → `reset()` (or destroy).
final class VadService: @unchecked Sendable {

    /// Sample rate the wrapper was configured with. Silero V5 only supports
    /// 16 kHz — kept as a property for callers to assert against their own
    /// converter output.
    let sampleRate: Int

    private let logger = Logger(subsystem: "com.murmur.app", category: "vad")
    private let detector: SherpaOnnxVoiceActivityDetectorWrapper
    private let lock = NSLock()

    /// - Parameters:
    ///   - modelURL: path to the Silero VAD ONNX file. Caller's
    ///     responsibility to make sure the file is on disk
    ///     (`ModelManager.auxiliaryModelPath(.sileroVad)`).
    ///   - sampleRate: must be 16 000 — Silero v5 doesn't support other
    ///     rates. Kept as a parameter so the type is honest about the
    ///     constraint; init throws if violated.
    ///   - bufferSeconds: ring buffer Silero keeps internally. 30 s is
    ///     plenty for live PTT and streaming; long-audio passes feed in
    ///     bounded chunks (see Phase 5) so this doesn't need to grow.
    ///   - threshold: speech probability above which Silero declares
    ///     speech. 0.5 is the library default.
    ///   - minSilenceDurationSeconds: silence required to close a segment.
    ///   - minSpeechDurationSeconds: speech required to open a segment.
    ///   - maxSpeechDurationSeconds: cap on segment length — Silero will
    ///     force-close past this to bound latency for ASR consumers.
    init(
        modelURL: URL,
        sampleRate: Int = 16_000,
        bufferSeconds: Float = 30,
        threshold: Float = 0.5,
        minSilenceDurationSeconds: Float = 0.25,
        minSpeechDurationSeconds: Float = 0.25,
        maxSpeechDurationSeconds: Float = 8.0
    ) throws {
        guard sampleRate == 16_000 else {
            throw MurmurError.transcriptionFailed("VadService: sample rate must be 16000 (got \(sampleRate))")
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw MurmurError.modelNotFound
        }
        self.sampleRate = sampleRate

        let silero = sherpaOnnxSileroVadModelConfig(
            model: modelURL.path,
            threshold: threshold,
            minSilenceDuration: minSilenceDurationSeconds,
            minSpeechDuration: minSpeechDurationSeconds,
            windowSize: 512,
            maxSpeechDuration: maxSpeechDurationSeconds
        )
        var config = sherpaOnnxVadModelConfig(
            sileroVad: silero,
            sampleRate: Int32(sampleRate),
            numThreads: 1,
            provider: "cpu",
            debug: 0
        )
        self.detector = withUnsafePointer(to: &config) { ptr in
            SherpaOnnxVoiceActivityDetectorWrapper(config: ptr, buffer_size_in_seconds: bufferSeconds)
        }
    }

    /// Push 16 kHz mono float32 samples into the detector. Cheap (~1 ms
    /// per 32 ms frame on Apple Silicon). Caller is expected to drain via
    /// `popSegments` periodically, otherwise Silero's internal buffer
    /// grows.
    func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        detector.acceptWaveform(samples: samples)
    }

    /// Drain all completed speech segments. Returns empty if Silero hasn't
    /// closed any since the last call. Safe to call on every audio
    /// callback — no-op when the queue is empty.
    func popSegments() -> [VadSegment] {
        lock.lock()
        defer { lock.unlock() }
        return drainLocked()
    }

    /// Whether Silero currently believes the live frame is speech. Used by
    /// hands-free mode's trailing-silence timer (Phase 3).
    var isCurrentlySpeech: Bool {
        lock.lock()
        defer { lock.unlock() }
        return detector.isSpeechDetected()
    }

    /// Flush the last in-progress segment (if any) and return all
    /// remaining segments. Call once when the audio source ends —
    /// `stopRecording`, end-of-file, etc. Resets internal state so the
    /// service can be reused for the next stream.
    func endOfStream() -> [VadSegment] {
        lock.lock()
        defer { lock.unlock() }
        detector.flush()
        let out = drainLocked()
        detector.reset()
        return out
    }

    /// Drop everything queued and pending. Use when the user cancels a
    /// recording mid-stream.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        detector.reset()
        detector.clear()
    }

    /// Caller must hold `lock`.
    private func drainLocked() -> [VadSegment] {
        var out: [VadSegment] = []
        while !detector.isEmpty() {
            let seg = detector.front()
            out.append(
                VadSegment(
                    startSample: seg.start,
                    endSample: seg.start + seg.n,
                    samples: seg.samples
                )
            )
            detector.pop()
        }
        return out
    }
}
