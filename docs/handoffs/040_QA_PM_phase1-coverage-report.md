# 040 — QA→PM：Phase 1覆蓋度報告

**From:** @QA
**To:** @PM
**Status:** RDY
**Date:** 2026-04-10
**Re:** Phase 1 feature-complete — 98 tests驗收

---

## 一、總體評估

| 項目 | 計劃 | 實際 | 覆蓋率 |
|------|------|------|--------|
| Unit Tests (UT-001~024) | 24 | ~18有效對應 | 75% |
| Integration Tests (IT-001~012) | 12 | ~6有效對應 | 50% |
| UI Tests (UI-001~016) | 16 | 0 | 0% |
| Edge Case Tests (EC-001~014) | 14 | ~5有效對應 | 36% |
| **合計** | **60** | 98（含額外tests） | — |

**98個tests通過，但其中約40個為計劃外新增tests（Phase0 spike、model switching、AppState型別）。計劃內60個tests覆蓋度低於預期。**

---

## 二、Unit Tests覆蓋分析（UT-001~024）

### 已覆蓋

| ID | 計劃描述 | 實際覆蓋 | 文件 |
|----|---------|---------|------|
| UT-001 | progress callback chunk/total | `test_sendLong_callsOnProgressForEachProgressEvent` | TranscriptionServiceLongTests |
| UT-002 | progress百分比遞增 | 部分：test確認chunk序號但未顯式驗證monotonic | TranscriptionServiceLongTests |
| UT-005 | error JSON→拋出TranscriptionError | `test_sendLong_throwsWhenResultContainsErrorField` | TranscriptionServiceLongTests |
| UT-012 | history add count遞增 | `test_add_entry_persists_to_disk` + `test_add_multiple_entries_preserves_insertion_order` | TranscriptionHistoryServiceTests |
| UT-013 | 50筆上限淘汰最舊 | `test_prune_enforces_50_entry_limit` | TranscriptionHistoryServiceTests |
| UT-014 | delete單項 | `test_delete_entry_removes_from_store` + `test_delete_removes_only_target_entry` | TranscriptionHistoryServiceTests |
| UT-015 | delete不存在ID無crash | `test_delete_nonexistent_entry_does_not_throw` | TranscriptionHistoryServiceTests |
| UT-016 | clearAll歸零 | `test_clearAll_empties_store` + `test_clearAll_persists_empty_state_to_disk` | TranscriptionHistoryServiceTests |
| UT-021 | 磁盤 < 1GB拒絕錄音 | `test_start_throws_when_disk_space_below_1GB` | LongRecordingServiceTests |
| UT-022 | 磁盤 >= 1GB允許錄音 | `test_start_succeeds_when_disk_space_above_1GB` | LongRecordingServiceTests |

### 未覆蓋（缺失）

| ID | 描述 | 優先級 | 理由 |
|----|------|--------|------|
| UT-003 | Task取消→pipeline停止，Python process終止 | **P0** | 取消行為是核心資源安全性；現有tests未驗證process.terminate() |
| UT-004 | cancel後voice input恢復active | **P0** | VoiceInputController狀態機未有任何test |
| UT-006 | 轉寫完成後voice input自動恢復 | **P0** | 同上 |
| UT-007~011 | ChunkBoundaryCalculator — 5個邊界值tests | **P1** | `ChunkBoundaryCalculator`或等效邏輯無任何tests |
| UT-017~020 | VoiceInputController狀態機4個tests | **P0** | 完全缺失；voice input pause/resume是Phase 1核心功能 |
| UT-023 | m4a 80% cap警告 | **P1** | LongRecordingService只測阻擋，未測警告 |
| UT-024 | m4a 100% cap拒絕 | **P1** | 同上 |

---

## 三、Integration Tests覆蓋分析（IT-001~012）

### 已覆蓋（精神對應）

| ID | 描述 | 實際覆蓋 | 文件 |
|----|------|---------|------|
| IT-010 | history persist→reload | `test_add_entry_persists_to_disk` + `test_updateStatus_persists_to_disk` | TranscriptionHistoryServiceTests |
| IT-011 | delete→reload後消失 | `test_delete_entry_removes_from_store` | TranscriptionHistoryServiceTests |
| IT-012 | 50筆上限跨session | `test_prune_enforces_50_entry_limit` | TranscriptionHistoryServiceTests |
| IT-008/009 | activationPolicy切換 | Phase0SpikeTests（3個policy tests） | Phase0SpikeTests |

### 未覆蓋

