# Audio Transcription — V2 Spec

**Author:** @PM
**Status:** REQ
**Created:** 2026-04-10
**Revision:** 9 (UAT triage — B1 voice input fix, search, .wav upload, paragraph breaks)

---

## Positioning

Input為macOS系統級語音輸入工具。V2新增長音頻轉寫，為voice input之自然延伸——同一模型、同一privacy promise、零額外下載。

**一句話差異化：** 你已有的語音輸入工具，順便也能轉寫長音頻。

**非目標：** Input不是meeting intelligence工具。不做diarization、不做summary、不做action items。此為plain transcript工具。需要完整會議記錄方案者，MacWhisper或Otter為更好選擇。

**Target user：** 已用Input做voice input、偶爾需轉寫一段錄音、不願另裝app之人。

---

## Problem

Meeting notes are a tax on attention. You either listen or you write — not both. Cloud transcription tools (Otter, Fireflies, Notion AI) solve this but require sending audio to remote servers. For legal discussions, medical consultations, HR conversations, and internal strategy meetings, that's a non-starter.

Input already runs Cohere Transcribe locally. The model may handle long-form audio with a chunked pipeline. We should let users point it at recordings too — same privacy guarantee, new job-to-be-done.

**Core bet:** Users who trust Input for voice input will trust it for audio transcription, because the value prop is identical — useful transcription, zero cloud dependency.

**Gate:** Phase 0 spike must validate this bet before any UI or architecture work begins.

### Phase 0 裁定 (2026-04-10): **FINAL GO**

Phase 0 spike全部通過（multi-speaker因無數據集未測，per spec deferred）。

**最終數據：**

| Test | Result | Detail |
|------|--------|--------|
| #1 Chunk策略 | **PASS** | 逐chunk串行，12 chunks / 5min，未OOM |
| #2 Speed | **PASS** | RTF = 0.97x（M1 8GB CPU）|
| #3 WER (ONNX) | **PASS** | 0.59% avg normalized |
| #4 Multi-speaker | **未測** | 無數據集 → deferred |
| #5 Memory | **PASS** | RAM delta = -44MB |
| #6 m4a decode | **PASS** | ffmpeg中轉 |
| #7 .ogg decode | **PASS** | soundfile直讀 |
| #8 activationPolicy | **PASS** | 8/8 Swift tests |
| #9 App Nap | **PASS** | API正常 |

**Kill criteria全部通過：**

| Criteria | Threshold | Actual | 餘裕 |
|----------|-----------|--------|------|
| ONNX WER (normalized) | < 20% | **0.59%** | 33x |
| Peak RAM delta | < 500MB | **-44MB** | N/A |
| Processing speed | < 2x RT | **0.97x** | 2x |

**已確認排除項：**
- HF backend: M1 8GB載入167s，不可用
- CoreML: q4f16僅1.6% nodes支持，全fallback CPU
- 8GB支持: OOM不可解，spec已為16GB+

---

## Phase 0 — Validation Spike (MUST PASS BEFORE V2 BUILD)

Phase 0 is a time-boxed engineering spike (max 5 days). No UI, no architecture. Pure validation.

### Spike deliverables

| Test | Method | Exit criteria |
|------|--------|---------------|
| Chunk strategy | Test 30s / 60s / 120s chunks with 5s overlap vs VAD-based splitting. Measure cross-boundary sentence coherence. | One strategy produces < 5% sentence-break errors on 10 test files |
| Processing speed | Benchmark 5 / 15 / 30 / 60 / 120 min audio files on M1 Pro 16GB | Measured ratio (processing time / audio duration) documented |
| Single-speaker accuracy | 5 EN + 5 ZH single-speaker recordings, measure WER/CER | Baseline documented |
| Multi-speaker accuracy | 5 EN + 5 ZH multi-speaker recordings (2-4 speakers), measure WER/CER | Baseline documented. If WER < 80%, multi-speaker deferred |
| Memory usage | Monitor RAM during 120 min file processing | Peak RAM < model baseline + 500 MB |
| m4a decode pipeline | Confirm Cohere Transcribe accepts decoded m4a audio stream | Pass/fail |
| .ogg decode pipeline | Confirm AVFoundation or alternate path can decode .ogg to PCM | Pass/fail + dependency documented. If fail → .ogg removed from supported formats |
| activationPolicy switching | Informal validation: `.accessory` ↔ `.regular` runtime switching on macOS 14+. Test Dock icon, Cmd+Tab, Space behavior | Documented findings. If problematic → fallback to always `.regular` |
| System sleep / App Nap | Test AVAudioRecorder behavior during lid-close and App Nap. If recording silently stops → use `NSProcessInfo.performActivity` | Documented behavior + mitigation if needed |

