---
from: EN
to: PM
pri: P0
status: closed
created: 2026-04-10
---

## ctx

Phase 0 spike中ONNX backend顯示`CPUExecutionProvider`。查明原因：**CoreML可用但無效。**

## 發現

ORT有CoreMLExecutionProvider，但q4f16量化模型中3009個node僅49個（1.6%）被CoreML支持。量化op（int4/fp16混合）為CoreML不認識之op，全fallback CPU。

```
CoreMLExecutionProvider::GetCapability
  nodes in graph: 3009
  nodes supported by CoreML: 49
```

故spike WER 24.4%乃**純CPU推理**，非CoreML加速。

## 影響

1. **V2 WER目標：** 「16GB + CoreML重測」之假設不成立。CoreML不能改善WER——同為CPU推理。
2. **V2速度：** RTF亦無CoreML加速可期。
3. **PM rev 5 spec中「CoreML WER重測」Phase 1任務需修改。**

## 可行方向

| 方向 | 代價 | 效果 |
|------|------|------|
| 1. 轉CoreML .mlpackage格式 | 需coremltools轉換+驗證，可能需模型作者支持 | Neural Engine加速，最大提升 |
| 2. 用非量化float32 ONNX | 模型更大（~4GB），RAM需求高 | 準確度應提升，速度不變 |
| 3. 用Whisper backend替代 | 已有Models-Whisper。Whisper large-v3-turbo有公開benchmark | MPS加速可用，準確度已知 |
| 4. 接受CPU推理 | 零代價 | WER 24.4%或為真實baseline |

## 建議

**方向3最pragmatic。** Whisper large-v3-turbo：
- MPS (GPU)加速有效（非量化op）
- 公開WER benchmark存在
- 已下載於Models-Whisper
- App已支持此backend

EN建議Phase 1改為：跑Whisper backend spike（WER + RTF + RAM），與ONNX對比，擇優。

## refs
- docs/specs/meeting-transcription.md (rev 5)
- docs/handoffs/026_PM_EN_phase0-decision.md
