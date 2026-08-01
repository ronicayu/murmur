import XCTest
@testable import Murmur

// Regression harness for the silence-gate / hands-free auto-stop subsystem —
// the code that burned eight consecutive releases (v0.4.2–v0.4.10) because
// every fix was verified by hand against a live microphone. These tests drive
// the extracted pure logic (`SilenceGate`, `HandsFreeAutoStopTimer`) with
// scripted inputs, so they are deterministic and run in the LIGHT tier: no
// AVAudioEngine, no microphone, no Silero model load. Real-Silero coverage
// lives in the heavy-gated `VadServiceTests`.
//
// Each `test_regression_vXYZ_*` reproduces a shipped CHANGELOG bug and would
// fail on the pre-fix behaviour.

// MARK: - SilenceGate

final class SilenceGateRegressionTests: XCTestCase {

    private let gate = SilenceGate()

    // v0.4.10 — fast 1-word utterances ("yes", "好", "ok") were silently
    // dropped. Silero needs ~0.25 s to open a segment, so a 150–200 ms word
    // produced zero segments and the gate discarded a real recording.
    // Pre-fix logic (no short-utterance backstop) returned .silence here.
    func test_regression_v0410_shortLoudUtterance_transcribes() {
        let decision = gate.decideVAD(
            hasClosingSegments: false,
            priorSegmentSeen: false,
            duration: 0.18,
            peakDB: -28
        )
        XCTAssertEqual(decision, .transcribe,
            "A short (≤2 s), loud (>-50 dB) clip with no VAD segment must still transcribe (v0.4.10)")
    }

    // The backstop must NOT swallow the genuinely-empty case: a long recording
    // with no segment really is silence.
    func test_longRecording_noSegment_isSilence() {
        let decision = gate.decideVAD(
            hasClosingSegments: false,
            priorSegmentSeen: false,
            duration: 10.0,
            peakDB: -70
        )
        XCTAssertEqual(decision, .silence,
            "A long recording with no VAD segment and a low peak is silence")
    }

    // A short clip that is also quiet (below the speech floor) is silence —
    // the backstop is gated on loudness, not just duration.
    func test_shortButQuiet_isSilence() {
        let decision = gate.decideVAD(
            hasClosingSegments: false,
            priorSegmentSeen: false,
            duration: 0.5,
            peakDB: -60
        )
        XCTAssertEqual(decision, .silence,
            "A short but quiet clip (below -50 dB) is silence, not a missed word")
    }

    // v0.4.7 (second failure mode) — the post-recording gate falsely flagged
    // empty when hands-free was on, because the poller drains segments out of
    // Silero's queue during recording, so `endOfStream()` sees nothing. The
    // fix OR's in `hadAnySpeechSegment` (priorSegmentSeen). Pre-fix returned
    // .silence and deleted a good recording.
    func test_regression_v047_handsFreeDrainedSegments_transcribes() {
        let decision = gate.decideVAD(
            hasClosingSegments: false,   // endOfStream empty — poller drained them
            priorSegmentSeen: true,      // but the poller DID see speech close
            duration: 5.0,
            peakDB: -35
        )
        XCTAssertEqual(decision, .transcribe,
            "Hands-free drains segments during recording; a prior closed segment means it was NOT silent (v0.4.7)")
    }

    func test_vadWithClosingSegments_transcribes() {
        let decision = gate.decideVAD(
            hasClosingSegments: true,
            priorSegmentSeen: false,
            duration: 3.0,
            peakDB: -20
        )
        XCTAssertEqual(decision, .transcribe)
    }

    // No-VAD RMS fallback (cold start before Silero is downloaded).
    func test_rmsFallback_belowFloor_isSilence() {
        XCTAssertEqual(gate.decideRMS(peakDB: -70), .silence,
            "Below the -65 dB fallback floor is silence")
    }

    func test_rmsFallback_aboveFloor_transcribes() {
        XCTAssertEqual(gate.decideRMS(peakDB: -40), .transcribe,
            "Above the -65 dB fallback floor transcribes")
    }
}

// MARK: - HandsFreeAutoStopTimer

final class HandsFreeAutoStopTimerRegressionTests: XCTestCase {

