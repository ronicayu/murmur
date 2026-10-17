import AVFoundation
import AppKit
import Darwin
import os

// MARK: - Streaming State Machine

/// States of a single streaming voice-input session.
///
/// ```
/// idle → streaming → finalizing → done
///            ↓
///         cancelled
/// ```
enum StreamingSessionState: Equatable, Sendable {
    /// No session active.
    case idle
    /// Recording in progress; the audio so far is being transcribed for the preview.
    case streaming(chunkCount: Int)
    /// Recording stopped; waiting for full-pass transcription to complete.
    case finalizing
    /// Full-pass complete; `finalResult` is set. Terminal state.
    case done
    /// User cancelled mid-session. Terminal state.
    case cancelled
    /// Unrecoverable error. Terminal state.
    case failed(String)
}

// MARK: - CPU Monitor

/// The host's CPU tick counters, by state. They count up from boot, so load
/// over a period is the difference between two readings.
struct CPUTicks: Equatable, Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// Polls the host CPU tick counters and fires a callback when sustained high
/// load is detected. Used to trigger automatic V1 fallback.
///
/// The load of each poll is measured between that poll's reading and the one
/// before it; the first reading only sets the baseline.
final class CPULoadMonitor: @unchecked Sendable {

    /// Called when CPU sustained load exceeds the threshold for the required duration.
    var onSustainedHighLoad: (() -> Void)?

    private let threshold: Double       // 0.0–1.0
    private let sustainedSeconds: TimeInterval
    private let pollInterval: TimeInterval
    private let sampleTicks: @Sendable () -> CPUTicks?
    private var monitorTask: Task<Void, Never>?
    private var highLoadStart: Date?
    private let logger = Logger(subsystem: "com.murmur.app", category: "cpu-monitor")

    init(
        threshold: Double = 0.90,
        sustainedSeconds: TimeInterval = 3.0,
        pollInterval: TimeInterval = 1.0,
        sampleTicks: @escaping @Sendable () -> CPUTicks? = CPULoadMonitor.hostCPUTicks
    ) {
        self.threshold = threshold
        self.sustainedSeconds = sustainedSeconds
        self.pollInterval = pollInterval
        self.sampleTicks = sampleTicks
    }

    func start() {
        monitorTask = Task.detached { [weak self] in
            guard let self else { return }
            var previous = self.sampleTicks()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.pollInterval))
                if Task.isCancelled { break }
                let current = self.sampleTicks()
                let load: Double
                if let previous, let current {
                    load = CPULoadMonitor.load(from: previous, to: current)
                } else {
                    load = 0.0
                }
                previous = current
                await MainActor.run {
                    self.evaluate(load: load)
                }
            }
        }
    }

    @MainActor
    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        highLoadStart = nil
    }

    // MARK: - Private

    @MainActor
    private func evaluate(load: Double) {
        if load > threshold {
            if highLoadStart == nil {
                highLoadStart = Date()
                logger.info("CPULoadMonitor: high load detected (\(load, format: .fixed(precision: 2)))")
            } else if let start = highLoadStart,
                      Date().timeIntervalSince(start) >= sustainedSeconds {
                logger.warning("CPULoadMonitor: sustained high load — triggering fallback")
                stop()
                onSustainedHighLoad?()
            }
        } else {
            if highLoadStart != nil {
                logger.info("CPULoadMonitor: load normalised")
                highLoadStart = nil
            }
        }
    }

    /// Share of CPU time spent busy between two readings, in [0.0, 1.0].
    /// 0.0 when no time passed between them.
    static func load(from previous: CPUTicks, to current: CPUTicks) -> Double {
        // The counters are 32-bit and wrap around; wrapping subtraction still
        // gives the right difference across a wrap.
        let user   = Double(current.user &- previous.user)
        let system = Double(current.system &- previous.system)
        let idle   = Double(current.idle &- previous.idle)
        let nice   = Double(current.nice &- previous.nice)
        let total  = user + system + idle + nice
        guard total > 0 else { return 0.0 }
        return (user + system + nice) / total
    }

    /// Reads the host's cumulative CPU ticks with `host_statistics`.
    ///
    /// HOST_CPU_LOAD_INFO_COUNT is a C macro unavailable in Swift; the struct contains
    /// 4 × UInt32 fields, so the count is MemoryLayout<host_cpu_load_info_data_t>.size / 4.
    /// Returns nil on error; the monitor then reports no load (conservative —
    /// won't falsely trigger fallback).
    static func hostCPUTicks() -> CPUTicks? {
        let cpuLoadInfoCount = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        var count = cpuLoadInfoCount
        var info = host_cpu_load_info_data_t()

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        return CPUTicks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
    }
}

