---
from: CR
to: EN
pri: P1
status: done
created: 2026-04-19
---

## ctx
Full review of branch `fix/b3-b4-download-ui-bugs` covering five commits:
- 9696f46 fix(B3): forward modelManager.objectWillChange into OnboardingViewModel
- 229ccff fix(B4): make isModelDownloaded(for:) respect active download state
- c3ebd27 chore: add handoff 060
- 12577dc fix(B3-B4-DA): address DA blockers
- 1fc6cbd Fix model download process (AudioService threshold + B3B4FixTests)

Files touched: `OnboardingViewModel.swift`, `ModelManager.swift`, `AudioService.swift`,
`SettingsView.swift`, `Murmur/Tests/B3B4FixTests.swift`.

## ask
1. Resolve the AudioService scope issue (described under BLOCKERS below).
2. Address the two medium-severity items.
3. Nits at your discretion.

## constraints
- Do not ship — UT/PM sign-off still pending.
- Deferred items from handoff 060/061 (H2, M2, M3) remain out of scope.

## refs
- `@EN/impl#b3` — `Murmur/Onboarding/OnboardingViewModel.swift`
- `@EN/impl#b4-c1-c2-h3-h1` — `Murmur/Services/ModelManager.swift`, `SettingsView.swift`
- `@EN/impl#audio-vad` — `Murmur/Services/AudioService.swift` (scope issue)
- Tests: `Murmur/Tests/B3B4FixTests.swift`
- Prior: handoff 060, handoff 061

---

## out

**Overall verdict: CHG:3**

The core B3/B4 fixes are correct and well-reasoned. Three items need resolution before
this branch merges: one scope blocker on the AudioService change, one medium correctness
gap in OnboardingView, and one medium risk on the `didSet` recursion contract.

---

### BLOCKERS

#### BLK-1 — AudioService silence threshold bundled into a B3/B4 bug-fix branch
**File:** `Murmur/Services/AudioService.swift:189`
**Commit:** 1fc6cbd ("Fix model download process")

The commit message says "Fix model download process" but the only functional code change is:
```
-        if dbRMS < -60 {
+        if dbRMS < -45 {
```
This is a 15 dB increase to the VAD silence threshold — entirely unrelated to download UI
bugs. Raising the threshold means audio that reads between -60 dB and -45 dB (quiet but
audible speech, soft voices, speech recorded with a distant mic) will now be rejected as
silence and throw `MurmurError.silenceDetected`, silently discarding the recording.

**Risk:** Regression for users with quiet voices or poor mic placement. The old -60 dB
threshold was deliberately permissive to avoid false rejections. -45 dB is a significant
tightening.

**Required action:** One of:
a. Revert the threshold change and file a separate branch + PM-approved issue for the VAD
   tuning, where it can get proper QA coverage (including a test with representative quiet
   speech samples).
b. If this threshold is genuinely needed (e.g. to fix a separate user-reported silent-audio
   transcription bug), document the motivation in the commit message, get PM buy-in, and
   add a regression test before merging here.

The commit message "Fix model download process" gives no hint this change exists, which
makes it even harder to audit in the future.

---

### MEDIUM

#### MED-1 — OnboardingView.backendCard missing `.disabled` during download
**File:** `Murmur/Onboarding/OnboardingView.swift:524-552`

`SettingsView.engineRow` (line 339) received the `isDownloadActive` lock + `.disabled`
modifier as C2. `OnboardingView.backendCard` (line 530-551) calls `viewModel.selectBackend`
on tap but has no corresponding `.disabled` guard. The `didSet` revert on `ModelManager`
is the final line of defence and will silently swallow the tap, but the user gets no
visual affordance that the control is locked.

**Suggested fix:** Mirror the SettingsView pattern:
```swift
let switchLocked: Bool = viewModel.modelManager.isDownloadActive
// ...
.disabled(switchLocked && !isSelected)
```
This is a two-line addition identical to the SettingsView change.

#### MED-2 — `activeBackend.didSet` recursive assignment contract is fragile
**File:** `Murmur/Services/ModelManager.swift:137-148`

The guard `if isDownloadActive { activeBackend = oldValue; return }` works today because:
1. `isDownloadActive` reads `state` (not `activeBackend`), so the recursive assign does not
   re-enter the guard loop.
