# Handoff 056 — EN → CR / DA: V3 Re-review P1 Fixes

**From:** EN
**To:** CR, DA
**Status:** RDY
**Date:** 2026-04-10
**Re:** V3 Streaming — DA-055 NEW-P1-1 + NEW-P1-2 fixes

---

## NEW-P1-1: Post-inject cursor verification ✓

**File:** `Services/StreamingTranscriptionCoordinator.swift`

`handleChunkTranscription` now performs a **second** AX cursor check after `appendText` returns. The ~1500ms clipboard round-trip in `appendText` is no longer a blind window — if the user moves the cursor during injection, the tracker is invalidated immediately rather than waiting for the next chunk's pre-inject check.

```swift
// After appendText + recordInjection:
if let expectedNext = self.rangeTracker?.expectedNextOffset {
    let actualOffset = self.resolveCurrentCursorOffsetAX()
    if actualOffset != nil && actualOffset != expectedNext {
        self.rangeTracker?.invalidate()
    }
}
```

Single-chunk sessions are now covered: the post-inject check catches cursor movement even when no subsequent chunk triggers a pre-inject check.

---

## NEW-P1-2: waitForStreamingDone backstop timeout ✓

**File:** `AppCoordinator.swift`

`waitForStreamingDone` now wraps the Combine-based `for await` loop in a `withTaskGroup` race against a 35s backstop timer. If the coordinator stalls without emitting state (task starvation, deadlock, or any bug preventing the `withTaskGroup` timeout inside `runFullPass` from firing), the backstop cancels the session unconditionally.

Timeline:
- 15s → "Still refining" warning (unchanged)
- 30s → inner deadline cancels (unchanged)
- 35s → backstop cancels (NEW — independent of state emission)

`streamingDoneBackstopSeconds` is a static constant on `AppCoordinator`.

---

## Not modified

- DA-P2-1 (`resolveCurrentCursorOffsetAX` duplication) — deferred to Phase 2 extraction per CR+DA consensus.

---

## Modified files

- `Murmur/Services/StreamingTranscriptionCoordinator.swift`
- `Murmur/AppCoordinator.swift`

---

## in

- `docs/handoffs/054_CR_EN_v3-rereview.md`
- `docs/handoffs/055_DA_EN_v3-rereview.md`

## out

`docs/handoffs/056_EN_CR_DA_v3-p1-fixes.md` — both P1 fixes applied, ready for re-review.
