# Handoff 047 — PM → EN: V3 Phase 0 Spike approved

**From:** PM
**To:** EN
**Status:** REQ
**Date:** 2026-04-10
**Re:** docs/specs/v3-streaming-voice-input.md (rev 3)

---

## 指令

V3 Streaming Voice Input通過DA挑戰，進入Phase 0 validation spike。

**Spec：** `docs/specs/v3-streaming-voice-input.md` rev 3
**時限：** 3日
**UI：** 無。純工程驗證。

---

## Phase 0 七項spike

| # | Test | Exit Criteria |
|---|------|---------------|
| 1 | Chunk大小（2s/3s/5s） | 至少一組合：首chunk < 5s 且邊界錯誤 < 10% |
| 2 | 首chunk延遲 | < 5s on M1 16GB。> 8s on both → **V3 cancelled** |
| 3 | 連續推理CPU佔用 | Sustained < 80% on M1 16GB。> 90% → throttle或cancel |
| 4 | 替換UX + focus guard | ≥ 3/5 app支持select+replace。Focus change可偵測 |
| 5 | Streaming vs full-pass差異 | Avg edit distance < 20%。> 40% → **V3 cancelled** |
| 6 | Dual-output AudioService | Pass/fail。Fail → 改用AVAudioEngine |
| 7 | V1 code path隔離 | EN + CR confirm isolation |

---

## Kill criteria（三硬門）

1. 首chunk延遲 > 8s on M1 16GB + M1 8GB → V3 cancelled
2. CPU sustained > 90% on M1 16GB無解 → V3 cancelled
3. Edit distance > 40% → V3 cancelled

## Conditional deferral

- Select+replace ≥ 3/5 app不可行 → 替換deferred，V3.0僅append
- Focus change不可偵測 → Focus guard deferred，加warning

---

## Rev 3重點（DA挑戰後新增）

EN需特別注意rev 3新增之scope：

1. **Focus guard**（行為§6，constraint §9）：inject期間偵測focus change。失焦→暫停，10s→放棄。Phase 0 #4含此。
2. **Discovery提示**（行為§2）：V1用滿10次→Settings提示。Phase 0不涉及，後續實作。
3. **雙向互斥**（constraint §2）：V3 streaming期間亦不可啟動V2 transcribeLong。

---

## 交付物

Phase 0完成後，請寫handoff回PM，含：
- 七項spike結果（pass/fail + 數據）
- Kill criteria是否觸發
- 建議之chunk大小
- 任何spec需調整之處

---

**out:** PM交付完畢。EN開工。
