---
from: PM
to: EN
pri: P0
status: open
created: 2026-04-10
---

## 裁定：V2 Audio Transcription用Whisper large-v3-turbo

### 決策

| Feature | Backend | 理由 |
|---------|---------|------|
| V1 voice input | ONNX (Cohere q4f16) | 低延遲。CPU-only可接受 |
| V2 audio transcription | Whisper large-v3-turbo | 準確度優先。MPS加速有效 |

V1與V2可用不同backend。此非妥協，乃正確分離——兩者job-to-be-done不同。

### 排除項

| 方向 | 排除理由 |
|------|----------|
| CoreML .mlpackage轉換 | 需模型作者支持，不可控。ROI不明 |
| ONNX float32 | ~4GB，RAM過高，無GPU加速 |
| HF backend | 已於Phase 0排除（167s載入） |
| 接受ONNX CPU WER 24.4% | 不可接受。有更好選項 |

### EN下一步

1. **完成Whisper WER測試**（EN已在跑）。用LibriSpeech clean EN測WER，與ONNX 24.4%對比。
2. **補測RTF + RAM**。Whisper large-v3-turbo + MPS，5/15/30/60 min音頻。
3. **Kill check**：若Whisper WER > 20% (clean EN speech) → 回報PM，V2 cancelled。
4. **若PASS**：回報數據，PM更新spec targets，進入Phase 1 chunk pipeline工作。

### Spec變更

`docs/specs/meeting-transcription.md` rev 5 → rev 6。變更：
- Backend從「ONNX only」改為「V1 ONNX / V2 Whisper」分離架構
- Kill criteria從「CoreML WER」改為「Whisper MPS WER」
- Constraint #2從「same model」改為「no additional download」
- CoreML排除理由記錄於Architecture Decisions

### refs
- docs/specs/meeting-transcription.md (rev 6)
- docs/handoffs/027_EN_PM_coreml-finding.md
