import AVFoundation
import os

/// Collects AVAudioPCMBuffer fragments from an audio engine tap and fires a callback
/// when enough samples have accumulated for one streaming chunk.
///
/// Thread-safety: all state, including `onChunkReady`, is guarded by an NSLock.
/// The `onChunkReady` callback is invoked synchronously on the caller's thread
/// (the AVAudioEngine tap thread), outside the lock.
///
/// Usage:
/// ```swift
/// let accumulator = AudioBufferAccumulator(
///     samplesPerChunk: Int(sampleRate * 3.0),
///     sampleRate: sampleRate
/// )
/// accumulator.onChunkReady = { buffer in
///     // schedule transcription for `buffer`
/// }
/// // In the AVAudioEngine tap:
/// accumulator.append(convertedBuffer)
/// // On recording stop:
/// if let partial = accumulator.flush() {
///     // schedule transcription for remaining audio
/// }
/// ```
final class AudioBufferAccumulator: @unchecked Sendable {

    // MARK: - Public interface

    /// Called with a full-chunk PCM buffer each time `samplesPerChunk` frames accumulate.
    /// Invoked synchronously on the thread that called `append(_:)`. It is set
    /// from the main actor and read on the audio tap thread, hence the lock.
    var onChunkReady: ((AVAudioPCMBuffer) -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return chunkHandler
        }
        set {
            lock.lock(); defer { lock.unlock() }
            chunkHandler = newValue
        }
    }

    // MARK: - Private state

    private let samplesPerChunk: Int
    private let sampleRate: Double
    private var pendingFrames: [Float] = []
    private var chunkHandler: ((AVAudioPCMBuffer) -> Void)?
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.murmur.app", category: "accumulator")

    // MARK: - Init

    /// - Parameters:
    ///   - samplesPerChunk: Number of audio frames per chunk (e.g. 48000
    ///     for 3 s at 16 kHz).
    ///   - sampleRate: Sample rate of the audio stream (Hz). Used when
    ///     constructing flush buffers.
    init(samplesPerChunk: Int, sampleRate: Double) {
        self.samplesPerChunk = samplesPerChunk
        self.sampleRate = sampleRate
        self.pendingFrames.reserveCapacity(samplesPerChunk * 2)
    }

    // MARK: - Append

    /// Append a buffer fragment. May synchronously invoke `onChunkReady` one or more
    /// times if the accumulated sample count crosses a chunk boundary.
    ///
    /// - Parameter buffer: PCM float32 mono buffer from the audio tap.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard
            let channelData = buffer.floatChannelData,
            buffer.frameLength > 0
        else { return }

        let frameCount = Int(buffer.frameLength)
        let newSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

        lock.lock()
        pendingFrames.append(contentsOf: newSamples)

        // Drain full chunks while holding the count snapshot; unlock before callback.
        while pendingFrames.count >= samplesPerChunk {
            let chunkSamples = Array(pendingFrames.prefix(samplesPerChunk))
            pendingFrames.removeFirst(samplesPerChunk)
            let handler = chunkHandler
            lock.unlock()

            deliverChunk(samples: chunkSamples, to: handler)

            lock.lock()
        }
        lock.unlock()
    }

    // MARK: - Flush

    /// Return any remaining accumulated samples as a single PCM buffer without waiting
    /// for a full chunk. Returns `nil` if no samples are pending.
    /// After this call the accumulator is empty.
    ///
    /// Call this when recording stops to ensure the tail audio is not silently discarded.
    func flush() -> AVAudioPCMBuffer? {
        lock.lock()
        let remaining = pendingFrames
        pendingFrames.removeAll(keepingCapacity: true)
        lock.unlock()

        guard !remaining.isEmpty else { return nil }

        return makePCMBuffer(samples: remaining)
    }

    // MARK: - Private helpers

    private func deliverChunk(samples: [Float], to handler: ((AVAudioPCMBuffer) -> Void)?) {
        guard let handler else { return }
        guard let buffer = makePCMBuffer(samples: samples) else {
            logger.error("AudioBufferAccumulator: failed to allocate chunk buffer (\(samples.count) samples)")
            return
        }
        handler(buffer)
    }

    private func makePCMBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                channelData[0].assign(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }
}
