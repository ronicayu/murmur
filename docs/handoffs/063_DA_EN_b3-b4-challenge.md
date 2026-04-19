---
from: DA
to: EN
pri: P1
status: open
created: 2026-04-19
---

## ctx
Re-challenge of the B3/B4 fixes after EN's round-2 response to handoff 060/061.
Prior DA pass produced C1, C2, H3, H1. EN addressed all four. This pass looks at
the code actually on `fix/b3-b4-download-ui-bugs` (HEAD = 1fc6cbd) and focuses on
residual failure modes in the revert guard, the `.disabled` row lock, the
positive-assertion `isModelDownloaded`, the Combine sink, and the unrelated
silence-threshold change that got bundled into commit 1fc6cbd.

## ask
1. Read findings below, confirm or refute each with a code citation.
2. Fix CRITICAL items on this branch before CR re-approves. HIGH items require a
   written response (fix or justified defer). MEDIUM/NIT at EN's discretion.
3. AudioService `-60 → -45 dB` change: either pull it off this branch or get
   explicit PM sign-off. It is not in B3/B4 scope and rides commit 1fc6cbd
   without its own review.

## constraints
- No scope creep. If a fix is big, defer it and write a follow-up handoff.
- Keep the C1 revert approach unless EN finds the reentrancy below unfixable;
  cancel-and-switch is still not acceptable per handoff 061.

## refs
- `Murmur/Services/ModelManager.swift:136-158` — `activeBackend.didSet`, `isDownloadActive`
- `Murmur/Services/ModelManager.swift:192-206` — `isModelDownloaded(for:)`
- `Murmur/Services/ModelManager.swift:419-433` — `cancelDownload()`
- `Murmur/Onboarding/OnboardingViewModel.swift:52-56` — Combine sink
- `Murmur/Views/SettingsView.swift:305-340` — `engineRow` + `.disabled`
- `Murmur/MurmurApp.swift:56-62` — `.onReceive(modelManager.$activeBackend)`
- `Murmur/AppCoordinator.swift:91-95` — `replaceTranscriptionService`
- `Murmur/Services/AudioService.swift:185-193` — silence threshold
- Prior: `060_EN_CR_b3-b4-download-ui-bugs.md`, `061_EN_CR_b3-b4-da-blockers.md`

## out

### C3 — CRITICAL: `@Published` + didSet revert fires 3 publishes; `.onReceive($activeBackend)` tears down the live transcription service mid-download

**Where:** `ModelManager.swift:136-149` (the revert) combined with
`MurmurApp.swift:56-62` (`.onReceive(modelManager.$activeBackend)` calling
`coordinator.replaceTranscriptionService`), which internally runs
`Task { await transcription.killProcess() }` (AppCoordinator.swift:91-95).

**Failure mode.** `@Published` publishes in willSet, not didSet. When the user
clicks a locked engine row (e.g., Whisper while ONNX is downloading), the
sequence is:

1. User assigns `activeBackend = .whisper`.
2. `@Published` willSet: sends `.whisper` to the `$activeBackend` publisher →
   `MurmurApp.onReceive` fires → `replaceTranscriptionService` kicks off
   `killProcess()` on the *currently downloading* transcription service.
3. Stored value becomes `.whisper`; didSet runs; sees `isDownloadActive == true`;
   assigns `activeBackend = oldValue` (`.onnx`).
4. That assignment is a second `@Published` publish: willSet sends `.onnx` →
   `onReceive` fires again → another `replaceTranscriptionService` →
   another `killProcess()`.

So a blocked click silently kills and rebuilds the transcription service twice
while a download is running. For ONNX that's `NativeTranscriptionService`; for
Python backends it's the `transcribe.py` subprocess (`killProcess()` ends the
running worker). This likely corrupts the in-flight download's finalization
path (`verify()` reads files the killed process may have been mid-write to) or
at minimum races with `download()`'s `monitorTask`.

