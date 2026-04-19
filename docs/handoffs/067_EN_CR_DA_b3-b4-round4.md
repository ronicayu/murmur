---
from: EN
to: CR, DA
pri: P1
status: RDY
created: 2026-04-19
branch: fix/b3-b4-download-ui-bugs
---

## ctx

Round-4 EN response to DA round-2 challenge (handoff 066, CHG:3).
CR had signed LGTM (065); DA found three CRITICAL findings post-LGTM.
Two commits added to branch on top of the round-3 HEAD (2caccd8).

New HEAD after this round: run `git log --oneline -3` on branch.

Prior: 060, 061, 062, 063, 064, 065, 066.

---

## fixes

### C5 — same-value short-circuit in setActiveBackend (FIXED)

**File:** `Murmur/Services/ModelManager.swift:155-172`
**Commit:** `4009b74 fix(C5): short-circuit setActiveBackend when backend unchanged`

Added `guard backend != activeBackend else { return true }` as the first
check inside `setActiveBackend(_:)`, before the `isDownloadActive` guard.

Calling with the current backend now returns `true` immediately without:
- assigning to `activeBackend` (no spurious `@Published` objectWillChange)
- writing to `UserDefaults`
- emitting `committedBackendChange` (no `MurmurApp.onReceive` → `replaceTranscriptionService`)

Both DA-identified call sites are now safe:
- `OnboardingViewModel.nextStep()` (line ~72): calling `.setActiveBackend(.onnx)` when
  `.onnx` is already active returns immediately.
- `SettingsView` re-click of active engine row: same.

**New tests (3) in `SetActiveBackendGuardTests`:**
- `test_setActiveBackend_sameValue_returnsTrue` — return value is `true`
- `test_setActiveBackend_sameValue_doesNotFireCommittedBackendChange` — called twice,
  zero emissions on `committedBackendChange`
- `test_setActiveBackend_sameValue_doesNotRewriteUserDefaults` — `activeBackend`
  and UserDefaults value unchanged

---

### C6 — SIGKILL escalation after cancelDownload (FIXED)

**File:** `Murmur/Services/ModelManager.swift:448-518`
**Commit:** `7f0409f fix(C6,C7,M3): ...`

`cancelDownload()` now:
1. Sends SIGTERM synchronously (unchanged from H4 fix).
2. Resets state/statusMessage synchronously so the UI unlocks immediately.
3. Launches a `Task.detached` that polls `proc.isRunning` at 100 ms intervals
   for up to 2 seconds. If the process is still alive, escalates to
   `Darwin.kill(pid, SIGKILL)` to guarantee no further file writes.
4. Once the subprocess is confirmed dead, deletes the partial model directory
   (`modelDirectory(for: capturedBackend)`). This is the H5 mitigation: removes
   partial files so `isModelDownloaded(for: backend)` cannot falsely return `true`
   for a cancelled, incomplete download.

`waitForProcessExit(_:timeoutSeconds:)` is a private static async helper that
polls without blocking the main actor.

**Unit test limitation (documented in test file):** `activeDownloadProcess` is `nil`
in the test harness, so the SIGKILL path is not exercised. Unit tests still prove
the synchronous state-reset contract. The real-subprocess path requires a QA
integration test — see handoff 068.

**New test (1) in `CancelDownloadTests`:**
- `test_cancelDownload_clearsStatusMessage` — `statusMessage` is `""` synchronously

---

### C7 — test seam runtime guard (FIXED, option b)

**File:** `Murmur/Services/ModelManager.swift:735-768`
**Commit:** `7f0409f`

Both `__testing_setState` and `__testing_setActiveBackend` now call:

```swift
assert(
    NSClassFromString("XCTestCase") != nil,
    "__testing_setState invoked outside XCTest — ..."
)
```

This makes the safety check structural (crashes the process in Debug builds if
called outside XCTest) rather than convention-based. Release builds are unaffected
(`#if DEBUG` gate still present). LLDB invocation, debug menus, or future
non-test code paths in Debug mode will hit an assertion failure immediately.

Option (b) was chosen over (a) (requires SPM build settings change) and (c)
(extensions cannot add stored-property writers cleanly). One-line enforcement
requiring no build system changes.

---

### M3 — dead downloadTask removed (FIXED)

**File:** `Murmur/Services/ModelManager.swift:184`
**Commit:** `7f0409f`

`private var downloadTask: Task<Void, Never>?` removed. `download()` never
assigned to it, so `downloadTask?.cancel()` in `cancelDownload()` was always
a no-op. The comment in the property declaration explains the removal.

---

### M4 — silent discard of setActiveBackend return (ADDRESSED via discard annotation)

`OnboardingViewModel.swift` callers use `@discardableResult`; the annotation on
`setActiveBackend` covers the intent. No UI propagation of `false` is added
(onboarding runs before any download is active, so `false` is unreachable in
practice). Both call sites at lines 72 and 88 are left as-is; the compiler
silences the unused-result warning via the attribute.

This is acceptable scope: wiring a UI error state for an unreachable path is out
of scope for this branch. Documenting as a future hardening item.

---

### H8 / H5 mitigation — partial-file cleanup on cancel (ADDRESSED)

H5 is not fully resolved (inactive-backend file-existence path still uses
`modelPath(for:) != nil`), but the partial-file scenario is now mitigated:
`cancelDownload()` deletes the model directory after the subprocess is confirmed
dead, so subsequent calls to `isModelDownloaded(for: cancelledBackend)` return
`false` as expected. Full H5 fix (hash/size manifest or `.cancelled` marker
across all paths) is deferred to a PM-scoped item.

---

### H7 / H8 deferred — QA integration test ask filed

See `068_QA_EN_b3-b4-integration-ask.md`.

---

## test counts

| Suite | Tests |
|---|---|
| SetActiveBackendGuardTests | 10 (+3 from C5) |
| CancelDownloadTests | 4 (+1 from C6) |
| IsModelDownloadedActiveBackendTests | 6 (unchanged) |
| OnboardingViewModelRepublishTests | 3 (unchanged) |
| All suites | 272 total, 0 failures, 21 skipped |

Full suite run: `swift test` → 272 tests, 0 failures.

---

## deferred items

| Item | Status | Note |
|---|---|---|
| H5 full fix — hash/size manifest | DEFER | Mitigation in place (delete on cancel). Full fix requires PM scope. |
| H7 — real-download integration test | DEFER to QA | Filed as 068. |
| H8 — inactive-backend state tracking refactor | DEFER | Broader than this branch. PM ticket needed. |
| M4 — propagate setActiveBackend false to UI | DEFER | Unreachable path in current onboarding; future hardening. |
| M5 — refreshState sets .ready on partial files | DEFER | Same root as H5; covered by H5 ticket. |
| NIT — committedBackendChange as AnyPublisher | DEFER | Separate cleanup PR. |

---

## asks

- **CR:** Re-review the two new commits for the three CRITICAL fixes. Focus on
  `cancelDownload()` async cleanup path and test seam assertion.
- **DA:** Re-examine C5/C6/C7 — are the fixes structurally sufficient?
- **QA:** Pick up `068_QA_EN_b3-b4-integration-ask.md` for the subprocess
  integration test.
