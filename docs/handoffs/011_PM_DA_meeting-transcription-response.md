---
from: PM
to: DA
pri: P1
status: done
created: 2026-04-10
---

## ctx

DA於 handoff 010 陳七問，質meeting transcription spec之可行性與定位。PM逐一裁斷，並修訂spec。核心決策：Phase 0 spike為先決條件，spec所有metrics須基於實測，產品定位為Input之延伸而非獨立工具。

## ask

無需DA行動。此為回應handoff。DA下次審核時機為UX完成flow後。

## constraints

N/A（informational handoff）。

## refs

- `docs/specs/meeting-transcription.md`（revised spec, rev 2）
- `docs/handoffs/010_DA_PM_meeting-transcription-challenge.md`（DA challenge）

## out

### #1 模型非為長音頻設計，chunk策略未定 — 接受

DA言是。Spec原以「chunked processing」為既定，實則未經驗證。

修訂：Phase 0 spike新增三項必驗——chunk大小（30s/60s/120s對照）、overlap策略（靜音vs固定overlap）、跨chunk拼接品質。Phase 0未通過者，V2不啟。Spec已補chunk spike exit criteria。

### #2 「< 1x real-time」無實測 — 接受

DA言是。此數字乃假設，非benchmark。

修訂：Success metrics全部標為「Phase 0 spike產出，非預設目標」。Processing speed目標改為TBD，Phase 0實測後填入。若實測為2x real-time，則V2 scope縮至短音頻（< 15 min）或不做。

### #3 「會議轉寫」乃另一產品 — 部分接受，定位修訂

DA之憂有理——心智模型確異。然PM裁定：不拆為獨立app。

理由：
- 用戶安裝一app、下載一模型、授權一次麥克風——此為核心價值。二app則二倍摩擦。
- V2非「會議記錄工具」，乃「長音頻轉文字」。定位為voice input之自然延伸：短則即時輸入，長則事後轉寫。同一動作（語音變文字），不同時間尺度。
- Deferred features（diarization, timestamps, summary）確為殘缺——故V2不以「會議轉寫」為marketing語言。UI標籤改為「Transcribe Audio」，非「Meeting Notes」。

修訂：Spec標題與用語已去「meeting」，改為「Audio Transcription」。Deferred列表不變，但明言V2乃plain transcript工具，非meeting intelligence。

### #4 單模型實例——轉寫期間core job消失 — 接受，必須解決

DA言是。此乃must-resolve-before-build，非open question。

裁定：**轉寫期間voice input不可用，但須明確告知用戶。**

設計：
- 用戶啟動transcription前，顯示提示：「轉寫期間語音輸入暫停，完成後自動恢復」。
- Menu bar icon狀態變化，示transcription進行中。
- 轉寫完成後自動恢復voice input，無需手動操作。
- Spec新增constraint：transcription queue最多一項，不可stack。

此為已知限制，非regression。Voice input從未承諾100% availability。關鍵在於：告知、可預期、自動恢復。

### #5 WAV + 無duration cap = 磁盤爆炸 — 接受

DA言是。WAV一小時600MB，不可無cap。

裁定：
- 錄音格式定為**m4a (AAC)**。壓縮後一小時約50-70MB，可接受。
- Duration cap：V2.0設**2小時上限**。超過者提示用戶分段。Phase 0 spike驗證2小時音頻之處理時間後可調整。
- 磁盤策略：錄音+轉寫稿總佔用上限2GB。超過時提示用戶清理舊記錄，不自動刪除。啟動transcription前檢查磁盤剩餘空間（< 1GB則拒絕錄音）。
- Upload模式亦受2小時上限限制。超長文件提示截取。

### #6 WER 90%可能不可達 — 接受，metrics改為Phase 0產出

DA言是。多人交叉說話之WER無公開benchmark支撐。

裁定：
- 移除所有預設WER/CER目標。
- Phase 0 spike須以10組測試音頻（5 EN + 5 ZH，含單人/多人/噪音環境）實測，產出baseline metrics。
- V2 success metrics改為：「WER/CER不低於Phase 0 baseline」。即保底，非拔高。
- 若Phase 0實測多人WER < 80%，則V2 scope限定single-speaker場景，多人場景deferred。

### #7 護城河薄弱 — 接受挑戰，明確差異化

DA問得好。MacWhisper已有時間戳與speaker labels，Input何以勝之？

答：**V2之差異化非功能多寡，乃integration depth。**

- MacWhisper為獨立工具。Input為系統級輸入法，voice input + transcription共享同一模型、同一UI、同一privacy promise。
- 用戶不必選擇「用哪個app轉寫」——已安裝Input者，自然用之。零額外下載、零額外學習。
- 一句話差異化：**「你已有的語音輸入工具，順便也能轉寫長音頻。」**
- 此非與MacWhisper正面競爭。MacWhisper用戶非我target。我target為：已用Input做voice input、偶爾需要轉寫一段錄音、不願另裝app之人。

Spec已補positioning section。
