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
    /// Recording in progress; chunks are being transcribed and injected.
    case streaming(chunkCount: Int)
    /// Recording stopped; waiting for full-pass transcription to complete.
    case finalizing
    /// Full-pass complete; replacement (if needed) applied. Terminal state.
    case done
    /// User cancelled mid-session. Terminal state.
    case cancelled
    /// Unrecoverable error. Terminal state.
    case failed(String)
}

// MARK: - Focus Guard

/// Observes the AX focus state of a target application.
/// Notifies the coordinator when focus leaves or returns.
///
/// Implemented via `NSWorkspace.didActivateApplicationNotification` (coarse-grained)
/// which fires on app-switch without requiring per-element AX observers.
final class FocusGuard: @unchecked Sendable {

    enum Event {
        case focusLeft(elapsedSeconds: TimeInterval)
        case focusReturned
    }

    var onEvent: ((Event) -> Void)?

    private let targetAppPID: pid_t
    private var focusLostAt: Date?
    private var observer: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.murmur.app", category: "focus-guard")

    init(targetAppPID: pid_t) {
        self.targetAppPID = targetAppPID
    }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleActivation(note)
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        focusLostAt = nil
    }

    private func handleActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        if app.processIdentifier == targetAppPID {
            // Focus returned to target
            if let lostAt = focusLostAt {
                let elapsed = Date().timeIntervalSince(lostAt)
                focusLostAt = nil
                logger.info("FocusGuard: focus returned after \(elapsed, format: .fixed(precision: 1))s")
                onEvent?(.focusReturned)
            }
        } else {
            // Focus left target
            if focusLostAt == nil {
                focusLostAt = Date()
                logger.info("FocusGuard: focus left target app")
                onEvent?(.focusLeft(elapsedSeconds: 0))
            }
        }
    }

    /// Elapsed seconds since focus was lost, or nil if focus is current.
    var secondsSinceFocusLost: TimeInterval? {
        focusLostAt.map { Date().timeIntervalSince($0) }
    }
}

// MARK: - CPU Monitor

/// Polls ProcessInfo for system CPU load and fires a callback when sustained
/// high load is detected. Used to trigger automatic V1 fallback.
///
/// Uses `ProcessInfo.processInfo.systemUptime` diff as a lightweight proxy;
/// the actual process CPU% comes from `host_statistics64`.
final class CPULoadMonitor: @unchecked Sendable {

    /// Called when CPU sustained load exceeds the threshold for the required duration.
    var onSustainedHighLoad: (() -> Void)?

    private let threshold: Double       // 0.0–1.0
    private let sustainedSeconds: TimeInterval
    private let pollInterval: TimeInterval
    private var monitorTask: Task<Void, Never>?
    private var highLoadStart: Date?
    private let logger = Logger(subsystem: "com.murmur.app", category: "cpu-monitor")

    init(
        threshold: Double = 0.90,
        sustainedSeconds: TimeInterval = 3.0,
        pollInterval: TimeInterval = 1.0
    ) {
        self.threshold = threshold
        self.sustainedSeconds = sustainedSeconds
        self.pollInterval = pollInterval
    }

    func start() {
        monitorTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let load = self.currentCPULoad()
                await MainActor.run {
                    self.evaluate(load: load)
                }
                try? await Task.sleep(for: .seconds(self.pollInterval))
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

    /// Returns a normalized [0.0, 1.0] CPU load estimate using host_statistics64.
    ///
    /// HOST_CPU_LOAD_INFO_COUNT is a C macro unavailable in Swift; the struct contains
    /// 4 × UInt32 fields, so the count is MemoryLayout<host_cpu_load_info_data_t>.size / 4.
    /// Falls back to 0.0 on error (conservative — won't falsely trigger fallback).
    private func currentCPULoad() -> Double {
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

        guard result == KERN_SUCCESS else { return 0.0 }

        let user   = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle   = Double(info.cpu_ticks.2)
        let nice   = Double(info.cpu_ticks.3)
        let total  = user + system + idle + nice
        guard total > 0 else { return 0.0 }
        return (user + system + nice) / total
    }
}

// MARK: - Injected Range Tracker

/// Tracks the cursor position and character count of text injected during a streaming session.
/// Used to reconstruct the AX range for full-pass replacement.
///
/// **Unit note:** all offsets and lengths are in UTF-16 code units to match
/// `kAXSelectedTextRangeAttribute` which uses UTF-16 code unit counts on macOS.
struct InjectedRangeTracker: Sendable {
    /// AX character offset (UTF-16 code units) where the first streaming chunk was inserted.
    private(set) var startOffset: Int
    /// Total UTF-16 code units injected so far (sum of all chunks).
    private(set) var totalLength: Int
    /// Set to true when the AX cursor is detected at an unexpected position,
    /// indicating the user moved the cursor mid-session. When invalidated,
    /// full-pass replacement is skipped to comply with spec §5 constraint 3.
    private(set) var invalidated: Bool

