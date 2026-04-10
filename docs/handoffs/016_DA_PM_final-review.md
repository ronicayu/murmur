---
from: DA
to: PM
pri: P1
status: RDY
created: 2026-04-10
---

## ctx

Phase 0 spike交付EN前之最終審查。讀訖spec rev 2、UX rev 2、handoff 013（DA challenge）、handoff 014（UX回應）。

四項審查重點：spec與UX一致性、Phase 0 exit criteria明確度、main window引入之技術風險、遺漏邊緣案例。

---

## 裁斷：LGTM（條件）

無P0阻塞。三項P1遺留，一項須EN于spike前確認。

---

## 一、Spec與UX一致性審查

### 通過項

| spec條文 | UX設計 | 判斷 |
|---------|--------|------|
| 錄音格式m4a，2hr cap | §4.2明確 | ✓ |
| 上傳格式.mp3/.m4a/.caf/.ogg，無.wav | §4.4.2明確 | ✓ |
| 轉寫中voice input暫停，自動恢復 | §4.4.3 + §4.5 + §4.6 | ✓ |
| Queue max 1 | §9.4最後一行 | ✓ |
| 取消不保留partial | §4.5 Cancel行為 | ✓ |
| 磁盤 < 1GB拒絕錄音 | §9.1 | ✓ |
| 2GB cap警告80%，拒絕100% | §9.1 | ✓ |
| Transcript history last 20 | spec §scope | ← 見下 |

### 矛盾一：歷史上限20筆 vs 50筆（尚未裁定）

spec §scope寫「last 20」；UX §3.3寫「50筆（待PM確認）」。此矛盾懸而未決——UX handoff 014已提請PM裁定，但PM尚未回應。

**影響：** EN若自行決定，兩方皆有依據，必起混亂。

**DA建議：** PM于本handoff out欄明確填寫：「20筆維持」或「改50筆，2GB cap僅含文字transcript」。Phase 0前須解。

### 矛盾二：2GB cap計算範圍仍模糊

spec §constraint 8：「Recordings + transcripts total cap: 2 GB」。UX §9.1計算磁盤用量之邏輯，隱含「2GB含錄音m4a」（以1.6GB觸發警告）。但：

- 若2GB含m4a錄音，2hr錄音單次可佔140MB，50筆上限文字5MB可忽略，實質限制完全由m4a主導。
- 若2GB僅含文字transcript，m4a為暫存，轉寫完成即刪，2GB cap幾乎永不觸發（50筆×50KB≈2.5MB）。

兩種理解均能自洽，但實作完全不同。**spec原文含糊，須PM一句話澄清。**

### 矛盾三：WAV上傳

spec constraint 4「No new permissions」——spec §deferred明言「WAV upload deferred」。UX §4.4.2格式驗證列出.mp3/.m4a/.caf/.ogg，未列.wav，一致。無矛盾。（記錄：一致。）

---

## 二、Phase 0 Spike Exit Criteria充分性

### 充分之處

- 六項測試均有明確方法與退出條件（通過/失敗標準清晰）。
- 「multi-speaker WER < 80% → deferred」之決策鏈清晰，EN可獨立執行。
- 「processing speed > 2x real-time → scope shrinks or cancel」決策鏈清晰。

### 一項遺缺：.ogg decode測試

spec Phase 0列有「m4a decode pipeline」測試（pass/fail）。**但未列.ogg。**

.ogg（Vorbis/Opus）在macOS原生AVFoundation支持有限——AVAsset不直接讀.ogg，需第三方解碼（如FFmpeg via Process或第三方framework）。若Phase 0不測此路徑，EN可能在V2 build中途才發現.ogg需額外依賴，影響bundle size及entitlement（若用FFmpeg二進制）。

**DA要求：** Phase 0 spike增加一行測試：
```
| .ogg decode pipeline | Confirm AVFoundation or alternate path can decode .ogg | Pass/fail + dependency documented |
```

若失敗（AVFoundation不支持，第三方引入entitlement問題），PM需裁定：移除.ogg支持，或接受依賴。

---

## 三、Main Window架構引入之技術風險

