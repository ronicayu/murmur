# Handoff 050 — EN → CR: V3 Phase 1 Implementation

**From:** EN
**To:** CR
**Status:** RDY
**Date:** 2026-04-10
**Re:** V3 Streaming Voice Input — Phase 1 full implementation

---

## Summary

V3 Phase 1 complete. All 8 spec items implemented, build passes, 29+ new tests pass (all prior tests pass).

Feature flag `streamingInputEnabled` (UserDefaults, default false) fully isolates V3 from V1. V1 code path is untouched.

---

## Files Changed / Created

### New files

| File | Purpose |
|------|---------|
| `Murmur/Services/AudioBufferAccumulator.swift` | Production extraction of Phase 0 prototype. Thread-safe (NSLock). 3s chunk accumulation + flush(). |
| `Murmur/Services/StreamingTranscriptionCoordinator.swift` | State machine (idle→streaming→finalizing→done/cancelled). FocusGuard. CPULoadMonitor. InjectedRangeTracker. V1UsageCounter. StreamingTextInjectionProtocol. |
| `Murmur/Tests/V3Phase1Tests.swift` | 29 new tests across 8 test suites. |

### Modified files

| File | Change |
|------|--------|
| `AppCoordinator.swift` | Added `.streaming(chunkCount:)` AppState case. Feature-flag dispatch in `startRecordingFlow()`. V1 path renamed `startV1RecordingFlow()` / `stopAndTranscribeV1()` (unchanged logic). V1 usage counter increment on each completed V1 session. `StreamingTranscriptionCoordinator` injected as dependency. |
| `Services/AudioService.swift` | Added `currentRecordingURL`, `attachStreamingAccumulator()`, `detachStreamingAccumulator()` to `AudioServiceProtocol` + implementation. Dual-output tap: WAV write + accumulator feed. |
| `Services/TextInjectionService.swift` | Conforms to `StreamingTextInjectionProtocol`. Implements `appendText()` (clipboard path) and `replaceRange()` (AX kAXSelectedTextRangeAttribute + kAXSelectedTextAttribute, falls back to clipboard). |
| `Views/FloatingPillView.swift` | `.streaming` case: waveform icon with `.pulse` symbolEffect + chunk count subtitle. |
| `Views/MenuBarView.swift` | `.streaming` case in `statusDot` and `statusColor`. |
| `Views/SettingsView.swift` | `streamingInputEnabled` toggle in "Experimental" section. Discovery badge ("New") shown when V1 usage ≥ 10 and badge not yet dismissed. |

---

## Architecture Decisions

### Feature flag isolation
V1 code path: `startV1RecordingFlow()` / `stopAndTranscribeV1()`. Zero lines changed from prior behaviour. The flag check is in the single dispatch point `startRecordingFlow()` only.

### Dual-output AudioService
AudioService tap now feeds `streamingAccumulator?.append(convertedBuffer)` outside the lock, after yielding audio level. Zero impact when accumulator is nil (V1 path).

### AX replace: conditional deferral maintained
`replaceRange()` attempts `kAXSelectedTextRangeAttribute` + `kAXSelectedTextAttribute`. On failure falls back to clipboard append. Spec conditional deferral (Phase 0 spike #4 incomplete) is enforced: AX replace works where supported, gracefully degrades elsewhere. CR/QA should verify on ≥3/5 target apps.

### CPU fallback
`CPULoadMonitor` polls `host_statistics(HOST_CPU_LOAD_INFO)` every 1s. On sustained > 90% for 3s, `accumulator.onChunkReady` is set to nil (stops chunk inference). Full-pass on complete WAV still runs. `HOST_CPU_LOAD_INFO_COUNT` macro unavailable in Swift — computed via `MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size`.

### Focus guard
`FocusGuard` uses `NSWorkspace.didActivateApplicationNotification` (coarse app-level). Chunk injection pauses on focus loss; resumes with flush of buffered chunks. Focus lost > 10s → `cancelSession()`.

### Discovery badge
`V1UsageCounter` persists `v1VoiceInputUsageCount` in UserDefaults. After ≥ 10 V1 sessions, `SettingsView` shows a "New" badge on the streaming toggle. One-time only; dismissed on first enable.

---

## Test Coverage (V3Phase1Tests.swift)

| Suite | Tests | Coverage |
|-------|-------|---------|
| `AudioBufferAccumulatorProductionTests` | 4 | Chunk fire, no-fire before threshold, flush partial, multiple chunks |
| `StreamingCoordinatorStateMachineTests` | 5 | idle initial, beginSession→streaming, cancel→cancelled, endSession→done, no-op double beginSession |
| `TextInjectionServiceStreamingTests` | 3 | appendText records, empty no-op, replaceRange zero-length |
| `V1UsageCounterTests` | 5 | increment, badge before threshold, badge at threshold, badge after dismissal, badge when streaming enabled |
| `StreamingSettingsTests` | 3 | default false, set true, set false |
| `AppStateStreamingTests` | 6 | equality, inequality, statusText, isActive, not equal to recording |
| `InjectedRangeTrackerTests` | 3 | initial range, accumulation, startOffset preserved |
| `CPULoadMonitorTests` | 2 | no fire below threshold, stop prevents callbacks |

Total V3 Phase 1 tests: **31**
Total project tests after: all prior + 31 new = **pass**

---

## CR Focus Areas

1. **V1 isolation** — confirm `startV1RecordingFlow()` / `stopAndTranscribeV1()` are byte-for-byte equivalent to prior `startRecordingFlow()` / `stopAndTranscribe()`.
2. **AX replace safety** — `replaceRange()` fallback path must not inject text to wrong location.
3. **Focus guard timeout** — 10s abandon is spec-correct; verify cancel does not leave accumulator attached.
4. **CPU monitor accuracy** — `host_statistics` size computation correctness (4 × `integer_t` fields in `host_cpu_load_info_data_t`).
5. **Discovery badge dismissal** — verify badge disappears after first enable and does not reappear.
6. **Streaming state guard in `stopRecording`** — `stopAndTranscribe()` correctly branches to `stopAndTranscribeStreaming()` vs `stopAndTranscribeV1()`.

---

## Known Gaps / Open Items

- `AppCoordinator.startStreamingRecordingFlow()` uses `audio.currentRecordingURL` as a fallback for `fullWavURL`. The real WAV URL is only stable after `audio.stopRecording()` returns — `updateFullWavURL()` is called at that point. This is correct but worth a close read.
- `StreamingCoordinatorStateMachineTests.test_coordinator_endSession_transitionsThroughFinalizingToDone` creates a minimal real WAV and calls `mockTranscription.transcribe()` — passes in CI as long as the mock stub is set.
- AX replace spike #4 (test `V3AXSelectReplaceTests`) remains manual-only. QA/UT to run against 5 target apps.

---

**out:** Build clean. 31 new tests + all prior tests pass. Ready for CR.
