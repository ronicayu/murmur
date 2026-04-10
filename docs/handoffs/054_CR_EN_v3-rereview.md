# Handoff 054 — CR → EN: V3 Phase 1 Re-Review

**From:** CR
**To:** EN
**Status:** LGTM
**Date:** 2026-04-10
**Re:** V3 Streaming Voice Input — Phase 1 re-review of CR 051 fixes

---

## Verdict

**LGTM.** All five CR issues from 051 are correctly addressed. Three new findings introduced by the fixes are minor (one nit, two observations with no blocking impact). Phase 1 is clear to proceed to QA.

---

## CR Issue Verification

### CR-P0-1: Chunk temp WAV leak — FIXED ✓

`processChunkBuffer` (`StreamingTranscriptionCoordinator.swift` L469–486):

- Success path: `try? FileManager.default.removeItem(at: chunkURL)` called immediately after `transcribe()` returns, before `handleChunkTranscription`.
- Failure path: same cleanup before the `logger.warning` call.
- `self == nil` early-return path: cleanup was already present; preserved unchanged.

All three exit paths now clean up. The fix matches the pattern requested in 051 exactly.

---

### CR-P1-1: InjectedRangeTracker units changed to UTF-16 — FIXED ✓

`handleChunkTranscription` (L515):
```swift
self.rangeTracker?.recordInjection(length: textToInject.utf16.count)
```

`InjectedRangeTracker` doc comment (L206–209) now explicitly states "all offsets and lengths are in UTF-16 code units to match `kAXSelectedTextRangeAttribute`".

The `resolveCurrentCursorOffsetAX()` helper (L704–720) returns `cfRange.location + cfRange.length` directly from the AX value — already in UTF-16 units. The new `expectedNextOffset` computation (`startOffset + totalLength`) is therefore unit-consistent end-to-end.

---

### CR-P1-2: replaceRange fallback removal — FIXED ✓

`TextInjectionService.replaceRange` (L109–131): the `_ = try await inject(text: text)` fallback is gone. On AX replace failure, the method logs a warning and returns without throwing, leaving the streaming version intact. The doc comment explicitly attributes this to CR-P1-2 and DA-P0-1, explaining _why_ clipboard fallback is prohibited here. This is good defensive documentation.

---

### CR-P2-1: CPULoadMonitor.stop() marked @MainActor — FIXED ✓

`CPULoadMonitor.stop()` (L144–149) is annotated `@MainActor`. The shared mutable field `highLoadStart` is now exclusively accessed under `@MainActor` (both `evaluate()` and `stop()`). The Swift compiler can now statically verify this — the concurrency blind spot is closed.

Test callsites updated to `await MainActor.run { monitor.stop() }` (V3Phase1Tests.swift L496, L516). Consistent.

---

### CR-P2-2: waitForStreamingDone() Combine rewrite — FIXED ✓

`AppCoordinator.waitForStreamingDone()` (L482–523): the 100ms polling loop is replaced with an `AsyncStream` wrapping a `Combine` `.sink` on `coordinator.$sessionState`. The cancellable is captured inside the stream continuation closure and cancelled via `onTermination`, preventing a subscription leak when the stream is abandoned.

One observation: the `cancellable` is a local `let` inside the `AsyncStream` initializer closure. It's not stored in a `var` outside — this works because `AnyCancellable` lives until `cancel()` is called, and the closure captures it by strong reference until `onTermination` fires. Non-obvious but correct; a short comment would help future readers.

The DA-P1-5 deadline logic (lines 498–521) fits naturally into the same loop. The 30s wall-clock deadline approach is appropriate here since we want a hard cap independent of how many state transitions occur.

---

## New Findings Introduced by the Fixes

### NIT-1: `resolveCurrentCursorOffsetAX()` duplicates `AppCoordinator.resolveCurrentCursorOffset()`

`StreamingTranscriptionCoordinator` (L704–720) and `AppCoordinator` (L525–538) contain identical AX cursor-resolution logic (same 6 lines, same return type, same fallback). Handoff 053 notes this was intentionally extracted as a coordinator-internal helper for DA-P0-2.

Not blocking — the duplication is small and deliberately scoped. Flagging for Phase 2: a shared `AXCursorResolver` utility or a protocol extension on `NSRunningApplication` would eliminate drift risk. If either copy gets a bug fix, the other will be missed.

---

### OBS-1: InjectedRangeTracker cursor-check fires _before_ injection on every chunk

In `handleChunkTranscription` (L504–509), the cursor position is validated against `expectedNextOffset` before calling `appendText`. On the _first_ chunk, `expectedNextOffset == startOffset + 0 == startOffset`. The AX cursor should still be at `startOffset` (no text injected yet), so this is correct.

However, there is a TOCTOU gap: the cursor query and the subsequent `appendText` are two separate AX calls with no lock between them. A concurrent keypress between lines 505 and 513 could cause a false-negative invalidation or a missed invalidation. This is inherent to the AX polling approach and not introduced by this PR — it existed in the original cursor-offset logic. Calling it out so QA/UT can account for it in real-device testing.

---

### OBS-2: Integration test 9a has a timing dependency on mock cleanup order

`MockTranscriptionService.transcribe()` (V3Phase1Tests.swift L708) calls `try? FileManager.default.removeItem(at: audioURL)` to mirror real service behavior. This means `transcribeCallURLs` in test 9a captures URLs that are already deleted by the time assertions run. The URL count is still meaningful, but if a future test tries to re-read the files, it will fail silently. Low risk as written; noted for completeness.

---

## Summary

All P0 and P1 CR issues from 051 are correctly fixed with no regressions introduced. The Combine-based `waitForStreamingDone` is a solid improvement. The DA additions (Electron app guard, tracker invalidation, focus-abandon task, full-pass timeout) are well-integrated and do not conflict with the CR fixes.

The two new observations (TOCTOU cursor gap, duplicated AX resolver) are pre-existing concerns surfaced by the new code — not introduced by it. NIT-1 (code duplication) is the only actionable item, and it is Phase 2 material.

**Phase 1 is ready for QA.** Hand off to QA for test plan execution against the 5 target apps (spec §4), with particular attention to Electron apps (DA-P0-1) and CJK/emoji input (P1-1 regression check).

---

## in

- `docs/handoffs/051_CR_EN_v3-review.md`
- `docs/handoffs/053_EN_CR_DA_v3-fixes.md`
- `Murmur/Services/StreamingTranscriptionCoordinator.swift`
- `Murmur/Services/TextInjectionService.swift`
- `Murmur/AppCoordinator.swift`
- `Murmur/Tests/V3Phase1Tests.swift`

## out

`docs/handoffs/054_CR_EN_v3-rereview.md` — All CR 051 issues verified fixed. LGTM. Ready for QA.
