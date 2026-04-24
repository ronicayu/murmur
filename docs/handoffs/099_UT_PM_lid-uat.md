---
from: UT
to: PM
pri: P1
status: CHG:4
created: 2026-04-25
---

## ctx

UAT of the Whisper-tiny audio LID feature on `feat/lid-whisper-tiny`. I cannot build or download the 40 MB model today, so this is a code-walk UAT plus a manual plan a human tester can run against a live build. Files covered: `Murmur/Views/SettingsView.swift` (General + Model tabs), `Murmur/Views/FloatingPillView.swift`, `Murmur/AppCoordinator.swift` (`resolveTranscriptionLanguageAsync`, V1/V3 start + stop flows), `Murmur/MurmurApp.swift` (attach/detach of `coordinator.lid`), `Murmur/MurmurError.swift`, `CHANGELOG.md`. Target user is a bilingual EN/ZH professional who speaks Mandarin into English-IME apps — the exact failure mode the pre-LID `EN·` badge exposed in v0.2.3.

## findings

### 1. First-time discovery — P1

**User perspective.** Opening Settings > General, I see a toggle called "Auto-detect language from audio" with caption "Uses a separate small model (~40 MB). Overrides manual selection when confident." That's OK — I know it costs 40 MB and that it will override my Picker. But the toggle is greyed out with no visible reason, and the label still reads "Auto-detect language from audio" even while it's disabled. I have to guess that the greying is download-related. The download button itself lives in a completely different tab (Model > "Language Detection" section), which I only find by clicking around. There is no "Download now to enable" inline button or link from the greyed toggle, no indicator arrow, nothing. A user who opens General first will probably conclude the toggle is broken or reserved for some other state.

Also: the `onChange` handler actually *does* kick off a download if the toggle somehow flips on when the model isn't there — but because `.disabled(!isAuxiliaryDownloaded)` blocks interaction, that code path is effectively dead. I'd expect one consistent pattern, not both.

**Proposed UX fix.** Inline the download affordance with the toggle. Two options, pick one:
(a) Keep toggle disabled, but add a caption row beneath it: "Download the 40 MB language model" as a tappable Button, on the General tab. On completion the toggle auto-enables and flips to on.
(b) Let the toggle always be tappable; flipping it on opens a mini-sheet/alert "This will download ~40 MB. Continue?" → then downloads and enables. Remove the separate Model-tab section or make it the "manage / delete" row only.

### 2. Download flow — P1