    init(startOffset: Int) {
        self.startOffset = startOffset
        self.totalLength = 0
        self.invalidated = false
    }

    /// Record an injection of `length` UTF-16 code units.
    mutating func recordInjection(length: Int) {
        totalLength += length
    }

    /// The AX offset we expect the cursor to be at after all injections so far.
    var expectedNextOffset: Int {
        startOffset + totalLength
    }

    /// Mark the tracker invalid because the cursor moved unexpectedly.
    mutating func invalidate() {
        invalidated = true
    }

    /// Returns the AX range covering all streamed text injected so far.
    var axRange: CFRange {
        CFRange(location: startOffset, length: totalLength)
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

/// Orchestrates the V3 streaming voice-input pipeline.
///
/// **Responsibilities:**
/// - Manages the streaming state machine (idle → streaming → finalizing → done/cancelled).
/// - Drives the `AudioBufferAccumulator` → `TranscriptionService.transcribe()` →
///   `TextInjectionService.appendText()` loop for each 3-second chunk.
/// - After recording stops, performs a full-pass transcribe of the complete WAV.
/// - If the full-pass result differs from the concatenated streaming text, calls
///   `TextInjectionService.replaceRange()` to substitute the correct text.
/// - Monitors focus via `FocusGuard`: pauses injection on focus loss, abandons
///   the session after 10 seconds of continued focus loss.
/// - Monitors CPU via `CPULoadMonitor`: falls back to V1 mode on sustained > 90% load.
///
/// **Thread model:** All public API must be called from `@MainActor`.
/// Internal chunk processing dispatches to a detached task but marshals results
/// back to the main actor before mutating state.
@MainActor
final class StreamingTranscriptionCoordinator: ObservableObject {

    // MARK: - Published state

    @Published private(set) var sessionState: StreamingSessionState = .idle
    @Published private(set) var chunkCount: Int = 0

    // MARK: - Dependencies (injected for testability)

    let transcription: TranscriptionServiceProtocol
    let injection: TextInjectionServiceProtocol & StreamingTextInjectionProtocol
    private let cpuMonitor: CPULoadMonitor
    /// Where the text cursor is in the focused app (UTF-16 offset), or nil
    /// when it cannot be read. Injectable because the real lookup asks the
    /// Accessibility API about whatever app happens to be frontmost — on a
    /// machine with the permission granted, a test would otherwise see that
    /// app's cursor, conclude the user moved it, and skip the replacement.
    private let cursorOffsetProvider: () -> Int?

    // MARK: - Session state

    private var accumulator: AudioBufferAccumulator?
    /// On-disk path to the Silero VAD ONNX, set via `setVadModelURL(_:)`.
    /// When non-nil, each `beginSession` builds a fresh `VadService`
    /// against this file and hands it to the accumulator. A fresh
    /// instance per session keeps state clean — Silero's reset semantics
    /// are good but cross-session reuse is unnecessary risk.
    private var vadModelURL: URL?
    private var rangeTracker: InjectedRangeTracker?
    private var streamingChunks: [String] = []
    private var focusGuard: FocusGuard?
    private var fullWavURL: URL?
    private var language: String = "en"
    private var pausedPendingChunks: [AVAudioPCMBuffer] = []
    private var isFocusPaused: Bool = false
    private var cpuFallbackTriggered: Bool = false
    /// DA-P1-3: Hold the focus-abandon timeout task so it can be cancelled on focusReturned.
    private var focusAbandonTask: Task<Void, Never>?
    /// DA-P1-5: Timestamp when full-pass finalizing phase started (for pill progress).
    private(set) var finalizingStartedAt: Date?
    /// UT-P0-2: If full-pass replaced streamed text, holds the replacement text for undoable UI.
    private(set) var fullPassReplacedText: String?

    // MARK: - Stable-prefix streaming state (LocalAgreement-2 over a growing window)

    /// Audio accumulated since the last window reset. Re-transcribed in full on every
    /// pass so each hypothesis has sentence context — isolated single-segment chunks
    /// are what let one-pass hallucinations reach the cursor.
    private var windowSamples: [Float] = []
    /// Emits only text two consecutive hypotheses agree on; withholds the unstable tail.
    private var aggregator = StablePrefixAggregator()
    /// At most one window transcription runs at a time (keeps hypotheses ordered).
    private var transcriptionInFlight = false
    /// Audio arrived while a pass was in flight — re-transcribe when it returns.
    private var windowDirty = false
    /// After a window force-reset, the next Latin-leading delta gets a separating space.
    private var pendingWindowSeparator = false
    /// Preview sessions: receives the full streamed text each time it grows,
    /// instead of the text being typed into the target app. Nothing is injected
    /// by the coordinator; the owner inserts `finalResult` once the session is done.
    private var onPreviewText: ((String) -> Void)?
    /// Preview sessions only: the text to insert once the session reaches `.done` —
    /// the full-pass transcription, or the streamed text if the full pass failed.
    private(set) var finalResult: TranscriptionResult?
    var isPreviewSession: Bool { onPreviewText != nil }

    /// Text confirmed but not yet pasted. Pastes run one at a time: each goes
    /// through the clipboard and a synthetic Cmd+V, so two overlapping pastes
    /// would both insert whichever text reached the clipboard last — one delta
    /// typed twice and the other lost.
    private var pendingInjections: [String] = []
    private var isDrainingInjections = false
    /// Incremental mode: the window is re-transcribed on a fixed short cadence
    /// over *all* captured audio instead of once per closed VAD segment. Only
    /// worth it with an engine fast enough to keep up (see `beginSession`).
    private var incrementalMode = false

    /// Why the session ended in `.cancelled` state, for UI messaging.
    enum CancellationReason: Sendable {
        case user
        case focusAbandoned
        case backstopTimeout
    }
    internal(set) var cancellationReason: CancellationReason?

    private static let chunkSampleRate: Double = 16000
    private static let chunkSeconds: Double = 3.0
    /// Seconds before a lost-focus session is abandoned. Configurable via Settings.
    static var focusAbandonSeconds: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "streamingFocusAbandonSeconds")
        return stored > 0 ? stored : 10.0
    }
    private static let samplesPerChunk: Int = Int(chunkSampleRate * chunkSeconds)
    private static let replaceWindowSeconds: TimeInterval = 0.5
    /// Cap on the re-transcribed window. Past this, the window is flushed + reset so a
    /// long monologue can't grow the per-pass transcription cost without bound.
    private static let maxWindowSeconds: Double = 12.0
    private static var maxWindowSamples: Int { Int(chunkSampleRate * maxWindowSeconds) }
    /// Incremental mode: once the speaker pauses, a window at least this long is
    /// closed at the pause so later passes don't re-transcribe finished sentences.
    private static let minPauseResetSeconds: Double = 3.0
    /// Incremental mode: a window with no frame above this RMS (≈ −50 dBFS,
    /// whisper level) is treated as silence and not sent to the model.
    private static let silenceRMSThreshold: Float = 0.00316

