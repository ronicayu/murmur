---
from: DA
to: EN
pri: P1
status: done
created: 2026-04-08
---

# Architecture Challenge: Murmur v1

## Fatal Flaws

### 1. `AppCoordinator.handleHotkeyEvent` swallows errors silently

The `handleHotkeyEvent` method uses `try await` on `audio.startRecording()`, `transcription.transcribe()`, and `injection.inject()` -- but there is no `do/catch` block shown. If any of these throw, the coordinator state gets stuck in `recording`, `transcribing`, or `injecting` permanently. The user will see a frozen pill and the app becomes unresponsive until relaunch. Every `try` in that method needs a catch that resets state to `.idle` and surfaces the error to the user.

### 2. Spec requires queueing rapid-fire recordings; architecture drops them

The spec says: "If user triggers recording while a previous transcription is in progress, queue the new recording. Do not drop it." The architecture's state machine has no queue. The `guard state == .idle` in `startRecording` silently rejects any hotkey press that arrives during transcription or injection. You need either a pending queue or at minimum a state that buffers the next recording request.

### 3. No crash recovery for the Python process

The spec's Open Questions explicitly ask: "If Murmur or the Python process crashes mid-transcription, what happens?" The architecture doesn't answer. If PythonKit segfaults (which it will -- torch + MPS + Python GC is a volatile combination), the entire app process dies. There is no isolation boundary between Swift and Python.

## Over-Engineering

### 1. Three-tier text injection cascade with verification is Phase 3 work

The CGEvent -> AXUIElement -> clipboard cascade with post-injection AXValue verification is correct in theory but is a large surface area for v1. The verification step (wait 100ms, read `AXValue`, compare suffix) will produce false negatives in apps that reformat text (rich text editors, terminals, Electron apps). For v1, consider: CGEvent for short text (< 200 chars), clipboard paste for everything else. Two tiers, no verification. Build the full cascade in Phase 3 when you have the app-compat matrix data.

### 2. Model auto-unload timer adds complexity for marginal benefit

The 60s idle timer with sleep-notification unload adds state management complexity. On a 16 GB machine, 2-4 GB for a loaded model is fine to keep resident. For v1, load on first use and unload only on sleep or quit. The 60s timer is a premature optimization that adds a cold-start penalty for users who pause between dictations.

## Under-Engineering

### 1. `AudioService.startRecording()` returns a URL before recording has started

The protocol says `startRecording() async throws -> URL`. Returning the file URL immediately means the consumer has a path to a file that is still being written to. If transcription somehow starts before `stopRecording()` (a bug, a race), you get a partial or corrupt WAV. `startRecording()` should return `Void`; `stopRecording()` should return the finalized URL. The current `stopRecording() async -> URL` is correct, but `startRecording` returning a URL is a footgun.

### 2. Clipboard restore timing is too fragile

Tier 3 saves the pasteboard, pastes via Cmd+V, then restores after 0.5s. Many apps process paste asynchronously (Electron apps, VS Code, Slack). 0.5s is not enough. If the restore happens before the app reads the clipboard, the user gets their old clipboard content pasted instead. You need to either poll the target app's AXValue to confirm receipt, or use a longer delay (1-2s), or accept that clipboard restore is best-effort and warn the user.

### 3. No audio silence detection

The spec says: "No audio detected: 'Didn't catch that. Try again.'" The architecture has no mechanism for this. `AudioService` streams to disk unconditionally. You need either a VAD (voice activity detection) check or a minimum RMS threshold before sending to transcription. Otherwise you will transcribe silence and get hallucinated text -- a known Whisper-family model behavior.

## Threading & Concurrency Risks

### 1. `@MainActor AppCoordinator` calls `async` services that may block

`AppCoordinator` is `@MainActor`. `handleHotkeyEvent` awaits `transcription.transcribe()` which dispatches to `pythonQueue` via `withCheckedThrowingContinuation`. This is correct IF the continuation is resumed from `pythonQueue`. But if there is any path where the continuation is not resumed (Python hangs, MPS driver deadlock), the main actor is blocked forever. You need a timeout on the transcription call -- the 120s max recording already implies a bound, but inference itself has no timeout. Add `withThrowingTaskGroup` + a deadline task.

