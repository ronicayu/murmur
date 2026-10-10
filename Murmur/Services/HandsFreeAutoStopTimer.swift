import Foundation

/// Pure state machine for hands-free auto-stop, extracted out of
/// `AudioService.runHandsFreeAutoStop` so the "when do we stop" decision can be
/// tested with scripted segment timings instead of a live microphone, a real
/// Silero model, and wall-clock sleeps.
///
/// The async polling loop in `AudioService` stays thin: each tick it pops the
/// VAD's closed segments, reads the live speech flag, and feeds them here with
/// a monotonic timestamp. This type decides whether to keep waiting or fire.
///
/// Behaviour mirrors the v0.4.7 segment-close design and its rationale:
///   - Anchor the trailing-silence timer to the timestamp of the most recent
///     segment that *Silero itself* declared closed (which already required
///     `minSilenceDuration` of low-probability frames). This is robust to
///     between-word pauses — the segment is still open during them.
///   - Never fire before at least one segment has closed, so a silent start
///     doesn't auto-stop instantly.
///   - Defer while the live frame is speech: the user is talking again, so the
///     timer waits for that segment to close before it can elapse.
struct HandsFreeAutoStopTimer {
    /// Seconds of trailing silence (since the last segment close) after which
    /// auto-stop fires.
    let trailingSilence: TimeInterval

    private var sawAnySegment = false
    private var lastSegmentEndTime: TimeInterval?

    init(trailingSilence: TimeInterval) {
        self.trailingSilence = trailingSilence
    }

    enum Tick: Equatable {
        case wait
        case fire
    }

    /// Advance the timer by one poll.
    ///
    /// - Parameters:
    ///   - now: a monotonic timestamp in seconds (any consistent clock; only
    ///     differences matter). Tests pass synthetic values.
    ///   - closedSegmentCount: number of segments Silero closed since the last
    ///     tick (`vad.popSegments().count`).
    ///   - isCurrentlySpeech: Silero's live speech flag (`vad.isCurrentlySpeech`).
    /// - Returns: `.fire` when auto-stop should trigger, otherwise `.wait`.
    mutating func step(
        now: TimeInterval,
        closedSegmentCount: Int,
        isCurrentlySpeech: Bool
    ) -> Tick {
        if closedSegmentCount > 0 {
            // A segment just closed — (re)anchor the trailing-silence timer to
            // this instant. Don't also evaluate firing on the same tick.
            sawAnySegment = true
            lastSegmentEndTime = now
            return .wait
        }

        guard sawAnySegment, let lastEnd = lastSegmentEndTime else {
            // Nothing has closed yet (silent start), or the timer is deferred
            // pending the current segment closing.
            return .wait
        }

        if isCurrentlySpeech {
            // The user is talking again; defer until this segment closes.
            lastSegmentEndTime = nil
            return .wait
        }

        return (now - lastEnd) >= trailingSilence ? .fire : .wait
    }
}