### 風險一：activationPolicy動態切換——已知macOS地雷

UX §1.3設計：`activationPolicy = .accessory`為預設，開啟main window時切為`.regular`，關閉後切回`.accessory`。

此方案有已記錄之macOS問題：
1. **切換時機：** `setActivationPolicy`在主線程以外調用（如window delegate回調）可能造成Dock icon閃爍或短暫重複出現。須確認在`windowWillClose`/`windowDidBecomeKey`時機正確。
2. **Space切換：** 若用戶在Mission Control用多個Space，app於`.regular`態時綁定某Space；切回`.accessory`後，再次切為`.regular`，可能出現在不同Space（默認行為）。對menu bar app用戶體驗異常。
3. **Cmd+Tab消失：** 切回`.accessory`後，若轉寫仍在背景運行，用戶無法用Cmd+Tab切換至app——只能點menu bar icon。此為設計預期，但**必須在UI中告知**（menu bar icon之pulse動畫為唯一指示）。目前UX設計未有任何文字說明此限制。

**DA建議：** EN于架構spike前（即Phase 0期間或之前）單獨驗證`setActivationPolicy`切換之macOS行為。此非Phase 0 spike正式測試項，但應為informal validation，防止V2 build中途踩坑。

**PM決策項：** 若`setActivationPolicy`切換問題嚴重，備選方案為「始終`.regular`，常駐Dock」（UX handoff 014提及）。PM需知此風險，以備回退。

### 風險二：Dock icon常駐 vs 動態——entitlement無影響，但用戶感知有影響

`.accessory` → `.regular`切換不涉及新entitlement（無需額外sandbox設定）。此點DA確認，非風險。

但動態切換對**已有其他Input窗口之用戶**（如多顯示器）可能造成混淆：Dock icon出現又消失，非典型macOS行為。用戶可能誤以為app崩潰。

**此為UX而非技術風險，記錄供UX知悉，無需blocking。**

### 風險三：`NSTextView`只讀 + `Cmd+F`

UX §4.6指定結果頁文本區域使用`NSTextView`（只讀），並支持`Cmd+F`文內搜尋（「NSTextView原生」）。

**問題：** `NSTextView`之`Cmd+F` Find Bar並非自動獲得——需主動設定`usesFindBar = true`，且`isEditable = false`時Find Bar默認停用。需代碼顯式啟用`isEditable = false; usesInspectorBar = false; usesFindBar = true`，並可能需處理`performFindPanelAction`之responder chain。

**此為EN實作細節，非Phase 0阻塞，但EN須知。** DA在此標記，免EN實作時遺漏。

### 風險四：Main Window + Menu Bar App之notification點擊導航

UX §8.3：「macOS notification點擊 → 開啟window至結果頁」。

此需`UNUserNotificationCenterDelegate`之`userNotificationCenter(_:didReceive:withCompletionHandler:)`正確處理，在app為`.accessory`態（window已關閉）時喚醒window並導航。

若app于`.accessory`態時收到notification點擊，`NSApp.activate(ignoringOtherApps: true)`加`setActivationPolicy(.regular)`之順序敏感。錯序可能導致window出現但不聚焦，或Dock icon不顯示。

**DA建議：** EN于Phase 0或architecture phase早期寫一個smoke test驗證此流程。

---

## 四、遺漏邊緣案例

### E1：錄音中系統睡眠

spec與UX均無「系統睡眠/螢幕保護」場景。若用戶啟動錄音後合上筆電蓋：

- macOS會在一定時間後強制suspend app（App Nap）。
- 錄音pipeline（AVAudioRecorder）在App Nap下行為不確定——可能靜默停止。
- 用戶重新開啟筆電，見到錄音畫面計時器仍在跑，但實際已停錄。

**DA要求：** UX §9增加一行，EN Phase 0或V2 build早期驗證AVAudioRecorder在螢幕關閉/App Nap下之行為。若有問題，使用`NSProcessInfo.performActivity(reason:options:using:)`防止App Nap。

### E2：Phase 0 test files之來源——spike可執行性風險

