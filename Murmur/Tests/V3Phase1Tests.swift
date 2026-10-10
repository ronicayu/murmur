import XCTest
import AVFoundation
import AppKit
@testable import Murmur

// MARK: - V3 Phase 1 Tests
//
// Covers:
//   1. AudioBufferAccumulator 
//   2. StreamingTranscriptionCoordinator state machine
//   4. V1UsageCounter — discovery badge logic
//   5. Settings streaming toggle — UserDefaults key
//   6. AppState streaming case — statusText + equality
//   7. CPULoadMonitor — callback fires on sustained high load (unit-level)
//  18. Session identity — one session's late work never reaches another

// MARK: - 1. AudioBufferAccumulator (production file)

final class AudioBufferAccumulatorProductionTests: XCTestCase {

    private let sampleRate: Double = 16000
    private var format: AVAudioFormat!

    override func setUp() {
        super.setUp()
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    // MARK: 1a — fires callback after samplesPerChunk frames

    func test_accumulator_firesCallback_whenChunkThresholdReached() {
        // Arrange
        let samplesPerChunk = Int(sampleRate * 3.0)
        let accumulator = AudioBufferAccumulator(
            samplesPerChunk: samplesPerChunk,
            sampleRate: sampleRate
        )
        var callbackCount = 0
        var receivedFrameLength: Int = 0
        accumulator.onChunkReady = { buffer in
            callbackCount += 1
            receivedFrameLength = Int(buffer.frameLength)
        }

        // Act — feed exactly 3 seconds of audio in 512-sample fragments
        let totalSamples = samplesPerChunk
        feedSilence(to: accumulator, totalSamples: totalSamples, fragmentSize: 512)

        // Assert
        XCTAssertEqual(callbackCount, 1, "Must fire exactly one callback for exactly one chunk")
        XCTAssertEqual(receivedFrameLength, samplesPerChunk,
            "Delivered buffer must contain exactly samplesPerChunk frames")
    }

    // MARK: 1b — does not fire before threshold

    func test_accumulator_doesNotFire_beforeThreshold() {
        let samplesPerChunk = Int(sampleRate * 3.0)
        let accumulator = AudioBufferAccumulator(
            samplesPerChunk: samplesPerChunk,
            sampleRate: sampleRate
        )
        var callbackCount = 0
        accumulator.onChunkReady = { _ in callbackCount += 1 }

        // Feed only 1 second (less than chunk)
        feedSilence(to: accumulator, totalSamples: Int(sampleRate * 1.0), fragmentSize: 512)

        XCTAssertEqual(callbackCount, 0, "Must not fire before chunk threshold is reached")
    }

    // MARK: 1c — flush returns partial buffer

    func test_accumulator_flush_returnsPartialBuffer_andClearsState() {
        let samplesPerChunk = Int(sampleRate * 3.0)
        let accumulator = AudioBufferAccumulator(
            samplesPerChunk: samplesPerChunk,
            sampleRate: sampleRate
        )
        accumulator.onChunkReady = { _ in XCTFail("No chunk should fire for sub-threshold input") }

        let halfChunk = Int(sampleRate * 1.5)
        feedSilence(to: accumulator, totalSamples: halfChunk, fragmentSize: 512)

        // Act
        let flushed = accumulator.flush()

        // Assert
        XCTAssertNotNil(flushed, "flush() must return the partial buffer")
        XCTAssertEqual(Int(flushed!.frameLength), halfChunk,
            "Flushed buffer must contain exactly the pending samples")

        // Second flush must be empty
        XCTAssertNil(accumulator.flush(), "Second flush must return nil — accumulator is empty")
    }

    // MARK: 1d — multiple chunks in one append

    func test_accumulator_firesMultipleCallbacks_whenFeedingMultipleChunksAtOnce() {
        let samplesPerChunk = Int(sampleRate * 3.0)
        let accumulator = AudioBufferAccumulator(
            samplesPerChunk: samplesPerChunk,
            sampleRate: sampleRate
        )
        var callbackCount = 0
        accumulator.onChunkReady = { _ in callbackCount += 1 }

        // Feed 9 seconds = 3 chunks
        feedSilence(to: accumulator, totalSamples: samplesPerChunk * 3, fragmentSize: 4096)

        XCTAssertEqual(callbackCount, 3, "Must fire one callback per complete chunk")
    }

    // MARK: - Private helpers

    private func feedSilence(
        to accumulator: AudioBufferAccumulator,
        totalSamples: Int,
        fragmentSize: Int
    ) {
        var remaining = totalSamples
        while remaining > 0 {
            let batch = min(fragmentSize, remaining)
            let buf = makeBuffer(frameLength: batch)
            accumulator.append(buf)
            remaining -= batch
        }
    }

    private func makeBuffer(frameLength: Int) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameLength))!
        buf.frameLength = AVAudioFrameCount(frameLength)
        return buf
    }
}

// MARK: - 2. StreamingTranscriptionCoordinator State Machine

final class StreamingCoordinatorStateMachineTests: XCTestCase {

    private var coordinator: StreamingTranscriptionCoordinator!
    private var mockTranscription: MockTranscriptionService!
    private var preview: PreviewRecorder!

    override func setUp() async throws {
        try await super.setUp()
        mockTranscription = MockTranscriptionService()
        preview = PreviewRecorder()
        coordinator = await StreamingTranscriptionCoordinator(
            transcription: mockTranscription
        )
    }

    // MARK: 2a — initial state is idle

    func test_coordinator_initialState_isIdle() async {
        let state = await coordinator.sessionState
        XCTAssertEqual(state, .idle)
    }

    // MARK: 2b — beginSession transitions to streaming

