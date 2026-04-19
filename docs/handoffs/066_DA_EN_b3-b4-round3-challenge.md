---
from: DA
to: EN
pri: P1
status: CHG:3
created: 2026-04-19
---

## ctx
Round-2 re-challenge of the B3/B4 fixes after EN round-3 (handoff 064) and
CR round-2 LGTM (handoff 065). Branch `fix/b3-b4-download-ui-bugs` HEAD
`2caccd8`. CR signed off; DA's job now is to check what CR's pass missed.

Prior DA findings (063) were C3, C4, H4, H5, H6, M1, M2 + NITs. EN addressed
C3, C4, H4, H6, AudioService-revert, logging. H5, M1 deferred. This pass
re-examines the new `setActiveBackend` path, the `PassthroughSubject` choice,
the `Process.terminate()` assumption, and residual H5 interactions.

## ask
1. Address the CRITICAL findings below before ship.
2. HIGH/MEDIUM items: fix or document defer.
3. Decide whether H5 is a ship-blocker in light of H4's new interactions.

## constraints
- No scope creep; CR already approved. If a fix is big, defer with a ticket.
- Branch is green; must stay green.

## refs
- `Murmur/Services/ModelManager.swift:141-165` — `setActiveBackend`, guard
- `Murmur/Services/ModelManager.swift:148` — `committedBackendChange` subject
- `Murmur/Services/ModelManager.swift:177` — `downloadTask` (dead?)
- `Murmur/Services/ModelManager.swift:442-471` — `cancelDownload`
- `Murmur/Services/ModelManager.swift:727-744` — `#if DEBUG` test seams
- `Murmur/MurmurApp.swift:14-27, 56-67` — init service wiring + subscription
- `Murmur/Onboarding/OnboardingViewModel.swift:72, 88` — `setActiveBackend` callers
- Prior: `063_DA_EN_b3-b4-challenge.md`, `064_EN_CR_DA_b3-b4-round3.md`,
  `065_CR_EN_b3-b4-round3-review.md`

---

## out

### C5 — CRITICAL: `setActiveBackend(current)` re-fires the service kill/rebuild (regression introduced by the C3 fix)

**Where:** `ModelManager.swift:155-165` (no same-value early return) combined
with `MurmurApp.swift:56-67` (`onReceive(committedBackendChange)` runs
`coordinator.replaceTranscriptionService` on every emit), and the same-value
call sites:
- `OnboardingViewModel.swift:72` — `modelManager.setActiveBackend(.onnx)`
  fires even when `.onnx` is already active (the default path).
- `Views/SettingsView.swift:310` — clicking the already-active engine row
  calls `modelManager.setActiveBackend(backend)` with `backend == activeBackend`.

**Failure mode.** `setActiveBackend` has no `guard backend != activeBackend`
early return, so calling it with the current backend:
1. Assigns `activeBackend = backend` (same value) — `@Published` willSet
   publishes an `objectWillChange` even though the value is identical, causing
   every `@ObservedObject`/`@StateObject` consumer of `ModelManager` to re-render.
2. Re-persists to `UserDefaults` (harmless, but pointless disk write).
3. `committedBackendChange.send(backend)` fires → `MurmurApp.onReceive` calls
   `coordinator.replaceTranscriptionService(newService)` →
   `Task { await transcription.killProcess() }` on the currently-running service,
   then `transcription = newService`, then `preloadModelInBackground()`.

That `killProcess()` tears down the live transcription service. If the user:
- is mid-onboarding and clicks "Continue" on the backend-already-ONNX screen
  (triggers `nextStep()` at OnboardingViewModel.swift:72), the transcription
  service is killed and rebuilt during onboarding. If it's currently warming
  (preload in flight), that preload is now aborted mid-way and restarted,
  wasting 2-5s and potentially leaving a `transcribe.py` subprocess zombie
  (depends on `killProcess()` semantics — not audited here).
- clicks the already-active engine row in Settings during a recording session,
  the in-flight transcription is killed mid-process. This is the exact category
  of bug C3 was introduced to *prevent* (service replaced by a stray publish),
  just through a different door.

**This is a fresh regression vs. the old `didSet` design.** The old didSet
compared `oldValue != newValue` implicitly (via the guard's semantics in
earlier commits), and `@Published` willSet always fires but no `replace`
action was bound to it. Now `committedBackendChange` IS the replace trigger,
so any spurious emit is destructive.

