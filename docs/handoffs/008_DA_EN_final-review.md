# Handoff 008: DA -> EN — Final Review

**Status:** REQ  
**Date:** 2026-04-08  
**Context:** Final pre-ship review of complete Murmur v1 implementation

---

## Must Fix (blocks shipping)

### M1. `transcribe.py` not bundled — transcription will crash

`Package.swift` excludes `Scripts/` from the target. `TranscriptionService` expects `Bundle.main.url(forResource: "transcribe", withExtension: "py")` which will return `nil`, falling through to `/dev/null`. Every transcription attempt will fail silently or crash the Python process.

**Fix:** Either move `transcribe.py` into `Resources/` (which is declared as `.copy("Resources")`) or add a separate `.copy("Scripts")` resource rule and update the Bundle lookup path.

### M2. `ModelManager.download()` blocks the main thread

`ModelManager` is `@MainActor`. The `download()` method calls `process.waitUntilExit()` (line 157), a synchronous blocking call. This freezes the entire UI for the duration of the multi-GB model download (potentially 10+ minutes). The progress monitor task will also never fire because the main actor is blocked.

**Fix:** Run the Process on a background thread/Task and await its completion. Use `process.terminationHandler` or wrap `waitUntilExit()` in a detached Task.

### M3. Max recording duration (120s) not wired to coordinator

`AudioService` emits on `maxDurationReached` when the timer fires, but `AppCoordinator` never subscribes to this stream. After 120s the recording will continue indefinitely (audio engine keeps running). The spec requires auto-stop at 120s.

**Fix:** In `AppCoordinator.startRecordingFlow()`, subscribe to `audio.maxDurationReached` and call `stopAndTranscribe()` when it emits.

### M4. Undo (Cmd+Z) not wired

`TextInjectionService.undoLastInjection()` exists but is never called from `AppCoordinator` or any view. The spec requires Cmd+Z to undo the last injection within a 5s window. There is no keyboard listener for Cmd+Z, and the `undoable` state never triggers undo logic.

**Fix:** Add a Cmd+Z global event monitor during the `undoable` state that calls `injection.undoLastInjection()`.

---

## Should Fix (before first beta)

### S1. Clipboard restore only saves first pasteboard type

`TextInjectionService.injectViaClipboard` iterates `pasteboardItems` but only captures `item.types.first` per item. Multi-type items (e.g., rich text + plain text + HTML) lose all but one type. Users will notice when their clipboard content is degraded after a voice input.

**Fix:** Iterate all types per item, not just `first`.

### S2. Onboarding test step uses hotkey, not a button

Spec says Step 5 should start with a "Big record button (not the hotkey -- they haven't learned it yet)" followed by a sub-step where the user practices the hotkey. Current implementation only supports the hotkey path, which the user hasn't learned yet.

**Fix:** Add a visible Record button for the first sub-step, then a second sub-step for hotkey practice.

### S3. No Ctrl+Space conflict detection

Spec requires onboarding to detect if Ctrl+Space conflicts with CJK input source switching and prompt the user to pick an alternative. This is not implemented.

### S4. Hotkey is not actually configurable

Settings shows "Change" button for the hotkey but `isRecordingNewHotkey` toggle does nothing — no key capture, no persistence. The hotkey is hardcoded to Ctrl+Space.

### S5. No SHA-256 verification of downloaded model

Spec requires SHA-256 verification of the downloaded model. `ModelManager.verify()` only checks if `config.json` and `preprocessor_config.json` exist.

### S6. No download resume across app restarts

Spec requires resumable downloads (HTTP Range) that resume on next launch. `cancelDownload()` just kills the task and sets state to `.notDownloaded`, losing all progress. `resumeData` field is declared but never used.

### S7. `Equatable` conformance of `InjectionMethod` needed explicitly

`InjectionMethod` is used in `AppState.undoable` which has a manual `Equatable` implementation comparing methods with `==`. While Swift auto-synthesizes `Equatable` for simple enums, adding explicit conformance (`: Equatable`) is safer and documents intent.

---

## Spec Compliance Check

| # | Spec Requirement | Status |
|---|-----------------|--------|
| P1-1 | Global hotkey Ctrl+Space, toggle mode | YES |
| P1-2 | Press hotkey to stop, hold mode available | YES |
| P1-3 | Text injected at cursor, auto language detect | YES |
| P1-4 | Menu bar: last transcription, copy, hotkey, settings, quit | YES |
| P1-5 | Undo after injection (Cmd+Z) | **NO** (M4) |
| P1-6 | Cancel recording with Esc | YES |
| P1-7 | Clear error feedback for all error types | PARTIAL (no "Open Settings" blocking alert on permission revocation) |
| P2-1 | Welcome screen | YES |
| P2-2 | Microphone permission step | YES |
| P2-3 | Accessibility permission + polling | YES |
| P2-4 | Model download with progress, speed, resume | PARTIAL (no resume — S6) |
| P2-5 | Disk space check before download | YES |
| P2-6 | Test transcription (button then hotkey) | **NO** (S2 — hotkey only) |
| P2-7 | Done screen with hotkey summary | YES |
| Edge | 120s max recording auto-stop | **NO** (M3) |
| Edge | Queue recording during transcription | YES |
| Edge | Unload model on sleep | YES |
| Edge | Disk check before recording (500 MB) | YES |
| Edge | Permission check on every hotkey | YES |
| Edge | Configurable hotkey | **NO** (S4) |
| Edge | Ctrl+Space conflict detection | **NO** (S3) |
| Edge | Multiple displays: pill on focused screen | **NO** (pill always on main screen) |
| Build | LSUIElement (no dock icon) | YES |
| Build | SPM + HotKey dependency | YES |
| Build | macOS 14+ target | YES |
| Inject | CGEvent tier 1, clipboard tier 2 fallback | YES |
| Inject | AXUIElement tier (spec tier 2) | NO (deferred, acceptable) |
| Inject | Post-injection verification via AX | NO (not implemented) |

---

**Summary:** 4 must-fix issues (M1-M4) that would cause runtime failures or missing core functionality. 7 should-fix issues for beta quality. The core recording-transcription-injection loop is architecturally sound but has critical wiring gaps.
