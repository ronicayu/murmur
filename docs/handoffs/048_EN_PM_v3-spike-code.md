# Handoff 048 — EN → PM: V3 Phase 0 Spike Code

**From:** EN
**To:** PM
**Status:** RDY
**Date:** 2026-04-10
**Re:** V3 Phase 0 spike deliverables — code complete, awaiting data run

---

## 完成摘要

依 `docs/handoffs/047_PM_EN_v3-approved.md` 指令，Phase 0 spike 代碼已全部寫入磁盤。

---

## 產出文件

### 1. Python Spike 腳本

**路徑：** `Murmur/Scripts/v3_phase0_spike.py`

覆蓋七項spike中之四項（#1, #2, #3, #5）：

| # | 測試名 | 方法 |
|---|--------|------|
| 1 | Chunk邊界錯誤率 | 對每個音頻文件：full-file baseline，2s/3s/5s chunks各自拼接後計算normalized edit distance |
| 2 | 首chunk延遲 | 取第一個音頻文件之首chunk，2s/3s/5s各跑10次，取中位數 |
| 3 | 30s streaming CPU佔用 | 10×3s chunks連續推理，psutil記錄每chunk之CPU% |
| 5 | Streaming vs full-pass差異 | 與Test #1同邏輯，但chunk size固定3s，集中報告edit distance統計 |

**使用方法：**
```
python3 Murmur/Scripts/v3_phase0_spike.py \
    --model-path ~/Library/Application\ Support/Murmur/Models-ONNX \
    --audio-dir <wav文件目錄> \
    --test all \
    --output v3_phase0_report.json
```

**依賴：** `editdistance`, `psutil`, `soundfile`（已在現有dev requirements中或需補充）

**複用：** 直接 `importlib.util` 加載 `transcribe.py`，複用 `transcribe_onnx()` 及 `load_model()`，無重複代碼。

---

### 2. Swift 測試

**路徑：** `Murmur/Tests/V3Phase0Tests.swift`

覆蓋七項spike中之兩項（#4, #6）：

#### Spike #4 — AX select+replace（需Accessibility permission）

- `V3AXSelectReplaceTests` — 五個per-app測試方法（Notes, TextEdit, VS Code, Terminal, Safari）
- `test_axSelectReplace_spikeSummary_atLeast3of5Apps` — 匯總test，直接評估exit criterion（≥3/5通過）
- `test_axFocusChangeNotification_canBeObserved` — 驗證 `kAXFocusedUIElementChangedNotification` 可被AXObserver訂閱（focus guard可行性）
- VS Code與Terminal已標記 `XCTExpectFailure`（Electron/Terminal AX支持已知受限）
- 所有test開頭呼叫 `requireAccessibilityPermission()`，未授權則 `XCTSkip`（CI安全）

#### Spike #6 — Dual-output AudioService（無需特殊權限）

- `V3DualOutputAudioTests` — 三個測試：
  - **#6a** `test_bufferAccumulator_firesCallback_atChunkInterval` — 驗證累積器在達到chunk大小時觸發callback
  - **#6b** `test_dualOutput_wavFileAndBufferCallback_coexist` — 驗證WAV寫入與streaming callback可在同一tap路徑並存
  - **#6c** `test_bufferAccumulator_flush_returnsPartialChunk` — 驗證錄音結束時flush返回剩餘partial buffer
- `AudioBufferAccumulator` class — spike驗證用最小實現，附NSLock線程保護
  - 生產版本將移入 `AudioService`（V3 feature flag路徑，不觸碰V1 code path）

---

### 3. Spike #7 — V1 Code Path 隔離 Review

**結論：V1 code path完全隔離，streaming code可安全加入。**

現有架構已自然隔離：

```
AudioService.swift
  startRecording() / stopRecording()          ← V1/V3共用，無需改動
  inputNode.installTap(...)                   ← 現有tap寫WAV
                                              ← V3將在同一tap加 accumulator.append()
                                                 （feature flag保護）

TranscriptionService.swift
  transcribe()                                ← V1 pipeline — 不改動
  transcribeLong()                            ← V2 pipeline — 不改動
  (新增) transcribeStreamChunk()              ← V3專屬，獨立方法，獨立stdin命令

transcribe.py
  transcribe_onnx() / transcribe_huggingface() ← V1/V2共用 — 不改動
  transcribe_onnx_chunked()                    ← V2 — 不改動
  (新增) handle_transcribe_stream_chunk cmd    ← V3專屬stdin命令

Feature flag:
  UserDefaults "streamingInputEnabled"         ← 默認false
  AppCoordinator — hotkey handler分支：
    if streamingEnabled → StreamingVoiceInputSession (全新)
    else → 現有V1 VoiceInputSession (不觸碰)
```

**V1受影響行數：0。** V3新增code僅在feature flag為true時執行。

---

## Phase 0 待執行

以下需在有模型及測試音頻的機器上人工執行：

```
# 準備測試音頻（LibriSpeech dev-clean subset，5 EN + 5 ZH）
# 或使用現有 prepare_test_audio.py

# 跑Python spike（#1,#2,#3,#5）
python3 Murmur/Scripts/v3_phase0_spike.py \
    --model-path ~/Library/Application\ Support/Murmur/Models-ONNX \
    --audio-dir /tmp/v3_test_audio \
    --output v3_phase0_report.json

# 跑Swift spike（#4,#6）
xcodebuild test -scheme Murmur -only-testing MurmurTests/V3Phase0Tests
```

**Swift #6 tests（無Accessibility）可在CI跑。**
**Swift #4 tests需手動授權Accessibility後本機跑，每個app需手動開啟並將游標置於text field。**

---

## Kill criteria 狀態

代碼已完備，數據尚未採集。待執行後由PM/EN聯合評估：

| Kill criterion | 閾值 | 狀態 |
|---------------|------|------|
| 首chunk延遲（中位） | > 8s → V3 cancelled | 待測 |
| Streaming CPU sustained | > 90% 無解 → V3 cancelled | 待測 |
| Edit distance avg | > 40% → V3 cancelled | 待測 |
| Select+replace | < 3/5 app → replacement deferred | 待測 |

---

## 依賴項補充

需確認 `requirements-dev.txt` 包含：
- `editdistance` （spike #1, #5）
- `psutil` （spike #3，V2 spike已有）
- `soundfile` （spike所有音頻讀取）

---

**out:** EN spike代碼交付完畢。待PM確認音頻素材路徑後可立即執行。
