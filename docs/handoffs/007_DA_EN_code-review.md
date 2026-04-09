---
from: DA
to: EN
pri: P1
status: done
created: 2026-04-08
---

# Phase 1 Code Review

Reviewed all 10 source files against `docs/architecture.md` rev 2.

---

## Critical Bugs

**B1. `AudioService` data race in recording tap (P0)**
`AudioService.swift:61-80` -- The `installTap` closure runs on a real-time audio thread but mutates `self.outputFile` (line 76) and `self.rmsAccumulator` (line 78) with no synchronization. `stopRecording()` sets `outputFile = nil` on the caller's thread (line 101) while the tap may still be writing. This will crash or corrupt data.

**B2. `TranscriptionService.send()` can resume continuation twice (P0)**
`TranscriptionService.swift:149-174` -- If the Python process closes stdout (empty `byte` at line 157), the continuation resumes with an error. But if the `DispatchQueue.global` block is still in the `while true` loop when the Task is cancelled (via `withTimeout`), and then stdout closes, the continuation could resume after the timeout already resumed it with `MurmurError.timeout`. A `CheckedContinuation` will trap on double-resume.

**B3. `MurmurApp.init` captures `@StateObject` before body is evaluated (P1)**
`MurmurApp.swift:38` -- `coordinator` is captured in `DispatchQueue.main.asyncAfter` inside `init()`. `@StateObject` is not guaranteed to be fully initialized during `init` of the `App` struct; SwiftUI may create and discard `App` instances. The `asyncAfter` closure may call `start()` on a discarded coordinator, or the actual coordinator never gets `start()` called.

## Bugs (Medium)

**B4. `AudioService.stopRecording` calls `log10` as a free function (P2)**
`AudioService.swift:108` -- `log10` shadows the `log` property (a `Logger`). This compiles only because Foundation provides a free `log10(_:)`. If someone renames or removes the import, this breaks silently. More importantly, `log` on line 104 is the Logger, while `log10` on line 108 is a math function -- confusing and fragile. Rename the logger to `logger`.

**B5. Duration timer does nothing (P2)**
`AudioService.swift:87-89` -- The `durationTimer` fires after `maxDuration` but its closure is empty. The comment says "AppCoordinator monitors state" but AppCoordinator has no max-duration logic. Recording will run forever if the user forgets to stop.

**B6. Temp WAV files leak on transcription error (P2)**
`TranscriptionService.swift:68-78` -- If `send(command:)` throws on line 68-71, the `removeItem` on line 74 is never reached. The temp file stays in `/tmp` until reboot.

---

## Architecture Drift

**A1. `ModelManager` is missing entirely**
Architecture specifies `ModelManager` (protocol, `ModelState` enum, download/verify/delete). Not implemented. `TranscriptionService` hardcodes model path. Onboarding will need this before it can work.

**A2. `PermissionsStatus` is missing `inputMonitoring`**
`PermissionsService.swift:11-18` -- Architecture specifies three fields (`microphone`, `accessibility`, `inputMonitoring`). Implementation only has two. `allGranted` does not check input monitoring. HotkeyService needs input monitoring to work with global hotkeys; this gap means the app will fail silently when input monitoring is denied.

**A3. `HotkeyService.register()` signature differs from protocol**
`HotkeyService.swift:17-19` vs `38` -- Protocol declares `register(key:modifiers:)` but the concrete class uses default arguments with different types (`Key` + `NSEvent.ModifierFlags`) vs the architecture's `register(combo: KeyCombo)`. Minor but will matter for Settings UI binding.

**A4. Views and Onboarding directories missing**
Architecture specifies `MenuBarView`, `FloatingPill`, `OnboardingWindow`, and `Settings`. Only a `MenuBarView` reference exists in `MurmurApp.swift` (line 9) but the file itself is not in the tree. Compile will fail.

---

## Concurrency Issues

**C1. `HotkeyService` is `@unchecked Sendable` with mutable state (P1)**
`HotkeyService.swift:23` -- `isRecording`, `mode`, `hotKey`, `escMonitor` are all mutated from hotkey callbacks (main thread) and potentially read from async contexts. The `@unchecked Sendable` annotation hides the problem from the compiler. Needs a lock or actor isolation.

**C2. `TranscriptionService` is not `Sendable` and has no synchronization (P1)**
`TranscriptionService.swift:25` -- Mutable `process`, `stdinPipe`, `stdoutPipe`, `isModelLoaded` are accessed from the main actor (via AppCoordinator) and from `DispatchQueue.global` (line 150). If two transcriptions overlap (e.g., timeout races with completion), `send()` can interleave stdin writes.

**C3. `TextInjectionService.injectViaCGEvent` blocks with `usleep` (P2)**
`TextInjectionService.swift:74` -- `usleep(1000)` per character on an async context. For 500 chars, that is 500ms of thread blocking. Should use `Task.sleep` or dispatch to a background thread.

---

## Missing Error Handling

**E1. `stdinPipe.fileHandleForWriting.write` can throw `SIGPIPE` (P1)**
`TranscriptionService.swift:146` -- If the Python process has died, writing to the pipe sends `SIGPIPE` which terminates the app by default. Need to either `signal(SIGPIPE, SIG_IGN)` at app launch or catch the write error.

**E2. Clipboard restore silently drops multi-type pasteboard items (P2)**
`TextInjectionService.swift:84-88` -- Only saves the first type of each pasteboard item. If the user had rich text + plain text + an image, only one survives. The `guard let type = item.types.first` discards all other types.

---

## Security Concerns

**S1. Python subprocess path is user-writable (P1)**
`TranscriptionService.swift:39-40` -- `~/Library/Application Support/Murmur/Python/bin/python3` is in a user-writable directory. A local attacker (or malware) could replace the Python binary. The architecture acknowledges this trade-off for avoiding code-signing the Python env, but there is no integrity check (hash verification) before launch.

**S2. No validation of Python subprocess responses (P2)**
`TranscriptionService.swift:165` -- JSON from stdout is trusted completely. A compromised Python process could inject arbitrary text into any focused application via TextInjectionService. Consider at minimum length limits on the `text` field.

---

## What's Good

- **State machine design** (`AppCoordinator.swift`) is clean. The `withTimeout` helper using `TaskGroup` is elegant and correct for the single-result case.
- **Two-tier injection** with automatic fallback is well-structured. Clipboard save/restore is a thoughtful touch.
- **Error taxonomy** (`MurmurError.swift`) covers the right failure modes and has good user-facing messages.
- **VAD via RMS** is a pragmatic v1 approach -- simple, no extra dependencies.
- **Python subprocess protocol** (JSON lines over stdin/stdout) is solid. The long-lived process avoids cold-start latency on every transcription.
- **Logging** is consistent across all services with appropriate subsystem/category structure matching the architecture spec.
- **Sleep-aware model unloading** (`AppCoordinator.swift:87-92`) prevents wasted memory.

---

## Recommended Fix Order

1. **B1** (audio data race) -- will crash in production
2. **B2** (double continuation resume) -- will trap
3. **E1** (SIGPIPE) -- will kill the app
4. **C1/C2** (concurrency) -- intermittent corruption
5. **B3** (StateObject init) -- may cause start() to never fire
6. **A4** (missing views) -- blocks compilation
7. **A1** (ModelManager) -- blocks onboarding
8. Everything else
