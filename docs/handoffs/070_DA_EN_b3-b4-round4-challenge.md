---
from: DA
to: EN, CR
pri: P1
status: CHG:2
created: 2026-04-19
branch: fix/b3-b4-download-ui-bugs
---

## ctx

Round-3 re-challenge of the B3/B4 fixes after EN round-4 (handoff 067). Branch
HEAD `7f0409f`. EN addressed the three CRITICALs (C5, C6, C7) DA raised in 066,
plus M3. This pass re-examines the new `Task.detached` cleanup path in
`cancelDownload`, the structure of the SIGKILL escalation, the XCTest assertion
seam, and the cancel/restart race that the H5 partial-file deletion introduces.

This is the last DA gate before QA/UT/PM.

## ask

1. EN: fix C8 (new race introduced by the cleanup Task) before QA.
2. EN: decide on M6 (PID-reuse narrow window) — document or fix.
3. CR/PM: ack H9 — the unit-test harness still does not exercise the SIGKILL or
   partial-file-delete path; confidence is entirely on QA's integration test.

## constraints

- No scope creep beyond this branch.
- Branch must stay green. Any new test must not depend on a real subprocess.

## refs

- `Murmur/Services/ModelManager.swift:156-172` — `setActiveBackend` with C5 guard
- `Murmur/Services/ModelManager.swift:239-258` — `init()` — initial service wiring
- `Murmur/Services/ModelManager.swift:451-521` — `cancelDownload` with SIGKILL + dir delete
- `Murmur/Services/ModelManager.swift:530-538` — `waitForProcessExit`
- `Murmur/Services/ModelManager.swift:287-448` — `download()` (creates modelDirectory)
- `Murmur/Services/ModelManager.swift:807-834` — test seams with XCTestCase assert
- `Murmur/MurmurApp.swift:14-27, 56-67` — init service wiring + subscription
- Prior: `063`, `064`, `065`, `066`, `067`, `068`

---

## out

### C5 — same-value short-circuit: LGTM

Verified the fix at `ModelManager.swift:162`:

```swift
guard backend != activeBackend else { return true }
```

This sits above the `isDownloadActive` guard, so same-value calls never hit the
`committedBackendChange.send`. The three new regression tests at
`Tests/B3B4FixTests.swift:555-605` cover the contract (returns true, no emit,
no UserDefaults rewrite).

**Initial-application check (DA task item 1).** The concern was: at app launch,
`ModelManager.init()` reads `modelBackend` from UserDefaults, assigns to
`self.activeBackend = saved` at `:244` directly (not via `setActiveBackend`).
`MurmurApp.init()` then reads `mm.activeBackend` and constructs the right
`TranscriptionService` at `MurmurApp.swift:18-23`. The initial service therefore
does NOT come from a `committedBackendChange` emission — it comes from direct
construction. So C5's guard short-circuiting the same-value case at launch is
safe: there is no code path that expects `committedBackendChange` to fire for
the saved backend at launch. Confirmed.

No action needed.

---

### C6 — SIGKILL escalation: mostly LGTM, but see C8 + M6

The escalation structure is correct:

1. SIGTERM synchronously (`:477`).
2. Capture `pid` and `capturedBackend` by value (`:472-476`).
3. `Task.detached` for poll + escalate + cleanup (`:483-510`).
4. Poll via `proc.isRunning` at 100ms intervals for up to 2s (`:530-538`).
5. If still running, `Darwin.kill(pid, SIGKILL)` + 100ms grace (`:488-492`).
6. `FileManager.removeItem` on model directory (`:503-506`).
7. Synchronous state reset (`:517-519`).

**Retain cycle / deallocation during 2s window (DA task item 2d).** The
`Task.detached` captures `proc` and `pid` by value (both are `let` bindings in
the enclosing scope) and `logger` by value (`Logger` is a `struct`). There is
no `self` capture — verified by reading `:483-510`. So `ModelManager`
deallocation during the 2s window does NOT affect the cleanup Task. The process
termination and directory deletion will still run to completion. This is
correct behaviour and the design is sound. No action needed.

