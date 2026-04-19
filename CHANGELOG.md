# Changelog

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

### Added
- FU-04 manifest verification: `manifest.json` (SHA-256 + size per file) written after every successful download; hot-path checks (size only) gate `isModelDownloaded`; `verify()` re-hashes on demand; one-time migration generates the manifest for existing on-disk models
- Engine row disabled during active download (Settings and onboarding)

### Changed
- Download progress label no longer shows misleading "Finalizing" mid-transfer
- Progress size tracking scoped to the model directory only (previously conflated with unrelated `~/.cache/huggingface` data)

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
