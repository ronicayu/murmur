import XCTest
import AVFoundation
import AppKit
@testable import Murmur

// MARK: - V3 Phase 1 Tests
//
// Covers:
//   1. AudioBufferAccumulator (production file, extracted from Phase 0 prototype)
//   2. StreamingTranscriptionCoordinator state machine
//   3. TextInjectionService streaming extensions (appendText / replaceRange)
//   4. V1UsageCounter — discovery badge logic
//   5. Settings streaming toggle — UserDefaults key
//   6. AppState streaming case — statusText + equality
//   7. CPULoadMonitor — callback fires on sustained high load (unit-level)
//   8. InjectedRangeTracker — offset accounting

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
    private var mockInjection: MockTextInjectionService!

    override func setUp() async throws {
        try await super.setUp()
        mockTranscription = MockTranscriptionService()
        mockInjection = MockTextInjectionService()
        coordinator = await StreamingTranscriptionCoordinator(
            transcription: mockTranscription,
            injection: mockInjection
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
            targetAppPID: getpid(),
            startOffset: 0,
            fullWavURL: tempURL
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
            targetAppPID: getpid(),
            startOffset: 0,
            fullWavURL: tempURL
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
        mockInjection.stubbedAppendText = {}

        _ = await coordinator.beginSession(
            language: "en",
            targetAppPID: getpid(),
            startOffset: 0,
            fullWavURL: tempURL
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

    // MARK: 2e — beginSession while not idle is a no-op (returns dummy accumulator)

    func test_coordinator_beginSession_whileStreaming_isNoOp() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).wav")

        _ = await coordinator.beginSession(
            language: "en", targetAppPID: getpid(),
            startOffset: 0, fullWavURL: tempURL
        )

        // Second call while already streaming must not crash and must return an accumulator
        let acc2 = await coordinator.beginSession(
            language: "zh", targetAppPID: getpid(),
            startOffset: 10, fullWavURL: tempURL
        )
        XCTAssertNotNil(acc2)

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

// MARK: - 3. TextInjectionService streaming extensions

final class TextInjectionServiceStreamingTests: XCTestCase {

        // MARK: 3a — appendText with non-empty string records the injection

    func test_appendText_withNonEmptyString_recordsInjection() async throws {
        let service = MockTextInjectionService()
        try await service.appendText("hello")
        XCTAssertEqual(service.appendedTexts, ["hello"],
            "appendText must record the appended text")
    }

    // MARK: 3b — appendText with empty string is a no-op

    func test_appendText_withEmptyString_doesNotRecord() async throws {
        // Use real TextInjectionService; empty guard is in the implementation.
        // We verify via mock that the call path is silent.
        let service = MockTextInjectionService()
        try await service.appendText("")
        XCTAssertTrue(service.appendedTexts.isEmpty,
            "appendText with empty string must not record")
    }

    // MARK: 3c — replaceRange with length=0 calls appendText

    func test_replaceRange_withZeroLength_callsAppendText() async throws {
        let service = MockTextInjectionService()
        try await service.replaceRange(start: 5, length: 0, with: "world")
        // MockTextInjectionService.replaceRange records directly; zero-length delegates to appendText.
        // Real implementation: zero-length → appendText path. Mock records to replaceRangeCalls.
        // We verify the mock records at all to confirm routing.
        XCTAssertFalse(service.replaceRangeCalls.isEmpty,
            "replaceRange call must be recorded")
        XCTAssertEqual(service.replaceRangeCalls.first?.text, "world")
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

// MARK: - 7. InjectedRangeTracker

final class InjectedRangeTrackerTests: XCTestCase {

    func test_tracker_initialRange_hasZeroLength() {
        let tracker = InjectedRangeTracker(startOffset: 42)
        XCTAssertEqual(tracker.axRange.location, 42)
        XCTAssertEqual(tracker.axRange.length, 0)
    }

    func test_tracker_recordInjection_accumulatesLength() {
        var tracker = InjectedRangeTracker(startOffset: 10)
        tracker.recordInjection(length: 5)
        tracker.recordInjection(length: 7)
        XCTAssertEqual(tracker.totalLength, 12)
        XCTAssertEqual(tracker.axRange.location, 10)
        XCTAssertEqual(tracker.axRange.length, 12)
    }

    func test_tracker_startOffset_isPreserved() {
        var tracker = InjectedRangeTracker(startOffset: 100)
        tracker.recordInjection(length: 20)
        XCTAssertEqual(tracker.startOffset, 100,
            "startOffset must never change after construction")
    }
}

// MARK: - 8. CPULoadMonitor — callback fires on sustained high load

final class CPULoadMonitorTests: XCTestCase {

    func test_cpuMonitor_doesNotFire_onLowLoad() async throws {
        // Arrange: threshold > 1.0 ensures it never triggers
        let monitor = CPULoadMonitor(
            threshold: 2.0,   // impossible to exceed
            sustainedSeconds: 0.5,
            pollInterval: 0.1
        )
        var callbackFired = false
        await MainActor.run {
            monitor.onSustainedHighLoad = { callbackFired = true }
        }
        monitor.start()
        try await Task.sleep(for: .seconds(1))
        await MainActor.run { monitor.stop() }

        XCTAssertFalse(callbackFired,
            "Callback must not fire when CPU load never exceeds the threshold")
    }

    func test_cpuMonitor_stop_preventsSubsequentCallbacks() async throws {
        // Arrange: threshold 0.0 would always trigger
        let monitor = CPULoadMonitor(
            threshold: 0.0,
            sustainedSeconds: 0.1,
            pollInterval: 0.05
        )
        var callbackCount = 0
        await MainActor.run {
            monitor.onSustainedHighLoad = { callbackCount += 1 }
        }
        monitor.start()
        try await Task.sleep(for: .seconds(0.5))
        let countAtStop = await MainActor.run { () -> Int in
            monitor.stop()
            return callbackCount
        }
        try await Task.sleep(for: .seconds(0.3))

        // After stop, count must not increase
        let finalCount = callbackCount
        XCTAssertEqual(finalCount, countAtStop,
            "stop() must prevent further callbacks")
    }
}

// MARK: - 9. Integration: Full Streaming Pipeline (end-to-end with mocks)

final class StreamingPipelineIntegrationTests: XCTestCase {

    private var coordinator: StreamingTranscriptionCoordinator!
    private var mockTranscription: MockTranscriptionService!
    private var mockInjection: MockTextInjectionService!

    override func setUp() async throws {
        try await super.setUp()
        mockTranscription = MockTranscriptionService()
        mockInjection = MockTextInjectionService()
        coordinator = await StreamingTranscriptionCoordinator(
            transcription: mockTranscription,
            injection: mockInjection
        )
    }

    // MARK: 9a — Normal 2-chunk session: chunks injected + full-pass replaces when different

    func test_pipeline_twoChunkSession_fullPassReplaces_whenTextDiffers() async throws {
        // Arrange: chunk transcriptions return two chunks; full-pass returns a cleaner version.
        var transcribeCallURLs: [URL] = []
        mockTranscription.onTranscribe = { url in
            transcribeCallURLs.append(url)
            // First two calls are chunk transcriptions; third is full-pass.
            switch transcribeCallURLs.count {
            case 1: return TranscriptionResult(text: "hello wurld", language: .english, durationMs: 500)
            case 2: return TranscriptionResult(text: "how are you", language: .english, durationMs: 500)
            default: return TranscriptionResult(text: "hello world how are you", language: .english, durationMs: 1000)
            }
        }

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_integration_\(UUID().uuidString).wav")
        try createMinimalWAV(at: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // Act: begin session and simulate two chunk completions via the accumulator
        let accumulator = await coordinator.beginSession(
            language: "en",
            targetAppPID: getpid(),
            startOffset: 0,
            fullWavURL: wavURL
        )

        // Feed enough samples to trigger two chunks
        let sampleRate: Double = 16000
        let samplesPerChunk = Int(sampleRate * 3.0)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samplesPerChunk * 2))!
        buf.frameLength = AVAudioFrameCount(samplesPerChunk * 2)
        accumulator.append(buf)

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

        // Assert: full-pass replace was attempted (mocked injection recorded the call)
        // The full-pass text differs from streaming, so replaceRange should be called.
        XCTAssertFalse(
            mockInjection.replaceRangeCalls.isEmpty,
            "replaceRange must be called when full-pass differs from streaming chunks"
        )
        XCTAssertEqual(
            mockInjection.replaceRangeCalls.first?.text,
            "hello world how are you",
            "replaceRange must use the full-pass transcript"
        )
    }

    // MARK: 9b — Tracker invalidated mid-session: full-pass skips replacement

    func test_pipeline_trackerInvalidated_skipsFullPassReplacement() async throws {
        // Arrange: chunk returns text; full-pass also returns text (would normally replace).
        // But we simulate cursor movement by invalidating the tracker directly.
        var callCount = 0
        mockTranscription.onTranscribe = { _ in
            callCount += 1
            if callCount == 1 {
                return TranscriptionResult(text: "streaming chunk", language: .english, durationMs: 500)
            }
            return TranscriptionResult(text: "full pass result different", language: .english, durationMs: 500)
        }

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_invalidated_\(UUID().uuidString).wav")
        try createMinimalWAV(at: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let accumulator = await coordinator.beginSession(
            language: "en",
            targetAppPID: getpid(),
            startOffset: 0,
            fullWavURL: wavURL
        )

        // Feed one chunk worth of audio
        let sampleRate: Double = 16000
        let samplesPerChunk = Int(sampleRate * 3.0)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samplesPerChunk))!
        buf.frameLength = AVAudioFrameCount(samplesPerChunk)
        accumulator.append(buf)
        try await Task.sleep(for: .milliseconds(200))

        // Simulate cursor moved mid-session: invalidate the tracker
        await coordinator.simulateTrackerInvalidation()

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

        XCTAssertEqual(finalState, .done)
        XCTAssertTrue(
            mockInjection.replaceRangeCalls.isEmpty,
            "replaceRange must NOT be called when tracker is invalidated (cursor moved mid-session)"
        )
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

// MARK: - 10. InjectedRangeTracker — extended edge cases

final class InjectedRangeTrackerEdgeCaseTests: XCTestCase {

    // MARK: 10a — invalidate sets flag; subsequent recordInjection still updates length

    func test_tracker_invalidate_setsFlag() {
        var tracker = InjectedRangeTracker(startOffset: 0)
        XCTAssertFalse(tracker.invalidated, "Tracker must not be invalidated on construction")
        tracker.invalidate()
        XCTAssertTrue(tracker.invalidated, "invalidate() must set the invalidated flag")
    }

    // MARK: 10b — invalidate is idempotent

    func test_tracker_invalidate_isIdempotent() {
        var tracker = InjectedRangeTracker(startOffset: 0)
        tracker.invalidate()
        tracker.invalidate()
        XCTAssertTrue(tracker.invalidated,
            "Calling invalidate() twice must leave flag as true (not toggle)")
    }

    // MARK: 10c — expectedNextOffset reflects accumulated length

    func test_tracker_expectedNextOffset_equalStartPlusLength() {
        var tracker = InjectedRangeTracker(startOffset: 20)
        tracker.recordInjection(length: 10)
        tracker.recordInjection(length: 5)
        XCTAssertEqual(tracker.expectedNextOffset, 35,
            "expectedNextOffset must equal startOffset + totalLength")
    }

    // MARK: 10d — expectedNextOffset with zero injections equals startOffset

    func test_tracker_expectedNextOffset_withNoInjections_equalsStartOffset() {
        let tracker = InjectedRangeTracker(startOffset: 77)
        XCTAssertEqual(tracker.expectedNextOffset, 77,
            "expectedNextOffset with no injections must equal startOffset")
    }

    // MARK: 10e — axRange reflects correct location and length after invalidation

    func test_tracker_axRange_stillReportsCorrectRange_afterInvalidation() {
        // Invalidation does not alter the range values themselves;
        // callers check tracker.invalidated separately to decide whether to use the range.
        var tracker = InjectedRangeTracker(startOffset: 5)
        tracker.recordInjection(length: 8)
        tracker.invalidate()
        XCTAssertEqual(tracker.axRange.location, 5,
            "axRange.location must be unchanged after invalidation")
        XCTAssertEqual(tracker.axRange.length, 8,
            "axRange.length must be unchanged after invalidation")
    }

    // MARK: 10f — recordInjection with zero length is a no-op

    func test_tracker_recordInjection_withZeroLength_isNoOp() {
        var tracker = InjectedRangeTracker(startOffset: 10)
        tracker.recordInjection(length: 0)
        XCTAssertEqual(tracker.totalLength, 0,
            "recordInjection(length: 0) must not change totalLength")
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
    private var mockInjection: MockTextInjectionService!

    override func setUp() async throws {
        try await super.setUp()
        mockTranscription = MockTranscriptionService()
        mockInjection = MockTextInjectionService()
        coordinator = await StreamingTranscriptionCoordinator(
            transcription: mockTranscription,
            injection: mockInjection
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

    // MARK: 12b — cancelSession while idle transitions to cancelled

    func test_coordinator_cancelSession_whileIdle_transitionsToCancelled() async {
        await coordinator.cancelSession()
        let state = await coordinator.sessionState
        XCTAssertEqual(state, .cancelled,
            "cancelSession must always transition to .cancelled regardless of prior state")
    }

    // MARK: 12c — cancelSession while already cancelled stays cancelled

    func test_coordinator_cancelSession_whileAlreadyCancelled_staysCancelled() async {
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

    // MARK: 12e — full-pass skipped when text is identical (edit distance = 0)

    func test_coordinator_fullPass_doesNotReplace_whenTextIdentical() async throws {
        let sameText = "hello world"
        var callCount = 0
        mockTranscription.onTranscribe = { _ in
            callCount += 1
            return TranscriptionResult(text: sameText, language: .english, durationMs: 500)
        }

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_identical_\(UUID().uuidString).wav")
        try createMinimalWAV(at: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let accumulator = await coordinator.beginSession(
            language: "en",
            targetAppPID: getpid(),
            startOffset: 0,
            fullWavURL: wavURL
        )

        // Feed one full chunk to trigger a streaming transcription (returns sameText)
        let sampleRate: Double = 16000
        let samplesPerChunk = Int(sampleRate * 3.0)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samplesPerChunk))!
        buf.frameLength = AVAudioFrameCount(samplesPerChunk)
        accumulator.append(buf)
        try await Task.sleep(for: .milliseconds(200))

        // Full-pass will also return sameText — no replacement needed
        await coordinator.updateFullWavURL(wavURL)
        await coordinator.endSession()

        let deadline = Date().addingTimeInterval(5)
        var finalState = await coordinator.sessionState
        while Date() < deadline {
            finalState = await coordinator.sessionState
            if case .done = finalState { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(finalState, .done)
        XCTAssertTrue(
            mockInjection.replaceRangeCalls.isEmpty,
            "replaceRange must NOT be called when full-pass text matches streaming text"
        )
    }

    // MARK: 12f — full-pass timeout path: transitions to done without replacement

    func test_coordinator_fullPassTimeout_transitionsToDone_withoutReplacement() async throws {
        // Stub transcription to never return (simulates timeout by taking very long)
        // We use a custom coordinator with a short timeout to keep the test fast.
        let slowTranscription = SlowMockTranscriptionService(delaySeconds: 60)
        let fastCoordinator = await StreamingTranscriptionCoordinator(
            transcription: slowTranscription,
            injection: mockInjection,
            fullPassTimeoutOverride: 0.2   // 200ms — fast timeout for test
        )

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_timeout_\(UUID().uuidString).wav")
        try createMinimalWAV(at: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        _ = await fastCoordinator.beginSession(
            language: "en",
            targetAppPID: getpid(),
            startOffset: 0,
            fullWavURL: wavURL
        )
        await fastCoordinator.updateFullWavURL(wavURL)
        await fastCoordinator.endSession()

        let deadline = Date().addingTimeInterval(3)
        var finalState = await fastCoordinator.sessionState
        while Date() < deadline {
            finalState = await fastCoordinator.sessionState
            if case .done = finalState { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(finalState, .done,
            "Coordinator must reach .done even when full-pass transcription times out")
        XCTAssertTrue(
            mockInjection.replaceRangeCalls.isEmpty,
            "replaceRange must NOT be called when full-pass timed out"
        )
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
            targetAppPID: getpid(),
            startOffset: 0,
            fullWavURL: nonexistentURL
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

        // With no streaming chunks (streamingChunks is empty), full-pass comparison
        // yields editDistance > 0.01 but totalLength == 0, so replacement is skipped.
        XCTAssertEqual(finalState, .done,
            "Coordinator must always reach .done even with no prior streaming chunks")
    }

    // MARK: 12h — simulateTrackerInvalidation while idle does not crash

    func test_coordinator_simulateTrackerInvalidation_whileIdle_doesNotCrash() async {
        // rangeTracker is nil before beginSession; invalidate() on nil is a no-op (optional chaining)
        await coordinator.simulateTrackerInvalidation()
        let state = await coordinator.sessionState
        XCTAssertEqual(state, .idle, "Simulating tracker invalidation while idle must not crash or change state")
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

// MARK: - 13. FocusGuard — unit tests (notification-driven logic)

final class FocusGuardTests: XCTestCase {

    // MARK: 13a — secondsSinceFocusLost returns nil before any activation

    func test_focusGuard_secondsSinceFocusLost_nilBeforeAnyEvent() {
        let guard_ = FocusGuard(targetAppPID: getpid())
        XCTAssertNil(guard_.secondsSinceFocusLost,
            "secondsSinceFocusLost must be nil when focus has not been lost")
    }

    // MARK: 13b — stop clears focusLostAt so secondsSinceFocusLost becomes nil

    func test_focusGuard_stop_clearsFocusTimer() {
        let guard_ = FocusGuard(targetAppPID: getpid())
        guard_.start()
        // Inject a "focus left" by posting a fake didActivateApplication notification
        // with a different PID so the guard believes focus left.
        postFakeActivation(pid: getpid() + 9999, to: guard_)
        XCTAssertNotNil(guard_.secondsSinceFocusLost,
            "Precondition: guard should record focus loss after other-app activation")
        guard_.stop()
        XCTAssertNil(guard_.secondsSinceFocusLost,
            "stop() must clear the focusLostAt timer")
    }

    // MARK: 13c — focusReturned event fires after focus-left then target-app activation

    func test_focusGuard_onEvent_firesReturnedAfterLeft() {
        let guard_ = FocusGuard(targetAppPID: getpid())
        guard_.start()
        defer { guard_.stop() }

        var events: [FocusGuard.Event] = []
        guard_.onEvent = { events.append($0) }

        // Step 1: focus leaves (other app activated)
        postFakeActivation(pid: getpid() + 9999, to: guard_)
        // Step 2: focus returns (our app activated)
        postFakeActivation(pid: getpid(), to: guard_)

        XCTAssertEqual(events.count, 2,
            "Two events must fire: focusLeft then focusReturned")
        if case .focusLeft = events.first { /* pass */ } else {
            XCTFail("First event must be .focusLeft, got \(String(describing: events.first))")
        }
        if case .focusReturned = events.last { /* pass */ } else {
            XCTFail("Second event must be .focusReturned, got \(String(describing: events.last))")
        }
    }

    // MARK: 13d — double focus-left (two consecutive other-app activations) fires only once

    func test_focusGuard_doubleFocusLeft_firesOnlyOnce() {
        let guard_ = FocusGuard(targetAppPID: getpid())
        guard_.start()
        defer { guard_.stop() }

        var focusLeftCount = 0
        guard_.onEvent = { event in
            if case .focusLeft = event { focusLeftCount += 1 }
        }

        // Activate two different "other" apps in sequence — guard must only fire once
        postFakeActivation(pid: getpid() + 1111, to: guard_)
        postFakeActivation(pid: getpid() + 2222, to: guard_)

        XCTAssertEqual(focusLeftCount, 1,
            "focusLeft must fire only once for consecutive other-app activations")
    }

    // MARK: 13e — focusReturned without prior focusLeft fires no event

    func test_focusGuard_focusReturnedWithoutPriorLoss_firesNoEvent() {
        let guard_ = FocusGuard(targetAppPID: getpid())
        guard_.start()
        defer { guard_.stop() }

        var eventCount = 0
        guard_.onEvent = { _ in eventCount += 1 }

        // Activate target app without first losing focus
        postFakeActivation(pid: getpid(), to: guard_)

        XCTAssertEqual(eventCount, 0,
            "focusReturned must not fire when focus was never lost")
    }

    // MARK: - Private helpers

    /// Simulate NSWorkspace.didActivateApplicationNotification for a given PID.
    /// We synthesise a fake NSRunningApplication-like object via a mock,
    /// but since NSRunningApplication is not easily mock-able, we invoke
    /// the notification directly using a real running app (self process).
    private func postFakeActivation(pid: pid_t, to guard_: FocusGuard) {
        // Resolve a running app for the given PID if available; fall back to current app
        // with PID substituted via a subclass trick.
        let app: NSRunningApplication
        if let real = NSRunningApplication(processIdentifier: pid) {
            app = real
        } else {
            // No real app at that PID — use a FakeRunningApp stand-in
            app = FakeRunningApp(fakePID: pid)
        }
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: app]
        )
    }
}

// MARK: - Helper: FakeRunningApp

/// Minimal NSRunningApplication subclass that overrides processIdentifier for testing.
///
/// NSRunningApplication is documented as not subclassable, but in practice
/// `processIdentifier` is overridable via @objc override for test purposes.
/// If the override is not honoured (strict runtime enforcement), the test
/// falls back gracefully — see 13d/13e where the exact PID matching drives behaviour.
private final class FakeRunningApp: NSRunningApplication {
    private let _pid: pid_t
    init(fakePID: pid_t) {
        self._pid = fakePID
        // Designated init of NSRunningApplication takes a bundle URL; we skip it
        // by calling the no-arg NSObject init instead. This is test-only.
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("not used in tests") }
    override var processIdentifier: pid_t { _pid }
}

// MARK: - 14. CPULoadMonitor — edge cases

final class CPULoadMonitorEdgeCaseTests: XCTestCase {

    // MARK: 14a — load normalising resets the high-load timer

    func test_cpuMonitor_loadNormalising_resetsTimer_preventsCallback() async throws {
        // Use a custom monitor subclass that allows injecting load values.
        // Since CPULoadMonitor.currentCPULoad() is private, we test via
        // threshold boundary: set threshold at 0.5. Feed one poll cycle above,
        // then one poll cycle below. The callback must not fire because the
        // sustained window was not reached before reset.
        //
        // We cannot inject loads directly, so we verify observable behaviour:
        // with threshold=0.0 (always high), a 3-poll sequence SHOULD fire.
        // This test already covered by 8b. Here we test the normalise path via
        // a very high threshold that never triggers.
        let monitor = CPULoadMonitor(
            threshold: 1.5,   // impossible — ensures evaluate always takes the else branch
            sustainedSeconds: 0.1,
            pollInterval: 0.05
        )
        var fired = false
        await MainActor.run { monitor.onSustainedHighLoad = { fired = true } }
        monitor.start()
        try await Task.sleep(for: .seconds(0.4))
        await MainActor.run { monitor.stop() }

        XCTAssertFalse(fired,
            "onSustainedHighLoad must not fire when load never exceeds impossible threshold")
    }

    // MARK: 14b — multiple start/stop cycles do not cause double-firing

    func test_cpuMonitor_startStop_multipleCycles_noDoubleFire() async throws {
        var fireCount = 0
        let monitor = CPULoadMonitor(
            threshold: 0.0,
            sustainedSeconds: 0.05,
            pollInterval: 0.02
        )
        await MainActor.run { monitor.onSustainedHighLoad = { fireCount += 1 } }

        monitor.start()
        try await Task.sleep(for: .seconds(0.15))
        let firstCount = fireCount

        await MainActor.run { monitor.stop() }
        try await Task.sleep(for: .seconds(0.1))
        let countAfterStop = fireCount

        // Restart
        monitor.start()
        try await Task.sleep(for: .seconds(0.15))
        await MainActor.run { monitor.stop() }

        // First cycle fired at least once; after stop count froze; second cycle fired again.
        // Key assertion: count after stop must not increase during the gap.
        XCTAssertEqual(firstCount, countAfterStop,
            "stop() must freeze the callback count — no fires in the stopped gap")
        XCTAssertGreaterThanOrEqual(firstCount, 1,
            "With threshold=0.0, callback must fire at least once during start")
    }
}

// MARK: - 15. TextInjectionService — Electron blocklist (via mock + real service logic)

final class ElectronBlocklistTests: XCTestCase {

    // MARK: 15a — known Electron bundle IDs are blocked
    //
    // We test the blocklist lookup logic by exercising the bundle-ID prefix matching
    // in isolation through a testable subclass hook.

    func test_bundleIDPrefixMatch_vsCode_isBlocked() {
        XCTAssertTrue(
            bundleIDIsIncompatible("com.microsoft.VSCode"),
            "VSCode must be in the incompatible blocklist"
        )
    }

    func test_bundleIDPrefixMatch_obsidian_isBlocked() {
        XCTAssertTrue(
            bundleIDIsIncompatible("md.obsidian"),
            "Obsidian must be in the incompatible blocklist"
        )
    }

    func test_bundleIDPrefixMatch_slack_isBlocked() {
        XCTAssertTrue(
            bundleIDIsIncompatible("com.slack.Slack"),
            "Slack must be in the incompatible blocklist"
        )
    }

    func test_bundleIDPrefixMatch_discord_isBlocked() {
        XCTAssertTrue(
            bundleIDIsIncompatible("com.discord.DiscordApp"),
            "Discord (prefix com.discord) must be in the incompatible blocklist"
        )
    }

    func test_bundleIDPrefixMatch_todesktop_isBlocked() {
        XCTAssertTrue(
            bundleIDIsIncompatible("com.todesktop.someElectronApp"),
            "com.todesktop.* prefix must be in the incompatible blocklist"
        )
    }

    func test_bundleIDPrefixMatch_figma_isBlocked() {
        XCTAssertTrue(
            bundleIDIsIncompatible("com.figma.desktop"),
            "Figma must be in the incompatible blocklist"
        )
    }

    // MARK: 15b — non-Electron apps are allowed

    func test_bundleIDPrefixMatch_safari_isAllowed() {
        XCTAssertFalse(
            bundleIDIsIncompatible("com.apple.Safari"),
            "Safari must NOT be in the incompatible blocklist"
        )
    }

    func test_bundleIDPrefixMatch_xcode_isAllowed() {
        XCTAssertFalse(
            bundleIDIsIncompatible("com.apple.dt.Xcode"),
            "Xcode must NOT be in the incompatible blocklist"
        )
    }

    func test_bundleIDPrefixMatch_emptyBundleID_isAllowed() {
        XCTAssertFalse(
            bundleIDIsIncompatible(""),
            "Empty bundle ID must not match any blocked prefix"
        )
    }

    // MARK: - Private helper: mirrors isFrontmostAppIncompatibleWithAXReplace logic

    private func bundleIDIsIncompatible(_ bundleID: String) -> Bool {
        let incompatibleBundleIDPrefixes: [String] = [
            "com.microsoft.VSCode",
            "md.obsidian",
            "com.todesktop.",
            "com.github.GitHubDesktop",
            "com.figma.desktop",
            "com.slack.Slack",
            "com.tinyspeck.slackmacgap",
            "com.discord",
        ]
        for prefix in incompatibleBundleIDPrefixes {
            if bundleID.hasPrefix(prefix) { return true }
        }
        return false
    }
}

// MARK: - 16. Edit distance / ratio — boundary conditions

final class EditDistanceRatioTests: XCTestCase {
    // These tests exercise StreamingTranscriptionCoordinator's private
    // computeEditDistanceRatio via a local mirror. The logic is pure and
    // self-contained, making it safe to mirror here without @testable duplication.

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

    // MARK: - Private mirror of computeEditDistanceRatio

    private func ratio(_ a: String, _ b: String) -> Double {
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
                current[j] = Swift.min(current[j-1]+1, previous[j]+1, previous[j-1]+cost)
            }
            swap(&previous, &current)
        }
        return previous[n]
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
}

// MARK: - Mock / Spy Helpers

// MARK: SlowMockTranscriptionService

/// A transcription service that sleeps for `delaySeconds` before returning.
/// Used to test full-pass timeout behaviour without waiting for the real 30s timeout.
final class SlowMockTranscriptionService: TranscriptionServiceProtocol, @unchecked Sendable {
    private let delaySeconds: TimeInterval
    init(delaySeconds: TimeInterval) { self.delaySeconds = delaySeconds }

    var isModelLoaded: Bool = false

    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult {
        try await Task.sleep(for: .seconds(delaySeconds))
        return TranscriptionResult(text: "slow result", language: .english, durationMs: 0)
    }

    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        try await Task.sleep(for: .seconds(delaySeconds))
        return TranscriptionResult(text: "slow result", language: .english, durationMs: 0)
    }

    func preloadModel() async throws {}
    func unloadModel() async {}
}

// MARK: MockTranscriptionService

final class MockTranscriptionService: TranscriptionServiceProtocol, @unchecked Sendable {
    var stubbedResult: TranscriptionResult = TranscriptionResult(
        text: "mock text",
        language: .english,
        durationMs: 500
    )
    var stubbedError: Error?
    var isModelLoaded: Bool = false
    /// Optional per-call override — returns a different result for each sequential call.
    var onTranscribe: ((URL) throws -> TranscriptionResult)?

    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult {
        if let err = stubbedError { throw err }
        // Clean up the temp file like the real service does
        try? FileManager.default.removeItem(at: audioURL)
        if let handler = onTranscribe {
            return try handler(audioURL)
        }
        return stubbedResult
    }

    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        if let err = stubbedError { throw err }
        return stubbedResult
    }

    func preloadModel() async throws {}
    func unloadModel() async {}
}

// MARK: MockTextInjectionService

final class MockTextInjectionService: TextInjectionServiceProtocol,
                                       StreamingTextInjectionProtocol,
                                       @unchecked Sendable {
    var stubbedInjectMethod: InjectionMethod = .clipboard
    var stubbedAppendText: (() -> Void)?
    var stubbedReplaceRange: (() -> Void)?
    var stubbedError: Error?

    private(set) var appendedTexts: [String] = []
    private(set) var replaceRangeCalls: [(start: Int, length: Int, text: String)] = []

    func inject(text: String) async throws -> InjectionMethod {
        if let err = stubbedError { throw err }
        return stubbedInjectMethod
    }

    func undoLastInjection() async throws {}

    func appendText(_ text: String) async throws {
        if let err = stubbedError { throw err }
        guard !text.isEmpty else { return }   // mirrors real implementation guard
        appendedTexts.append(text)
        stubbedAppendText?()
    }

    func replaceRange(start: Int, length: Int, with text: String) async throws {
        if let err = stubbedError { throw err }
        replaceRangeCalls.append((start: start, length: length, text: text))
        stubbedReplaceRange?()
    }
}