**Test audio files:** EN自行準備或使用公開數據集（LibriSpeech for EN, AISHELL for ZH）。License須為研究/開發可用。20個文件須在spike Day 1前就位。

### Spike outcomes → V2 scope decisions

- If processing speed > 2x real-time on M1 Pro → V2 scope shrinks to files < 15 min, or V2 is cancelled.
- If multi-speaker WER < 80% → V2 marketed as single-speaker only. Multi-speaker deferred.
- If chunk stitching produces > 5% sentence-break errors with all strategies → V2 is cancelled.
- If RAM exceeds baseline + 500 MB → investigate streaming decode before proceeding.
- If .ogg decode fails without acceptable dependency → .ogg removed from upload formats.
- If activationPolicy switching is unreliable → fallback to always `.regular` (permanent Dock icon).

---

## Architecture Decisions (rev 3)

### Dual-window model

| Component | Role | Relation to V1 |
|-----------|------|-----------------|
| Menu bar popover | Voice input (V1 feature) | Unchanged. Adds "Open Transcription" entry point |
| Main window | Record, upload, transcribe, history | New in V2 |
| Dock icon | App visibility | `activationPolicy = .accessory`, switches to `.regular` when main window opens |

**Rationale:** Audio transcription requires reading long text, managing history, and monitoring progress — tasks that don't fit a 260pt popover. Separate window keeps V1 popover untouched.

### Dock strategy: accessory policy (approved)

- Default: `.accessory` (menu bar app, no Dock icon)
- Main window open: temporarily `.regular` (Dock icon visible, appears in Cmd+Tab)
- Main window closed: revert to `.accessory`
- Follows macOS conventions (cf. Bartender, PopClip settings windows)

### Main window layout: sidebar + main area

- Sidebar (200pt, resizable 160–280pt): history list, grouped by date, "+" New button, Settings
- Main area: state machine — Idle / Recording / Confirm / Transcribing / Result
- Window close does not stop active recording/transcription — background continues, menu bar icon reflects state

### Global hotkey: `Cmd+Shift+T` (approved)

Opens or focuses the main window. Not user-configurable in V2.0 — ship opinionated default, revisit if conflicts reported.

### History limit: 50 entries (approved)

- 2GB disk cap applies to transcript text + m4a temp files
- Completed transcriptions delete m4a (text-only ~100KB each)
- 50 text transcripts ≈ 5MB worst case — well within budget
- m4a files only exist transiently during active sessions
- DA's recommendation accepted: 20 was unnecessarily conservative

---

## User Stories

### Record Mode
1. **Start a recording.** User opens Input's main window, hits Record. Audio streams from the selected input device to a local m4a file. Timer shows elapsed time. **Duration cap: 2 hours.**
2. **Stop and transcribe.** User stops recording. Confirmation page shows audio details + estimated time. User confirms "Start Transcription" — **voice input pauses only now** (not during recording). Progress indicator shows estimated time remaining as a range (e.g., "About 1-2 min remaining"). User can background the app during processing.
3. **Review transcript.** Plain text transcript appears in a scrollable, full-height text view. **Paragraph breaks inserted where silence between chunks exceeds 2 seconds.** User can copy all, select portions, search with Cmd+F, or export as .txt.

### Upload Mode
4. **Upload an audio file.** User drags or selects a file (.mp3, .m4a, .caf, .ogg, **.wav**). Input validates the format, checks duration (max 2 hours), and shows file duration + estimated transcription time before starting.
5. **Transcribe uploaded file.** Same local processing pipeline as record mode. Same progress UI. Same voice input pause behavior.
6. **Review and export.** Same transcript view as record mode.

### Shared
7. **Transcript history.** Sidebar list of past transcriptions (last 50) with date, duration, and first-line preview. **Search field at top of sidebar** — simple string match against transcript text, filters list in real-time (in-memory, no indexing needed). Transcripts stored locally. User can delete individually or clear all. Failed transcriptions show retry option.
8. **Cancel in progress.** User can cancel transcription mid-process. Inline confirmation shows progress %. Partial results are discarded. Voice input resumes immediately upon cancel.
9. **Voice input conflict.** Voice input pauses **only during transcription processing** — never during recording. Before user confirms "Start Transcription" (both record and upload modes), Input shows: "Voice input will pause during transcription." Voice input resumes immediately on completion or cancel. Menu bar icon changes to indicate paused state.

---

## Success Metrics

