# Handoff 045 — DA → PM: V3 Streaming Voice Input 挑戰

**From:** DA  
**To:** PM  
**Status:** RDY  
**Date:** 2026-04-10  
**Re:** docs/specs/v3-streaming-voice-input.md

---

## 概論

V3 pseudo-streaming概念可行，惟現稿七處致命缺陷，須逐一裁定方可交付EN實作。

---

## 挑戰一：替換UX災難（P0）

**現稿：** 錄音結束 → full-pass → 若結果異 → `select all streamed text → replace`

**問題：** 用戶見streaming文字出現，以為完成，隨即在後方繼續鍵入。Full-pass完畢時，系統需選中所有streamed text以替換。但用戶後來打的字無法與streamed text區分——selection range若按字符數計，必然連帶覆蓋用戶手打之字。

**技術根源：** `TextInjectionService.replaceRange()`需追蹤injected range之終點。用戶在streaming期間插入字符，終點位移（offset shift）無可靠追蹤機制。AX API無法可靠取得「我之前inject的範圍現在在哪」。

**裁定要求：** PM須選擇一：
- (A) 棄置full-pass替換，streaming結果即最終結果（犧牲WER）
- (B) 全-pass替換僅在用戶「未繼續打字」時執行（需偵測post-injection keystroke）
- (C) UI提示用戶「替換中，勿輸入」並block鍵入（UX倒退，近似modal）
- (D) 刪除V3，保留V1

---

## 挑戰二：首chunk延遲≠streaming（P0）

**現稿：** 「邊說邊看文字出現」

**實測數據（V2 Phase 0）：**
- ONNX encoder per chunk：RTF 0.97x，即3s音頻需~3s處理
- 加decoder：M1 8GB實測1-2s/chunk（短音頻）
- 首chunk pipeline：錄音3s + encoder~1.5s + decoder~1s = **用戶說完後等4-5s才見首字**

**問題：** 4-5s首字延遲，非人感知之「streaming」。Whisper Web、Google Voice等真streaming工具首字延遲<500ms（用incremental encoder，非batch）。V3用batch ONNX encoder，架構上無法達成真streaming。

**裁定要求：** PM須明確：
- 「pseudo-streaming」之可接受首字延遲上限為何？
- 若用戶說10字，等4s，此為可接受UX？
- 若不可接受，V3應否延至有incremental encoder支持時再做？

---

## 挑戰三：CPU持續佔用 → thermal throttle（P1）

**現稿：** 錄音中逐chunk實時推理

**問題：** V1錄音期間CPU幾乎零佔用（僅AVAudioRecorder寫盤）。V3錄音期間持續跑ONNX encoder+decoder，M1 8GB平均inference ~1.5s/3s chunk，即CPU佔用率~50%持續整段錄音。連續使用5+分鐘，M1 thermal throttle概率高，反致後段推理更慢。

**具體後果：** 用戶說話越長，後段chunk延遲越大，streaming體驗越差。自我懲罰機制。

**裁定要求：** 是否要求EN做thermal監控、降頻策略？或spec明列「連續使用上限建議X分鐘」？

---

## 挑戰四：chunk邊界WER惡化（P1）

**現稿：** 複用V2的`transcribe_onnx_chunked()`，chunk size 3-5s

**問題：** V2用30s chunks + 5s overlap，Phase 0 WER 0.59%。V3用3-5s chunks，邊界密度提升6-10倍。

**技術細節：** `transcribe_onnx`現收完整WAV，以整句為單位decode。3s強切chunk於詞中截斷概率高。V2有overlap trimming heuristic（2wps），3s chunk overlap若設5s則overlap>chunk，邏輯矛盾。若不設overlap，邊界截斷必產生殘字、重複詞、語義斷裂。

**裁定要求：** PM是否接受streaming模式WER明顯高於V1/V2？需明列在spec limitations中，避免用戶以streaming模式轉寫重要內容後投訴準確率倒退。

---

## 挑戰五：TextInjection位置追蹤不可靠（P1）

**現稿：** 「TextInjectionService需新增`appendText()`和`replaceRange()`方法」

**現有代碼現實（AppCoordinator.swift）：** `injection.inject(text:)`為一次性操作，注入後無position追蹤。AX API的`kAXSelectedTextRangeAttribute`只能取得當前游標位置，非歷史注入範圍。

**風險場景（三種）：**
1. 用戶在streaming中移動游標至文章其他位置 → 下一chunk append到錯誤位置
2. 用戶切換app（Cmd+Tab）→ inject target app失焦 → chunk注入至錯誤app或失敗
3. 用戶點擊其他輸入框 → streaming文字散落多處

**裁定要求：** EN需實作「游標位移偵測」並明定行為（停止streaming？警告用戶？）。此為新增複雜度，現稿未估工。

---

## 挑戰六：「默認關閉」= 永遠關閉（P2）

**現稿：** Settings中開關：「Streaming input (beta)」，默認關閉。

**問題：** Input現有Settings UI為何？用戶打開率估計多少？Beta功能若用戶發現不到，無法收集真實使用數據，無從決定是否升為默認。「默認關閉」實為擱置，非測試。

**若V3是未來方向：** 應考慮：
- (A) 對新安裝用戶默認開啟（老用戶不受影響）
- (B) Onboarding提示「試用新功能」
- (C) pill UI加「開啟streaming」快捷入口

**裁定要求：** PM明列採用率目標及discovery機制，否則「默認關閉」= 永遠無數據 = 永遠無法升為默認。

---

## 挑戰七：V2 Python process競爭（P2）

**現稿：** 複用V2的`transcribe_onnx_chunked()`

**現有架構（AppCoordinator.swift）：**
- `transcribeLong()`佔用`TranscriptionService`的Python process（長期任務）
- V3 streaming也需同一Python process做chunk推理
- `AppState.transcribing`現已阻擋voice input hotkey

**衝突：** 若用戶正在V2 transcribeLong（例如轉寫30分鐘會議），同時觸發V3 streaming voice input——兩者爭同一Python process，JSON protocol無法multiplex。

**現有保護：** `beginWindowTranscription()`/`endWindowTranscription()`將coordinator置為`.transcribing`，阻擋hotkey。但V3 streaming本身也需`.recording`狀態，與`.transcribing`互斥。

**裁定要求：** PM確認V3 streaming期間是否完全禁止V2 transcribeLong（反之亦然）？若是，用戶開始說話時若有進行中的V2任務，UX如何處理？

---

## 總結優先級

| # | 挑戰 | 優先 | 類型 |
|---|------|------|------|
| 1 | 替換UX → 覆蓋用戶輸入 | P0 | 設計缺陷 |
| 2 | 首chunk 4-5s延遲非streaming | P0 | 架構限制 |
| 3 | CPU thermal throttle | P1 | 性能風險 |
| 4 | 3s chunk WER惡化 | P1 | 準確率退步 |
| 5 | TextInjection位置不可靠 | P1 | 實作缺口 |
| 6 | 默認關閉≠無數據 | P2 | 產品策略 |
| 7 | V2/V3 Python process競爭 | P2 | 架構衝突 |

P0兩項任一不解，V3不應開工。建議PM先裁定挑戰一、二，再決定V3是否進入設計階段。

---

**out:** DA挑戰完畢。待PM回應後，若V3繼續，轉交UX做流程設計（含替換UX方案）。
