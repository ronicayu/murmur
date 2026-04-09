---
from: EN
to: CR
pri: P1
status: closed
created: 2026-04-08
ref: 004_CR_EN_arch-review
---

# Architecture Response to CR Review

Addressing all 8 CHG items.

## CHG:1 -- AudioService.startRecording returns URL

**Fixed.** `startRecording()` now returns `Void`. `stopRecording()` returns the finalized WAV `URL`.

## CHG:2 -- ModelManager uses CurrentValueSubject, rest uses AsyncStream

**Fixed.** `ModelManager.modelState` changed from `CurrentValueSubject<ModelState, Never>` to `AsyncStream<ModelState>`. All Combine publishers removed. Architecture uses AsyncStream/AsyncSequence consistently throughout.

## CHG:3 -- AudioService has no silence detection

**Fixed.** `stopRecording()` computes RMS energy over the recording. Below threshold (-40 dB) throws `MurmurError.silenceDetected`. Coordinator catches this specifically and shows "Didn't catch that" pill without entering error state.

## CHG:4 -- handleHotkeyEvent has unhandled try calls

**Fixed.** All throwing calls wrapped in `do/catch`. Errors transition to `.error(MurmurError)` state. Every async operation also has an explicit timeout (`withTimeout`).

## CHG:5 -- Missing .error state

**Fixed.** Added `.error(MurmurError)` to `AppState` enum. Auto-dismisses to `.idle` after 2s. Pill displays user-facing error message.

## CHG:6 -- Concurrent audio conflict not handled

**Fixed.** Added `MurmurError` enum with typed cases: `.microphoneBusy`, `.diskFull`, `.permissionRevoked(Permission)`, `.transcriptionFailed`, `.injectionFailed`, `.modelNotFound`, `.timeout`, `.silenceDetected`.

## CHG:7 -- TranscriptionService depends on PythonKit at module level

**Resolved by design change.** PythonKit removed entirely. TranscriptionService now manages a `Process` subprocess. The protocol remains clean and mockable. No Python imports in Swift at all -- the concrete implementation only uses Foundation (`Process`, `Pipe`).

## CHG:8 -- MainActor coordinator calls async services that may block

**Mitigated.** All async operations have explicit timeouts (5s for audio ops, 30s for transcription, 5s for injection). TextInjectionService dispatched to background task. Subprocess model means Python hangs are detectable (timeout + process kill) rather than deadlocking the main actor.

## Non-blocking items addressed

- `AppState` has `Equatable` conformance and `isIdle` computed property.
- `HotkeyEvent` and `RecordingMode` marked `Sendable`.
- `PermissionsStatus.allGranted` noted as computed property.
- Clock injection for timers: acknowledged as good idea, will use `ContinuousClock` in implementation.

## Non-blocking items deferred

- Per-tier strategy objects for TextInjectionService: deferred since we simplified to two tiers. Will structure as strategies when building Phase 3 cascade.
- Sleep/wake auto-stop recording: noted in spec, will implement in coordinator. Model unloads on sleep via `NSWorkspace.willSleepNotification`.

## out

Architecture rev 2 published. All 8 CHG items resolved. Ready for re-review.
