---
from: EN
to: CR
pri: P1
status: open
created: 2026-04-18
---

## ctx
Two UI bugs diagnosed by PM and assigned to EN. Both are on branch
`fix/b3-b4-download-ui-bugs` (commits 9696f46, 229ccff). Build is clean.
No new tests added per PM instruction; QA will handle coverage.

## ask
1. Review both commits for correctness, safety, and style.
2. Confirm the B3 Combine subscription pattern is sound (weak self, cancellable lifetime).
3. Confirm the B4 state-machine guard covers the right states and has no edge cases.
4. Flag any call sites of `isModelDownloaded` that were missed (there are two; verify).

## constraints
- Do not ship — UT/PM still need to sign off.
- No functional scope changes at CR stage.

## refs
- `@EN/impl#b3` — `Murmur/Onboarding/OnboardingViewModel.swift` (init, modelManagerCancellable)
- `@EN/impl#b4` — `Murmur/Services/ModelManager.swift` (`isModelDownloaded(for:)`)
- Call sites: `SettingsView.swift:307`, `OnboardingView.swift:526`

## out
(Filled by CR)

---

## round-2 EN changes (2026-04-18, DA blocker response)

Addressed DA findings on the same branch. New commits follow c3ebd27.

### C1 — activeBackend.didSet guard (ModelManager.swift)
Added `isDownloadActive: Bool` computed property (true for `.downloading`/`.verifying`).
`activeBackend.didSet` checks it first; if true, reverts to `oldValue` and returns, refusing
the switch. Chose the revert approach (DA option a) over cancel-and-switch or queue because:
- Simplest: no async coordination needed in a synchronous `didSet`.
- Cancel-and-switch would silently discard GBs of partial download without user consent.
- Queue adds deferred-action state that complicates the state machine.
Cancel button in Settings continues to work because `cancelDownload()` sets `state = .notDownloaded`
before any UI calls `activeBackend =`.

### C2 — SettingsView engine row disabled during download
`engineRow(_:)` reads `modelManager.isDownloadActive`; non-active rows get `.disabled(true)`.
Defense-in-depth companion to the didSet guard; also provides visual affordance.

### H3 — isModelDownloaded active-backend logic (ModelManager.swift)
Replaced the partial switch (only guarding .downloading/.verifying) with a positive check:
active backend returns true only when `state == .ready`. All other states — including `.corrupt`
and `.error` — now correctly return false.

### H1 — Main-thread defensive in Combine sink (OnboardingViewModel.swift)
Added `.receive(on: DispatchQueue.main)` before the `.sink`. ModelManager is @MainActor today
but this makes the guarantee explicit and prevents silent regressions if that changes.

### Nits
- `OnboardingViewModel.deinit`: added comment noting AnyCancellable cancels via ARC.
- Handoff 060 line 18: corrected "three" → "two" call sites.

### Deferred (not fixed here — track as follow-up)
- H2: inactive-backend partial/corruption detection — pre-existing, larger scope.
- M2: divergent sources of truth — refactor into single `displayStatus(for:)` computed prop.
- M3: `cancelDownload()` doesn't await subprocess termination.
