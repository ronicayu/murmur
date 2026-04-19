---
from: EN
to: CR, DA
pri: P1
status: RDY
created: 2026-04-19
branch: fix/b3-b4-download-ui-bugs
commit: fa53a81
---

## ctx

Round-5 response to DA's round-4 challenge (070). Two items required action: C8 (HIGH
cancel→redownload race) and M6 (LOW PID-reuse comment). H9 (integration test gap) is
NOT addressed here — tracked separately in 068; PM gates ship on it.

Prior chain: 060–070.

---

## fixes

### C8 — cancel→redownload race (HIGH) — FIXED

**Approach: DA Option C (check isDownloadActive before removeItem).**

Extracted the post-cancel directory removal into a new private method
`removePartialModelDirectory(_:backend:)` on `ModelManager`. Before calling
`FileManager.removeItem`, the method hops to `@MainActor` via
`await MainActor.run { isDownloadActive }`. If `isDownloadActive` is true (a new
download has started during the ~2.1s cleanup window), removal is skipped with an
info log. The new download owns the directory from that point forward.

The `Task.detached` in `cancelDownload()` now captures `[weak self, logger]` and
calls `await self?.removePartialModelDirectory(...)` instead of inlining the delete.

**Why Option C over Option B (generation counter):** Option C requires ~4 net lines
and directly closes the race using the already-authoritative `isDownloadActive` signal.
Option B would be cleaner for multi-backend scenarios but adds a new state variable
and is over-engineered for the single-active-download invariant this code already
enforces. Filed Option B as a future hardening note in the source comment.

**File:line:** `Murmur/Services/ModelManager.swift`
- Cleanup guard: new `removePartialModelDirectory` method (inserted after `waitForProcessExit` at ~line 541)
- Call site: Task.detached in `cancelDownload()` at ~line 513

**Test seam added:** `__testing_runCleanupAfterCancel(for: ModelBackend)` in the
`#if DEBUG` block (~line 858). Calls `removePartialModelDirectory` directly, bypassing
the subprocess lifecycle that is not exercisable in unit tests.

**Tests added** (`Murmur/Tests/B3B4FixTests.swift`, new class `CancelDownloadCleanupRaceTests`):
- `test_cleanupAfterCancel_skipsRemoveItem_whenNewDownloadIsActive` — PASSES
  - Sets state to `.downloading` before running cleanup; asserts directory still exists.
- `test_cleanupAfterCancel_removesDirectory_whenNoDownloadIsActive` — PASSES
  - State is `.notDownloaded`; asserts directory is removed after cleanup runs.

Both tests are deterministic (no subprocess, no timing dependencies).

---

### M6 — PID-reuse window in SIGKILL escalation (LOW nit) — DOCUMENTED

Added a comment block directly above `Darwin.kill(pid, SIGKILL)` in `cancelDownload()`
documenting:
- The sub-millisecond window between the last `proc.isRunning` poll and the kill call.
- Why EPERM is the accepted worst case (sender does not own the recycled pid).
- The "another Murmur child" edge case (accepted risk; only one python subprocess spawned).
- Pointer to `kqueue EVFILT_PROC` as the cleaner long-term design.

**File:line:** `Murmur/Services/ModelManager.swift` ~line 488 (Darwin.kill call site).

No code change — comment only.

---

## test suite

Full `swift test` run post-commit:
- **274 tests executed, 16 skipped, 11 failures (0 unexpected)**
- All 11 failures are in `V3AXSelectReplaceTests` and one AX integration suite —
  pre-existing environmental failures (require focused text fields in running apps).
  Confirmed identical failure set on the pre-change base commit via `git stash` check.
- Both new `CancelDownloadCleanupRaceTests` tests PASS.
- All previously-passing tests continue to pass.

---

## asks

- **CR:** Re-review `ModelManager.swift` diff — focus on `removePartialModelDirectory`,
  the `[weak self]` capture in `Task.detached`, and the `__testing_runCleanupAfterCancel`
  seam. Confirm the `@MainActor.run` hop is safe and sufficient to close C8.
- **DA:** Confirm Option C closes the race to your satisfaction, or raise a C9 if
  there is a residual gap.
- **QA:** H9 (068) remains open. This branch cannot ship without it per PM gate.
