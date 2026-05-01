# Changelog

<!-- Release process:
     1. Bump `CFBundleShortVersionString` in `Murmur/Info.plist` to the new version.
     2. Add a section here describing what changed.
     3. Tag `vX.Y.Z` on main; CI's release.yml overrides the plist from the tag
        anyway, but keeping the plist in sync prevents confusion for local builds. -->

## [0.4.10] — 2026-05-01

### Fixed
- **Fast 1-word utterances ("yes", "好", "ok") were silently dropped.** Silero requires 0.25 s of sustained ≥ 0.5 prob frames to *open* a speech segment, so a 150–200 ms word never registered — `endOfStream()` returned empty, the silence gate fired, the WAV was deleted with no transcription. Added a short-utterance backstop in `AudioService.stopRecording`: if VAD found nothing but the recording is ≤ 2 s and peak RMS is ≥ −50 dB (whisper level), the audio still goes to Cohere. Long recordings with no VAD segment continue to short-circuit as silence — the backstop only kicks in for short clips where Silero's open-threshold can plausibly miss a real word.

## [0.4.9] — 2026-05-01

### Removed
- **Settings → Model → Transcription Cleanup section.** Rule-based punctuation/casing toggle was rarely useful and added noise to the Model tab. The underlying `PunctuationCleanupService` is unchanged; only the UI control is gone. The `cleanupTranscription` UserDefaults key is no longer read.
- **Settings → General → Network (Advanced) section.** Custom CA bundle picker was a niche WARP/Zero-Trust escape hatch that almost no user touched. The auto-generated keychain bundle (introduced in 0.3.5) handles the same case automatically, plus `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` env vars still work for manual override. The `customCABundlePath` UserDefaults key is no longer read.

## [0.4.8] — 2026-05-01

### Changed
- **Streaming chunks no longer break mid-sentence.** The streaming VAD's `minSilenceDurationSeconds` was using Silero's 0.25 s default, which closes a segment on a mid-sentence breath — so a single utterance was getting transcribed in halves. Bumped to 0.8 s; now spans typical commas / breath pauses so a chunk only delivers on a real sentence-end pause. `maxSpeechDurationSeconds=8` still caps long monologues. Affects only `StreamingTranscriptionCoordinator`'s VAD; the live PTT and hands-free auto-stop VAD instances are unchanged.

## [0.4.7] — 2026-05-01

### Fixed
- **Hands-free auto-stop fired mid-utterance and / or never fired in noisy rooms.** Two failure modes from the same root cause: the polling logic gated the silence timer on instantaneous RMS thresholds (relative to a rolling noise floor) and `vad.isCurrentlySpeech`. Both signals are jittery — between-word pauses look like silence, ambient bumps look like speech — so the timer either reset mid-phrase or stayed stuck in a "neither speech nor silent" limbo and never fired. Replaced with a segment-close-event approach: poll `vad.popSegments` at 10 Hz, anchor the trailing-silence timer to the timestamp of the most recent segment that *Silero itself* declared closed (which already requires `minSilenceDuration` of low-probability frames), and gate fire on `!vad.isCurrentlySpeech`. Robust to between-word pauses (segment is still open during them) and to noisy environments (Silero waits for a real silence interval before closing). RMS-based logic dropped entirely from the auto-stop path.
- **Post-recording silence gate could falsely flag empty when hands-free was on.** The new polling drains segments out of Silero's queue, so by stop time `endOfStream()` only sees the residual in-progress segment. Added `AudioService.hadAnySpeechSegment` (set whenever the polling task pops anything) and OR'd it into the gate's emptiness check.

## [0.4.6] — 2026-05-01

### Changed
- **Hands-free trailing-silence slider raised to 1.0 – 10.0 s** (was 1.0 – 3.0 s). Three seconds is too short for thinking between sentences in a slow dictation flow — feedback from real use was that the auto-stop fired before the user was ready for the next utterance. Detection thresholds (RMS noise floor, speech / silence margins) are unchanged; only the configurable upper bound moved.

## [0.4.5] — 2026-05-01

### Fixed
- **Hands-free required two hotkey presses to start the next recording.** When auto-stop fired, only `AppCoordinator.state` and `AudioService` knew the recording had ended — `HotkeyService.isRecording` stayed `true`. The next hotkey press toggled it back to `false` and emitted `.stopRecording` (a no-op at the coordinator since state was already `.idle`); only the press *after that* emitted `.startRecording`. Added `HotkeyService.notifyRecordingStopped()` and called it from both auto-stop callbacks (V1 and streaming) so the hotkey's internal state stays in sync with the coordinator.

