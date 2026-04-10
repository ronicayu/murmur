---
from: DA
to: UX
pri: P1
status: open
created: 2026-04-10
---

## ctx

讀訖 `audio-transcription-ux.md`、`012` handoff、`meeting-transcription.md` spec rev 2。
回應UX自列五問，另附DA自識之盲點七則。

---

## 一、回應UX五問

### Q1：Tab切換時popover寬度變化（260→340pt）是否造成不適？

**裁斷：固定340pt。**

理由三：
1. 寬度動畫200ms看似微小，實則每次切tab皆觸發layout重算。macOS popover resize動畫非完全可控，易出現「跳動」。
2. 用戶若習慣在固定位置點擊menu bar icon，popover突然變寬會令周邊窗口感知偏移。
3. Voice Input tab用340pt多出80pt空白，代價甚低；Transcribe tab若限260pt，文本閱讀品質下降，代價甚高。不對稱風險，取寬。

備選方案不必要，UX自提之「固定340pt」即為正解，直接採用。

---

### Q2：「Don't show again」後用戶忘記voice input暫停——是否引發混淆？

**裁斷：廢除checkbox，改為persistent inline banner。**

UX備選方案二（始終顯示inline小提示）優於原設計。理由：

- 「Don't show again」之設計假設：用戶記得自己勾過。音頻轉寫為低頻操作（相較voice input），記憶衰退期較長。
- Voice input暫停為**功能性副作用**，非一次性警告。每次皆發生，故每次皆應告知。
- Spec明言此為safety constraint（§5.4並發衝突）。checkbox繞過safety constraint，違反spec意圖。

**建議實作：** 錄音確認頁保留確認dialog，但移除checkbox。改為底部固定單行banner：`⚠ Voice input pauses during transcription`，`.caption2`，`systemOrange`，永遠顯示，不可關閉。此banner亦出現於轉寫確認頁及轉寫中畫面，三處一致。

---

### Q3：Cancel丟棄partial result是否過於浪費？

**裁斷：維持丟棄，但增加一條確認文字。**

保留partial result之成本：
- 需定義partial transcript之存儲格式（不完整metadata）
- 歷史列表須處理「不完整」狀態，增UI複雜度
- 用戶若不知partial有多少，「80%完成但不知道」比「歸零」更令人焦慮

丟棄之成本：
- 45分鐘轉寫到80%取消——確實浪費。但此為用戶主動選擇，非系統強制。

**建議實作：** Cancel按鈕點擊後，先顯示inline確認：
```
Cancel transcription?
Progress will be lost (80% complete).
[Keep going]  [Cancel anyway]
```
此確認令用戶知悉進度，自行承擔後果，DA不再反對丟棄。

若UX認為此二次確認過重，可退而求其次：Cancel按鈕長按2秒觸發（破壞性操作慣例）。

---

### Q4：歷史上限20筆是否太少？

**裁斷：改為50筆，但此決策屬spec層級，須PM確認。**

UX觀察正確：音頻轉寫之成本遠高於voice input片段，用戶更珍視歷史。

計算：
- 50筆之轉寫文本（純文字）：假設每筆2萬字（2小時錄音），50筆 = 100萬字 ≈ 4-5 MB。文字存儲幾乎可忽略。
- 歷史上限受2GB磁盤cap約束——但2GB限制的是**錄音文件**，非文字轉寫結果。二者需分開計算。

**DA發現潛在spec矛盾：** spec §constraint 8「Recordings + transcripts total cap: 2 GB」——「transcripts」在此指文字transcript，抑或錄音文件？若含錄音m4a，2GB極快耗盡（每小時50-70MB）；若含文字transcript，20筆上限過於保守。建議PM釐清此約束之確切範圍，再由UX調整歷史上限。

---

### Q5：首次使用提示文字是否過於didactic？

**裁斷：刪除，改為極簡subtitle。**

UX原文：「Record or upload audio up to 2 hours. Transcription runs entirely on your Mac.」——二句話，第一句功能說明（Record/Upload卡片已自明），第二句privacy promise（重要但非流程必要）。

Target user（已用Input做voice input者）已知local transcription之value prop，無需重複告知。Power user確實反感。

**建議：** 刪除提示文字。若需保留privacy reassurance，置於Upload卡片subtitle：`.mp3 .m4a .caf .ogg · < 2hr · on-device`，以「on-device」替代長句。三次使用後隱藏之邏輯亦可省略，複雜度不值。

