---
from: EN
to: ALL
pri: P2
status: SHIP
created: 2026-07-30
refs: 095, 096, 104, docs/plans/2026-07-30-10x-plan.md
---

## ctx

Closing note for the 10x plan's **Phase 0 (foundation)**. All handoffs through
104 are shipped or superseded; this note supersedes the open threads rather
than re-litigating them individually.

## done (Phase 0)

- **0.1 CI gate.** `.github/workflows/ci.yml` runs `swift build` + light-tier
  `swift test` on every PR and push to `main`. Model-loading (heavy) tests are
  isolated in `.github/workflows/heavy-tests.yml`, `workflow_dispatch`-only —
  they can never run implicitly, and never on the dev Mac mini (RAM-limited;
  heavy tests have crashed it — see `TestHeavyGate.swift`).
- **0.1b Deterministic suite.** Timing-race tests (`CPULoadMonitor`,
  `TranscriptionWindowModel` m4a/cancel paths) rewritten to await the actual
  work (`TranscriptionWindowModel.transcriptionTask` is now test-visible) or to
  poll a condition (`pollUntil`) instead of a fixed sleep. Green under load.
- **0.2 Silence-gate / hands-free regression harness.** The logic behind the
  eight v0.4.2–v0.4.10 fires is extracted into pure, unit-tested units —
  `SilenceGate` and `HandsFreeAutoStopTimer` — driven with scripted timings
  (fake VAD, light tier, no Silero). Each shipped bug in the class has a named
  regression test in `AudioGateRegressionTests.swift`. `AudioService` now calls
  into these instead of holding the logic inline.
- **0.3 Dead code deleted.** Removed the Python transcription subprocess bridge
  (`TranscriptionService.swift` + `Resources/transcribe.py`) and, in doing so,
  fixed a **live bug**: under the FireRed backend, non-zh/en audio routed to a
  subprocess pointed at a sherpa model it could not load. `AppCoordinator`'s
  default transcription service is now always the in-process Cohere ONNX engine,
  so the `.cohereONNX` fallback works. Also removed the orphaned
  `AuxiliaryModel.lidWhisperTiny`, the always-nil `AppCoordinator.lid` slot,
  and `PunctuationCleanupService` (its Settings UI was removed in v0.4.9 and its
  `cleanupTranscription` key is unreachable, so the pipeline step was a no-op).
- **0.4 Docs truth pass.** `CLAUDE.md` status (was "v0.2.0"), README
  (architecture no longer claims a Python IPC fallback; hands-free + VAD now
  documented; stale test count fixed), and `docs/ux/flows.md` (hotkey was
  "Option+Space", shipped hotkey is Right Command).

## open (for Ronica — carried in the plan)

- **Repo license** — README still says TBD. Blocks a public v1.0. Not guessed.
- **SenseVoice ModelScope terms** — blocks Phase 2 wiring; research + decision
  pending (see plan §Phase 2).

## next

Phase 1: land the `fix/streaming-stable-prefix` WIP (stable-prefix streaming).
