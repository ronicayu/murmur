---
from: EN
to: CR, QA
pri: P1
status: RDY
created: 2026-04-20
---

## ctx

Round 2 fixes for `feat/language-badge-on-pill`. Addresses all blocking and should-fix items from CR #087 and QA #088. Branch unchanged; one new commit on top of `3907343`.

---

## items addressed

### CR #1 (blocking) — V3 streaming first-frame badge

Moved `resolveTranscriptionLanguage()` and `activeBadge` assignment to before the first `pill.show` in `startStreamingRecordingFlow`, exactly mirroring the V1 flow. The duplicate resolution block and the second "badge-bearing refresh" `pill.show` after `startRecording()` are removed. The resolved `lang` value is reused downstream in `beginSession()` — no double resolution.

### CR #2 (blocking) — `"transcriptionLanguage"` key deduplication

Extracted `private static let transcriptionLanguageKey = "transcriptionLanguage"` on `AppCoordinator`. All three former literal call sites — V1 flow, V3 flow, and `resolveTranscriptionLanguage()` — now reference `Self.transcriptionLanguageKey`.

### CR #3 (should-fix) — `var` → `let` on `FloatingPillView.languageBadge`

Changed to `let languageBadge: String?`. Added an explicit `init(state:audioLevel:languageBadge:)` with `languageBadge` defaulting to `nil`. This is required because Swift excludes `let` stored properties with default values from the synthesized memberwise initializer — the explicit init preserves all existing call sites without change.

### CR #4 (nit) — MARK comment

Renamed `// MARK: - BadgeView` to `// MARK: - LanguageBadgeView` in `LanguageBadge.swift`. 30-second fix, done.

### QA #1 (blocking) — `isRecordingState` guard untested

Made `isRecordingState` `internal` (removed `private` modifier) on `FloatingPillView`. Added two unit tests to `LanguageBadgeTests.swift`:
- `test_isRecordingState_trueForRecordingAndStreaming` — asserts `true` for `.recording` and `.streaming(chunkCount:)`.
- `test_isRecordingState_falseForAllNonRecordingStates` — iterates all 5 non-recording states (`.idle`, `.transcribing`, `.injecting`, `.undoable`, `.error`) and asserts `false` for each.

---

## deferred

### QA #2 — V3 streaming badge-before-audio-task integration test

Deferred. An `AppCoordinator` integration test verifying `activeBadge` is non-nil before audio-level tasks fire requires a stub `StreamingTranscriptionCoordinator`. The stub infrastructure is not available in this session. The architectural fix (CR #1) eliminates the race window; the integration test is a follow-up hardening item.

---

## test results

11 `LanguageBadgeTests` pass (9 original + 2 new `isRecordingState` tests). All pre-existing passing tests remain green. Pre-existing failures (`StreamingPipelineIntegrationTests`, `V3AXSelectReplaceTests` XCTExpectFailure) are unrelated to this feature.

---

## files changed (round 2)

- `Murmur/AppCoordinator.swift` — extracted `transcriptionLanguageKey` constant; reordered V3 badge resolution before first `pill.show`; removed duplicate resolution block
- `Murmur/Views/FloatingPillView.swift` — `var` → `let` on `languageBadge`; added explicit init; `isRecordingState` made internal
- `Murmur/Views/LanguageBadge.swift` — MARK comment rename
- `Murmur/Tests/LanguageBadgeTests.swift` — 2 new `isRecordingState` tests
- `docs/handoffs/085_PM_EN_language-badge-spec.md` — round 2 changes recorded in `## out`
