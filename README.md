# Murmur

Local voice input for macOS. Press a hotkey, speak, text appears at your cursor. No cloud, no latency, no data leaves your Mac.

Chinese + English with automatic language detection.

## How It Works

```
Right Command → Record → Transcribe (local) → Text inserted at cursor
```

Murmur lives in your menu bar. It uses [Cohere Transcribe](https://cohere.com/blog/transcribe) running entirely on your Mac via ONNX Runtime (with CoreML acceleration on Apple Silicon). Text is inserted into the active app using clipboard paste.

> **Important:** Murmur temporarily uses your clipboard to insert text. It saves your clipboard contents before pasting and restores them afterward. If you copy something during the brief insertion window (~1.5s), your new clipboard content is preserved — Murmur won't overwrite it.

## Requirements

| | Minimum |
|---|---|
| Chip | Apple Silicon (M1+) |
| RAM | 8 GB |
| macOS | 14.0 (Sonoma) |
| Disk | 3 GB free (1.5 GB model + Python env) |
| Python | 3.10+ (Homebrew or system) |

## Getting Started

### 1. Build and run

```bash
cd Murmur
swift build
open .build/debug/Murmur.app
```

### 2. Complete onboarding

On first launch, Murmur walks you through 5 steps:

1. **Welcome + Microphone** — Grant mic access
2. **Accessibility** — Required for text insertion (System Settings opens automatically)
3. **Model Download** — Downloads the ONNX speech model (~1.5 GB). Python dependencies are installed automatically.
4. **Test** — Record with the button, then try the hotkey
5. **Done** — Shortcuts cheat sheet

The entire setup takes 3-5 minutes depending on your internet speed.

## User Guide

### Recording

| Shortcut | Action |
|---|---|
| **Right Command** | Start / stop recording (toggle mode) |
| **Esc** | Cancel recording |
| **Cmd + Z** | Undo last text insertion (within 5 seconds) |

1. Focus any text field in any app
2. Press **Right Command** to start recording — a floating pill appears near the menu bar
3. Speak naturally. The pill pulses red with your voice level
4. Press **Right Command** again to stop
5. Text appears at your cursor within 1-2 seconds

The hotkey and recording mode (toggle vs hold-to-talk) are customizable in Settings.

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
- You can undo the insertion with **Cmd+Z** within 5 seconds

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
- Launch at login

**Model tab:**
- ONNX engine is the default (~1.5 GB, fast, recommended)
- Advanced engines (HuggingFace PyTorch ~4 GB, Whisper ~1.6 GB) are available under a disclosure
- Download progress, model status, re-download option
- Model and log folder shortcuts

### Sleep / Wake

Murmur unloads the model when your Mac sleeps to free memory, and reloads it when you wake. The first transcription after wake may take 1-2 extra seconds.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                      AppCoordinator (@MainActor)                  │
│   State: idle → recording → transcribing → injecting → undoable   │
├──────────┬──────────┬──────────────┬──────────────┬──────────────┤
│ Hotkey   │ Audio    │ Transcription│ Injection    │ Permissions  │
│ Service  │ Service  │ Service      │ Service      │ Service      │
│          │          │ (actor)      │              │              │
│ RightCmd │ AVAudio  │     ↕        │ Clipboard    │ Mic + A11y   │
│ Toggle/  │ Engine   │  JSON IPC    │ paste        │              │
│ Hold     │ RMS/VAD  │     ↕        │ (Cmd+V)     │              │
└──────────┴──────────┤  Python      ├──────────────┴──────────────┘
                      │  subprocess  │
                      │  ONNX/HF/   │
                      │  Whisper     │
                      └──────────────┘
```

- **TranscriptionService** is a Swift `actor` — all subprocess I/O is serialized by the type system
- Python subprocess communicates via JSON lines over stdin/stdout
- Model preloads on launch and after wake for instant first transcription
- Python dependencies are pinned in `requirements.txt` for reproducibility

## Project Structure

```
Murmur/
├── MurmurApp.swift                  # Entry point, menu bar (.window style)
├── AppCoordinator.swift             # State machine, flow orchestration
├── Services/
│   ├── TranscriptionService.swift   # Actor — Python subprocess bridge
│   ├── HotkeyService.swift          # Global hotkey (Right Command)
│   ├── AudioService.swift           # AVAudioEngine recording + VAD
│   ├── TextInjectionService.swift   # Clipboard paste + CGEvent fallback
│   ├── ModelManager.swift           # Model download, venv setup, verification
│   ├── PermissionsService.swift     # Mic + accessibility checks
│   └── AudioFeedbackService.swift   # System sounds
├── Views/
│   ├── MenuBarView.swift            # Menu bar dropdown (capsule switcher)
│   ├── FloatingPillView.swift       # Recording overlay
│   ├── SettingsView.swift           # Settings (General + Model tabs)
│   └── HotkeyRecorderView.swift     # Hotkey capture widget
├── Onboarding/
│   ├── OnboardingView.swift         # 5-step first-launch flow
│   └── OnboardingViewModel.swift    # Onboarding logic + step skipping
├── Tests/
│   ├── P0FixTests.swift             # Hash isolation, concurrency, defaults
│   ├── ModelSwitchingTests.swift    # Backend switch + race conditions
│   └── AppCoordinatorTests.swift   # State machine, history, errors
└── Resources/
    ├── transcribe.py                # ONNX/HF/Whisper inference + opencc
    └── requirements.txt             # Pinned Python dependencies
```

## Development

Built with Swift Package Manager. One dependency:

- [HotKey](https://github.com/soffes/HotKey) (0.2.1+) — Global keyboard shortcuts

```bash
cd Murmur
swift build        # Build
swift test         # Run 46 unit tests
open .build/debug/Murmur.app   # Launch
```

## Troubleshooting

**"Python3 not found"** — Install Python 3.10+ via `brew install python3`

**Model download fails** — Check your internet connection. Partial downloads are preserved and will resume.

**No text appears after transcription** — Make sure Accessibility is enabled for Murmur in System Settings > Privacy & Security > Accessibility

**Transcription is wrong language** — Set the language manually in the menu bar instead of Auto, or switch your macOS input method

**App doesn't appear** — Murmur is a menu bar app with no dock icon. Look for the mic icon in your menu bar (top right of screen)

## License

TBD