    private let logger = Logger(subsystem: "com.murmur.app", category: "streaming-coordinator")

    // MARK: - Init

    init(
        transcription: TranscriptionServiceProtocol,
        injection: TextInjectionServiceProtocol & StreamingTextInjectionProtocol,
        cpuMonitor: CPULoadMonitor = CPULoadMonitor(),
        fullPassTimeoutOverride: TimeInterval? = nil,
        cursorOffsetProvider: @escaping () -> Int? = { resolveAXCursorOffset() }
    ) {
        self.cursorOffsetProvider = cursorOffsetProvider
        self.transcription = transcription
        self.injection = injection
        self.cpuMonitor = cpuMonitor
        self.fullPassTimeoutSeconds = fullPassTimeoutOverride ?? 30.0
    }

    // MARK: - Public API

    /// Set (or clear) the Silero VAD model used by future streaming
    /// sessions. Called from `AppCoordinator.setVadService(_:)` so live
    /// PTT and streaming share the same model file.
    func setVadModelURL(_ url: URL?) {
        self.vadModelURL = url
    }

    /// Begin a streaming session.
    ///
    /// - Parameters:
    ///   - language: BCP-47 language code (e.g. "en", "zh").
    ///   - targetAppPID: PID of the app receiving injected text (for focus guard).
    ///   - startOffset: AX character offset at the current insertion point.
    ///   - fullWavURL: URL where `AudioService` is writing the complete WAV.
    ///   - incrementalSeconds: When set, re-transcribe the growing window every
    ///     this many seconds of captured audio instead of once per VAD segment.
    ///     Text then follows speech by a pass or two rather than waiting for a
    ///     sentence-end pause, and no speech onset is lost to VAD segmentation.
    ///     Pass it only for an engine that transcribes a full window well within
    ///     the interval and stays silent on silence; nil keeps segment-driven passes.
    ///   - onPreviewText: When set, streamed text is reported here (for a preview
    ///     UI) and never typed into the target app. The caller inserts
    ///     `finalResult` after the session is done.
    /// - Returns: The configured `AudioBufferAccumulator` to attach to the audio tap.
    func beginSession(
        language: String,
        targetAppPID: pid_t,
        startOffset: Int,
        fullWavURL: URL,
        incrementalSeconds: Double? = nil,
        onPreviewText: ((String) -> Void)? = nil
    ) -> AudioBufferAccumulator {
        guard case .idle = sessionState else {
            logger.warning("beginSession called while not idle — ignoring")
            return AudioBufferAccumulator(
                samplesPerChunk: Self.samplesPerChunk,
                sampleRate: Self.chunkSampleRate
            )
        }

        self.language = language
        self.fullWavURL = fullWavURL
        self.rangeTracker = InjectedRangeTracker(startOffset: startOffset)
        self.streamingChunks = []
        self.chunkCount = 0
        self.pausedPendingChunks = []
        self.isFocusPaused = false
        self.cpuFallbackTriggered = false
        self.cancellationReason = nil
        self.fullPassReplacedText = nil
        self.windowSamples = []
        self.aggregator = StablePrefixAggregator()
        self.transcriptionInFlight = false
        self.windowDirty = false
        self.pendingWindowSeparator = false
        self.incrementalMode = incrementalSeconds != nil
        self.pendingInjections = []
        self.onPreviewText = onPreviewText
        self.finalResult = nil

        // Build a fresh per-session VAD if a model is configured.
        // minSilenceDurationSeconds: 0.8 — Silero's 0.25 s default closes
        // a segment on a mid-sentence breath, which makes streaming emit
        // half-finished phrases. 0.8 s spans typical mid-sentence pauses
        // (commas, breaths) so a chunk only delivers on a real
        // sentence-end pause.
        // maxSpeechDurationSeconds: 8 — give the ASR enough context per
        // chunk; Silero will force-close past this even if speech
        // continues, so a long monologue still produces deliverable
        // chunks at a usable cadence.
        let sessionVad: VadService?
        if incrementalSeconds != nil {
            // Incremental mode windows over all captured audio; VAD segmentation
            // would reintroduce the sentence-end wait and clip soft onsets.
            sessionVad = nil
        } else if let vadURL = self.vadModelURL {
            sessionVad = try? VadService(
                modelURL: vadURL,
                minSilenceDurationSeconds: 0.8,
                maxSpeechDurationSeconds: 8.0
            )
            if sessionVad == nil {
                logger.warning("StreamingCoordinator: VAD construction failed — falling back to fixed-size chunking")
            }
        } else {
            sessionVad = nil
        }

        let acc = AudioBufferAccumulator(
            samplesPerChunk: incrementalSeconds.map { max(1, Int(Self.chunkSampleRate * $0)) }
                ?? Self.samplesPerChunk,
            sampleRate: Self.chunkSampleRate,
            vad: sessionVad
        )
        acc.onChunkReady = { [weak self] buffer in
            guard let self else { return }
            Task { @MainActor in
                self.handleChunkReady(buffer)
            }
        }
        self.accumulator = acc

        // A preview session types nothing until the end, so there is no
        // mid-session insertion point for a focus change to disturb.
        if onPreviewText == nil {
            setupFocusGuard(targetAppPID: targetAppPID)
        }
        setupCPUMonitor()
        transition(to: .streaming(chunkCount: 0))
        logger.info("StreamingCoordinator: session started (lang=\(language), pid=\(targetAppPID))")
        return acc
    }

