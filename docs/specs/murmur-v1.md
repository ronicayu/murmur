# Murmur v1 Product Spec

**Author:** @PM
**Status:** RDY
**Created:** 2026-04-08
**Last updated:** 2026-04-08
**Revision:** 2 (post-DA challenge)

---

## Problem

Voice input on macOS is broken in three specific ways:

1. **Apple Dictation is cloud-dependent and slow.** Every utterance round-trips to Apple's servers. Latency is 1-3s. It fails offline. Apple's on-device dictation is better but mediocre at Chinese, and you can't control the model.

2. **No existing tool does bilingual Chinese/English well locally.** macOS dictation requires you to pick a language. Switching between Chinese and English mid-sentence -- which is how millions of bilingual speakers actually talk -- is poorly supported.

3. **Privacy-conscious users have no good option.** Tools like 闪电说 send audio to remote servers. For medical notes, legal memos, and internal discussions, this is a non-starter.

Murmur gives bilingual macOS users fast, private, local-only voice input that works everywhere a text cursor exists.

---

## Target User

**Primary:** Bilingual (Chinese/English) knowledge workers on Apple Silicon Macs (16 GB+ RAM) who value privacy. Developers, writers, researchers, product managers.

**Secondary:** Any macOS user who wants fast, private, offline dictation -- monolingual English or Chinese.

**Not our user (v1):** Windows/Linux users. Users needing real-time streaming transcription. Users needing speaker diarization. Users on 8 GB Macs (see System Requirements).

---

## System Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| Chip | Apple Silicon (M1+) | M1 Pro or later |
| RAM | 16 GB | 16 GB+ |
| macOS | 14.0 (Sonoma) | Latest |
| Disk | 6 GB free (4 GB model + app + temp) | 10 GB free |

**8 GB Macs are not supported in v1.** The 2B model uses 2-4 GB RAM during inference. On an 8 GB machine with typical workloads (browser, editor, Slack), this causes swap pressure and degrades system performance. We will revisit with a quantized model in v2.

---

## Success Metrics

| Metric | Target | How we measure |
|--------|--------|----------------|
| End-to-end latency | < 1.5s for 10s utterance | Timestamp from stop-trigger to text-injected |
| Transcription accuracy (EN) | > 95% WER on common speech | Manual eval, 50 test utterances |
| Transcription accuracy (ZH) | > 90% CER on common speech | Manual eval, 50 test utterances |
| Cold start to first transcription | < 60s (model already downloaded) | Timer from app launch to first inject |
| Onboarding completion rate | > 90% | Local counter (UserDefaults) |
| Daily active usage | 5+ uses/day after first week | Local counter (UserDefaults) |

---

## Decisions (Resolved)

### Runtime: Cohere Transcribe via PythonKit (embedded Python)

**Decision:** We use Cohere Transcribe running locally via PythonKit (embedded Python runtime in Swift). This is confirmed and not open for debate.

**Rationale:** Cohere Transcribe handles bilingual Chinese/English natively with a single model. PythonKit lets us call Python inference from Swift without bundling a standalone Python installation or dealing with venv path issues.

**Risk acknowledged:** PythonKit + Python dependency management in a macOS .app is non-trivial. Phase 0 (validation spike) exists to prove this works before any real development.

### Default hotkey: Ctrl+Space (configurable)

**Decision:** Default is `Ctrl+Space`. Configurable during onboarding and in settings.

**Why not Option+Space:** Conflicts with Spotlight on some configurations, with Alfred/Raycast launcher apps, and with non-breaking space insertion in writing apps.

**Why not Fn double-tap:** Unreliable to detect programmatically on all keyboard types. Apple uses it for dictation already, creating confusion.

**Conflict handling:** If `Ctrl+Space` conflicts with the user's CJK input source switching, onboarding detects this and prompts the user to pick an alternative before proceeding.

### Default mode: Toggle (press to start, press to stop)

**Decision:** Toggle mode is the default. Hold-to-talk is available as a setting.

**Rationale:** Hold-to-talk is physically uncomfortable for dictation longer than 10-15 seconds. Most voice input users dictate for 15-60 seconds. Toggle is the sane default.

### Language detection: Auto-detect only (v1)

**Decision:** No manual language override in v1. The model auto-detects Chinese vs English. The menu bar dropdown does NOT show a language selector.

**Rationale:** Manual override adds complexity, contradicts the "it just works" pitch, and the model handles code-switching natively. If auto-detection proves unreliable in testing, we add manual override in v1.1.

### Settings scope for v1

Included in v1 settings:
- Hotkey configuration
- Toggle vs hold mode
- Launch at login (default: ON)
- Sound effects on/off
- Model status (version, size, re-download, delete)

NOT in v1 settings: language selection, themes, model picker, advanced config.

### Launch at login: ON by default

Enabled automatically after onboarding completes. Menu bar apps that don't start at login get forgotten.

---

## Phased Plan

### Phase 0: Validation Spike (1-2 days, before any other work)

**Goal:** Prove the core technical stack works on target hardware.