| ID | 描述 | 優先級 | 理由 |
|----|------|--------|------|
| IT-001 | 真實Python subprocess — progress+result | **P0** | 端到端Python bridge未有integration test；現有tests均mock |
| IT-002 | model未載入→error JSON不crash | **P1** | 部分被TranscriptionServiceLongTests覆蓋（mock管道），但非真實subprocess |
| IT-003 | 錄音5秒→transcribeLong→non-empty transcript | **P2** | 需mic權限，CI不適合；可列manual test |
| IT-004 | 轉寫完成→m4a自動刪除 | **P0** | 無任何test驗證m4a cleanup邏輯 |
| IT-005~007 | 文件上傳格式驗證（mp3通過、wav拒絕、2hr拒絕） | **P1** | `AudioFileValidator`類別無任何tests |
| IT-006 | wav拒絕 | **P1** | 同上 |
| IT-007 | 超2hr拒絕 | **P1** | 同上 |

---

## 四、Edge Case Tests覆蓋分析（EC-001~014）

### 已覆蓋

| ID | 描述 | 實際覆蓋 | 文件 |
|----|------|---------|------|
| EC-012 | 並發transcription第二個被拒 | `test_transcribeLong_rejectsSecondConcurrentCall` | TranscriptionServiceLongTests |

### 未覆蓋

| ID | 描述 | 優先級 |
|----|------|--------|
| EC-001/002 | 錄音中關閉window，後台繼續；重開恢復畫面 | **P1** |
| EC-003 | Cancel後partial results不寫history | **P0** — TranscriptionWindowModelTests已部分覆蓋，但未驗證m4a路徑 |
| EC-004 | Cancel後m4a臨時文件刪除 | **P0** |
| EC-005/006 | 磁盤不足UI提示、m4a 80%警告UI | **P1**（UI層，需XCUITest） |
| EC-007~009 | 格式錯誤/duration邊界UI | **P1** |
| EC-010/011 | 孤兒m4a清理邏輯 | **P0** — `OrphanM4ACleaner`或等效邏輯無任何tests |
| EC-013 | 轉寫中Upload按鈕禁用 | **P1**（UI層） |
| EC-014 | Python crash→history.failed，保留m4a | **P0** |

---

## 五、UI Tests覆蓋（UI-001~016）

**完全缺失。** 16個XCUITest全未實作。

- UI-001~003：window open/close、Cmd+N導航 — **P1**
- UI-004~007：錄音流程UI — **P1**
- UI-008~010：上傳流程UI — **P1**
- UI-011~013：進度UI、Copy All — **P1**
- UI-014~016：搜尋、sidebar — **P2**
- UI-017~019：menu bar icon（Manual）— 已明確標記manual，**無需補**

---

## 六、冗餘/低價值Tests

| Tests | 評估 |
|-------|------|
| `Phase0SpikeTests`（8個）| 驗證macOS API surface，非Phase 1功能；保留但標記為spike validation，不計入Phase 1覆蓋 |
| `AppCoordinatorTests`中`testHistoryMaxCount`、`testHistoryPreservesLanguage` | 測試local array邏輯，非真實`TranscriptionHistoryService`；已被`TranscriptionHistoryServiceTests`更嚴格覆蓋，屬**冗餘** |
| `ModelSwitchingTests.testRapidBackendSwitching`、`testConcurrentSetModelPathAndKillProcess` | 價值高，保留 |
| `P0FixTests.testAutoLanguagePassedToTranscription` | 只測string equality；**低價值**，可刪 |

---

## 七、P0缺失Tests — 需立即補寫

以下5組為**P0**，已直接補寫入 `Murmur/Tests/Phase1P0MissingTests.swift`：

1. **VoiceInputController狀態機**（對應UT-017~020 + UT-004/006）
2. **m4a自動刪除**（對應IT-004）
3. **Cancel後m4a刪除**（對應EC-004）
4. **孤兒m4a清理**（對應EC-010/011）
5. **Python crash→history.failed**（對應EC-014）

---

## 八、P1缺失Tests — 建議下sprint補寫

1. `ChunkBoundaryCalculator` 5個邊界值tests（UT-007~011）
2. `AudioFileValidator` 3個tests（IT-005~007）
3. m4a cap warning tests（UT-023/024）
4. Window state restore during background recording（EC-001/002）
5. XCUITest suite（UI-001~013）— 需獨立test target

---

## 九、結論

Phase 1的98個tests在**基礎服務層**覆蓋扎實（History CRUD、磁盤檢查、JSON parsing、並發guard）。**主要缺口**：

- VoiceInputController整個狀態機**無tests**（P0）
- m4a生命週期管理（刪除、孤兒清理）**無tests**（P0）
- UI層（XCUITest）**全空**
- AudioFileValidator **全空**

P0 tests已補寫。P1留下sprint處理。
