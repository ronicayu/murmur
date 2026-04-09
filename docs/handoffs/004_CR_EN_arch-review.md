---
from: CR
to: EN
pri: P1
status: done
created: 2026-04-08
---

## ctx

Architecture review of `docs/architecture.md` against `docs/specs/murmur-v1.md` rev 2. Overall: solid decomposition, clean protocol boundaries, good separation of concerns. Several issues need addressing before implementation.

## Verdict: CHG:8

---

## API Design

**Good:** Protocols are clean and testable. Each service has a single responsibility. `AsyncStream` for hotkey events and audio levels is idiomatic.

**Issues:**

1. **`AudioService.startRecording()` returns `URL` but so does `stopRecording()`.** Which URL does the caller use? `startRecording` should return `Void` -- the caller only needs the WAV path after recording finishes. Returning a URL from start implies the file is ready, but it's still being written.

2. **`ModelManager.modelState` uses `CurrentValueSubject` -- everything else uses `AsyncStream`.** Pick one pattern. `CurrentValueSubject` is Combine; the rest of the architecture is structured concurrency. Use `AsyncStream` or `@Published` consistently. Given `AppCoordinator` is `@MainActor + ObservableObject`, prefer `@Published` for UI-bound state and `AsyncStream` for service-to-service.

3. **Missing: `AudioService` has no way to report "no audio detected."** The spec (Phase 1, Story 7) requires "Didn't catch that" feedback. Add a silence detection result or a minimum audio level threshold check in `stopRecording()`.

## Error Handling

4. **`handleHotkeyEvent` has unhandled `try` calls.** `audio.startRecording()` and `transcription.transcribe()` both `throw`, but there's no `do/catch` in the coordinator. A transcription failure leaves `state` stuck on `.transcribing`. Every throwing call needs a catch that transitions to `.idle` (or a new `.error` state) and surfaces feedback via the pill.

5. **Missing state: `.error(Error)`.** The state machine diagram shows `error -> IDLE` but `AppState` enum only has `idle, recording, transcribing, injecting, undoable`. Add `.error(MurmurError)` with auto-dismiss to `.idle` after pill display. Without this, the UI has no way to show "Microphone in use" or "Transcription failed."

6. **Concurrent audio conflict not handled.** Spec says show "Microphone is in use by another app." `AudioService.startRecording()` will throw, but there's no specific error type to distinguish mic-busy from other AVAudioEngine failures. Define a `MurmurError` enum with `.microphoneInUse`, `.insufficientDiskSpace`, `.permissionRevoked`, etc.

## Testability

**Good:** Protocol-based design means every service is mockable. `AppCoordinator` takes protocol deps -- straightforward to inject test doubles.

7. **`TranscriptionService` depends on `PythonKit` at the module level.** The protocol is clean, but confirm the concrete implementation isolates `PythonKit` imports so tests can substitute a mock without linking Python. The `pythonQueue` DispatchQueue pattern should be internal to the implementation, not leaked through the protocol.

**Recommendations (non-blocking):**
- Add a `Clock` protocol or use `ContinuousClock` injection for the 60s model unload timer and 5s undo timeout. Hardcoded timers are untestable.
- `TextInjectionService` cascade logic (try CGEvent -> AX -> clipboard) should be testable per-tier. Consider making each tier a separate internal strategy object.

## Swift Best Practices

8. **`AppCoordinator.handleHotkeyEvent` is `@MainActor` but calls `async` service methods.** The `startRecording` / `transcribe` / `inject` chain runs sequentially on the main actor's executor. `transcribe` dispatches to `pythonQueue` internally (good), but `AudioService` setup and `TextInjectionService` injection both happen on main thread. Confirm `AudioService.startRecording()` returns quickly -- `AVAudioEngine.start()` is synchronous and fast, but the disk space check could block. Move disk check to a background task.

**Non-blocking observations:**
- `AppState` needs `Equatable` conformance for the `guard state == .idle` checks. `undoable` case with associated values means you'll need manual conformance or a computed `isIdle` property.
- `HotkeyEvent` and `RecordingMode` should be `Sendable`. They cross actor boundaries via `AsyncStream`.
- Consider making `PermissionsStatus.allGranted` a computed property (it's referenced in coordinator but not defined in the struct).

## Architecture Patterns

**State machine is correct for the happy path.** The IDLE -> RECORDING -> TRANSCRIBING -> INJECTING -> UNDOABLE flow matches the spec.

**Missing from state machine:**
- Spec says "rapid-fire usage: if user triggers recording while transcription is in progress, queue it." The current `guard state == .idle` silently drops the request. Need either a queue or a `.pendingRecording` state.
- Sleep/wake: spec says "auto-stop recording on sleep, transcribe what was captured." No `NSWorkspace` sleep notification handling visible in the architecture.
- The `UNDOABLE -> IDLE` transition on "any user input" isn't implemented. Need an event tap or AX observer to detect user keystrokes post-injection.

## refs

- `docs/architecture.md`
- `docs/specs/murmur-v1.md` rev 2

## out

(To be filled by EN after addressing changes)