// MARK: - V1 Usage Counter

/// Tracks cumulative V1 voice-input session count for the discovery badge mechanism.
/// Increments once per completed V1 session. Persists in UserDefaults.
struct V1UsageCounter {
    static let userDefaultsKey = "v1VoiceInputUsageCount"
    static let discoveryThreshold = 10

    static func increment() {
        let current = UserDefaults.standard.integer(forKey: userDefaultsKey)
        UserDefaults.standard.set(current + 1, forKey: userDefaultsKey)
    }

    static func currentCount() -> Int {
        UserDefaults.standard.integer(forKey: userDefaultsKey)
    }

    /// True once the user has completed ≥10 V1 sessions and the discovery badge
    /// has not yet been acknowledged.
    static var shouldShowDiscoveryBadge: Bool {
        let count = currentCount()
        let dismissed = UserDefaults.standard.bool(forKey: "streamingDiscoveryBadgeDismissed")
        let streamingEnabled = UserDefaults.standard.bool(forKey: "streamingInputEnabled")
        return count >= discoveryThreshold && !dismissed && !streamingEnabled
    }

    static func dismissDiscoveryBadge() {
        UserDefaults.standard.set(true, forKey: "streamingDiscoveryBadgeDismissed")
    }
}

// MARK: - StreamingTranscriptionCoordinator

/// Orchestrates a streaming dictation session.
///
/// **Responsibilities:**
/// - Manages the streaming state machine (idle → streaming → finalizing → done/cancelled).
/// - While the user speaks, re-transcribes the growing window of captured
///   audio on a short fixed cadence and reports the text two consecutive
///   passes agree on, for a preview. Nothing is typed into the target app.
/// - After recording stops, transcribes the complete WAV once more. That
///   text (or the streamed text, if the pass fails) is `finalResult`, which
///   the owner inserts.
/// - Monitors CPU via `CPULoadMonitor`: on sustained > 90% load the preview
///   passes stop; the closing pass still runs.
///
/// **Thread model:** All public API must be called from `@MainActor`.
/// Internal chunk processing dispatches to a detached task but marshals results
/// back to the main actor before mutating state.
///
/// **Session identity:** a transcription cannot be interrupted, so work started
/// by one session can finish after that session was cancelled, or after the
/// next one began. Every task and callback captures `sessionGeneration` when
/// it is created and does nothing once the value has moved on.
@MainActor
final class StreamingTranscriptionCoordinator: ObservableObject {

    // MARK: - Published state

    @Published private(set) var sessionState: StreamingSessionState = .idle
    @Published private(set) var chunkCount: Int = 0

    // MARK: - Dependencies (injected for testability)

    let transcription: TranscriptionServiceProtocol
    private let cpuMonitor: CPULoadMonitor
    // MARK: - Session state

    /// Changes whenever a session begins, is cancelled or is reset. Work that
    /// captured an older value belongs to a session that is over.
    private var sessionGeneration = 0
    private var accumulator: AudioBufferAccumulator?
    private var streamingChunks: [String] = []
    private var fullWavURL: URL?
    private var language: String = "en"
    private var cpuFallbackTriggered: Bool = false
    /// DA-P1-5: Timestamp when full-pass finalizing phase started (for pill progress).
    private(set) var finalizingStartedAt: Date?

    // MARK: - Stable-prefix streaming state (LocalAgreement-2 over a growing window)

    /// Audio accumulated since the last window reset. Re-transcribed in full on every
    /// pass so each hypothesis has sentence context — isolated short chunks
    /// are what let one-pass hallucinations reach the preview.
    private var windowSamples: [Float] = []
    /// Emits only text two consecutive hypotheses agree on; withholds the unstable tail.
    private var aggregator = StablePrefixAggregator()
    /// At most one window transcription runs at a time (keeps hypotheses ordered).
    private var transcriptionInFlight = false
    /// Audio arrived while a pass was in flight — re-transcribe when it returns.
    private var windowDirty = false
    /// After a window force-reset, the next Latin-leading delta gets a separating space.
    private var pendingWindowSeparator = false
    /// Receives the full streamed text each time it grows.
    private var onPreviewText: ((String) -> Void)?
    /// The text to insert once the session reaches `.done`: the full-pass
    /// transcription, or the streamed text if the full pass failed.
    private(set) var finalResult: TranscriptionResult?
    /// True when the closing full pass failed or timed out, so whatever text
    /// the session ended with is the streamed preview at best. Lets the owner
    /// tell "nothing was said" from "the transcription broke".
    private(set) var fullPassFailed = false