    func test_coordinator_beginSession_transitionsToStreaming() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).wav")
        _ = await coordinator.beginSession(
            language: "en",
            fullWavURL: tempURL,
            onPreviewText: { _ in }
        )

        let state = await coordinator.sessionState
        if case .streaming = state {
            // pass
        } else {
            XCTFail("Expected .streaming, got \(state)")
        }
        await coordinator.cancelSession()
    }

    // MARK: 2c — cancelSession transitions to cancelled

    func test_coordinator_cancel_transitionsToCancelled() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).wav")
        _ = await coordinator.beginSession(
            language: "en",
            fullWavURL: tempURL,
            onPreviewText: { _ in }
        )

        await coordinator.cancelSession()

        let state = await coordinator.sessionState
        XCTAssertEqual(state, .cancelled)
    }

    // MARK: 2d — endSession transitions through finalizing to done

    func test_coordinator_endSession_transitionsThroughFinalizingToDone() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).wav")

        // Create a minimal valid WAV for the full-pass
        try createMinimalWAV(at: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        mockTranscription.stubbedResult = TranscriptionResult(
            text: "hello world",
            language: .english,
            durationMs: 1000
        )

        _ = await coordinator.beginSession(
            language: "en",
            fullWavURL: tempURL,
            onPreviewText: { _ in }
        )
        await coordinator.updateFullWavURL(tempURL)
        await coordinator.endSession()

        // Wait for done (full-pass is async)
        let deadline = Date().addingTimeInterval(5)
        var finalState = await coordinator.sessionState
        while Date() < deadline {
            finalState = await coordinator.sessionState
            if case .done = finalState { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(finalState, .done,
            "Coordinator must reach .done after endSession + full-pass. Got \(finalState)")
    }

    // MARK: 2e — beginSession during a session is a no-op (returns dummy accumulator)

    func test_coordinator_beginSession_whileStreaming_isNoOp() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).wav")

        _ = await coordinator.beginSession(
            language: "en", fullWavURL: tempURL,
            onPreviewText: { _ in }
        )

        // Second call while already streaming must not crash and must return an accumulator
        let acc2 = await coordinator.beginSession(
            language: "zh", fullWavURL: tempURL,
            onPreviewText: { _ in }
        )
        XCTAssertNotNil(acc2)
        let state = await coordinator.sessionState
        XCTAssertEqual(state, .streaming(chunkCount: 0),
            "The running session must not be disturbed")

        await coordinator.cancelSession()
    }

    // MARK: - Private helpers

    private func createMinimalWAV(at url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buf.frameLength = 160
        try file.write(from: buf)
    }
}

// MARK: - 4. V1UsageCounter — discovery badge

final class V1UsageCounterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset state for each test
        UserDefaults.standard.removeObject(forKey: V1UsageCounter.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: "streamingDiscoveryBadgeDismissed")
        UserDefaults.standard.removeObject(forKey: "streamingInputEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: V1UsageCounter.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: "streamingDiscoveryBadgeDismissed")
        UserDefaults.standard.removeObject(forKey: "streamingInputEnabled")
        super.tearDown()
    }

    // MARK: 4a — increment increases count

    func test_increment_increasesCount() {
        XCTAssertEqual(V1UsageCounter.currentCount(), 0)
        V1UsageCounter.increment()
        XCTAssertEqual(V1UsageCounter.currentCount(), 1)
        V1UsageCounter.increment()
        XCTAssertEqual(V1UsageCounter.currentCount(), 2)
    }

    // MARK: 4b — badge does not show before threshold

    func test_shouldShowDiscoveryBadge_returnsFalse_beforeThreshold() {
        for _ in 0..<9 {
            V1UsageCounter.increment()
        }
        XCTAssertFalse(V1UsageCounter.shouldShowDiscoveryBadge,
            "Badge must not show before 10 V1 sessions")
    }

    // MARK: 4c — badge shows at threshold

    func test_shouldShowDiscoveryBadge_returnsTrue_atThreshold() {
        for _ in 0..<10 {
            V1UsageCounter.increment()
        }
        XCTAssertTrue(V1UsageCounter.shouldShowDiscoveryBadge,
            "Badge must show after exactly 10 V1 sessions")
    }

    // MARK: 4d — badge does not show after dismissal

    func test_shouldShowDiscoveryBadge_returnsFalse_afterDismissal() {
        for _ in 0..<10 {
            V1UsageCounter.increment()
        }
        V1UsageCounter.dismissDiscoveryBadge()
        XCTAssertFalse(V1UsageCounter.shouldShowDiscoveryBadge,
            "Badge must not show after it has been dismissed")
    }

    // MARK: 4e — badge does not show when streaming already enabled

    func test_shouldShowDiscoveryBadge_returnsFalse_whenStreamingAlreadyEnabled() {
        for _ in 0..<10 {
            V1UsageCounter.increment()
        }
        UserDefaults.standard.set(true, forKey: "streamingInputEnabled")
        XCTAssertFalse(V1UsageCounter.shouldShowDiscoveryBadge,
            "Badge must not show when user has already enabled streaming")
    }
}

// MARK: - 5. Settings — streaming UserDefaults key

final class StreamingSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "streamingInputEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "streamingInputEnabled")
        super.tearDown()
    }

    func test_streamingInputEnabled_defaultIsFalse() {
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "streamingInputEnabled"),
            "streamingInputEnabled must default to false")
    }

    func test_streamingInputEnabled_canBeSetToTrue() {
        UserDefaults.standard.set(true, forKey: "streamingInputEnabled")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "streamingInputEnabled"))
    }

    func test_streamingInputEnabled_canBeSetToFalse() {
        UserDefaults.standard.set(true, forKey: "streamingInputEnabled")
        UserDefaults.standard.set(false, forKey: "streamingInputEnabled")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "streamingInputEnabled"))
    }
}

// MARK: - 6. AppState streaming case

final class AppStateStreamingTests: XCTestCase {

    func test_streamingState_equality_withSameChunkCount() {
        XCTAssertEqual(AppState.streaming(chunkCount: 0), AppState.streaming(chunkCount: 0))
        XCTAssertEqual(AppState.streaming(chunkCount: 3), AppState.streaming(chunkCount: 3))
    }

    func test_streamingState_inequality_withDifferentChunkCount() {
        XCTAssertNotEqual(AppState.streaming(chunkCount: 0), AppState.streaming(chunkCount: 1))
    }

    func test_streamingState_statusText_withZeroChunks() {
        XCTAssertEqual(AppState.streaming(chunkCount: 0).statusText, "Listening...")
    }

    func test_streamingState_statusText_withChunks() {
        XCTAssertEqual(AppState.streaming(chunkCount: 2).statusText, "Listening...")
    }

    func test_streamingState_isActive() {
        XCTAssertTrue(AppState.streaming(chunkCount: 0).isActive)
    }

    func test_streamingState_isNotEqualToRecording() {
        XCTAssertNotEqual(AppState.streaming(chunkCount: 0), AppState.recording)
    }
}

// MARK: - 8. CPULoadMonitor — callback fires on sustained high load

/// Hands the monitor made-up tick readings: each reading adds `step` to the
/// one before it, starting from `start` (the "since boot" totals).
private final class FakeCPUTicks: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: CPUTicks
    private let step: CPUTicks

    init(start: CPUTicks, step: CPUTicks) {
        self.ticks = start
        self.step = step
    }

    func next() -> CPUTicks? {
        lock.withLock {
            let reading = ticks
            ticks.user &+= step.user
            ticks.system &+= step.system
            ticks.idle &+= step.idle
            ticks.nice &+= step.nice
            return reading
        }
    }

    /// A host that idled for a long time and is fully busy from now on.
    static func busyNowIdleSinceBoot() -> FakeCPUTicks {
        FakeCPUTicks(
            start: CPUTicks(user: 0, system: 0, idle: 1_000_000, nice: 0),
            step: CPUTicks(user: 80, system: 20, idle: 0, nice: 0)
        )
    }

    /// A host that was busy for a long time and is fully idle from now on.
    static func idleNowBusySinceBoot() -> FakeCPUTicks {
        FakeCPUTicks(
            start: CPUTicks(user: 1_000_000, system: 0, idle: 0, nice: 0),
            step: CPUTicks(user: 0, system: 0, idle: 100, nice: 0)
        )
    }
}

