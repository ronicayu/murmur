---
from: DA
to: PM
pri: P1
status: done
created: 2026-04-08
---

# Spec Challenge: Murmur v1

## Fatal Flaws

### 1. "Cohere Transcribe" does not appear to be a real, shippable product

The spec is built entirely around "Cohere Transcribe 2B" -- a model described as ~4 GB, running locally via Python or compiled inference. As of early 2026, Cohere's public model offerings are Coral (chat), Command (generation), and Embed. There is no publicly documented "Cohere Transcribe" speech-to-text model available for local inference. If this model does not exist as a downloadable, locally-runnable artifact with a permissive license, the entire project is DOA.

**Action required:** Confirm the model exists, is downloadable, has a license that permits redistribution/bundling, and actually runs on Apple Silicon. If it doesn't exist, evaluate alternatives: Whisper (via whisper.cpp or mlx-whisper), Canary, or Parakeet. This must be resolved before any other work proceeds.

### 2. No plan for text injection failure -- the default case

The spec (Risk #1) acknowledges AXUIElement injection "doesn't work consistently across all macOS apps" and rates likelihood as **High**. The UX flows (Section 1, Failure States) fall back to clipboard paste when "no focused text field" is found, but that is a different failure mode. The spec never addresses what happens when a text field IS focused but injection fails silently or partially (wrong cursor position, text replaces selection unexpectedly, injection goes to wrong window). This is the core feature. A high-likelihood failure in the core feature with no robust fallback plan is fatal.

**Action required:** Define a concrete injection strategy matrix: (1) try AXUIElement setValue, (2) if that fails, try CGEvent keystroke simulation, (3) if that fails, clipboard + Cmd+V. Build detection for each failure mode. Ship with a tested app compatibility list.

---

## Questionable Assumptions

### 1. "Option+Space is a good default hotkey"

**Assumption:** Option+Space is available and ergonomic as the default recording trigger.

**Why it might be wrong:** Option+Space is used by macOS Spotlight in some configurations, and by many apps for non-breaking space insertion (common in typesetting, writing apps). Alfred, Raycast, and other launcher apps also commonly bind Option+Space. The spec mentions `Fn` double-tap and `Ctrl+Space` but the UX flows hardcode `Option+Space`. The spec and UX flows disagree on the default hotkey.

**What to do:** Pick one default and make both docs consistent. Test for conflicts with Spotlight, Alfred, Raycast, and CJK input methods (Ctrl+Space switches input sources on many setups). Document conflict resolution in onboarding.

### 2. "4 GB download during onboarding is acceptable friction"

**Assumption:** Users will wait for a 4 GB download before getting any value from the app.

**Why it might be wrong:** The spec itself (Risk #5) rates the likelihood of user bounce as High. "Under 3 minutes on a fast connection" is optimistic -- 4 GB at typical home speeds (50 Mbps) is ~10 minutes. On slower connections, 30+ minutes. Users who installed a <10 MB app and are then asked to wait 30 minutes will uninstall.

**What to do:** Consider shipping a tiny model (~200 MB quantized Whisper) for instant first-use, then downloading the large model in the background. The user gets value immediately (even if accuracy is lower), and upgrades transparently.

### 3. "2-4 GB RAM for inference is fine"

**Assumption:** Users will tolerate 2-4 GB memory usage for a utility app.

**Why it might be wrong:** The base M1 MacBook Air ships with 8 GB RAM. With macOS using ~3-4 GB, a browser using 2-3 GB, this leaves very little headroom. Loading a 2-4 GB model even temporarily will cause swap pressure and degrade system performance. The spec says "load/unload after 60s" but loading a 4 GB model into memory on every use introduces multi-second cold-start latency that directly conflicts with the 1.5s latency target.

**What to do:** Benchmark on an 8 GB M1 Air with realistic workloads (browser + Slack + VS Code open). If memory pressure is real, the quantized/smaller model isn't optional -- it's mandatory for the base config. Consider a 4-bit quantized variant that fits in ~1 GB.

### 4. "Apple Silicon only is an acceptable constraint"

**Assumption:** Limiting to Apple Silicon cuts a small segment.

**Why it might be wrong:** As of 2026 this is mostly fine, but the spec should explicitly state the minimum RAM requirement (8 GB? 16 GB?). An M1 with 8 GB is very different from an M3 Pro with 36 GB for this workload.

---

## Missing Edge Cases

1. **Long recordings.** The spec mentions "10-second utterance" as the benchmark. What happens with 60-second or 5-minute recordings? Is there a max recording duration? Memory for audio buffers? The model may produce garbage on very long inputs.

2. **Rapid-fire usage.** User presses hotkey, transcribes, immediately presses again. Is the model still loaded? What if a second recording starts while the first is still transcribing?

3. **App switching during recording.** User starts recording in VS Code, switches to Slack mid-recording. Where does the text go -- the app that was focused when recording started, or when it ended?

4. **Sleep/wake.** Mac goes to sleep during model download. Mac goes to sleep with model loaded in memory. Mac wakes and user immediately tries to record.

5. **Disk space.** 4 GB model + audio temp files on a Mac with limited storage. No disk space check before download. No warning when disk is low.

6. **Multiple displays/Spaces.** Floating pill appears "near the cursor" -- which screen? Which Space? What if the focused text field is on a different display than the menu bar?

7. **Accessibility permission revoked.** User grants permission during onboarding, then revokes it later via System Settings. The app should detect this on every use, not just during onboarding.

8. **Concurrent audio.** User is on a FaceTime call or playing music. Does Murmur record system audio or just the mic? What if the mic is in use by another app exclusively?

---

## Scope Concerns

### Too much for v1

- **Settings UI** (UX flows Section 5) includes language selection, sound effects toggle, launch at login, delete model, re-download, hold vs toggle mode. The spec explicitly says Settings UI is "out of scope for v1" beyond hotkey selection. The UX flows contradict this. Resolve the conflict -- either cut Settings or update the spec.

- **Toggle mode** is specified in UX flows but not in the spec. This adds complexity to the state machine and hotkey handling. Cut it from v1 or add it to the spec.

- **Language selection submenu** in the menu bar dropdown (UX Section 3). The spec says "auto-detected -- I never choose." The UX adds manual override. Pick one.

### Missing from v1

- **No launch-at-login.** If the app doesn't start at login, users will forget it exists. The UX flows include it in Settings, but the spec doesn't mention it. This should be a v1 requirement, not a settings feature -- it should default to ON after onboarding.

- **No clipboard mode.** The UX flows already implement clipboard fallback when no text field is found. Promoting this to an explicit feature (hotkey variant or setting) is near-zero additional work and makes the app useful in more contexts.

---

## UX Challenges

1. **Hold-to-record is exhausting for long dictation.** The default mode requires holding Option+Space for the entire duration of speech. For anything over 10-15 seconds, this is physically uncomfortable, especially on a laptop keyboard. Toggle mode should be the default, or hold duration should be capped with auto-stop.

2. **Floating pill position is underspecified.** "Near the cursor" -- which cursor? The mouse cursor or the text cursor? What if the text cursor is at the bottom of the screen and the pill would be clipped? What about full-screen apps?

3. **No undo.** After text is injected, there's no way to undo via Murmur. The user must manually select and delete. Consider: inject text, and if the user presses the hotkey again within 2 seconds, undo the last injection and start a new recording.

4. **Onboarding Step 5 uses a button, not the hotkey.** The test step uses a big record button, but the real app uses a hotkey. The user never practices the actual interaction during onboarding. Step 6 shows the hotkey but doesn't let them try it. Add a "try the hotkey" sub-step.

5. **No indication of which language was detected.** The transcribed text just appears. Users will want to know if the model chose Chinese or English, especially when accuracy is low. Show the detected language briefly in the pill.

---

## Technical Red Flags

1. **Python runtime bundling is listed as High likelihood, High impact risk -- and still unresolved.** This is Open Question #1 and the spec acknowledges it "must be resolved before EN starts coding." Yet UX has already designed detailed flows. If the runtime decision changes the architecture fundamentally (e.g., whisper.cpp has no Cohere model support), the UX work may need revision. Resolve the runtime question NOW, before more design work.

2. **No versioning strategy for the model.** When Cohere releases v2.2 or v3 of the model, how do users update? The spec has no auto-update mechanism and no model update flow. The Settings UI shows a version string but no update button.

3. **"Local-only analytics" is underspecified.** Success metrics include onboarding completion rate and daily active usage measured by "local-only counter" and "analytics event." Where is this stored? What format? Is it accessible to the developer? If this is just UserDefaults, it's not queryable at scale. If the app has no telemetry, these metrics are unmeasurable beyond the developer's own machine.

4. **No crash recovery.** What happens if Murmur crashes mid-transcription? The model process dies? Is there a watchdog? Does the app restart automatically? Menu bar apps that crash silently and disappear are confusing.

5. **CGEvent tap + Accessibility permission creates a single point of failure.** The hotkey mechanism (Open Question #2) and text injection both require Accessibility permission. If the user revokes it, both input and output break simultaneously with potentially no way to show an error (since the app can't intercept the hotkey anymore).

---

## Recommendations

1. **Validate the model exists and is shippable before doing anything else.** Run Cohere Transcribe (or its real equivalent) on an M1 Air with 8 GB RAM. Measure latency, memory usage, and bilingual accuracy. If any metric fails, switch to whisper.cpp + a multilingual Whisper model. This is a one-day spike that prevents months of wasted work.

2. **Ship a small model for instant onboarding, download the large model in background.** Bundle or fast-download a ~200 MB quantized model so users get value in under 60 seconds. Download the 4 GB model in the background. Switch to the better model silently when ready. This eliminates the biggest onboarding friction.

3. **Resolve the spec/UX conflicts before engineering starts.** The documents disagree on: default hotkey (spec says Fn/Ctrl+Space, UX says Option+Space), settings scope (spec says minimal, UX has a full settings panel), language selection (spec says auto-only, UX adds manual override), toggle mode (UX has it, spec doesn't). One source of truth, one decision per item.

4. **Build the text injection compatibility matrix in week 1.** Test AXUIElement injection + CGEvent fallback against the top 20 macOS apps. Publish a compatibility table. This determines whether the core value prop actually works before investing in polish.

5. **Default to toggle mode, not hold mode.** Hold-to-record is fine for 5-second queries but painful for dictation. Most users of voice input apps dictate for 15-60 seconds. Make toggle the default, keep hold as an option for power users who want it.
