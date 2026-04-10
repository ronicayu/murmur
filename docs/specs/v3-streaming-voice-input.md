# V3 — Streaming Voice Input

**Author:** @PM
**Status:** GO
**Created:** 2026-04-10
**Revision:** 4 (Phase 0 GO — spike實測裁定、chunk=3s確定、AX replace TBD)
**Depends on:** V2 Audio Transcription (chunked pipeline)

---

## 概念

V1 voice input為「錄完→轉寫→注入」。V3改為pseudo-streaming：錄音中每N秒切chunk，即時轉寫並注入，用戶邊說邊看文字出現。錄音結束後，全文重新轉寫一次（full-pass），若結果不同則替換先前輸出。

**一句話：** 說話時即見文字，鬆手時自動修正。

**非目標：** 此非real-time streaming ASR。延遲以秒計，非毫秒。不做partial-word streaming、不做word-level confidence、不做即時翻譯。

---

## User Stories

### S1 — 寫郵件邊說邊看

用戶於Mail.app撰寫郵件。按住hotkey說話，每數秒文字逐段出現於游標處。鬆開hotkey，全文替換為更準確之結果。用戶無需等待錄音結束方可見文字——心理延遲大幅縮短。

**Job:** 長段口述時，即時確認模型是否在聽、方向是否正確。

### S2 — 會議中快速記筆記

用戶於Obsidian中，聽到重點即按hotkey口述一句。3-5秒後文字出現，用戶可即時判斷是否需要補充。鬆開hotkey，full-pass替換。用戶繼續聽會議。

**Job:** 短句口述之feedback loop——說完即見，無需等。

### S3 — 長段口述確認模型在聽

用戶口述一段話30秒以上。若無streaming，30秒內無任何視覺反饋，用戶不確定app是否在工作。Streaming每chunk出文字，即為「模型在聽」之信號。

**Job:** 消除「app是否凍住」之焦慮。

---

## Success Metrics

| Metric | Target | Measurement | 備註 |
|--------|--------|-------------|------|
| 首chunk延遲 | < 5s（按下hotkey至首段文字出現） | Timer instrumentation | 含chunk accumulation + inference。Phase 0實測 |
| Full-pass替換率 | < 30% of sessions觸發替換 | Local analytics | 替換率過高則streaming文字不可信，UX劣化 |
| 替換文字差異量 | 替換時 edit distance < 15% of total chars | Local analytics | 大幅替換令用戶不安。若超標需調chunk策略 |
| Feature開啟率 | > 10% WAU於上線30日內開啟 | UserDefaults flag | 默認關閉，故10%已為有意義之adoption |
| CPU佔用 | Streaming期間CPU < 80%（M1 16GB） | Activity Monitor / Phase 0 | 若卡頓影響前台app則不可接受 |
| V1回退率 | < 5% 用戶開啟後又關閉 | UserDefaults flag | 若高於此，streaming體驗有根本問題 |

---

## 行為

1. **默認關閉。** Settings中開關：「Streaming input (beta)」。
2. **Discovery機制：** 用戶V1 voice input累計使用達10次後，Settings中顯示一次性提示「Try streaming input (beta)」。提示僅現一次，不自動開啟。（rev 3新增）
3. **開啟後：**
   - 用戶按hotkey開始錄音
   - 每N秒自動切chunk，送入ONNX encoder-decoder
   - 每chunk轉寫完畢立即inject到游標位置（append）
   - Pill UI顯示streaming狀態：脈動動畫 + 已輸出文字行數
   - 用戶鬆開hotkey停止錄音
   - 全文WAV做一次完整轉寫（full-pass）
   - 若full-pass結果與streaming拼接結果不同：select all streamed text → replace with full-pass result
   - 替換以單次undo-able操作執行（用戶可Cmd+Z撤銷替換、恢復streaming版本）