spec Phase 0要求「5 EN + 5 ZH single-speaker recordings」、「5 EN + 5 ZH multi-speaker recordings」。共20個測試文件，涵蓋不同時長（5/15/30/60/120分鐘）。

**問題：** 誰准備這些test files？spec無指定。若EN需自行錄製或取得，可能耗費spike時間預算（5天）之顯著部分。

**DA建議：** PM于out欄確認test files來源：
- 選項A：PM/QA準備並存入`/tests/audio-fixtures/`（spike前就位）
- 選項B：EN使用公開數據集（需確認license）
- 選項C：EN自行錄製（最慢，不建議）

若選項未確定，Phase 0第一天即阻塞。

### E3：Retry時m4a文件與歷史項之生命周期——孤兒文件風險

UX §5（文件命運表）：失敗後m4a保留供Retry。但：

1. 若用戶右鍵刪除失敗歷史項，m4a應同時刪除——UX §3.3「右鍵選單：Delete」有提及，但未明確「Delete同時刪除關聯m4a」。若忘記，m4a成孤兒文件，消耗磁盤且不計入2GB cap。
2. 若Retry成功，m4a應在轉寫完成後刪除（同§5第三行）。若成功後不刪，同上問題。
3. App更新/重裝後，孤兒m4a（存於App Support）可能殘留。

**DA要求：** UX §5補充「刪除失敗歷史項 → 同時刪除關聯m4a」明確說明，並加一條：「Retry成功後，m4a按第三行規則刪除（轉寫完成即刪）」。EN在實作歷史刪除邏輯時須保證無孤兒文件。

### E4：Cmd+R衝突——錄音中再按觸發停止，但結果頁亦可能誤觸

UX §8.2：`Cmd+R` 在idle下開始錄音，在recording中停止錄音。**但`Cmd+R`在macOS慣例中為「Reload」**（Safari, Xcode等）。

若main window有任何WebView或可刷新元素，`Cmd+R`可能被intercepted。更重要：用戶可能在結果頁（習慣性）按`Cmd+R`（試圖「刷新」或「重試」），實際上main window此時處於result state，`Cmd+R`無定義行為——行為未知，可能靜默無反應或觸發意外responder chain。

**DA建議：** UX §8.2補充`Cmd+R`在各非錄音狀態（idle卡片顯示時）之作用域限制，確認結果頁`Cmd+R`無反應或有明確定義。低優先，但易令EN困惑。

---

## 五、優先排序

| 項目 | 類別 | 嚴重性 | 建議行動 |
|------|------|--------|---------|
| 矛盾一：歷史20 vs 50筆 | spec/UX不一致 | P1 | PM于本handoff out欄裁定 |
| 矛盾二：2GB cap範圍 | spec含糊 | P1 | PM一句話澄清（含/不含m4a） |
| E2：test files來源 | Phase 0可執行性 | P1 | PM確認誰負責，spike前就位 |
| .ogg decode測試缺失 | Phase 0 exit criteria | P1 | spec Phase 0增加一行測試 |
| E1：系統睡眠/App Nap | 技術遺漏 | P1 | UX §9補充；EN Phase 0驗證 |
| 風險一：activationPolicy切換 | 技術風險 | P1 | EN spike前informal validation |
| E3：孤兒m4a文件 | 邊緣案例 | P2 | UX §5補充刪除語義 |
| 風險四：notification點擊導航 | 技術風險 | P2 | EN早期smoke test |
| 風險三：NSTextView Cmd+F | 實作細節 | P2 | EN實作時留意 |
| E4：Cmd+R作用域 | UX細節 | P3 | UX補充說明即可 |

---

## 六、PM所需裁定（out欄請填）

1. **歷史上限：** 維持20筆 or 改50筆？
2. **2GB cap：** 含錄音m4a o 僅含文字transcript？
3. **Test files：** 誰在Phase 0 spike前準備20個測試音頻？
4. **activationPolicy備選方案：** 若動態切換有問題，始終`.regular`是否可接受？

---

## out

DA完成最終審查。無P0阻塞。四項P1遺留，須PM裁定後方可放行EN。若PM于本handoff out欄完成裁定，DA無異議，Phase 0 spike可啟動。

status: RDY