2. The recursive assign _does_ fire `didSet` a second time. On that second entry,
   `isDownloadActive` is still true (state hasn't changed), so it would recurse again —
   but `oldValue` in the inner call equals the value we just wrote, so the assign is a
   no-op and Swift short-circuits `didSet` for same-value assigns on most published
   properties... except `@Published` does _not_ suppress `didSet` on same-value writes.

This is correct in practice because the inner recursive call has `activeBackend == oldValue`
(i.e. same value we're trying to revert to), and _that_ inner didSet sees `isDownloadActive`
true, tries `activeBackend = oldValue` again (same value), and so on — this is a potential
infinite recursion if Swift doesn't coalesce same-value `didSet` triggers on `@Published`.

In the current Swift/SwiftUI runtime, `@Published` _does_ fire `didSet` regardless of
whether the value changed. However, empirically the revert terminates because the value
written is the same object (enum case) already stored. Verify this holds; if not, add a
guard:
```swift
if isDownloadActive {
    if activeBackend != oldValue { activeBackend = oldValue }
    return
}
```
This is a latent correctness risk rather than an observed bug, but it's worth hardening
before shipping given that `@Published` + `didSet` recursive-write behaviour is not
officially documented to be safe.

---

### NITS

#### NIT-1 — `refreshState()` is `internal` (no access modifier)
**File:** `ModelManager.swift:233`

`refreshState()` is called from tests (`manager.refreshState()`). This is acceptable as a
test seam, but leaving it implicitly `internal` makes it easy for future callers to misuse
it from outside the class. Consider marking it explicitly `internal` with a comment, or
— if you add a test-seam injection point for state (see coverage note below) — restrict
it to `private` again. Low priority, but good hygiene.

#### NIT-2 — Commit message "Fix model download process" (1fc6cbd) does not describe contents
The commit bundles a VAD threshold change and 389 lines of tests. Neither is related to
"model download process". If the threshold stays, the commit message needs to describe
what it actually does. If it's reverted, the commit can be retitled to "test: add B3/B4
fix coverage".

---

### Confirmed correct

The following items from handoffs 060/061 were verified and are sound:

**B3 — Combine forwarding pattern (9696f46 + 12577dc H1)**
- `modelManagerCancellable` is `AnyCancellable?`, stored on the view model. It cancels via
  ARC when the view model deallocates. The `[weak self]` capture prevents a retain cycle
  between the view model and its own `objectWillChange` publisher. Pattern is correct and
  leak-free.
- `.receive(on: DispatchQueue.main)` is sound: it is a hop, not a trampoline. Since
  `ModelManager` is already `@MainActor`, in practice this is a no-op hop, but it is
  correct as a defensive measure against future actor annotation changes.
- `deinit` comment about ARC is accurate and helpful.

**B4 — `isModelDownloaded` positive assertion (229ccff + 12577dc H3)**
- The switch-to-positive-assertion approach is correct. The old code only guarded
  `.downloading`/`.verifying`; the new code returns true only for `.ready && modelPath != nil`.
  This correctly rejects `.corrupt` and `.error` states.
- The belt-and-suspenders `modelPath(for:) != nil` check in the `.ready` branch is
  appropriate given that `refreshState()` could theoretically be stale.
- Both call sites verified: `SettingsView.swift:307` and `OnboardingView.swift:526` go
  through the same method. No missed call sites.

**C1 — `activeBackend.didSet` guard (12577dc)**
- The revert-on-download approach is the right tradeoff vs. cancel-and-switch or queue.
  The rationale in the handoff (no async coordination needed, no silent discard of GBs) is
  sound.
- `cancelDownload()` sets `state = .notDownloaded` before any UI call reaches `activeBackend =`,
  so `isDownloadActive` is already false when cancel completes. The sequencing is correct.

**C2 — SettingsView engine rows disabled (12577dc)**
- `.disabled(switchLocked && !isActive)` correctly locks non-active rows while keeping the
  active row enabled (so the selection remains visible). Pattern matches handoff description.

**B3B4FixTests.swift — Test quality**
- Test seam coverage: the tests correctly cover the states reachable without a real download
  (`.ready`, `.notDownloaded`). The coverage note and reference to a QA handoff for
  `.downloading`/`.verifying`/`.corrupt`/`.error` seam is accurate and well-documented.
  QA should file that handoff as `063_QA_EN_b4-state-seam-request.md` (062 is now taken
  by this CR review).
- `test_subscriptionReleased_whenViewModelDeallocated_noZombieSink` is well-constructed:
  it correctly uses a direct subscription to `modelManager.objectWillChange` (not the
  view model) to verify the model manager continues to fire after the view model is gone.
  The test passing without `EXC_BAD_ACCESS` is the key assertion, which the test documents
  accurately.
- `test_activeBackend_readyState_filesDeleted_returnsFalse` is a good belt-and-suspenders
  test. The setup + tearDown pattern for temp files is correct; `defer` is used in the
  non-active-backend tests for scoped cleanup. Consistent.
- Minor: `test_nonActiveBackend_filesAbsent_returnsFalse` uses an early `return` (test
  skip) if whisper files happen to exist on the machine. This is acceptable but should
  ideally use `try XCTSkip(...)` in XCTest for clearer skip reporting. Nit-level.

---

## resolution (2026-04-19)

All CHG:3 items resolved in commits f8d8cba, ebf010c, 0bbaac5, 9b2bfeb.
Round-2 re-review verdict: **LGTM**.
See handoff `065_CR_EN_b3-b4-round3-review.md` for full findings.