final class CPULoadMonitorTests: XCTestCase {

    // MARK: 8a — load is measured between two readings, not since boot

    func test_load_isTheBusyShareBetweenTwoReadings() {
        let before = CPUTicks(user: 1000, system: 500, idle: 90_000, nice: 0)
        let after = CPUTicks(user: 1060, system: 530, idle: 90_010, nice: 0)
        // 60 + 30 busy ticks out of 100.
        XCTAssertEqual(CPULoadMonitor.load(from: before, to: after), 0.9, accuracy: 0.0001)
    }

    func test_load_ignoresHowBusyTheHostWasBeforeTheFirstReading() {
        let before = CPUTicks(user: 900_000, system: 90_000, idle: 10_000, nice: 0)
        let after = CPUTicks(user: 900_000, system: 90_000, idle: 10_100, nice: 0)
        XCTAssertEqual(CPULoadMonitor.load(from: before, to: after), 0.0, accuracy: 0.0001)
    }

    func test_load_isZeroWhenNoTimePassed() {
        let reading = CPUTicks(user: 5, system: 5, idle: 5, nice: 5)
        XCTAssertEqual(CPULoadMonitor.load(from: reading, to: reading), 0.0)
    }

    func test_load_survivesACounterWrappingAround() {
        let before = CPUTicks(user: UInt32.max - 9, system: 0, idle: 100, nice: 0)
        let after = CPUTicks(user: 40, system: 0, idle: 150, nice: 0)
        // user advanced by 50 across the wrap, idle by 50.
        XCTAssertEqual(CPULoadMonitor.load(from: before, to: after), 0.5, accuracy: 0.0001)
    }

    // MARK: 8b — the monitor acts on current load

    func test_cpuMonitor_fires_whenBusyNow_evenIfIdleSinceBoot() async {
        let ticks = FakeCPUTicks.busyNowIdleSinceBoot()
        let monitor = CPULoadMonitor(
            threshold: 0.9,
            sustainedSeconds: 0.05,
            pollInterval: 0.02,
            sampleTicks: { ticks.next() }
        )
        let fires = LockedCounter()
        await MainActor.run {
            monitor.onSustainedHighLoad = { fires.increment() }
        }
        monitor.start()
        let fired = await pollUntil(timeout: 5) { fires.value >= 1 }
        await MainActor.run { monitor.stop() }

        XCTAssertTrue(fired,
            "Sustained load between readings must fire, whatever the average since boot")
    }

    func test_cpuMonitor_doesNotFire_whenIdleNow_evenIfBusySinceBoot() async throws {
        let ticks = FakeCPUTicks.idleNowBusySinceBoot()
        let monitor = CPULoadMonitor(
            threshold: 0.9,
            sustainedSeconds: 0.05,
            pollInterval: 0.02,
            sampleTicks: { ticks.next() }
        )
        let fires = LockedCounter()
        await MainActor.run {
            monitor.onSustainedHighLoad = { fires.increment() }
        }
        monitor.start()
        try await Task.sleep(for: .seconds(0.4))
        await MainActor.run { monitor.stop() }

        XCTAssertEqual(fires.value, 0,
            "A host that is idle now must not trigger the fallback because it was busy earlier")
    }

    func test_cpuMonitor_doesNotFire_whenTheReadingFails() async throws {
        let monitor = CPULoadMonitor(
            threshold: 0.0,
            sustainedSeconds: 0.05,
            pollInterval: 0.02,
            sampleTicks: { nil }
        )
        let fires = LockedCounter()
        await MainActor.run {
            monitor.onSustainedHighLoad = { fires.increment() }
        }
        monitor.start()
        try await Task.sleep(for: .seconds(0.3))
        await MainActor.run { monitor.stop() }

        XCTAssertEqual(fires.value, 0, "No reading means no load, not full load")
    }

    func test_cpuMonitor_stop_preventsSubsequentCallbacks() async throws {
        // The load is high from the first reading, and stop() comes long
        // before the 1 s it must last. A monitor that kept polling after
        // stop() would fire during the wait below.
        let ticks = FakeCPUTicks.busyNowIdleSinceBoot()
        let monitor = CPULoadMonitor(
            threshold: 0.9,
            sustainedSeconds: 1.0,
            pollInterval: 0.05,
            sampleTicks: { ticks.next() }
        )
        let fires = LockedCounter()
        await MainActor.run {
            monitor.onSustainedHighLoad = { fires.increment() }
        }
        monitor.start()
        await MainActor.run { monitor.stop() }
        try await Task.sleep(for: .seconds(1.5))

        XCTAssertEqual(fires.value, 0, "A stopped monitor must not report load")
    }
}

// MARK: - 9. Integration: Full Streaming Pipeline (end-to-end with mocks)

final class StreamingPipelineIntegrationTests: XCTestCase {

    private var coordinator: StreamingTranscriptionCoordinator!
    private var mockTranscription: MockTranscriptionService!
    private var preview: PreviewRecorder!

    override func setUp() async throws {
        try await super.setUp()
        mockTranscription = MockTranscriptionService()
        preview = PreviewRecorder()
        coordinator = await StreamingTranscriptionCoordinator(
            transcription: mockTranscription
        )
    }

    // MARK: 9a — Normal 2-chunk session: the full-pass text is the final result

