---
from: EN
to: PM
pri: P0
status: RDY
created: 2026-04-10
refs:
  - docs/handoffs/015_PM_EN_audio-transcription-approved.md
  - docs/specs/meeting-transcription.md
---

## ctx

Phase 0 validation spike代碼已完成。四個文件寫入磁盤，可立即運行。

## 所寫文件

| 文件 | 測試覆蓋 | 說明 |
|------|---------|------|
| `Murmur/Scripts/phase0_spike.py` | Tests #1–7 | 主benchmark腳本，argparse，輸出JSON report |
| `Murmur/Scripts/phase0_chunk_test.py` | Test #1 deep-dive | chunk策略詳細分析（fixed-overlap + energy VAD + webrtcvad） |
| `Murmur/Scripts/prepare_test_audio.py` | Test data prep | LibriSpeech EN + AISHELL ZH下載、duration文件生成、m4a/.ogg probe |
| `Murmur/Tests/Phase0SpikeTests.swift` | Tests #8–9 | activationPolicy切換 + NSProcessInfo.performActivity（XCTest） |
| `Murmur/Scripts/requirements-dev.txt` | — | jiwer, psutil, webrtcvad, tqdm, requests |

## 如何運行

### Step 0 — 安裝dev依賴

```bash
pip install -r Murmur/Scripts/requirements-dev.txt
```

### Step 1 — 準備測試音頻（需ffmpeg + 網絡）

```bash
python3 Murmur/Scripts/prepare_test_audio.py \
    --output-dir ./test_audio
```

AISHELL約15GB，若磁盤不足可加`--no-aishell`只跑EN。

### Step 2 — 跑全部Python測試（#1–7）

```bash
python3 Murmur/Scripts/phase0_spike.py \
    --model-path ~/Library/Application\ Support/Murmur/Models-ONNX \
    --audio-dir ./test_audio \
    --output phase0_report.json
```

跑單項（如只跑速度+記憶體）：

```bash
python3 Murmur/Scripts/phase0_spike.py \
    --model-path <path> \
    --audio-dir ./test_audio \
    --test 2,5 \
    --output speed_mem_report.json
```

### Step 3 — chunk策略深度測試（Test #1 詳細）

```bash
python3 Murmur/Scripts/phase0_chunk_test.py \
    --model-path ~/Library/Application\ Support/Murmur/Models-ONNX \
    --audio ./test_audio/duration/60min.wav \
    --output chunk_report.json
```

### Step 4 — Swift測試（Tests #8–9）

```bash
xcodebuild test \
    -scheme Murmur \
    -only-testing MurmurTests/Phase0SpikeTests \
    | grep -E "(PASS|FAIL|error)"
```

## 依賴說明

| 依賴 | 用途 | 可選？ |
|------|------|--------|
| jiwer | WER/CER計算（Tests #3, #4） | 否 |
| psutil | RSS監控（Test #5） | 否 |
| webrtcvad | 準確VAD分割（Test #1） | 是，energy-based fallback |
| ffmpeg（CLI） | m4a/ogg轉換、FLAC轉WAV | 是，afconvert fallback for m4a |
| tqdm | 下載進度條 | 是 |
| requests | 不直接用，urllib fallback | 是 |

## Report格式

`phase0_report.json` 結構：

```json
{
  "timestamp": "2026-04-10T...",
  "model_path": "...",
  "tests": {
    "chunk_strategy":     { "status": "pass|fail|skip", "best_strategy": "...", "best_sber": 0.03, ... },
    "processing_speed":   { "status": "pass|fail", "results": [{"rtf": 1.2, ...}, ...] },
    "single_speaker_wer": { "en": { "average": 0.12 }, "zh": { "average": 0.18 } },
    "multi_speaker_wer":  { "status": "pass|fail", "recommendation": "..." },
    "memory_usage":       { "status": "pass|fail", "delta_mb": 312.5 },
    "m4a_decode":         { "status": "pass|fail", "method": "ffmpeg|afconvert" },
    "ogg_decode":         { "status": "pass|fail", "method": "soundfile|ffmpeg" }
  },
  "summary": { "passed": 6, "failed": 1, "overall": "fail" }
}
```

PM可直接取此JSON填入spec §Phase 0 success metrics欄位。

## 設計備注

- `phase0_spike.py` import `transcribe.py` via `importlib.util`——不動production代碼，不需subprocess
- 所有測試均可獨立運行（`--test N`）；無需全部pass才能看中間結果
- Swift Tests #8/#9 不依賴Murmur target內部state，只用AppKit/Foundation公開API
- Test #4（multi-speaker）fail不阻止go-ahead——spec定義為「defer multi-speaker」而非取消V2
- webrtcvad在macOS arm64需`pip install webrtcvad`（有C extension），若安裝困難energy VAD自動接管

## 待PM決定

1. `phase0_report.json`中哪些欄位需填入spec rev 4表格？
2. Test #4 fail → multi-speaker defer的scope change需PM正式裁定
3. `.ogg` fail → 移除.ogg支持的決定需PM確認

## out

代碼已寫入磁盤，可立即運行。等待PM確認scope或開Phase 1。