**Deliverables:**
1. Run Cohere Transcribe locally on an M1 Mac (16 GB) via PythonKit from a Swift CLI app.
2. Measure inference latency for 5s, 10s, 30s, and 60s audio clips in both English and Chinese.
3. Measure peak RAM usage during inference.
4. Confirm the model is downloadable and its license permits bundling/redistribution.
5. Document results in `docs/spikes/phase0-results.md`.

**Exit criteria:**
- Inference < 2s for 10s audio on M1 16 GB: proceed.
- Inference 2-3s: proceed with a warning, investigate optimization.
- Inference > 3s or model unavailable: STOP. Evaluate whisper.cpp + multilingual Whisper or mlx-whisper as alternatives. PM re-scopes.

### Phase 1: Core Loop (MVP)

User can install Murmur, press a key, speak, and see text appear.

### Phase 2: Onboarding

First-launch experience: permissions, model download, test transcription.

### Phase 3: Polish

Settings UI, error recovery, app compatibility testing.

---

## User Stories -- Phase 1: Core Loop

1. **Global hotkey to start recording.** Default: `Ctrl+Space` (toggle mode). Menu bar icon turns red, floating pill shows `Recording...` with live waveform.

2. **Press hotkey again to stop recording.** Recording stops. Audio sent to local model. Menu bar icon shows processing state (spinner dots). Hold-to-talk users release the key instead.

3. **Transcribed text injected at cursor.** Text appears at the cursor position in the active app via the injection strategy matrix (see below). Language is auto-detected. A brief pill shows the first ~30 chars of transcribed text + detected language, then fades.

4. **Menu bar presence.** Small icon in macOS menu bar. Click to see: last transcription (click to copy), hotkey reminder, settings link, quit.

5. **Undo after injection.** After text is injected, `Cmd+Z` undoes it. Murmur injects text in a way that registers with the target app's undo stack (CGEvent keystroke simulation inherently supports this; AXUIElement setValue does not -- see injection strategy).

6. **Cancel recording.** Press `Esc` while recording to discard audio. Pill shows `Cancelled` for 0.5s.

7. **Clear error feedback:**
   - No microphone permission: prompt to open System Settings.
   - No accessibility permission: same pattern.
   - Model not downloaded: launch onboarding.
   - No audio detected: "Didn't catch that. Try again."
   - Permission revoked post-onboarding: detect on every hotkey press, show blocking alert with "Open Settings" button.

---

## Text Injection Strategy Matrix

Ordered fallback chain, executed on every injection:

| Step | Method | Pros | Cons | When to use |
|------|--------|------|------|-------------|
| 1 | CGEvent keystroke simulation | Works in most apps, supports undo stack, handles selections correctly | Slower for long text, affected by input method state | Default method |
| 2 | AXUIElement setValue | Fast, clean | Breaks undo, doesn't work in all apps, may clobber selection | Fallback if CGEvent fails |
| 3 | Clipboard paste (Cmd+V) | Universal | Overwrites clipboard, user-visible side effect | Last resort; save/restore clipboard |

**Detection:** After injection, verify text appeared via AXUIElement value read. If mismatch, try next method. If all fail, copy to clipboard and notify user.

**App compatibility list:** EN builds and maintains a tested app list (`docs/app-compat.md`) covering the top 20 macOS apps. Started in Phase 1, expanded continuously.

---

## User Stories -- Phase 2: Onboarding

1. **Welcome screen.** "Speak into your Mac. Text appears." One sentence, clean, minimal.

2. **Microphone permission.** Request access. If denied, explain why and link to System Settings. Cannot proceed without it.

3. **Accessibility permission.** Explain why needed. Link to System Settings > Privacy > Accessibility. Poll for trust status every 1s. Auto-advance when granted.

4. **Model download.** Show size (~4 GB), progress bar, speed, ETA. Resumable downloads (HTTP Range). SHA-256 verification. Retry on failure. Resume on next launch if interrupted.

5. **Disk space check.** Before starting download, verify 6 GB free. If insufficient, show clear message: "Murmur needs 6 GB of free space. You have X GB. Free up space and try again."