    func test_pipeline_twoChunkSession_fullPassTextIsTheFinalResult() async throws {
        // Arrange: streaming passes over the growing window mis-hear one word;
        // the full pass over the complete recording gets it right. The mock
        // tells the two apart by URL — the full pass reads the session's WAV,
        // window passes read temp files — not by call order, which depends on
        // how many window passes the coordinator chooses to run.
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_integration_\(UUID().uuidString).wav")
        try createMinimalWAV(at: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let windowPasses = LockedCounter()
        mockTranscription.onTranscribe = { url in
            if url == wavURL {
                return TranscriptionResult(text: "hello world how are you", language: .english, durationMs: 1000)
            }
            windowPasses.increment()
            let text = windowPasses.value == 1 ? "hello wurld" : "hello wurld how are you"
            return TranscriptionResult(text: text, language: .english, durationMs: 500)
        }

        // Act: begin session and simulate two chunk completions via the accumulator
        let accumulator = await coordinator.beginSession(
            language: "en",
            fullWavURL: wavURL,
            incrementalSeconds: 3.0,
            onPreviewText: { [preview] in preview?.record($0) }
        )

        // Feed enough samples to trigger two chunks
        accumulator.append(makeAudibleBuffer(seconds: 6.0))

        // Allow chunk tasks to dispatch
        try await Task.sleep(for: .milliseconds(200))

        // End session (triggers full-pass)
        await coordinator.updateFullWavURL(wavURL)
        await coordinator.endSession()

        // Wait for done
        let deadline = Date().addingTimeInterval(5)
        var finalState = await coordinator.sessionState
        while Date() < deadline {
            finalState = await coordinator.sessionState
            if case .done = finalState { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        // Assert: coordinator reached done state
        XCTAssertEqual(finalState, .done,
            "Pipeline must reach .done after endSession + full-pass")

        // Assert: the full-pass text is what the owner gets, and the preview
        // ends on it.
        let finalText = await coordinator.finalResult?.text
        XCTAssertEqual(finalText, "hello world how are you")
        XCTAssertEqual(preview.latest, "hello world how are you")
        XCTAssertTrue(preview.texts.contains { $0.contains("wurld") },
            "Precondition: the streamed text differed from the full pass")
    }

    // MARK: 9a-2 — Stable prefix: a one-pass hallucination is never shown

    func test_pipeline_stablePrefix_suppressesOnePassHallucination() async throws {
        // Growing-window hypotheses: pass 1 carries a phantom English tail ("thank you")
        // on what is really Chinese speech; pass 2 disagrees, so it must never reach the
        // preview. Only text two consecutive passes agree on is shown.
        // Thread-safe call counter — onTranscribe may be invoked from detached tasks.
        let lock = NSLock()
        var call = 0
        mockTranscription.onTranscribe = { _ in
            lock.lock(); call += 1; let n = call; lock.unlock()
            let text: String
            switch n {
            case 1: text = "你好 thank you"        // phantom tail on pass 1
            case 2: text = "你好 现在"             // real continuation; phantom gone
            default: text = "你好 现在 可以"
            }
            return TranscriptionResult(text: text, language: .english, durationMs: 100)
        }

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_stableprefix_\(UUID().uuidString).wav")
        try createMinimalWAV(at: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let acc = await coordinator.beginSession(
            language: "zh", fullWavURL: wavURL,
            incrementalSeconds: 3.0,
            onPreviewText: { [preview] in preview?.record($0) })

        func feedOneChunk() async throws {
            acc.append(makeAudibleBuffer(seconds: 3.0))
            try await Task.sleep(for: .milliseconds(400))   // let each pass finish, in order
        }

        try await feedOneChunk()   // pass 1 -> emits nothing (LocalAgreement-2 needs a 2nd pass)
        try await feedOneChunk()   // pass 2 -> confirms "你好"
        try await feedOneChunk()   // pass 3 -> confirms "现在"

        // Poll until the confirmed prefix lands.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !preview.latest.contains("现在") {
            try await Task.sleep(for: .milliseconds(50))
        }

        let streamed = preview.latest
        XCTAssertFalse(streamed.lowercased().contains("thank"),
                       "one-pass hallucination must never reach the preview; got: '\(streamed)'")
        XCTAssertTrue(streamed.contains("你好"),
                      "confirmed prefix should be shown; got: '\(streamed)'")
        XCTAssertTrue(streamed.contains("现在"),
                      "second confirmed token should be shown; got: '\(streamed)'")
    }

    // MARK: - Private helpers

    private func createMinimalWAV(at url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buf.frameLength = 160
        try file.write(from: buf)
    }
}

// MARK: - 11. StreamingSessionState — full equality and terminal states

final class StreamingSessionStateTests: XCTestCase {

    // MARK: 11a — idle equality

    func test_state_idle_equalsIdle() {
        XCTAssertEqual(StreamingSessionState.idle, StreamingSessionState.idle)
    }

    // MARK: 11b — done equality

    func test_state_done_equalsDone() {
        XCTAssertEqual(StreamingSessionState.done, StreamingSessionState.done)
    }

    // MARK: 11c — cancelled equality

    func test_state_cancelled_equalsCancelled() {
        XCTAssertEqual(StreamingSessionState.cancelled, StreamingSessionState.cancelled)
    }

    // MARK: 11d — failed equality (same message)

    func test_state_failed_withSameMessage_isEqual() {
        XCTAssertEqual(
            StreamingSessionState.failed("oops"),
            StreamingSessionState.failed("oops"),
            "Two .failed states with the same message must be equal"
        )
    }

    // MARK: 11e — failed inequality (different messages)

    func test_state_failed_withDifferentMessages_isNotEqual() {
        XCTAssertNotEqual(
            StreamingSessionState.failed("a"),
            StreamingSessionState.failed("b"),
            "Two .failed states with different messages must not be equal"
        )
    }

    // MARK: 11f — cross-case inequality

    func test_state_idle_notEqualDone() {
        XCTAssertNotEqual(StreamingSessionState.idle, StreamingSessionState.done)
    }

    func test_state_streaming_notEqualFinalizing() {
        XCTAssertNotEqual(
            StreamingSessionState.streaming(chunkCount: 0),
            StreamingSessionState.finalizing
        )
    }
}

// MARK: - 12. StreamingTranscriptionCoordinator — additional state machine paths

final class StreamingCoordinatorExtendedStateMachineTests: XCTestCase {

    private var coordinator: StreamingTranscriptionCoordinator!
    private var mockTranscription: MockTranscriptionService!
    private var preview: PreviewRecorder!

    override func setUp() async throws {
        try await super.setUp()
        mockTranscription = MockTranscriptionService()
        preview = PreviewRecorder()
        coordinator = await StreamingTranscriptionCoordinator(
            transcription: mockTranscription
        )
    }

    // MARK: 12a — endSession while idle is a no-op (stays idle)

    func test_coordinator_endSession_whileIdle_isNoOp() async {
        // Precondition: idle
        let before = await coordinator.sessionState
        XCTAssertEqual(before, .idle)

        await coordinator.endSession()

        let after = await coordinator.sessionState
        XCTAssertEqual(after, .idle,
            "endSession called while idle must leave state as idle")
    }

    // MARK: 12b — cancelSession while idle is a no-op (stays idle)

    func test_coordinator_cancelSession_whileIdle_staysIdle() async {
        await coordinator.cancelSession()
        let state = await coordinator.sessionState
        XCTAssertEqual(state, .idle,
            "There is nothing to cancel while idle; a .cancelled state would block the next session")
    }

    // MARK: 12c — cancelSession while already cancelled stays cancelled

    func test_coordinator_cancelSession_whileAlreadyCancelled_staysCancelled() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).wav")
        _ = await coordinator.beginSession(
            language: "en", fullWavURL: tempURL,
            onPreviewText: { _ in }
        )
        await coordinator.cancelSession()
        await coordinator.cancelSession()
        let state = await coordinator.sessionState
        XCTAssertEqual(state, .cancelled,
            "Double-cancel must remain in .cancelled")
    }

    // MARK: 12d — didTriggerCPUFallback starts false

    func test_coordinator_cpuFallback_initiallyFalse() async {
        let flag = await coordinator.didTriggerCPUFallback
        XCTAssertFalse(flag, "CPU fallback flag must be false before any session")
    }

    // MARK: 12f — full-pass timeout path: transitions to done

    func test_coordinator_fullPassTimeout_transitionsToDone() async throws {
        // The full pass never returns during the test and, like the real
        // decode, cannot be cancelled: the timeout must not wait for it.
        let stuckTranscription = GatedTranscriptionService()
        defer { stuckTranscription.releaseAll() }
        let fastCoordinator = await StreamingTranscriptionCoordinator(
            transcription: stuckTranscription,
            fullPassTimeoutOverride: 0.2   // 200ms — fast timeout for test
        )

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_timeout_\(UUID().uuidString).wav")
        try createMinimalWAV(at: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        _ = await fastCoordinator.beginSession(
            language: "en",
            fullWavURL: wavURL,
            onPreviewText: { _ in }
        )
        await fastCoordinator.updateFullWavURL(wavURL)
        await fastCoordinator.endSession()

        let reachedDone = await pollUntil(timeout: 5) { fastCoordinator.sessionState == .done }

        XCTAssertTrue(reachedDone,
            "Coordinator must reach .done when the full pass times out, without waiting for the decode")
        XCTAssertEqual(stuckTranscription.finishedCount, 0,
            "Precondition: the decode is still running when the session is done")
        let failed = await fastCoordinator.fullPassFailed
        XCTAssertTrue(failed, "The owner must be able to tell that the full pass did not finish")
    }

    // MARK: 12g — full-pass not run when fullWavURL is nil

    func test_coordinator_fullPass_skipped_whenNoWavURL() async throws {
        // Create coordinator, begin session, but never call updateFullWavURL with a real URL.
        // The coordinator captures the initial URL from beginSession — use a dummy that
        // won't exist so the full-pass fails gracefully (and we can verify done is reached).
        let nonexistentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).wav")

        // We'll use the stubbed transcription that returns immediately (but the file won't exist).
        // The real service would fail on a missing file; the mock ignores the URL.
        mockTranscription.stubbedResult = TranscriptionResult(
            text: "ok", language: .english, durationMs: 100
        )

        _ = await coordinator.beginSession(
            language: "en",
            fullWavURL: nonexistentURL,
            onPreviewText: { _ in }
        )
        // Do not feed any audio — no chunks, no streaming text
        await coordinator.endSession()

        let deadline = Date().addingTimeInterval(5)
        var finalState = await coordinator.sessionState
        while Date() < deadline {
            finalState = await coordinator.sessionState
            if case .done = finalState { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(finalState, .done,
            "Coordinator must always reach .done even with no prior streaming chunks")
    }

    // MARK: - Private helpers

    private func createMinimalWAV(at url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buf.frameLength = 160
        try file.write(from: buf)
    }
}

// MARK: - 14. CPULoadMonitor — edge cases

final class CPULoadMonitorEdgeCaseTests: XCTestCase {

    // MARK: 14b — multiple start/stop cycles do not cause double-firing

    func test_cpuMonitor_startStop_multipleCycles_noDoubleFire() async throws {
        let fires = LockedCounter()
        let ticks = FakeCPUTicks.busyNowIdleSinceBoot()
        let monitor = CPULoadMonitor(
            threshold: 0.9,
            sustainedSeconds: 0.05,
            pollInterval: 0.02,
            sampleTicks: { ticks.next() }
        )
        await MainActor.run { monitor.onSustainedHighLoad = { fires.increment() } }

        // First cycle: every reading is fully busy, so the monitor detects sustained
        // load and fires exactly once (evaluate() self-stops on fire). Poll for the
        // fire rather than sleeping a fixed window — under machine load the
        // detached poller can be starved past any fixed budget.
        monitor.start()
        let firedFirst = await pollUntil { fires.value >= 1 }
        XCTAssertTrue(firedFirst,
            "With a fully busy host, callback must fire at least once during start")
        let firstCount = fires.value

        // After an explicit stop, the count must not advance.
        await MainActor.run { monitor.stop() }
        try await Task.sleep(for: .seconds(0.1))
        let countAfterStop = fires.value
        XCTAssertEqual(firstCount, countAfterStop,
            "stop() must freeze the callback count — no fires in the stopped gap")

        // Second cycle fires again — start/stop is reusable.
        monitor.start()
        let firedSecond = await pollUntil { fires.value > firstCount }
        await MainActor.run { monitor.stop() }
        XCTAssertTrue(firedSecond,
            "Second start cycle must fire again after a prior stop")
    }
}

// MARK: - 16. Edit distance / ratio — boundary conditions

final class EditDistanceRatioTests: XCTestCase {
    // StreamingTranscriptionCoordinator.editDistanceRatio decides whether the
    // full pass replaces the streamed text.

    // MARK: 16a — identical strings → 0.0

    func test_editDistance_identicalStrings_returnsZero() {
        XCTAssertEqual(ratio("hello", "hello"), 0.0, accuracy: 0.001)
    }

    // MARK: 16b — empty strings → 0.0

    func test_editDistance_bothEmpty_returnsZero() {
        XCTAssertEqual(ratio("", ""), 0.0, accuracy: 0.001)
    }

    // MARK: 16c — one empty string → 1.0

    func test_editDistance_oneEmptyString_returnsOne() {
        XCTAssertEqual(ratio("hello", ""), 1.0, accuracy: 0.001)
        XCTAssertEqual(ratio("", "world"), 1.0, accuracy: 0.001)
    }

    // MARK: 16d — single character substitution

    func test_editDistance_singleSubstitution_returnsExpected() {
        // "cat" → "bat": 1 edit, max length 3 → ratio = 1/3
        let r = ratio("cat", "bat")
        XCTAssertEqual(r, 1.0 / 3.0, accuracy: 0.001)
    }

    // MARK: 16e — completely different strings → 1.0

    func test_editDistance_completelyDifferent_returnsOne() {
        // "abc" → "xyz": 3 edits, max 3 → 1.0
        XCTAssertEqual(ratio("abc", "xyz"), 1.0, accuracy: 0.001)
    }

    // MARK: 16f — ratio 0.01 threshold: just-above triggers replacement

    func test_editDistance_justAboveThreshold_triggersReplacement() {
        // Ratio > 0.01 causes replacement; below or equal does not.
        // "hello world" (11 chars) — 1 edit → ratio ≈ 0.0909 > 0.01
        let r = ratio("hello world", "hello worlt")
        XCTAssertGreaterThan(r, 0.01,
            "One-char error in 11-char string must exceed 0.01 threshold")
    }

    private func ratio(_ a: String, _ b: String) -> Double {
        StreamingTranscriptionCoordinator.editDistanceRatio(a, b)
    }
}

// MARK: - 17. AudioBufferAccumulator — additional edge cases

final class AudioBufferAccumulatorEdgeCaseTests: XCTestCase {

    private let sampleRate: Double = 16000
    private var format: AVAudioFormat!

    override func setUp() {
        super.setUp()
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    // MARK: 17a — appending a zero-frameLength buffer is a no-op

    func test_accumulator_appendZeroLengthBuffer_isNoOp() {
        let samplesPerChunk = Int(sampleRate * 3.0)
        let accumulator = AudioBufferAccumulator(
            samplesPerChunk: samplesPerChunk,
            sampleRate: sampleRate
        )
        var fired = false
        accumulator.onChunkReady = { _ in fired = true }

        let emptyBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        emptyBuf.frameLength = 0
        accumulator.append(emptyBuf)

        XCTAssertFalse(fired, "Appending a zero-length buffer must not fire onChunkReady")
        XCTAssertNil(accumulator.flush(), "After a zero-length append the accumulator must remain empty")
    }

    // MARK: 17b — flush on empty accumulator returns nil

    func test_accumulator_flush_onEmpty_returnsNil() {
        let accumulator = AudioBufferAccumulator(
            samplesPerChunk: Int(sampleRate * 3.0),
            sampleRate: sampleRate
        )
        XCTAssertNil(accumulator.flush(),
            "flush() on an empty accumulator must return nil")
    }

    // MARK: 17c — remainder after multi-chunk feed is flushed correctly

    func test_accumulator_feedTwoChunksPlusRemainder_flushesRemainder() {
        let samplesPerChunk = Int(sampleRate * 3.0)
        let accumulator = AudioBufferAccumulator(
            samplesPerChunk: samplesPerChunk,
            sampleRate: sampleRate
        )
        var chunkCount = 0
        accumulator.onChunkReady = { _ in chunkCount += 1 }

        let remainder = 1000
        let total = samplesPerChunk * 2 + remainder
        var remaining = total
        while remaining > 0 {
            let batch = min(512, remaining)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(batch))!
            buf.frameLength = AVAudioFrameCount(batch)
            accumulator.append(buf)
            remaining -= batch
        }

        XCTAssertEqual(chunkCount, 2, "Two full chunks must be delivered")

        let flushed = accumulator.flush()
        XCTAssertNotNil(flushed, "Flush must return remaining samples")
        XCTAssertEqual(Int(flushed!.frameLength), remainder,
            "Flushed buffer must contain exactly the remainder samples")
    }

    // MARK: 17d — onChunkReady can be replaced mid-accumulation

    func test_accumulator_replacingOnChunkReady_midAccumulation() {
        let samplesPerChunk = Int(sampleRate * 3.0)
        let accumulator = AudioBufferAccumulator(
            samplesPerChunk: samplesPerChunk,
            sampleRate: sampleRate
        )

        var firstHandlerCount = 0
        var secondHandlerCount = 0
        accumulator.onChunkReady = { _ in firstHandlerCount += 1 }

        // Feed half a chunk
        let halfChunk = samplesPerChunk / 2
        let buf1 = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(halfChunk))!
        buf1.frameLength = AVAudioFrameCount(halfChunk)
        accumulator.append(buf1)

        // Replace the callback before the chunk threshold is reached
        accumulator.onChunkReady = { _ in secondHandlerCount += 1 }

        // Feed the remaining half — triggers the chunk
        let buf2 = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(halfChunk))!
        buf2.frameLength = AVAudioFrameCount(halfChunk)
        accumulator.append(buf2)

        XCTAssertEqual(firstHandlerCount, 0,
            "First handler must not fire (replaced before threshold)")
        XCTAssertEqual(secondHandlerCount, 1,
            "Second (replacement) handler must fire when chunk completes")
    }

    // MARK: 17e — setting onChunkReady to nil suppresses delivery

    func test_accumulator_nilOnChunkReady_suppressesDelivery() {
        let samplesPerChunk = Int(sampleRate * 3.0)
        let accumulator = AudioBufferAccumulator(
            samplesPerChunk: samplesPerChunk,
            sampleRate: sampleRate
        )
        var fired = false
        accumulator.onChunkReady = { _ in fired = true }
        accumulator.onChunkReady = nil   // clear before feeding

        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samplesPerChunk))!
        buf.frameLength = AVAudioFrameCount(samplesPerChunk)
        accumulator.append(buf)

