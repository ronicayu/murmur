---
id: 030
from: EN
to: QA
status: RDY
topic: chunked-transcribe-poc
date: 2026-04-10
---

# Handoff: Serial Chunked Transcription PoC — EN → QA

## Context

Phase 0 診斷發現 CohereAsrProcessor 的 batch mode 在 120 min 音頻上（235 chunks 同時載入）觸發 SIGKILL。V2 方案：手動逐 chunk 串行處理，記憶體峰值恆定於 model baseline + 單 chunk tensor（~100 MB）。

## 實現內容

### 新增函數（`Murmur/Resources/transcribe.py`）

| 函數 | 職責 |
|------|------|
| `compute_chunk_boundaries(total_samples, chunk_samples, overlap_samples)` | 純數學切割，返回 `(start, end)` list |
| `estimate_words_in_duration(duration_sec)` | overlap trimming 字數估算 |
| `_load_audio_any_format(audio_path)` | 多格式載入（wav/m4a/mp3/ogg via ffmpeg） |
| `_decode_single_chunk_onnx(chunk_audio, language)` | 單 chunk ONNX encode+decode，不持有 past_kv 跨 chunk |
| `transcribe_onnx_chunked(audio_path, language, chunk_sec, overlap_sec)` | 主函數：切割→串行轉寫→overlap trim→progress JSON→result |

### 新增命令（`main()` dispatch）

```json
{"cmd": "transcribe_long", "audio_path": "/path/to/file.m4a", "language": "en", "chunk_sec": 30, "overlap_sec": 5}
```

每 chunk 輸出：
```json
{"type": "progress", "chunk": 3, "total": 10, "text": "partial text so far..."}
```

最終返回：
```json
{"type": "result", "text": "full text", "language": "en", "duration_ms": 12345, "chunks": 10}
```

### 測試腳本

`Murmur/Scripts/test_chunked_transcribe.py`：

- **Layer 1（Unit）**：5 tests — chunk splitting 數學、overlap trim 邏輯、邊界條件
- **Layer 2（Integration）**：4 tests — mock model，驗證 JSON 協議、progress 事件、overlap 不重複
- **Layer 3（System）**：3 tests（`--system` flag）— 真實模型 + 5 min 音頻，RAM delta < 500 MB

執行：
```bash
python Murmur/Scripts/test_chunked_transcribe.py           # unit + integration（17 tests, OK）
python Murmur/Scripts/test_chunked_transcribe.py --system  # 需真實模型
```

## 設計決策

1. **Overlap trimming 策略**：heuristic（2 wps × overlap_sec → N words），非精確時間戳。對短句可能過度丟棄（整個 chunk 被 discard），但比重複內容更保守。如需精確請換用 timestamp-based approach（future work）。

2. **記憶體邊界**：`past_kv` 在每個 chunk 的 `_decode_single_chunk_onnx` 結束後即被 GC——不跨 chunk 保留 KV cache，犧牲少量 attention window，換取 O(1) 記憶體。

3. **m4a 支持**：ffmpeg pipe 路徑，無臨時文件，timeout=120s。

## 已知限制

- Overlap trimming 為 word-count heuristic，中文（無空格）trimming 無效——目前回落為整個 chunk 丟棄（若 word count ≤ 估算值）。中文長音頻需 character-based trimming（後續迭代）。
- system test 需 `ffmpeg` 已安裝（`brew install ffmpeg`）。
- `transcribe_long` 命令目前僅支持 ONNX backend；HuggingFace/Whisper backend 的 chunked 版本尚未實現。

## 請 QA 驗證

1. 確認 unit + integration tests 在 CI 環境全通過
2. 若有真實長音頻（≥ 5 min m4a），執行 `--system` test，記錄 RAM delta 數值
3. 確認 `transcribe_long` 命令對 model-not-loaded 狀態正確返回 error JSON（不 crash）
4. 補充 edge case：零長度音頻、損壞的 m4a、`chunk_sec < overlap_sec`（應返回 error）

---

out: `Murmur/Resources/transcribe.py`（新增函數），`Murmur/Scripts/test_chunked_transcribe.py`（新建）
