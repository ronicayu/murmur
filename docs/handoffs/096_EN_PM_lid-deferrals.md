---
from: EN
to: PM
pri: P2
status: RDY
created: 2026-04-25
branch: feat/lid-whisper-tiny
refs: 091, 092, 093, 094
---

## ctx

Round-1 review of the LID feature (handoffs 092–094) is resolved on the
branch. This handoff captures the items that were explicitly out of scope
for that pass, with enough context for PM to prioritise them for v0.3.

---

## deferrals

### 1. Librosa fixture for WhisperMelExtractor (DA #2, CR Q4)

**What.** `WhisperMelExtractor` is 240 lines of DSP (HTK mel filterbank,
STFT, log10 normalisation). No fixture comparison against a librosa
reference exists. QA proposed T5 (`logAndNormalise`) as a unit test —
that was not added in this pass because it requires making a `private static`
method `internal`.

**Why deferred.** A meaningful correctness gate requires (a) a Python
script that runs `librosa.feature.melspectrogram` with Whisper's exact
parameters on one or more short WAV fixtures, (b) those fixtures committed
to the repo, and (c) an XCTest comparing the Swift output to the reference
within tolerance 1e-3. This is half a day of work and requires a Python
environment — QA is better placed to own it.

**Proposed next step.** QA writes a follow-up task to:
- Generate 2–3 short WAV fixtures (silence, single tone, short speech).
- Dump librosa mel output to a JSON fixture file.
- Add `WhisperMelExtractorReferenceTests` that loads the fixture and
  asserts element-wise agreement.

Risk if not done: DSP may produce plausible-but-wrong mel frames, causing
the model to be confidently wrong for certain languages. Medium risk;
feature is opt-in and failures fall back to IME.

---

### 2. Cohere-echo alternative (DA #C)

**What.** DA challenged whether the 40 MB Whisper-tiny LID model is
necessary. Cohere Transcribe's response already carries a `language` field.
An alternative: transcribe once with IME's best guess, check Cohere's
returned language vs. the requested one, re-transcribe if mismatch and
output is degenerate. Cost: one wasted transcription on ~5–10% of recordings.

**Why deferred.** This is a PM-level architectural decision, not a code
fix. Both approaches are shippable. LID is already implemented and passes
review. The Cohere-echo path has not been prototyped.

**Proposed next step.** PM decides: (a) ship LID as-is for v0.3 opt-in,
collect dogfood data, revisit in v0.3.1; or (b) prototype Cohere-echo
before merging LID. If (b), DA's 20-recording comparison experiment is the
right gate. LID is feature-flagged (`autoDetectLanguage` default off), so
shipping it first carries low user-visible risk.

---

### 3. V3 streaming LID parity (DA #4)

**What.** LID currently runs only on V1 (stop-and-transcribe). V3 streaming
users get no language detection benefit. DA noted V3 is the growth path and
that a 200–400 ms pre-roll may be acceptable before the first partial.

**Why deferred.** The V3 streaming flow has fundamentally different
timing semantics. A pre-roll LID would add latency before the first chunk
is sent to Cohere, which needs its own latency budget analysis. The safer
approach for v0.3: LID on V3 fires after the first 5 s of audio is
accumulated, overriding only the language for the full-pass replacement
text (not the streaming partials). This requires coordinator changes
that are separate from the V1 integration.

**Proposed next step.** Scope as a v0.3.1 task once V1 LID is dogfooded.
Note in Settings UI: "Auto-detect works in standard mode. Streaming mode
support coming soon." (Requires PM approval for the copy change.)

---

### 4. Tonal-language reliability curve (DA #1)

**What.** DA raised that the 5-second probe + 0.60 threshold may perform
poorly for tonal languages (Mandarin, Cantonese, Vietnamese) when the first
seconds of audio are silence or throat-clearing noise. The confidence for
"EN on silence" can exceed 0.85 per Whisper's language prior.

**Why deferred.** Fixing this properly requires (a) empirical data from real
recordings, and (b) possibly a VAD gate before LID (skip LID if <500 ms of
voiced audio in the probe). Both require production logs.

**Proposed next step.** PM seeds an eval harness post-ship: collect 50+
`.public` LID log lines per language from team dogfooding. Specifically,
log the `detected/confidence/fallback` triple. After two weeks of
dogfooding, analyse: (a) false-positive rate for tonal languages, (b)
threshold tuning. If the silence-bias problem is confirmed, add a VAD gate
as a v0.3.1 fix.

---

### 5. Whisper 30 s zero-pad acknowledged (DA #5)

**What.** DA noted that the 5-second audio probe is zero-padded to 30 s
before mel extraction, and that Whisper was trained on real 30 s chunks,
not 5 s + 25 s of silence. The comment in the source ("no accuracy cost")
is incorrect.

**Status.** The comment was not updated in this pass (it requires a
decision on whether to change the probe length). DA's concern is
acknowledged and documented here. The comment in
`LanguageIdentificationService.swift` at `probeSeconds` should be updated
to be honest ("we clip to 5 s to keep inference cheap; accept potential
accuracy loss on short or late-starting utterances") before merge.
Assigning to EN as a pre-merge clean-up (1-line edit, no logic change).

---

### 6. Privacy wording on first HF download (DA #10)

**What.** The README/CHANGELOG says "local-only" but the aux model is
fetched from huggingface.co on first download, which logs IP + user agent.

**Proposed fix.** Add to onboarding copy and README: "Initial model
download is a one-time network fetch from huggingface.co; no audio or
transcription data ever leaves your device." One paragraph, no code change.

**Why deferred.** Copy/docs change — PM and UX own. Low urgency since the
toggle is off by default and the download is user-initiated. Target: resolve
before any public announcement of the LID feature.

---

## out

Six items, zero code required from EN to unblock merge. Action owners:

| Item | Owner | Target |
|------|-------|--------|
| Librosa fixture | QA | v0.3.1 |
| Cohere-echo decision | PM | before v0.3 GA |
| V3 LID parity | EN (scope in v0.3.1) | v0.3.1 |
| Tonal-language eval harness | PM | 2 weeks post-ship |
| probeSeconds comment fix | EN | pre-merge (1 line) |
| Privacy wording | PM/UX | before LID announcement |