    // v0.4.4 — auto-stop fired internally but never reached the coordinator
    // (an AsyncStream race dropped the event). The event-generation itself is
    // exercised here: once a segment closes and trailing silence elapses, the
    // timer must produce exactly one `.fire`.
    func test_regression_v044_firesAfterTrailingSilence() {
        var timer = HandsFreeAutoStopTimer(trailingSilence: 1.5)

        // A segment closes at t=0.
        XCTAssertEqual(timer.step(now: 0.0, closedSegmentCount: 1, isCurrentlySpeech: false), .wait)
        // Silence continues; not yet elapsed.
        XCTAssertEqual(timer.step(now: 1.0, closedSegmentCount: 0, isCurrentlySpeech: false), .wait)
        // Threshold reached → fire.
        XCTAssertEqual(timer.step(now: 1.5, closedSegmentCount: 0, isCurrentlySpeech: false), .fire)
    }

    // v0.4.7 (first failure mode) — auto-stop fired MID-utterance in some
    // cases. With the segment-close design, while the user is talking again
    // (a new segment is open, isCurrentlySpeech = true) the timer must defer
    // no matter how much wall-clock passes, because the segment hasn't closed.
    func test_regression_v047_doesNotFireMidUtterance() {
        var timer = HandsFreeAutoStopTimer(trailingSilence: 1.0)

        // First segment closes at t=0.
        _ = timer.step(now: 0.0, closedSegmentCount: 1, isCurrentlySpeech: false)
        // User starts talking again well within the window.
        _ = timer.step(now: 0.5, closedSegmentCount: 0, isCurrentlySpeech: true)
        // Long time passes while still speaking — must NOT fire even though
        // way more than 1.0 s has elapsed since the last segment close.
        XCTAssertEqual(timer.step(now: 9.0, closedSegmentCount: 0, isCurrentlySpeech: true), .wait,
            "Timer must not fire while the user is speaking again (v0.4.7)")
        // Even after speech stops, it must not fire until a NEW segment closes.
        XCTAssertEqual(timer.step(now: 9.2, closedSegmentCount: 0, isCurrentlySpeech: false), .wait,
            "After talking resumes, the timer waits for the next segment to close before it can elapse")

        // New segment closes, then real trailing silence → fire.
        _ = timer.step(now: 10.0, closedSegmentCount: 1, isCurrentlySpeech: false)
        XCTAssertEqual(timer.step(now: 11.0, closedSegmentCount: 0, isCurrentlySpeech: false), .fire)
    }

    // A silent start (no speech ever) must never auto-stop — otherwise tapping
    // the hotkey and pausing to think would instantly end the session.
    func test_silentStart_neverFires() {
        var timer = HandsFreeAutoStopTimer(trailingSilence: 1.0)
        for t in stride(from: 0.0, through: 20.0, by: 0.5) {
            XCTAssertEqual(timer.step(now: t, closedSegmentCount: 0, isCurrentlySpeech: false), .wait,
                "No segment has ever closed — must never fire")
        }
    }

    // Long pause mid-sentence: Silero keeps the segment OPEN across a breath
    // (isCurrentlySpeech stays true), so the timer must not fire during the
    // pause. Mirrors the "long pause mid-sentence" fixture.
    func test_betweenWordPause_doesNotFire_untilSegmentCloses() {
        var timer = HandsFreeAutoStopTimer(trailingSilence: 1.0)
        _ = timer.step(now: 0.0, closedSegmentCount: 1, isCurrentlySpeech: false)
        // A breath pause where Silero still considers it one open segment.
        _ = timer.step(now: 0.3, closedSegmentCount: 0, isCurrentlySpeech: true)
        XCTAssertEqual(timer.step(now: 2.0, closedSegmentCount: 0, isCurrentlySpeech: true), .wait)
    }

    // The threshold is respected exactly: fire at/after, wait just before.
    // Covers the trailing-silence slider extremes (1.0 s … 10.0 s).
    func test_trailingSilence_respectsThreshold_shortExtreme() {
        var timer = HandsFreeAutoStopTimer(trailingSilence: 1.0)
        _ = timer.step(now: 0.0, closedSegmentCount: 1, isCurrentlySpeech: false)
        XCTAssertEqual(timer.step(now: 0.99, closedSegmentCount: 0, isCurrentlySpeech: false), .wait)
        XCTAssertEqual(timer.step(now: 1.0, closedSegmentCount: 0, isCurrentlySpeech: false), .fire)
    }

    func test_trailingSilence_respectsThreshold_longExtreme() {
        var timer = HandsFreeAutoStopTimer(trailingSilence: 10.0)
        _ = timer.step(now: 0.0, closedSegmentCount: 1, isCurrentlySpeech: false)
        XCTAssertEqual(timer.step(now: 9.9, closedSegmentCount: 0, isCurrentlySpeech: false), .wait,
            "Must not fire before the 10 s trailing-silence window at the slider's max")
        XCTAssertEqual(timer.step(now: 10.0, closedSegmentCount: 0, isCurrentlySpeech: false), .fire)
    }
}
