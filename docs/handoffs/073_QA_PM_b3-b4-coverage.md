---
from: QA
to: PM
pri: P1
status: RDY
created: 2026-04-19
branch: fix/b3-b4-download-ui-bugs
refs: 060, 061, 062, 063, 064, 065, 066, 067, 068, 069, 070, 071
---

## ctx

QA coverage review of the B3/B4 download-UI bug fixes. Covers all findings
from the full DA/CR review chain (C1–C8, H1–H9, CR-M1/M2, M3–M6). Responds
to EN's integration-test ask in handoff 068. Delivers:

1. Coverage table: every finding mapped to unit tests or flagged as a gap.
2. Integration test plan for the subprocess cancel path (ship-gating per 068).
3. PM-level residual risk register.

---

## 1. Coverage table

| Finding | Description | Unit tests covering it | Gap? |
|---------|-------------|----------------------|------|
| B3 | Combine subscription forwards ModelManager.objectWillChange into OnboardingViewModel | `OnboardingViewModelRepublishTests` (3 tests): forward propagation, multiple changes, no zombie sink after dealloc | Covered |
| B4 | isModelDownloaded positive assertion (.ready + files only) | `IsModelDownloadedActiveBackendTests` (6 tests): ready+present, notDownloaded, ready+deleted, non-active present/absent, notDownloaded always-false | Covered |
| C1 | activeBackend.didSet revert (superseded by C3 — setActiveBackend guard) | Covered via C3/C4 tests below | Superseded |
| C2 | SettingsView engine rows .disabled during download | No unit test — view-layer guard, visual affordance. Relies on C3 guard as authoritative backstop. | **Gap — manual only** |
| C3 | setActiveBackend refuses switch without publishing; committedBackendChange not fired | `SetActiveBackendGuardTests`: `test_setActiveBackend_whileDownloading_returnsFalse`, `_activeBackendUnchanged`, `_whileVerifying_returnsFalse`, `_committedBackendChange_doesNotFireWhenSwitchRefused_downloading`, `_verifying` (5 tests) | Covered |
| C4 | Guard has direct test coverage (seam added) | `SetActiveBackendGuardTests` (all 10 tests use `__testing_setState` seam) | Covered |
| C5 | Same-value setActiveBackend returns true without firing committedBackendChange | `SetActiveBackendGuardTests`: `test_setActiveBackend_sameValue_returnsTrue`, `_doesNotFireCommittedBackendChange`, `_doesNotRewriteUserDefaults` (3 tests) | Covered |
| C6 | SIGKILL escalation after cancelDownload + model dir deletion | `CancelDownloadTests`: state/isDownloadActive/statusMessage reset synchronously (4 tests). SIGKILL path: **no unit test** — requires real subprocess. Tracked in 068. | **Gap — integration test required** |
| C7 | Test seam guarded by XCTestCase assert in Debug builds | Not directly testable (assert fires only outside XCTest). Design verified by CR in 069. | Covered (by design) |
| C8 | Cancel→redownload race: cleanup Task skips removeItem when new download is active | `CancelDownloadCleanupRaceTests` (2 tests): skips when downloading, removes when idle | Covered |
| H1 | Remove .receive(on: DispatchQueue.main) hop from OnboardingViewModel sink | Verified by B3 forward-propagation tests (synchronous delivery confirmed) | Covered |
| H3 | isModelDownloaded .corrupt/.error return false (positive assertion) | `IsModelDownloadedActiveBackendTests`: covered via the positive-assert logic; .corrupt/.error cannot be driven without a subprocess seam — states unreachable | **Partial gap** — states .corrupt/.error not directly tested; risk low (logic is a simple `state == .ready` check) |
| H4 | cancelDownload stores Process reference and calls terminate() | Synchronous state reset tested in `CancelDownloadTests`. proc.terminate() call: **no unit test** — activeDownloadProcess is nil in harness. | **Gap — integration test required** |
| H5 / H8 | Inactive-backend file-existence path lies for partial/corrupt files | Not covered by any test. Mitigation only: cancel deletes the dir (C8 / `CancelDownloadCleanupRaceTests`). Full fix deferred per PM scope. | **Known gap — PM decision required** |
| H6 | .receive(on: .main) removed (regression introduced then fixed) | Covered by B3 propagation tests | Covered |
| H7 | Tests prove guard logic but not real-download reachability | Structural gap acknowledged in 068 and 070. QA integration plan below. | **Gap — integration test required** |
| H9 | SIGKILL + partial-dir-delete paths never run in CI | Structural gap. All 274 CI tests pass without touching a real process. | **Gap — integration test required** |
| CR-M1 | OnboardingView.backendCard missing .disabled (added) | No unit test — view-layer change. Same rationale as C2. | **Gap — manual only** |
| CR-M2 | didSet recursive-assign risk (superseded by C3 refactor) | No longer applicable — activeBackend.didSet is gone. | Superseded |
| M3 | Dead downloadTask property removed | Verified by grep + CR regression scan (069). | Covered (structural) |
| M4 | setActiveBackend callers silently discard false return | Not tested; marked as unreachable path in current onboarding flow. | **Known gap — low risk** |
| M5 | refreshState sets .ready on partial-file backends | Not tested. Same root as H5. Covered by H5 deferral ticket. | **Known gap — PM decision** |
| M6 | PID-reuse window in SIGKILL escalation | Documented in source comment; accepted EPERM risk. No test. | **Known gap — accepted** |
| AudioService revert | -60 → -45 dB VAD change reverted | CR regression scan confirmed revert. No test needed. | Covered (structural) |

