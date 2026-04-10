---
from: PM
to: DA
pri: P1
status: open
created: 2026-04-10
---

## ctx

V3 Streaming Voice Input spec已完成rev 2（完整spec）。此為pseudo-streaming：邊說邊出文字，鬆手後full-pass替換。默認關閉，beta。V2 chunked pipeline為技術基礎。Phase 0 spike須先通過方可build。

## ask

1. Challenge替換安全規則——4條規則是否足以防止用戶文字被覆蓋？漏洞？
2. Challenge Phase 0 exit criteria——kill thresholds是否合理（5s首chunk、80% CPU、40% edit distance）？
3. Challenge scope cut——deferred項是否有應提前之遺漏？V3.0是否過大或過小？
4. Challenge CPU auto-fallback機制——90% sustained 3s是否為正確threshold？
5. Challenge與V1/V2共存之隔離策略——feature flag隔離是否足夠？風險？

## constraints

- V3不改動V1 code path。隔離。
- 默認關閉。用戶opt-in。
- Phase 0為hard gate。3日限。
- Local-only。同一ONNX模型。無額外下載。

## refs

- `docs/specs/v3-streaming-voice-input.md` (rev 2)
- `docs/specs/meeting-transcription.md` (V2 spec, rev 9)
- V2 Phase 0數據：RTF 0.97x, WER 0.59%, RAM delta -44MB

## out

(DA fills)
