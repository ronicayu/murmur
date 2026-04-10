---
from: DA
to: EN
pri: P1
status: done
created: 2026-04-10
---

## ctx

EN addressed all DA-052 challenges in handoff 053. This is DA's re-review of those fixes.
Files read: `StreamingTranscriptionCoordinator.swift`, `TextInjectionService.swift`,
`AppCoordinator.swift`, `Tests/V3Phase1Tests.swift`.

Overall verdict: **LGTM with three observations** — two are P1 risks that should be tracked,
one is a minor P2 code smell. No new P0s. The P0 fixes are structurally sound. Pipeline is
clear to proceed to QA/UT, but the P1 items below should be fixed before ship.

---

## Re-review: DA-052 fixes verified

### DA-P0-1: Electron incompatibility — LGTM

`isFrontmostAppIncompatibleWithAXReplace()` correctly gates `replaceRange` entry.
Bundle ID prefix list covers the known Electron apps. No clipboard fallback. Correct.

**Residual caveat (already noted in 053 as known):** the bundle ID list is best-effort;
spike #4 data still needed before full confidence. Tracked by EN as Phase 2 work.
Not a blocker.

---

### DA-P0-2: Cursor tracking — LGTM with new observation (see NEW-P1-1 below)

`expectedNextOffset`, `invalidated`, and the per-chunk AX cursor check are all present.
`runFullPass` correctly skips replace when `tracker.invalidated == true`.
Test 9b covers the invalidation path. Structurally correct.

**However:** see NEW-P1-1 — there is a subtle ordering gap introduced by the fix.

---

### DA-P1-3: Focus guard race — LGTM

`focusAbandonTask` is stored, cancelled in `focusReturned` **before** `isFocusPaused`
is cleared, and also cancelled in `cancelSession`. The race condition from 052 is
eliminated. Code reads clearly.

---

### DA-P1-4: Chunk WAV cleanup — LGTM

Both success and failure paths in `processChunkBuffer` call
`try? FileManager.default.removeItem(at: chunkURL)`. The `self == nil` early-exit
path was already covered. All three branches clean up. Correct.

---

### DA-P1-5: Full-pass timeout — LGTM with new observation (see NEW-P1-2 below)

`withTaskGroup` race pattern correctly races transcription vs. 30s timeout.
`finalizingStartedAt` is exposed for pill progress. 15s warning constant is defined.
The approach is correct.

**However:** see NEW-P1-2 — the `waitForStreamingDone` deadline path has a liveness gap.

---

### DA-P2: Integration tests — LGTM

`StreamingPipelineIntegrationTests` (9a, 9b) add meaningful end-to-end coverage.
`onTranscribe` per-call handler is a clean mock extension. Both tests verify the
right invariants: replace-when-different and skip-when-invalidated.

---

## New risks introduced or uncovered by the fixes

### NEW-P1-1: Cursor check and appendText are not atomic — cursor can move between them

**Location:** `StreamingTranscriptionCoordinator.handleChunkTranscription` (lines 498–519)

The cursor verification and the subsequent `appendText` call are sequential within a
`Task { @MainActor }` closure, but the AX query and the clipboard paste are separated
by an `await`:

```swift
// (1) AX cursor read — synchronous, but...
let actualOffset = self.resolveCurrentCursorOffsetAX()
// ... await suspends here before (2) ...
// (2) appendText → injectViaClipboard → Task.sleep(1500ms)
try await self.injection.appendText(textToInject)
```

Between step (1) and the Cmd+V paste actually landing in the target app, the user can
still move the cursor. The check only guards against cursor movement that happened
**before** this chunk's verification point — not movement that happens in the ~1500ms
clipboard restore window.

**Impact:** Not a regression from before (the old code had no check at all), and the
tracker correctly reflects the world at the time of the check. However, the check can
pass and the paste can still land at the wrong position if the user moves the cursor in
the ~1500ms window. The invalidation then only triggers on the **next** chunk's
verification. For a session with a single chunk followed by full-pass, this means the
full-pass replacement could run on an already-invalidated cursor position.

**Suggested fix:** After `appendText` returns, perform a second AX cursor check and
compare against `expectedNextOffset` again. If still mismatched, invalidate immediately
rather than deferring to the next chunk.

---

### NEW-P1-2: `waitForStreamingDone` deadline never fires if coordinator emits no new states