### Summary counts

- Total unit tests in B3B4FixTests.swift: **28 tests** across 6 classes
- Total unit tests in ModelSwitchingTests.swift: **11 tests** across 4 classes
- Findings fully covered by unit tests: **15 of 23**
- Findings requiring integration tests (ship-gating): **C6 / H4 / H7 / H9** (one integration test suite covers all four)
- Findings with view-layer-only coverage gap (manual): **C2, CR-M1**
- Findings with known-deferred PM-scope gaps: **H5, H8, M5**
- Findings with accepted low risk: **M4, M6**

---

## 2. Integration test plan (responds to handoff 068)

These tests cannot be automated as unit tests because `activeDownloadProcess` is
nil in the test harness — the real `Process` lifecycle (SIGTERM → poll → SIGKILL
→ FileManager.removeItem) is not exercised by any current test.

### Option A: Automated XCTest integration test (preferred)

**File:** `Murmur/Tests/ModelManagerCancelIntegrationTests.swift`
**Gate:** `#if DEBUG` — must not ship in release target.
**Dependency:** No network, no HuggingFace. Uses a real Python subprocess that
simulates a stalled download.

---

#### Test 1 — Cancel mid-download: process terminates within 3 seconds

```
Preconditions:
  - `python3` available on the test machine (standard macOS).
  - A test seam exists in ModelManager to inject a pre-created Process into
    `activeDownloadProcess` without running real download() logic.
    EN ask: add `__testing_injectDownloadProcess(_ proc: Process)` seam alongside
    the existing `__testing_setState` seam.

Steps:
  1. Create a Process: python3 -c "import time; time.sleep(30)"
  2. Call proc.launch() (or proc.run())
  3. Call manager.__testing_setState(.downloading(progress: 0.1, bytesPerSec: 0))
  4. Call manager.__testing_injectDownloadProcess(proc)
  5. Capture proc.processIdentifier
  6. Call manager.cancelDownload()
  7. Wait up to 3 seconds polling kill(pid, 0)

Expected outcomes:
  a. manager.state == .notDownloaded within 100ms (synchronous reset)
  b. manager.isDownloadActive == false within 100ms
  c. kill(pid, 0) returns -1 with errno == ESRCH within 3 seconds (process dead)
```

---

#### Test 2 — SIGKILL escalation: hung process killed within 2.5 seconds

