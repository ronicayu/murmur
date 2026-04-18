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
4. Flag any call sites of `isModelDownloaded` that were missed (there are three; verify).

## constraints
- Do not ship — UT/PM still need to sign off.
- No functional scope changes at CR stage.

## refs
- `@EN/impl#b3` — `Murmur/Onboarding/OnboardingViewModel.swift` (init, modelManagerCancellable)
- `@EN/impl#b4` — `Murmur/Services/ModelManager.swift` (`isModelDownloaded(for:)`)
- Call sites: `SettingsView.swift:307`, `OnboardingView.swift:526`

## out
(Filled by CR)
