# Murmur

Local voice input for macOS. Press a hotkey, speak, text appears at your cursor. No cloud, no latency, no data leaves your Mac.

Chinese + English with automatic language detection.

## How It Works

```
Ctrl+Space → Record → Transcribe (local) → Text injected at cursor
```

Murmur lives in your menu bar. It uses [Cohere Transcribe](https://cohere.com/blog/transcribe) (2B parameter model) running entirely on your Mac via a Python subprocess. Text is inserted into the active app using CGEvent keystrokes with clipboard paste as fallback.

## Requirements

| | Minimum |
|---|---|
| Chip | Apple Silicon (M1+) |
| RAM | 16 GB |
| macOS | 14.0 (Sonoma) |
| Disk | 6 GB free |

## Getting Started

### 1. Set up the Python environment

```bash
python3 -m venv ~/Library/Application\ Support/Murmur/Python
~/Library/Application\ Support/Murmur/Python/bin/pip install \
  huggingface_hub transformers torch soundfile librosa
```

### 2. Build and run

```bash
cd Murmur
swift build
.build/debug/Murmur
```

### 3. Complete onboarding

On first launch, Murmur will walk you through:
- Granting microphone access
- Granting accessibility access (for text injection)
- Downloading the transcription model (~4 GB)
- Testing your first transcription

## Usage

| Shortcut | Action |
|---|---|
| `Ctrl + Space` | Start / stop recording (toggle mode) |
| `Esc` | Cancel recording |
| `Cmd + Z` | Undo last text insertion (within 5s) |

The hotkey is customizable in Settings. Hold-to-talk mode is available as an alternative to toggle.

## Features

- **Local-only transcription** — Cohere Transcribe runs on-device via Apple Silicon GPU (MPS)
- **Bilingual** — Chinese + English with automatic language detection
- **System-wide** — Works in any app with a text cursor
- **Menu bar app** — No dock icon, launches at login
- **Floating pill** — Shows recording state, transcription preview, and detected language
- **Smart fallback** — CGEvent keystrokes (supports undo) with clipboard paste as backup
- **Crash-isolated** — Python runs as a subprocess; if it crashes, the app stays alive
- **Privacy** — Zero network calls after model download

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  CGEvent Tap ──► HotkeyService ──► AppCoordinator     │
│                                     │ │ │ │           │
│                          ┌──────────┘ │ │ └────┐      │
│                          ▼            │ │      ▼      │
│                   PermissionsService  │ │  ModelMgr    │
│                          ▼            │ │              │
│                    AudioService ──────┘ │              │
│                     (WAV + VAD)         │              │
│                          ▼              │              │
│                 TranscriptionService ───┘              │
│                   (Python subprocess)                  │
│                          ▼                             │
│                 TextInjectionService ──► target app    │
│                                                       │
│  UI: MenuBarView | FloatingPill | OnboardingWindow    │
└──────────────────────────────────────────────────────┘
```

The Python subprocess communicates via JSON lines over stdin/stdout:

```
→ {"cmd":"load","model_path":"/path/to/model"}
← {"status":"ok"}

→ {"cmd":"transcribe","wav_path":"/tmp/audio.wav"}
← {"text":"Hello world","language":"en","duration_ms":1200}
```

## Project Structure

```
Murmur/
├── MurmurApp.swift                  # App entry point, menu bar, windows
├── AppCoordinator.swift             # State machine, orchestration
├── MurmurError.swift                # Typed error enum
├── Services/
│   ├── HotkeyService.swift          # Global hotkey (Ctrl+Space)
│   ├── AudioService.swift           # AVAudioEngine recording + VAD
│   ├── TranscriptionService.swift   # Python subprocess bridge
│   ├── TextInjectionService.swift   # CGEvent + clipboard injection
│   ├── PermissionsService.swift     # Mic + accessibility checks
│   ├── ModelManager.swift           # Model download + verification
│   └── AudioFeedbackService.swift   # Sound effects
├── Views/
│   ├── MenuBarView.swift            # Menu bar dropdown
│   ├── FloatingPillView.swift       # Floating status overlay
│   ├── SettingsView.swift           # Settings window
│   └── HotkeyRecorderView.swift    # Hotkey capture widget
├── Onboarding/
│   ├── OnboardingView.swift         # 6-step first-launch flow
│   └── OnboardingViewModel.swift    # Onboarding state machine
├── Scripts/
│   ├── transcribe.py                # Cohere Transcribe subprocess
│   └── spike_test.py                # Phase 0 validation benchmark
└── Resources/
    └── transcribe.py                # Bundled copy
```

## Phase 0 Validation Spike

Before building further, validate that Cohere Transcribe runs acceptably on your hardware:

```bash
~/Library/Application\ Support/Murmur/Python/bin/python3 \
  Murmur/Scripts/spike_test.py \
  --model-path ~/Library/Application\ Support/Murmur/Models
```

| Metric | Pass | Warn | Fail |
|---|---|---|---|
| Latency (10s audio, M1 16GB) | < 2s | 2-3s | > 3s |
| Peak RAM | < 4 GB | 4-5 GB | > 5 GB |

## Development

Built with Swift Package Manager. Dependencies:

- [HotKey](https://github.com/soffes/HotKey) — Global keyboard shortcuts

```bash
cd Murmur
swift build        # Build
swift run          # Build and run
```

## Docs

| Document | Description |
|---|---|
| `docs/specs/murmur-v1.md` | Product spec (rev 2) |
| `docs/architecture.md` | Technical architecture (rev 2) |
| `docs/ux/flows.md` | UX interaction flows |
| `docs/team-protocol.md` | Agent team workflow |
| `docs/handoffs/` | 9 handoff documents tracking team decisions |

## License

TBD