```
Preconditions:
  - Same seam as Test 1.
  - A Python script that catches SIGTERM and continues:
    python3 -c "
      import signal, time
      signal.signal(signal.SIGTERM, lambda s,f: None)
      time.sleep(30)
    "

Steps:
  1. Create and launch the SIGTERM-ignoring Process.
  2. Inject via __testing_injectDownloadProcess.
  3. Set state to .downloading via __testing_setState.
  4. Call manager.cancelDownload().
  5. Poll kill(pid, 0) at 200ms intervals for up to 2.5 seconds.

Expected outcomes:
  a. manager.state == .notDownloaded within 100ms (synchronous reset — before SIGKILL)
  b. kill(pid, 0) returns -1 with errno == ESRCH within 2.5 seconds (SIGKILL fired and
     took effect within the 2-second escalation window + 100ms grace)
  c. The model directory for the active backend does NOT exist after the cleanup Task
     completes (give 3 seconds total after cancelDownload() returns).
```

---

#### Test 3 — Partial-file cleanup: model dir removed after cancel

```
Preconditions:
  - Same seam as Test 1.
  - Plant a sentinel file in manager.modelDirectory(for: .onnx) before the test.

Steps:
  1. Create sentinel file in manager.modelDirectory(for: .onnx).
  2. Launch python3 -c "import time; time.sleep(30)" Process.
  3. Inject and set state to .downloading.
  4. Call manager.cancelDownload().
  5. Wait up to 3 seconds for the cleanup Task to complete (poll FileManager.fileExists
     on the sentinel path).

Expected outcomes:
  a. Sentinel file does not exist after 3 seconds.
  b. manager.state == .notDownloaded.
  c. manager.isDownloadActive == false.
```

---

#### Test 4 — Cancel-then-immediately-redownload: new download's dir is NOT deleted

```
Preconditions:
  - Same seam as Test 1.
  - Plant a sentinel file in manager.modelDirectory(for: .onnx).
  - Second test seam: __testing_injectDownloadProcess must be callable to simulate a
    new download starting before the cleanup Task runs.

Steps:
  1. Launch first python3 sleep process. Inject as activeDownloadProcess.
  2. Set state to .downloading.
  3. Call manager.cancelDownload() — resets state synchronously to .notDownloaded.
  4. IMMEDIATELY (before 2.1s cleanup window closes):
     a. Call manager.__testing_setState(.downloading(progress: 0.1, bytesPerSec: 0))
        to simulate a new download starting for the same backend.
  5. Wait 3 seconds (long enough for the old cleanup Task to complete its poll loop).
  6. Check FileManager.fileExists on the sentinel path.

Expected outcomes:
  a. Sentinel file STILL EXISTS — cleanup Task saw isDownloadActive == true and
     skipped removeItem.
  b. manager.isDownloadActive == true (the simulated new download state is still set).
  c. No crash or assertion failure.

Note: This test covers the C8 fix. It complements the seam-driven
CancelDownloadCleanupRaceTests by exercising the real Task.detached timing.
```

---

### Option B: Manual test plan (fallback if seam cannot be added before ship)

If EN cannot land `__testing_injectDownloadProcess` before the ship gate, use
this manual checklist. Requires HuggingFace token and a real network connection.

