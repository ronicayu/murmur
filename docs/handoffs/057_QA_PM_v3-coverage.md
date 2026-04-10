# Handoff 057 — QA → PM: V3 Phase 1 Coverage Report

**From:** QA (`qa-test-engineer`)
**To:** PM (`staff-product-manager`)
**Status:** RDY
**Date:** 2026-04-10

---

## Summary

Full QA test pass on V3 Phase 1 streaming voice input. Added 48 new tests across 8 new test suites targeting identified coverage gaps. Total project test count: 170 → 218 (48 new). All new tests pass. One pre-existing flaky test (`M4AAutoDeleteTests::test_beginTranscription_success_deletesM4AFile`) fails intermittently under load — this is not caused by V3 changes and was failing before this QA pass.

One minimal production change was required for testability: `StreamingTranscriptionCoordinator.fullPassTimeoutSeconds` was converted from a static constant to an injectable `init` parameter (`fullPassTimeoutOverride: TimeInterval? = nil`, defaults to 30s). This preserves all production behaviour while enabling the full-pass timeout test to run in milliseconds rather than 30 seconds.

---

## Coverage Before This Pass

| Area | Prior Coverage |
|------|---------------|
| AudioBufferAccumulator | Basic threshold, flush, multi-chunk |
| StreamingTranscriptionCoordinator state machine | idle→streaming, cancel, endSession→done, no-op on double beginSession |
| InjectedRangeTracker | Initial range, accumulation, startOffset preservation |
| CPULoadMonitor | Low-load no-fire, stop prevents callbacks |
| FocusGuard | None |
| StreamingSessionState (.failed case) | None |
| Electron blocklist logic | None |
| Edit distance / ratio | None |
| Full-pass timeout path (.timedOut) | None |
| Full-pass skip when text identical | None |
| Post-inject cursor check (NEW-P1-1) | Indirectly via simulateTrackerInvalidation only |
| CPU fallback flag (didTriggerCPUFallback) | None |

---

## New Tests Added

### Suite 10: InjectedRangeTrackerEdgeCaseTests (6 tests)
- `test_tracker_invalidate_setsFlag` — invalidate() sets flag, initially false
- `test_tracker_invalidate_isIdempotent` — double-invalidate stays true (no toggle)
- `test_tracker_expectedNextOffset_equalStartPlusLength` — verifies computed property
- `test_tracker_expectedNextOffset_withNoInjections_equalsStartOffset` — zero-injection base case
- `test_tracker_axRange_stillReportsCorrectRange_afterInvalidation` — range values unchanged after invalidation
- `test_tracker_recordInjection_withZeroLength_isNoOp` — zero-length injection guard

### Suite 11: StreamingSessionStateTests (7 tests)
- `test_state_idle_equalsIdle`
- `test_state_done_equalsDone`
- `test_state_cancelled_equalsCancelled`
- `test_state_failed_withSameMessage_isEqual` — `.failed("x")` == `.failed("x")`
- `test_state_failed_withDifferentMessages_isNotEqual` — `.failed("a")` != `.failed("b")`
- `test_state_idle_notEqualDone` — cross-case inequality
- `test_state_streaming_notEqualFinalizing` — cross-case inequality

### Suite 12: StreamingCoordinatorExtendedStateMachineTests (8 tests)
- `test_coordinator_endSession_whileIdle_isNoOp` — guard on endSession
- `test_coordinator_cancelSession_whileIdle_transitionsToCancelled` — cancel from any state
- `test_coordinator_cancelSession_whileAlreadyCancelled_staysCancelled` — idempotent cancel
- `test_coordinator_cpuFallback_initiallyFalse` — didTriggerCPUFallback flag
- `test_coordinator_fullPass_doesNotReplace_whenTextIdentical` — edit distance ≤ 0.01 skips replaceRange
- `test_coordinator_fullPassTimeout_transitionsToDone_withoutReplacement` — NEW-P1-2: timeout path → .done, no replaceRange
- `test_coordinator_fullPass_skipped_whenNoWavURL` — no streaming chunks → always reaches .done
- `test_coordinator_simulateTrackerInvalidation_whileIdle_doesNotCrash` — nil tracker safety