### 2. `TextInjectionService` on main thread is a bottleneck

The architecture says injection runs on main thread. CGEvent posting and AXUIElement queries are synchronous AppKit calls that can hang if the target app is unresponsive (spinning beachball). A hung target app will freeze Murmur's UI. Consider dispatching injection to a background thread and only updating UI state on main.

### 3. HotkeyService AsyncStream backpressure

If the consumer (`AppCoordinator`) is awaiting a long transcription when a hotkey event fires, the `AsyncStream` buffers it. But `AsyncStream` with default buffering policy drops the oldest event when the buffer is full. If the user taps the hotkey multiple times while transcription is running, some events will be silently dropped. Use `.bufferingPolicy(.unbounded)` or explicitly handle the "busy" state by playing an error sound.

## Python Integration Risks

### 1. PythonKit shares the process address space -- any Python crash kills Swift

There is no isolation. A segfault in torch, numpy, or MPS backend takes down the entire app. The architecture mentions a `Process`-based fallback in the spike section but does not carry it into the main design. Recommendation: use `Process` (subprocess) as the primary integration, not a fallback. JSON over stdin/stdout. It costs ~100ms overhead per call but gives you crash isolation, memory isolation, and the ability to kill a hung Python process.

### 2. ~800 MB bundled Python runtime is a signing and notarization minefield

Every `.dylib` and `.so` in the bundle must be individually signed, and Apple's notarization service scans them all. One unsigned or improperly signed file and notarization fails. The architecture mentions `bundle_python.sh` but doesn't address: (a) `torch` ships ~50+ `.so` files, (b) numpy has compiled extensions, (c) Apple silicon `libpython3.11.dylib` must match the exact build. This is the single highest-risk item in the project and deserves more than one line.

### 3. Memory leak from Python GC + MPS

Python's garbage collector and MPS memory management interact poorly. `torch.mps.empty_cache()` in `unload_model()` only releases MPS allocations that PyTorch knows about. Fragmentation and leaked Python objects will accumulate over hours of use. With the subprocess approach, you get automatic cleanup -- kill the process, OS reclaims everything.

## Missing from Architecture

1. **Crash recovery and state reset.** What happens after a crash? Does the app relaunch? Is there stale state in UserDefaults that causes a stuck onboarding? Who cleans up temp WAV files?

2. **Logging and diagnostics.** No mention of `os_log`, crash reporting, or any way to debug user-reported issues. A voice input app that "doesn't work" with no logs is unsupportable.

3. **App compatibility strategy for text injection.** The spec requires testing against top 20 apps. The architecture defines the cascade but not how you detect which tier succeeded or how you build the compatibility matrix. Consider a `TextInjectionStrategy` per-app override table.

4. **Hotkey conflict detection at runtime.** The spec says onboarding detects Ctrl+Space conflicts with CJK input switching. The architecture's `HotkeyService` has no conflict detection API.

5. **Update/migration path.** How does the user update the app? How do you update the Python bundle or the model? No versioning scheme for bundled components.

## Recommendations

1. **Use subprocess (`Process`) for Python, not PythonKit.** JSON over stdin/stdout. Crash isolation, memory isolation, killable on timeout. The ~100ms overhead is negligible against 1-2s inference. This eliminates the entire class of "Python crash kills app" bugs and simplifies signing (Python runtime lives outside the app bundle in `~/Library/Application Support/Murmur/`).

2. **Add error handling and timeouts to `AppCoordinator`.** Wrap `handleHotkeyEvent` in do/catch, add a 30s timeout on transcription, and always reset to `.idle` on error. Surface errors via the floating pill.

3. **Simplify text injection to two tiers for v1.** CGEvent keystrokes for text under 500 chars, clipboard paste for everything else. Drop AXUIElement setValue and post-injection verification. Build the full cascade in Phase 3 with real app-compat data.

4. **Add silence/VAD detection in `AudioService`.** Compute RMS over the recording. If below threshold, skip transcription and show "Didn't catch that." This prevents hallucinated output and saves inference time.

5. **Add structured logging from day one.** Use `os_log` with subsystem `com.murmur` and categories per service. Log state transitions, Python process lifecycle, injection tier used, and errors. This is zero-effort now and invaluable later.