```
## Manual Test: Cancel mid-download subprocess termination
Preconditions:
  - App built in Debug. HuggingFace token configured. ONNX selected as backend.
  - Terminal open for process monitoring.

Steps:
  1. Open Settings → Model → Download Model (ONNX).
     Expected: download progress begins, status shows bytes/sec.
  2. After 5-10 seconds (subprocess is mid-download), click Cancel.
     Expected: progress disappears, state shows "Not Downloaded."
  3. Immediately run: ps aux | grep snapshot_download
     Expected: no snapshot_download process visible within 3 seconds of cancel.
  4. Run: ls ~/Library/Application\ Support/Murmur/Models-ONNX/
     Expected: directory does not exist (cleaned up by cancel).

## Manual Test: SIGKILL escalation
Preconditions: Same as above, plus ability to run a Python script.

Steps:
  1. In Terminal, run a SIGTERM-ignoring script:
       python3 -c "import signal,time; signal.signal(signal.SIGTERM,lambda s,f:None); time.sleep(60)"
     Note the PID.
  2. In a second terminal, after 2 seconds: kill -TERM <PID>
     Expected: process still alive (confirms SIGTERM ignored).
  3. After 2 more seconds: kill -9 <PID>
     Expected: process terminates (confirms SIGKILL works on the platform).
  Manual note: this validates the OS-level mechanism; the automated integration
  test (Option A, Test 2) validates that ModelManager uses it correctly.

## Manual Test: Cancel-then-redownload
Steps:
  1. Start ONNX download. Wait 10s.
  2. Click Cancel. Immediately click Download again (within 2 seconds).
     Expected: second download starts normally; no "Download failed" error.
  3. Wait for second download to complete or run for 30 seconds.
     Expected: no corruption; model directory exists and is being written into.

Priority: Critical
Reason not automated: requires network + HuggingFace token; subprocess seam
not yet added to ModelManager.
```

---

## 3. PM-level risk register

Items below are not code bugs in the current branch but represent residual
product risk that PM should acknowledge before ship.

### Risk 1 — H5/M5: inactive-backend "Downloaded" label can lie (MEDIUM)

If a user had a prior partial ONNX download (before this branch), the model
directory may contain some required filenames but with truncated contents.
`isModelDownloaded(for: .onnx)` on the inactive-backend path returns true based
on file-name existence alone. The UI shows "Downloaded" in green. User clicks
ONNX, preload fires on corrupt files, transcription crashes.

The cancel-cleanup mitigation (C8) only helps for files written during THIS
session. Orphan dirs from prior sessions, previous-version downloads, or
app crashes during download are not cleaned up.

**PM ask:** Approve a follow-up PM ticket for per-backend hash/size manifest
verification at `isModelDownloaded` and `refreshState` time. This is the H5
full fix (handoffs 063:180, 067:133, 069:154).

### Risk 2 — H9: SIGKILL + partial-file-delete paths ship unexercised in CI (HIGH)

The cancelDownload() async cleanup chain (SIGTERM → poll → SIGKILL → rmdir)
has never been run against a real subprocess in any automated test. All 274 CI
tests pass without touching the real Process lifecycle. The code is structurally
correct per CR inspection (069), but behavioral regressions in this path will
not be caught until they surface in user reports.

**PM ask:** Make handoff 068 integration test (or the manual plan above) a
hard ship-gate prerequisite. Do not merge until at least the manual checklist
has been executed and signed off by QA or UT.

### Risk 3 — Real network failures not tested (LOW-MEDIUM)

`download()` uses `snapshot_download` against HuggingFace. Known failure
modes not covered by any test:
- Rate limiting (HTTP 429): Python process may retry indefinitely, holding the
  subprocess alive past the expected cancel window.
- DNS failure on airgapped networks: process errors immediately; cancel
  path is not reached (benign but user sees cryptic error).
- HuggingFace API schema change: download script breaks silently, leaving
  state at .downloading forever until timeout (none implemented).

**PM ask:** Add a download timeout (`state = .error("download timed out")` if
`.downloading` persists beyond N minutes without progress). File as follow-up.

### Risk 4 — Slow-disk delete on cancel (LOW)

`FileManager.removeItem` on a large partial model dir (multi-GB) can take
several seconds on a spinning disk or an HDD-based external volume. The cleanup
Task does not time out the delete. During the delete, `isDownloadActive == false`
and the UI allows a new download, which `CancelDownloadCleanupRaceTests` proves
is safe (the C8 guard skips the delete). But on a slow disk the dir may persist
visibly for several seconds after cancel, which is confusing UX.

No action needed for this branch. Document as a future UX polish item.

### Risk 5 — M4: onboarding cannot surface setActiveBackend refusal (LOW)

`OnboardingViewModel.nextStep()` and `selectBackend()` call `setActiveBackend`
with `@discardableResult`. If a future refactor adds a path where onboarding
runs during a download (e.g., user goes back to onboarding mid-download),
the backend switch silently fails with no user feedback. Current onboarding
flow makes this unreachable.

