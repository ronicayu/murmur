---
from: EN
to: PM
pri: P0
status: wip
created: 2026-04-10
---

## ctx

Phase 0 spike中間報告。部分測試已完成，部分在進行中。

## 已完成測試

| # | Test | Result | Detail |
|---|------|--------|--------|
| 3 | Single-speaker WER (ONNX/CPU) | **observed** | EN avg WER = 24.4% (clean speech, 5 utterances). 偏高。 |
| 6 | m4a decode | **PASS** | soundfile不能直讀m4a，需ffmpeg中轉。Pipeline可行。 |
| 7 | .ogg decode | **PASS** | soundfile直接decode ogg(opus)。無需ffmpeg。 |
| 8 | activationPolicy switching | **PASS** | 8/8 Swift tests通過。.accessory↔.regular切換正常。 |
| 9 | App Nap prevention | **PASS** | NSProcessInfo.performActivity API正常。 |

## 進行中

| # | Test | Status |
|---|------|--------|
| 2 | Processing speed (ONNX, quick) | 5min file在跑。processor自動batch成10段。 |
| 3 | Single-speaker WER (HF/MPS) | 模型載入慢（167s），inference進行中。 |
| 5 | Memory usage | 與Test #2同跑 |

## 關鍵發現

### 1. Processor自動chunking
ONNX backend的CohereAsrProcessor收到5min音頻時，自動生成shape (10, 3101, 128)的input——即10個~30s chunks。**模型已有內建chunking機制，V2不需自行實現chunk splitting。** 需驗證拼接質量。

### 2. m4a需ffmpeg前處理
`soundfile`不支持m4a直讀。Production code需加:
```
ffmpeg -i input.m4a -ar 16000 -ac 1 -f wav pipe:1
```
或先轉換為wav臨時文件。

### 3. ONNX WER偏高（24.4%）
Clean speech上24.4% WER不理想。可能原因：
- q4f16量化損失
- CPUExecutionProvider（未用CoreML）
- 短音頻（3-10s）邊緣效應

等HF backend結果對比後才能判斷是模型問題還是量化問題。

### 4. HF模型載入極慢
2B模型在M1 8GB上：
- Weight loading: 79.6s
- Move to MPS: 86.8s
- 總計: ~167s

V2若用HF backend，首次transcription延遲不可接受。建議V2使用ONNX backend。

### 5. Hardware constraint
測試機為M1 8GB（非spec定義的M1 Pro 16GB）。結果為下界估計。

## 待完成

- Test #1 chunk strategy（需完整speed test後）
- Test #4 multi-speaker（無ZH數據，無multi-speaker數據）
- 完整report（所有測試完成後）

## out

（進行中）