Phase 0 spike完成，數據已填入。

| Metric | Target | Baseline (Phase 0) | Measurement |
|--------|--------|---------------------|-------------|
| Transcription speed | < 1.5x real-time (M1 Pro 16GB) | **0.97x RT** (M1 8GB CPU) | Benchmark suite |
| Accuracy (EN, single-speaker, normalized) | WER < 5% | **0.59%** | jiwer, normalized |
| Accuracy (ZH, single-speaker) | CER < 10% | 未測（Phase 1補） | jiwer |
| Accuracy (multi-speaker) | Deferred | 未測（無數據集）| — |
| Upload-to-transcript (5 min file) | < 6 min | **~5 min** (M1 8GB) | Timer |
| Peak RAM delta | < 500 MB above model baseline | **-44 MB** | memory_profiler |
| Feature adoption | > 20% WAU try within 30 days | — | Local analytics (UserDefaults) |

**Notes:**
- Speed/WER baselines測於M1 8GB（worst-case hardware）。Target hardware為M1 Pro 16GB，預期更優。
- EN WER 0.59%遠超預期。Target設5%留有餘裕（production環境含噪音、非標準口音）。
- Speed target設1.5x RT（非1x）以容納longer files及噪音場景之variance。

---

## Scope

### In V2.0
- Main window with sidebar + main area (dual-window model)
- Record mode (single input device, not system audio, **m4a format, 2 hour cap**)
- Upload mode (.mp3, .m4a, .caf, .ogg, **.wav**, 2 hour cap)
- Chunked processing for long audio (strategy determined by Phase 0 spike)
- Plain text transcript view with copy/export (.txt), Cmd+F search
- Transcript history (last 50, stored locally, deletable, with failed-retry support, **sidebar search**)
- **Paragraph breaks** in transcript output (silence > 2s heuristic)
- Progress UI with cancel confirmation (shows %), ETA as range
- Auto language detection (same as v1 — Chinese/English)
- Voice input pause/resume **during transcription only** (not during recording) with user notification
- Menu bar state indicator: 3 states (idle / active / processing)
- Dock: accessory policy, visible when main window open
- Global hotkey `Cmd+Shift+T` to open/focus main window
- Transcription queue: max 1 item, no stacking
- Background operation: window close does not stop active session

### Deferred (V2.x or later)
- **Speaker diarization.** High value but requires a separate model or significant pipeline work. Revisit when Cohere Transcribe adds native support.
- **Timestamps / seek-to-audio.** Useful but adds UI complexity. Wait for user demand.
- **System audio capture.** Requires a virtual audio driver (kernel extension or AudioServerPlugin). Heavy lift, privacy implications. Not yet.
- **Rich export formats.** Markdown, SRT, DOCX. Plain text first — see if anyone asks.
- **Summary / action items.** Requires an LLM, not just ASR. Out of scope for a transcription tool.
- **Real-time streaming transcription.** Different architecture. Different product.
- **Editable transcript.** Text editing UI is a product unto itself. Copy to your editor.
- **Multi-speaker optimization.** If Phase 0 shows WER < 80%, multi-speaker is deferred until model improves.
- ~~**WAV upload support.**~~ **Moved to V2.0** (rev 9). Upload mode only — no disk footprint concern since file is user's, not ours.
- **Configurable global hotkey.** Ship `Cmd+Shift+T` first. Make configurable if conflict reports arise.

---

## Constraints

1. **Local-only.** No audio or transcript ever leaves the machine. Same as v1. Non-negotiable.
2. **No additional download.** V1與V2皆用Cohere Transcribe (ONNX)。同一模型，零額外下載。
3. **macOS / Apple Silicon / 16 GB+.** Same hardware requirements as v1. **8GB明確不支持——Phase 0實測OOM，非可解問題。**
4. **No new permissions.** Microphone permission already granted. File upload uses standard file picker (no new entitlements).
5. **Memory budget.** Long audio processing must not spike RAM beyond model baseline + 500 MB. Stream audio from disk, process in chunks.
6. **Recording format: m4a (AAC).** Compressed. ~50-70 MB per hour. Not negotiable in V2.0.
7. **Duration cap: 2 hours.** Both record and upload modes. Adjustable in V2.x based on Phase 0 data.
8. **Disk budget: 2 GB cap on m4a recording files only.** Transcript text不計入（50筆×100KB≈5MB，可忽略）。Warn at 80% (1.6 GB). Refuse new recording at 100%. Completed transcriptions delete m4a — cap主要約束concurrent temp files及failed retry之保留m4a。User deletes manually — no auto-delete.
9. **Disk space check.** Refuse to start recording if < 1 GB free disk space.
10. **Voice input exclusivity.** Transcription **processing** and voice input cannot run concurrently. Voice input pauses only when transcription starts (not during recording). Auto-resume on completion or cancel.
11. **Transcription queue: max 1.** No stacking. User must wait for current transcription to finish.
12. ~~**Phase 0 gate.**~~ **PASSED (2026-04-10).** V2 Phase 1 greenlit.
13. **History limit: 50 entries.** Oldest auto-pruned when exceeded.