6. **Test transcription.** Big record button (not the hotkey -- they haven't learned it yet). Transcribed text appears in a text area. User can retry. Then a second sub-step: "Now try the hotkey" -- user practices `Ctrl+Space` in the same text area to confirm muscle memory.

7. **Done screen.** Shows the hotkey, confirms launch-at-login is enabled. "Start Using Murmur" closes onboarding.

---

## Edge Cases

### Long recordings
- **Max duration:** 120 seconds. After 120s, recording auto-stops and transcribes what was captured. Pill shows "Max recording length reached."
- **Audio buffer:** Stream to disk, not RAM. Temp file in app's cache directory. Cleaned up after transcription.

### Rapid-fire usage
- If user triggers recording while a previous transcription is in progress, queue the new recording. Do not drop it. Process sequentially. Model stays loaded for 60s after last use.

### App switching during recording
- Text is injected into the app that is focused when recording STOPS, not when it started. This matches user intent (they switched to where they want the text).

### Sleep/wake
- **During model download:** Resume download on wake (HTTP Range).
- **Model loaded in memory:** Unload on sleep. Reload on first use after wake (user pays cold-start cost, but this is rare).
- **Recording in progress:** Auto-stop recording on sleep. Transcribe what was captured.

### Disk space
- Check before model download (Phase 2, Story 5).
- Check before recording starts: if < 500 MB free, warn user and refuse to record.

### Permission revocation
- Check microphone and accessibility permission on every hotkey press. If revoked, show blocking alert with "Open Settings" button. Do not silently fail.

### Concurrent audio
- Murmur records from the default input device (mic) only, never system audio. If another app has exclusive mic access, show "Microphone is in use by another app."

### Multiple displays
- Floating pill appears on the screen containing the focused text field (not the menu bar screen). If no text field, pill appears on the screen with the mouse cursor.

---

## Scope

### In scope for v1

- macOS menu bar app (no dock icon, no main window after onboarding)
- Global hotkey (Ctrl+Space default, configurable) with toggle mode default
- Local-only transcription via Cohere Transcribe 2B + PythonKit
- Auto language detection (Chinese + English)
- Text injection via CGEvent > AXUIElement > clipboard fallback chain
- Undo support (Cmd+Z after injection)
- First-launch onboarding: permissions + disk check + model download + test + hotkey practice
- Settings: hotkey, toggle/hold mode, launch-at-login, sound effects, model management
- Launch at login (default ON)
- Disk space checks
- Permission revocation detection
- 120s max recording duration
- Apple Silicon only, 16 GB+ RAM, macOS 14+

### Out of scope for v1

- Streaming/real-time transcription (v1 is toggle-to-talk)
- Custom vocabulary or user-trained models
- Intel Mac support
- 8 GB RAM support (revisit with quantized model in v2)
- Punctuation or formatting controls
- Manual language selection
- Multi-model support
- Auto-update (manual update for v1)
- Localized UI (English only)
- Small "instant" model for fast onboarding (good idea, deferred to v2)

---

## Risks

### 1. PythonKit bundling complexity
**Risk:** Embedding Python via PythonKit in a signed, notarized macOS .app may cause path issues, signing failures, or runtime crashes.
**Likelihood:** High
**Impact:** High
**Mitigation:** Phase 0 spike validates this before any other work. If PythonKit proves unworkable, fall back to subprocess-based Python invocation or compiled inference (whisper.cpp).

### 2. Accessibility API reliability across apps
**Risk:** Text injection doesn't work consistently across all macOS apps.
**Likelihood:** High
**Impact:** Medium
**Mitigation:** Three-tier injection fallback (CGEvent > AXUIElement > clipboard). App compatibility matrix tested against top 20 apps in Phase 1. Clipboard fallback ensures text is never lost.

### 3. Model inference speed on base hardware
**Risk:** 2B model may be too slow on M1 16 GB with other apps open.
**Likelihood:** Medium
**Impact:** High
**Mitigation:** Phase 0 benchmarks on target hardware under realistic load. Hard rule: if inference > 2s for 10s audio, evaluate quantized variant or smaller model.

### 4. Model download reliability
**Risk:** 4 GB download fails on flaky connections.
**Likelihood:** Medium
**Impact:** Medium
**Mitigation:** Resumable downloads, SHA-256 verification, clear retry UX, resume across app restarts.

### 5. Onboarding friction
**Risk:** Two permission prompts + 4 GB download = high bounce rate.
**Likelihood:** High
**Impact:** Medium
**Mitigation:** Start download early (during accessibility permission step). "Try it" step gives immediate reward. Target < 5 min total on 100 Mbps. For v2, consider bundling a small model for instant value.

### 6. Ctrl+Space conflicts with CJK input source switching
**Risk:** Users with Chinese input methods often use Ctrl+Space to switch input sources.
**Likelihood:** Medium (for our exact target user)
**Impact:** Medium
**Mitigation:** Onboarding detects this conflict and forces hotkey reconfiguration before proceeding.

---

## Open Questions

1. **Model hosting:** Where does the 4 GB model live? Options: Hugging Face Hub (free, good for ML models), self-hosted CDN, or Cohere's hosting. GitHub Releases has a 2 GB per-file limit. @EN to recommend.

2. **Audio feedback:** Should recording start/stop have a sound? Subtle click? Visual-only? @UX to decide, keeping in mind this is now a v1 setting (sound effects toggle).

3. **Crash recovery:** If Murmur or the Python process crashes mid-transcription, what happens? Need a watchdog or launchd keep-alive. @EN to design.

---

## Next Steps

1. @EN -- Execute Phase 0 validation spike immediately. Results determine whether we proceed.
2. @UX -- Update flows to match this revised spec (Ctrl+Space default, toggle default, no language selector in menu bar, add hotkey practice step in onboarding, add disk space check step).
3. @EN -- After Phase 0 passes, build text injection compatibility matrix against top 20 apps.