## [0.4.4] — 2026-05-01

### Fixed
- **Hands-free auto-stop fired internally but never reached the coordinator.** Diagnosed from a noisy-environment session where Console showed `Hands-free auto-stop: 2.00s silence (rms -17.7 dB, floor -23.1 dB)` followed by 18 seconds of nothing — recording only stopped when the user manually pressed the hotkey. The signal path used an `AsyncStream<Void>` shared across recordings; back-to-back stop/start cycles race on the iterator lifecycle (the cancelled task's iterator can grab the next yield before the new task's iterator becomes active, silently dropping the event). Replaced with a plain callback `AudioService.onAutoStop` set per recording and cleared on stop/cancel. No iterator, no race.

## [0.4.3] — 2026-05-01

### Fixed
- **Hands-free auto-stop still failed in genuinely noisy environments.** v0.4.2 used a fixed -50 dB silence floor — that breaks in cafés, open offices, anywhere the ambient level itself sits above the floor, since neither VAD nor RMS ever crosses the threshold. `AudioService.runHandsFreeAutoStop` now keeps a rolling 30 s window of RMS samples, estimates the noise floor as the 10th percentile, and treats speech as ≥ 8 dB above the floor / silence as within 4 dB of it. Adapts to quiet rooms and loud rooms without tuning.

## [0.4.2] — 2026-05-01

### Fixed
- **Hands-free auto-stop never fired on noisy mics.** The trailing-silence timer polled `VadService.isCurrentlySpeech` only — Silero's 0.5 probability threshold can stick on for environments with persistent background noise (HVAC, fan, room tone), preventing the timer from ever starting. `AudioService.runHandsFreeAutoStop` now combines VAD's live flag with instantaneous RMS (calibrated against the same -50 dB floor as the post-recording silence gate). `sawSpeech` requires both signals to agree it's speech, so a noisy room can't trigger an instant premature stop; the trailing-silence timer runs whenever either signal indicates silence, so a stuck-on VAD no longer blocks the auto-stop.