    /// Stop recording and initiate the full-pass finalizing phase.
    ///
    /// Flushes the accumulator (processes partial tail audio), then runs a
    /// full-pass transcription. Replaces streamed text if the result differs.
    func endSession() {
        guard case .streaming = sessionState else {
            logger.warning("endSession called while not streaming — ignoring")
            return
        }

        focusGuard?.stop()
        focusGuard = nil
        cpuMonitor.stop()

        // Flush partial tail
        if let partial = accumulator?.flush() {
            handleChunkReady(partial)
        }
        accumulator = nil

        finalizingStartedAt = Date()
        transition(to: .finalizing)
        logger.info("StreamingCoordinator: session ending, starting full-pass")

        Task { @MainActor [weak self] in
            // A preview session inserts the full-pass text, so the streamed
            // text only needs finishing if that pass fails (see runFullPass).
            if self?.isPreviewSession == false {
                await self?.finishStreamedText()
            }
            await self?.runFullPass()
        }
    }

    /// Bring the streamed text up to the end of the recording before the full pass.
    ///
    /// The last hypothesis the aggregator saw predates the final stretch of audio
    /// (anything captured after the last pass started), so flushing it as-is drops
    /// the closing words. Transcribe the final window once more and emit everything
    /// after the already-typed words. This matters most where the full-pass
    /// replacement cannot run (apps without AX range replace): there the streamed
    /// text is the final text.
    ///
    /// It also covers the short single-utterance case: LocalAgreement-2 emits
    /// nothing until a second pass agrees, and the full pass only *replaces*
    /// streamed text — it never inserts from empty.
    private func finishStreamedText() async {
        // Let a pass that was already running finish; its result is ignored
        // (the session is no longer `.streaming`) but it holds the model.
        let deadline = Date().addingTimeInterval(5)
        while transcriptionInFlight && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if !windowSamples.isEmpty,
           !(incrementalMode && Self.isSilent(windowSamples)),
           let wavURL = writeSamplesToTempWAV(windowSamples) {
            let transcription = self.transcription
            let lang = self.language
            let text = try? await transcription.transcribe(audioURL: wavURL, language: lang).text
            try? FileManager.default.removeItem(at: wavURL)
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let delta = aggregator.ingest(text)
                if !delta.isEmpty { injectDelta(delta) }
            }
        }
        windowSamples.removeAll()

