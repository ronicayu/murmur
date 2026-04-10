# Handoff 046 — PM → DA: V3挑戰裁定

**From:** PM
**To:** DA
**Status:** RDY
**Date:** 2026-04-10
**Re:** docs/handoffs/045_DA_PM_v3-challenge.md

---

## 七裁定

### #1 替換UX覆蓋用戶輸入（P0）→ 接受風險

Spec已有四條安全規則。最關鍵：用戶中間編輯→放棄替換。Phase 0 spike #4測5 app之select+replace。若≥3/5不可行→替換deferred，V3.0僅append不替換。

不選(A)(C)(D)。選(B)之強化版——安全規則+Phase 0 gate。

### #2 首chunk 4-5s延遲（P0）→ 接受

Spec已標「非real-time streaming ASR，延遲以秒計」。核心價值非速度，乃「模型在聽」之視覺反饋（User Story S3）。Kill criteria: >8s。Phase 0實測。

4-5s首字可接受。用戶說10字等4s，仍優於V1之「說完30s後才見字」。

### #3 Thermal throttle（P1）→ 已有緩解

Spec已有CPU fallback（>90% 3s → auto V1 mode）。Phase 0 #3驗證。無需新增spec內容。

### #4 3s chunk WER惡化（P1）→ 接受風險

Streaming文字為preview性質，full-pass為最終結果。WER惡化影響preview品質，不影響最終輸出。Phase 0 #5量測edit distance。已加入風險表。

### #5 Inject位置錯亂（P1）→ 新增focus guard

接受DA三場景。Spec新增：
- Streaming inject偵測focus change
- Focus離開目標→暫停inject
- Focus回來→resume
- 失焦超10s→放棄session

Phase 0 #4含此測試。

### #6 默認關閉=永遠關閉（P2）→ 新增discovery

接受DA觀點。新增：V1 voice input累計10次後，Settings一次性提示「Try streaming input (beta)」。不自動開啟。

### #7 V2/V3 Python process競爭（P2）→ 沿用V2互斥

沿用V2 constraint #10 voice input exclusivity。明確雙向互斥：V2期間不可用V3，V3期間不可用V2。已有guard。

---

## Spec變更摘要（rev 2 → rev 3）

| 區塊 | 變更 |
|------|------|
| 行為§2 | 新增discovery提示 |
| 行為§6 | 新增focus guard |
| Scope In V3.0 | +discovery提示、+focus guard |
| Scope conditional | +替換conditional deferral |
| Constraint §2 | 雙向互斥措辭強化 |
| Constraint §9 | 新增focus guard constraint |
| 風險表 | +3行（WER、inject位置、thermal） |
| DA裁定表 | 新增完整裁定紀錄 |
| Phase 0 #4 | 擴充含focus change測試 |
| Spike outcomes | +focus change不可偵測之fallback |

---

**out:** 七裁定完畢。Spec rev 3已更新。V3進入Phase 0。EN接手。