**`proc.isRunning` staleness (DA task item 2a).** `Process.isRunning` in
Foundation is backed by `waitpid(pid, …, WNOHANG)` semantics under the hood; it
is not cached. It reflects the kernel's view at call time (subject to the
parent having not yet reaped via `terminationHandler`). In practice, since
`download()` is the parent and registers `proc.terminationHandler` at `:391`,
the process will be reaped by that handler when it exits — at which point
`isRunning` becomes false. No false-true staleness. No action needed.

However: see **C8** below for an interaction with the reap timing that matters.

---

### C7 — XCTest runtime assertion: LGTM with caveat (acknowledged, not blocking)

`assert(NSClassFromString("XCTestCase") != nil, ...)` at `:815, :828` does what
DA asked for in 066 option (b). In Debug, if a non-test Debug binary invokes
`__testing_setState` or `__testing_setActiveBackend`, the assertion fires and
the app crashes — loud, structural, immediate. CR and PM should note:

- `assert` is stripped in release, but the whole `#if DEBUG` wrapper also
  strips the functions. So release builds cannot hit the function at all; the
  assertion is only reachable in Debug, and any Debug invocation outside XCTest
  trips it.
- This is "theater" only in the narrow sense that a malicious internal consumer
  could catch the assertion via signal handling or disable it via
  `-Onone -assert-config=Disabled`. That's not a realistic threat model.
- The practical attack surface (a future dev adds a debug menu item that calls
  `__testing_setState`) is now blocked at first execution in Debug.

**Caveat.** `NSClassFromString("XCTestCase") != nil` is `true` under `swift test`
(XCTest is linked). It is false under every other debug launch. But if someone
ever ships a Debug build that *also* links XCTest (e.g. for dogfooding with test
instrumentation), the assertion would pass and the seam would be callable. This
is contrived and not worth fixing today. Not blocking.

No action needed.

---

### C8 — HIGH: partial-file-delete race on rapid cancel → restart (NEW)

**Where:** `ModelManager.swift:483-510` (background cleanup Task) combined with
`:287-299` (`download()` creates model directory synchronously).

**Failure mode.** The cleanup Task does:

```
waitForProcessExit(proc, 2.0)     // up to 2s
Darwin.kill(pid, SIGKILL) + 100ms // if needed, up to ~2.1s total
FileManager.removeItem(capturedModelDir)
```

Meanwhile, the UI state is reset synchronously at `:517-519` so
`isDownloadActive == false` immediately. The user can click "Download" again
right away, which calls `download()`:

- `:287` `state = .downloading(progress: 0, bytesPerSec: 0)` — fine.
- `:296-299` `createDirectory(at: modelDirectory, withIntermediateDirectories: true)` — fine.
- `:338-347` spawns a new Python subprocess that writes into `modelDirectory`.
- `:350` assigns new `process` to `activeDownloadProcess`.

Now there are two timelines:
- T+0: old cancel starts, `Task.detached` running.
- T+0.5s: user clicks Download again, new subprocess starts writing to the same dir.
- T+1.2s: old subprocess finally exits (it was mid-TLS-read).
- T+1.3s: `waitForProcessExit` returns true. Cleanup Task proceeds.
- T+1.4s: `FileManager.removeItem(capturedModelDir)` **deletes the directory
  that the new download is actively writing into**.

The new `Process`'s `snapshot_download` call will either (a) fail mid-write
with an I/O error surfaced as "Download failed", or (b) silently re-create the
directory and continue, leaving a gap of missing files that verification will
catch as `.corrupt`. Best case: user sees a cryptic error and retries. Worst
case: the HuggingFace cache-to-local-dir copy is partially complete, and the
new `snapshot_download` returns success with a partial file set.

**Repro.**
1. Start `.onnx` download.
2. Wait ~5s for subprocess to start writing files.
3. Click Cancel.
4. Immediately (within 2.1s) click Download again.
5. Observe: the new download fails or produces a corrupt model.

**Why round-4 tests missed this.** The integration test is deferred to QA.
None of the unit tests drive a real subprocess through cancel → restart.
`test_cancelDownload_allowsSubsequentBackendSwitch` at `:664` verifies state is
valid for a *switch*, but does not exercise a *redownload of the same backend*.

**What EN should do (pick one):**
- **Option A — gate the new download on cleanup.** Store the cleanup `Task`
  reference, and at the top of `download()` `await cleanupTask?.value`. This
  serialises cancel-cleanup and redownload. Downside: user-visible pause of up
  to 2.1s on rapid retry.