### Changed
- **Settings warns when hands-free is enabled without VAD.** Picking the hands-free recording mode now auto-attempts `setUseVAD(true)` (no-op if the Silero model isn't downloaded). When VAD remains off, an inline orange caption under the auto-stop slider tells the user to enable VAD in the Model tab — previously the mode silently no-opped at recording time and the pill stayed in `recording` forever.
- **Menu bar label is icon-only.** `MenuBarExtra` label switched from `.titleAndIcon` to `.iconOnly`. The "Murmur" string is kept on the underlying `Label` for accessibility but no longer takes menu bar real estate.

## [0.4.1] — 2026-04-29

### Added
- **Settings → Voice Activity Detection toggle.** Flipping ON downloads the Silero VAD model (~2 MB) if missing and wires it into all four consumers — live PTT silence gate, hands-free auto-stop, V3 streaming chunk boundaries, and long-audio chunking + paragraph breaks. OFF cleanly tears down the wiring and reverts to the legacy paths. Mirrors the ASR-punctuation toggle pattern: persisted in `UserDefaults` under `useVAD`, downgraded to OFF on launch if the model isn't on disk.

## [0.4.0] — 2026-04-29

### Added
- **Voice Activity Detection across all transcription paths.** Silero VAD (~2 MB ONNX, lazy-downloaded as `AuxiliaryModel.sileroVad`) now drives endpointing app-wide. New `VadService` wraps the vendored `SherpaOnnxVoiceActivityDetectorWrapper`; `AudioService`, `AudioBufferAccumulator`, `StreamingTranscriptionCoordinator`, and `NativeTranscriptionService` all consume it with graceful fallback to the legacy paths when the model is missing.
- **Hands-free recording mode.** New `RecordingMode.handsFree` in Settings → Recording → Mode. Tap the hotkey to start; recording auto-stops after a configurable trailing-silence window (slider, 1.0–3.0 s, default 1.5 s). Push-to-talk and toggle modes preserved; hands-free is opt-in.
- **VAD-driven streaming chunks (V3).** `AudioBufferAccumulator` accepts a `VadService` and emits one chunk per detected speech segment instead of fixed 3-second slices. Cap raised to 8 s `maxSpeechDuration` for ASR context. Cleaner clause boundaries, fewer mid-word breaks.
- **VAD-driven long-audio chunking + paragraph breaks.** `NativeTranscriptionService.transcribeLong` runs a one-shot VAD pass over loaded audio, merges speech segments into windows up to 30 s (silence dropped from inference input), and inserts `\n\n` between windows separated by ≥ 2 s — implements the heuristic from `docs/specs/meeting-transcription.md:184`. Falls back to fixed 30 s + 5 s overlap when VAD is unavailable.

### Changed
- **Live silence gate is now Silero-driven, not peak-RMS.** When the VAD model is on disk, `AudioService.stopRecording` consults `VadService.endOfStream()` instead of the -65 dB peak floor. Quiet-speech misfires from voice-processing AGC artefacts go away. Legacy peak-RMS gate retained as fallback for cold-start before the model is downloaded.

### Notes
- The VAD model auto-attaches at app boot when `~/Library/Application Support/Murmur/Models-SileroVAD/onnx/model.onnx` exists. A Settings toggle to trigger the download is a follow-up.
- `Murmur/Services/ONNXTranscriptionBackend.swift` gained an inline pointer to `Scripts/patch-ort-float16.sh` so future readers know where the `.float16` enum case originates (the patch is run by `release.yml` after `swift package resolve`).

## [0.3.5] — 2026-04-26

### Fixed
- **Model download failed silently under Cloudflare WARP / Zero Trust.** Two compounding problems: (1) the v0.3.4 fix pointed Python at `/etc/ssl/cert.pem`, which on macOS is an Apple-shipped static bundle — *not* regenerated from the System keychain, so WARP's intercepting root was never trusted; (2) the Python subprocess only printed output after termination, so a hung TLS handshake produced zero log signal until eventual timeout. Both fixed: Murmur now builds `~/Library/Application Support/Murmur/cabundle.pem` once per launch by concatenating certifi's defaults with anchor certs dumped from `/Library/Keychains/System.keychain` and `/System/Library/Keychains/SystemRootCertificates.keychain` via `security find-certificate -a -p`. That bundle picks up any user-installed roots (including Cloudflare WARP / Zero Trust). Subprocess stdout/stderr are now streamed line-by-line into the unified log (`py>` / `py!` prefixes), and the download script prints probe markers and tags exceptions with their type so failures stop being invisible.

### Added
- **Settings → General → Network (Advanced) → Custom CA bundle.** File picker for a `.pem`/`.crt`/`.cer` containing the root(s) you want trusted during model downloads. Overrides the auto-generated bundle. Useful for enterprise environments where the keychain dump is incomplete or you keep your own portable PEM. Stored in `UserDefaults` under `customCABundlePath`.

### Resolution order for the CA bundle
1. `customCABundlePath` from Settings, if set and the file exists.
2. `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` if you launched Murmur with them pre-set.
3. The auto-generated keychain-aware bundle.

## [0.3.4] — 2026-04-26

### Fixed
- **Model download failed under Cloudflare WARP / Zero Trust** with `CERTIFICATE_VERIFY_FAILED`. *(Superseded by 0.3.5 — the fix pointed at `/etc/ssl/cert.pem`, which on macOS does not include user-installed keychain roots.)*

## [0.3.3] — 2026-04-26

### Performance
- **FireRed transcription ~17% faster** by passing `numThreads: 4` to sherpa-onnx (default was 1 — single-threaded CPU inference for a 1B-param int8 ONNX). Measured on the spike's 14.7 s reference clip: RTF 0.545 → 0.450. CoreML execution provider was *evaluated and rejected* — it's ~15× slower on this int8 model because most ops can't be delegated and the fallback path is slow. 8 threads was also evaluated and is slightly *worse* than 4 due to perf-cluster contention. See `run_speed_sweep.py` in the spike workspace.

## [0.3.2] — 2026-04-26

### Fixed
- **ASR punctuation skipped on Chinese speech when IME was English**. Two stacked bugs both rooted in trusting the IME-derived language hint instead of the actual transcript content:
  1. `routedTranscribeV1` tagged FireRed transcripts with the *input language hint* — so an English IME + Chinese audio yielded `result.language = .english`. The auto-detect retry then logged "english matched — no retry" even though the transcript was 中文.
  2. `applyASRPunctuationIfEnabled` skipped when `language == "en"` to avoid the CT-Transformer appending a Chinese 。 to pure-English text. Combined with #1, Chinese audio under English IME got no punctuation at all.

  Both checks now look at content: FireRed transcripts are tagged by CJK-character ratio (mirrors `NativeTranscriptionService.detectLanguage`), and ASR-punc runs whenever the transcript contains CJK Unified Ideographs (and no Japanese hiragana/katakana, since CT-Transformer is zh-en only).

## [0.3.1] — 2026-04-26

### Removed
- **HuggingFace ("High Quality") and Whisper backends**. Both were rarely-chosen alternatives to the default Cohere ONNX backend. Murmur now ships with two backends: **Standard** (Cohere ONNX, multilingual) and **FireRed** (Chinese-first). Existing users on `huggingface` or `whisper` backends are auto-migrated to `onnx` on next launch (the `ModelBackend.init(rawValue:)` lookup falls back to `.onnx` for unknown raw values). The on-disk `~/Library/Application Support/Murmur/Models/` (HF) and `Models-Whisper/` directories are left untouched — delete them manually to reclaim disk if you used those backends. Onboarding's HuggingFace-login step is gone too (Cohere ONNX repo is public, no token needed). Settings → Speech Engine is now a flat two-row picker, no Advanced disclosure.

### Added
- **Version label in Settings** (General tab footer) reads `CFBundleShortVersionString` from `Info.plist`. Helpful when filing bug reports.

### Fixed
- **Duplicate Settings windows** — fast clicks during the close animation could leave two windows on screen simultaneously. The reuse path no longer requires `isVisible == true`; any prior NSWindow (with `isReleasedWhenClosed = false`) is brought back to front instead. Same fix applied to Recent Transcriptions.

## [0.3.0] — 2026-04-26

### Added
- **ASR Punctuation** as an opt-in toggle in Settings → ASR Punctuation. Runs the [sherpa-onnx CT-Transformer](https://huggingface.co/csukuangfj/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12) zh-en model on the bare ASR transcript at ~1 ms per clip, inserting `，。？！` into otherwise unpunctuated output. Particularly useful with FireRed (which never emits punctuation on its own); harmless with Cohere (whose punctuation is preserved unchanged — the model is conservative on already-punctuated text). Skipped for pure-English audio (the zh-dominant CT-Transformer otherwise appends a Chinese 。 in English context). ~280 MB aux model, downloaded on demand. Recommended for Chinese users together with the FireRed backend.
- **Post-transcription cleanup** as an opt-in toggle in Settings → Model. After V1 transcription succeeds and before text is injected, the cleanup service applies rule-based fixes on a 250 ms hard cap; any timeout or error silently falls back to the raw text.
  - **English:** sentence-initial capitalisation, capitalisation after `.?!` + whitespace, standalone "i" → "I" (word-boundary, no proper-noun gazetteer), terminal period if missing, leading/trailing whitespace trim.
  - **Chinese:** appends `。` if the text doesn't already end in a recognised CJK or Western terminal (or closing CJK quote/bracket); converts a trailing ASCII `.` `?` `!` to the full-width equivalent (`。` `？` `！`); leaves mid-text ASCII punctuation alone so embedded Latin fragments like "Python 3.11" are preserved.
  - Japanese, Korean, and any other language code pass through unchanged.
  - V3 streaming is deliberately excluded from cleanup; only the V1 full-pass path runs it.
- **FireRed Chinese ASR backend** as a 4th engine option, plus an opt-in "Use FireRed for Chinese transcription" toggle visible under Cohere backends. Both routes share the same on-disk FireRed model files (`csukuangfj2/sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26`, ~1.24 GB).
  - **Quality:** in spike testing on SenseVoice's `asr_example_cn_en.wav` Chinese-English mixed sample, FireRed achieved 8.94% CER vs Cohere's 22.76% (zh prompt). FireRed preserves character-level fidelity including English code-switching ("做 machine learning 做 deep learning…"); Cohere paraphrases.
  - **Routing:** Toggle ON: V1 Chinese audio routes to FireRed; English and other languages stay on Cohere. FireRed backend: Chinese + English use FireRed; other languages auto-fallback to Cohere ONNX (also requires Cohere ONNX downloaded).
  - **V3 streaming unchanged:** sherpa-onnx FireRedASR2-AED has no streaming mode; V3 always uses Cohere regardless of toggle/backend.
  - **Bundling:** Adds vendored sherpa-onnx v1.12.40 macOS xcframework (~42 MB compressed in repo, links to existing `onnxruntime-swift-package-manager` — no duplicate ONNX runtime).

### Fixed
- **Local-LLM correction with reasoning models (Qwen3, DeepSeek-R1, OpenAI o1-style)** silently produced empty output, causing every correction to fall back to the raw transcript and effectively disabling punctuation/sound-alike fixes. Root cause: those models put their answer in `message.reasoning` and leave `message.content` null, which the correction safety-rail reads as empty and discards. The OpenAI-compatible corrector now sends `chat_template_kwargs={enable_thinking: false}` so reasoning models emit their answer directly into `content`. Backends that don't honour this kwarg (Ollama, plain llama.cpp) ignore it harmlessly.

## [0.2.4] — 2026-04-25

### Added
- Audio-based language identification (LID) as an opt-in auxiliary model. When enabled, the app runs a locally-installed Whisper-tiny ONNX encoder + one decoder step on the first 5 s of the recording to pick a language before handing audio to Cohere. Falls through to the existing IME-based resolver on any failure or low-confidence result. Streaming V3 deliberately skips LID to avoid pre-roll latency. Opt-in via a new Settings section that downloads the ~40 MB auxiliary model on demand.

### Fixed
- CoreAudio error -10868 (`kAudioUnitErr_FormatNotSupported`) after the app sat idle through sleep/wake or an audio route change (e.g. Bluetooth mic disconnect, display-with-mic sleep). `AudioService` now observes `AVAudioEngineConfigurationChange` and `NSWorkspace.didWakeNotification`, calls `engine.reset()` before the next `startRecording` when either has fired, and reads the live hardware format at record-start instead of relying on the first-buffer format. Early-fails with a clear "No audio input available" message when no input device is present.

### Changed
- Coordinator state and error logs promoted to `.public` privacy so Console.app / `log stream` no longer redacts them as `<private>`, unblocking diagnosis of sleep/wake failures.

(Note: v0.2.3 tag was claimed upstream by an earlier handoff-docs commit on 2026-04-19; 0.2.4 absorbs both the earlier 0.2.3 feature set below and the sleep/wake + LID work above.)

## [0.2.3] — 2026-04-20

### Added
- Language indicator on the recording pill: a small badge (e.g. `EN`, `ZH`) sits between the state icon and the "Recording…" text so the user can confirm which language the model will transcribe in before speaking. When the language setting is `Auto`, the badge gets a trailing middle dot (e.g. `EN·`, `ZH·`) to signal that the value came from the active macOS keyboard input source rather than a fixed Settings choice.
- Cancel button on the recording pill (`xmark.circle.fill`). Clicking goes through the same `.cancelRecording` path as the Esc shortcut.

### Fixed
- Esc-to-cancel-recording now works reliably across macOS versions. The previous implementation used `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`, which silently fails to deliver events on some installs while the `flagsChanged` monitor keeps working — so right-cmd-to-record worked but Esc didn't. Replaced with a Carbon `RegisterEventHotKey` registration (via the existing `HotKey` package) that's installed when recording starts and torn down when it ends. Side effect: Esc is exclusively grabbed by Murmur during a recording.

## [0.2.2] — 2026-04-19

### Added
- FU-07: download stall timeout — if the download makes no byte progress for 90 s the app cancels the subprocess and surfaces a critical `.downloadStalled` NSAlert ("Download stopped making progress") so the user can retry after a network hiccup
- FU-03: subprocess-lifecycle integration tests for `cancelDownload` — real `Process` injection via `__testing_injectDownloadProcess`, covers SIGTERM→SIGKILL escalation, partial-file cleanup, cancel→redownload race
- Test-only `__testing_setModelDirectory(_:for:)` seam redirects model file ops to a temp dir so integration tests can't delete a developer's real installed model

### Fixed
- FU-10: 9 `V3AXSelectReplaceTests` that silently failed on any machine without a focused text field now skip with an actionable message instead of failing CI
- FU-09: `actions/checkout` bumped to `@v5` for Node-24 compatibility (GitHub deprecation)
- FU-11: `CFBundleShortVersionString` in `Info.plist` kept in sync with shipped version

## [0.2.1] — 2026-04-19

### Fixed
- B3: onboarding UI didn't refresh when model download completed
- B4: `isModelDownloaded` returned true mid-download before files were complete
- Backend switch during active download silently torn down the running subprocess (C3); `activeBackend` is now gated by `setActiveBackend(_:)`
- `cancelDownload()` was a no-op — `downloadTask` was declared but never assigned (H4)
- `Process.terminate()` sent SIGTERM without waiting; now escalates to SIGKILL after 2s (C6)
- Cancel→redownload race where the cleanup Task deleted files the new download was writing (C8)
- Termination-handler race in `download()`: handler now attached before `run()` with defensive post-run check
- Monitor task overwrote `.ready` with a stale `.downloading` write after the subprocess exited
- V1 pill lagged 1.5 s behind text insertion because `injectViaClipboard` blocked on clipboard restoration; restore is now a detached Task
- Critical errors (model missing, disk full) now surface as NSAlert with clear copy instead of a truncated pill
- Pre-check on startRecording catches missing-model case before wasted audio capture

### Added
- FU-04 manifest verification: `manifest.json` (SHA-256 + size per file) written after every successful download; hot-path checks (size only) gate `isModelDownloaded`; `verify()` re-hashes on demand; one-time migration generates the manifest for existing on-disk models
- Engine row disabled during active download with "Locked during download" caption + hover tooltip (Settings and onboarding)
- Cancel confirmation dialog above 100 MB ("You've downloaded N MB — cancelling will discard it")
- `MurmurError.Severity` + `shortMessage` + `alertTitle` taxonomy for consistent error presentation
- Every error state transition logged via `os_log` (subsystem `com.murmur.app`, category `coordinator`) for post-hoc diagnosis

### Changed
- Download progress label no longer shows misleading "Finalizing" mid-transfer
- Progress size tracking scoped to the model directory only (previously conflated with unrelated `~/.cache/huggingface` data)
- Pill for `.undoable` state simplified to "Inserted" — removed the transcribed-text preview and "⌘Z to undo" hint (Cmd+Z still works)
- Audio feedback reduced to just two sounds: Tink on record start (system event: mic is live) and Basso on error (system event: failure). Stop/cancel/success chimes removed — the pill and visible text insertion already confirm those user-initiated or visible events. All sounds at 0.18 volume.
- "Cancel" → "Cancel Download" copy unified across Settings and onboarding

## [0.2.0] — 2026-04-13

### Added
- V3 streaming voice input: real-time transcription with live text injection
- Native ONNX transcription backend (pure Swift, no Python dependency)
- Pure Swift MelSpectrogramExtractor replacing ONNX mel_extractor dependency
- 48 QA tests for V3 streaming: edge cases, state machine, focus guard, blocklist
- V2 audio transcription: record, upload, and transcribe long audio locally
- Language picker on upload/recording confirm views before transcription
- "Undo after transcription" toggle in Settings (off by default)

### Fixed
- Microphone permission: request OS dialog on first use instead of showing error
- CI release build: sign with entitlements, run Float16 patch before build
- Streaming coordinator not resetting to idle after session (second recording broken)
- Hotkey unresponsive for 5s after transcription (undoable state blocked new recordings)
- Streaming path missing undo auto-recovery timer (stuck in undoable forever)
- Audio transcription language hardcoded to English when set to auto-detect
- Right Command hotkey missed when Murmur is focused
- 15 pre-existing test failures
- transcribe.py deployment: auto-sync source script to App Support on launch
- Audio transcription showing 0:00 duration in sidebar
- V3 streaming: post-inject cursor check and waitForStreamingDone backstop timeout
- V3 UX: replaced debug chunk count with "Listening...", show undo hint after refinement
- SPM build: guard #Preview macro with canImport(PreviewsMacros)

### Improved
- CPU/focus notifications, streaming indicator, accessibility deduplication
- Removed mel_extractor.onnx dependency — fully native mel spectrogram pipeline

## [0.1.0] — 2026-03-28

### Added
- Initial release: local voice input for macOS using Cohere Transcribe
- Onboarding flow with model download, HuggingFace login, accessibility setup
- Menu bar UI with pill overlay for transcription status
- Multi-backend support (ONNX / HuggingFace / Whisper)
- Auto language detection from active input method
- Transcription history sidebar
- Right Command hotkey trigger
- DMG installer with drag-to-install
- GitHub Actions release workflow

### Fixed
- Model hallucination (garbage repetitive output) on HuggingFace backend
- ONNX crash: import torch before onnxruntime, CoreML, OMP threading
- Pill crash from NSHostingView automatic window sizing
- Download progress stuck at 68%, speed display showing 0 B/s
- VAD threshold too high (-40dB → -60dB)
- Various hotkey capture and settings window issues
