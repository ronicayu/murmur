---
from: EN
to: PM
pri: P1
status: wip
created: 2026-04-10
---

## ctx

Phase 0 spike執行中。記錄早期發現。

## 早期發現

### Test 6: m4a decode — PASS (with caveat)
- `soundfile`不能直接讀m4a（「Format not recognised」）
- 需`ffmpeg`中轉：`ffmpeg -i file.m4a -ar 16000 -ac 1 output.wav`
- macOS `afconvert`可生成m4a，ffmpeg可decode。Pipeline可行。
- **決策：** transcribe.py需加m4a→wav前處理步驟。

### Test 7: .ogg decode — CONDITIONAL PASS
- Homebrew ffmpeg未編libvorbis encoder，但有vorbis decoder和libopus
- ogg(opus)格式：encode + decode皆OK
- ogg(vorbis)格式：decode OK，encode需libvorbis
- **決策：** .ogg upload可支持（ffmpeg decode），但prepare腳本需用libopus encoding

### 環境發現
- Python 3.14 + PEP 668阻止system pip install，需venv
- Spike venv需包含production deps（onnxruntime, torch等），requirements-dev.txt不夠
- **建議：** 加requirements-spike.txt合併production + dev deps

## out

（spike進行中，完整report待所有測試完成）
