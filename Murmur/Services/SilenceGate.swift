import Foundation

/// Pure decision for the post-recording silence gate: given what the VAD (or
/// the RMS fallback) observed, decide whether to transcribe the recording or
/// discard it as silence.
///
/// Extracted out of `AudioService.stopRecording` so the gate can be tested
/// exhaustively without an `AVAudioEngine`, a microphone, or a loaded Silero
/// model. `AudioService` gathers the inputs (VAD segments, the
/// `hadAnySpeechSegment` bookkeeping flag, recording duration, peak dB) and
/// calls into here; this type holds no state and does no I/O.
///
/// The thresholds are the ones that shipped through the v0.4.x fixes; changing
/// them is a behavioural change and should come with a new regression test.
struct SilenceGate {
    /// Recordings at or under this length qualify for the short-utterance
    /// backstop (v0.4.10). Silero needs ~0.25 s of sustained speech to *open*
    /// a segment, so a 150–200 ms word ("yes" / "好" / "ok") can produce zero
    /// segments even though there is clearly a word in the clip.
    var shortUtteranceMaxDuration: TimeInterval = 2.0
    /// Peak level (dB) at or above which a short clip is treated as real
    /// speech worth transcribing. Whisper-level speech peaks above this.
    var speechFloorDB: Float = -50
    /// Peak floor for the no-VAD RMS fallback path (cold start before Silero
    /// is downloaded). Below this is "mic muted / wrong device / stray hotkey."
    var rmsFallbackFloorDB: Float = -65

    enum Decision: Equatable {
        /// Keep the recording and send it to transcription.
        case transcribe
        /// Discard as silence; the WAV is deleted and `silenceDetected` thrown.
        case silence
    }

    /// VAD-active decision.
    ///
    /// - Parameters:
    ///   - hasClosingSegments: `endOfStream()` returned at least one segment.
    ///   - priorSegmentSeen: the hands-free poller popped a closed segment
    ///     earlier this recording (`AudioService.hadAnySpeechSegment`). This is
    ///     the v0.4.7 fix: the poller drains segments out of Silero's queue
    ///     during recording, so an empty `endOfStream()` does not mean the
    ///     recording was silent.
    ///   - duration: recording length in seconds.
    ///   - peakDB: peak RMS in dB over the recording.
    func decideVAD(
        hasClosingSegments: Bool,
        priorSegmentSeen: Bool,
        duration: TimeInterval,
        peakDB: Float
    ) -> Decision {
        if hasClosingSegments || priorSegmentSeen {
            return .transcribe
        }
        // No VAD segment anywhere. Apply the short-utterance backstop before
        // giving up: a short, loud clip is almost certainly a fast single word
        // that flew under Silero's open-threshold.
        if duration <= shortUtteranceMaxDuration && peakDB > speechFloorDB {
            return .transcribe
        }
        return .silence
    }

    /// No-VAD RMS fallback decision (used before the Silero model exists).
    func decideRMS(peakDB: Float) -> Decision {
        peakDB < rmsFallbackFloorDB ? .silence : .transcribe
    }
}
