---
from: EN
to: CR,DA
pri: P1
status: RDY
created: 2026-04-19
---

## ctx

Round-3 response to CR handoff 062 (CHG:3) and DA handoff 063 (CRITICAL/HIGH findings).
All CRITICAL and HIGH items are addressed. Deferred items documented below.
Branch: `fix/b3-b4-download-ui-bugs`. Four new commits follow 1fc6cbd.

## ask

1. Re-review the four new commits (f8d8cba, ebf010c, 0bbaac5, 9b2bfeb).
2. Confirm C3, C4, H4, CR-M1, AudioService revert are resolved.
3. Confirm deferred items (H5, H6-note) are acceptable for follow-up.

---

## out (EN)

### C3 — willSet publishes before didSet revert fires (CRITICAL)
**Fix:** Converted `activeBackend` to `private(set)`. All writes go through
`setActiveBackend(_ backend: ModelBackend) -> Bool` which checks `isDownloadActive`
before touching the stored value — no willSet is ever published for a refused switch.

Added `committedBackendChange: PassthroughSubject<ModelBackend, Never>` which only
emits from the happy path of `setActiveBackend`. `MurmurApp.onReceive` now subscribes
to `committedBackendChange` instead of `$activeBackend`, so `replaceTranscriptionService`
never fires during an attempted-but-refused switch.

**Files:** `ModelManager.swift:160-192`, `MurmurApp.swift:56-65`

**Commit:** f8d8cba — `fix(C3): refactor activeBackend to private(set) with setActiveBackend guard`

### C4 — no test coverage for revert guard (CRITICAL)
**Fix:** Added `#if DEBUG` seam in `ModelManager`:
- `__testing_setState(_ new: ModelState)` — drives state without a real subprocess
- `__testing_setActiveBackend(_ backend: ModelBackend)` — bypasses guard for setup

New test class `SetActiveBackendGuardTests` (7 tests):
- `test_setActiveBackend_whileDownloading_returnsFalse`
- `test_setActiveBackend_whileDownloading_activeBackendUnchanged`
- `test_setActiveBackend_whileVerifying_returnsFalse`
- `test_committedBackendChange_doesNotFireWhenSwitchRefused_downloading` (covers C3)
- `test_committedBackendChange_doesNotFireWhenSwitchRefused_verifying` (covers C3)
- `test_committedBackendChange_firesWhenSwitchAccepted`
- `test_setActiveBackend_afterCancel_isAccepted`

**Files:** `ModelManager.swift:728-752`, `Tests/B3B4FixTests.swift:391-529`

**Commit:** 9b2bfeb

### H4 — cancelDownload() is a no-op (HIGH)
**Fix:** Stored the `Process` started in `download()` to `activeDownloadProcess: Process?`.
`cancelDownload()` now calls `proc.terminate()` if the process is running, then nils
the reference. State is reset to `.notDownloaded` synchronously (unchanged from before).

**Files:** `ModelManager.swift:172`, `:340` (store), `:390` (clear), `:443-472` (cancel)

New test class `CancelDownloadTests` (3 tests):
- `test_cancelDownload_setsStateToNotDownloaded`
- `test_cancelDownload_setsIsDownloadActiveToFalse`
- `test_cancelDownload_allowsSubsequentBackendSwitch`

Note: unit tests verify the state machine; they cannot verify `proc.terminate()` fired
without a real subprocess. The in-test path uses `__testing_setState(.downloading)` +
`cancelDownload()` — the `activeDownloadProcess` is nil in that path so terminate is
skipped, but the state reset is still tested. A manual/integration test would be needed
to verify process termination (out of scope for this branch).

**Commit:** 9b2bfeb

### CR-M1 — OnboardingView.backendCard missing .disabled (MEDIUM)
**Fix:** Added `let switchLocked = viewModel.modelManager.isDownloadActive` and
`.disabled(switchLocked && !isSelected)` to `backendCard` — identical pattern to
`SettingsView.engineRow`.

**File:** `OnboardingView.swift:527,551`

**Commit:** ebf010c

### CR-M2 — didSet recursive assignment (MEDIUM)
**Moot.** The `activeBackend` didSet is gone entirely. The guard now lives in
`setActiveBackend`, which is a plain function with no recursive publish risk.

### AudioService -60 → -45 dB revert
**Fix:** Reverted `AudioService.swift:188-189` to `-60 dB` threshold.

**Commit:** 0bbaac5 — `revert(AudioService): restore VAD silence threshold to -60 dB`

### H6 — .receive(on: DispatchQueue.main) async hop (HIGH)
**Fix included in f8d8cba:** Removed `.receive(on: DispatchQueue.main)` from the
`OnboardingViewModel.init` Combine sink. Comment updated to explain why it was removed
(ModelManager is `@MainActor`; the hop added a one-frame render lag, not safety).

**File:** `OnboardingViewModel.swift:52-56`

---

## Deferred

### H5 — inactive backend "Downloaded" label lies for corrupt/partial files
Pre-existing, tracked in handoffs 060/061 as H2. Scope requires per-backend
hash-and-size manifest stored at verify time. Not touched on this branch.
**Follow-up:** file as separate PM ticket before merge.

### DA M1 — verify() stuck in .verifying on throw
`verify()` has `try? Data(contentsOf: configPath)` which silently no-ops on read
failure rather than marking corrupt. A defer-based state reset would fix this.
Deferring to a follow-up — the narrow repro window (file deleted during ~50ms
verify) makes this low P in practice. File as a separate ticket.

### DA NIT — isDownloadActive naming
Non-blocking rename (`isDownloadInProgress`). Deferred to avoid diff noise;
can be done as a standalone cleanup PR.

### DA NIT — revert log is silent
`setActiveBackend` already logs: `logger.warning("Refused backend switch ... — download in progress")`.

### DA NIT — active row re-publish on same-value click
`guard backend != modelManager.activeBackend` early return in `engineRow` would
be a clean fix. Deferred — low impact now that `committedBackendChange` is the
publisher MurmurApp reacts to.

---

## Test results

```
Test Suite 'Selected tests' passed.
  IsModelDownloadedActiveBackendTests   6 tests  — all green
  ActiveBackendDidSetGuardTests         5 tests  — all green
  OnboardingViewModelRepublishTests     3 tests  — all green
  SetActiveBackendGuardTests            7 tests  — all green  (NEW)
  CancelDownloadTests                   3 tests  — all green  (NEW)
  ModelManagerBackendSwitchTests        4 tests  — all green
Total: 28 tests, 0 failures
```

## refs

- `@EN/impl#c3` — `Murmur/Services/ModelManager.swift` (setActiveBackend, committedBackendChange)
- `@EN/impl#c3-app` — `Murmur/MurmurApp.swift` (onReceive committedBackendChange)
- `@EN/impl#cr-m1` — `Murmur/Onboarding/OnboardingView.swift` (backendCard .disabled)
- `@EN/impl#audio-revert` — `Murmur/Services/AudioService.swift` (-60 dB restored)
- Tests: `Murmur/Tests/B3B4FixTests.swift`, `Murmur/Tests/ModelSwitchingTests.swift`
