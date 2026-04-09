# Murmur Technical Architecture

**Author:** @EN | **Status:** RDY | **Rev:** 2 | **Created:** 2026-04-08 | **Spec:** `docs/specs/murmur-v1.md` rev 2

Incorporates feedback from @DA (handoff 003) and @CR (handoff 004).

---

## System Architecture

```
┌─────────────────────────────────────────────────────┐
│  CGEvent Tap ──► HotkeyService ──► AppCoordinator    │
│                                     │ │ │ │          │
│                          ┌──────────┘ │ │ └────┐     │
│                          ▼            │ │      ▼     │
│                   PermissionsService  │ │  ModelMgr   │
│                          ▼            │ │             │
│                    AudioService ──────┘ │             │
│                     (WAV + VAD)         │             │
│                          ▼              │             │
│                 TranscriptionService ───┘             │
│                   (Python subprocess)                 │
│                          ▼                            │
│                 TextInjectionService ──► target app   │
│                                                      │
│  UI: MenuBarView | FloatingPill | OnboardingWindow   │
│  Logging: os_log  subsystem com.murmur.app           │
└─────────────────────────────────────────────────────┘
```

## Project Structure

```
Murmur/
├── MurmurApp.swift              # @main, menu bar, LSUIElement
├── AppCoordinator.swift         # State machine, orchestration
├── MurmurError.swift            # Typed error enum
├── Services/
│   ├── HotkeyService.swift      # Global Ctrl+Space via HotKey SPM
│   ├── AudioService.swift       # AVAudioEngine → WAV, VAD
│   ├── TranscriptionService.swift # Python subprocess bridge
│   ├── TextInjectionService.swift # CGEvent → clipboard (two tiers)
│   ├── PermissionsService.swift # Mic + a11y + input monitoring
│   └── ModelManager.swift       # Download, verify, store model
├── Views/                       # MenuBar, FloatingPill, Settings
├── Onboarding/                  # 6-step onboarding flow
├── Scripts/transcribe.py        # Python entry point, JSON stdin/stdout
└── Resources/                   # Assets, sounds
```

## MurmurError

```swift
enum MurmurError: Error, Sendable {
    case microphoneBusy, diskFull, modelNotFound, silenceDetected
    case permissionRevoked(Permission)
    case transcriptionFailed(String), injectionFailed(String)
    case timeout(operation: String)
    enum Permission { case microphone, accessibility, inputMonitoring }
}
```

---

## Component Design

### 1. HotkeyService

```swift
protocol HotkeyServiceProtocol: Sendable {
    var events: AsyncStream<HotkeyEvent> { get }
    func register(combo: KeyCombo) throws
    func unregister()
    func setMode(_ mode: RecordingMode)
}
enum HotkeyEvent: Sendable { case startRecording, stopRecording, cancelRecording }
enum RecordingMode: Sendable { case toggle, hold }
```

Deps: HotKey (SPM). AsyncStream `.bufferingPolicy(.bufferingNewest(1))`.

### 2. AudioService

Record to WAV on disk. Max 120s. Check 500 MB free. VAD via RMS threshold.

```swift
protocol AudioServiceProtocol {
    func startRecording() async throws       // Void; throws .microphoneBusy, .diskFull
    func stopRecording() async throws -> URL // finalized WAV; throws .silenceDetected
    func cancelRecording()
    var audioLevel: AsyncStream<Float> { get }
}
```

`stopRecording()` computes RMS. Below -40 dB threshold -> `.silenceDetected` -> pill shows "Didn't catch that."

### 3. TranscriptionService (Python Subprocess)

```swift
protocol TranscriptionServiceProtocol {
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
    func preloadModel() async throws
    func unloadModel() async
    var isModelLoaded: Bool { get }
}
struct TranscriptionResult: Sendable {
    let text: String
    let language: DetectedLanguage  // .english, .chinese
    let durationMs: Int
}
```

**JSON-line protocol over stdin/stdout:**

```
→ {"cmd":"load","model_path":"/path/to/model"}      ← {"status":"ok"}
→ {"cmd":"transcribe","wav_path":"/tmp/audio.wav"}   ← {"text":"...","language":"en","duration_ms":1200}
→ {"cmd":"unload"}                                    ← {"status":"ok"}
```

**Crash isolation:** Broken pipe or timeout -> kill process -> restart on next call. App stays alive. Memory leaks cleaned up by OS when process exits.

**Model lifecycle:** Load on first use (~5s cold). Stays in memory. Unload on sleep (`NSWorkspace.willSleepNotification`) or quit. No idle timer for v1.

Deps: Foundation (Process, Pipe). Threading: background Task.

### 4. TextInjectionService

Two tiers for v1. AXUIElement tier deferred to Phase 3 with app-compat data.

```swift
protocol TextInjectionServiceProtocol {
    func inject(text: String) async throws -> InjectionMethod
    func undoLastInjection() async throws
}
enum InjectionMethod: Sendable { case cgEvent, clipboard }
```

**Tier 1 -- CGEvent keystrokes:** One CGEvent per char. Supports undo. Falls to Tier 2 on failure.

**Tier 2 -- Clipboard paste:** Save pasteboard, set text, Cmd+V, restore after 1.5s. Pill: "Pasted from clipboard."

**Undo:** Tier 1 only. Posts Cmd+Z. 5s window in AppCoordinator.

### 5. PermissionsService