**User perspective.** I go to Model tab > Language Detection > click "Download". I see an indeterminate `ProgressView().progressViewStyle(.linear)` — no percentage. The caption says "Downloading: 12 MB" and shows a speed. No ETA. No cancel button (the primary model has "Cancel Download"; the aux one doesn't). For a 40 MB file on a good network this is fine; on a hotel Wi-Fi it's going to feel stuck.

If I'm offline: `snapshot_download` throws, we land in the JSON-error branch and surface "Error: <stderr snippet>" in red. Actionable for a developer; for a normal user the stderr leak is noise. If the disk is full we throw `MurmurError.diskFull` — the aux row shows nothing useful, because the row only renders `.error(msg)` state, and `diskFull` is thrown from `downloadAuxiliary` via `try?` at the call site in SettingsView, so the error is swallowed and the user sees the "Download" button come back with no explanation.

When the download *finishes*, the auxiliary state flips to `.ready`, `MurmurApp`'s `onReceive($auxiliaryStates)` attaches the LID service — good. But the General-tab toggle does **not** auto-flip on. The user is expected to know to switch tabs and turn it on. They just paid 40 MB for a feature and the feature is still off.

**Proposed UX fix.**
- Add a Cancel button mirroring the primary model's affordance; 40 MB is small but flaky networks exist.
- Catch `diskFull` at the SettingsView call site and show an NSAlert ("Need ~100 MB free to install language detection"). `try?` is hiding a user-critical error.
- On successful download, flip `autoDetectLanguage = true` automatically (the user clicked Download with intent). At minimum, show a post-download banner "Language Detection is ready. Turn it on in General." with a one-click link.
- Sanitize the error string — strip the Python traceback snippet before putting it in the UI.

### 3. Happy-path use (EN IME, speaking ZH) — P1

**User perspective.** Pill appears with `EN·` badge (dot = IME-derived, v0.2.3 behavior). I speak Mandarin. I release the hotkey. Pill goes to "Transcribing…" — and **the badge disappears entirely**, because `FloatingPillView.body` only shows `languageBadge` when `isRecordingState` is true (recording/streaming). Then LID runs, `stopAndTranscribeV1` updates `activeBadge` to `ZH·` and calls `pill.show(state: .transcribing, languageBadge: activeBadge)` — but that update is invisible for the same reason: the transcribing state doesn't render the badge. So the *entire override signal is invisible* to the user. The only way they learn LID worked is seeing Chinese characters appear in their editor.

That's a missed trust-building moment. The whole promise of the feature is "we detected you were speaking Chinese and fixed it for you." The user deserves to see `EN· → ZH` happen.

**Proposed UX fix.** Render the language badge during `.transcribing` as well (drop the `isRecordingState` guard for the badge, keep it for the cancel button). Even better, briefly animate the change (crossfade, 300 ms) when `activeBadge` differs from the pre-recording value. This is the single change that will make the feature *feel* intelligent instead of magical-invisible.

Secondary concern: the badge dot semantics get fuzzy once LID is in the mix. Today the dot means "came from IME, not manual pick." With LID it could mean "overridden by audio." Consider a different glyph (e.g. a small `~` suffix or a speaker icon) for the LID-detected case so the user can distinguish IME-guess from audio-detected.

### 4. Low-confidence path — P2

**User perspective.** I grunt for half a second. LID returns a low-confidence result; `resolveTranscriptionLanguageAsync` falls through to the IME fallback silently (just a `.info` log line). No pill change, no badge change. User doesn't know LID "considered it and abstained." That's fine — quiet fallback is the right call here, since the fallback is the v0.2.3 behavior they had before. Low severity.

One thing worth noting: if the audio is silent, the inner `catch MurmurError.silenceDetected` also falls through quietly. But the *outer* transcription will usually surface its own `silenceDetected` shortly after — so the pill does show "Didn't catch that" for the usual reason. Consistent enough.

**Proposed UX fix.** None required. Optionally, in a verbose/debug mode, show the confidence score in a tooltip on the badge — useful for debugging user reports but not shipping UX.

### 5. Failure modes — P0 (for 5a), P1 (for 5b–d)

**5a. User deletes the aux model after enabling LID.** This is the worst one. `MurmurApp` subscribes to `$auxiliaryStates` and, on transition to not-ready, sets `coordinator.lid = nil` AND forcibly sets `autoDetectLanguage = false` in UserDefaults. That is a silent product decision being taken away from the user without notification. If I deleted the model by accident (or a future feature nukes the cache), my auto-detect preference is gone and I have to re-enable it. The reasoning in the code comment is sound ("so we don't fire the 'Language model not installed' pill on every transcription"), but the cure is worse than the disease — because now the user has no idea anything changed. **P0**: any setting we flip on behalf of the user must be announced.

**5b. Offline during download.** See finding 2 — raw stderr in the red caption is ugly and unactionable.

**5c. Mac sleeps mid-download.** The `snapshot_download` subprocess will probably survive short sleeps but may stall. There's no stall timeout on the aux download (the primary model has the 90 s FU-07 stall timer; the aux path does not). On long sleeps the user returns to a frozen progress view forever.

**5d. LID inference throws.** `resolveTranscriptionLanguageAsync`'s catch-all shows a pill `.error(.transcriptionFailed("Language detection unavailable"))` that auto-hides. The actual transcription still proceeds with the fallback language. Sequence for the user is: they release hotkey → pill flashes an orange warning briefly → pill changes to "Transcribing…" → text lands in editor. That's confusing ("did it fail or not?"). It succeeded; the warning made them think it didn't.

**Proposed UX fix.**
- 5a: when auto-disabling `autoDetectLanguage`, post a menu-bar notification or pill toast "Language Detection turned off — model was removed." Don't silently flip user settings.
- 5b: sanitize error text, add a "Retry" button that calls `downloadAuxiliary` again.
- 5c: apply the same 90 s stall timer to the aux download.
- 5d: don't show a pill error if we successfully fell back and will proceed. Log-only is fine here. Alternatively, briefly show the badge change with a subtle warning color.

### 6. V3 streaming user — P1

**User perspective.** If streaming is enabled AND autoDetectLanguage is enabled AND the LID model is downloaded, streaming mode (`startStreamingRecordingFlow`, line 427) calls `resolveTranscriptionLanguage()` (sync, no LID) and never consults LID. The async version is called only from `stopAndTranscribeV1` and `transcribeLong`. The user sees zero indication this is happening. They paid 40 MB, enabled the toggle, and in streaming mode it just… doesn't apply. The toggle label says nothing about "V1 only" or "non-streaming."

**Proposed UX fix.** Either (a) greyed-out "(not used with Streaming input)" sub-caption under the toggle when streaming is also on, or (b) decide the product story — maybe LID is a V1-only feature by design (for latency reasons, per the code comment) and the UI should say that. The current state is the worst of both worlds: feature advertised, feature silently skipped.

### 7. Uninstall / disable flow — P2

**User perspective.** Disable is easy — toggle off in General. But deleting the 40 MB model requires navigating to Model > Language Detection > Delete button. Two-tab trip. The auto-detach logic in `MurmurApp` then also flips the toggle off, which (see 5a) is silent. If the user just wants to reclaim disk without losing the setting, there's no "keep disabled but keep model" state distinction; delete = toggle off forever.

**Proposed UX fix.** Co-locate a small "Remove model (40 MB)" link under the toggle on the General tab so users can uninstall from one place. Keep the full Model-tab row too for power users. And again — when auto-flipping the toggle, tell the user.

### 8. CHANGELOG language — P2

> Audio-based language identification (LID) as an opt-in auxiliary model. When enabled, the app runs a locally-installed Whisper-tiny ONNX encoder + one decoder step on the first 5 s of the recording to pick a language before handing audio to Cohere. Falls through to the existing IME-based resolver on any failure or low-confidence result. Streaming V3 deliberately skips LID to avoid pre-roll latency. Opt-in via a new Settings section that downloads the ~40 MB auxiliary model on demand.

Mostly honest. Two nits. First, "Whisper-tiny ONNX encoder + one decoder step" is engineer-speak for a user-facing CHANGELOG — "uses a small on-device model" is enough. Second, "Streaming V3 deliberately skips LID" is a footnote buried in a feature blurb; for a user who has both streaming and LID enabled, this is a real limitation, not a footnote. Promote it to its own line: "Note: Language detection does not apply when 'Streaming input' (Beta) is enabled."

## manual test plan

For a human tester running a built `.app` with internet access, a working mic, an English system IME, and the ability to install/remove a Chinese (Pinyin) input source.

1. **Fresh-state discovery.** Launch built app, open Settings > General. Confirm "Auto-detect language from audio" toggle is present, disabled, and has a caption mentioning ~40 MB. Note whether there is any link/button to start the download from this tab. **Expected pain:** none visible.
2. **Cross-tab discovery.** Switch to Model tab. Confirm "Language Detection" section is present with a "Download" button, displayName "Language Detection Model", and "~40 MB" size caption.
3. **Download happy path.** Click "Download". Observe progress UI — confirm linear indeterminate bar, MB counter updating, speed caption. Time it. On completion confirm green "Downloaded" text, Delete button appears.
4. **Auto-enable check.** Switch back to General. Confirm whether `Auto-detect language from audio` auto-flipped to on (expected: no, user must toggle manually). Note the friction.
5. **Offline download.** Turn Wi-Fi off. Delete the aux model. Click Download. Observe error caption. Confirm it's in red, does not include raw Python traceback. Click Download again after Wi-Fi returns — confirm it recovers cleanly.
6. **Disk-full simulation.** (Harder — use Disk Utility to create a tiny APFS volume and point `~/Library/Application Support/Murmur` at it via a symlink; or stub `.systemFreeSize`.) Click Download. Confirm user-facing error, not a silent re-appearance of the Download button.
7. **Happy path ZH-in-EN.** With EN IME active, enable Auto-detect (model already downloaded). Open a text field. Hit right-cmd, say a Mandarin phrase ("你好，今天天气很好"), release. Observe: (a) pill shows `EN·` during record, (b) does the badge change visible during Transcribing?, (c) text arrives as Chinese characters. Rate the trust signal 1–5 from the badge transition alone.
8. **Happy path EN-in-ZH.** Switch active IME to Pinyin. Start recording. Say an English sentence. Observe `ZH·` → EN override behavior, same three check points as above.
9. **Low-confidence grunt.** Record a 300 ms "uh". Release. Confirm behavior is "Didn't catch that" or empty — no jarring wrong-language output, no pill error about LID.
10. **Fall-back on LID crash.** Corrupt the decoder file (truncate `onnx/decoder_model_quantized.onnx` to 1 KB). Record something. Confirm: pill briefly flashes "Language detection unavailable", then transcription proceeds using the fallback language, text is inserted. Confirm the error flash does not look like the whole transcription failed.
11. **Model deletion by user.** With autoDetect enabled, go to Model tab, click Delete on the Language Detection row. Return to General. Confirm the toggle is now off. Confirm some user-visible signal was given (expected: none — see finding 5a). Try to re-enable the toggle without re-downloading — confirm it stays disabled.
12. **Sleep mid-download.** Start download. Close the laptop lid for 3 minutes. Reopen. Confirm download either resumes and completes, or fails with a clear error. No indefinite frozen progress.
13. **V3 streaming + LID.** Turn on "Streaming input" in Experimental. Keep auto-detect on, model downloaded. Record with mismatched IME/spoken language. Confirm LID does *not* kick in (fallback pill badge stays, text comes out in fallback language = wrong for this user). Confirm nothing in the UI tells them why.
14. **Uninstall path round-trip.** Delete model. Re-enable auto-detect — confirm what happens (expected: click triggers a re-download per the `onChange` handler path in `SettingsView` line 127–131). Confirm new download completes, LID works.
15. **CHANGELOG cross-read.** Read the 0.2.4 entry cold, without context. Would a user understand: (i) that this is opt-in, (ii) that they'll pay 40 MB, (iii) that it doesn't work with streaming? If any of the three is unclear, flag.

## ship readiness

**Would I ship this to the public as a user? No — not yet.**

The core feature works (the code path is sound, the threshold is reasonable, the fallback is quiet). But three things would keep me personally frustrated as the target user:

1. **Silent setting-flip** when the model is deleted (finding 5a). That's a trust-breaker. If I uninstall something and my settings change without notice, I stop trusting the app with any settings.
2. **Invisible override** — the badge disappears during Transcribing so the whole "we detected Chinese, we fixed it" moment is hidden (finding 3). For a feature whose entire reason for existing is *to fix* the EN-IME/ZH-speech case, not showing the fix means the user won't know it's working, and will uninstall the 40 MB next time they clean up disk.
3. **Streaming silently skips LID** (finding 6). The settings screen doesn't warn you. If I'm a streaming user I'll think the feature is broken, not "not applicable."

**The smallest thing that would move me to yes:** fix #2 first — render the badge during transcribing, and animate the pre→post change. That single rendering tweak is maybe 3 lines in `FloatingPillView.swift`, and it turns the feature from invisible-magic into a visible promise-kept. Combined with a one-line inline warning under the toggle for streaming users and a toast when auto-disabling (finding 5a), that's the ship-able minimum. Everything else in findings 1, 2, 7, 8 is polish for 0.2.5.

## out

Handoff ready for PM triage. Recommend `CHG:4` — minimum ship gates are stories 3, 5a, 6. Stories 1, 2, 7, 8 are followups. Offering to re-UAT once EN addresses 3 + 5a + 6.