        let pendingTail = aggregator.flushAndReset()
        if !pendingTail.isEmpty { injectDelta(pendingTail) }

        await waitForInjectionsToDrain()
    }

    /// Reset the coordinator to idle so it can be reused for the next session.
    /// Call after the session reaches a terminal state (done/cancelled/failed).
    func resetToIdle() {
        if case .idle = sessionState { return }
        if case .streaming = sessionState {
            logger.warning("resetToIdle called while streaming — cancelling first")
            cancelSession()
        }
        transition(to: .idle)
    }

    /// Update the full WAV URL after `AudioService.stopRecording()` resolves.
    /// Must be called before `endSession()`.
    func updateFullWavURL(_ url: URL) {
        fullWavURL = url
    }

    /// Cancel the session immediately, discarding any in-flight work.
    func cancelSession() {
        focusGuard?.stop()
        focusGuard = nil
        focusAbandonTask?.cancel()
        focusAbandonTask = nil
        cpuMonitor.stop()
        accumulator = nil
        pendingInjections.removeAll()
        transition(to: .cancelled)
        logger.info("StreamingCoordinator: session cancelled")
    }

    // MARK: - Chunk handling (LocalAgreement-2 over a growing window)

    private func handleChunkReady(_ buffer: AVAudioPCMBuffer) {
        guard case .streaming = sessionState else { return }

        if isFocusPaused {
            pausedPendingChunks.append(buffer)
            logger.info("StreamingCoordinator: chunk buffered (focus paused)")
            return
        }

        appendToWindow(buffer)
        transcribeWindowIfIdle()
    }