**Repro (onboarding path, no download needed).**
1. Fresh launch with no saved backend → default `.onnx` loaded, transcription
   service created at `MurmurApp.init` line 20.
2. User advances onboarding past welcome → `nextStep()` called → hits
   `case .modelChoice:` at `OnboardingViewModel.swift:71` → calls
   `modelManager.setActiveBackend(.onnx)`.
3. Guard passes (state is `.notDownloaded` or `.ready`).
4. `activeBackend = .onnx` — same as current value.
5. `committedBackendChange.send(.onnx)` fires.
6. `MurmurApp.onReceive` builds a *new* `NativeTranscriptionService` with the
   same model path and assigns it to `coordinator.transcription`, replacing the
   one created at init. Log shows `killProcess()` fired on the init-time service.
7. `preloadModelInBackground()` runs twice (once from init, once from here).

**Repro (settings path, during active session).**
1. Active backend = ONNX, state = `.ready`.
2. User is recording. `coordinator.transcription` is in use.
3. User opens Settings, clicks the ONNX row (already active).
4. `setActiveBackend(.onnx)` passes guard.
5. `committedBackendChange` fires → `replaceTranscriptionService` →
   `await transcription.killProcess()` on the *recording-in-use* service.
6. Current transcription fails or produces empty output.

**What EN should do.**
- Add a same-value short-circuit at the top of `setActiveBackend`:
  ```swift
  guard backend != activeBackend else { return true }
  ```
  Return `true` because the "desired" state is achieved (nothing to do).
  Alternative: only fire `committedBackendChange.send` inside an `if backend
  != activeBackend` branch.
- Add a regression test in `SetActiveBackendGuardTests`:
  `test_setActiveBackend_sameValue_doesNotFireCommittedBackendChange`.
- Consider whether `refreshState()` should also skip for same-value (minor;
  idempotent but wasteful).

Note: 063 NIT #3 flagged this pattern at the `engineRow` call site and EN
deferred it as "low impact now that committedBackendChange is the publisher."
That analysis is wrong — `committedBackendChange` IS the subscriber that
causes the damage. The NIT was actually a C-class finding; promoting.

---

### C6 — CRITICAL: `Process.terminate()` does not guarantee that the HuggingFace download subprocess stops writing files (H4 incomplete)

**Where:** `ModelManager.swift:447-451` — `cancelDownload()` calls
`proc.terminate()` only. No follow-up `proc.waitUntilExit()`, no
`SIGKILL` escalation, no cleanup of partial files.

**Failure mode.**
(a) **Signal delivery is asynchronous.** `Process.terminate()` sends `SIGTERM`
to the top-level Python process. Python's signal handler dispatches on the
main thread between bytecode instructions — but `huggingface_hub.snapshot_download`
spends most of its time inside C extension calls (`requests` → `urllib3` →
OpenSSL `SSL_read`, file I/O, zlib). Python cannot service SIGTERM until the
C call returns. This window can be >1 second for a large file chunk. During
that window:
  1. `cancelDownload()` returns synchronously (state = .notDownloaded).
  2. `isDownloadActive` is now false.
  3. User calls `setActiveBackend(.whisper)` — guard passes.
  4. `committedBackendChange` fires → `replaceTranscriptionService`.
  5. The zombie Python process completes its current chunk write and flushes
     it to `Models-ONNX/`.
  6. Next click on ONNX in Settings: `isModelDownloaded(for: .onnx)` uses
     the *inactive-backend* path (`modelPath(for: .onnx) != nil`). If the
     partial write included the last of the three `requiredFiles`, the UI
     shows ONNX as "Downloaded" in green. User clicks it, `refreshState()`
     sets `.ready`, `preloadModelInBackground()` fires on corrupt files, crash.

(b) **No partial-file cleanup.** Per the comment at line 462-464, cancel
*intentionally* keeps partial downloads to allow resume. Fine as a product
choice, but it means partial files can linger and fool the inactive-backend
path in `isModelDownloaded(for:)` if the process wrote enough before dying.

(c) **No `waitUntilExit` means `activeDownloadProcess = nil` races with
termination.** Line 451 nils the reference immediately after `terminate()`.
If a second `cancelDownload()` fires (e.g. double-click), the second call
sees `activeDownloadProcess == nil` and does nothing, but the first process
is still dying. Benign today but a latent race if cancel-twice semantics ever
matter.