---

## 二、DA自識之盲點

### B1：Popover適合長轉寫文本否？——核心設計風險

**問題：** 結果頁文本區域max 280pt高，寬340pt。2小時錄音之轉寫文字可達數萬字，用戶在280pt高之窗口內閱讀、尋找特定段落，體驗極差。

**量化：** 340pt寬，`.system(.body)`字體約16字/行，280pt高約13-14行可見。2萬字 = 約1250行 = 用戶須滾動約90屏。

**UX設計之隱含假設：** 結果頁主要用途為Copy All或Export .txt，非閱讀。若此假設成立，280pt高可接受。若不成立，此設計嚴重低估用戶需求。

**DA建議：** 結果頁增加「在Finder中開啟」或「在TextEdit中開啟」action，使長文本之閱讀需求外包至系統工具。此為最小成本解法，不引入新窗口，符合PM之popover約束。

---

### B2：錄音中意外關閉popover——恢復路徑不清晰

**問題：** UX §4.3聲明「錄音中關閉popover：錄音繼續，menu bar icon保持record.circle pulse」。但：

1. 用戶重新開啟popover，**落於哪個tab？**
   - 若設計為「永遠落於Voice Input tab（預設）」，用戶需手動切至Transcribe tab才能見到錄音狀態。此為嚴重易用性問題。
   - UX §1「預設：Voice Input tab，不記憶上次tab」與此場景衝突。

2. 用戶若不知錄音繼續，可能以為已停止，另起voice input操作（雖voice input被暫停，但用戶可能困惑）。

**DA要求：** UX明確定義「錄音/轉寫進行中重新開啟popover」之tab恢復邏輯。建議：凡有active session（錄音中或轉寫中），開啟popover強制落於Transcribe tab，忽略「永遠落於Voice Input」規則。此為session override。

---

### B3：2小時錄音之進度估算準確度

**問題：** UX §2.4「剩餘時間：基於已處理chunk之平均速度估算」。此方法之前提假設——chunk處理速度穩定。

Phase 0 spike尚未完成，processing ratio未知。已知風險：
- 長音頻之chunk處理速度可能隨記憶體壓力增加而下降（thermal throttling、swap）
- 最後幾個chunk若遭遇多說話人或噪音，處理時間可能突增
- 「1:12 remaining」之估算若在最後10%突然跳至「5:00 remaining」，用戶體驗崩潰

**DA建議：**
1. 進度顯示加入信賴區間：「About 1-2 min remaining」，非精確秒數
2. 若已處理chunk之速度標準差 > 20%，自動切換為indeterminate模式（UX §2.4已有此後備，但觸發條件不夠寬鬆）
3. 永不顯示「0:00 remaining」再卡住——最後一chunk完成前，剩餘時間顯示最小值「< 1 min」

---

### B4：menu bar icon四態——認知負荷評估

**問題：** UX定義四態：`mic.fill`（idle）、`mic.fill`+pulse（voice recording）、`record.circle`（audio recording）、`waveform`（transcribing）、`checkmark.circle`（complete，2秒）。

實為五態（含complete），且：

1. `record.circle`（紅色pulse）與`mic.fill`+pulse（現有voice recording）之視覺差異在menu bar 16pt icon尺寸下是否可辨？兩者皆為紅色pulse動畫，差異僅icon形狀。用戶能否區分「我在錄音頭」與「我在轉寫」？

2. `checkmark.circle`顯示2秒後消失——此2秒通知若用戶不在電腦前（轉寫背景運行），完全無效。macOS notification已處理此情況，`checkmark.circle`的2秒動畫為錦上添花，可省。

3. `waveform` + pulse之「轉寫中」icon，與macOS其他app之音頻相關icon（如聲音設定面板）視覺相近，可能引起混淆。

**DA建議：**
- 簡化為三態：idle（`mic.fill`）、active（`mic.fill`+pulse，涵蓋voice recording與audio recording）、processing（`waveform`）
- 取消`checkmark.circle`短暫態，靠notification替代
- 若PM堅持區分voice recording與audio recording，則須A/B測試驗證可辨性，非UX直覺可決定

---

### B5：歷史列表與主流程之導航衝突

**問題：** 歷史列表存在於Transcribe tab之idle狀態下半部。流程衝突：

