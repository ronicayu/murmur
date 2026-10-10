# Murmur

Local voice input for macOS. Press a hotkey, speak, text appears at your cursor. No cloud, no latency, no data leaves your Mac.

Two modes:
- **Voice input** — dictate, with an optional live preview while you speak, and the text is inserted at your cursor
- **Audio transcription** — record or upload long audio files, get full transcripts

Built for Chinese, English and mixed Chinese-English speech. The speech model recognises the language by itself and writes its own punctuation.

## How It Works

```
Right Command → Record → Transcribe (local) → Text inserted at cursor
```

Murmur lives in your menu bar. It runs [Qwen3-ASR-0.6B](https://github.com/QwenLM/Qwen3-ASR) entirely on your Mac through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). Text is inserted into the active app using clipboard paste.

**Streaming mode**: your words appear in a floating bubble while you speak. When you stop, the whole recording is transcribed once more and that final text is inserted in one go.

> **Important:** Murmur temporarily uses your clipboard to insert text. It saves your clipboard contents before pasting and restores them afterward. If you copy something during the brief insertion window (~1.5s), your new clipboard content is preserved — Murmur won't overwrite it.

## Requirements

| | Minimum |
|---|---|
| Chip | Apple Silicon (M1+) |
| RAM | 8 GB |
| macOS | 14.0 (Sonoma) |
| Disk | 2 GB free (1 GB model) |

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
swift build
open .build/debug/Murmur.app
```

### First launch

On first launch, Murmur walks you through 5 steps:

1. **Welcome + Microphone** — Grant mic access (the OS permission dialog appears automatically)
2. **Accessibility** — Required for text insertion (System Settings opens automatically)
3. **Model Download** — Downloads the speech model (~1 GB)
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

With **streaming mode** enabled (Settings > Experimental), a floating bubble shows the text as you speak, about a second or two behind your voice. Nothing is typed until you stop; then the final text is inserted once.

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

There is no language to select. The speech model works out what you are speaking for each recording, so you can switch between languages freely.

**Settings → General → Languages you speak** lists the 19 languages Murmur supports and starts with all of them turned on. If you turn off the languages you never speak, Murmur double-checks any result that comes back in a writing system none of your languages uses: it listens again, and keeps the text only if the second pass agrees. Speaking a language you turned off still works; it takes a moment longer.

The model accepts 30 languages, but how well each one works differs a lot, so Murmur offers only the first two groups below. Measured with Murmur's own engine on 30 read-speech clips per language from the FLEURS validation set (lower is better; clips with numerals excluded, because the model writes digits where the reference spells numbers out):

| Works well (error ≤ ~11%) | Usable (12–26%) | Poor (over 40%) — not offered |
|---|---|---|
| Chinese 2.3 · Korean 3.3 · English 3.8 · Cantonese 4.8 · Spanish 5.9 · German 6.1 · Portuguese 6.7 · Thai 7.3 · French 8.9 · Japanese 10.5 · Italian 10.6 | Vietnamese 12.4 · Indonesian 13.4 · Russian 14.2 · Hindi 15.9 · Dutch 21.0 · Turkish 23.0 · Arabic 23.7 · Malay 26.3 | Filipino 42 · Polish 43 · Swedish 44 · Greek 57 · Czech 58 · Romanian 58 · Finnish 59 · Hungarian 61 · Danish 62 · Persian 62 · Macedonian 75 |

Character error rate for Chinese, Cantonese, Japanese, Korean and Thai; word error rate for the rest. Thirty clips is a small sample, so read these as tiers, not precise scores. In the "poor" group the output is often a phonetic approximation, and sometimes in a neighbouring language (Danish written as Swedish, Macedonian in Latin letters). The model still transcribes those languages if you speak them; Murmur just does not list them.

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
- Languages you speak
- Sound effects on/off
- Undo after transcription (off by default)
- Launch at login

**Experimental tab:**
- Streaming voice input (live text while you speak)

**Model tab:**
- Speech model status, download, re-download and delete (~1 GB)
- Voice activity detection add-on (~2 MB) for better silence detection and hands-free auto-stop
- Remove models left over from earlier versions of Murmur
- Model and log folder shortcuts

### Sleep / Wake

Murmur unloads the model when your Mac sleeps to free memory, and reloads it when you wake. The first transcription after wake may take 1-2 extra seconds.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                      AppCoordinator (@MainActor)                      │
│   State: idle → recording → transcribing → injecting → idle          │
├──────────┬──────────┬────────────────┬──────────────┬────────────────┤
│ Hotkey   │ Audio    │ Qwen3          │ Text         │ Permissions    │
│ Service  │ Service  │ Transcription  │ Injection    │ Service        │
│          │          │ Service        │ Service      │                │
│ RightCmd │ AVAudio  │ sherpa-onnx    │ Clipboard    │ Mic + A11y     │
│ Toggle/  │ Engine   │ Qwen3-ASR-0.6B │ paste        │                │
│ Hold     │ RMS/VAD  │ int8           │ (Cmd+V)      │                │
└──────────┴──────────┴────────────────┴──────────────┴────────────────┘
         │
         └─── StreamingTranscriptionCoordinator
              (growing-window passes → stable prefix → preview bubble
               → full pass → single insert)
```

- **Qwen3TranscriptionService** — the one speech engine. Loads the model lazily, retries when a decode comes back corrupt, and splits long audio at pauses.
- **MurmurEngine** — a helper process that holds that engine. The app (`EngineProcessClient`) sends it one request per line of JSON and ends it after 5 idle minutes, which is the only way to give the 2–4 GB the engine holds back to the system.
- **StreamingTranscriptionCoordinator** — re-transcribes the growing audio window every second and shows the words two consecutive passes agree on (`StablePrefixAggregator`).
- **ModelManager** — downloads the model files from a pinned revision on Hugging Face with the system `curl` (no Python), and checks every file's SHA-256 against that revision's listing before the model is marked ready.
- The model loads when a recording starts, while you speak.

## Project Structure

```
Murmur/
├── MurmurApp.swift                          # Entry point, menu bar (.window style)
├── AppCoordinator.swift                     # State machine, flow orchestration
├── MurmurError.swift                        # Typed error enum
├── Services/
│   ├── Qwen3TranscriptionService.swift      # Speech engine (sherpa-onnx Qwen3-ASR)
│   ├── TranscriptionTypes.swift             # Result / progress types, service protocol
│   ├── StreamingTranscriptionCoordinator.swift # Streaming state machine
│   ├── StablePrefixAggregator.swift         # LocalAgreement-2 stable prefix
│   ├── AudioBufferAccumulator.swift         # Streaming audio chunk accumulator
│   ├── AudioService.swift                   # AVAudioEngine recording + silence gate
│   ├── VadService.swift                     # Silero voice activity detection
│   ├── HotkeyService.swift                  # Global hotkey (Right Command)
│   ├── TextInjectionService.swift           # Clipboard paste + CGEvent fallback
│   ├── LongRecordingService.swift           # Long audio recording for transcription
│   ├── TranscriptionHistoryService.swift    # Persistent transcription history
│   ├── TranscriptionCorrectionService.swift # Optional LLM correction
│   ├── ModelManager.swift                   # Model download, verification
│   ├── HFDownload.swift                     # Download decisions: listing, paths, hashes, curl arguments
│   ├── PermissionsService.swift             # Mic + accessibility checks
│   ├── AudioFeedbackService.swift           # System sounds
│   └── Vendor/SherpaOnnx.swift              # sherpa-onnx Swift wrapper
├── Views/
│   ├── MenuBarView.swift                    # Menu bar dropdown
│   ├── FloatingPillView.swift               # Recording overlay
│   ├── StreamingPreviewBubble.swift         # Live text bubble for streaming
│   ├── TranscriptionWindowView.swift        # Audio transcription main window
│   ├── TranscriptionWindowModel.swift       # Transcription window ViewModel
│   ├── TranscriptionSubViews.swift          # Idle/Record/Upload/Result sub-views
│   ├── RecentHistoryView.swift              # Recent transcriptions
│   ├── SettingsView.swift                   # Settings
│   └── HotkeyRecorderView.swift             # Hotkey capture widget
├── Onboarding/
│   ├── OnboardingView.swift                 # First-launch flow
│   └── OnboardingViewModel.swift            # Onboarding logic
├── Tests/                                   # Unit tests
├── Scripts/                                 # run.sh, build-release.sh
├── vendor/sherpa-onnx.xcframework           # Vendored sherpa-onnx static library
└── Resources/                               # App icon
```

## Development

Built with Swift Package Manager. Dependencies:

- [HotKey](https://github.com/soffes/HotKey) (0.2.1+) — Global keyboard shortcuts
- [onnxruntime-swift-package-manager](https://github.com/microsoft/onnxruntime-swift-package-manager) (1.24+) — ONNX Runtime, linked by the vendored sherpa-onnx library

```bash
cd Murmur
swift package resolve
swift build        # Build
swift test         # Run the unit tests
open .build/debug/Murmur.app   # Launch
```

`swift test` skips the tests that need the speech model when the model is not installed, as on CI. To run them, including on a Mac that has the Command Line Tools but not Xcode:

```bash
Scripts/model-regression.sh    # uses the model the app downloaded
```

## Troubleshooting

**"Murmur needs microphone access"** — On first use, the OS permission dialog should appear automatically. If it doesn't, go to System Settings > Privacy & Security > Microphone and add Murmur.

**Model download fails** — Check your internet connection. Partial downloads are preserved and will resume.

**No text appears after transcription** — Make sure Accessibility is enabled for Murmur in System Settings > Privacy & Security > Accessibility

**Text comes out in the wrong language or script** — The model picks the language from the audio and cannot be forced to one. Add the languages you speak in Settings → General → Languages you speak so odd results get a second pass. Short or unclear clips are the usual cause.

**Streaming not working** — Enable streaming in Settings > Experimental. If it was previously enabled but stopped working, try toggling it off and on.

**App doesn't appear** — Murmur is a menu bar app with no dock icon. Look for the mic icon in your menu bar (top right of screen)

## License

TBD