    // MARK: - Session measurements

    /// When the streaming session began — the reference point for
    /// time-to-first-word.
    private(set) var sessionStartedAt: Date?
    /// When the first stable delta became visible in the preview. Nil if the
    /// session never streamed anything.
    private(set) var firstDeltaAt: Date?
    /// Levenshtein ratio between the streamed text and the full-pass text,
    /// computed during the closing pass. Nil until that pass runs.
    private(set) var lastEditDistanceRatio: Double?

    /// Milliseconds from session start to the first visible streamed word.
    var timeToFirstWordMs: Int? {
        guard let sessionStartedAt, let firstDeltaAt else { return nil }
        return Int((firstDeltaAt.timeIntervalSince(sessionStartedAt) * 1000).rounded())
    }

    /// Why the session ended in `.cancelled` state, for UI messaging.
    enum CancellationReason: Sendable {
        case user
        case backstopTimeout
    }
    internal(set) var cancellationReason: CancellationReason?

    private static let chunkSampleRate: Double = 16000
    /// Cap on the re-transcribed window. Past this, the window is flushed + reset so a
    /// long monologue can't grow the per-pass transcription cost without bound.
    private static let maxWindowSeconds: Double = 12.0
    private static var maxWindowSamples: Int { Int(chunkSampleRate * maxWindowSeconds) }
    /// Once the speaker pauses, a window at least this long is closed at the
    /// pause so later passes don't re-transcribe finished sentences.
    private static let minPauseResetSeconds: Double = 3.0
    /// A window with no frame above this RMS (≈ −50 dBFS, whisper level) is
    /// treated as silence and not sent to the model.
    private static let silenceRMSThreshold: Float = 0.00316

    private let logger = Logger(subsystem: "com.murmur.app", category: "streaming-coordinator")

    // MARK: - Init

    init(
        transcription: TranscriptionServiceProtocol,
        cpuMonitor: CPULoadMonitor = CPULoadMonitor(),
        fullPassTimeoutOverride: TimeInterval? = nil
    ) {
        self.transcription = transcription
        self.cpuMonitor = cpuMonitor
        self.fullPassTimeoutSeconds = fullPassTimeoutOverride ?? 30.0
    }

    // MARK: - Public API

    /// Begin a streaming session.
    ///
    /// A session left in a terminal state (done, cancelled, failed) is cleared
    /// first, so a missing `resetToIdle()` cannot block the next session.
    ///
    /// - Parameters:
    ///   - language: the language hint for the engine.
    ///   - fullWavURL: URL where `AudioService` is writing the complete WAV.
    ///   - incrementalSeconds: The growing window is re-transcribed every this
    ///     many seconds of captured audio, so text follows speech by a pass or
    ///     two. The engine must transcribe a full window well within the interval.
    ///   - onPreviewText: receives the streamed text each time it grows (for
    ///     a preview UI). The caller inserts `finalResult` after the session
    ///     is done.
    /// - Returns: The configured `AudioBufferAccumulator` to attach to the audio tap.
    func beginSession(
        language: String,
        fullWavURL: URL,
        incrementalSeconds: Double = 1.0,
        onPreviewText: @escaping (String) -> Void
    ) -> AudioBufferAccumulator {
        let acc = AudioBufferAccumulator(
            samplesPerChunk: max(1, Int(Self.chunkSampleRate * incrementalSeconds)),
            sampleRate: Self.chunkSampleRate
        )
        switch sessionState {
        case .streaming, .finalizing:
            logger.warning("beginSession called during a session — ignoring")
            return acc
        case .idle, .done, .cancelled, .failed:
            break
        }

        clearSessionState()
        let generation = sessionGeneration

        self.language = language
        self.fullWavURL = fullWavURL
        self.onPreviewText = onPreviewText
        self.sessionStartedAt = Date()

        acc.onChunkReady = { [weak self] buffer in
            guard let self else { return }
            Task { @MainActor in
                self.handleChunkReady(buffer, generation: generation)
            }
        }
        self.accumulator = acc

        // The CPU fallback stops the streaming passes; the full pass at the
        // end still produces the text.
        setupCPUMonitor()
        transition(to: .streaming(chunkCount: 0))
        logger.info("StreamingCoordinator: session started (lang=\(language))")
        return acc
    }

