---
from: PM
to: DA
pri: P1
status: done
created: 2026-04-08
---

## ctx

DA challenged the Murmur v1 spec (handoff 001). This is PM's response after revising the spec. The user has also made a key decision: runtime is Cohere Transcribe via PythonKit (embedded Python). That question is closed.

## ask

No action required from DA. This is a response handoff. DA's next review opportunity is after UX updates flows to match the revised spec.

## constraints

N/A (informational handoff).

## refs

- `docs/specs/murmur-v1.md` (revised spec, rev 2)
- `docs/handoffs/001_DA_PM_spec-challenge.md` (DA's challenge)
- `docs/ux/flows.md` (UX flows, to be updated by UX)

## out

### Accepted

1. **Phase 0 validation spike.** Added as a formal phase before any development. Covers latency benchmarking, RAM measurement, license check, and PythonKit feasibility. Clear exit criteria defined.

2. **Text injection strategy matrix.** Replaced the vague "test top 20 apps" mitigation with a concrete three-tier fallback: CGEvent > AXUIElement > clipboard. CGEvent is now the default (supports undo). Verification step after each injection attempt.

3. **Toggle mode as default.** Hold-to-talk is demoted to a setting. Toggle is the default. DA was right: hold is painful for dictation.

4. **Hotkey changed to Ctrl+Space.** Option+Space had too many conflicts (Spotlight, Alfred, Raycast, non-breaking space). Ctrl+Space is the new default. Added conflict detection for CJK input source switching during onboarding.

5. **Spec/UX contradictions resolved.** Made definitive decisions on: hotkey (Ctrl+Space), mode (toggle default), language selection (auto-only, no manual override in v1), settings scope (explicitly listed what's in/out), launch-at-login (ON by default, in v1).

6. **Missing edge cases added.** Long recordings (120s cap, stream to disk), sleep/wake handling, disk space checks, permission revocation detection on every use, app switching behavior, concurrent audio, multiple displays, rapid-fire usage queueing.

7. **Undo mechanism.** Cmd+Z works after injection because CGEvent keystroke simulation (the new default injection method) registers with the target app's undo stack.

8. **16 GB RAM minimum.** 8 GB Macs are explicitly unsupported in v1. Added a System Requirements table. 8 GB support deferred to v2 with a quantized model.

9. **Hotkey practice in onboarding.** Added a sub-step after the test transcription where the user practices the actual hotkey, not just the in-app button.

10. **Disk space check before download.** Added as an onboarding step. Also checks before recording (< 500 MB = refuse).

### Rejected

1. **Small model for instant onboarding.** Good idea in theory, but adds significant complexity to v1: two model management paths, model switching logic, accuracy expectations mismatch. Deferred to v2. The onboarding friction is real but manageable with resumable downloads and parallel permission/download steps.

2. **"Cohere Transcribe doesn't exist" concern.** The user has confirmed the runtime choice. Phase 0 validates that it works in practice. If Phase 0 fails, we pivot. This is not an open question anymore.

### Deferred

1. **Quantized model for 8 GB Macs.** v2.
2. **Small bundled model for instant first-use.** v2.
3. **Model versioning/update strategy.** Not needed until Cohere ships a new model version. Will address when relevant.
4. **Telemetry beyond UserDefaults counters.** v1 metrics are developer-only (read from UserDefaults on the dev's own machine). Queryable telemetry is a v2 concern if we ever have users beyond ourselves.
5. **Crash recovery watchdog.** Added as an open question for EN to design. Not specced in detail because the right approach depends on Phase 0 findings (how PythonKit processes are managed).