- **Option B — pass a generation token.** Increment a generation counter at
  each `download()` call, capture it at cleanup start, and in the cleanup Task
  check `generation == captured` before `removeItem`. If it changed, skip the
  delete (a new download owns the dir now). This is the cleanest fix and
  matches the SwiftUI "stale closure" pattern.
- **Option C — check isDownloadActive in the cleanup Task before delete.**
  Hop to `@MainActor` inside the Task before `removeItem`; if
  `state == .downloading`, skip deletion. Simpler than Option B.

Option C is the minimum viable fix. Two lines:

```swift
// before removeItem in the Task.detached
let isRestarted = await MainActor.run { isDownloadActive }
guard !isRestarted else {
    logger.info("Skipping partial-dir cleanup — new download in progress")
    return
}
```

Recommend Option C for this branch; file a ticket for Option B if we want the
cleaner design later.

**Severity:** HIGH. This is a real data-loss / confusing-UX path. Not a
CRITICAL because the user can retry from scratch and eventually succeed, and
because the window is ~2 seconds (only reached by fast-clicking users or
automated testing). But it is reachable and it is introduced by this round's
H5-mitigation delete.

---

### M6 — MEDIUM: PID reuse window in SIGKILL escalation (NEW)

**Where:** `ModelManager.swift:488` — `Darwin.kill(pid, SIGKILL)`.

**Failure mode.** After `proc.terminate()` sends SIGTERM:
- The process may exit and be reaped by `terminationHandler` at `:391-393`.
- The kernel can now recycle `pid` for a new, unrelated process.
- Meanwhile the Task.detached's `waitForProcessExit` checks `proc.isRunning`.
  Because `Process` caches the termination state after `terminationHandler`
  fires, `isRunning` will return false after reap, so the SIGKILL branch is
  not entered. Good.
- But what if `proc.isRunning` returns true *during* the poll but then the
  process exits and is reaped *between* the last poll and `Darwin.kill(pid, ...)`?
  In the 2-second window before timeout, a poll sees running → 100ms sleep
  → process exits → pid is reused by another app → timeout elapses → Task
  sees `!proc.isRunning` after the loop → `return !proc.isRunning` is `true`
  (not kill path). OK.
- **Real window:** after the 2s timeout, `waitForProcessExit` returns false
  (still running). `Darwin.kill(pid, SIGKILL)` fires. Between the last
  `proc.isRunning` check inside the loop and the `Darwin.kill` call, the
  process could finish, get reaped, and pid could be reused. Typically this
  window is sub-millisecond, but it exists.

**Impact.** A SIGKILL sent to a reused PID that belongs to another app. On
macOS, `kill` requires the sender to own the target PID or be root. Since
Murmur is not root and the reused pid likely belongs to another user process,
`kill` will return `EPERM`. No harm done. But if the reused pid is another
child of Murmur (unlikely — we only spawn python), we could kill our own
unrelated subprocess.

**Mitigation options:**
- Ignore: EPERM is silently discarded, worst case is we don't kill the hung
  process (but it already exited so no harm).
- Use `kill(pid, 0)` + `errno == ESRCH` check first to verify pid is still ours
  — but this has the same TOCTOU issue.
- Structurally: keep a file-descriptor handle open on the process via `kqueue`
  `EVFILT_PROC` and use that to wait for exit without polling. Much cleaner,
  larger change.

**Severity:** MEDIUM-low. Real but extremely narrow. Recommend documenting in a
comment and moving on. If the project grows more subprocess plumbing, swap to
`kqueue`-based wait in a separate refactor.

**What EN should do:** Add a comment at `:488` noting the theoretical PID-reuse
window and that EPERM is accepted as "someone else's pid now, process is
already gone, we don't care." No code change required.

---

### H9 — HIGH: unit tests still do not cover SIGKILL or partial-file delete paths

**Where:** `Tests/B3B4FixTests.swift:608-680` (CancelDownloadTests).

**What's covered.** State reset synchronously: `state == .notDownloaded`,
`isDownloadActive == false`, `statusMessage == ""`, `setActiveBackend(other)`
accepted after cancel.

**What's NOT covered.**
- `proc.terminate()` is never called (no real Process).
- `Darwin.kill(..., SIGKILL)` is never called.
- `FileManager.removeItem(capturedModelDir)` is never called.
- `waitForProcessExit` is never invoked.
- The cleanup Task is never spawned.