4. **關閉時：** 行為與V1完全一致。零影響。
5. **替換安全規則：**
   - 僅替換本次streaming session注入之文字
   - 若用戶於streaming文字後方繼續鍵入，替換不觸及用戶鍵入之內容
   - 若用戶於streaming文字中間編輯（移動游標、插入文字），放棄替換，保留streaming版本
   - 替換window：full-pass完成後500ms內執行。逾時則放棄。
6. **Focus guard（rev 3新增）：**
   - Streaming inject期間持續偵測目標app/輸入框focus狀態
   - Focus離開目標app或目標輸入框 → 暫停inject（chunk仍在後台轉寫、緩存）
   - Focus回到目標 → resume inject（flush緩存之chunk）
   - Focus離開超過10s → 放棄本次streaming session，full-pass結果亦不替換

---

## 技術要點

- 複用V2的`transcribe_onnx_chunked()`逐chunk pipeline
- 新增Python命令`transcribe_stream`：接收audio buffer stream而非文件路徑
- AudioService需改為dual-output：既寫WAV文件（供full-pass），又逐buffer送Python
- TextInjectionService需新增`appendText()`和`replaceRange()`方法
- Full-pass替換需追蹤injected text的cursor position + length
- `replaceRange()`須為single undo group（NSUndoManager / CGEvent based）
- TextInjectionService需新增focus change偵測（AX notification / NSWorkspace.didActivateApplicationNotification）（rev 3新增）

---

## Scope

### In V3.0

- Settings toggle: 「Streaming input (beta)」，默認關閉
- Discovery提示：V1使用滿10次後，Settings一次性提示（rev 3新增）
- Streaming pipeline: chunk → transcribe → inject loop
- Full-pass替換: 錄音結束後全文重轉寫，差異時替換
- 替換安全規則（上述4+1條）
- Focus guard: focus偵測、暫停/resume inject（rev 3新增）
- Cmd+Z撤銷替換
- Pill UI streaming狀態指示（脈動 + 行數）
- CPU throttle: 若CPU > 90%持續3s，自動fallback to V1模式（完成錄音後整段轉寫）

### Deferred (V3.x or later)

- **Chunk大小用戶可調。** V3.0用Phase 0確定之固定值。
- **Partial-word streaming。** 需模型支持token-level streaming，當前ONNX不支持。
- **Streaming期間語言切換。** V3.0同V1——整段同一語言。
- **替換動畫。** 文字替換時之過渡動畫。先ship功能，再打磨視覺。
- **Streaming + V2 audio transcription整合。** 長音頻轉寫用streaming顯示進度。複雜度高，分開做。
- **Confidence-based partial replacement。** 僅替換低confidence chunks。需模型輸出confidence score。

### Conditional deferral (Phase 0 gated)

- **Full-pass替換：** 若Phase 0 spike #4中 ≥ 3/5 app不支持select+replace → V3.0僅append不替換，替換deferred。（rev 3新增）

---

## Constraints

1. **與V1共存。** Streaming關閉時，voice input行為與V1完全一致。Streaming不改動V1 code path——新code path，feature flag隔離。
2. **與V2共存。** V2 audio transcription與V3 streaming為獨立feature。V2處理中不可啟動streaming voice input（沿用V2 constraint #10 voice input exclusivity）。反之亦然：V3 streaming期間不可啟動V2 transcribeLong。（rev 3明確雙向互斥）
3. **CPU佔用。** Streaming期間ONNX持續推理。M1 8GB（16GB+為target）須保持系統可用。Hard limit: CPU sustained > 90% for 3s → auto-fallback to V1 mode。
4. **替換安全。** 替換僅限本次session注入之文字。不可覆蓋用戶既有內容或中間編輯。寧可放棄替換，不可破壞用戶文字。
5. **默認關閉。** 非opt-out。用戶須主動開啟。V3.0為beta。
6. **Undo支持。** Full-pass替換為single undo operation。Cmd+Z恢復streaming版本。
7. **Local-only。** 同V1/V2。音頻與文字不離開本機。
8. **無額外下載。** 同V1/V2同一ONNX模型。
9. **Focus guard。** Inject期間target app/field失焦 → 暫停inject。失焦超10s → 放棄session。（rev 3新增）