        XCTAssertFalse(fired,
            "Setting onChunkReady to nil must suppress chunk delivery")
    }

    // MARK: 17f — the callback can be changed while the audio thread appends

    func test_accumulator_changingOnChunkReady_whileAppending_isSafe() {
        let accumulator = AudioBufferAccumulator(samplesPerChunk: 160, sampleRate: sampleRate)
        let delivered = LockedCounter()
        let format = self.format!
        let rounds = 2000

        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            for round in 0..<rounds {
                if worker == 0 {
                    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
                    buf.frameLength = 160
                    accumulator.append(buf)
                } else {
                    let handler: ((AVAudioPCMBuffer) -> Void)? =
                        round.isMultiple(of: 2) ? { _ in delivered.increment() } : nil
                    accumulator.onChunkReady = handler
                }
            }
        }

        XCTAssertLessThanOrEqual(delivered.value, rounds,
            "Each appended chunk is delivered at most once, to whichever callback was set")

        // The accumulator still works after the contention: one more chunk
        // goes exactly once to the callback that is set now.
        let after = LockedCounter()
        accumulator.onChunkReady = { _ in after.increment() }
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buf.frameLength = 160
        accumulator.append(buf)
        XCTAssertEqual(after.value, 1)
    }
}

// MARK: - 18. Sessions do not leak into each other