EN's handoff 067 acknowledges this and points to 068 (QA integration ask).
That's fine — unit tests can't realistically spawn a subprocess that writes to
the disk without leaving test artifacts. But this means:

1. **If QA skips or defers 068, we ship blind.** The cancel-restart race (C8),
   the SIGKILL escalation, and the partial-dir deletion are all code paths
   that have never been exercised in CI.
2. Any regression in `cancelDownload()` that changes the synchronous/async
   split will not be caught by the unit tests. A future refactor could silently
   break the SIGKILL escalation (e.g. moving the delete out of the Task into
   an unreachable branch) and all 272 tests would still pass.

**What EN / CR / PM should do:**
- **Block the ship on 068 landing** — or at minimum have QA manually exercise
  the cancel path with a large download (`.huggingface`, 4 GB) and verify no
  zombie `snapshot_download` python process survives past 3 seconds.
- Document this explicitly in the PM ship-gate checklist: "handoff 068
  integration test executed and passing" is a hard prerequisite.

**Severity:** HIGH, not CRITICAL — the individual fixes all look correct on
inspection, but the lack of any real-subprocess test means we're shipping on
inspection alone.

---

### Integration reality check (DA task item 4)

Asked to enumerate real-world breakage conditions for the SIGTERM → Task →
poll → SIGKILL → rmdir pipeline:

1. **Network timeout mid-download.** Python `requests` raises; `snapshot_download`
   may return an exception or hang on retries. `Process.isRunning` remains
   true. SIGTERM is delivered on next bytecode dispatch; if Python is sleeping
   in urllib3 retry backoff, SIGTERM wakes it. Cleanup succeeds. **OK.**
2. **User clicks cancel twice rapidly.** Second call hits
   `if let proc = activeDownloadProcess, proc.isRunning` at `:475`. Because
   `activeDownloadProcess = nil` at `:512` is synchronous after the first call,
   the second call's `if let` fails and it skips the terminate branch entirely.
   State is reset again (no-op, already reset). **OK.** But note: the first
   call's cleanup Task is still running, and the second call spawns *no*
   second Task. No double-delete race. **OK.**
3. **App backgrounded during the 2s poll.** `Task.detached` runs on a global
   executor, not tied to app lifecycle. It will continue running. `Darwin.kill`
   works regardless of foreground/background. FileManager works. **OK.**
4. **Mac goes to sleep during the 2s poll.** `Task.sleep` is suspended; poll
   resumes on wake. `Process` is suspended by the OS during sleep; `isRunning`
   remains true (kernel process table still has it). After wake, the loop
   resumes, process exits (since it had been running), cleanup completes.
   **OK, but** if the user's machine sleeps for hours, the cleanup Task has
   been waiting for hours. If the user restarts Murmur during sleep (unlikely
   but possible via wake-from-sleep crash), the cleanup Task dies with the
   process and the partial dir is orphaned. **Minor orphan-file risk;** not
   worth fixing.
5. **App crashes during the 2s poll.** Same as above — orphan partial dir.
   Refresh logic handles this on next launch: `refreshState()` reports
   partial size, but `modelPath(for:)` returns nil (missing files), so it
   shows "partial download, click to resume." **OK by existing design.**
6. **User deletes ~/.cache/huggingface manually during download.** Python
   errors. SIGTERM works normally. Irrelevant to this branch. **OK.**
7. **Disk full during partial-dir removal.** `removeItem` throws, logged, no
   crash. Partial dir remains. `refreshState()` on next launch shows partial
   size. **OK.**
8. **Rapid cancel → redownload same backend (the C8 bug).** See C8. **BROKEN.**

So: one real breakage (C8), one minor orphan path (sleep during poll), rest
OK. Not bad for this much moving machinery.

---

### M7 — NIT: `waitForProcessExit` can return before timeout without final poll

**Where:** `ModelManager.swift:530-538`.

```swift
for _ in 0..<maxIterations {
    if !proc.isRunning { return true }
    try? await Task.sleep(for: pollInterval)
}
return !proc.isRunning
```

The loop iterates `maxIterations` times (20 for 2s timeout), sleeps AFTER the
running check, then the final `return !proc.isRunning` runs *without* sleeping
after the last iteration's sleep — so there IS a final check. Actually correct.

