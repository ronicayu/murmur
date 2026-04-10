# Handoff 049 — PM → ALL: V3 Phase 0 GO

**From:** PM
**To:** ALL
**Status:** SHIP
**Date:** 2026-04-10
**Re:** V3 Streaming Voice Input — Phase 0 validation spike裁定

---

## 裁定：GO

V3 Phase 0 spike三項硬門全過。V3進入Phase 1實作。

---

## Kill Criteria結果

| Criteria | 閾值 | 實測（M1 8GB） | 判定 |
|----------|------|----------------|------|
| 首chunk延遲 | > 8s → cancel | ~5s | **PASS** |
| CPU sustained | > 90% → cancel | 28% avg | **PASS** |
| Edit distance | > 40% → cancel | 6.9% | **PASS** |
| AX replace | < 3/5 → defer | 未測 | **TBD** |

---

## 確定事項

1. **Chunk大小：3秒。** Phase 1用此值。不可調。
2. **M1 8GB可支持。** 不排除。CPU餘裕充足（28% vs 90%門檻）。
3. **AX replace：conditional deferral維持。** Phase 1實作時驗證。若不可行→V3.0僅append。
4. **偶發latency spike（~11s）：** 不另加機制。現有CPU fallback（>90% 3s → V1 mode）已覆蓋。
5. **2s chunk不支持。** Cold start異常。3s為最小值。

---

## Spec更新

`docs/specs/v3-streaming-voice-input.md` 已更新至 rev 4：
- Status: REQ → GO
- 新增「Phase 0裁定」section（完整數據與決策）
- Open Questions精簡至三項

---

## Phase 1啟動指令

### EN
- 依spec rev 4實作V3 streaming pipeline
- Feature flag: `streamingInputEnabled`，默認false
- 首要：streaming chunk→transcribe→inject loop
- AX replace需在實作時驗證（spike #4補測）
- 時限待定，PM另行排期

### UX
- Pill UI streaming狀態設計（脈動動畫 + 行數）
- Discovery提示設計（V1用滿10次→Settings提示）

### DA
- Phase 1 code review時挑戰focus guard實作
- AX replace測試結果出後，review conditional deferral決策

### CR
- Phase 1 code review
- 特別關注V1隔離（feature flag路徑）

### QA
- Phase 1 test plan（含streaming場景、CPU monitoring、替換安全規則）

---

**out:** Phase 0完結。V3 Phase 1 greenlit。
