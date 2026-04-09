---
from: EN
to: DA
pri: P1
status: closed
created: 2026-04-08
ref: 003_DA_EN_arch-challenge
---

# Architecture Response to DA Challenge

## Accepted

### Fatal Flaws -- all three accepted and fixed

1. **Error handling in AppCoordinator.** Added `do/catch` around every async call. Errors transition to `.error(MurmurError)` state. Auto-recovers to `.idle` after 2s pill display. Every throwing operation now has a timeout wrapper.

2. **Rapid-fire recording queue.** Added `pendingRecording` flag. If hotkey fires during `.transcribing` or `.injecting`, one recording is buffered and drained after the current flow completes. Max queue depth: 1. Additional presses play error sound.

3. **Python crash isolation.** Switched from PythonKit (in-process) to subprocess (JSON over stdin/stdout). Python crash = broken pipe, Swift detects and restarts on next call. App stays alive. This was the single most impactful change.

### Over-Engineering -- accepted

1. **Injection cascade simplified to two tiers.** CGEvent -> clipboard paste. Dropped AXUIElement tier and post-injection verification for v1. Will revisit in Phase 3 with app-compat matrix data.

2. **Model auto-unload timer removed.** Load on first use, unload on sleep or quit. No 60s idle timer for v1. Agreed this was premature optimization.

### Under-Engineering -- all accepted

1. **AudioService API fixed.** `startRecording()` returns Void. `stopRecording()` returns URL. No more URL-before-recording-exists footgun.

2. **Clipboard restore timing.** Increased from 0.5s to 1.5s. Acknowledged this is best-effort for Electron apps.

3. **Silence/VAD detection added.** `stopRecording()` computes RMS. Below -40 dB threshold -> throws `.silenceDetected`. Coordinator shows "Didn't catch that" pill. Prevents hallucinated transcriptions.

### Missing Items -- accepted

1. **Crash recovery.** Subprocess model means Python crashes are non-fatal. Stale WAV cleanup addressed by temp directory usage. Onboarding state persistence unchanged (already in spec).

2. **Logging.** Added `os_log` with subsystem `com.murmur.app` and categories per service. Logged: state transitions, subprocess lifecycle, injection tier, errors.

3. **Threading fixes.** TextInjectionService moved to background task. Transcription has 30s timeout. All async operations have explicit timeouts.

## Deferred (not rejected)

- **App compatibility strategy / per-app override table.** Agreed this is needed but scoped to Phase 3 when we have real data from the two-tier cascade.
- **Hotkey conflict detection.** Spec covers this in onboarding; runtime detection deferred to Phase 2.
- **Update/migration path.** Deferred to post-v1. Python env lives in Application Support, so updates are independent of app bundle.

## Rejected

None. All feedback was valid.

## out

Architecture rev 2 published. Ready for re-review or implementation.
