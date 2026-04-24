---
from: EN
to: CR
pri: P1
status: RDY
created: 2026-04-25
branch: feat/lid-whisper-tiny
refs: 098, 099, a914e7f
---

## ctx

Round-2 fixes applied on top of d77a594. Addresses all in-scope items from CR
handoff 098 and UT handoff 099.

---

## changes (commit a914e7f)

### P0 — UT #3 / CR NC-2: Badge visibility during transcribing

- `FloatingPillView`: added `isLanguageBadgeVisible` computed var (true for
  `.recording`, `.streaming`, `.transcribing`). Badge guard in `body` now uses
  `isLanguageBadgeVisible` instead of `isRecordingState`. Cancel button guard
  unchanged (still `isRecordingState`).
- `FloatingPillView`: extracted `PillControlling` protocol with `show(state:audioLevel:languageBadge:onCancel:)` and `hide(after:)`. Default-parameter convenience overloads moved to protocol extension. `FloatingPillController` conforms; its concrete methods now have no default params. `AppCoordinator.pill` typed as `any PillControlling`.
- `AppCoordinator`: `activeBadge` changed from `private` to `internal(set)` with comment explaining why (spy alternative to stopAndTranscribeV1 path).
- Tests added: `test_isLanguageBadgeVisible_trueForRecordingStreamingAndTranscribing`, `test_isLanguageBadgeVisible_falseForNonActiveStates` (in `LanguageBadgeTests`).
- Badge test renamed from `test_badgeUpdate_whenLIDOverridesIME_resolvedLanguageAndBadgeMatch` to `test_resolvedLanguage_isLIDCode_whenConfidenceAboveThreshold`. False-close static assertion removed. Comment explains stopAndTranscribeV1 pill-update path requires live audio; accepted as integration-only gap per CR NC-2 fallback option (b).

### P0 — UT #5a: Silent UserDefault flip notification

- `AppCoordinator.notifyLIDModelDetached()`: new method, posts `.error(.transcriptionFailed("Auto-detect disabled — language model was removed"))` pill, hides after 4 s. Comment explains it only fires on real transition (lid was non-nil), not initial subscription.
- `MurmurApp`: `!lidReady` branch now calls `coordinator.notifyLIDModelDetached()` after setting `autoDetectLanguage = false`.
- Test added: `test_notifyLIDModelDetached_showsPillWithDisabledMessage` — uses `SpyPillController` injected via `AppCoordinator(pill:)`. Asserts show called once, hide called once, state is `.error` with message mentioning language/auto-detect.

### P1 — UT #6: V3 streaming caption

- `SettingsView`: below the auto-detect toggle label, conditionally shows `.caption` grey text "Streaming voice input uses the active input source — audio detection runs on full-pass transcription only." when `streamingInputEnabled` is true.

### P1 — CR NC-1: convertError comment

- `LanguageIdentificationService.loadProbeSamples`: one-line comment above the `convertError` check documents AVAudioConverter's write-on-error-only contract.

---

## test summary

- 4 new tests; 345 total, 0 failures, 21 skipped (skips pre-existing, infra-gated).
- `swift build` clean (warnings are pre-existing).

---

## P2 items — skipped

- UT #1 (auto-enable banner on download): deferred. Requires `SettingsView` to
  observe `$auxiliaryStates` changes and show inline banner on `.ready`
  transition. Straightforward but adds ~20 lines of state + view code; nothing
  in the P0/P1 set depends on it.
- UT #2 (diskFull / download error surfacing): deferred. The `try?` patterns in
  `SettingsView` downloadAuxiliary call require adding `@State` error binding
  and UI rendering. Safe standalone change but low-risk for shipping behind the
  P0/P1 fixes.

Both P2s are suitable for a 0.2.5 polish pass.

---

## out

RDY for CR round-3 and re-UAT. The two P0s are fixed and tested. P1s applied.
