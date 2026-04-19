---
from: CR
to: EN
pri: P1
status: LGTM
created: 2026-04-19
branch: fix/b3-b4-download-ui-bugs
---

## ctx

Round-4 CR re-review focused on C5/C6/C7/M3 fixes from commits 4009b74 and 7f0409f.
Prior CR LGTM at handoff 065 was countered by DA round-2 (066, CHG:3). EN addressed
all three CRITICALs in round-4 (067, RDY). This pass re-examines those specific fixes
and runs a full regression scan of the branch diff vs main in Murmur/.

Prior chain: 060, 061, 062, 063, 064, 065, 066, 067.

---

## out

**Overall verdict: LGTM**

All three DA CRITICAL findings (C5, C6, C7) are structurally fixed. M3 dead code is
removed cleanly. No new issues found in the full branch diff.

---

### C5 — same-value short-circuit (CONFIRMED CORRECT)

`ModelManager.swift:162` — `guard backend != activeBackend else { return true }` is
placed as the *first* check inside `setActiveBackend`, before the `isDownloadActive`
guard. Ordering is intentional and correct: the same-value case should return true
regardless of download state (requested backend is already active; nothing to do).
This is the right semantics.

No mutations, no UserDefaults write, no `committedBackendChange.send()` reach the
remaining lines on same-value call. All three paths DA cited as harmful are shut off.

Bypass scan: `activeBackend =` has exactly three assignment sites in the file —
line 167 (inside `setActiveBackend`, post-guard), line 244 (`init`, commented and
justified), and line 832 (`__testing_setActiveBackend`, DEBUG-only test seam).
No external callers can write `activeBackend` directly (`private(set)`). No bypass
paths found.

Three regression tests in `SetActiveBackendGuardTests`:
- `test_setActiveBackend_sameValue_returnsTrue` — return value contract
- `test_setActiveBackend_sameValue_doesNotFireCommittedBackendChange` — zero emissions
  after two same-value calls; this is the key safety proof DA required
- `test_setActiveBackend_sameValue_doesNotRewriteUserDefaults` — value and key unchanged

Tests are behavior-focused and directly prove the regression DA identified. LGTM.

---

### C6 — SIGKILL escalation in cancelDownload (CONFIRMED ADEQUATE WITH ONE NOTE)

Walk of the happy path (process exits cleanly after SIGTERM):
1. `capturedBackend` and `capturedModelDir` are snapshotted from the main actor before
   the background Task.
2. `proc.terminate()` sends SIGTERM synchronously.
3. `Task.detached { [logger] in ... }` — capture list is `[logger]` only. `proc` and
   `pid` are captured by value (both value types / reference to the already-captured
   `Process` ref). `capturedModelDir` (a URL, value type) is also captured by value.
   No retain of `self`. No retain cycle.
4. Background polls `proc.isRunning` at 100ms intervals for up to 2s.
5. On exit: deletes the model directory (H5 mitigation). Errors are caught and logged.
6. `activeDownloadProcess = nil`, `state = .notDownloaded`, `statusMessage = ""`
   happen synchronously on the main actor before Task.detached runs. UI unlocks
   immediately.

Walk of the SIGKILL escalation path (process survives SIGTERM):
1. `waitForProcessExit` returns false after 2s.
2. `Darwin.kill(pid, SIGKILL)` is called. The PID was captured before `proc.terminate()`
   and before the background Task began — the process is still alive (confirmed by
   `waitForProcessExit` returning false), so PID has not been recycled. The reuse
   window is only open after the process actually exits, which has not happened here.
   This is safe.
3. 100ms grace sleep allows OS to reclaim file handles.
4. Model directory deleted.

Partial-file deletion vs. concurrent `isModelDownloaded(for:)` on inactive backend:
`isModelDownloaded(for: backend)` for an inactive backend calls `modelPath(for:) != nil`
which does `FileManager.fileExists` on each required file. The delete and the
file-existence check could race. The race outcome: either the check runs before delete
and sees files (stale true), or during delete (partial removal, still true or false
depending on order), or after (false). The pre-delete stale-true case is the H5 scenario
that was already accepted as deferred/mitigated rather than fully fixed. This is not a
new problem introduced by this commit; it's the documented residual risk from H5 deferral.
The mitigation (delete on cancel) meaningfully shrinks the window. Acceptable.