**Location:** `AppCoordinator.waitForStreamingDone` (lines 501–522)

The 30s deadline is checked **only inside the `for await state in stream` loop body**,
which only executes when `coordinator.$sessionState` publishes a new value. If the
coordinator is stuck in `.finalizing` without any state change (e.g., the full-pass
transcription hangs without timing out, or the `withTaskGroup` itself deadlocks),
the AsyncStream yields no new values and the deadline check at line 515 never executes.

The 30s `withTaskGroup` timeout inside `runFullPass` should prevent this in the happy
path. But if the `Task.sleep` for the timeout itself is never scheduled (e.g., task
starvation under high CPU load, or a bug that prevents the timeout task from being
added to the group), the coordinator silently hangs in `.finalizing` forever, and
`waitForStreamingDone` never returns.

**Evidence that this path is untested:** there is no test that simulates a coordinator
stuck in `.finalizing` to verify the AppCoordinator-level deadline fires correctly.

**Suggested fix:** Add a second, independent timeout in `waitForStreamingDone` using
`withTimeout` (the same helper already used elsewhere in `AppCoordinator`), so the
deadline is guaranteed to fire regardless of whether the coordinator publishes state:

```swift
try await withTimeout(seconds: 31, operation: "streaming-done") {
    for await state in stream { ... }
}
```

This also provides a test hook: inject a mock coordinator that never transitions out of
`.finalizing` and assert `waitForStreamingDone` returns within ~31s.

---

### NEW-P2-1: `resolveCurrentCursorOffsetAX` duplicated in two files

**Locations:**
- `AppCoordinator.resolveCurrentCursorOffset()` (lines 525–538)
- `StreamingTranscriptionCoordinator.resolveCurrentCursorOffsetAX()` (lines 705–720)

The logic is identical. Introduced when EN extracted the cursor query into the
coordinator for DA-P0-2. No correctness risk — but two identical AX cursor read
implementations will diverge over time if one is patched.

**Suggested fix:** Extract to a `AXCursorHelper` free function or static method in a
shared file, call from both sites. Or remove the `AppCoordinator` copy (it only feeds
`beginSession`'s `startOffset`) and pass through to the coordinator. Either is fine;
pick one in Phase 2.

---

## Summary

| # | Issue | Priority | Verdict |
|---|-------|----------|---------|
| DA-P0-1 | Electron incompatibility fix | P0 | LGTM (spike #4 deferred, known) |
| DA-P0-2 | Cursor tracker fix | P0 | LGTM (see NEW-P1-1) |
| DA-P1-3 | Focus guard race fix | P1 | LGTM |
| DA-P1-4 | Chunk WAV cleanup | P1 | LGTM |
| DA-P1-5 | Full-pass timeout fix | P1 | LGTM (see NEW-P1-2) |
| DA-P2 | Integration tests | P2 | LGTM |
| **NEW-P1-1** | Cursor check/paste non-atomic — gap for single-chunk sessions | **P1** | CHG |
| **NEW-P1-2** | `waitForStreamingDone` deadline liveness gap | **P1** | CHG |
| **NEW-P2-1** | `resolveCurrentCursorOffsetAX` duplicated | P2 | OBS |

**Conclusion:** P0 issues are resolved. Two new P1 issues found — neither is a
showstopper, but NEW-P1-1 is a correctness gap that violates spec §5 rule 3 in a
narrow single-chunk scenario, and NEW-P1-2 is a reliability gap that could cause
the UI to hang indefinitely if `withTaskGroup` internals misbehave. Recommend EN
address both before QA. Passing this to EN as **CHG:2**.

---

## in

- `docs/handoffs/052_DA_EN_v3-challenge.md`
- `docs/handoffs/053_EN_CR_DA_v3-fixes.md`
- `Murmur/Services/StreamingTranscriptionCoordinator.swift`
- `Murmur/Services/TextInjectionService.swift`
- `Murmur/AppCoordinator.swift`
- `Murmur/Tests/V3Phase1Tests.swift`
- `docs/team-protocol.md`

## out

`docs/handoffs/055_DA_EN_v3-rereview.md` — LGTM on all DA-052 fixes; CHG:2 for two
new P1 risks (cursor-check/paste non-atomic; waitForStreamingDone liveness gap).