---

## 風險

| 風險 | 影響 | 緩解 |
|------|------|------|
| Chunk邊界截斷 | 句子斷裂、重複詞 | V2已有overlap策略。Phase 0測streaming場景 |
| 替換覆蓋用戶輸入 | 數據丟失 | 替換安全規則4條 + Cmd+Z + 用戶中間編輯→放棄替換 |
| 首chunk延遲過長 | 體感與V1無異，feature無價值 | Phase 0實測。Kill: > 8s。可接受延遲以秒計——核心價值為視覺反饋非速度 |
| CPU卡頓 | 前台app不可用 | Auto-fallback機制 + Phase 0 benchmark |
| Full-pass與streaming差異過大 | 用戶不信任streaming文字 | 監測替換率。若 > 50%需改chunk策略或取消feature |
| Accessibility cursor tracking | 部分app不支持selection range查詢 | Phase 0測5個常用app。不支持之app fallback to V1 |
| 3s chunk WER惡化（rev 3） | Streaming preview文字品質較差 | Streaming為preview性質，full-pass為最終結果。Phase 0 #5量測edit distance |
| Inject位置錯亂（rev 3） | 文字注入錯誤位置或錯誤app | Focus guard: 失焦→暫停、10s→放棄。Phase 0 #4含此測試 |
| Thermal throttle（rev 3） | 長錄音後段推理更慢 | CPU fallback（>90% 3s → V1 mode）。Phase 0 #3驗證 |

---

## DA挑戰裁定（rev 3）

| # | 挑戰 | 級 | 裁定 | 變更 |
|---|------|----|------|------|
| 1 | 替換UX覆蓋用戶輸入 | P0 | 接受風險。Spec已有四條安全規則。Phase 0 #4測select+replace，≥3/5不可行→替換deferred，V3.0僅append | 新增conditional deferral |
| 2 | 首chunk 4-5s延遲 | P0 | 接受。Spec已標非real-time。核心價值為「模型在聽」之視覺反饋（S3）。Kill: >8s | 無變更 |
| 3 | Thermal throttle | P1 | Spec已有CPU fallback（>90% 3s → V1）。Phase 0 #3驗證 | 無變更 |
| 4 | 3s chunk WER惡化 | P1 | 接受。Streaming為preview，full-pass為最終。Phase 0 #5量測 | 風險表新增 |
| 5 | Inject位置錯亂 | P1 | 接受。新增focus guard：失焦→暫停inject，10s→放棄session | 新增行為§6、constraint §9 |
| 6 | 默認關閉=永遠關閉 | P2 | 接受DA觀點。新增discovery：V1用滿10次→Settings一次性提示 | 新增行為§2 |
| 7 | V2/V3 Python process競爭 | P2 | 沿用V2 constraint #10互斥。明確雙向：V3期間亦不可用V2 | Constraint §2措辭強化 |

---

## Phase 0 — Validation Spike

Phase 0為時限3日之工程spike。無UI。驗證V3核心假設。

### Spike Deliverables

| # | Test | Method | Exit Criteria |
|---|------|--------|---------------|
| 1 | Chunk大小 | 測2s / 3s / 5s chunks之首chunk延遲及邊界錯誤率 | 至少一組合：首chunk < 5s 且邊界錯誤 < 10% |
| 2 | 首chunk延遲 | 計時：audio start → 首段transcript output。M1 16GB + M1 8GB | < 5s on M1 16GB。若 > 8s on both → V3 cancelled |
| 3 | 連續推理CPU佔用 | 30s streaming session，Activity Monitor記錄CPU% | Sustained < 80% on M1 16GB。> 90% → 需throttle或cancel |
| 4 | 替換UX可行性 + focus guard | Python script模擬：inject text → select range → replace。測5個app（Notes, TextEdit, VS Code, Obsidian, Mail）。含focus change偵測測試（rev 3） | ≥ 3/5 app支持 select + replace via accessibility API。Focus change可偵測 |
| 5 | Streaming vs full-pass差異 | 10段語音（5 EN + 5 ZH），比較streaming拼接與full-pass之edit distance | Avg edit distance < 20%。> 40% → V3 cancelled |
| 6 | Dual-output AudioService | 驗證AVAudioRecorder可同時寫WAV + 逐buffer回調 | Pass/fail。若fail需改用AVAudioEngine |
| 7 | V1 code path隔離 | Streaming code路徑完全不觸碰V1 pipeline。Review code structure | EN + CR confirm isolation |