```swift
protocol PermissionsServiceProtocol {
    func checkAll() -> PermissionsStatus
    func requestMicrophone() async -> Bool
    func openAccessibilitySettings()
    func pollAccessibilityGranted() -> AsyncStream<Bool>
}
struct PermissionsStatus {
    let microphone, accessibility, inputMonitoring: PermissionState
    var allGranted: Bool { /* computed */ }
}
```

### 6. ModelManager

```swift
protocol ModelManagerProtocol {
    var modelState: AsyncStream<ModelState> { get }
    var modelPath: URL? { get }
    func download() async throws
    func cancelDownload()
    func verify() async throws -> Bool
    func delete() throws
    func checkDiskSpace() throws
}
enum ModelState: Sendable {
    case notDownloaded, downloading(progress: Double, bytesPerSec: Int64)
    case verifying, ready, corrupt
}
```

Storage: `~/Library/Application Support/Murmur/Models/`. Resume via HTTP Range + persisted ETag/offset.

---

## AppCoordinator

### State Machine

```
  IDLE ──start──► RECORDING ──stop──► TRANSCRIBING ──ok──► INJECTING ──done──► UNDOABLE
   ▲                  │                    │                    │                  │
   └── cancel(Esc) ───┘                   │                    │                  │
   ▲                                      │                    │                  │
   └── auto-recover(2s) ◄── ERROR ◄──────┴────────────────────┘──────────────────┘
```

**Queue:** Hotkey during TRANSCRIBING/INJECTING buffers one pending recording. Max depth: 1. Extra presses play error sound.

**Timeouts:** audio ops 5s, transcription 30s, injection 5s.

```swift
@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var state: AppState = .idle
    private var pendingRecording = false
    private static let log = Logger(subsystem: "com.murmur.app", category: "coordinator")

    func handleHotkeyEvent(_ event: HotkeyEvent) async {
        switch event {
        case .startRecording:
            guard permissions.checkAll().allGranted else {
                transition(to: .error(.permissionRevoked(.accessibility))); return
            }
            if state == .idle { await startRecordingFlow() }
            else if state == .transcribing || state == .injecting { pendingRecording = true }
        case .stopRecording:
            guard state == .recording else { return }
            await stopAndTranscribe()
        case .cancelRecording:
            guard state == .recording else { return }
            audio.cancelRecording(); transition(to: .idle)
        }
    }

    private func stopAndTranscribe() async {
        do {
            transition(to: .transcribing)
            let wav = try await withTimeout(5) { try await self.audio.stopRecording() }
            let result = try await withTimeout(30) {
                try await self.transcription.transcribe(audioURL: wav) }
            transition(to: .injecting)
            let method = try await withTimeout(5) {
                try await self.injection.inject(text: result.text) }
            transition(to: .undoable(text: result.text, method: method))
        } catch { transition(to: .error(mapError(error))) }
        if pendingRecording { pendingRecording = false; Task { await startRecordingFlow() } }
    }
    // transition() logs via os_log; .error auto-recovers to .idle after 2s
    // .silenceDetected caught in mapError -> shows "Didn't catch that" pill
}

enum AppState: Equatable, Sendable {
    case idle, recording, transcribing, injecting
    case undoable(text: String, method: InjectionMethod)
    case error(MurmurError)
    var isIdle: Bool { self == .idle }
}
```

---

## Python Subprocess Detail

**Runtime location:** `~/Library/Application Support/Murmur/Python/` -- outside app bundle. Avoids 800 MB signing/notarization complexity. Python env installed/updated by ModelManager alongside model. Only the Swift app binary is code-signed.

**transcribe.py:** Long-lived process. Main loop reads JSON lines from stdin, dispatches to `load`/`transcribe`/`unload` handlers, writes JSON response + flush. Uses `torch.float16` + `device_map="mps"`. Errors return `{"error": "..."}`. See `Scripts/transcribe.py` for implementation.

Swift side: `TranscriptionService` manages `Process` + stdin/stdout `Pipe`s. On unexpected exit, logs and lazily restarts.

---

## Logging

`os_log` via `Logger(subsystem: "com.murmur.app", category: ...)`:

| Category | Logs |
|----------|------|
| `coordinator` | State transitions, queue events |
| `audio` | Start/stop, RMS, silence detection |
| `transcription` | Subprocess lifecycle, latency, errors |
| `injection` | Tier used, target app, success/failure |
| `permissions` | Checks, grants, revocations |
| `model` | Download progress, verification, disk space |

---

## Build & Dependencies

**SPM:** [HotKey](https://github.com/soffes/HotKey) 0.2.1+. PythonKit removed.

**Signing:** Hardened Runtime ON, Sandbox OFF. Entitlements: `device.audio-input`, `cs.disable-library-validation`. Python lives outside bundle -- no `.so` signing. Notarized DMG via `xcrun notarytool`.

**Target:** macOS 14.0+ (Sonoma), arm64 only.

---

## Phase 0: Validation Spike

Swift CLI: launch Python subprocess, load model, record 10s, transcribe, print.

| Metric | Pass | Warn | Fail |
|--------|------|------|------|
| Latency (10s, M1 16 GB) | < 2s | 2-3s | > 3s |
| Peak RAM (Python proc) | < 4 GB | 4-5 GB | > 5 GB |
| Subprocess responds | Works | -- | Hangs |
| Model on MPS | Works | CPU fallback | Fails |
| kill -9 Python | App survives | -- | App dies |

Timeline: 1-2 days. Results in `docs/spikes/phase0-results.md`.