1. 用戶在idle狀態，滾動瀏覽歷史列表（列表max 200pt，可滾動）——此時點擊Record卡片（在歷史列表**上方**）需滾回頂部。若歷史項目多，用戶需先滾回頂部才能開始新錄音。此為導航陷阱。

2. 點擊歷史項進入結果頁，結果頁之「New」按鈕回到idle。但「Back」按鈕（§7.3流程圖）與「New」按鈕在結果頁設計（§2.5）中未明確區分——§2.5只有「New」(`arrow.counterclockwise`)，§7.3歷史模式有「Back」。同一UI元素，二種語境，行為相同否？

**DA要求：**
- Record/Upload卡片固定於Transcribe tab頂部（sticky），歷史列表滾動不影響入口可達性
- 歷史模式之結果頁，「New」按鈕標籤改為「← Back」，明確區分「開始新轉寫」與「返回列表」之語義差異

---

### B6：轉寫失敗後錄音文件之命運——spec衝突

**問題：** UX §2.4 Cancel行為（第5點）：「若為錄音模式，m4a文件……直接刪除」。UX §5.3失敗處理（處理中crash）：「錄音文件保留供重試」。

**矛盾：** Cancel主動刪除，但crash保留。若用戶在轉寫80%時遭遇crash，文件保留；主動Cancel，文件刪除。用戶若將crash誤認為系統問題，重啟後發現文件仍在，可重試——此為良好體驗。但若用戶在crash後未意識到，再次開啟app時看到歷史列表有一筆「Transcription interrupted」，點擊後才知需重試——此為隱藏狀態。

**DA要求：** 明確定義三種終止情境之文件命運：
| 終止情境 | m4a文件 | 歷史記錄 |
|---------|---------|---------|
| 用戶主動Cancel | 刪除 | 不建立 |
| 轉寫失敗/crash | 保留（供重試） | 建立，狀態「Failed — tap to retry」 |
| 完成 | 刪除（文字transcript已存） | 建立，正常顯示 |

此表格缺失為UX設計漏洞，需補全。

---

### B7：「Voice input paused」banner之過度出現

**問題：** 統計UX設計中「Voice input paused」banner/提示之出現位置：
1. 錄音確認對話框（§2.2.1）
2. 錄音中畫面底部（§2.2.2）
3. 轉寫確認畫面（§2.2.3）
4. 上傳確認畫面（§2.3.3）
5. 轉寫中畫面底部（§2.4）
6. Voice Input tab切換時之灰色banner（§5.4）
7. Floating pill（§5.4）

**七處。** 用戶在完成一次轉寫的過程中，可能見到此訊息5次。訊息重複度過高，將導致用戶習得性忽略（banner blindness）——真正需要注意時反而失效。

**DA建議：** 保留位置1（首次確認，有決策意義）、保留位置5（轉寫中，持續狀態）。位置2、3、4為重複，可簡化為icon狀態指示（menu bar icon已顯示錄音中），無需文字重申。位置6、7為並發保護，保留但需確認不同時觸發。

---

## 三、優先排序

| 項目 | 嚴重性 | 建議行動 |
|------|--------|---------|
| B2：popover恢復tab邏輯 | P0 | UX必須明確定義，否則EN無法實作 |
| B6：失敗後文件命運 | P0 | spec缺失，UX補表格後交PM確認 |
| B1：長文本閱讀體驗 | P1 | 加「在TextEdit中開啟」action |
| B3：ETA準確度 | P1 | 加信賴區間，放寬indeterminate觸發條件 |
| Q2：廢除checkbox | P1 | 改permanent banner |
| B5：歷史列表導航 | P1 | sticky header + Back/New語義區分 |
| Q3：Cancel確認 | P2 | 加inline確認顯示進度百分比 |
| B4：icon四態簡化 | P2 | 建議簡化，待PM裁定 |
| B7：banner過度重複 | P2 | 精簡至2處核心位置 |
| Q1：固定340pt | 已解 | 直接採用UX備選 |
| Q4：歷史50筆 | 待PM | 先釐清2GB cap之計算範圍 |
| Q5：刪除提示文字 | 低 | 改subtitle一行即可 |

---

## out

DA完成審查。B2、B6為blocking issues，UX需補齊後方可交EN實作。其餘項目UX自行裁斷，無需再過DA。

status: RDY