    /// Append a freshly-closed VAD segment's audio to the current window. The window
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

        // Incremental mode has no VAD in front of it, so keep silence away from
        // the model: an all-quiet window is dropped instead of transcribed.
        if incrementalMode, Self.isSilent(windowSamples) {
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
                self.handleWindowHypothesis(hypothesis)
            }
        }
    }

    /// Fold a completed window hypothesis into the aggregator and inject only the
    /// newly-stable text. Resets the window past the cap so per-pass cost stays bounded.
    private func handleWindowHypothesis(_ text: String?) {
        transcriptionInFlight = false
        guard case .streaming = sessionState else { return }

        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let delta = aggregator.ingest(text)
            if !delta.isEmpty { injectDelta(delta) }
        }

        // Incremental mode: two passes that agree word for word mean the speaker
        // paused. Close the window there — a clean sentence boundary — rather
        // than letting it run to the hard cap and cut mid-word. `windowDirty`
        // means newer audio is already waiting, so the pause is over; keep going.
        let pausedAtBoundary = incrementalMode
            && !windowDirty
            && aggregator.lastPassFullyAgreed
            && windowSamples.count >= Int(Self.chunkSampleRate * Self.minPauseResetSeconds)

        if windowSamples.count >= Self.maxWindowSamples || pausedAtBoundary {
            var tail = aggregator.flushAndReset()
            if !pausedAtBoundary {
                // The cap cut mid-speech; a punctuating model still ends the
                // partial hypothesis with a full stop that nobody spoke.
                tail = Self.droppingTrailingSentenceEnd(tail)
            }
            if !tail.isEmpty { injectDelta(tail) }
            windowSamples.removeAll(keepingCapacity: true)
            pendingWindowSeparator = true
            logger.info("StreamingCoordinator: window \(pausedAtBoundary ? "closed at pause" : "cap reached") — flushed + reset")
        }

        if windowDirty { transcribeWindowIfIdle() }
    }

    /// Inject a confirmed delta verbatim and keep the AX range tracker in sync. Deltas
    /// carry their own intra-window spacing; a separator space is added only at a window
    /// boundary, and only when the next text begins a Latin word (CJK needs none).
    private func injectDelta(_ delta: String) {
        var textToInject = delta
        if StreamingSeparator.needsLeadingSpace(
            delta: delta,
            atWindowBoundary: pendingWindowSeparator,
            hasPriorText: !streamingChunks.isEmpty
        ) {
            textToInject = " " + delta
        }
        pendingWindowSeparator = false

        streamingChunks.append(textToInject)
        chunkCount += 1
        if case .streaming = sessionState {
            transition(to: .streaming(chunkCount: chunkCount))
        }

        if let onPreviewText {
            onPreviewText(streamingChunks.joined())
            return
        }

        pendingInjections.append(textToInject)
        drainInjectionsIfIdle()
    }

    /// Paste queued deltas one at a time, coalescing whatever accumulated while
    /// the previous paste was in progress into a single paste.
    private func drainInjectionsIfIdle() {
        guard !isDrainingInjections else { return }
        isDrainingInjections = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pendingInjections.isEmpty {
                let text = self.pendingInjections.joined()
                self.pendingInjections.removeAll()
                await self.performInjection(text)
            }
            self.isDrainingInjections = false
        }
    }

    /// Resolves once every queued delta has been pasted (or after a short cap).
    private func waitForInjectionsToDrain() async {
        let deadline = Date().addingTimeInterval(3)
        while (isDrainingInjections || !pendingInjections.isEmpty) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func performInjection(_ textToInject: String) async {
        // DA-P0-2: Verify AX cursor has not moved mid-session before injecting.
        // If the cursor offset differs from our expectation, the user edited mid-session;
        // invalidate the tracker so full-pass replacement is skipped (spec §5 rule 3).
        if let expectedNext = self.rangeTracker?.expectedNextOffset {
            let actualOffset = self.resolveCurrentCursorOffsetAX()
            if actualOffset != nil && actualOffset != expectedNext {
                self.rangeTracker?.invalidate()
                self.logger.warning("StreamingCoordinator: cursor mismatch (expected=\(expectedNext), actual=\(actualOffset!)) — tracker invalidated, replacement will be skipped")
            }
        }

        do {
            try await self.injection.appendText(textToInject)
            // Use UTF-16 code unit count to match AX kAXSelectedTextRangeAttribute units.
            self.rangeTracker?.recordInjection(length: textToInject.utf16.count)

            // NEW-P1-1: Post-inject cursor verification.
            // appendText involves a ~1500ms clipboard round-trip; the user may move the cursor
            // during that window. Check again after injection lands to catch late edits.
            if let expectedNext = self.rangeTracker?.expectedNextOffset {
                let actualOffset = self.resolveCurrentCursorOffsetAX()
                if actualOffset != nil && actualOffset != expectedNext {
                    self.rangeTracker?.invalidate()
                    self.logger.warning("StreamingCoordinator: post-inject cursor mismatch (expected=\(expectedNext), actual=\(actualOffset!)) — tracker invalidated")
                }
            }

            self.logger.info("StreamingCoordinator: delta \(self.chunkCount) injected (\(textToInject.utf16.count) UTF-16 units)")
        } catch {
            self.logger.warning("StreamingCoordinator: append failed: \(error)")
        }
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

    /// Preview sessions: the full pass was unavailable, so fall back to the
    /// streamed text, completed up to the end of the recording.
    private func finishPreviewWithStreamedText() async {
        await finishStreamedText()
        finalResult = TranscriptionResult(text: streamingChunks.joined(), language: .unknown, durationMs: 0)
    }

    private func runFullPass() async {
        guard let wavURL = fullWavURL else {
            if isPreviewSession { await finishPreviewWithStreamedText() }
            transition(to: .done)
            return
        }

        // DA-P1-5: Race full-pass transcription against a 30s hard timeout.
        // Uses a throwing task group: transcription throws CancellationError on timeout,
        // timeout throws a sentinel error when transcription finishes first.
        let transcription = self.transcription
        let language = self.language

        enum FullPassResult {
            case transcribed(TranscriptionResult)
            case timedOut
            case failed
        }

        let timeoutSeconds = self.fullPassTimeoutSeconds
        let passResult: FullPassResult = await withTaskGroup(of: FullPassResult.self) { group in
            group.addTask {
                do {
                    let r = try await transcription.transcribe(audioURL: wavURL, language: language)
                    return .transcribed(r)
                } catch {
                    return .failed
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return .timedOut
            }
            // Take whichever finishes first.
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }

        let result: TranscriptionResult
        switch passResult {
        case .timedOut:
            logger.warning("StreamingCoordinator: full-pass exceeded \(Int(timeoutSeconds))s — keeping streaming version")
            if isPreviewSession { await finishPreviewWithStreamedText() }
            transition(to: .done)
            return
        case .failed:
            logger.warning("StreamingCoordinator: full-pass transcription failed — keeping streaming version")
            if isPreviewSession { await finishPreviewWithStreamedText() }
            transition(to: .done)
            return
        case .transcribed(let r):
            result = r
        }

        if isPreviewSession {
            // Nothing was typed, so there is nothing to replace: hand the
            // full-pass text to the owner to insert in one go.
            finalResult = result
            onPreviewText?(result.text)
            logger.info("StreamingCoordinator: full-pass complete (preview session)")
            transition(to: .done)
            return
        }

        let fullText = result.text
        // Deltas are verbatim slices that already carry their own spacing — join with "".
        let streamedText = streamingChunks.joined()
        let editDistance = computeEditDistanceRatio(a: streamedText, b: fullText)
        logger.info("StreamingCoordinator: full-pass complete. edit_distance_ratio=\(editDistance, format: .fixed(precision: 3))")

        if editDistance > 0.01,
           let tracker = rangeTracker,
           tracker.totalLength > 0 {

            // DA-P0-2: If the tracker was invalidated (cursor moved mid-session),
            // skip replacement to comply with spec §5 rule 3.
            if tracker.invalidated {
                logger.warning("StreamingCoordinator: tracker invalidated (cursor moved mid-session) — skipping full-pass replacement, streaming version preserved")
            } else {
                // Replace streamed text with full-pass result within the replace window
                let replaceDeadline = Task<Void, Never> {
                    try? await Task.sleep(for: .seconds(Self.replaceWindowSeconds))
                }

                do {
                    try await injection.replaceRange(
                        start: tracker.startOffset,
                        length: tracker.totalLength,
                        with: fullText
                    )
                    fullPassReplacedText = fullText
                    logger.info("StreamingCoordinator: replaced \(tracker.totalLength) UTF-16 units with full-pass result")
                } catch {
                    logger.warning("StreamingCoordinator: replaceRange failed — keeping streaming version: \(error)")
                }

                replaceDeadline.cancel()
            }
        }

        transition(to: .done)
    }

    // MARK: - Focus Guard

    private func setupFocusGuard(targetAppPID: pid_t) {
        let guard_ = FocusGuard(targetAppPID: targetAppPID)
        guard_.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleFocusEvent(event)
            }
        }
        guard_.start()
        self.focusGuard = guard_
    }

    private func handleFocusEvent(_ event: FocusGuard.Event) {
        switch event {
        case .focusLeft:
            isFocusPaused = true
            logger.info("StreamingCoordinator: injection paused — focus left")

            // DA-P1-3: Store the task handle so focusReturned can cancel it deterministically,
            // eliminating the race condition where the task fires 0.1s after isFocusPaused is
            // set back to false.
            focusAbandonTask?.cancel()
            focusAbandonTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(Self.focusAbandonSeconds))
                guard !Task.isCancelled else { return }
                guard self.isFocusPaused, case .streaming = self.sessionState else { return }
                self.logger.warning("StreamingCoordinator: focus lost >10s — abandoning session")
                self.cancellationReason = .focusAbandoned
                self.cancelSession()
            }

        case .focusReturned:
            // DA-P1-3: Cancel the abandon task before clearing isFocusPaused to avoid the race.
            focusAbandonTask?.cancel()
            focusAbandonTask = nil
            isFocusPaused = false
            logger.info("StreamingCoordinator: injection resumed — focus returned")

            // Flush buffered chunks into the window, then run a single pass.
            let buffered = pausedPendingChunks
            pausedPendingChunks.removeAll()
            for buffer in buffered {
                appendToWindow(buffer)
            }
            transcribeWindowIfIdle()
        }
    }

    // MARK: - CPU Monitor

    private func setupCPUMonitor() {
        cpuMonitor.onSustainedHighLoad = { [weak self] in
            Task { @MainActor in
                self?.handleCPUFallback()
            }
        }
        cpuMonitor.start()
    }

    private func handleCPUFallback() {
        guard case .streaming = sessionState else { return }
        logger.warning("StreamingCoordinator: CPU fallback triggered — stopping streaming inference")
        cpuFallbackTriggered = true
        accumulator?.onChunkReady = nil   // stop processing new chunks
        // The session continues; endSession() will still run full-pass on the complete WAV.
        // No further chunk transcriptions are dispatched.
    }

    /// Whether CPU fallback was triggered during this session.
    var didTriggerCPUFallback: Bool { cpuFallbackTriggered }

    // MARK: - Test Hooks

    /// Invalidate the range tracker to simulate a mid-session cursor move.
    /// For testing only — call from test targets via `@testable import`.
    func simulateTrackerInvalidation() {
        rangeTracker?.invalidate()
    }

    // MARK: - Helpers

    private func transition(to newState: StreamingSessionState) {
        sessionState = newState
    }

    private func resolveCurrentCursorOffsetAX() -> Int? {
        cursorOffsetProvider()
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
    private func computeEditDistanceRatio(a: String, b: String) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0.0 }
        let distance = levenshtein(Array(a), Array(b))
        let maxLen = max(a.count, b.count)
        return Double(distance) / Double(maxLen)
    }

    private func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
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

// MARK: - StreamingTextInjectionProtocol

/// Extends `TextInjectionServiceProtocol` with streaming-specific operations.
protocol StreamingTextInjectionProtocol {
    /// Append text at the current cursor position (no preceding newline).
    /// - Parameter text: The text to append.
    func appendText(_ text: String) async throws

    /// Select and replace an AX character range with new text.
    ///
    /// - Parameters:
    ///   - start: Zero-based AX character offset of the first character to replace.
    ///   - length: Number of characters to replace.
    ///   - text: Replacement text.
    /// - Throws: `MurmurError.injectionFailed` if the target element cannot be accessed
    ///   or the range is no longer valid.
    func replaceRange(start: Int, length: Int, with text: String) async throws
}
