---
from: EN
to: CR
pri: P1
status: open
created: 2026-04-18
---

## ctx
DA reviewed the B3/B4 fixes (handoff 060) and raised two CRITICAL blockers (C1, C2),
two HIGH items (H3, H1), and nits. This handoff covers the EN response on the same branch
`fix/b3-b4-download-ui-bugs`. New commits follow c3ebd27 (do not rebase/squash).

## changes this round

### C1 — activeBackend switch refused during download (CRITICAL)
`ModelManager.activeBackend.didSet` now checks `isDownloadActive` before proceeding.
If true, it reverts to `oldValue` and returns immediately, refusing the switch.
Added `var isDownloadActive: Bool` as a computed property (`.downloading` or `.verifying` → true).

Rationale for revert approach over cancel-and-switch or queue:
- No async coordination required in a synchronous `didSet`.
- Cancel-and-switch would silently discard partial GBs without user consent.
- Queue introduces deferred-action state that complicates the state machine.
Cancel button in Settings continues to work: `cancelDownload()` sets `state = .notDownloaded`
synchronously before any UI calls `activeBackend =`, so `isDownloadActive` is already false.

### C2 — SettingsView engine rows disabled during download (CRITICAL)
`engineRow(_:)` reads `modelManager.isDownloadActive`; non-active rows get `.disabled(true)`.
Defense-in-depth to C1's didSet guard; also provides visual affordance to the user.
Active (currently selected) backend row stays enabled so the user sees their selection.

### H3 — isModelDownloaded: .corrupt/.error now return false (HIGH)
Replaced the partial switch (only guarding `.downloading`/`.verifying`) with a positive
assertion: the active backend returns true only when `state == .ready && files exist`.
All other states — including `.corrupt` and `.error` — now return false.

### H1 — .receive(on: DispatchQueue.main) in Combine sink (HIGH)
Added `.receive(on: DispatchQueue.main)` before the `.sink` in `OnboardingViewModel.init`.
ModelManager is `@MainActor` today; this is a defensive guarantee so future changes to
the actor annotations don't silently break main-thread safety.

### Nits
- `OnboardingViewModel.deinit`: added comment noting `AnyCancellable` cancels via ARC.
- Handoff 060: corrected "three" → "two" call sites.

## deferred (do not fix in this branch)
- **H2**: inactive-backend partial/corruption detection — pre-existing larger work.
- **M2**: divergent sources of truth — `displayStatus(for:)` computed prop refactor.
- **M3**: `cancelDownload()` doesn't await subprocess termination.

## ask
1. Re-review C1/C2/H3/H1 changes for correctness, safety, and style.
2. Confirm `isDownloadActive` computed property is placed and named well.
3. Confirm the positive-assertion approach in `isModelDownloaded` (state == .ready only)
   is correct for the active backend, and that inactive-backend path is unchanged.
4. If LGTM, pass to UT/PM for final sign-off.

## constraints
- Do not ship — UT/PM still need to sign off.
- Deferred items above must not be in scope for this review.

## refs
- `@EN/impl#c1` — `Murmur/Services/ModelManager.swift` (activeBackend.didSet, isDownloadActive)
- `@EN/impl#c2` — `Murmur/Views/SettingsView.swift` (engineRow, .disabled modifier)
- `@EN/impl#h3` — `Murmur/Services/ModelManager.swift` (isModelDownloaded)
- `@EN/impl#h1` — `Murmur/Onboarding/OnboardingViewModel.swift` (.receive(on:))

## out
(Filled by CR)