    /// Stop recording and initiate the full-pass finalizing phase.
    ///
    /// Keeps the partial tail of audio, then runs a full-pass transcription
    /// whose text becomes `finalResult`.
    func endSession() {
        guard case .streaming = sessionState else {
            logger.warning("endSession called while not streaming — ignoring")
            return
        }

        cpuMonitor.stop()

        // Keep the partial tail in the window, but start no pass for it: its
        // result would be discarded (the session is no longer streaming) and
        // the full pass would wait behind it. `finishStreamedText` transcribes
        // the final window where the streamed text is needed.
        if let partial = accumulator?.flush() {
            appendToWindow(partial)
        }
        accumulator = nil

        finalizingStartedAt = Date()
        transition(to: .finalizing)
        logger.info("StreamingCoordinator: session ending, starting full-pass")

        let generation = sessionGeneration
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            // The owner inserts the full-pass text, so the streamed text only
            // needs finishing if that pass fails (see runFullPass).
            await self.runFullPass(generation: generation)
        }
    }

    /// Bring the streamed text up to the end of the recording, for a session
    /// whose full pass was unavailable.
    ///
    /// The last hypothesis the aggregator saw predates the final stretch of audio
    /// (anything captured after the last pass started), so flushing it as-is drops
    /// the closing words. Transcribe the final window once more and emit everything
    /// after the words already shown. It also covers the short single-utterance
    /// case: LocalAgreement-2 emits nothing until a second pass agrees.
    ///
    /// - Parameter transcribeFinalWindow: false when the engine is known to be
    ///   busy (an abandoned full pass still holds it): only the text the last
    ///   hypothesis already holds is flushed.
    ///
    /// The session can end while this waits; callers check `isCurrent` afterwards.
    private func finishStreamedText(generation: Int, transcribeFinalWindow: Bool = true) async {
        if transcribeFinalWindow {
            // Let a pass that was already running finish; its result is ignored
            // (the session is no longer `.streaming`) but it holds the model.
            let deadline = Date().addingTimeInterval(5)
            while transcriptionInFlight && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                guard isCurrent(generation) else { return }
            }

            if !windowSamples.isEmpty,
               !Self.isSilent(windowSamples),
               let wavURL = writeSamplesToTempWAV(windowSamples) {
                let transcription = self.transcription
                let lang = self.language
                let text = try? await transcription.transcribe(audioURL: wavURL, language: lang).text
                try? FileManager.default.removeItem(at: wavURL)
                guard isCurrent(generation) else { return }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let delta = aggregator.ingest(text)
                    if !delta.isEmpty { emitDelta(delta) }
                }
            }
        }
        windowSamples.removeAll()

        let pendingTail = aggregator.flushAndReset()
        if !pendingTail.isEmpty { emitDelta(pendingTail) }
    }

    /// Reset the coordinator to idle so it can be reused for the next session.
    /// Call after the session reaches a terminal state (done/cancelled/failed).
    /// Clears everything the session reported (`finalResult`,
    /// `cancellationReason`, the measurements), so read those first.
    func resetToIdle() {
        switch sessionState {
        case .idle:
            // The owner can set `cancellationReason` on an idle coordinator
            // (its backstop does); leave nothing behind for the next read.
            cancellationReason = nil
            return
        case .streaming, .finalizing:
            logger.warning("resetToIdle called during a session — cancelling first")
            cancelSession()
        case .done, .cancelled, .failed:
            break
        }
        clearSessionState()
        transition(to: .idle)
    }

    /// Update the full WAV URL after `AudioService.stopRecording()` resolves.
    /// Must be called before `endSession()`.
    func updateFullWavURL(_ url: URL) {
        fullWavURL = url
    }

    /// Cancel the session immediately, discarding any in-flight work.
    /// Does nothing when no session is running (idle, or already ended).
    func cancelSession() {
        switch sessionState {
        case .streaming, .finalizing:
            break
        case .idle, .done, .cancelled, .failed:
            return
        }
        // Whatever this session still has in flight must find it gone.
        sessionGeneration += 1
        cpuMonitor.stop()
        accumulator = nil
        transition(to: .cancelled)
        logger.info("StreamingCoordinator: session cancelled")
    }

    /// True while the session that captured `generation` is still the current one.
    private func isCurrent(_ generation: Int) -> Bool {
        generation == sessionGeneration
    }

    /// Stops everything a session owns and clears all per-session state and
    /// results, so nothing from one session can be read as the next one's.
    private func clearSessionState() {
        sessionGeneration += 1
        cpuMonitor.stop()
        accumulator = nil
        fullWavURL = nil
        streamingChunks = []
        chunkCount = 0
        cpuFallbackTriggered = false
        cancellationReason = nil
        finalizingStartedAt = nil
        windowSamples = []
        aggregator = StablePrefixAggregator()
        transcriptionInFlight = false
        windowDirty = false
        pendingWindowSeparator = false
        onPreviewText = nil
        finalResult = nil
        fullPassFailed = false
        sessionStartedAt = nil
        firstDeltaAt = nil
        lastEditDistanceRatio = nil
    }

    // MARK: - Chunk handling (LocalAgreement-2 over a growing window)

    private func handleChunkReady(_ buffer: AVAudioPCMBuffer, generation: Int) {
        guard isCurrent(generation), case .streaming = sessionState else { return }

        appendToWindow(buffer)
        transcribeWindowIfIdle()
    }

    /// Append newly captured audio to the current window. The window
    /// holds all audio since the last reset; the whole window is re-transcribed each
    /// pass so every hypothesis carries sentence context.
    private func appendToWindow(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frameCount = Int(buffer.frameLength)
        windowSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }

    /// Transcribe the current window unless a pass is already running. Serialising
    /// passes keeps hypotheses ordered for the aggregator; audio that arrives mid-flight
    /// is coalesced into the next pass, which also self-throttles when the model is
    /// slower than speech.
    private func transcribeWindowIfIdle() {
        guard case .streaming = sessionState else { return }
        guard !transcriptionInFlight else { windowDirty = true; return }
        guard !windowSamples.isEmpty else { return }

        // There is no VAD in front of the window, so keep silence away from
        // the model: an all-quiet window is dropped instead of transcribed.
        if Self.isSilent(windowSamples) {
            windowSamples.removeAll(keepingCapacity: true)
            return
        }

        guard let wavURL = writeSamplesToTempWAV(windowSamples) else {
            logger.error("StreamingCoordinator: failed to write window to temp WAV")
            return
        }

        transcriptionInFlight = true
        windowDirty = false
        let lang = self.language
        let generation = sessionGeneration
        // Audio keeps arriving while the pass runs; only this much is in it.
        let sentSamples = windowSamples.count
        Task.detached { [weak self, wavURL, lang] in
            guard let self else {
                try? FileManager.default.removeItem(at: wavURL)
                return
            }
            var text: String?
            do {
                text = try await self.transcription.transcribe(audioURL: wavURL, language: lang).text
            } catch {
                text = nil
                await MainActor.run {
                    self.logger.warning("StreamingCoordinator: window transcription failed: \(error)")
                }
            }
            try? FileManager.default.removeItem(at: wavURL)
            let hypothesis = text
            await MainActor.run {
                self.handleWindowHypothesis(hypothesis, generation: generation, coveredSamples: sentSamples)
            }
        }
    }

    /// Fold a completed window hypothesis into the aggregator and emit only the
    /// newly-stable text. Resets the window past the cap so per-pass cost stays bounded.
    ///
    /// - Parameter coveredSamples: how much of the window the pass transcribed.
    private func handleWindowHypothesis(_ text: String?, generation: Int, coveredSamples: Int) {
        // A pass that outlived its session reports to nobody: the next session
        // has its own in-flight flag, window and aggregator.
        guard isCurrent(generation) else { return }
        transcriptionInFlight = false
        guard case .streaming = sessionState else { return }

        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let delta = aggregator.ingest(text)
            if !delta.isEmpty { emitDelta(delta) }
        }

        // Two passes that agree word for word mean the speaker
        // paused. Close the window there — a clean sentence boundary — rather
        // than letting it run to the hard cap and cut mid-word. `windowDirty`
        // means newer audio is already waiting, so the pause is over; keep going.
        let pausedAtBoundary = !windowDirty
            && aggregator.lastPassFullyAgreed
            && windowSamples.count >= Int(Self.chunkSampleRate * Self.minPauseResetSeconds)

        if windowSamples.count >= Self.maxWindowSamples || pausedAtBoundary {
            var tail = aggregator.flushAndReset()
            if !pausedAtBoundary {
                // The cap cut mid-speech; a punctuating model still ends the
                // partial hypothesis with a full stop that nobody spoke.
                tail = Self.droppingTrailingSentenceEnd(tail)
            }
            if !tail.isEmpty { emitDelta(tail) }
            // Drop only the audio this pass heard. Audio captured while it ran
            // has not been transcribed yet; it opens the next window.
            windowSamples.removeFirst(min(coveredSamples, windowSamples.count))
            pendingWindowSeparator = true
            logger.info("StreamingCoordinator: window \(pausedAtBoundary ? "closed at pause" : "cap reached") — flushed + reset")
        }

        if windowDirty { transcribeWindowIfIdle() }
    }

    /// Add a confirmed delta to the streamed text and report the whole text
    /// to the preview. Deltas carry their own intra-window spacing; a
    /// separator space is added only at a window boundary, and only when the
    /// next text begins a Latin word (CJK needs none).
    private func emitDelta(_ delta: String) {
        var text = delta
        if StreamingSeparator.needsLeadingSpace(
            delta: delta,
            atWindowBoundary: pendingWindowSeparator,
            hasPriorText: !streamingChunks.isEmpty
        ) {
            text = " " + delta
        }
        pendingWindowSeparator = false

        streamingChunks.append(text)
        chunkCount += 1
        if firstDeltaAt == nil { firstDeltaAt = Date() }
        if case .streaming = sessionState {
            transition(to: .streaming(chunkCount: chunkCount))
        }

        onPreviewText?(streamingChunks.joined())
    }

    /// Removes one trailing sentence-ending mark (and surrounding whitespace).
    nonisolated static func droppingTrailingSentenceEnd(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, "。.！!？?".contains(last) else { return text }
        return String(trimmed.dropLast())
    }

    // MARK: - Full-pass

    /// Seconds after which a stalled full-pass transcription is abandoned.
    /// Overridable at init-time for unit tests (pass a short value to keep tests fast).
    let fullPassTimeoutSeconds: TimeInterval
    /// After this many seconds, the pill should show a "still refining" warning.
    static let fullPassWarningSeconds: TimeInterval = 15.0

    /// The full pass was unavailable: the streamed text is completed up to
    /// the end of the recording and becomes `finalResult`.
    private func finishWithStreamedText(generation: Int, transcribeFinalWindow: Bool = true) async {
        await finishStreamedText(generation: generation, transcribeFinalWindow: transcribeFinalWindow)
        guard isCurrent(generation) else { return }
        finalResult = TranscriptionResult(text: streamingChunks.joined(), language: .unknown, durationMs: 0)
        transition(to: .done)
    }

    /// Runs `operation` and returns its value, or nil when it has not finished
    /// within `seconds`.
    ///
    /// The operation runs in a task of its own, and on timeout that task is
    /// abandoned rather than awaited. A speech decode cannot be interrupted,
    /// and a task group returns only when all its children have: with one, the
    /// "timeout" would last as long as the decode. An abandoned operation runs
    /// to its end and its value is dropped.
    nonisolated static func firstResult<T: Sendable>(
        within seconds: TimeInterval,
        of operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let (stream, continuation) = AsyncStream<T?>.makeStream()
        let work = Task.detached {
            continuation.yield(await operation())
        }
        let timer = Task.detached {
            try? await Task.sleep(for: .seconds(seconds))
            continuation.yield(nil)
        }
        var first: T?
        for await value in stream {
            first = value
            break
        }
        timer.cancel()
        // An operation that honours cancellation stops early; nothing waits
        // for one that does not.
        work.cancel()
        return first
    }

    private func runFullPass(generation: Int) async {
        guard isCurrent(generation) else { return }
        guard let wavURL = fullWavURL else {
            await finishWithStreamedText(generation: generation)
            return
        }

        // DA-P1-5: Race full-pass transcription against a 30s hard timeout.
        let transcription = self.transcription
        let language = self.language

        enum FullPassResult: Sendable {
            case transcribed(TranscriptionResult)
            case timedOut
            case failed
        }

        let timeoutSeconds = self.fullPassTimeoutSeconds
        let passResult: FullPassResult = await Self.firstResult(within: timeoutSeconds) {
            do {
                let r = try await transcription.transcribe(audioURL: wavURL, language: language)
                return FullPassResult.transcribed(r)
            } catch {
                return FullPassResult.failed
            }
        } ?? .timedOut

        // The pass can outlast the session (cancelled by the owner's backstop,
        // or already followed by the next one). Its result then belongs nowhere.
        guard isCurrent(generation) else {
            logger.info("StreamingCoordinator: full-pass finished after its session ended — result dropped")
            return
        }

        let result: TranscriptionResult
        switch passResult {
        case .timedOut:
            logger.warning("StreamingCoordinator: full-pass exceeded \(Int(timeoutSeconds))s — keeping streaming version")
            fullPassFailed = true
            // In-process, the abandoned decode still holds the engine; with the
            // helper, `firstResult` cancelled it (dropped if waiting, helper
            // ended if running). Either way the final window is not transcribed.
            await finishWithStreamedText(generation: generation, transcribeFinalWindow: false)
            return
        case .failed:
            logger.warning("StreamingCoordinator: full-pass transcription failed — keeping streaming version")
            fullPassFailed = true
            await finishWithStreamedText(generation: generation)
            return
        case .transcribed(let r):
            result = r
        }

        lastEditDistanceRatio = Self.editDistanceRatio(streamingChunks.joined(), result.text)
        finalResult = result
        onPreviewText?(result.text)
        logger.info("StreamingCoordinator: full-pass complete")
        transition(to: .done)
    }

    // MARK: - CPU Monitor

    private func setupCPUMonitor() {
        let generation = sessionGeneration
        cpuMonitor.onSustainedHighLoad = { [weak self] in
            Task { @MainActor in
                self?.handleCPUFallback(generation: generation)
            }
        }
        cpuMonitor.start()
    }

    private func handleCPUFallback(generation: Int) {
        guard isCurrent(generation), case .streaming = sessionState else { return }
        logger.warning("StreamingCoordinator: CPU fallback triggered — stopping streaming inference")
        cpuFallbackTriggered = true
        accumulator?.onChunkReady = nil   // stop processing new chunks
        // The session continues; endSession() will still run full-pass on the complete WAV.
        // No further chunk transcriptions are dispatched.
    }

    /// Whether CPU fallback was triggered during this session.
    var didTriggerCPUFallback: Bool { cpuFallbackTriggered }

    // MARK: - Helpers

    private func transition(to newState: StreamingSessionState) {
        sessionState = newState
    }

    /// True when no 100 ms frame of `samples` reaches `silenceRMSThreshold`.
    nonisolated static func isSilent(_ samples: [Float]) -> Bool {
        let frame = Int(chunkSampleRate / 10)
        var start = 0
        while start < samples.count {
            let end = min(start + frame, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            if (sum / Float(end - start)).squareRoot() >= silenceRMSThreshold { return false }
            start = end
        }
        return true
    }

    /// Write a window of Float32 mono samples to a temporary WAV file and return its URL.
    private func writeSamplesToTempWAV(_ samples: [Float]) -> URL? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.chunkSampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: samples.count)
            }
        }
        return writeBufferToTempWAV(buffer)
    }

    /// Write a PCM buffer to a temporary WAV file and return its URL.
    private func writeBufferToTempWAV(_ buffer: AVAudioPCMBuffer) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur_chunk_\(UUID().uuidString).wav")

        guard let format = buffer.format as AVAudioFormat?,
              let file = try? AVAudioFile(forWriting: url, settings: format.settings) else {
            return nil
        }

        do {
            try file.write(from: buffer)
        } catch {
            logger.error("StreamingCoordinator: WAV write failed: \(error)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    /// Simple edit-distance ratio: edits / max(|a|, |b|).
    /// Returns 0.0 for equal strings, 1.0 for completely different strings.
    nonisolated static func editDistanceRatio(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0.0 }
        let distance = levenshtein(Array(a), Array(b))
        let maxLen = max(a.count, b.count)
        return Double(distance) / Double(maxLen)
    }

    private nonisolated static func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        var previous = Array(0...n)
        var current = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            current[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(
                    current[j - 1] + 1,
                    previous[j] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[n]
    }
}
