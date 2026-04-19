---
from: EN
to: QA
pri: P1
status: RDY
created: 2026-04-19
branch: fix/b3-b4-download-ui-bugs
refs: 073, 072
---

## ctx

Ship-blocker fix for the `CancelDownloadCleanupRaceTests` real-model-deletion risk
flagged by QA in 073 (item 4 in test-code quality notes) and echoed by DA in 072
(non-blocking residual item 2).

---

## fix

**Approach (b)** — `XCTSkipIf` in `setUpWithError`. The code-under-test
(`__testing_runCleanupAfterCancel`) calls `modelDirectory(for:)` internally;
there is no injectable directory parameter without touching production code, so
approach (a) was ruled out.

**File:** `Murmur/Tests/B3B4FixTests.swift`
**Line:** `CancelDownloadCleanupRaceTests.setUpWithError` (line ~632 post-edit)

```swift
try XCTSkipIf(
    manager.modelPath(for: .onnx) != nil,
    "Real ONNX model present on this machine — skipping CancelDownloadCleanupRaceTests " +
    "to protect pre-downloaded model files. Run on a machine without the ONNX model installed."
)
```

`modelPath(for: .onnx)` returns non-nil only when all required ONNX files exist,
which is the exact condition that makes the destructive test dangerous. The guard
fires before the sentinel file is written, so setUp is fully safe.

`tearDownWithError` was also hardened: it now guards on `if let dir = tempModelDir`
to handle the case where `XCTSkipIf` throws before `tempModelDir` is assigned.

**C8 correctness preserved:** On a machine without the ONNX model, both tests
run as before and prove the cleanup logic:
- `test_cleanupAfterCancel_skipsRemoveItem_whenNewDownloadIsActive` — guard fires,
  dir survives.
- `test_cleanupAfterCancel_removesDirectory_whenNoDownloadIsActive` — no guard,
  dir is removed.

---

## test results

`swift test` run post-fix:
- **274 tests executed**, 16 skipped, 11 failures (all pre-existing AX integration
  failures requiring running GUI apps — unrelated to this branch).
- `CancelDownloadCleanupRaceTests`: both tests **passed** on this dev machine
  (no real ONNX model installed).
- No regressions introduced.

---

## no production code changed

Only `Murmur/Tests/B3B4FixTests.swift` was modified.