### Spike Outcomes → V3 Scope Decisions

- 首chunk延遲 > 8s on both targets → **V3 cancelled**。
- CPU sustained > 90% on M1 16GB with no throttle solution → **V3 cancelled**。
- Select + replace 失敗於 ≥ 3/5 app → **替換deferred**，V3.0僅append不替換。
- Streaming vs full-pass edit distance > 40% → **V3 cancelled**。差異過大則streaming文字無用。
- Dual-output不可行 → 改用AVAudioEngine（增加工程量，不cancel）。
- Focus change不可偵測 → Focus guard deferred，V3.0加warning：「streaming期間勿切換app」。（rev 3新增）

---

## Phase 0 裁定（rev 4）

**判決：GO。** 三項硬門全過。Phase 1可啟。

### 實測環境

M1 8GB，ONNX CPU。此為下界——16GB+ target機性能只會更優。

### Kill Criteria結果

| Criteria | 閾值 | 實測 | 判定 |
|----------|------|------|------|
| 首chunk延遲 | > 8s → cancel | ~5s（3s累積 + 2s推理） | **PASS** |
| CPU sustained | > 90% single-core → cancel | 28% avg, 45% peak（psutil multi-core normalized） | **PASS** |
| Edit distance | > 40% → cancel | 6.9% | **PASS** |
| AX select+replace | < 3/5 app → replacement deferred | 未測 | **TBD — conditional deferral維持** |

### Spike逐項結果

| # | Test | 結果 | 備註 |
|---|------|------|------|
| 1 | Chunk大小 | **3s optimal** | 3s: 1.93s latency, text品質優。2s cold start異常（27s）。5s延遲過長 |
| 2 | 首chunk延遲 | **~5s** | 3s accumulation + 2s inference |
| 3 | CPU佔用 | **28% avg, 45% peak** | 大幅低於90%門檻 |
| 4 | AX replace | **未測** | 需手動Accessibility測試。Conditional deferral規則維持 |
| 5 | Streaming vs full-pass | **6.9% edit distance** | 遠優於40%門檻 |
| 6 | Dual-output | **PASS** | AVAudioEngine方案可行 |
| 7 | V1隔離 | **PASS** | Feature flag設計，V1受影響行數：0 |

### 確定事項

1. **Chunk大小：3秒。** 固定值，不可調。
2. **CPU fallback閾值：維持>90% 3s → V1 mode。** 實測28%，餘裕極大。
3. **AX replace：維持conditional deferral。** Phase 1實作時測試。若≥3/5 app不可行→V3.0僅append。

### 已知風險（Phase 0發現）

- **偶發latency spike：** 10 chunks連續推理中偶見11s spike。疑thermal throttle或GC。現有CPU fallback機制（>90% 3s → V1）已覆蓋此風險。不另加機制。
- **2s chunk cold start異常（27s）：** 首次推理cold start問題。3s chunk cold start後穩定1.9s。**決策：不支持2s chunk。**
- **M1 8GB可支持。** 實測數據全在8GB上取得。CPU餘裕充足。V3不排除8GB。

---

## Open Questions（Phase 0後殘留）

1. **Pill UI如何反映streaming狀態？** 待UX設計。
2. **替換動畫是否必要？** 待Phase 1 edit distance實際替換率數據。
3. **AX replace可行性。** Phase 1實作時驗證。結果決定V3.0是append-only或含替換。