One note (non-blocking): the `Task.detached` closure captures `proc` by value, which is
a reference type. The background task holds a strong reference to the `Process` object
for up to ~2 seconds after `cancelDownload()` returns and `activeDownloadProcess = nil`.
This is intentional and correct — the task needs the reference to poll `isRunning` and
to have called `terminate()`. No leak; the `Process` is released when the task completes.

Unit test for C6 (`test_cancelDownload_clearsStatusMessage`) proves synchronous UI-state
reset. SIGKILL path not unit-testable without a real subprocess; QA integration ask
correctly filed as 068. Acceptable boundary.

---

### C7 — test seam runtime assertion (CONFIRMED CORRECT)

`#if DEBUG` at line 807, `#endif` at line 834 — both `__testing_setState` and
`__testing_setActiveBackend` are inside the same DEBUG block. The functions do not
compile into release builds at all.

Within DEBUG builds, `assert(NSClassFromString("XCTestCase") != nil, ...)` fires in
-Onone (debug) configuration and is stripped in -O (release) — but since the entire
function body is already behind `#if DEBUG`, the assert is never reached in release
regardless. The guard is meaningful only in debug builds, where it provides structural
enforcement: a misuse (LLDB console, debug menu, future code path) crashes the process
immediately rather than silently corrupting state. This is the right trade-off and
matches DA's "option (b)" recommendation.

The comment block at lines 792-805 explains the design decision precisely. LGTM.

---

### M3 — dead downloadTask removed (CONFIRMED)

No `downloadTask` property or `downloadTask?.cancel()` call exists in any Swift source
file under Murmur/ (binary files in .build/ excluded). The comment at line 184-186
explains the removal. Clean.

---

### Regression scan — full branch diff vs main in Murmur/

Scanned all additions in the diff. No new concerns beyond what is tracked:

- `import Darwin` added for `Darwin.kill` — correct and scoped.
- `import Combine` added — already used (PassthroughSubject); was presumably
  implicitly available before. No issue.
- `modelDirectory(for:)` new overload introduced to support per-backend directory
  cleanup — correctly scoped, private access chain preserved via `FileManager` calls.
- No new signal handlers, no new `atexit` or `sigaction` calls.
- No new FileManager calls outside the already-reviewed cancel cleanup path.
- `waitForProcessExit` is `private static async` — no actor isolation, callable from
  `Task.detached`. Correct.
- All `@Published` properties are still written only on the main actor (cancelDownload
  is `@MainActor` via the class annotation). The background Task does not write any
  `@Published` properties. Correct.

---

## deferred items carried forward

| Item | Status | Note |
|------|--------|------|
| H5 full fix | DEFER | Mitigation in place (delete on cancel). Full fix needs PM scope. |
| H7 real-download integration test | DEFER to QA | Filed as 068. |
| H8 inactive-backend state tracking | DEFER | Broader than this branch. |
| M4 propagate setActiveBackend false to UI | DEFER | Unreachable path in onboarding; future hardening. |
| M5 refreshState on partial files | DEFER | Same root as H5; covered by H5 ticket. |

---

## asks

- **EN:** No blocking changes required. Branch is cleared for QA and UT.
- **QA:** Pick up 068 — integration test for the SIGKILL path and real cancel flow.
- **UT/PM:** No CR blockers. Branch ready for user acceptance and ship decision.

---

## resolution

Round-4 CR review complete. Status: LGTM.
All three DA CRITICAL findings from round-2 (C5/C6/C7) confirmed fixed.
M3 dead code confirmed removed.
No new issues found in full regression scan.

DA raised C8 and M6 in 070 after this LGTM. EN addressed both in round-5.
See `071_EN_CR_DA_b3-b4-round5.md` for fixes, test seam, and test results.
