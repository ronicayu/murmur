---
from: CR
to: EN
pri: P1
status: LGTM
created: 2026-04-19
---

## ctx

Round-2 CR re-review of branch `fix/b3-b4-download-ui-bugs`.
Covers four new commits since handoff 062 (CHG:3):
- f8d8cba fix(C3): refactor activeBackend to private(set) with setActiveBackend guard
- ebf010c fix(CR-M1): add .disabled to OnboardingView.backendCard during active download
- 0bbaac5 revert(AudioService): restore VAD silence threshold to -60 dB
- 9b2bfeb test(C3,C4,H4): add seam-driven tests for download guard and cancel

Refs: handoff 062 (CR round-1, CHG:3), handoff 063 (DA CRITICAL findings),
handoff 064 (EN round-3 response, RDY).

## ask

N/A — this is a review response, not a request.

---

## out

**Overall verdict: LGTM**

All three CHG:3 items from handoff 062 are resolved. All DA CRITICAL (C3, C4) and
HIGH (H4, H6) items addressed. AudioService revert confirmed. No remaining blockers
from CR's scope. Deferred items (H5, DA-M1) are acceptable for follow-up.

---

### C3 — setActiveBackend guard replacing didSet (RESOLVED)

**Files:** `ModelManager.swift:141-164`, `MurmurApp.swift:56-67`

`activeBackend` is now `@Published private(set)`. All external writes go through
`setActiveBackend(_:) -> Bool`. The guard checks `isDownloadActive` before touching
the stored value, so no `@Published` willSet is ever emitted for a refused switch.
`committedBackendChange: PassthroughSubject<ModelBackend, Never>` emits only from
the accepted path. `MurmurApp.onReceive` now subscribes to `committedBackendChange`
(line 56), not `$activeBackend`.

Verified: no stray `$activeBackend` subscribers remain in live code (docs-only
references in handoffs 063/064 are comments, not subscriptions). The old `didSet`
recursion risk (MED-2, handoff 062) is eliminated entirely by design.

`objectWillChange.send()` note: `ModelManager` does not call it manually inside
`setActiveBackend`. This is correct. `activeBackend = backend` (line 160) triggers
`@Published`'s own willSet mechanism, which calls `objectWillChange.send()`
automatically before the value is stored. SwiftUI observers on `ModelManager`
receive exactly one publish per accepted switch, synchronously. No extra send needed.

### C4 — Test seam and guard coverage (RESOLVED)

**Files:** `ModelManager.swift:727-744`, `Tests/B3B4FixTests.swift:393-547`

`#if DEBUG` seam functions `__testing_setState` and `__testing_setActiveBackend`
are correctly scoped — they will not compile into release builds.

`SetActiveBackendGuardTests` (7 tests) covers:
- Return value `false` while `.downloading` and `.verifying`.
- `activeBackend` unchanged after refused switch.
- `committedBackendChange` does not fire on refused switch (both states).
- `committedBackendChange` does fire on accepted switch, with correct value.
- Switch is accepted after state returns to `.notDownloaded` (post-cancel).

All tests are testing observable behavior (return value, published state, subject
emissions), not internal implementation. Well-constructed.

### H4 — cancelDownload process termination (RESOLVED)

**File:** `ModelManager.swift:178, 341, 387, 442-470`

`activeDownloadProcess: Process?` is stored at line 341 immediately after
`process.run()`. `cancelDownload()` calls `proc.terminate()` if `isRunning` is
true. Reference is cleared at line 451 in cancel and at line 387 on normal
completion (after `terminationHandler` fires, so the process has already exited —
no premature nil on a running process).

Error-path analysis: all `throw` sites in `download()` are at lines 404, 415, 428,
438 — all after `activeDownloadProcess = nil` at line 387. No leak on any throw path.

Limitation acknowledged: unit tests use `__testing_setState(.downloading)` +
`cancelDownload()`, so `activeDownloadProcess` is nil in tests and the
`proc.terminate()` branch is not exercised by unit tests. EN's note in handoff 064
is accurate. This is an acceptable boundary for a unit test suite; integration/manual
verification covers the real subprocess path. QA should capture this.

### CR-M1 — OnboardingView.backendCard .disabled (RESOLVED)

**File:** `OnboardingView.swift:527, 556`

`switchLocked` is derived from `viewModel.modelManager.isDownloadActive` at line 527.
`.disabled(switchLocked && !isSelected)` applied at line 556. Pattern is identical to
`SettingsView.engineRow` (line 308, 339). Non-selected cards are disabled during
active download; the selected card stays enabled for visual affordance. Correct.

### H6 — .receive(on: DispatchQueue.main) removed (RESOLVED)

**File:** `OnboardingViewModel.swift:47-56`

`.receive(on: DispatchQueue.main)` is gone. Comment at lines 49-52 accurately
explains the reasoning: `ModelManager` is `@MainActor`, so `objectWillChange`
always fires on main. The hop was adding latency, not safety. Sink now delivers
synchronously on the publishing context, which is what SwiftUI's diffing expects.

### AudioService revert (RESOLVED)

**File:** `AudioService.swift:188-189`

Threshold is back to `-60 dB`. Log message at line 188 confirms: `"threshold: -60 dB"`.
No other references to `-45` remain in the codebase.

### Modified tests — ModelSwitchingTests.swift (CONFIRMED SAFE)

24-line change set updates `ModelManagerBackendSwitchTests` to call
`manager.setActiveBackend(...)` (returning discardable `Bool`) instead of the old
direct-assignment pattern. Coverage is not weakened: the four tests still assert
UserDefaults persistence, directory-per-backend, per-backend hash keys, and
post-switch `refreshState()` behavior. `_ = manager.setActiveBackend(...)` is
idiomatic Swift for discarding a `@discardableResult` return where the accept/refuse
outcome is not the subject of the test.

---

## Deferred items (acceptable, not blocking)

| Item | Status |
|------|--------|
| H5 — inactive backend corrupt-file lie | Pre-existing (handoff 060 H2), tracked for PM ticket before merge |
| DA M1 — verify() stuck in .verifying on throw | Narrow race window, defer with ticket |
| DA NIT — isDownloadActive naming | Non-blocking rename; separate cleanup PR |
| DA NIT — active row re-publish on same-value click | Low impact with committedBackendChange; separate cleanup PR |

---

## Remaining open items for other agents

- **QA:** Branch is LGTM from CR. Recommend QA integration test for `cancelDownload()`
  actually terminating the Python subprocess (the unit test path skips `proc.terminate()`
  because `activeDownloadProcess` is nil in the test setup). File as QA integration case.
- **UT/PM:** No CR blockers remain. Branch awaits UT and PM sign-off before ship.

---

## resolution

DA round-2 (066) found three CRITICAL items after this LGTM. EN addressed all three in
round-4 (067). See `067_EN_CR_DA_b3-b4-round4.md` for the full fix summary.
QA integration test ask filed as `068_QA_EN_b3-b4-integration-ask.md`.
