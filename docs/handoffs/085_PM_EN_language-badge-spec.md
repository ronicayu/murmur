---
from: PM
to: EN
pri: P1
status: open
created: 2026-04-20
---

## ctx

Users can't tell at a glance which language Murmur will transcribe in. The language is either fixed in Settings or auto-resolved from the active macOS keyboard input source — both are invisible at the moment of recording. Result: occasional surprises when the wrong language gets selected, and no fast way to confirm before speaking.

Fix: a small, persistent language badge in the top-right of the floating recording pill. Two-letter ISO code, with a trailing middle dot when the value came from auto-resolution.

This is a focused UI addition with no new state — read-through of values that already exist.

## ask

1. Add a small badge to the top-right corner of the recording pill HUD showing the active transcription language.
2. Format:
   - Fixed language → uppercase 2-letter ISO code, no suffix. Examples: `EN`, `ZH`, `JA`.
   - Auto-resolved → same code with a trailing middle dot (`·`, U+00B7). Examples: `EN·`, `ZH·`.
3. Show the badge for the full duration of the recording state (V1 push-to-talk and V3 streaming). Hide in success / error / dismissed pill states.
4. Source the value from the same resolution path used to start the recording — do not duplicate the auto-resolution logic. Pass it into the pill view alongside the existing recording state.
5. Supported codes (matches Cohere's set): `EN, ZH, JA, KO, FR, DE, ES, PT, IT, NL, PL, EL, AR, VI`. If a code falls outside this set for any reason, render `??` (with the dot suffix preserved if auto). Do not crash, do not hide the badge.

### Success criteria (verifiable by running the app)

- Set Settings > language to `English`. Start recording. Badge reads `EN`.
- Set Settings > language to `Chinese (Simplified)`. Start recording. Badge reads `ZH`.
- Set Settings > language to `Auto`. Switch macOS input source to U.S. English. Start recording. Badge reads `EN·`.
- Set Settings > language to `Auto`. Switch macOS input source to Pinyin. Start recording. Badge reads `ZH·`.
- Stop recording. Badge disappears in the success/error pill states.
- Repeat with V3 streaming enabled. Same behavior.

## constraints

- **Visual:** ~10pt font, semibold, secondary/low-contrast color. Must not visually compete with the audio level meter. Readable at a glance, not loud.
- **Placement:** top-right of the pill, static (no animation, no layout shift on the rest of the pill).
- **No new persistent state.** No new UserDefaults keys, no new settings UI.
- **No re-resolution at render time.** The view receives the resolved code; resolution stays in `AppCoordinator`.
- **Don't refactor the language resolution path.** If the current call sites at `AppCoordinator.swift:352` (V1) and `:430` (V3 streaming) both call `resolveTranscriptionLanguage()`, capture the resolved value at those call sites and propagate it to the pill controller.
- **Auto-mode detection** = the user's stored `transcriptionLanguage` UserDefault equals `"auto"`. Do not infer it from anything else.
- Keep diff small. This is one view addition + one value propagated through the pill controller.

## refs

- Pill view: `Murmur/Views/FloatingPillView.swift`
- Pill controller: `Murmur/FloatingPillController.swift` (recording state lives at lines 111-185)
- Language resolution: `Murmur/AppCoordinator.swift:839-863` (`resolveTranscriptionLanguage()`)
- Recording entry points to read the resolved code from: `AppCoordinator.swift:352` (V1), `AppCoordinator.swift:430` (V3 streaming)
- UserDefaults key: `transcriptionLanguage`, default `"auto"` — see `SettingsView.swift:11`, `MenuBarView.swift:6`
- Cohere language list (source of truth for the 14 codes): `Murmur/Services/ONNXTranscriptionBackend.swift:31-36`

## out

**Branch:** `feat/language-badge-on-pill`
**Commit:** `3907343`

**Files changed:**
- `Murmur/Views/LanguageBadge.swift` (new, lines 1–44): `LanguageBadge` enum with `format(code:isAuto:)` and `badgeText(resolvedCode:storedSetting:)`, plus `LanguageBadgeView` SwiftUI view.
- `Murmur/Views/FloatingPillView.swift` (lines 3–35, 127): Added `languageBadge: String?` param to `FloatingPillView`; wrapped body in `ZStack(.topTrailing)` to overlay the badge. Added `isRecordingState` guard so badge only renders in `.recording`/`.streaming`. Updated `FloatingPillController.show()` signature to accept and forward `languageBadge`.
- `Murmur/AppCoordinator.swift` (lines 122, 363–376, 406–435): Added `activeBadge: String?` property; resolve + store badge at both recording entry points (V1 `startV1RecordingFlow`, V3 `startStreamingRecordingFlow`); thread badge through all `pill.show(state: .recording/streaming, ...)` calls including audio-level task closures.
- `Murmur/Tests/LanguageBadgeTests.swift` (new, lines 1–62): 9 unit tests covering fixed/auto/unknown/all-14-supported-codes cases for `format` and `badgeText`.

**Test results:** 315 tests run, 2 expected failures (pre-existing `XCTExpectFailure` for AX spike), 0 unexpected failures, 0 regressions. 9 new tests all green.

**Success criteria — not verifiable without GUI:**
All 6 criteria require running the macOS app with an active microphone and switching input sources. This is not possible in a CLI agent session. Criteria are:
1. Fixed EN → badge reads `EN`
2. Fixed ZH → badge reads `ZH`
3. Auto + US English input → badge reads `EN·`
4. Auto + Pinyin input → badge reads `ZH·`
5. Stop recording → badge absent in success/error states
6. V3 streaming enabled → same behavior

**Decisions not pre-decided in spec:**
- `activeBadge` is stored as an instance property on `AppCoordinator` so the audio-level task closures (which run asynchronously after `startV1RecordingFlow` returns) can reference the resolved value. No new UserDefaults key; cleared implicitly on next recording start.
- In `startStreamingRecordingFlow`, the initial `pill.show` before `resolveTranscriptionLanguage()` runs (before the recording start timeout) shows no badge; the badge-bearing refresh fires immediately after resolution. This is correct — the language isn't known until that point in the streaming flow.

**Round 2 changes (2026-04-20, after CR #087 + QA #088):**
- CR #1 (blocking): Moved `resolveTranscriptionLanguage()` and `activeBadge` assignment before the first `pill.show` in `startStreamingRecordingFlow` — mirrors V1 flow. Removed the now-redundant second `pill.show` and duplicate resolution block. `lang` is reused for `beginSession`.
- CR #2 (blocking): Extracted `private static let transcriptionLanguageKey = "transcriptionLanguage"` on `AppCoordinator`. All three call sites (V1 flow, V3 flow, `resolveTranscriptionLanguage()`) now use `Self.transcriptionLanguageKey`.
- CR #3 (should-fix): Changed `var languageBadge: String? = nil` to `let languageBadge: String?` on `FloatingPillView`. Added explicit memberwise-style `init(state:audioLevel:languageBadge:)` with default `nil` to preserve call-site compatibility (Swift excludes `let` properties with defaults from the synthesized memberwise init).
- CR #4 (nit): Renamed `// MARK: - BadgeView` to `// MARK: - LanguageBadgeView` in `LanguageBadge.swift`.
- QA #1 (blocking): Made `isRecordingState` `internal` (removed `private`). Added 2 new unit tests in `LanguageBadgeTests.swift`: `test_isRecordingState_trueForRecordingAndStreaming` and `test_isRecordingState_falseForAllNonRecordingStates` (covers all 5 non-recording states).
- QA #2 (follow-up): V3 streaming timing integration test deferred — AppCoordinator stub infrastructure not available in this session. Noted in handoff 089.

**Test results (round 2):** 11 LanguageBadgeTests pass (9 original + 2 new). All other tests unchanged.
