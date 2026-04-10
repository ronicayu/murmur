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

    // MARK: - Session state

    private var accumulator: AudioBufferAccumulator?
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

    private static let chunkSampleRate: Double = 16000
    private static let chunkSeconds: Double = 3.0
    private static let focusAbandonSeconds: TimeInterval = 10.0
    private static let samplesPerChunk: Int = Int(chunkSampleRate * chunkSeconds)
    private static let replaceWindowSeconds: TimeInterval = 0.5

    private let logger = Logger(subsystem: "com.murmur.app", category: "streaming-coordinator")

    // MARK: - Init

    init(
        transcription: TranscriptionServiceProtocol,
        injection: TextInjectionServiceProtocol & StreamingTextInjectionProtocol,
        cpuMonitor: CPULoadMonitor = CPULoadMonitor()
    ) {
        self.transcription = transcription
        self.injection = injection
        self.cpuMonitor = cpuMonitor
    }

    // MARK: - Public API

    /// Begin a streaming session.
    ///
    /// - Parameters:
    ///   - language: BCP-47 language code (e.g. "en", "zh").
    ///   - targetAppPID: PID of the app receiving injected text (for focus guard).
    ///   - startOffset: AX character offset at the current insertion point.
    ///   - fullWavURL: URL where `AudioService` is writing the complete WAV.
    /// - Returns: The configured `AudioBufferAccumulator` to attach to the audio tap.
    func beginSession(
        language: String,
        targetAppPID: pid_t,
        startOffset: Int,
        fullWavURL: URL
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

        let acc = AudioBufferAccumulator(
            samplesPerChunk: Self.samplesPerChunk,
            sampleRate: Self.chunkSampleRate
        )
        acc.onChunkReady = { [weak self] buffer in
            guard let self else { return }
            Task { @MainActor in
                self.handleChunkReady(buffer)
            }
        }
        self.accumulator = acc

        setupFocusGuard(targetAppPID: targetAppPID)
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
            await self?.runFullPass()
        }
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
        transition(to: .cancelled)
        logger.info("StreamingCoordinator: session cancelled")
    }

    // MARK: - Chunk handling

    private func handleChunkReady(_ buffer: AVAudioPCMBuffer) {
        guard case .streaming = sessionState else { return }

        if isFocusPaused {
            pausedPendingChunks.append(buffer)
            logger.info("StreamingCoordinator: chunk buffered (focus paused)")
            return
        }

        processChunkBuffer(buffer)
    }

    private func processChunkBuffer(_ buffer: AVAudioPCMBuffer) {
        guard case .streaming = sessionState else { return }

        // Write buffer to a temp WAV for transcription
        guard let chunkURL = writeBufferToTempWAV(buffer) else {
            logger.error("StreamingCoordinator: failed to write chunk to temp WAV")
            return
        }

        let lang = self.language
        Task.detached { [weak self, chunkURL, lang] in
            guard let self else {
                try? FileManager.default.removeItem(at: chunkURL)
                return
            }
            do {
                let result = try await self.transcription.transcribe(audioURL: chunkURL, language: lang)
                try? FileManager.default.removeItem(at: chunkURL)
                await MainActor.run {
                    self.handleChunkTranscription(result.text)
                }
            } catch {
                try? FileManager.default.removeItem(at: chunkURL)
                await MainActor.run {
                    self.logger.warning("StreamingCoordinator: chunk transcription failed: \(error)")
                }
            }
        }
    }

    private func handleChunkTranscription(_ text: String) {
        guard case .streaming = sessionState else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let textToInject = streamingChunks.isEmpty ? text : " " + text
        streamingChunks.append(text)
        chunkCount += 1
        transition(to: .streaming(chunkCount: chunkCount))

        Task { @MainActor [weak self] in
            guard let self else { return }

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

                self.logger.info("StreamingCoordinator: chunk \(self.chunkCount) injected (\(textToInject.utf16.count) UTF-16 units)")
            } catch {
                self.logger.warning("StreamingCoordinator: append failed: \(error)")
            }
        }
    }

    // MARK: - Full-pass

    /// Seconds after which a stalled full-pass transcription is abandoned.
    private static let fullPassTimeoutSeconds: TimeInterval = 30.0
    /// After this many seconds, the pill should show a "still refining" warning.
    static let fullPassWarningSeconds: TimeInterval = 15.0

    private func runFullPass() async {
        guard let wavURL = fullWavURL else {
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
                try? await Task.sleep(for: .seconds(Self.fullPassTimeoutSeconds))
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
            logger.warning("StreamingCoordinator: full-pass exceeded \(Int(Self.fullPassTimeoutSeconds))s — keeping streaming version")
            transition(to: .done)
            return
        case .failed:
            logger.warning("StreamingCoordinator: full-pass transcription failed — keeping streaming version")
            transition(to: .done)
            return
        case .transcribed(let r):
            result = r
        }

        let fullText = result.text
        let streamedText = streamingChunks.joined(separator: " ")
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
                self.cancelSession()
            }

        case .focusReturned:
            // DA-P1-3: Cancel the abandon task before clearing isFocusPaused to avoid the race.
            focusAbandonTask?.cancel()
            focusAbandonTask = nil
            isFocusPaused = false
            logger.info("StreamingCoordinator: injection resumed — focus returned")

            // Flush buffered chunks
            let buffered = pausedPendingChunks
            pausedPendingChunks.removeAll()
            for buffer in buffered {
                processChunkBuffer(buffer)
            }
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

    /// Query the AX cursor offset (UTF-16 code units) of the focused element.
    /// Returns nil if the element is not accessible or does not support the attribute.
    private func resolveCurrentCursorOffsetAX() -> Int? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(frontmost.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement
        var selRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selRef) == .success,
              let selValue = selRef else { return nil }
        var cfRange = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(selValue as! AXValue, .cfRange, &cfRange) else { return nil }
        return cfRange.location + cfRange.length
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
