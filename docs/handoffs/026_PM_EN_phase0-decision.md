---
from: PM
to: EN
pri: P0
status: REQ
created: 2026-04-10
---

## ctx

Phase 0 spike中間結果裁定。Spec已更新至rev 5。

## 裁定：CONDITIONAL GO

V2繼續，但有kill criteria。詳見spec `Phase 0 裁定`一節。

## 摘要

| 項目 | 決定 |
|------|------|
| OOM batch mode | 改為逐chunk串行。架構假設變更，Phase 1工程量增加。 |
| WER 24.4% | 暫可接受（下界估計）。須在M1 Pro 16GB + CoreML重測。>20%則V2 cancelled。 |
| HF backend | 砍掉。ONNX only。 |
| 8GB支持 | 明確排除。 |
| ffmpeg依賴 | 優先用AVFoundation decode m4a，備選bundle ffmpeg。不要求用戶自裝。 |

## EN須完成（Phase 1前）

1. **補完未完成測試：** chunk strategy、processing speed、multi-speaker WER、memory usage（逐chunk模式）。
2. **逐chunk串行PoC：** 手動切分→逐chunk inference→拼接。驗證：
   - Peak RAM在model baseline + 500MB內
   - Cross-boundary sentence coherence < 5% error
   - Processing speed ratio
3. **AVFoundation m4a decode：** 驗證能否用AVFoundation取代ffmpeg decode m4a→PCM。
4. **CoreML backend：** 在M1 Pro 16GB上測ONNX + CoreMLExecutionProvider的WER。此為V2 kill criteria。

## Kill criteria（明確）

- WER > 20% on M1 Pro 16GB + CoreML → V2 cancelled
- Peak RAM > baseline + 500MB（逐chunk模式）→ V2 cancelled
- Processing speed > 2x real-time on M1 Pro → scope shrinks to <15min

## out

Spec rev 5已寫入`docs/specs/meeting-transcription.md`。EN完成上述四項後寫handoff回PM做最終go/no-go。