@MainActor
final class StreamingCoordinatorSessionIdentityTests: XCTestCase {

    private var wavURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_session_\(UUID().uuidString).wav")
        try makeAudibleWAV(at: wavURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: wavURL)
        try await super.tearDown()
    }

    private func makeCoordinator(
        _ transcription: TranscriptionServiceProtocol,
        fullPassTimeout: TimeInterval? = nil
    ) -> StreamingTranscriptionCoordinator {
        StreamingTranscriptionCoordinator(
            transcription: transcription,
            fullPassTimeoutOverride: fullPassTimeout
        )
    }

    private func begin(
        _ coordinator: StreamingTranscriptionCoordinator,
        incrementalSeconds: Double = 1.0,
        onPreviewText: @escaping (String) -> Void = { _ in }
    ) -> AudioBufferAccumulator {
        coordinator.beginSession(
            language: "en", fullWavURL: wavURL,
            incrementalSeconds: incrementalSeconds, onPreviewText: onPreviewText
        )
    }

    /// Gives main-actor work that is already queued the chance to run.
    private func letQueuedWorkRun() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    // MARK: 18a — a start that failed must not poison the next session (S1)

    func test_beginSession_afterACancelWhileIdle_startsALiveSession() async {
        let transcription = GatedTranscriptionService()
        defer { transcription.releaseAll() }
        let coordinator = makeCoordinator(transcription)

        // What the owner does when starting the recording fails: cancel a
        // session that never began.
        coordinator.cancelSession()
        XCTAssertEqual(coordinator.sessionState, .idle)

        let accumulator = begin(coordinator)
        XCTAssertEqual(coordinator.sessionState, .streaming(chunkCount: 0))

        accumulator.append(makeAudibleBuffer(seconds: 1.0))
        let transcribed = await pollUntil { transcription.startedCount == 1 }
        XCTAssertTrue(transcribed, "The returned accumulator must feed the session")
    }

    func test_beginSession_fromATerminalState_startsALiveSession() async {
        let transcription = GatedTranscriptionService()
        defer { transcription.releaseAll() }
        let coordinator = makeCoordinator(transcription)

        _ = begin(coordinator)
        coordinator.cancellationReason = .backstopTimeout
        coordinator.cancelSession()
        XCTAssertEqual(coordinator.sessionState, .cancelled)

        // No resetToIdle() in between.
        let accumulator = begin(coordinator)
        XCTAssertEqual(coordinator.sessionState, .streaming(chunkCount: 0))
        XCTAssertNil(coordinator.cancellationReason,
            "The previous session's cancellation must not be reported for this one")

        accumulator.append(makeAudibleBuffer(seconds: 1.0))
        let transcribed = await pollUntil { transcription.startedCount == 1 }
        XCTAssertTrue(transcribed, "The returned accumulator must feed the session")
    }

    func test_previousSessionsResults_areCleared_byBeginAndByReset() async {
        let transcription = MockTranscriptionService()
        transcription.stubbedResult = TranscriptionResult(text: "first session", language: .english, durationMs: 1)
        let coordinator = makeCoordinator(transcription)

        _ = begin(coordinator, onPreviewText: { _ in })
        coordinator.endSession()
        let done = await pollUntil(timeout: 5) { coordinator.sessionState == .done }
        XCTAssertTrue(done)
        XCTAssertEqual(coordinator.finalResult?.text, "first session")
        XCTAssertNotNil(coordinator.finalizingStartedAt)

        // A new session straight from .done.
        _ = begin(coordinator, onPreviewText: { _ in })
        XCTAssertNil(coordinator.finalResult, "The previous session's text must not be delivered again")
        XCTAssertNil(coordinator.finalizingStartedAt)
        XCTAssertNil(coordinator.lastEditDistanceRatio)

        coordinator.endSession()
        let doneAgain = await pollUntil(timeout: 5) { coordinator.sessionState == .done }
        XCTAssertTrue(doneAgain)
        XCTAssertNotNil(coordinator.finalResult)

        coordinator.resetToIdle()
        XCTAssertEqual(coordinator.sessionState, .idle)
        XCTAssertNil(coordinator.finalResult)
        XCTAssertNil(coordinator.finalizingStartedAt)
        XCTAssertNil(coordinator.cancellationReason)
        XCTAssertNil(coordinator.sessionStartedAt)
    }

    // MARK: 18b — the full-pass timeout is real (S2)

    func test_firstResult_returnsTheValue_whenTheOperationFinishesInTime() async {
        let value = await StreamingTranscriptionCoordinator.firstResult(within: 30) { "text" }
        XCTAssertEqual(value, "text")
    }

    func test_firstResult_returnsNil_withoutWaitingForAnOperationThatCannotBeCancelled() async {
        let gate = GatedTranscriptionService()
        defer { gate.releaseAll() }
        let url = wavURL!
        let timedOut = LockedCounter()
        Task {
            let value = await StreamingTranscriptionCoordinator.firstResult(within: 0.1) {
                try? await gate.transcribe(audioURL: url, language: "en").text
            }
            if value == nil { timedOut.increment() }
        }

        let returned = await pollUntil(timeout: 5) { timedOut.value == 1 }

        XCTAssertTrue(returned, "The timeout must return while the operation is still blocked")
        XCTAssertEqual(gate.finishedCount, 0)
    }

    func test_fullPassTimeout_endsWithTheStreamedText() async throws {
        let transcription = GatedTranscriptionService()
        defer { transcription.releaseAll() }
        transcription.textForCall = { _ in "hello world" }
        let coordinator = makeCoordinator(transcription, fullPassTimeout: 0.2)

        var previews: [String] = []

        // Two window passes that agree, so there is streamed text to fall back on.
        let accumulator = begin(coordinator, onPreviewText: { previews.append($0) })
        accumulator.append(makeAudibleBuffer(seconds: 1.0))
        accumulator.append(makeAudibleBuffer(seconds: 1.0))
        transcription.releaseOne()
        transcription.releaseOne()
        let streamed = await pollUntil(timeout: 5) { previews.last == "hello world" }
        XCTAssertTrue(streamed)

        // The full pass (the third call) is never released.
        coordinator.endSession()
        let done = await pollUntil(timeout: 5) { coordinator.sessionState == .done }

        XCTAssertTrue(done, "The session must end at the timeout although the decode still runs")
        XCTAssertEqual(transcription.finishedCount, 2, "Precondition: the full pass is still blocked")
        XCTAssertEqual(coordinator.finalResult?.text, "hello world",
            "The streamed text is what the owner gets")
    }

    // MARK: 18c — work that outlives its session reaches no other session (S2)

    func test_fullPassOfACancelledSession_changesNothing_whenItFinishesWhileIdle() async throws {
        let transcription = GatedTranscriptionService()
        defer { transcription.releaseAll() }
        let coordinator = makeCoordinator(transcription)
        var previews: [String] = []

        _ = begin(coordinator, onPreviewText: { previews.append($0) })
        coordinator.endSession()
        let fullPassStarted = await pollUntil { transcription.startedCount == 1 }
        XCTAssertTrue(fullPassStarted)

        // The owner's backstop gives up on the session.
        coordinator.cancellationReason = .backstopTimeout
        coordinator.cancelSession()
        coordinator.resetToIdle()

        transcription.releaseOne()
        let fullPassFinished = await pollUntil { transcription.finishedCount == 1 }
        XCTAssertTrue(fullPassFinished)
        try await letQueuedWorkRun()

        XCTAssertEqual(coordinator.sessionState, .idle)
        XCTAssertNil(coordinator.finalResult)
        XCTAssertTrue(previews.isEmpty)
    }

    func test_fullPassOfACancelledSession_doesNotFinishTheNextSession() async throws {
        let transcription = GatedTranscriptionService()
        defer { transcription.releaseAll() }
        transcription.textForCall = { _ in "stale text" }
        let coordinator = makeCoordinator(transcription)
        var firstPreviews: [String] = []
        var secondPreviews: [String] = []

        _ = begin(coordinator, onPreviewText: { firstPreviews.append($0) })
        coordinator.endSession()
        let fullPassStarted = await pollUntil { transcription.startedCount == 1 }
        XCTAssertTrue(fullPassStarted)
        coordinator.cancelSession()
        coordinator.resetToIdle()

        _ = begin(coordinator, onPreviewText: { secondPreviews.append($0) })

        // The first session's full pass comes back now, into the second session.
        transcription.releaseOne()
        let fullPassFinished = await pollUntil { transcription.finishedCount == 1 }
        XCTAssertTrue(fullPassFinished)
        try await letQueuedWorkRun()

        XCTAssertEqual(coordinator.sessionState, .streaming(chunkCount: 0),
            "A result from the previous session must not end this one")
        XCTAssertNil(coordinator.finalResult)
        XCTAssertTrue(firstPreviews.isEmpty)
        XCTAssertTrue(secondPreviews.isEmpty)
    }

    func test_windowPassOfACancelledSession_isNotCountedAsAPassOfTheNextSession() async throws {
        let transcription = GatedTranscriptionService()
        defer { transcription.releaseAll() }
        transcription.textForCall = { _ in "alpha beta" }
        let coordinator = makeCoordinator(transcription)

        let first = begin(coordinator)
        first.append(makeAudibleBuffer(seconds: 1.0))
        let firstPassStarted = await pollUntil { transcription.startedCount == 1 }
        XCTAssertTrue(firstPassStarted)
        coordinator.cancelSession()
        coordinator.resetToIdle()

        var previews: [String] = []
        let second = begin(coordinator, onPreviewText: { previews.append($0) })
        second.append(makeAudibleBuffer(seconds: 1.0))
        let secondPassStarted = await pollUntil { transcription.startedCount == 2 }
        XCTAssertTrue(secondPassStarted, "A pass left over from the last session must not hold this one up")

        // Both passes return the same words. Text needs two passes *of one
        // session* to agree; the stale one must not be the second vote.
        transcription.releaseOne()
        transcription.releaseOne()
        let bothFinished = await pollUntil { transcription.finishedCount == 2 }
        XCTAssertTrue(bothFinished)
        try await letQueuedWorkRun()

        XCTAssertEqual(coordinator.chunkCount, 0)
        XCTAssertTrue(previews.isEmpty,
            "Nothing is confirmed after a single pass of the new session")
    }

    // MARK: 18d — a window reset keeps audio the pass never heard (S4)

    func test_windowReset_keepsAudioCapturedWhileThePassWasRunning() async throws {
        let transcription = GatedTranscriptionService()
        defer { transcription.releaseAll() }
        let coordinator = makeCoordinator(transcription)
        let sixSeconds = 6 * 16_000

        // Two 6 s chunks: the first starts a pass, the second arrives while
        // that pass is running and takes the window to the 12 s cap.
        let accumulator = begin(coordinator, incrementalSeconds: 6.0)
        accumulator.append(makeAudibleBuffer(seconds: 6.0))
        accumulator.append(makeAudibleBuffer(seconds: 6.0))
        let firstPassStarted = await pollUntil { transcription.startedCount == 1 }
        XCTAssertTrue(firstPassStarted)
        XCTAssertEqual(transcription.framesOfCall(0), sixSeconds)
        try await letQueuedWorkRun()

        // The pass returns: the window is at the cap and is reset.
        transcription.releaseOne()

        let secondPassStarted = await pollUntil { transcription.startedCount == 2 }
        XCTAssertTrue(secondPassStarted, "The second chunk must still be transcribed after the reset")
        XCTAssertEqual(transcription.framesOfCall(1), sixSeconds,
            "The next window must hold exactly the audio the first pass did not cover")
    }

    // MARK: 18e — stopping starts no pass whose result is thrown away (S7)

    func test_endSession_transcribesOnlyTheFullRecording() async {
        let transcription = MockTranscriptionService()
        let windowPasses = LockedCounter()
        let fullURL = wavURL!
        transcription.onTranscribe = { url in
            if url != fullURL { windowPasses.increment() }
            return TranscriptionResult(text: "full text", language: .english, durationMs: 1)
        }
        let coordinator = makeCoordinator(transcription)

        let accumulator = begin(coordinator, onPreviewText: { _ in })
        // Less than one chunk: it is still in the accumulator at stop time.
        accumulator.append(makeAudibleBuffer(seconds: 0.5))
        coordinator.endSession()
        let done = await pollUntil(timeout: 5) { coordinator.sessionState == .done }

        XCTAssertTrue(done)
        XCTAssertEqual(coordinator.finalResult?.text, "full text")
        XCTAssertEqual(windowPasses.value, 0,
            "The tail must not get a window pass of its own in front of the full pass")
    }
}