But the timing is subtly off: on iteration 0, we check then sleep. On
iteration 19, we check then sleep. Then we check again. That's 20 checks in
the loop + 1 final check = 21 checks with 20 sleeps of 100ms each = 2.0s total
elapsed before the final return. That's fine.

Edge case: if `pollInterval` sleeps throw (cancellation), `try?` swallows it
and we continue immediately. A cancelled Task would spin through 20 checks
without sleeping → ~0ms return. Since the Task is not cancelled externally
(it's detached and we don't store a handle), this path is unreachable.

No action. Non-blocking.

---

### Betting-money prediction (DA task item 5)

If I had to bet money on what breaks in QA / UT:

1. **C8 (cancel → redownload race)**. Near-certain. First user to double-click
   Download after a cancel will see a cryptic error. Probability: 80%.
2. **H5 / partial-file UI state on a machine where the user killed the app mid-download
   (orphan dir without our cleanup running).** On next launch, the inactive-backend
   branch still uses `modelPath(for:) != nil`, so if the orphan dir happens to have
   all required filenames (even if truncated), UI shows "Downloaded." Probability: 20%.
3. **Zombie subprocess on machines where Python was compiled against an old OpenSSL
   that doesn't respect SIGTERM fast.** The SIGKILL escalation is EXACTLY for this,
   but the model-dir cleanup happens before the user can observe whether it actually
   worked. Probability of user-visible symptom: low, 5%.
4. **C7 XCTest assertion firing in a dogfood Debug build because someone linked
   XCTest as a diagnostic dependency.** Extremely unlikely. 1%.

Items 3 and 4 are well within acceptable risk. Item 2 is pre-existing (H5).
Item 1 (C8) is the one to fix.

---

## summary

EN's round-4 addresses all three of DA's round-2 CRITICALs (C5, C6, C7) plus
M3 correctly. Verified:

- **C5 LGTM.** Guard is right, tests are right, initial-launch path confirmed safe.
- **C6 LGTM (structure).** SIGKILL escalation via `Task.detached` correctly
  avoids `self` capture, `proc`/`pid` are captured by value, cleanup survives
  ModelManager deallocation.
- **C7 LGTM (pragmatic).** XCTest assert is structural enough for Debug.
- **M3 LGTM.** dead `downloadTask` removed.

But the new cleanup Task introduces **one new HIGH bug** that DA asks EN to fix
before QA:

- **C8 (HIGH, new)**: the partial-dir removal races with a new download of the
  same backend started within the 2.1s cleanup window. Recommended fix: check
  `isDownloadActive` from inside the `Task.detached` before `removeItem`
  (Option C, ~4 lines).

Plus minor items:

- **M6 (MEDIUM)**: theoretical PID-reuse window in SIGKILL escalation; accept
  with a code comment.
- **H9 (HIGH)**: integration-test gap (068) means SIGKILL + rmdir are shipping
  unexecuted in CI. Hard-block the ship on 068 executing and passing.
- **M7 (NIT)**: `waitForProcessExit` timing analysis — correct, no change needed.

Status: **CHG:2** — fix C8 (blocking), add a comment for M6 (trivial). H9 is a
PM/QA gate, not an EN code change.

Once C8 is fixed and 068 is exercised, DA will sign LGTM for round-3.

---

## resolution

EN addressed C8 and M6 in commit `fa53a81` (round-5).
See `071_EN_CR_DA_b3-b4-round5.md` for full details.

- **C8**: Fixed via Option C. `removePartialModelDirectory` hops to `@MainActor` before
  `removeItem` and skips deletion when `isDownloadActive` is true. Two deterministic
  unit tests in `CancelDownloadCleanupRaceTests` prove the skip and the remove paths.
- **M6**: Comment added above `Darwin.kill(pid, SIGKILL)` documenting the PID-reuse
  window and EPERM acceptance. No code change.
- **H9**: Not fixed on this branch. PM ship gate blocks on 068 executing.

DA re-challenge of round-5 fixes: see `072_DA_EN_b3-b4-round5-challenge.md`.
Status: **LGTM.** Branch moves to QA/UT. Two non-blocking residuals filed
(backend-aware guard, test-hygiene on real user dir). H9/068 remains the
PM ship-gate.
