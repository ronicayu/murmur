---
from: DA
to: EN
pri: P1
status: WIP
created: 2026-04-25
branch: feat/lid-whisper-tiny
refs: 091, 085, 086, 090
---

## ctx

Stress-testing the Whisper-tiny LID feature on `feat/lid-whisper-tiny`.
Read 091, `LanguageIdentificationService.swift`, the two call sites in
`AppCoordinator.swift` (lines 376–418, 640–701, 865–940),
`MurmurApp.swift` (aux-state subscription), `SettingsView.swift`
(`autoDetectLanguage` toggle + `lidModelRow`), and the
`downloadAuxiliary` path in `ModelManager.swift`.

Net read: the code is clean, the math looks right, the failure-mode
triage is conservative. But the **UX story has a v0.2.3 regression**
baked in, the **5-second probe is not actually what whisper LID
expects**, and there are four to five scenarios where the current error
surfacing is objectively worse than silent fallback. Detailed below.

## challenges

### 1. "5 seconds" is a misnomer — the encoder still runs the full 30 s window

**Assumption.** "Whisper LID needs only a short probe; trimming audio
before mel extraction is a pure speed win with no accuracy cost."
(Service.swift:89–93.)

**Why it's suspect.** Whisper's encoder input is always 30 s padded.
Truncating the audio before mel extraction just replaces seconds 5–30
with silence; the encoder *still* runs over 3000 frames of mel, the vast
majority of which are now zeros. The speed win is literally zero on the
hot path (STFT dominates, not the zero-pad region), and zero-padding
after a short probe pushes the encoder into a regime the Whisper authors
did not train on (their corpora are real 30 s chunks, not 5 s + 25 s of
silence). OpenAI's own reference `detect_language` feeds the raw 30 s
mel; they do not truncate to 5 s first.

**Concrete risk.** Short utterances ("hi there, schedule a meeting")
give the encoder a 5 s speech + 25 s silence mel that the model has
seen in training only as "end of utterance" signal — language posteriors
may collapse toward English or toward a low-energy attractor. This is
exactly the distribution where tonal-language users will be worst
served.

**Suggested fix.** Either (a) probe the *full* recording up to 30 s (no
truncation), or (b) keep the 5 s cap but document it honestly — "we
clip to 5 s to keep inference cheap, accept accuracy loss on tonal
languages." The current comment "no accuracy cost" is just wrong.
Cheapest A/B: run 20 real recordings through both paths, log the top-2
language posteriors, eyeball the divergence.

---

### 2. Leading silence / press-and-breathe → English default

**Assumption.** Users hold down the hotkey and immediately start
talking. The first 5 s is audio of the target language.

**Why it's suspect.** Usability research we already did for the badge
feature (see 088 UAT) shows the opposite — power users press and
*then* think. Press-and-release toggle mode (the default per
`SettingsView`:80–87) amplifies this: users click, say "uhh", then
speak. The first 5 s is commonly ~2 s silence + ~1 s of throat-clear +
~2 s of speech.