**Repro.**
- Start an ONNX download (or simulate via test seam — see C4).
- While `state == .downloading` or `.verifying`, set
  `modelManager.activeBackend = .whisper`.
- Log: observe two `replaceTranscriptionService` calls and two `killProcess()`
  invocations. In the real UI, the SettingsView `.disabled` guard (C2) should
  prevent this click — but the OnboardingView's `backendCard` at
  `OnboardingView.swift:524-528` has no equivalent disable, and the didSet
  guard is supposed to be the authoritative lock anyway. Programmatic callers
  (`OnboardingViewModel.nextStep()` at `OnboardingViewModel.swift:72` and
  `selectBackend` at line 88) bypass any UI disable.

**What EN should do.**
- Either (a) move the publish-side side effect out of
  `.onReceive(modelManager.$activeBackend)` into a method that's only called
  *after* the didSet guard has accepted the change (e.g., emit a separate
  `backendSwitched` Publisher from inside the didSet's accept branch), or
  (b) make `replaceTranscriptionService` a no-op when
  `modelManager.isDownloadActive == true`. Option (a) is cleaner.
- Add a regression test: assigning `activeBackend = .whisper` while mock-state
  is `.downloading` must result in zero calls to `replaceTranscriptionService`
  (the coordinator's `transcription` reference must not change at all).

### C4 — CRITICAL: `isDownloadActive` is never true in any unit test; the guard has no direct test coverage

**Where:** `ModelManager.swift:136-158` and `Tests/B3B4FixTests.swift:178-283`.

**Failure mode.** `state` is `@Published private(set)`. Only `download()`,
`verify()`, `cancelDownload()`, `delete()`, and `refreshState()` can write it.
None of them can be put into `.downloading` or `.verifying` without actually
invoking the full Python subprocess path or `verify()`'s file check. The test
file explicitly notes this at lines 183-186 and punts to a future seam (handoff
062). So the C1 behaviour — "refuse switch while downloading" — is *literally
untested*. Handoff 061 claims LGTM-ready, but there is no evidence the guard
fires on the real branch. A single off-by-one in the switch statement of
`isDownloadActive` (or a future refactor that drops `.verifying`) would ship
silently.

**Repro.**
- Run the `ActiveBackendDidSetGuardTests` suite and grep for a test that actually
  asserts `manager.activeBackend` was reverted. There isn't one.

**What EN should do.**
- Before CR signs off, add a minimal `#if DEBUG` test seam:
  `func _forceState(_ s: ModelState)` (or expose `state` as internal-set under
  `@testable import`). Write three tests:
  1. `state = .downloading` → assign `activeBackend = .whisper` → assert
     `activeBackend == .onnx` (revert happened).
  2. `state = .verifying` → same assertion.
  3. `state = .downloading` → assert that `objectWillChange` fires zero or one
     times (whichever is correct) for the rejected assignment, and that no
     side effect observer sees `.whisper` as the committed value. This also
     covers C3.
- Yes, this expands beyond B3/B4 scope, but handoff 061's "LGTM if no DA
  findings" cannot stand while a CRITICAL-class guard is untested on this
  branch.

### H4 — HIGH: `cancelDownload()` sets `state = .notDownloaded` but leaves `downloadTask` nil; the Python process is *not* terminated

**Where:** `ModelManager.swift:161` (declares `downloadTask`, never assigned)
and `:419-433` (`cancelDownload()` calls `downloadTask?.cancel()` against nil).

**Failure mode.** `cancelDownload()` is a lie. The stored property
`downloadTask` is declared but `download()` never assigns anything to it
(grep confirms: only write site is `downloadTask = nil` inside `cancelDownload`).
So pressing "Cancel Download" in Settings:

1. Sets `state = .notDownloaded` synchronously.
2. `isDownloadActive` returns false.
3. The Python `snapshot_download` process is still running in the background.
4. The user (or the didSet guard, now unlocked) switches to another backend.
5. The zombie process continues writing to `Murmur/Models-ONNX/` even after the
   user has "cancelled" and picked `.whisper`.

The revert guard's safety argument ("Cancel button in Settings continues to
work because `cancelDownload()` sets `state = .notDownloaded` synchronously
before any UI calls `activeBackend =`, so `isDownloadActive` is already
false" — handoff 061:25-26) relies on cancel actually stopping the download.
It doesn't. Handoff 060:68 marks M3 "cancelDownload() doesn't await subprocess
termination" as *deferred* — but this is worse than "doesn't await"; it
doesn't *attempt* to terminate at all.

**Repro.**
- Start a download. Click Cancel. Run `ps aux | grep snapshot_download`.
  Process is still alive. Files continue to grow in the model dir.
- Alternatively: start an HF download (requires token), click Cancel, switch to
  Whisper, then call `download()`. Two Python processes run in parallel; one
  writes to `Models-Whisper/`, one still writes to `Models/`. `verify()` on
  Whisper can race against the zombie writing to `Models/` (which is harmless
  for Whisper but wastes bandwidth/disk).

**What EN should do.**
- Minimum: store the `Process` created at `ModelManager.swift:310` in a
  property, and call `.terminate()` (or `.interrupt()`) from `cancelDownload()`.
- This is *on scope* for this branch because it's the load-bearing assumption
  of C1. Don't defer this to a future handoff while shipping C1 as "LGTM".

### H5 — HIGH: `isModelDownloaded(for:)` is asymmetric — inactive backends with corrupt/partial files show as "Downloaded"

**Where:** `ModelManager.swift:192-206`.

**Failure mode.** The active branch correctly returns false for `.corrupt`,
`.error`, partial `.downloading`. The inactive branch (line 205) returns
`modelPath(for: backend) != nil`, where `modelPath(for:)` only checks that
every `requiredFiles` entry exists — not that they're complete, non-zero, or
hash-verified. Consequence: if the user downloaded Whisper, it corrupted, they
switched to ONNX, the SettingsView engine row still shows Whisper as "Downloaded"
in green. When they click Whisper, activeBackend switches, refreshState() re-
evaluates via `modelPath != nil` (same file-existence check), sets state to
`.ready`, and the preload path in MurmurApp (`$state` onReceive) fires
`preloadModelInBackground()` against corrupt files. The native ONNX runtime
or transcribe.py will then fail at inference time, not at switch time — far
from the error origin. Bad UX, bad telemetry.

Handoff 060/061 explicitly deferred this as "H2 inactive-backend partial
detection — pre-existing larger work." DA agreed to defer at the time. The
re-challenge is: **given that C1 / C2 / H3 all converged on "make the active
backend's status the source of truth," shipping with the inactive backend
still lying is a visible UX regression risk**, because the "Downloaded" green
label in the Advanced disclosure group is the main signal users have to pick a
backend. At a minimum, file this as an EN-tracked ticket before merge, not a
defer-forever.

**Repro.**
- With ONNX active and fully downloaded, manually `touch` the three required
  files in `~/Library/Application Support/Murmur/Models-Whisper/` (create
  empty files).
- Open Settings → Model → Advanced. Whisper row shows "Downloaded" in green.
- Click Whisper. Crash/error on next transcription.

**What EN should do.**
- Short-term (this branch): demote the "Downloaded" label to "Installed"
  for inactive backends, or show a tentative check (e.g., size-based:
  `directorySize >= 0.8 * requiredDiskSpace`). Cheap heuristic, honest enough.
- Long-term: store per-backend config hash and file-size manifest at verify
  time, check against that for inactive backends.

### H6 — HIGH: Combine sink `.receive(on: .main)` introduces an async hop that defeats willSet semantics for SwiftUI

**Where:** `OnboardingViewModel.swift:52-56`.

**Failure mode.** `.receive(on: DispatchQueue.main)` schedules the downstream
sink on the next main-queue tick, even when the upstream already fires on main
(which ModelManager does, being `@MainActor`). Effect:

1. ModelManager's `objectWillChange` fires synchronously in willSet.
2. SwiftUI's own subscription on ModelManager re-renders views observing
   ModelManager directly (SettingsView via `@ObservedObject`) *this* runloop
   tick.
3. The hopped sink in OnboardingViewModel fires on the *next* runloop tick,
   then calls `self.objectWillChange.send()`.
4. SwiftUI re-renders OnboardingView one tick later than SettingsView.

In onboarding alone this is usually invisible, but during rapid state churn
(e.g., download-speed updates every 1s plus status-message changes) the
OnboardingView lags ModelManager's actual state by one runloop. More severe:
SwiftUI's diffing algorithm may read `modelManager.state` during its render
pass *after* objectWillChange fired but before the stored value changed,
producing a one-frame flash of the stale value. This is the exact bug H1 was
supposed to *prevent*, not introduce.

Handoff 061:39-41 rationalizes `.receive(on: .main)` as "defensive for future
actor changes." That's backwards — if ModelManager moves off the main actor,
you want the sink on a matching actor (e.g., via `MainActor.run`), not a
runloop hop. The current code is the worst of both worlds: no extra safety
today, a guaranteed async delay today.

**Repro.**
- Hard to see directly; would need a counter of runloop iterations between
  `ModelManager.state` change and OnboardingView render. Easier signal:
  during a 60s download with per-second progress updates, observe that the
  OnboardingView progress bar trails the SettingsView progress bar by ~16ms
  (one frame).

**What EN should do.**
- Drop `.receive(on: DispatchQueue.main)`. ModelManager is `@MainActor`;
  Combine will deliver on the publishing context and SwiftUI expects
  synchronous willSet propagation. If main-thread safety ever becomes in
  doubt, assert it in the sink with `dispatchPrecondition(condition:
  .onQueue(.main))` — that's a real defense, not a disguised latency.

### M1 — MEDIUM: The `.disabled` lock has no recovery path if the download hangs in `.verifying`

**Where:** `SettingsView.swift:339` and `ModelManager.swift:435-474` (`verify()`).

**Failure mode.** `verify()` is an async function that sets `state = .verifying`
on entry and `.ready` (or `.corrupt`) on exit. If it throws (e.g., the
SHA-256 read of config.json fails because the file was half-written when HF's
atomic-rename didn't fully land), `state` is left at `.verifying` because the
error propagates *before* the state is reset. There is no catch-all that
resets `state` on `verify()` throw. Consequence:

1. `state` stuck at `.verifying`.
2. `isDownloadActive` returns true forever.
3. Every engine row is disabled forever (except the active one).
4. Cancel button is gone (the button branch at `SettingsView.swift:240-245`
   only shows for `.downloading`; `.verifying` falls into the "else" branch
   which shows "Download Model" — but the `.disabled(switchLocked && !isActive)`
   applies only to engine rows, not to the Download button, so the user can
   click Download again... which *does* proceed because `download()` has no
   `isDownloadActive` guard of its own.
5. User restart is the only recovery.

**Repro.**
- Delete the model while `verify()` is reading config.json (requires a race or
  a debugger breakpoint). `Data(contentsOf:)` throws. `state` stays at
  `.verifying`.
- Or: unplug the model dir via Finder during the ~50ms verification window.

**What EN should do.**
- Wrap the `verify()` body in a defer-style guard: if we exit without setting
  `.ready`, reset to `.corrupt` (or `.error`). The existing early-return paths
  at lines 445 and 463 do set `.corrupt`, but `Data(contentsOf:)` throwing at
  line 452 does not — it uses `try?` which silently no-ops, then... actually,
  looking again, `try?` returns nil, skip the hash block, fall through to
  `state = .ready` at line 471. That's arguably worse: silent pass on a
  config.json read failure.
- Add a timeout on `.verifying`: if the state has been `.verifying` for >60s,
  force it to `.error("verification timeout")`.

### M2 — MEDIUM: Silence threshold `-45 dB` is unjustified on this branch (and probably too loud)

**Where:** `AudioService.swift:188-189`, introduced in commit 1fc6cbd alongside
the B3/B4 test file.

**Failure mode.** `-45 dB` RMS is a *significantly* louder threshold than
`-60 dB`. For reference:
- A quiet room ambient noise floor is typically -55 to -50 dBFS on a good mic.
- A whispered voice at close range sits around -40 to -35 dBFS.
- Normal speech at 30cm is -25 to -15 dBFS.

The old `-60 dB` threshold rejected only true near-silence. At `-45 dB`:
1. A quiet room's ambient noise alone will pass as "not silent" on a noisy
   mic (false negatives: empty recordings transcribed).
2. A whispered voice or speech from ~1m away will be rejected as silence
   (false positives: user speaks, nothing happens).
3. Users on built-in MacBook mics in hushed contexts (library, office at
   night) will lose real input.

Handoff 060:68 / 061:50 do not mention AudioService. Commit message for
1fc6cbd is "Fix model download process" — nothing about VAD. No tests in
B3B4FixTests touch AudioService. No UT on this threshold. This is a behavior
change that rides a fix commit. It should either:
- Be reverted on this branch and re-proposed as its own PM-scoped change, or
- Get explicit PM sign-off with a rationale (what bug was it fixing? what
  recordings were leaking past the old threshold?), and get UT validation on
  quiet/noisy/whispered inputs.

Shipping it implicit in `fix/b3-b4-download-ui-bugs` is a scope violation that
CR should bounce back.

**Repro.**
- Record 3s of silence in a quiet room → should be rejected as silence (still
  works at -45).
- Record 3s of whispered speech at ~50cm → under -45, will now be rejected.
  Under -60, would have been transcribed.

**What EN should do.**
- Revert the AudioService hunk of 1fc6cbd before CR signs off, or file a
  separate PM handoff explaining the motivation and get UT coverage on the
  input set above.

### NIT — `isDownloadActive` naming

The name reads as past/state-of tense. `isDownloadInProgress` or
`downloadIsActive` would more clearly signal "right now." Non-blocking.

### NIT — Revert log is silent

`activeBackend.didSet` silently reverts. Add a one-line
`logger.warning("Refused backend switch from \(oldValue) → \(newValue) — download in progress")`
so future bug reports about "I clicked but nothing happened" have a trail.

### NIT — `engineRow`: active row not disabled but also not meaningfully interactive

When `switchLocked && isActive`, the active row is *enabled* (per line 339) but
clicking it triggers `activeBackend = backend` against the same value. That
goes through didSet (now guarded, will no-op via the `if isDownloadActive`
branch) but still re-publishes via `@Published` willSet (see C3) — firing
the `$activeBackend` sink and the SettingsView re-render. Consider a
`guard backend != modelManager.activeBackend` early return at line 310.

---

## summary for CR/PM

The prior-pass C1/C2/H3/H1 fixes are structurally pointed in the right
direction, but there are three CRITICAL issues that mean this branch is **not
ready to merge** as-is:

- **C3** — the revert publishes twice through `@Published`, and
  `MurmurApp.onReceive($activeBackend)` runs a live-process-killing side effect
  each time. Silent corruption risk on every blocked click.
- **C4** — the C1 guard has *zero direct test coverage* because the test seam
  was deferred. LGTM cannot be given to an untested CRITICAL guard.
- **H4** — `cancelDownload()` doesn't terminate the Python subprocess, which
  invalidates the safety argument the whole revert strategy rests on.

Plus H5 (inactive-backend lie), H6 (`.receive(on: .main)` regression), and
**M2 (-45 dB scope violation)** which must be pulled off this branch or
explicitly PM-approved.
