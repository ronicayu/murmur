---
from: PM
to: ALL
pri: P2
status: done
created: 2026-04-19
---

## ctx

v0.2.1 shipped (GitHub release re-published at tag `v0.2.1`, HEAD `e8a79fa`).
This handoff closes out the trail:

- FU-01 and FU-04 from `076_PM_ALL_b3-b4-ship-decision.md` are both in
  v0.2.1 and can be marked `SHIP`.
- A sizeable amount of UX polish landed **after** handoff 078 without going
  through the full PM → CR/DA → QA → UT loop. This is the official record of
  what shipped, why the loop was bypassed, and what the audit trail looks
  like for future maintainers or an auditor.

## what shipped in v0.2.1 (final)

Everything from the original v0.2.1 scope (B3, B4, DA blockers C1–C8, FU-04
manifest, race fixes) plus:

### FU-01 (formal — handoff 078 covers EN work + CR LGTM)
- Disabled engine-row caption + tooltip ("Locked during download")
- Cancel-confirm dialog above 100 MB
- "Cancel" → "Cancel Download" copy unified
- `downloadedBytes: Int64` published on ModelManager so the dialog can
  show "You've downloaded N MB — cancelling will discard it"

### UX polish (informal — user-driven, not reviewed)
Commits `f2bdc83`..`7c2f03a` on `fix/fu-01-download-ui-polish`:

| Commit   | What                                                   |
|----------|--------------------------------------------------------|
| f2bdc83  | Audio feedback volume 1.0 → 0.3; success chime moved from .done to .finalizing (later reverted) |
| 279e06f  | Pill for `.undoable` simplified to "Inserted" only (dropped text preview + "⌘Z to undo") |
| ac38e67  | Pill renders errors multi-line, hides after 5 s; every `.error` transition logged via `Self.log.error` |
| 9a133eb  | `MurmurError` gains `Severity` + `shortMessage` + `alertTitle`; critical errors (`modelNotFound`, `diskFull`) route to NSAlert via new `handleError(_:)`; transient errors use short pill |
| c712021  | `startRecording` pre-checks `manifest.json` existence for the active backend; NSAlert fires before wasted audio capture. `NSApp.activate` added so modal shows for the LSUIElement app |
| 420d7c3  | Streaming success chime removed entirely (timing unavoidable gap); default volume dropped to 0.18 |
| fbd2b55  | Stop/cancel sounds removed from all three paths (cancel, V1 stop, V3 stop). Start sound kept — it confirms a system event |
| ba77f1b  | V1 success chime removed — inserted text is visually self-evident |
| 7c2f03a  | Clipboard restore in `TextInjectionService.injectViaClipboard` detached to a background Task so `inject()` returns in ~50 ms instead of 1500 ms; closes the V1 pill-lag gap between text appearing and "Inserted" showing |

### Why the loop was bypassed

Real-time user testing session:
- User installed the build, hit issues, reported them in Chinese/English conversationally.
- Each fix was <50 LOC, isolated to a single file or two, and validated by
  the user immediately on the next reinstall.
- Loop-style handoffs would have added hours of latency per iteration; the
  cost/benefit flipped for UX-polish scope.
- Risk accepted: these changes did not get DA challenge or QA coverage.
  None added new control-flow paths that could cause the kinds of bugs DA
  caught in the B3/B4 rounds. The biggest risk item — the `handleError`
  refactor collapsing five catch blocks — was covered by manual testing of
  each error path on the installed build.

### CI recovery trail

Release run for v0.2.1 failed once (`24630584919`) on strict-concurrency
errors in the newly-added `NSLock + var alreadyResumed` pattern.
Fixed with a `ResumeGuard` reference type (`d25af59`), tag moved, CI re-ran
green on `24631008506`. After the UX polish merge, tag was moved a
**third** time (to `e8a79fa`) and CI run `24632306754` published the final
DMG.

## backlog status from handoff 076

| ID | Title | Status after v0.2.1 |
|---|---|---|
| FU-01 | Download-UI polish (caption + cancel confirm + copy) | **SHIP** |
| FU-02 | ETA + human-readable byte counts in progress | open, P2 |
| FU-03 | Subprocess-lifecycle integration test suite (C6/H4/H7/H9) | open, P1 |
| FU-04 | Per-backend manifest verification (H5 fix) | **SHIP** |
| FU-05 | Backend-aware guard in cleanup Task | open, P2 |
| FU-06 | Surface setActiveBackend refusal in UI | open, P3 |
| FU-07 | Download stall timeout | open, P2 |
| FU-08 | Migrate cancel to kqueue EVFILT_PROC | open, P3 |

### New items surfaced during this cycle

| ID | Title | Pri | Notes |
|---|---|---|---|
| FU-09 | Bump `actions/checkout@v4` + `softprops/action-gh-release@v2` to Node-24-compatible versions | P3 | CI deprecation; Node 20 removed Sept 2026 |
| FU-10 | 11 pre-existing test failures in `V3AXSelectReplaceTests` + streaming integration tests | P2 | Flaky or environmental; document or fix |
| FU-11 | Info.plist `CFBundleShortVersionString` source-of-truth (pre-release was stuck at 0.1.0) | P3 | CI overrides from tag, but local builds were confusing |
| FU-12 | V3 streaming coordinator swallows transcription errors in `processChunkBuffer` + full-pass; no way for upstream to see real failures | P1 | Surfaced while diagnosing "no NSAlert" complaint; pre-check worked around it but the underlying silent-swallow is a correctness gap |

## ask

(None — this is a closeout record.) If any reviewer wants to retro-review the
UX-polish commits listed above, they can do so at leisure against the merged
main. Findings belong in new handoffs.

## refs

- `076_PM_ALL_b3-b4-ship-decision.md` — original ship decision + backlog
- `077_EN_ALL_fu04-and-race-fix.md` — FU-04 + termination-race implementation
- `078_EN_CR_fu-01-ui-polish.md` — FU-01 EN summary for CR
- `CHANGELOG.md` § 0.2.1 — user-facing copy
- GitHub release https://github.com/ronicayu/murmur/releases/tag/v0.2.1

## out

Closing — v0.2.1 is officially wrapped. Next session starts fresh against
the FU-02 / FU-03 / FU-12 backlog.