**The H4 fix is a *material improvement* over the round-1 code (where terminate
was never called), but it is not a complete fix.** The safety argument for C3
still relies on "cancel means no more writes to the model dir" — which is not
true in the window between SIGTERM delivery and Python actually exiting.

**Repro.**
- Start `.onnx` download. Let it get to the `snapshot_download` phase (the
  Python subprocess is running, writing to `~/.cache/huggingface` first,
  then copying to `Models-ONNX/`).
- Click Cancel. Immediately run `ps aux | grep snapshot_download`.
- **Expected (per EN):** process gone.
- **Actual:** process likely still alive for 0.5-3 seconds, especially if it
  was in the middle of a TLS handshake or a large-file decompression.
- Meanwhile, `isDownloadActive == false`, UI unlocks, Settings allows backend
  switches. H5 reads the dir and can falsely report "Downloaded".

**What EN should do.**
- Minimum: after `proc.terminate()`, call `proc.waitUntilExit()` with a
  bounded timeout (say, 2s). If still running, escalate to a `kill -9`
  equivalent (Swift `Process` doesn't expose SIGKILL directly; use
  `Darwin.kill(proc.processIdentifier, SIGKILL)` from `import Darwin`).
- Document the cancel guarantee: "by the time cancelDownload() returns, the
  subprocess is either exited or no longer holds file handles on the model
  dir." Anything weaker means H5 is reachable.
- Integration test: QA-owned, but requires a real subprocess. EN should file
  the test case (handoff 065 already noted this gap).

---

### C7 — CRITICAL: `#if DEBUG` test seams are callable from onboarding/settings code in debug builds

**Where:** `ModelManager.swift:727-744`.

**Failure mode.** `__testing_setState` and `__testing_setActiveBackend` are
declared without any access-level qualifier, so they default to `internal`.
Any file in the `Murmur` module compiled in Debug configuration can call them.
The guard doc-comment says "Never call this in production code," but *that
is a comment, not a check*. There is no `#if TESTING` vs. `#if DEBUG` split,
no `@_spi(Testing)` attribute, and no assertion that we're running under XCTest.

Concrete risks:
1. A future dev (or Claude) adds a debug-only menu item that calls
   `modelManager.__testing_setState(.ready)` to "simulate" a completed
   download for screenshot purposes. Ships in a TestFlight build. Users who
   enable Developer mode bypass the download.
2. Any crash reporter / telemetry wrapper that introspects public+internal
   API surface picks these up as "intended behavior."
