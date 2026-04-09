# Handoff 009: DA -> EN — Final Sweep

**Status:** REQ  
**Date:** 2026-04-08  
**Context:** Final pre-ship sweep. Team believes backlog is empty.

---

## Previous Review Verification (008)

| Item | Description | Fixed? |
|------|-------------|--------|
| M1 | `transcribe.py` not bundled | YES — copied to `Resources/`, present in build output |
| M2 | `ModelManager.download()` blocks main thread | YES — uses `withCheckedContinuation` + `terminationHandler` |
| M3 | Max recording duration not wired | YES — `AppCoordinator` subscribes to `audio.maxDurationReached` (line 186) |
| M4 | Undo (Cmd+Z) not wired | YES — global monitor installed during `undoable` state (line 237) |
| S1 | Clipboard restore only saves first type | YES — iterates all types per item via `compactMap` (line 85) |
| S2 | Onboarding test uses hotkey not button | YES — two sub-steps: button then hotkey practice |
| S3 | No Ctrl+Space conflict detection | PARTIAL — `HotkeyConflictDetector` exists but is never called (see B1 below) |
| S4 | Hotkey not configurable | YES — `HotkeyRecorderView` captures, persists, and applies |
| S5 | No SHA-256 verification | YES — `ModelManager.verify()` computes and stores SHA-256 |
| S6 | No download resume | YES — partial downloads preserved, huggingface_hub handles resume |
| S7 | `InjectionMethod` Equatable | YES — explicit `: Equatable` conformance |

---

## New Issues Found

### B1. Onboarding record button is a no-op — blocks user from completing onboarding

**File:** `Onboarding/OnboardingViewModel.swift:79-91`  
**Severity:** Must-fix (blocks user)

`toggleTestRecording()` has an empty `Task {}` body. When the user taps the big record button in onboarding step 5a, nothing happens. The user cannot produce a test transcription via the button, so `hotkeyPracticeMode` never becomes `true`, and they cannot advance to step 5b or complete onboarding — unless they already know the hotkey (which defeats the purpose of onboarding).

**Fix:** Wire the button to actually start/stop recording via `AppCoordinator`. For example, yield `.startRecording`/`.stopRecording` events through the hotkey service, or call the audio/transcription services directly.

### B2. `HotkeyConflictDetector` exists but is never called

**File:** `Views/HotkeyRecorderView.swift:120-139` (definition), nowhere invoked  
**Severity:** Should-fix

The detector for Ctrl+Space vs CJK input source conflicts was implemented (fixing S3 from 008) but never wired into the onboarding flow. A CJK user — the primary target user per spec — will hit a conflict with no warning.

### B3. `SettingsView.loadSavedHotkey()` is never called — hotkey display is wrong

**File:** `Views/SettingsView.swift:152-160` (definition), nowhere invoked  
**Severity:** Should-fix

`@State` properties `hotkeyKey` and `hotkeyModifiers` are initialized to `.space`/`.control` defaults. `loadSavedHotkey()` exists to read the actual values from UserDefaults but is never called (no `.onAppear` or `init` invocation). If the user customized their hotkey, Settings will display the wrong shortcut.

---

## Verdict

**Not yet SHIP.** One must-fix (B1: onboarding record button is dead code) blocks users from completing first-launch setup. Two should-fix items (B2, B3) are low-effort wiring oversights.

All M1-M4 from handoff 008 are resolved. S1-S2, S4-S7 are resolved. S3 is partially resolved (detector built but not called = B2).