---

## Edge Cases (rev 4)

### System sleep / App Nap during recording
- If user closes lid or macOS triggers App Nap, AVAudioRecorder may silently stop.
- EN must validate behavior in Phase 0 spike.
- Mitigation: `NSProcessInfo.performActivity(reason:options:using:)` to suppress App Nap during active recording/transcription.
- If mitigation insufficient, UI must detect and inform user that recording was interrupted.

### Orphan m4a files
- **Delete history item → delete associated m4a.** No orphans.
- **Retry success → delete m4a** per existing file destiny rule (transcription complete = m4a deleted).
- **App update/reinstall:** On launch, scan App Support for m4a files not referenced by any history entry. Delete orphans silently.
- EN must guarantee: no code path leaves an m4a without a corresponding history entry (or pending operation).

---

## Open Questions (Phase 1)

1. ~~**Chunk strategy details.**~~ **已解決。** 30s chunks + 5s overlap，逐chunk串行。Overlap trimming用2wps heuristic（Phase 1改善）。
2. **Progress estimation.** RTF 0.97x穩定。**PM建議：顯示range ETA（"About X-Y min remaining"）。** EN於Phase 1確認variance是否足夠穩定。
3. ~~**Audio decode pipeline.**~~ **已確認：m4a需ffmpeg中轉。** PM決定：方案C（AVFoundation）優先，方案A（bundle ffmpeg）備選。
4. ~~**activationPolicy switching.**~~ **已驗證：PASS。**
5. **中文overlap trimming。** Word-count heuristic對無空格語言失效。Phase 1須實現character-based trimming。（新增）

## Architecture Decisions (rev 5 additions)

### Backend: V1與V2統一ONNX (rev 7 逆轉)

| Feature | Backend | 理由 |
|---------|---------|------|
| V1 voice input | ONNX (Cohere q4f16) | 低延遲優先。CPU-only但短語足矣 |
| V2 audio transcription | ONNX (Cohere q4f16) | WER 3.9%（normalized）勝Whisper 7.8%。速度1-2s/file vs 3-8s。RAM ~300MB。CPU-only，無需GPU |

**Rev 7逆轉理由：** Rev 6以ONNX WER 24.4%為據改用Whisper。該數據為jiwer未normalize標點/大小寫所致偽WER。

**最終數據（Phase 0 spike完成）：**

| Backend | Avg WER (normalized) | Speed | RAM |
|---------|---------------------|-------|-----|
| ONNX (CPU) | **0.59%** (short) / **0.97x RT** (long chunked) | 1-2s/chunk | delta -44MB |
| Whisper (MPS) | **7.8%** | 3-8s/file | GPU memory |

ONNX於準確度、速度、RAM三項全勝。無理由用Whisper。

**CoreML已排除。** q4f16量化模型僅1.6% nodes被CoreML支持，全fallback CPU。

**HF backend已排除。** M1 8GB載入167s，inference不完成。

**ONNX float32已排除。** ~4GB模型，RAM需求過高，且無GPU加速。

**OOM問題仍在：** ONNX batch mode長音頻OOM。V2須逐chunk串行處理——此為已知解法，非blocker。

**Constraint #2恢復：** V1與V2用同一模型（ONNX Cohere q4f16）。零額外下載。Privacy promise不變。

### Chunked pipeline: 逐chunk串行 (Phase 0 裁定)

CohereAsrProcessor的batch mode將所有chunks同時載入記憶體，長音頻必OOM。V2須：
1. 手動切分音頻為chunks
2. 逐chunk串行送入model
3. 拼接transcript

此為Phase 1新增工程工作，取代原本「直接用processor」之假設。

### ffmpeg依賴 (Phase 0 裁定)

m4a decode需ffmpeg。選項：
- 方案A：Bundle ffmpeg binary（增加app size ~80MB）
- 方案B：要求用戶安裝ffmpeg（UX劣化）
- 方案C：用AVFoundation decode（須EN驗證可行性）

**PM建議：方案C優先，方案A備選。方案B排除——UX不可接受。**
