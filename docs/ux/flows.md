# Murmur UX Flows

## 1. Core Recording Flow

### State Machine

```
                  Option+Space        transcription
     +---------+  (tap)    +-----------+  done   +----------+  inject  +--------+
     |  IDLE   |---------->| RECORDING |-------->|TRANSCRIBE|-------->| INJECT |
     +---------+           +-----------+         +----------+         +--------+
       ^  ^                  |       |                |                  |  |
       |  |  Option+Space    |  Esc  |                | fail             |  | ok
       |  |  (tap again)     |       |                v                  |  v
       |  |                  +-------+          +----------+         +--------+
       |  |                  cancel             |  ERROR   |         | UNDOABLE|
       |  +-------------------------------------+----------+         +--------+
       |            auto-dismiss 2s                                    |
       |                                                    Cmd+Z      |
       |  +----------+   undo injection                    (within 5s) |
       +--| UNDO     |<-----------------------------------------------+
          +----------+
```

### Trigger Behavior

- **Toggle mode (default)**: Tap Option+Space to start recording, tap again to stop and transcribe.
- **Hold mode (setting)**: Hold Option+Space to record, release to stop. Available in Settings.

### Menu Bar Icon States

| State        | Icon                       | Description                    |
|--------------|----------------------------|--------------------------------|
| Idle         | `[M]` outline mic          | Monochrome, template-style     |
| Recording    | `[M]` filled red mic       | Solid red, pulses every 0.5s   |
| Transcribing | `[M]` filled, spinner dots | Three rotating dots near icon  |
| Error        | `[M]` with `!` badge       | Clears after 3s or on click    |

### Floating Pill

The floating pill appears anchored below the menu bar icon (not near the cursor). This avoids multi-display ambiguity and is consistent regardless of where the text cursor is.

- **Recording**: Pill shows `Recording...` with a live waveform.
- **Transcription complete**: Pill shows a checkmark, detected language tag (`EN` or `中`), and the first ~30 chars of text. Fades after 1.5s.
- **Cancel**: Press Escape or tap Option+Space while in IDLE-after-start. Pill shows `Cancelled` for 0.5s.

### Audio Feedback

- Short click sound on start (like a mic tap). Optional chime on stop.
- Sounds can be disabled in Settings.

### Success and Undo

Text is injected at the cursor position via Accessibility API. For 5 seconds after injection, the UNDOABLE state is active: pressing Cmd+Z removes the injected text (Murmur sends the appropriate delete keystrokes or AX undo action). After 5s or any other user input, the undo window closes and Cmd+Z reverts to the app's native undo.

### Failure States

| Scenario              | Pill message                              | Duration |
|-----------------------|-------------------------------------------|----------|
| Transcription failed  | `Transcription failed. Try again.`        | 2s       |
| No focused text field | `Copied to clipboard (no text field)`     | 2s       |

---

## 2. Onboarding Flow (First Launch)

```
+----------+  +----------+  +----------+  +----------+  +----------+  +----------+
| Welcome  |->|   Mic    |->|  A11y    |->|  Model   |->| Try the  |->|  Done    |
|          |  |  Perm.   |  |  Perm.   |  | Download |  |  Hotkey  |  |          |
+----------+  +----------+  +----------+  +----------+  +----------+  +----------+
  Step 1/6      Step 2/6      Step 3/6      Step 4/6      Step 5/6      Step 6/6
```

### Step 1: Welcome

```
+------------------------------------------+
|              (mic icon)                  |
|           Welcome to Murmur              |
|   Voice input for your Mac.              |
|   Press a hotkey, speak, and your        |
|   words appear wherever you type.        |
|   - Works offline, 100% local            |
|   - Chinese + English                    |
|   - System-wide, any text field          |
|            [ Get Started ]               |
+------------------------------------------+
```

### Steps 2-3: Permissions (Mic, Accessibility)

Each permission screen explains why it's needed, triggers the system dialog, and auto-advances once granted. If denied, button becomes `Open System Settings` with a direct link. Accessibility step polls trust status every 1s.

### Step 4: Model Download

- Shows model size and estimated time. Button: `Download Model`.
- Progress bar with percentage, bytes, and ETA during download.
- **Cancel**: Returns to pre-download state.
- **Network error**: `Download interrupted. Check your connection and retry.` Button: `Retry`.
- **Disk space low**: Before starting, check available space. If < model size + 1 GB buffer, show `Not enough disk space. Free up X GB and try again.`
- **Completion**: SHA-256 verification. If failed: `Download corrupted. Please retry.` If passed: auto-advances.

### Step 5: Try the Hotkey

```
+------------------------------------------+
|  Try It Out                     Step 5/6 |
|                                          |
|  Press  Option + Space  to start,        |
|  speak, then press it again to stop.     |
|                                          |
|       (waveform area / pill preview)     |
|                                          |
|  +---------------------------------+     |
|  | "Hello, this is a test."        |     |
|  +---------------------------------+     |
|                                          |
|  Looks good?                             |
|     [ Try Again ]    [ Continue ]        |
+------------------------------------------+
```

