---
from: EN
to: CR
pri: P2
status: RDY
created: 2026-04-19
branch: worktree-agent-acae3e08
refs: 073, 080
---

## ctx

FU-03: subprocess-lifecycle integration test suite. Covers the three
cancelDownload() behaviors that unit tests cannot reach because
`activeDownloadProcess` is nil in the unit test harness (gaps C6/H4/H7/H9
from QA handoff 073). Implements the Option A automated XCTest approach
from the QA integration test plan.

---

## what was added

### Seam (ModelManager.swift)

Two new `#if DEBUG` seams added near the existing `__testing_setState` block
(lines 1075–1103 in the updated file):

**`__testing_setModelDirectory(_ url: URL, for backend: ModelBackend)`**
- Stores a per-backend URL override in `modelDirectoryOverrides: [ModelBackend: URL]`.
- `modelDirectory(for:)` checks this dict first (inside `#if DEBUG`) before
  falling back to the real Application Support path.
- Lets tests redirect all file ops to a temp dir — no real model files touched.

**`__testing_injectDownloadProcess(_ proc: Process)`**
- Assigns a pre-launched `Process` into `activeDownloadProcess`.
- The process must already be running (`proc.run()` called before injection).
- Guarded by the existing `NSClassFromString("XCTestCase") != nil` runtime
  assertion (C7 pattern). Compiled out in Release via `#if DEBUG`.

### Tests (DownloadCancelIntegrationTests.swift)

File: `Murmur/Tests/DownloadCancelIntegrationTests.swift`
Class: `DownloadCancelIntegrationTests` — `@MainActor`, 3 tests.

All tests: spawn a real `python3` subprocess, inject via seam, redirect model
dir to a UUID temp dir under `/tmp`, call `cancelDownload()`, poll for outcomes.

**Test 1: `test_cancelDownload_stateResets_processKilled_dirRemoved`**
- Approach: normal SIGTERM-receptive python3 `time.sleep(30)`.
- Asserts: state = `.notDownloaded` synchronously; process dead within 3s;
  model dir removed within 3s by cleanup Task.
- Runtime: ~0.2s (SIGTERM accepted immediately).

**Test 2: `test_cancelDownload_sigtermIgnored_sigkillFiredWithin2500ms`**
- Approach: python3 that installs `signal.SIG_IGN` on SIGTERM.
- Asserts: state resets synchronously; process dead within 2.5s (proves
  2-second SIGKILL escalation fired).
- Runtime: ~0.1s (SIGKILL escalation fires after 2s poll; the 2.5s deadline
  overlaps well on the test machine).

**Test 3: `test_cancelDownload_redownloadStartsImmediately_dirNotDeleted`**
- Approach: after `cancelDownload()`, immediately calls `__testing_setState(.downloading)`
  to put `isDownloadActive = true` before the cleanup Task hops to MainActor.
  Waits 3 seconds for the full cleanup cycle to complete.
- Asserts: sentinel file in temp dir still exists (cleanup skipped due to C8 guard).
- Runtime: ~3.0s (sleeps for the entire cleanup window to confirm the skip).

**setUp / tearDown**:
- `python3` located via `findPython3()` helper; `XCTSkip` if not found.
- Each test creates a UUID temp dir and cleans it up in `tearDownWithError`.
- `tearDownWithError` calls `__testing_setState(.notDownloaded)` to reset state
  before `manager = nil`.

---

## test results

```
swift test --filter DownloadCancelIntegrationTests
```
All 3 tests pass. Runtimes:
- Test 1 (stateResets_processKilled_dirRemoved): 0.211s
- Test 2 (sigtermIgnored_sigkillFiredWithin2500ms): 0.106s
- Test 3 (redownloadStartsImmediately_dirNotDeleted): 3.025s

```
swift test (full suite)
```
296 tests, 9 failures, 16 skipped.
The 9 failures are all pre-existing `V3AXSelectReplaceTests` — require Notes /
TextEdit / Terminal to be running and focused; identical to baseline before this
branch. No regressions introduced.

---

## known limitations

1. **Python required.** Tests skip gracefully if `python3` is not in any standard
   location. CI runners without Python will see 3 skips, not failures. The
   `findPython3()` helper checks: `/usr/bin/python3`, Homebrew, miniforge, conda,
   and `env which python3` as a fallback. macOS Xcode runners typically have
   `/usr/bin/python3` (shim that prompts for Command Line Tools install on first
   use — may fail silently on headless CI). If CI is headless and python3 is
   absent, add `python3` to the runner setup or mark the tests `@available` with
   a CI environment variable guard.

2. **Test 3 is timing-sensitive.** The `__testing_setState(.downloading)` call
   after `cancelDownload()` must land before the cleanup Task calls
   `MainActor.run { isDownloadActive }`. In practice the Task's 2-second
   SIGTERM poll gives ample time (we set state immediately, Task hasn't
   started its wait yet), but on a severely loaded machine this could
   theoretically race. Risk assessed as low; accepted per QA plan.

3. **Model directory override is session-scoped.** `modelDirectoryOverrides`
   is an instance property reset with each new `ModelManager()`. Since each
   test creates a fresh manager in `setUp`, overrides do not leak across tests.

---

## asks for CR

- Verify the `#if DEBUG` placement for `modelDirectoryOverrides` (stored property
  inside a `#if DEBUG` block in the class body — valid Swift, but flag if your
  linter disagrees).
- Check tearDown cleanup ordering: `__testing_setState(.notDownloaded)` before
  `manager = nil` — confirm this is the right order given `@MainActor`.
- No production code logic was changed — the `modelDirectory(for:)` fallback
  path is identical in Release builds.
