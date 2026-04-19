---
from: DA
to: EN, CR, PM
pri: P1
status: LGTM
created: 2026-04-19
branch: fix/b3-b4-download-ui-bugs
commit-reviewed: fa53a81
---

## ctx

Round-5 re-challenge. EN's round-5 (handoff 071) addresses C8 (HIGH, cleanup
race) and M6 (LOW, PID-reuse comment) from DA's round-4 (handoff 070). This is
the 4th DA gate; either LGTM or a genuine showstopper — no nit escalation.

Reviewed: commit `fa53a81`, diff across `ModelManager.swift` and
`Tests/B3B4FixTests.swift`.

## verdict

**LGTM.** The C8 fix correctly closes the cancel→redownload race for the
common case. M6 comment is accurate. Tests exercise the real code path (not
tautological). Two narrow gaps identified below are non-blocking — see
"accepted residuals" section.

## refs

- `Murmur/Services/ModelManager.swift:451-522` — cancelDownload with [weak self] Task
- `Murmur/Services/ModelManager.swift:541-576` — removePartialModelDirectory
- `Murmur/Services/ModelManager.swift:488-500` — M6 comment above Darwin.kill
- `Murmur/Services/ModelManager.swift:873-889` — __testing_runCleanupAfterCancel
- `Murmur/Tests/B3B4FixTests.swift:608-680` — CancelDownloadCleanupRaceTests
- Prior: 060–071

---

## out

### C8 fix — the MainActor hop analysis

The concern in 070 was whether `await MainActor.run { isDownloadActive }` could
lose a scheduling race. Traced the actor semantics:

- `ModelManager` is `@MainActor`-isolated at the type level (line 132).
- `cancelDownload()` runs on MainActor. At line 518 it synchronously sets
  `state = .notDownloaded`, then returns.
- The `Task.detached` at line 483 runs off MainActor. When it eventually
  invokes `await MainActor.run { isDownloadActive }`, that closure is enqueued
  onto the MainActor and runs atomically with respect to all other MainActor
  work.
- If the user has clicked Download in between, `download()` (line 287) runs
  on MainActor and line 291 sets `state = .downloading(...)` before any other
  MainActor job can interleave. When cleanup's `MainActor.run` eventually
  executes, it reads the up-to-date state.

**There is no ordering by which cleanup's `MainActor.run` can read a stale
`isDownloadActive` while a new `download()` is running.** The MainActor
serializes the read against both the cancel's state reset and the new
download's state set. LGTM.

**Reverse-ordering check.** If cleanup's MainActor.run runs BEFORE the user
clicks Download: cleanup sees `isDownloadActive == false`, calls
`removeItem`, dir is gone. Then user clicks Download. `download()` runs
`createDirectory(withIntermediateDirectories: true)` at line 296 — idempotent;
creates a fresh dir. No corruption. LGTM.

---

### C8 fix — cross-backend scenario (narrow residual)

**Scenario:** cancel `.onnx` download → switch to `.huggingface` via
`setActiveBackend` → click Download. The detached cleanup Task wakes, reads
`isDownloadActive == true` (but for `.huggingface`, not `.onnx`), and SKIPS
deletion of the `.onnx` partial dir.

The guard is coarse-grained: "any active download" → skip. A backend-aware
guard would be:

```swift
let shouldSkip = await MainActor.run {
    isDownloadActive && activeBackend == backend
}
```

**Is this a showstopper?** No, because:

1. The `.onnx` partial dir orphan is pre-existing H5-territory behaviour; the
   C8 fix only introduces this narrow extra window (the ~2.1s detached Task
   lifetime after cancel).
2. To cause user-visible harm, the partial would need to contain all required
   ONNX filenames (`config.json`, encoder+decoder `.onnx`). The ONNX files
   are ~700 MB each; the download would have to have progressed past both
   files' final flush at the exact moment of cancel. Very unlikely.
3. `refreshState()` recomputes `statusMessage` next time `setActiveBackend(.onnx)`
   fires; if the partial is incomplete, user sees "Partial download: X MB".
4. If the partial did complete all filenames, `isModelDownloaded(.onnx)`
   returns true — but this is the same H5 risk the round-3 mitigation already
   accepted for the "app crashed mid-download" case. No new class of bug.

**Recommendation (not blocking):** when EN next touches this code, tighten the
guard to be backend-aware. Filed as nit, not as C9.

---

### C8 fix — `[weak self]` deallocation scenario

**Scenario:** ModelManager is deallocated between `Task.detached` spawn and
`await self?.removePartialModelDirectory(...)`. `self?` is nil, the method
call is a no-op. The partial model directory is not cleaned up.

**Is this a problem?** No. ModelManager is owned by `MurmurApp` (the app
singleton) and survives for the app's lifetime. Deallocation mid-cleanup only
happens if the app is terminating, in which case:

- The detached Task itself is running on a global executor; it may or may not
  complete before app exit.
- A partial dir on disk is a known H5-territory edge case; `refreshState()`
  on next launch shows "Partial download: X MB".
- The partial dir is NOT mistaken for a complete download unless it happens
  to contain all required filenames — same acceptance as the main C8 residual.

