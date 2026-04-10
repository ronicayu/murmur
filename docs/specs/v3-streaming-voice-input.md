# V3 — Streaming Voice Input

**Author:** @PM
**Status:** PLANNED
**Created:** 2026-04-10
**Depends on:** V2 Audio Transcription (chunked pipeline)

---

## 概念

V1 voice input為「錄完→轉寫→注入」。V3改為pseudo-streaming：錄音中每3-5秒切chunk，即時轉寫並注入，用戶邊說邊看文字出現。錄音結束後，全文重新轉寫一次（full-pass），若結果不同則替換先前輸出。

## 行為

1. **默認關閉。** Settings中開關：「Streaming input (beta)」
2. **開啟後：**
   - 用戶按hotkey開始錄音
   - 每3-5秒自動切chunk，送入ONNX encoder-decoder
   - 每chunk轉寫完畢立即inject到游標位置（append）
   - 用戶鬆開hotkey停止錄音
   - 全文WAV做一次完整轉寫（full-pass）
   - 若full-pass結果與streaming拼接結果不同：select all streamed text → replace with full-pass result
3. **關閉時：** 行為與V1完全一致

## 技術要點

- 複用V2的`transcribe_onnx_chunked()`逐chunk pipeline
- 新增Python命令`transcribe_stream`：接收audio buffer stream而非文件路徑
- AudioService需改為dual-output：既寫WAV文件（供full-pass），又逐buffer送Python
- TextInjectionService需新增`appendText()`和`replaceRange()`方法
- Full-pass替換需追蹤injected text的selection range

## 風險

- Chunk邊界截斷問題（V2已有，streaming更敏感）
- 替換體驗：用戶正在游標後繼續打字，替換可能覆蓋用戶輸入
- 3-5秒延遲仍然明顯，非真正real-time
- CPU佔用：streaming期間持續推理，M1 8GB可能卡頓

## Open Questions

1. Chunk大小：3s vs 5s？更短更即時但更多邊界錯誤
2. Full-pass替換的UX：如何選中並替換？用戶在中間打了字怎麼辦？
3. 是否需要「接受/撤銷替換」的UI？
4. Streaming期間voice input的pill UI如何顯示文字？
