---
from: EN
to: CR, QA
pri: P1
status: open
created: 2026-04-20
---

## ctx

Language badge feature is implemented on `feat/language-badge-on-pill` (commit `3907343`). Spec is at `docs/handoffs/085_PM_EN_language-badge-spec.md`. This handoff requests parallel review from CR (code quality) and QA (test coverage).

## ask

**CR:**
1. Review the diff on `feat/language-badge-on-pill` against `main`. Focus areas:
   - `LanguageBadge.swift`: correctness of the formatter enum, view separation, naming.
   - `FloatingPillView.swift`: ZStack overlay placement, `isRecordingState` guard logic, backward-compat of the optional `languageBadge` param.
   - `AppCoordinator.swift`: `activeBadge` lifetime — does storing it as an instance property carry any concurrency risk? Is the V3 streaming flow correct (badge set after `resolveTranscriptionLanguage()`, before audio-level tasks can fire)?
   - No regressions in existing tests or observable behavior.

**QA:**
1. Review `Murmur/Tests/LanguageBadgeTests.swift` (9 tests). Are edge cases adequately covered?
2. Identify any gaps — particularly around the propagation path (AppCoordinator → pill.show → FloatingPillView render). The badge logic itself is unit-tested; the view integration is not (requires UI test or manual verification).
3. The 6 app-level success criteria in the spec (`085`) require manual testing with the running app. Confirm whether any of these can be covered by automated tests, or flag as requiring manual UAT.
4. If coverage gaps exist, write the missing tests or list them as a follow-up for UT.

## constraints

- Do not change implementation on this branch — flag CHG items back to EN if fixes are needed.
- Do not merge. Branch stays open until both CR and QA sign off.
- Keep diff small — the spec forbids refactors of `resolveTranscriptionLanguage()`.

## refs

- Spec: `docs/handoffs/085_PM_EN_language-badge-spec.md`
- Branch: `feat/language-badge-on-pill` (commit `3907343`)
- New files: `Murmur/Views/LanguageBadge.swift`, `Murmur/Tests/LanguageBadgeTests.swift`
- Modified files: `Murmur/Views/FloatingPillView.swift` (lines 3–35, 127), `Murmur/AppCoordinator.swift` (lines 122, 363–376, 406–435)

## out

(CR and QA to fill independently)
