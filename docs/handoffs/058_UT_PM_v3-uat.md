# Handoff 058 — UT -> PM: V3 Streaming Voice Input UAT Review

**From:** UT (`uat-user-tester`)
**To:** PM (`staff-product-manager`)
**Status:** CHG:6
**Date:** 2026-04-10

---

## Summary

I went through the V3 streaming voice input feature as a regular user would -- someone who already uses Murmur for daily voice typing in English and Chinese. Overall the feature concept is solid and addresses a real frustration (the "is this thing even working?" feeling during long dictation). But there are several places where the experience would leave me confused, worried, or unsure what to do. Six issues flagged, three of which I consider blockers for a good first impression.

---

## What Worked Well

1. **The toggle placement is good.** "Streaming input (beta)" is in Settings under an "Experimental" section header. It doesn't shout at me but it's easy to find. The "(beta)" label sets my expectations correctly -- I know this might be rough.

2. **The "New" discovery badge is a nice touch.** Showing it after 10 uses of regular voice input is smart. By that point I already trust the app enough to try something new. And it goes away once I flip the switch, which is respectful.

3. **The description text is clear.** "See text appear as you speak. Final result replaces streaming preview." -- I get it in one read. That's the right amount of words.

4. **The floating pill streaming state (orange waveform + pulse) feels alive.** It's visually distinct from the regular red recording dot, so I know I'm in a different mode. Good.

5. **Safety-first approach to replacement.** Cursor moved? Skip replacement. Electron app? Skip replacement. Focus lost too long? Abandon session. I wouldn't know any of this as a user, but the fact that the app errs on the side of "don't mess up my text" is exactly right.

6. **Cmd+Z undo works on the full-pass replacement.** This is critical. If the app changes my text after I stopped talking, I need a way to say "no, put it back." Good that this exists.

---

## Issues Found

### Issue 1 (P0-UX): "Streaming..." pill shows chunk count in developer language

**What I see:** The floating pill says "Streaming..." and below it shows "3 chunks". 

**My reaction:** What is a "chunk"? I'm not a developer. I don't know what chunks are. I just said three sentences -- is that three chunks? Or is it something else? This makes me feel like I'm looking at debug output instead of a finished product.

**What I expected:** Something that tells me the app is working in human terms. Like "Streaming... 9s" (elapsed time) or just "Streaming..." with the pulse animation and nothing else. Even "3 segments" would be slightly better than "chunks" but honestly I'd prefer elapsed time or word count.

**Applies to:** `FloatingPillView.swift` line 87-89, `AppState.statusText` line 44.

**Recommendation:** Replace chunk count with elapsed recording time, or just drop the count entirely and let the pulse animation do the work.

---

### Issue 2 (P0-UX): No feedback when full-pass replacement happens

**What happens:** I finish speaking, release the hotkey. The pill shows "Transcribing..." then the text I streamed gets silently replaced with different text. There's a success sound and a green checkmark, same as V1.

**My reaction:** Wait -- did my text just change? I was reading what I dictated, and suddenly some words are different. There's no indication that a replacement happened vs. the text just being "done." If I wasn't paying close attention, I might not even notice the replacement, which means I also wouldn't know to Cmd+Z if I preferred the original.

**What I expected:** Some kind of signal that the text was corrected. Even a brief pill message like "Text refined" or a different colored checkmark. Something that tells me "hey, I changed a few words to be more accurate." And ideally a hint that I can Cmd+Z to undo the refinement.

**Applies to:** `AppCoordinator.swift` `stopAndTranscribeStreaming()` -- after `waitForStreamingDone()` it just transitions to idle with a success sound. No differentiation between "kept streaming version" and "replaced with full-pass."

**Recommendation:** When full-pass replacement actually fires, show a brief pill state like "Refined" or "Updated" (maybe with a blue checkmark instead of green?) and include a subtitle "Cmd+Z to undo". When no replacement happens, show the normal green checkmark.

---

### Issue 3 (P1-UX): No indication when streaming falls back to V1 mode

**What happens:** If CPU goes above 90% for 3 seconds, the app silently stops processing new chunks and falls back to doing one big transcription at the end (V1 behavior).

**My reaction:** If I had streaming on and was expecting to see text appear while I talk, and suddenly it just... stops appearing... I would think the app froze. I'd probably hit Escape and try again. I wouldn't know that the app is still recording and will transcribe everything at the end.

**What I expected:** A pill message like "Switched to standard mode" or the pill changing back from the orange streaming look to the red recording look. Anything that tells me "I'm still working, just in a different way now."

**Applies to:** `StreamingTranscriptionCoordinator.swift` `handleCPUFallback()` -- it silently sets `cpuFallbackTriggered = true` and nulls out the chunk handler, but the pill is never updated.

**Recommendation:** When CPU fallback triggers, update the pill to show the standard recording state (red dot) or show a brief transition message. The user needs to know the app is still alive.

---

### Issue 4 (P1-UX): Focus guard abandonment is silent

**What happens:** If I switch away from the app I'm typing in for more than 10 seconds during streaming, the session is abandoned. No notification, no sound, nothing.

