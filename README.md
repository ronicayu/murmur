# Murmur

Local voice input for macOS. Press a hotkey, speak, text appears at your cursor. No cloud, no latency, no data leaves your Mac.

Two modes:
- **Voice input** — real-time streaming transcription injected at your cursor
- **Audio transcription** — record or upload long audio files, get full transcripts

Supports Chinese, English, Japanese, Korean, French, German, Spanish and more with automatic language detection.

## How It Works

```
Right Command → Record → Transcribe (local) → Text inserted at cursor
```

Murmur lives in your menu bar. It uses [Cohere Transcribe](https://cohere.com/blog/transcribe) running entirely on your Mac via a native Swift ONNX Runtime backend (with CoreML acceleration on Apple Silicon). Text is inserted into the active app using clipboard paste.

**Streaming mode** (V3): Text appears in real-time as you speak. Chunks are transcribed and injected continuously, then a full-pass refinement runs when you stop to ensure accuracy.

> **Important:** Murmur temporarily uses your clipboard to insert text. It saves your clipboard contents before pasting and restores them afterward. If you copy something during the brief insertion window (~1.5s), your new clipboard content is preserved — Murmur won't overwrite it.

## Requirements

| | Minimum |
|---|---|
| Chip | Apple Silicon (M1+) |
| RAM | 8 GB |
| macOS | 14.0 (Sonoma) |
| Disk | 3 GB free (1.5 GB model) |

## Install

Download the latest DMG from [Releases](../../releases), drag to Applications, launch.

### First launch (macOS security prompt)

Because Murmur isn't notarized by Apple yet, macOS will block it the first time you open it with a message like *"Murmur cannot be opened because Apple cannot check it for malicious software."*

1. Open **System Settings → Privacy & Security**
2. Scroll to the **Security** section — you'll see `"Murmur" was blocked…`
3. Click **Open Anyway** and confirm with your password
4. Subsequent launches won't prompt again

### Build from source

```bash
cd Murmur
swift package resolve
bash Scripts/patch-ort-float16.sh   # Required: patches ONNX Runtime for Float16 support
swift build
open .build/debug/Murmur.app
```

### First launch

On first launch, Murmur walks you through 5 steps:

1. **Welcome + Microphone** — Grant mic access (the OS permission dialog appears automatically)
2. **Accessibility** — Required for text insertion (System Settings opens automatically)
3. **Model Download** — Downloads the ONNX speech model (~1.5 GB)
4. **Test** — Record with the button, then try the hotkey
5. **Done** — Shortcuts cheat sheet

The entire setup takes 3-5 minutes depending on your internet speed.

## User Guide

### Voice Input

| Shortcut | Action |
|---|---|
| **Right Command** | Start / stop recording (toggle mode) |
| **Esc** | Cancel recording |
| **Cmd + Z** | Undo last text insertion (when undo is enabled in Settings) |

1. Focus any text field in any app
2. Press **Right Command** to start recording — a floating pill appears near the menu bar
3. Speak naturally. The pill pulses red with your voice level
4. Press **Right Command** again to stop
5. Text appears at your cursor within 1-2 seconds

With **streaming mode** enabled (Settings > Experimental), text appears in real-time as you speak. A full-pass refinement runs when you stop to correct any streaming errors.

The hotkey and recording mode (toggle vs hold-to-talk) are customizable in Settings.

### Recording in noisy environments — turn on macOS Voice Isolation

Murmur intentionally does NOT enable AVAudioEngine voice processing — on macOS that audio unit returns silent buffers with several common device routes (notably AirPods, EarPods, and some external USB mics), which would break recording entirely.

Instead, use macOS's system-level **Voice Isolation** mic mode. It runs in the OS, applies to any input device, and uses Apple's ML noise-suppression model:

1. Start a recording in any app once (e.g., open the Murmur recording pill — Voice Isolation only appears in Control Center while a process is using the mic).
2. Open **Control Center** (top-right menu bar).
3. Click **Microphone Mode**.
4. Select **Voice Isolation**.

The setting persists per app. With AirPods Pro you also get the headset's own hardware noise cancellation on top — that combination is dramatically better than anything Murmur could do in-process.

### Audio Transcription

Open the transcription window from the menu bar to transcribe long audio files:

- **Record** — Record audio directly, then transcribe
- **Upload** — Import .mp3, .m4a, .caf, .wav, or .ogg files (up to 2 hours)
- **Drag and drop** — Drop an audio file onto the window

Before transcription starts, you can select the language (auto-detect, Chinese, English, etc.). Transcription history is saved and searchable in the sidebar.

### Language

Murmur defaults to **Auto** — it detects your language from your active macOS input method:

- Using **Pinyin** or **Wubi** keyboard? Murmur transcribes in Chinese (simplified)
- Using **ABC** or **US** keyboard? Murmur transcribes in English
- Switch your input method, and the transcription language follows automatically

You can also pin a language manually via the menu bar dropdown or Settings.

The menu bar shows quick-switch capsule buttons: **Auto | EN | 中文 | 日 | 한**

### How text insertion works

Murmur inserts text using **clipboard paste** (Cmd+V):

1. Your current clipboard is saved
2. The transcribed text is placed on the clipboard
3. Cmd+V is simulated to paste into the active app
4. After ~1.5 seconds, your original clipboard is restored

**This means:**
- It works in virtually every app (browsers, editors, terminals, chat apps)
- Your clipboard is briefly occupied during insertion
- If you copy something new during the 1.5s window, Murmur detects this and keeps your new content (it won't overwrite it)
- You can undo the insertion with **Cmd+Z** within 5 seconds (when undo is enabled in Settings)

If clipboard paste fails, Murmur falls back to CGEvent keystrokes (character-by-character injection).

### Menu Bar

Click the Murmur icon in your menu bar to see:

- **Status** — Ready, Recording, Transcribing, or Error
- **Language switcher** — Capsule buttons to change language quickly
- **Recent transcriptions** — Last 20 results with detected language badges (click to copy)
- **Hotkey** — Shows current shortcut (click to open Settings)
- **Settings / Quit**

### Floating Pill

During recording and transcription, a small overlay appears near the menu bar:

- **Red pulsing dot** — Recording (shows "Esc to cancel")
- **Spinner** — Transcribing
- **Green checkmark** — Text inserted (shows preview)
- **Orange warning** — Error occurred

### Settings

Open Settings from the menu bar dropdown.

**General tab:**
- Hotkey trigger (Right Command or custom shortcut)
- Recording mode (Toggle or Hold-to-talk)
- Transcription language
- Sound effects on/off
- Undo after transcription (off by default)
- Launch at login

**Experimental tab:**
- Streaming voice input (real-time transcription as you speak)
- Focus timeout (auto-cancel when target app loses focus)

**Model tab:**
- ONNX engine is the default (~1.5 GB, fast, recommended)
- Native Swift ONNX backend (no Python dependency)
- Download progress, model status, re-download option
- Model and log folder shortcuts

### Sleep / Wake

Murmur unloads the model when your Mac sleeps to free memory, and reloads it when you wake. The first transcription after wake may take 1-2 extra seconds.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                      AppCoordinator (@MainActor)                      │
│   State: idle → recording → transcribing → injecting → idle          │
│   Streaming: idle → recording (streaming chunks) → finalizing → idle  │
├──────────┬──────────┬────────────────┬──────────────┬────────────────┤
│ Hotkey   │ Audio    │ Transcription  │ Injection    │ Permissions    │
│ Service  │ Service  │ Service        │ Service      │ Service        │
│          │          │                │              │                │
│ RightCmd │ AVAudio  │ Native ONNX    │ Clipboard    │ Mic + A11y     │
│ Toggle/  │ Engine   │ (pure Swift)   │ paste        │                │
│ Hold     │ RMS/VAD  │ + Python IPC   │ (Cmd+V)     │                │
│          │          │ fallback       │              │                │
│          │ Streaming│                │              │                │
│          │ Accum.   │ Mel Spectro.   │              │                │
│          │ (chunks) │ (pure Swift)   │              │                │
└──────────┴──────────┴────────────────┴──────────────┴────────────────┘
         │
         └─── StreamingTranscriptionCoordinator
              (chunk transcribe + full-pass refinement + focus guard)
```

- **Native ONNX backend** — pure Swift, no Python dependency. Uses ONNX Runtime Swift bindings with CoreML acceleration
- **MelSpectrogramExtractor** — pure Swift mel spectrogram, replacing the ONNX mel_extractor dependency
- **StreamingTranscriptionCoordinator** — manages real-time chunk transcription, text injection, and full-pass refinement
- **Python subprocess** (legacy fallback) communicates via JSON lines over stdin/stdout
- Model preloads on launch and after wake for instant first transcription

## Project Structure

```
Murmur/
├── MurmurApp.swift                          # Entry point, menu bar (.window style)
├── AppCoordinator.swift                     # State machine, flow orchestration
├── MurmurError.swift                        # Typed error enum
├── Services/
│   ├── NativeTranscriptionService.swift     # Native ONNX backend (pure Swift)
│   ├── ONNXTranscriptionBackend.swift       # ONNX Runtime model inference
│   ├── MelSpectrogramExtractor.swift        # Pure Swift mel spectrogram
│   ├── BPETokenizerDecoder.swift            # BPE token decoding
│   ├── StreamingTranscriptionCoordinator.swift # V3 streaming state machine
│   ├── AudioBufferAccumulator.swift         # Streaming audio chunk accumulator
│   ├── TranscriptionService.swift           # Python subprocess bridge (legacy)
│   ├── HotkeyService.swift                  # Global hotkey (Right Command)
│   ├── AudioService.swift                   # AVAudioEngine recording + VAD
│   ├── TextInjectionService.swift           # Clipboard paste + CGEvent fallback
│   ├── LongRecordingService.swift           # Long audio recording for transcription
│   ├── TranscriptionHistoryService.swift    # Persistent transcription history
│   ├── ModelManager.swift                   # Model download, verification
│   ├── PermissionsService.swift             # Mic + accessibility checks
│   └── AudioFeedbackService.swift           # System sounds
├── Views/
│   ├── MenuBarView.swift                    # Menu bar dropdown
│   ├── FloatingPillView.swift               # Recording overlay
│   ├── TranscriptionWindowView.swift        # Audio transcription main window
│   ├── TranscriptionWindowModel.swift       # Transcription window ViewModel
│   ├── TranscriptionSubViews.swift          # Idle/Record/Upload/Result sub-views
│   ├── SettingsView.swift                   # Settings
│   └── HotkeyRecorderView.swift            # Hotkey capture widget
├── Onboarding/
│   ├── OnboardingView.swift                 # 5-step first-launch flow
│   └── OnboardingViewModel.swift            # Onboarding logic
├── Tests/                                   # 295 unit tests
│   ├── V3Phase1Tests.swift                  # Streaming voice input tests
│   ├── V3Phase0Tests.swift                  # Streaming spike tests
│   ├── NativeTranscriptionTests.swift       # Native ONNX backend tests
│   ├── TranscriptionWindowModelTests.swift  # Audio transcription UI tests
│   └── ...                                  # + 8 more test files
├── Scripts/
│   └── patch-ort-float16.sh                 # Patch ONNX Runtime for Float16
└── Resources/
    ├── transcribe.py                        # Python inference (legacy fallback)
    └── requirements.txt                     # Python dependencies
```

## Development

Built with Swift Package Manager. Dependencies:

- [HotKey](https://github.com/soffes/HotKey) (0.2.1+) — Global keyboard shortcuts
- [onnxruntime-swift-package-manager](https://github.com/microsoft/onnxruntime-swift-package-manager) (1.24+) — ONNX Runtime for native inference

```bash
cd Murmur
swift package resolve
bash Scripts/patch-ort-float16.sh   # Required before first build
swift build        # Build
swift test         # Run 295 unit tests
open .build/debug/Murmur.app   # Launch
```

## Troubleshooting

**"Murmur needs microphone access"** — On first use, the OS permission dialog should appear automatically. If it doesn't, go to System Settings > Privacy & Security > Microphone and add Murmur.

**Model download fails** — Check your internet connection. Partial downloads are preserved and will resume.

**No text appears after transcription** — Make sure Accessibility is enabled for Murmur in System Settings > Privacy & Security > Accessibility

**Transcription is wrong language** — Set the language manually in the menu bar instead of Auto, or switch your macOS input method. For audio transcription, select the language in the confirm dialog before starting.

**Streaming not working** — Enable streaming in Settings > Experimental. If it was previously enabled but stopped working, try toggling it off and on.

**App doesn't appear** — Murmur is a menu bar app with no dock icon. Look for the mic icon in your menu bar (top right of screen)

## License

TBD