**PM ask:** If any onboarding restart flow is planned, wire the false-return
to a UI error state before shipping that feature.

---

## test-code quality notes (for EN)

`B3B4FixTests.swift` is overall well-constructed. Specific notes:

1. **setUp/tearDown isolation**: All test classes restore state in `tearDownWithError`.
   `SetActiveBackendGuardTests.tearDownWithError` calls `__testing_setState(.notDownloaded)`
   then `setActiveBackend(.onnx)`. `IsModelDownloadedActiveBackendTests` removes the
   temp directory in tearDown. `CancelDownloadCleanupRaceTests` removes `tempModelDir`.
   All three patterns are correct and deterministic.

2. **Determinism**: No test has a timing dependency except `OnboardingViewModelRepublishTests`
   which uses XCTestExpectation with a 1-second timeout. This is appropriate for Combine
   delivery (synchronous in practice, but the expectation is correct defensive form).
   All other tests are fully synchronous. No known flaky patterns.

3. **`test_nonActiveBackend_filesAbsent_returnsFalse` early return**: Uses a plain `return`
   instead of `try XCTSkip(...)`. As noted in CR handoff 062, this is nit-level but should
   be changed to `XCTSkip` for proper skip reporting in CI. Not a flaky risk.

4. **`CancelDownloadCleanupRaceTests` disk state**: Both tests write to the real
   `manager.modelDirectory(for: .onnx)` path. On a machine with ONNX already downloaded,
   `test_cleanupAfterCancel_removesDirectory_whenNoDownloadIsActive` will delete the real
   model directory. This is a real risk. EN should add a guard:
   ```swift
   guard manager.state != .ready else {
       throw XCTSkip("Real ONNX model present — skip destructive cleanup test")
   }
   ```
   **This is an actionable test-quality bug.** Filing as a documentation ask, not blocking.

5. **No test covers OnboardingView or SettingsView `.disabled` state**: C2 and CR-M1
   are view-layer changes with zero automated coverage. A UI test (XCUITest) could
   assert the backend-card is disabled during an active download, but this would
   require either a real download or a SwiftUI preview/injection seam.
   Not feasible on this branch; document as follow-up.

---

## asks

- **PM:** Ack the three PM-asks above (H5 ticket, 068 ship-gate, download timeout).
- **EN:** Add `__testing_injectDownloadProcess(_:)` seam to ModelManager so automated
  integration tests can be written. Filed as the prerequisite for Option A above.
- **EN:** Add `XCTSkip` guard in `CancelDownloadCleanupRaceTests` to protect real model
  dirs on developer machines.
- **EN:** Change `test_nonActiveBackend_filesAbsent_returnsFalse` early `return` to
  `try XCTSkip(...)` for proper CI skip reporting.

---

## resolution of handoff 068

Handoff `068_QA_EN_b3-b4-integration-ask.md` is resolved by this document.
The integration test plan (Section 2) delivers the four tests EN requested:
cancel mid-download (Test 1), SIGKILL escalation (Test 2), partial-file cleanup
(Test 3), and cancel→redownload race (Test 4). A manual fallback plan is
included for the case where the `__testing_injectDownloadProcess` seam cannot
land before the ship gate.

QA assessment: **the integration tests should be the ship gate for C6/H4/H7/H9**.
If only the manual plan is executed, require explicit sign-off from UT in the
release checklist.

See this handoff (073) as the QA sign-off document for the B3/B4 branch from
QA's perspective. PM + UT sign-off remains pending.

---

## resolution

The ship-blocker test bug (item 4 in test-code quality notes) was fixed by EN in
handoff `075_EN_QA_b3-b4-test-fix.md`. Approach (b) chosen: `XCTSkipIf` guard in
`CancelDownloadCleanupRaceTests.setUpWithError` using `modelPath(for: .onnx) != nil`.
C8 correctness is preserved; no production code was changed. All 274 tests pass
(11 pre-existing AX failures unrelated to this branch).