**My reaction:** I switched to Finder to check a filename, got distracted for 15 seconds, went back to my email, and... nothing? Is Murmur still recording? Did it stop? Where did my text go? I'd have to look at the menu bar to figure out the state, and even then I might not understand what happened.

**What I expected:** At minimum, an error sound when the session is abandoned. Ideally the pill should briefly appear saying something like "Session ended -- app was inactive too long" before disappearing. I also think 10 seconds is pretty short -- I can easily spend 15 seconds checking something in another app. But I understand there's a technical reason for the limit.

**Applies to:** `StreamingTranscriptionCoordinator.swift` `handleFocusEvent` focus-abandon path calls `cancelSession()` which just transitions state. No user-facing feedback.

**Recommendation:** Play the error sound and show a brief pill notification when the session is abandoned due to focus loss. Consider bumping the timeout to 15-20 seconds if possible.

---

### Issue 5 (P2-UX): No way to know streaming is ON from the menu bar

**What I see:** The menu bar dropdown shows a status header ("Ready", "Recording...", etc.) and I can see "Streaming..." with the orange waveform when actively streaming. But when I'm NOT actively recording, there's no indication anywhere in the menu bar that streaming mode is enabled vs. disabled.

**My reaction:** I turned on streaming yesterday, and today I can't remember if it's still on. I have to open Settings to check. This is a minor annoyance but it adds up.

**What I expected:** A small indicator in the menu bar status area when idle -- maybe the status text says "Ready (streaming)" instead of just "Ready", or a small icon badge. Something quick to glance at.

**Applies to:** `MenuBarView.swift` `statusHeader` and `AppState.statusText` for `.idle`.

**Recommendation:** When streaming is enabled, append something to the idle status text or add a small visual indicator in the menu bar header.

---

### Issue 6 (P2-UX): Clipboard is borrowed during every chunk injection

**What I noticed (from reading the code):** Each streaming chunk injection uses the clipboard-paste method -- it saves my clipboard, puts the transcribed text in, simulates Cmd+V, waits 1500ms, then restores my clipboard. During a 30-second dictation with 3-second chunks, that's roughly 10 clipboard round-trips.

**My concern:** If I copy something to my clipboard right before dictating (which I do all the time -- copy a URL, then dictate a sentence about it), there's a 1.5-second window per chunk where my clipboard content is replaced. With 10 chunks, that's up to 15 seconds of "clipboard roulette." The code does restore the clipboard, but there's a race condition window.

**What I expected:** This is honestly something I'd only notice if I tried to paste right after dictating and got the wrong thing. But for a streaming feature where chunks are injected repeatedly, the clipboard churn feels risky. I know this is how V1 works too, but V1 only does it once. Streaming does it 10 times.

**Applies to:** `TextInjectionService.swift` `injectViaClipboard` called via `appendText` for every chunk.

**Recommendation:** Not sure what the fix is from a user perspective -- I just want my clipboard to still have what I copied before I started talking. Maybe worth a note in the beta description? "Streaming input temporarily uses your clipboard."

---

## Edge Cases I'd Want Tested (as a user)

1. **Dictating in Chinese then switching to English mid-sentence.** The spec says streaming uses one language for the whole session. But as a bilingual user, I mix languages constantly. What happens when I say "我想要一个meeting tomorrow"? Does the 3-second chunk that catches "meeting tomorrow" get mangled?

2. **Very short dictation (< 3 seconds).** If I tap the hotkey, say "OK", and release in 2 seconds, does streaming mode handle this gracefully? Or does the first chunk never accumulate?

3. **Dictating into a password field or search bar.** These are unusual text fields. Does the streaming injection cause weird behavior?

---

## Overall Feeling

The streaming concept is genuinely useful. The "is this thing on?" anxiety during long dictation is real, and seeing text appear while I talk would fix that. The safety measures (skip replacement when cursor moved, Electron blocklist, focus guard) show thoughtful engineering.

But right now the feature feels like it's built for developers, not users. The "chunks" terminology, the silent fallbacks, and the missing feedback when text gets replaced -- these all assume the user understands what's happening under the hood. A regular person just wants to know: "Is it working? What just happened? Can I undo that?"

If Issues 1 and 2 are fixed, I'd feel comfortable recommending this to someone. Issues 3 and 4 would make it even better. As-is, I'd turn it on, get confused by the "chunks" label and the silent text replacement, and probably turn it off after a day -- which would show up as the "V1 rollback rate" metric the spec is worried about.

**Verdict:** Not ready for beta users without at least P0 fixes. Close, though -- the bones are good.

---

## Handoff

**To PM:** Please review the six issues above. P0s (Issue 1, Issue 2) should be addressed before any external beta. P1s (Issue 3, Issue 4) are strongly recommended. P2s (Issue 5, Issue 6) can wait for V3.x.

**Status codes for issues:**
- Issue 1: REQ (change "chunks" to human-readable label)
- Issue 2: REQ (add replacement feedback + undo hint)
- Issue 3: REQ (add CPU fallback user notification)
- Issue 4: REQ (add focus-abandon user notification)
- Issue 5: PUNT (nice-to-have idle indicator)
- Issue 6: PUNT (clipboard churn awareness)