- The user practices the real hotkey interaction (Option+Space toggle), not an in-app button.
- The floating pill appears as it would in normal use.
- If transcription fails: `Make sure you speak clearly and try again.`

### Step 6: Done

```
+------------------------------------------+
|  You're All Set                 Step 6/6 |
|                                          |
|  Murmur lives in your menu bar.          |
|                                          |
|        Option + Space                    |
|     Tap to start, tap to stop.           |
|                                          |
|  Text appears wherever your cursor is.   |
|  Cmd+Z to undo within 5 seconds.        |
|                                          |
|         [ Start Using Murmur ]           |
+------------------------------------------+
```

- Closes onboarding window. App remains in menu bar. Launch at login is enabled by default.

---

## 3. Menu Bar Interaction

### Dropdown Menu

```
+-------------------------------+
|  Last: "send the report to..." |  <- click to copy full text
+-------------------------------+
|  Option+Space to record       |  <- hotkey reminder (dimmed)
+-------------------------------+
|  Settings...                  |
+-------------------------------+
|  Quit Murmur                  |
+-------------------------------+
```

- **Last transcription**: Truncated to ~35 chars. Click to copy full text. Hidden if none yet.
- **During recording**: Top item becomes `Recording... (Esc to cancel)` with a red dot.

---

## 4. Edge Cases

### System Events During Recording

| Event                        | Behavior                                                  |
|------------------------------|-----------------------------------------------------------|
| Mac sleeps during recording  | Cancel recording, return to IDLE. No transcription.       |
| Mac wakes after sleep        | Return to IDLE. If model was loaded, it will reload on next use. |
| App switch during recording  | Continue recording. Text injects into the focused app at time of injection (not at recording start). |
| Display disconnected         | Pill repositions to primary display menu bar.             |

### Permission and Resource Issues

| Event                          | Behavior                                                  |
|--------------------------------|-----------------------------------------------------------|
| Mic permission revoked         | On next hotkey press: blocking alert with `Open Settings` button. Menu bar icon shows `!` badge. |
| A11y permission revoked        | Hotkey stops working (can't intercept). Menu bar click shows error with `Open Settings` link. |
| Disk space < 500 MB            | Before recording: pill warns `Disk space low`. Recording still allowed (audio buffers are small). |
| Mic in exclusive use           | On record attempt: `Microphone unavailable. Close other audio apps.` |

### Recording Limits

- **Max duration**: 5 minutes. At 4:30, pill shows `30s remaining`. At 5:00, auto-stops and transcribes.
- **Rapid-fire**: If user triggers hotkey while transcription is in progress, queue the new recording. Only one active transcription at a time.

---

## 5. Error States

### Blocking Errors (alert window on hotkey or menu click)

| Error         | Message                                                    | Actions                  |
|---------------|------------------------------------------------------------|--------------------------|
| No mic        | Murmur needs microphone access to work.                    | `Open Settings` / `Dismiss` |
| No a11y       | Murmur needs Accessibility access to type into apps.       | `Open Settings` / `Dismiss` |
| Model missing | The speech model hasn't been downloaded yet.               | `Download Now` / `Later` |
| Model corrupt | The speech model appears corrupted.                        | `Re-download` / `Dismiss` |

### Non-Blocking Errors (floating pill)

| Error                | Pill message                        | Duration    |
|----------------------|-------------------------------------|-------------|
| Transcription failed | `Transcription failed. Try again.`  | 2s          |
| No text field        | `Copied to clipboard`               | 2s          |
| Engine error         | `Engine error. Restart Murmur.`     | 3s          |
| Model loading        | `Model loading...`                  | until ready |

---

## 6. Settings

Accessed via menu bar > `Settings...`. Standard macOS settings window.

```
+--------------------------------------------------+
|  Murmur Settings                                  |
+--------------------------------------------------+
|  Hotkey                                           |
|  [Option + Space]  [ Change... ]                  |
|  Mode: (o) Toggle on/off  ( ) Hold to record      |
|                                                   |
|  Language                                         |
|  (o) Auto-detect  ( ) Chinese  ( ) English        |
|                                                   |
|  Sound Effects                                    |
|  [x] Play sounds on start/stop                    |
|                                                   |
|  Startup                                          |
|  [x] Launch Murmur at login                       |
|                                                   |
|  Model                                            |
|  Cohere Transcribe v2.1 -- 4.0 GB                 |
|  Status: Ready                                    |
|  [ Re-download ]  [ Delete Model ]                |
+--------------------------------------------------+
```

- **Hotkey change**: Click `Change...`, press desired combo. Escape cancels.
- **Mode**: Toggle (default) or Hold. Takes effect immediately.
- **Delete model**: Confirmation dialog. **Re-download**: Progress in-place, same as onboarding.