3. Debug builds are what devs test against; if `__testing_setState` diverges
   from real state transitions (it doesn't fire `download()` side effects),
   dev-testing gives false-positive confidence.

**CR's claim at 065:60 — "they will not compile into release builds" — is
correct** (the whole function body is gated). But Debug builds include dev
builds, TestFlight via Debug config if misconfigured, and internal demos.
The issue is not release binary surface; it's *who can call them in Debug*.

**Repro.** In the Xcode debugger, while running a Debug build, execute
`po modelManager.__testing_setState(.ready)` in the LLDB console during
an onboarding session. State flips to `.ready`, MurmurApp's `onReceive(\$state)`
fires `preloadModelInBackground()`, attempting to load a non-existent model.

**What EN should do.**
- Gate with `#if DEBUG && TESTING` or tighter — add a custom `TESTING` flag
  to the test target's `OTHER_SWIFT_FLAGS` and guard on it. Alternatively
  use `@_spi(Testing) public` with `@testable import` replaced by explicit
  SPI import. The minimal fix: rename to `__testing_…` is fine, but also
  mark `fileprivate` and move test-only helper into an extension compiled
  into the test target via `@testable import`.
- Second-best: keep `internal` but add
  `assert(NSClassFromString("XCTest") != nil, "…testing seam called outside XCTest")`
  at the top of each seam function.
- This is not a shipped-binary bug, but it is a "the guard is implemented by
  convention" smell that C4 fixed by moving from an impossible-to-test path
  to an easy-to-misuse path.

---

### H7 — HIGH: Test coverage proves the guard fires when state is *forced*, not when a *real download* progresses through it

**Where:** `Tests/B3B4FixTests.swift:393-547` — every `SetActiveBackendGuardTests`
case uses `manager.__testing_setState(.downloading(...))` to set up. None
exercises the actual `download()` → `state = .downloading` path.

**Failure mode.** The tests prove:
- *IF* `state == .downloading`, *THEN* `setActiveBackend` returns false.

They do not prove:
- That `download()` actually puts `state` into `.downloading`.
- That the assignment at `ModelManager.swift:282` (`state = .downloading(...)`)
  is reachable synchronously before the `await ensurePythonEnv()` call at
  line 297. (It is, by inspection, but no test locks this in.)
- That `monitorTask`'s `state = .downloading(progress: -1, …)` at line 369
  continues to satisfy the `.downloading` branch of `isDownloadActive` (it
  does, because `isDownloadActive` matches any `.downloading(...)` case;
  but a future refactor could introduce `.downloadingFinalizing` or similar
  and break this without breaking the seam-driven tests).
- That `verify()` sets `state = .verifying` before any suspension point.
  (Inspection: yes, line 474. But it's a single line; a future refactor
  could move it.)

The seam-driven tests are valuable for the guard logic. They are insufficient
to claim "the guard fires during a real download." The CR at 065:89 flags
this: "unit tests use `__testing_setState(.downloading)` …
`activeDownloadProcess` is nil in tests and the `proc.terminate()` branch
is not exercised." CR punts to QA. Fine — but the handoff should carry a
QA action item as a ship-blocker, not a nice-to-have.

**What EN should do.**
- Add a lightweight integration test (maybe `#if DEBUG` with a mock Process
  or a real Python one-liner that sleeps 5s) that drives the real
  `download()` path and asserts `isDownloadActive` is true during the sleep.
- At minimum, file a QA handoff item calling this out as SHIP-blocker, not
  a deferred nicety. Mark it explicitly in 064/065 resolution.

---

### H8 — HIGH: H5 (inactive-backend file-existence lie) is no longer a "pre-existing deferred" issue — it is reachable through the H4/C6 cancel window

**Where:** `ModelManager.swift:209-223` (inactive branch returns
`modelPath(for: backend) != nil`) + `:442-471` (cancelDownload keeps partial
files for resume) + C6 (terminate may leave a Python process writing for
seconds after cancel).

**Failure mode.** H5 was deferred on grounds of "requires corrupt-file
detection, large scope, pre-existing." But the *cancel+switch* interaction
makes it trivially reachable on this branch:
1. Start `.onnx` download.
2. Cancel at 80% progress. Per line 462-466, partial files preserved for
   resume. Per C6, Python may still flush more files for ~1s after cancel.
3. Immediately switch to `.whisper` via Settings. `setActiveBackend(.whisper)`
   passes guard (state = .notDownloaded).
4. In Settings, the ONNX row now shows `isModelDownloaded(for: .onnx)` via
   the inactive-backend branch. If all three `requiredFiles` for ONNX
   happened to be written (config.json is tiny and likely written first;
   the two ONNX blobs may be present as partial .part files or completed
   from a prior run), the UI reports "Downloaded" in green.
5. User clicks ONNX. `setActiveBackend(.onnx)` → `refreshState()` →
   `modelPath != nil` → state = `.ready`. Preload fires. Crash.

**This was DA's own scope-deferred finding, but the C3/H4 changes created a
new, easy repro path.** Keeping it deferred is defensible (per EN at 064),
but it must be acknowledged that the H4 fix didn't close H5 and H5's repro
footprint has *expanded* on this branch, not shrunk.

**What EN should do.**
- Short-term: on cancel, if state is reset to `.notDownloaded`, delete the
  partial files OR add a `.part` marker file that `modelPath(for:)` checks
  and treats as "not ready."
- Or: in `cancelDownload()`, touch a per-backend `.cancelled` marker. In
  `isModelDownloaded(for: backend)` inactive branch, check for the marker
  and return false if present. Clear marker on successful `download()`
  completion.
- Alternatively: bump H5 to P0 and ship the per-backend size/hash manifest
  fix. (PM decision.)

---

### M3 — MEDIUM: `downloadTask` is dead code

**Where:** `ModelManager.swift:177` declares `private var downloadTask:
Task<Void, Never>?`. Only write sites are `downloadTask?.cancel()` (line 453)
and `downloadTask = nil` (line 454) in `cancelDownload()`. The `download()`
method never assigns to it. So `downloadTask?.cancel()` is always a no-op.

**Impact.** Misleading to reviewers. Suggests there's a task to cancel when
there isn't. If a future dev is asked to "cancel the download," they'll
assume `downloadTask.cancel()` does something and skip adding the real
cancellation mechanism.

**What EN should do.** Delete the property and the no-op cancel call. If
the intent was to cancel the `monitorTask`, store THAT instead.

---

### M4 — MEDIUM: `nextStep()` at `OnboardingViewModel.swift:72` discards `setActiveBackend` return value silently

**Where:** `OnboardingViewModel.swift:72, 88` — both callers call
`modelManager.setActiveBackend(backend)` without checking the return. In
practice this is fine because onboarding runs before any download is active,
but:
- If a user restarts onboarding while a download is in flight (not currently
  possible but a small refactor away), the backend silently stays on the old
  value and the onboarding UI shows the new value, diverging from reality.
- Test `test_setActiveBackend_afterCancel_isAccepted` proves `true` on happy
  path, but no test verifies callers handle `false` gracefully.

**What EN should do.** Either propagate the return (e.g., show a UI message
if refused) or explicitly `_ = manager.setActiveBackend(...)` to document
the intentional ignore.

---

### M5 — MEDIUM: `refreshState()` inside `setActiveBackend` can flip state to `.ready` even for partial/corrupt backends

**Where:** `ModelManager.swift:163` calls `refreshState()` after every accepted
switch. `refreshState()` at line 252-266 uses `modelPath != nil` (file
existence) to set `.ready`. This is the same weakness as H5.

**Failure mode.** Switching to an inactive backend that has partial files
sets `state = .ready` immediately. MurmurApp's `onReceive(\$state)` at line
68-72 fires `preloadModelInBackground()` on corrupt files.

**What EN should do.** Either (a) tighten `refreshState()` to verify hash or
size before declaring ready, or (b) make switch-path use a more conservative
state (e.g., `.unverified` → user explicitly verifies/re-downloads before
use). Scope decision.

---

### NIT — `setActiveBackend` same-value early return (see C5)

Promoted to C5.

### NIT — Log line on refused switch uses `—` (em dash)

`ModelManager.swift:157` — good for humans, but log parsers may choke.
Non-blocking.

### NIT — `committedBackendChange` is a `PassthroughSubject<ModelBackend, Never>` exposed as a `let` property

Consider exposing only the `AnyPublisher` (`.eraseToAnyPublisher()`) so
external callers can't accidentally `.send` into it. Read-only encapsulation.

---

## summary

CR signed LGTM; DA finds **three CRITICAL** items CR missed:

- **C5** — same-value `setActiveBackend` fires `committedBackendChange` →
  tears down the live transcription service. Reachable in onboarding default
  path (`nextStep()` → `.onnx` when already `.onnx`) and in any "re-click
  active row" in Settings. New regression introduced by the C3 fix.
- **C6** — `Process.terminate()` in `cancelDownload()` does not synchronously
  stop file writes. The safety guarantee C3 depends on ("after cancel, no
  writes to model dir") is wrong for up to several seconds after `terminate()`.
  H4 fix is a real improvement but not complete.
- **C7** — `#if DEBUG` test seams are module-internal in Debug, callable from
  any Debug build code (LLDB, dev menu, future refactors). Convention-based
  safety, not structural.

Plus H7 (tests only prove guard logic, not real-download reachability), H8
(H5 repro surface expanded by this branch's cancel flow), M3 (dead
downloadTask property), M4, M5, and a couple of nits. H8 upgrades DA's
own 063 deferral: H5 is now a ship-consideration, not a defer.

Status: **CHG:3** (fix C5 + C6 + C7; address H7/H8 with tickets at minimum).
C5 is the highest-priority single fix: two lines to add a same-value guard.

---

## resolution

EN addressed all three CRITICAL findings in round-4. See `067_EN_CR_DA_b3-b4-round4.md`.

- C5: `guard backend != activeBackend else { return true }` added at ModelManager.swift:155. 3 regression tests.
- C6: SIGKILL escalation via `Darwin.kill` in background Task + model dir deletion (H5 mitigation). 1 new test.
- C7: `assert(NSClassFromString("XCTestCase") != nil, ...)` in both seam functions (option b).
- M3: dead `downloadTask` property removed.
- H7/H8: deferred with QA integration ask filed as `068_QA_EN_b3-b4-integration-ask.md`.

DA round-3 re-review: C5/C6/C7/M3 all verified. One new HIGH finding (C8, cancel → redownload race on partial-dir delete) and two lesser items (M6 PID-reuse, H9 integration-test gap) raised in `070_DA_EN_b3-b4-round4-challenge.md`. Status: **CHG:2** — fix C8 before QA.