### Suite 13: FocusGuardTests (5 tests)
- `test_focusGuard_secondsSinceFocusLost_nilBeforeAnyEvent` — initial state
- `test_focusGuard_stop_clearsFocusTimer` — stop() clears focusLostAt
- `test_focusGuard_onEvent_firesReturnedAfterLeft` — full focus-left → focus-returned sequence
- `test_focusGuard_doubleFocusLeft_firesOnlyOnce` — idempotent focus-left (guard against double-fire)
- `test_focusGuard_focusReturnedWithoutPriorLoss_firesNoEvent` — no spurious events on initial focus

### Suite 14: CPULoadMonitorEdgeCaseTests (2 tests)
- `test_cpuMonitor_loadNormalising_resetsTimer_preventsCallback` — impossible threshold never triggers
- `test_cpuMonitor_startStop_multipleCycles_noDoubleFire` — stop() freezes count; restart re-enables

### Suite 15: ElectronBlocklistTests (9 tests)
- VSCode, Obsidian, Slack, Discord, Todesktop, Figma are blocked
- Safari, Xcode, empty bundle ID are not blocked
- Mirrors `isFrontmostAppIncompatibleWithAXReplace` prefix logic (private method not directly testable)

### Suite 16: EditDistanceRatioTests (6 tests)
- Identical strings → 0.0
- Both empty → 0.0
- One empty → 1.0
- Single substitution → 1/3
- Completely different → 1.0
- Just-above 0.01 threshold (11-char, 1 edit) → triggers replacement

### Suite 17: AudioBufferAccumulatorEdgeCaseTests (5 tests)
- Zero-length buffer append is no-op
- Flush on empty returns nil
- Feed two chunks + remainder: remainder flushed correctly
- Replacing onChunkReady mid-accumulation: new handler fires, old does not
- Setting onChunkReady to nil suppresses delivery

---

## Gaps Not Automated (with reasons)

| Gap | Reason Not Automated |
|-----|---------------------|
| Focus guard → abandon session after 10s | Would require 10s wall-clock wait; impractical for unit tests. The `handleFocusEvent` code path is covered structurally; the 10s timeout is a `Task.sleep` that we trust. Manual testing scenario provided below. |
| Post-inject AX cursor verification (NEW-P1-1) | `resolveCurrentCursorOffsetAX()` calls live AX APIs; cannot be injected. The invalidation *effect* is tested via `simulateTrackerInvalidation`. |
| Backstop timeout in `waitForStreamingDone` | Logic lives in `AppCoordinator.waitForStreamingDone` which requires full `AppCoordinator` setup (audio, hotkey, etc.). The coordinator-level timeout (full-pass) IS tested. |
| Electron app blocklist via real `isFrontmostAppIncompatibleWithAXReplace` | Requires frontmost app to be a real Electron app — not automatable in CI. Tested via logic mirror in Suite 15. |

---

## Manual Test: Focus-Abandon After 10s

**Preconditions:** Streaming input enabled, recording in progress in a text app.
**Steps:**
1. Hold hotkey to begin recording (streaming mode). → **Expected:** Pill shows "Streaming..."
2. Switch to a different app (e.g., Finder) while still holding hotkey. → **Expected:** Streaming pauses (no further chunk injection).
3. Wait 11 seconds without returning focus. → **Expected:** Session cancelled; pill hides; state returns to idle.
4. Immediately return focus within 5 seconds instead of waiting 10s. → **Expected:** Session resumes; buffered chunks inject; no cancellation.

**Postconditions:** App returns to idle state.
**Priority:** High
**Reason not automated:** Requires 10s real-time wall-clock wait; not acceptable in a unit test suite.

---

## Production Code Change

**File:** `Murmur/Services/StreamingTranscriptionCoordinator.swift`

Changed `private static let fullPassTimeoutSeconds: TimeInterval = 30.0` to an injectable `let fullPassTimeoutSeconds: TimeInterval` initialised from a new `fullPassTimeoutOverride: TimeInterval?` init parameter (nil → defaults to 30s). This is a pure testability improvement with no behaviour change in production.

---

## Skipped Tests (7 — pre-existing)

The 7 skipped tests are pre-existing conditional skips (model-loaded guards in transcription service tests). No new skips introduced.

---

**out:** Test file at `Murmur/Tests/V3Phase1Tests.swift`. Production change at `Murmur/Services/StreamingTranscriptionCoordinator.swift`. Total 218 tests, 7 skipped (pre-existing), 0 new failures.