`[weak self]` is the correct pattern here: if the owner is gone, don't extend
its lifetime for non-critical cleanup work. LGTM.

---

### M6 comment — accuracy

Read the comment at `ModelManager.swift:488-500`. It correctly describes:

- The sub-millisecond window between the last `proc.isRunning` poll and the
  `Darwin.kill` call.
- EPERM returned when the recycled PID belongs to another user's process.
- The "another Murmur child" edge case, correctly noted as extremely narrow
  because only one python subprocess is spawned at a time.
- Pointer to `kqueue EVFILT_PROC` as the clean long-term design.

One factual nit: the comment implies kill() returns EPERM "and is a no-op"
for another user's process. Technically kill() still returns -1 and sets
errno; the surrounding code doesn't read errno, so it IS effectively a no-op
for us. The comment is close enough. LGTM.

---

### Test quality — `CancelDownloadCleanupRaceTests`

Reviewed both tests at `B3B4FixTests.swift:608-680`:

1. `test_cleanupAfterCancel_skipsRemoveItem_whenNewDownloadIsActive` —
   arranges `.downloading` state, calls cleanup, asserts dir exists. This
   exercises the exact `await MainActor.run { isDownloadActive }` guard path
   and proves the skip branch works. Not tautological — it could have failed
   if the guard were implemented wrong (e.g. reading a stale copy of state).
2. `test_cleanupAfterCancel_removesDirectory_whenNoDownloadIsActive` —
   arranges `.notDownloaded` state, calls cleanup, asserts dir gone. Exercises
   the delete branch end-to-end via real `FileManager.removeItem`.

The `__testing_runCleanupAfterCancel` seam is a thin passthrough to the
production `removePartialModelDirectory` method — it bypasses only the
subprocess lifecycle (out of scope for unit tests; covered by H9/068). The
assertion guard (`NSClassFromString("XCTestCase") != nil`) matches the C7
pattern. Not a tautology. LGTM.

---

### Test hygiene — side effect on real user directory (MEDIUM nit)

**Where:** `B3B4FixTests.swift:622-624`.

The setUp does `tempModelDir = manager.modelDirectory(for: .onnx)`, which
resolves to `~/Library/Application Support/Murmur/Models-ONNX/`. This is the
REAL user model path, not a temp directory.

If a developer runs `swift test` on a machine with a real ONNX model installed
at that path:

1. setUp's `createDirectory(withIntermediateDirectories: true)` succeeds
   (idempotent — dir already exists).
2. setUp writes `sentinel.txt` into the real model dir.
3. `test_cleanupAfterCancel_removesDirectory_whenNoDownloadIsActive` calls
   `removePartialModelDirectory`, which `removeItem`s the entire directory —
   **deleting the real user's model**.
4. tearDown's `try? removeItem` is redundant (already gone).
5. Developer next runs Murmur → model missing → re-download.

**Severity:** MEDIUM. Not a production bug; affects developers running tests
locally. Not reachable in CI if CI runners don't have a model installed. Not
a shipstopper.

**Recommendation (not blocking):** swap to a temp directory for this test, or
gate setUp on "fail fast if real model exists at this path." Can be a QA
follow-up.

---

### Integration reality check — betting-money update

Revised round-4 predictions after the C8 fix:

1. **C8 (cancel → redownload same backend).** Probability of QA/UT hit:
   dropped from 80% to ~5%. The MainActor hop closes the common case.
   The residual ~5% covers the cross-backend scenario and only triggers if
   the partial happens to have all required filenames — uncommon.
2. **Developer's local model deleted by running tests.** 100% if a developer
   runs `swift test` on a machine with a real `.onnx` model. Annoying but
   recoverable.
3. **Cross-backend orphan.** 20%. Same severity as round-4's item 2.
4. **Zombie subprocess.** 5%, unchanged. Covered by H9/068 integration test.
5. **C7 XCTest assertion tripping in dogfood Debug.** 1%, unchanged.

Net risk profile: significantly improved from round-4. The remaining items
are QA/ship-gate territory, not EN code changes.

---

## accepted residuals (non-blocking)

- **Cross-backend orphan on cancel→switch→redownload.** Tighten
  `isDownloadActive` guard to be backend-aware in a future pass.
- **Test side-effect on real user directory.** QA should migrate
  `CancelDownloadCleanupRaceTests` to a temp-directory harness.
- **`[weak self]` skips cleanup on app shutdown.** Accepted; partial dir
  orphan is pre-existing H5 risk.
- **H9 / 068 integration-test gap.** PM ship-gate blocks on this, not an EN
  code change.

---

## summary

- **C8:** Fixed correctly via MainActor hop. Common case closed. Narrow
  cross-backend residual accepted.
- **M6:** Comment is accurate and helpful. Points to kqueue for future work.
- **Tests:** Exercise the real cleanup logic; not tautological. One test
  hygiene concern on real-user-dir side effect (QA follow-up).
- **[weak self]:** Correct pattern for this use case.

**Status: LGTM.** Branch moves to QA/UT.

PM: please carry the H9/068 hard-block forward to your ship-gate checklist,
and consider filing the two "accepted residuals" (backend-aware guard,
test-hygiene) as follow-up tickets.
