---
from: CR
to: EN
pri: P2
status: CHG:2
created: 2026-04-25
refs: 095, 103, 156567c
---

## ctx

Review of `feat(cleanup): v0.3.0 rule-based post-transcription cleanup` (156567c).
PunctuationCleanupService (193 lines), 19 tests, AppCoordinator integration,
SettingsView toggle, MurmurApp wiring. Spec: 095 v3 RDY.

## findings

### P1 — Must fix before merge

**[P1-A] Timeout test does not exercise the real timeout mechanism.**
`PunctuationCleanupTests.swift:385` — `SpyCleanupService.slowSuccess` does
`Task.sleep(seconds: 1.0)`. The coordinator's `withTimeout` helper works via
`withThrowingTaskGroup` — when the timer task wins it throws `MurmurError.timeout`
and `group.cancelAll()` cancels the body task. The spy's `Task.sleep` is
cooperative: it only cancels if the Swift runtime propagates the cancellation
into the sleeping task, which it does. But the test relies on wall-clock time
(250 ms cap + 1 s sleep) and runs on the same executor as the test body.
**Risk:** on a heavily loaded CI machine the test task may not be scheduled
within 250 ms, causing the body to win before the timeout fires, and the test
will assert raw text was returned but `coordinator.lastTranscription` will be
the cleaned text — a false pass, not a fail. The test is not reliable.
**Fix:** have `SpyCleanupService.slowSuccess` instead set a flag and then
await on an `AsyncStream` continuation that is never resumed. That blocks
indefinitely without wall-clock dependency, so the timeout always fires first.
Alternatively use a `CheckedContinuation` that is never resumed and cancelled
by the task group.

**[P1-B] Undo restores the cleaned text, not the raw transcription.**
`AppCoordinator.swift:705-708` — `undoableState` is constructed with
`textToInject` (the cleaned text). The `undoLastInjection()` path in
`InjectionService` replaces the just-injected text in the target application.
Since the injected text is already cleaned, undo correctly reverses what was
typed. That part is fine. The concern is `transcriptionHistory` (line 701):
it also records `textToInject`. If the user has cleanup on, history shows
cleaned text; if they turn it off mid-session, earlier history entries are
cleaned, later are raw — inconsistency across a session toggle. This is a
judgment call, not a crash, but worth a deliberate decision: document the
intent (or always store raw in history + a separate `cleanedText` field). For
v0.3.0 the current behaviour is acceptable; just add an inline comment
acknowledging the choice.

### P2 — Should address

**[P2-A] Quotes in `terminalPunctuation` suppress trailing period in real cases.**
`PunctuationCleanupService.swift:54-59` — closing quote (`"`, `'`, `\u{201D}`,
`\u{2019}`) is in the terminal punctuation set. Input `he said "hello"` ends
in `"` → no period appended. For quoted speech that is arguable; for a
transcription that genuinely ends mid-sentence inside a quote the user gets no
period. This is not a crash and the spec is silent on it, but it is a user-
visible quality gap in common dictation. Recommendation: remove ASCII and
typographic close-quotes from `terminalPunctuation`. If the last word before
the quote is the sentence end, the human-readable result is `He said "hello."` —
period inside the closing quote (American style), which is close enough for a
rule-based pass. At minimum, document the current behaviour in a comment.

**[P2-B] `capitalizeFirst` silently drops multi-scalar lead characters.**
`PunctuationCleanupService.swift:131-135` — `capitalizeFirst` does
`String(firstChar).uppercased()` on the first `Character` (grapheme cluster)
and concatenates with `text[text.index(after: firstIndex)...]`. For an accented
character like `é` this is fine — a `Character` is grapheme-cluster-aware and
`uppercased()` handles it. The real risk is the `capitalizeAfterTerminalPunctuation`
helper (lines 143-169): it builds `Array<Character>` and indexes with `i` / `j`
as integer offsets. `String.uppercased()` can return a *multi-character* string
for some Unicode scalars (e.g., German `ß` → `SS`). Line 162 takes only
`upper.first` and assigns it back to `chars[j]`, silently dropping the second
character. This is unlikely to fire on real ASR output but it is technically
wrong. For v0.3.0 English-only this is acceptable; add a `// FIXME(v0.3.1)`
comment.

**[P2-C] `stopAndTranscribeV1ForTesting` hardcodes `method: .clipboard` for undo.**
`AppCoordinator.swift:766` — real `stopAndTranscribeV1` reads the injection
method from the actual `injection.inject()` result. The test stub always
transitions to `.undoable(method: .clipboard)`. If a test checks injection
method it will silently get the wrong answer. Not a blocker for cleanup tests
(they don't check method), but the divergence widens the gap between the test
path and production.

### P2 — Spec gap (flag for PM/QA)

**[P2-D] Auto-disable counter not implemented.**
Spec 095 scope #6 and 103 scope #5 both require a persisted consecutive-failure
counter and auto-disable after 10 failures + Settings banner. Neither the
counter nor the banner is present. The commit message does not mention deferral.
For a rule-based pass the failure rate is essentially zero, so this will not
bite v0.3.0 in practice, but it is a committed spec item. Either implement or
file a follow-up issue and note the deferral in this handoff.

**[P2-E] Onboarding nudge not implemented.**
Spec 095 scope #7 requires a one-time Settings-pane banner after 10 successful
transcriptions. Not present. Same deferral note as above applies.

### Verified OK — no action needed

- `replaceStandaloneI` boundary check: correct. Left/right checks use
  `isLetter || isNumber` (not just `isLetter`), so `i2c` and `i_var` are both
  correctly skipped. The single-character `"i"` input hits `before == startIndex`
  and `after == endIndex` → both boundaries OK → replaced. Edge case handled.
- `withTimeout` on the calling side: the helper uses `withThrowingTaskGroup`
  with `group.cancelAll()` after the first result. Cancellation propagates
  cooperatively into the sleeping spy task. Mechanically correct.
- `@AppStorage("cleanupTranscription")` in SettingsView matches the
  `"cleanupTranscription"` key in `AppCoordinator.cleanupEnabled`. Bound to
  the same key. Toggle is live.
- `PunctuationCleanupService()` is always allocated in `MurmurApp.init`.
  An actor with no state is a single allocation; no concern.
- `capitalizeAfterTerminalPunctuation` uses `Array<Character>` with integer
  index, which is `Character`-boundary-safe (not raw scalar). Correct for the
  common case; see P2-B for the edge.
- Tests test observable behaviour (output strings), not internal state. No
  implementation-detail leakage.

## out

Status: **CHG:2** — two P1 items require fixes; P2 items are improvements or
follow-up issues. The core rule logic and wiring are sound. Once P1-A (timeout
test reliability) and P1-B (history comment clarifying intent) are addressed
this is shippable for v0.3.0.

Passing to EN. P2-D and P2-E can be filed as issues if not implementing now.