**Concrete risk.** Whisper-tiny on near-silence is well-documented to
default to English (highest prior in its LM — openai/whisper issues
#928, #1432). With the 0.60 threshold, the confidence for "EN on
silence" is often ~0.85 because the LM has no competing signal. So the
*failure mode* is: Chinese user speaks Chinese, but the LID sees 3 s of
silence + 2 s of speech, returns `en @ 0.87`, coordinator trusts it,
Cohere is invoked as English on Chinese audio → garbage. This is a
**strict regression** vs. today's IME-based resolver, which would
correctly pick `zh` because their keyboard is in pinyin.

**Suggested fix.** Add an RMS/VAD gate before LID: if the first 5 s has
<500 ms of voiced audio, skip LID and fall back to IME. Or, more
robustly, seek to the first 500 ms of voiced audio *before* slicing
the 5 s probe. Simpler still: raise the probe to the full clip or the
first 10 s, whichever is shorter.

---

### 3. Badge-vs-result inconsistency is a v0.2.3 UX regression

**Assumption.** Unstated — the handoff doesn't mention the badge at
all.

**Why it's suspect.** v0.2.3 shipped the language badge as a trust
signal (see 086–090). The contract we sold UT/users is: *"The pill
badge tells you which language will be used for this transcription."*
With LID on:

1. `startV1RecordingFlow` (AppCoordinator:378) computes the badge
   **synchronously from IME at press time** — e.g., "EN·".
2. Recording proceeds, pill shows "EN·" for the full 10 s.
3. `stopAndTranscribeV1` (line 661) calls
   `resolveTranscriptionLanguageAsync`, LID fires, returns `zh`.
4. Cohere transcribes as Chinese. Output is Chinese characters.
5. User sees: pill said "EN·", Chinese characters appeared.

**Concrete risk.** Direct contradiction with the v0.2.3 badge promise.
UT's whole point (088) was "users need to know *before* releasing the
key whether the language is right." LID breaks that invariant. Worse:
the user has *no way to correct it*, because by the time they see the
mismatch the transcription is done and the text is already injected.

**Suggested fix.** Three options, pick one:
- **(A)** When `autoDetectLanguage` is on, badge renders something
  ambiguous like "AUTO·" or "⋯·" during recording, then the injected
  text's correctness is the signal. This is honest.
- **(B)** Run LID on a rolling first-second of mic buffer *during*
  recording (keep partial mel running). Update badge live as confidence
  rises. Expensive but user-truthful.
- **(C)** Ship LID V3-only, where there is no badge-at-start contract.
  V1 keeps today's IME behaviour.

The current code ships (A)'s *technical behaviour* but (B)'s *user
promise*. That's the worst of all worlds.

---

### 4. V3 streaming has no LID — the feature's biggest user segment is excluded

**Assumption.** "Pre-roll LID would defeat V3's first-token latency
target." (AppCoordinator:877.)

**Why it's suspect.** V3 is marketed as "streaming input" beta — the
growth path for Murmur. If LID is genuinely good enough to flip user
experience, V3 users get *zero benefit*. If it isn't good enough for
V3 because latency matters, then why is it good enough for V1, where
users were willing to wait anyway?

Also: the latency claim is unverified. A 5 s probe + whisper-tiny
encoder + one decoder step on M1 is ~200–400 ms. That's a one-time
pre-roll. Against a typical V3 first-partial of 1–2 s after speech
starts, adding 200 ms once is *not* "defeating the latency target" —
it's one partial tick.

**Concrete risk.** Fragmentation. Tomorrow we ship LID, a user enables
it, streaming is also on (default path for new users per 090?), and
LID does nothing. User reports "you told me to turn on the language
model and it didn't help." We have to explain "actually, the thing you
just installed only works when you turn off the feature we just told
you to turn on." That's a support channel nightmare.

**Suggested fix.** Either (a) run LID on the first post-press audio
chunk in V3 before sending the first partial, or (b) gate the toggle
visibility on `!streamingInputEnabled` and surface a clear "LID is
V1-only" caption. Today's UI lets the user enable both and get nothing.

---

### 5. The 99→14 language gate is silently punitive

**Assumption.** Whisper detects `th` (Thai). `CohereLanguageMapping.map`
returns nil. Coordinator falls back to IME resolver
(AppCoordinator:897–900). Safe.

**Why it's suspect.** For a Thai user with Thai IME: fallback =
`resolveTranscriptionLanguage()` = `en` (Thai isn't in the hard-coded
switch at line 923–936). So their journey is:
1. Download a 40 MB LID model *because* they hoped for better
   detection.
2. LID correctly says `th @ 0.92`.
3. Coordinator says "Thai isn't supported, fall back to IME → en."
4. Cohere transcribes Thai audio as English. Garbage.

Without LID, the flow would have been *the same garbage* — so LID
didn't break anything. But the user paid 40 MB + a new settings toggle
+ a "language model not installed" pill for exactly zero improvement.
And the pill error text lies ("Language detection unavailable" — it
worked fine, the *output language* just isn't supported).

**Concrete risk.** Low severity but high frequency on the long tail of
85 languages. The feature is anti-honest for that cohort.

**Suggested fix.** When LID returns a language outside Cohere's 14,
log info (not error), do NOT show the pill error, and fall back
silently. Reserve error pills for actual inference failures.

---

### 6. Model lifecycle has at least four latent bugs

**6a. User deletes aux model mid-recording.**
`MurmurApp.swift`:88–92 nullifies `coordinator.lid` when
`auxiliaryStates[.lidWhisperTiny] != .ready`. But `identify` may already
be in flight on the actor. The ORTSession lives inside the actor; the
actor retains it. Setting `coordinator.lid = nil` drops the outer
reference, but the in-flight `identify` still has the session bound.
Test: delete model while a 20 s recording is being transcribed — does
anything crash? Does the deletion succeed while `.onnx` files are
mmap'd?

**6b. Toggle off mid-recording.**
`autoDetectLanguageEnabled` is read at transcription time
(AppCoordinator:880). Flipping the toggle during recording means the
badge shown during recording used LID semantics but the post-record
resolution uses IME. Opposite of (3) but same root cause: badge and
resolution are computed at different times.

**6c. Download fails at 90% — toggle state.**
`SettingsView`:126–130 flips the UserDefault first, *then* starts the
download. If the download fails,
`modelManager.auxiliaryStates[.lidWhisperTiny]` is `.error` but
`autoDetectLanguage = true`. Next recording: guard `lid` is nil, error
pill fires, fallback to IME. Forever, silently, until the user notices.
**Fix.** On download error, flip the toggle back off and surface a
settings-pane error. Or gate the toggle by download success via a
binding that ignores optimistic writes.

**6d. Sleep/wake.**
`LanguageIdentificationService` holds `encoderSession`/`decoderSession`
across app lifetimes. After a deep sleep, the ORT session may or may
not be valid — CoreML/ORT models that reference hardware (ANE) have
been known to require re-init after GPU reset (`AMFI` logs). Nothing in
the service code calls `unload` on sleep. If a post-wake `identify`
throws, the user sees the pill error on their first recording of the
day.

**Suggested fix.** Add a `NSWorkspace.didWakeNotification` observer that
calls `await lid.unload()`; next identify will lazily preload. Cheap
insurance.

---

### 7. "Language detection unavailable" pill is a noisy default

**Assumption.** "Show the user when LID fails so they can act."
(Implied by 091 open Q3.)

**Why it's suspect.** Users *cannot* act on this error. The only
actions are (a) turn off the setting, (b) re-download the model.
Neither is obvious from a red transient pill. The failure modes
producing this error are overwhelmingly **recoverable and transient**
(race on load, ORT warm-up, short audio, corrupted probe) — the user
still gets transcription via the IME fallback. Showing a red pill for
a case the system already recovered from is anti-UX.

**Concrete risk.** For the silence case (see #2), the error pill fires
with meaningful frequency — 5–10% of real recordings could plausibly
trigger it. That's "this feature is broken" territory to a casual user.

**Suggested fix.** Silent fallback + log.error. Surface *once per
launch* via a MenuBar indicator if we must. Never on the pill for a
path the system auto-recovered from.

---

### 8. Memory and startup cost

**Assumption.** `LanguageIdentificationService(modelPath:)` is
instantiated at `MurmurApp.init()` if the aux model exists
(MurmurApp:28–30). The actor doesn't call `preload()` — sessions are
lazily created on first `identify`. Good.

**Why it's still suspect.** `preload()` is never called eagerly, so the
*first* recording with LID enabled pays the ORTSession-init cost
(~500 ms – 1 s for encoder+decoder init on M-series per ORT benchmarks)
on the stop-and-transcribe path. That's added to the already
perceptible transcription wait. Users will notice this only on the
first LID invocation per launch.

After preload, decoder + encoder quantised sessions sit at ~60–90 MB
RSS. Acceptable, but we ship this for every user who toggles the
setting, even those whose active session uses LID twice a week. On an
8 GB Mac with Electron apps, not trivial.

**Suggested fix.** (a) Preload on the background queue after download
completes, or on app launch 2 s after idle, so the first recording is
clean. (b) `unload()` after 30 minutes of LID idle to give RAM back.

---

### 9. Privacy claim needs a precise edit

**Assumption.** "Local-only after download" (README/CHANGELOG).

**Why it's suspect.** The aux model ships from
`onnx-community/whisper-tiny` on Hugging Face
(`ModelManager.swift`:137). First download is an HTTPS request to
huggingface.co, which logs IP + UA + repo. That's an HF problem, not
ours, but:
- The Murmur primary model is also HF-hosted. Same policy applies.
- "Local-only" means local-only *transcription*. We should explicitly
  state: "Initial model download is a one-time network fetch from
  huggingface.co; no audio or transcription data ever leaves your
  device."

**Concrete risk.** A privacy-conscious reviewer (HN/Reddit) notices
the wording gap and accuses us of a dark pattern. It's a
one-paragraph fix in README+CHANGELOG.

---

### 10. Why not use Cohere's own language confidence as a fallback?

**Assumption.** We need a standalone LID model because Cohere doesn't
report language confidence reliably enough.

**Why it's suspect.** This was never tested. Cohere Transcribe
(streaming and long-form) returns a `language` field on the response.
The naive alternative design is:
1. Transcribe once with IME's best guess.
2. Compare Cohere's returned `language` with the requested one.
3. If mismatch AND output looks degenerate (empty / single-char /
   repeating tokens), re-transcribe with Cohere's detected language.

Cost: one wasted transcription on ~5–10% of recordings where IME is
wrong. Benefit: zero extra models, zero model-management UX, zero
mel-extractor correctness risk, no `WhisperMelExtractor` (240 lines,
untested vs. librosa reference), no aux-state machine in
ModelManager.

**Concrete risk of shipping whisper-tiny LID instead.** 40 MB aux
download, 240 lines of DSP we have no ground-truth fixture for, a new
settings section, a new error pill, new badge inconsistency, a new
aux-state machine in ModelManager (200+ lines), a new sleep/wake
concern. All for a win we have not measured against the Cohere-echo
alternative.

**Suggested fix.** Before merging, run the Cohere-echo alternative
against the same 20 real recordings as #1. If it's within 5 pp of
whisper-tiny LID's accuracy, ship that instead. We pay 0 bytes, 0 new
UI, 0 new failure modes.

---

## contrarian answers to open questions

**Q1. AuxiliaryModel parallel hierarchy vs. sub-state of ModelBackend.**
Parallel is correct *today* but I'd flag it as tech debt the moment we
have a second aux model (punctuation restoration, speaker diarisation,
etc). The abstraction fails the moment two aux models want to share a
download mutex or a verification step. Acceptable for v0.3 only if
there's a docs/architecture.md line saying "refactor to generic aux
registry once N ≥ 2."

**Q2. Confidence threshold on AppCoordinator vs. UserDefault.**
Neither. Do not surface this in Settings (advanced) — it's an
un-tunable knob for 99.9% of users and a footgun for the 0.1% who will
tune it wrong and then blame Cohere. Keep it private. But **log the
detected/threshold pair on every invocation** (which the code already
does — good), so a future dogfooding sweep can pick a data-driven
value. And plan a v0.3 task: collect 50 `.public` LID log lines from
team, pick the threshold that minimises FP+FN on the mislabel cases.

**Q3. "Language detection unavailable" pill.** Covered in #7 — drop it.
Silent fallback, log.error only. If we must surface, use the existing
Settings section to show last-failure state, not a transient pill.

**Q4. WhisperMelExtractor without a librosa fixture.** Block. This is
240 lines of DSP with non-trivial numeric normalisation (log10 + clip +
(x+4)/4). The correctness risk is that the model outputs *plausible*
but wrong language codes, which is undetectable from unit tests but
catastrophic for the feature's entire purpose. Cost of a fixture test:
one Python script to dump librosa output for 3 WAV files, one
`XCTAssertEqual` with tolerance 1e-3. Half a day. Non-negotiable for a
P1 ship.

## out

**Am I comfortable shipping?** No, not as-is. This feature has three
independent blockers:

1. **Blocker: the v0.2.3 badge contract is silently broken.** (#3)
   This is a known shipped promise we're about to contradict with no
   mitigation. Either the badge behaviour changes for LID-on mode, or
   LID waits for v0.3 until we can redesign the badge.
2. **Blocker: no DSP fixture test for `WhisperMelExtractor`.** (#Q4,
   #1.) The feature's correctness hinges on mel extraction matching
   librosa within tolerance. We have literally zero evidence this is
   the case. Ship this and we may be shipping a confidently-wrong
   language detector.
3. **Blocker: the Cohere-echo alternative was never prototyped.** (#10)
   We have not earned the right to add 40 MB, a new actor, a new
   state machine, and a new error mode without first proving the
   simpler alternative is insufficient.

**Smallest change that would get me to LGTM:**

- A 20-recording dogfood comparison: whisper-tiny LID vs.
  Cohere-echo vs. status-quo IME. Published as a table in
  `docs/handoffs/095_EN_DA_lid-evidence.md`.
- Fix the badge regression (pick option A or C from #3).
- Either fix #5 (silent fallback for unsupported-by-Cohere) or
  document it as a known limitation in Settings copy.
- A librosa-fixture test for `WhisperMelExtractor`.

If those four land, I withdraw blockers 1–3 and the remaining items
(#2 silence gate, #6 lifecycle, #7 pill noise, #8 preload timing) can
be fast-followed in a v0.3.1.

One more thing: if v0.3's big bet is streaming V3, then shipping an
LID feature that **explicitly does not work in V3** is selling the
user a feature for the pipeline we're trying to retire. Reconsider
the whole scope — V3-only LID or no LID at all may be the honest
answer.