// MARK: - Audio fixtures

/// A mono 16 kHz buffer loud enough that the coordinator does not treat it as silence.
private func makeAudibleBuffer(seconds: Double) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000, channels: 1, interleaved: false
    )!
    let frames = Int(16000 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let samples = buffer.floatChannelData![0]
    for i in 0..<frames { samples[i] = i.isMultiple(of: 2) ? 0.1 : -0.1 }
    return buffer
}

private func makeAudibleWAV(at url: URL) throws {
    let buffer = makeAudibleBuffer(seconds: 0.01)
    let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
    try file.write(from: buffer)
}

// MARK: - Mock / Spy Helpers

// MARK: GatedTranscriptionService

/// A transcription service whose calls block until the test lets them go.
/// Like the real decode, a blocked call does not react to task cancellation.
final class GatedTranscriptionService: TranscriptionServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var permits = 0
    private var framesByCall: [Int] = []
    private var finished = 0

    /// The text call number `index` (0-based, in start order) returns.
    var textForCall: (Int) -> String = { _ in "gated text" }
    var isModelLoaded: Bool = false

    /// Calls that have begun, blocked or not.
    var startedCount: Int { lock.withLock { framesByCall.count } }
    /// Calls that have returned.
    var finishedCount: Int { lock.withLock { finished } }

    /// Length, in frames, of the audio handed to call number `index`.
    func framesOfCall(_ index: Int) -> Int? {
        lock.withLock { framesByCall.indices.contains(index) ? framesByCall[index] : nil }
    }

    /// Lets the longest-blocked call return, or the next call if none is blocked.
    func releaseOne() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                permits += 1
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.resume()
    }

    /// Lets every blocked and every future call return.
    func releaseAll() {
        let blocked: [CheckedContinuation<Void, Never>] = lock.withLock {
            permits = Int.max / 2
            defer { waiters = [] }
            return waiters
        }
        blocked.forEach { $0.resume() }
    }

    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult {
        let frames = (try? AVAudioFile(forReading: audioURL)).map { Int($0.length) } ?? -1
        let index: Int = lock.withLock {
            framesByCall.append(frames)
            return framesByCall.count - 1
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let goNow: Bool = lock.withLock {
                if permits > 0 {
                    permits -= 1
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if goNow { continuation.resume() }
        }
        let text = textForCall(index)
        lock.withLock { finished += 1 }
        return TranscriptionResult(text: text, language: .english, durationMs: 0)
    }

    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        try await transcribe(audioURL: audioURL, language: language)
    }

    func preloadModel() async throws {}
    func unloadModel() async {}
}
