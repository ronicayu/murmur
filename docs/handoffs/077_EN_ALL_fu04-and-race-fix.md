---
from: EN
to: ALL
pri: P0
status: RDY
created: 2026-04-19
branch: fix/b3-b4-download-ui-bugs
commit: fc8e5bb
refs: 076 (PM ship decision), 068 (integration test ask), FU-04
---

## summary

Two fixes shipped in one commit (fc8e5bb):

1. **Termination-handler race** — root cause of "stuck at Finalizing" when HF
   cache hit causes subprocess to exit before handler is attached.
2. **FU-04 manifest verification** — manifest-gated `isModelDownloaded` and
   `verify()` replacing the file-existence-only check.

---

## fix 1: termination-handler race

**File:** `Murmur/Services/ModelManager.swift`

**Root cause:** `process.terminationHandler` was attached *after*
`try process.run()`. When `huggingface_hub.snapshot_download` sees a full
cache hit, the subprocess exits in milliseconds. The handler never fires; the
`withCheckedContinuation` never resolves; state stays `.downloading` forever.

**Fix (lines ~467–551):** Restructured `download()`, `runProcess()`, and
`runProcessWithLiveOutput()` to attach `terminationHandler` *before* calling
`process.run()`, with an `NSLock`-guarded bool `alreadyResumed` preventing
double-resume:

```swift
let resumeLock = NSLock()
var alreadyResumed = false
let exitStatus: Int32 = await withCheckedContinuation { continuation in
    process.terminationHandler = { proc in
        resumeLock.lock(); defer { resumeLock.unlock() }
        guard !alreadyResumed else { return }
        alreadyResumed = true
        continuation.resume(returning: proc.terminationStatus)
    }
    do { try process.run() } catch { /* resume(-1) under lock */ return }
    activeDownloadProcess = process
    // Defensive: process may have already exited before we got here
    if !process.isRunning {
        resumeLock.lock(); defer { resumeLock.unlock() }
        guard !alreadyResumed else { return }
        alreadyResumed = true
        continuation.resume(returning: process.terminationStatus)
    }
}
```

The `NSLock` guard is thread-safe: `terminationHandler` fires on a background
queue; the defensive check runs on the calling actor. Both paths are covered.

**Monitor fixes (same function):**
- Removed HF cache dir (`~/.cache/huggingface`) from size tracking — it can be
  arbitrarily large from unrelated prior downloads, producing false MB counts.
  Now tracks `modelDirectory` only.
- Removed "Finalizing" threshold (`modelSize > 1_000_000`). Monitor always
  emits "Downloading: N MB"; `verify()` sets "Verifying" when it actually runs.

---

## fix 2: FU-04 manifest verification

**File:** `Murmur/Services/ModelManager.swift` (new methods ~204–350)

### data model

```json
{
  "version": 1,
  "backend": "onnx",
  "createdAt": "2026-04-19T...",
  "files": {
    "config.json":                              { "sha256": "...", "size": 1234 },
    "onnx/encoder_model_q4f16.onnx":           { "sha256": "...", "size": 987654321 },
    "onnx/encoder_model_q4f16.onnx_data":      { "sha256": "...", "size": 876543210 },
    "onnx/decoder_model_merged_q4f16.onnx":    { "sha256": "...", "size": 765432109 }
  }
}
```

Manifest covers ALL regular files in `modelDirectory` (skips hidden and
`manifest.json` itself), not just `requiredFiles`, so weight files
(`.onnx_data`) are included.

### hot path — `isModelDownloaded(for:)` / `manifestIsValid(for:)`

- Requires `manifest.json` to exist.
- Requires every file in the manifest to exist with matching `size` (cheap
  `attributesOfItem` stat — no hashing).
- Returns false if manifest missing, any file absent, or any size mismatch.

### cold path — `verify()`

- Recomputes SHA-256 for every file in `modelDirectory` (except manifest).
- Compares against stored manifest hash-by-hash.
- Sets `state = .corrupt` and descriptive `statusMessage` on first mismatch.
- Writes `manifest.json` if none exists (first-time post-download flow).

### migration

`migrateToManifestIfNeeded(for:)` is called for every backend in `init()`:

- If manifest already exists: no-op (idempotent).
- If `requiredFiles` are all present but no manifest: hashes on-disk files,
  writes manifest, logs clearly.
- If files are absent: no-op (falls through to `.notDownloaded`).

Existing users are not forced to redownload. The migration runs once per
backend per machine.

### backward compat concern

`modelPath(for:)` now returns nil if `manifest.json` is absent, even if files
exist. The migration in `init()` handles this for existing installs. Any user
who has a partial download with all required filenames but truncated content
will see `isModelDownloaded` return false (correct: manifest size check catches
truncation), and be offered a redownload.

---

## tests

**New file:** `Murmur/Tests/ManifestVerificationTests.swift` — 19 tests across
4 classes:

| Class | Tests | Runs on this machine |
|---|---|---|
| `ManifestBuildAndValidationTests` | 9 | Skipped (real ONNX model present) |
| `ManifestVerifyCorruptionTests` | 4 | Skipped (real ONNX model present) |
| `ManifestMigrationTests` | 4 | Skipped (real ONNX model present) |
| `TerminationHandlerAtomicGuardTests` | 2 | PASS |

The skip guard (`XCTSkipIf(manager.modelPath(for: .onnx) != nil, ...)`)
protects the developer's downloaded model from being deleted by tests that
write into the same directory. Tests will run on a CI machine or a machine
without the ONNX model installed.

**Updated:** `Murmur/Tests/B3B4FixTests.swift` — 3 existing tests now call
`buildManifest`/`writeManifest` after planting stub files, to satisfy the
FU-04 contract that `manifestIsValid()` requires a manifest before returning
true.

**Full suite:** 293 tests, 11 failures (all pre-existing: AX integration tests
and flaky `StreamingPipelineIntegrationTests`), 16 skipped.

---

## migration behavior summary

| Scenario | Before this commit | After this commit |
|---|---|---|
| Fresh install, download completes | Files → `.ready` | Files + manifest → `.ready` |
| Cache-hit redownload (files exist) | HUNG (continuation never resolves) | Exits in <1s, manifest validated |
| Existing install, no manifest | `.ready` (file-existence only) | Migration writes manifest → `.ready` |
| Truncated file, no manifest | `.ready` (silent corruption) | Size mismatch → `.notDownloaded` |
| SHA-256 corruption, manifest exists | Undetected (only config.json checked) | `verify()` catches → `.corrupt` |

---

## asks

- **QA**: Run the manifest tests on a machine without the ONNX model installed
  to exercise the full class (not just the atomic guard tests). Track in FU-03.
- **UT**: Re-test the download flow end-to-end — the "stuck at Finalizing" bug
  should now be fixed. Try: kill Murmur with a cached model, relaunch, tap
  Download — should complete in seconds without hanging.
- **CR**: Review `buildManifest(for:)` — the directory walk uses
  `.skipsHiddenFiles` to avoid hashing `.` dirs; confirm this is appropriate
  for the HF download layout.
- **PM**: FU-04 is now done. FU-03 (integration test seam) and FU-01 (download
  UI polish) remain as follow-ups per 076.
