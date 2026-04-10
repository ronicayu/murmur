---
from: DA
to: PM
pri: P1
status: open
created: 2026-04-10
---

## ctx

PM於 docs/specs/meeting-transcription.md 提V2 spec，欲以Cohere Transcribe處理會議錄音及音頻上傳。核心賭注：聲稱同模型可兼語音輸入與長音頻轉寫。DA審之，見七大疑點，陳於下。

---

## ask

**1. 技術可行性：模型非為長音頻而設**

Cohere Transcribe之公開文件聚焦即時語音輸入（streaming ASR）。一小時會議音頻，分塊處理之切割點如何定？Spec言「chunked processing」，卻未指定chunk大小、overlap策略、拼接演算法。跨chunk邊界之句子如何復原？若VAD分塊，靜音偵測於嘈雜會議室能否可靠？此三問，spec皆無答——乃假設而非設計。

**2. 「< 1x real-time於M1 Pro」——此數字從何而來？**

Success metrics列「60分鐘音頻需少於60分鐘處理」。此乃benchmark目標抑或已驗證數據？Cohere Transcribe之throughput於長音頻有無實測？若處理速度為2x real-time，整個V2 premise崩潰。Phase 0 spike必須在任何UI或架構決策之前完成，否則此spec乃建於沙上。

**3. 範圍蔓延之隱患：「會議轉寫」乃另一產品**

Input之core job——「說話即輸入，代替鍵盤」——與「會議記錄工具」乃不同心智模型。前者為即時、片段、工具性；後者為非同步、完整、文件性。同一app容納兩模式，用戶認知負擔倍增。Spec將speaker diarization、timestamps、summary、editing皆推至deferred——但用戶期望會議轉寫工具必備此四項。無之，V2之「會議轉寫」乃殘缺品，引發差評而非口碑。何不以獨立app（Murmur Minutes）發布，保Input品牌純粹？

**4. 單模型實例之競爭衝突**

Spec Open Questions第2點自問：語音輸入與會議轉寫可否並行？自答「probably not」。此乃嚴重UX破壞。用戶錄製一小時會議後點「Stop」，轉寫期間語音輸入全程失效——Input之核心功能消失達數十分鐘。Spec提「block or queue」，卻未決策。此非open question，乃must-resolve-before-build。若block，V2 launch即製造regression。

**5. 錄音格式未決，卻言無duration cap**

Spec言「no duration cap in v2.0」，同時錄音格式留為open question（WAV vs m4a）。WAV格式下，一小時立體聲錄音約600MB；八小時全日會議逾4.8GB。用戶磁盤空間無預警消耗。Spec僅言「memory budget +500MB」——此為RAM限制，非disk限制。磁盤清理策略於V2.0必須明確，否則用戶首次使用後即告磁盤不足。

**6. 「90% WER於多人對話」——此標準過寬**

Success metrics要求英語會議WER > 90%。然多人交叉說話（crosstalk）之WER於業界最佳模型（Whisper large-v3、AssemblyAI）亦僅達85-88%。Cohere Transcribe於此場景之公開benchmark幾近空白。若實測WER僅達80%，spec之metric即告失敗——而Cohere Transcribe無說話人分離，多人場景之輸出為混合文字流，用戶實際體驗遠低於WER數字所示。此metric需基於實測，非假設。

**7. 競爭定位：護城河薄弱**

MacWhisper（免費）、Whisper.cpp（開源）、Aiko（App Store）皆提供本地會議轉寫，且Whisper large-v3準確度有公開benchmark支撐。Input之差異化主張為「Cohere Transcribe + 零雲端」——但MacWhisper亦零雲端，且已有時間戳、speaker labels、export格式。V2若僅提供plain text輸出，何以說服已用MacWhisper之用戶遷移？「同模型、零額外下載」為工程便利，非用戶價值。PM需明確：V2之一句話差異化為何？

---

## constraints

- 必須本地，音頻與轉寫稿皆不出機器
- 必須使用Cohere Transcribe，不引入Whisper或其他ASR模型
- 僅macOS，Apple Silicon，16GB+

---

## refs

- docs/plan.md
- docs/specs/meeting-transcription.md
- docs/handoffs/001_DA_PM_spec-challenge.md（先例：DA挑戰模式）
- docs/handoffs/002_PM_DA_spec-response.md（PM回應格式參考）
