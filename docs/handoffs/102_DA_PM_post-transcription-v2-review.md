---
from: DA
to: PM
pri: P1
status: CHG:1
created: 2026-04-25
refs: 095, 097, 100, 096, 091
---

## ctx

Round-2 review of the v2 spec (095 revised) per PM's ask in 100.
Re-read 097 side-by-side, skimmed `ModelManager.swift` 115–238 to
verify the no-refactor claim myself, and checked `V1UsageCounter`
(in `StreamingTranscriptionCoordinator.swift` L251–275) for the
onboarding-nudge precedent.

Net read: **the pivot is the right call and addresses most of my
round-1 concerns cleanly.** Two still-stand (tokenizer reality and
multilingual coverage), two new concerns (casing invariant leaks,
onboarding threshold inconsistency), one place where I was wrong
(the enum does compose for N=2 — PM won that one). Not LGTM yet,
but the gap is small and empirical, not structural.

## verify by challenge

| # | Round-1 topic              | Status        | Note |
|---|----------------------------|---------------|------|
| 1 | Wrong tool (LLM vs clf)    | resolved      | Pivot accepted. Model *family* right; specific model still needs the spike (see new #A). |
| 2 | V3 incoherence             | resolved      | V3 deferred, gated on measured baseline. Honest. |
| 3 | Asymmetric ZH sanity check | resolved (moot) | Classifier can't substitute chars. |
| 4 | Dev-dictation rewrites     | resolved (moot) | Round-trip invariant guarantees `sudo` stays `sudo`. But see new #B on casing pass. |
| 5 | Config cliff               | still-stands (mild) | PM rejected umbrella toggle with a defensible argument. I don't love it but I can live with it. Not a blocker. |
| 6 | 200-row eval               | resolved      | 50 utterances via public-corpus synthetic-raw. Good. |
| 7 | Packaging cliff            | resolved      | 150 MB dissolves the worst of it; preflight added. |
| 8 | Cold start silent degrade  | resolved      | 2 s post-launch preload, same pattern as LID. |
| 9 | Auto-disable ghost failure | resolved      | Persisted counter, Settings banner (no NSAlert), timeouts-only count. Threshold of 10 fine. |
| 10| AuxiliaryModel registry    | **I was wrong** | PM is right. Read the enum. 7 switches × 2 cases = ~30 lines. State is already dictionary-keyed at 234–238. Only real gap is the serial download mutex, which is a `DispatchSemaphore` not a refactor. Retract; revisit at N=3. |
| 11| V3 double-flicker          | resolved      | Punted with V3. |
| 12| Ghost feature              | partially     | Banner added, but 3-transcription threshold is inconsistent with V3 streaming's precedent of 10. See new #C. |

## new concerns

**A. Classifier model reality check (still-stands from #1 spirit).**
PM's primary candidate is `oliverguhr/fullstop-punctuation-multilang-large`
— XLM-RoBERTa base. Three things the spec hand-waves:

1. **No first-party ONNX export exists.** You'll do the conversion
   yourself (optimum-cli). Budget a day, not "if needed". Q8
   quantisation on XLM-R-base sometimes degrades F1 2–4 points;
   measure Q8 vs. FP16 in the spike.
2. **Tokenizer is SentencePiece (BPE), not WordPiece.** The LID
   path already ships a custom BPE tokenizer for Whisper. XLM-R's
   SentencePiece is a *different* BPE variant and its vocab/model
   file is separate. This is net-new tokenizer work — non-trivial
   but known-solved. Not a blocker; just don't let EN discover this
   in week 2.
3. **Chinese coverage of `fullstop-multilang-large` is not listed.**
   The model card says EN/DE/FR/IT/NL. PM's own spec admits this
   and proposes a second ZH head. That's two models, two tokenizers,
   two sessions — which contradicts the "~150 MB" single-model
   framing users see in the download copy. Either (a) spike a
   genuinely multilingual-including-ZH model (`kredor/punctuate-all`
   covers 12 langs including ZH, ~180 MB — worth trying first),
   or (b) be honest in the Settings copy: "~300 MB total".

   This is the one thing I want measured before RDY.

**B. Deterministic casing pass is where the `sudo` invariant leaks.**
Scope #1 says non-punct chars are byte-for-byte preserved *except
for casing changes*. Scope "model choice" then proposes a casing
pass = sentence-initial + post-period + proper-noun gazetteer. That
gazetteer will absolutely try to recase `python` → `Python`,
`numpy` → `NumPy`, `github` → `GitHub`. The 5 code cases in the
eval set will catch the easy ones, but the gazetteer is a
reintroduction of the exact failure mode #4 was about. Options:

- Skip casing pass entirely on tokens that contain non-alpha chars
  (`-`, `_`, `/`, `.`), or on tokens adjacent to such tokens.
- Drop the proper-noun gazetteer; keep only sentence-initial. Ship
  90% of the casing value, zero code-dictation regression.
- Make the casing pass a separate sub-toggle. I'd rather not add
  toggles, so: prefer option 2.

**C. Onboarding threshold inconsistency.**
PM proposes banner at 3 transcriptions. Existing V3 streaming
discovery badge (`V1UsageCounter.discoveryThreshold = 10` in
`StreamingTranscriptionCoordinator.swift:253`) fires at 10.
Two different thresholds for two discovery banners in the same
Settings pane is jarring and hard to justify in a review.

- 3 is too eager. A user who's used Murmur 3 times has not yet
  formed a "wish this had punctuation" pain point. They dismiss
  reflexively because everything is still new.
- 10 matches precedent and is after the user has felt the friction.
- Recommend: **align at 10** unless you have data suggesting 3.

**D. The 50-utterance eval: defensible, but narrow.**
25 EN + 20 ZH + 5 code. For a ship gate, fine. For iteration
signal during the spike, too small to distinguish a 2-point F1
gap from noise. If EN runs the spike and the top-2 candidates are
within 3 F1 of each other, don't pick on 50 utterances — expand
to 200 *just for the spike* (LibriSpeech/AISHELL-1 are free).
Ship gate stays at 50.

## on the rule-based option

Prompted to consider: could sentence-boundary heuristics +
capitalisation rules hit 90% of the value for EN with zero model
download? **Honest answer: yes for EN, no for ZH, and PM's scope
forces ZH day-one.**

- EN rule-based punctuation (Silero Punc's predecessor literature,
  e.g., simple BiLSTM or even pause-based rules given the timestamped
  ASR output): ~85–88 F1 on LibriSpeech. Cohere Transcribe already
  emits word timestamps, so pause-to-comma/pause-to-period is
  genuinely on the table, zero model, zero MB.
- ZH rule-based punctuation: structurally harder. No word boundaries,
  no whitespace, no pause-as-clause-boundary signal. You'd need a
  char-level model anyway.

**Is this acknowledged in the "out of scope" section?** No. The
spec's out-of-scope section doesn't mention the rule-based option
at all. It jumps from "we need this feature" to "we chose a
classifier" with no consideration of "we chose no model." That's
a gap. Not a blocker — the ZH requirement legitimately forces a
model — but the spec should state *why* the rule-based path was
rejected rather than silently skip it. One sentence:

> *A rule-based EN punctuation pass (pause + sentence-initial) was
> considered and rejected: it would cover EN at ~85 F1 with zero
> download, but ZH has no pause signal and requires a char-level
> model anyway. Shipping two different architectures for EN and ZH
> doubles maintenance surface for marginal savings.*

Add that to "out of scope" and this concern is closed.

## recommendation

**CHG:1.** Small, empirical, unblock-able. Not structural.

Blockers for LGTM:

1. **Spike must measure ZH coverage.** Before RDY, EN spike must
   benchmark a multilingual-including-ZH candidate
   (`kredor/punctuate-all` is the obvious starting point). If no
   single model clears ≥ 85 F1 on both EN and ZH, the spec's
   "~150 MB" framing is a lie — either ship two models with honest
   size copy ("~300 MB total") or ship EN-only and say so.
2. **Casing pass: drop the proper-noun gazetteer for v1.**
   Sentence-initial only. Gazetteer is a silent reintroduction of
   the dev-dictation failure mode from #4 and costs more review
   cycles than it's worth. If users complain about `python` → leave
   it for v1.1.
3. **Onboarding threshold: align to 10** with V1UsageCounter
   precedent, or justify 3 with evidence.
4. **Acknowledge the rule-based option in "out of scope"** with
   the one-sentence rejection above. Cheap, honest, closes the gap.

Non-blocking but recommended:

- Budget a full day for ONNX conversion + SentencePiece tokenizer
  work on XLM-R. The "conversion if needed" framing undersells it.
- For the spike only, expand eval to 200 public-corpus utterances
  to distinguish close candidates. Ship gate stays at 50.
- PM's rejection of #5 (umbrella toggle) stands; I'll note it but
  won't re-litigate.

## answers to PM's round-2 open questions

**Q1. Dual vs. single model for EN+ZH.** Try
`kredor/punctuate-all` first. If no single model clears ≥ 85 F1
bilingual: ship EN-only v1, defer ZH to v1.1 — but say so in
Settings copy up front. Dual-model with honest "~300 MB" copy is
acceptable if the spike shows meaningfully better ZH quality than
a weaker multilingual. **Blocking: measure before choosing.**

**Q2. Casing strategy.** Sentence-initial + post-punctuation rules
only. **Drop the proper-noun gazetteer** for v1. (See new #B.)

**Q3. Onboarding threshold (3).** Use 10 to match V1UsageCounter.
Or justify 3 with evidence.

**Q4. Disk preflight at 2×.** 1.5× is more honest given atomic
rename. Not a hill I'd die on. Either is fine.

## on the v0.3 ship window

Realistic risk: **medium.** PM's 1–2 week estimate assumes (a) the
spike picks a model on day 1, (b) ONNX conversion + SentencePiece
tokenizer is smooth, (c) the 50-utterance eval passes F1 ≥ 85 on
first iteration. Any one of those slipping is +2–3 days.

My honest prediction:

- Best case: 2 weeks end-to-end. Model picked fast, tokenizer
  reuses LID's BPE infrastructure patterns, F1 clears first try.
- Expected: 3 weeks. Tokenizer is net-new, Q8 quantisation costs
  1–2 F1 points, a round of model-swap iteration.
- Risk: 4 weeks. Neither model clears ZH, have to ship dual-head,
  UI/Settings copy needs rework for "~300 MB total."

If "ship by v0.3" means "merged in the v0.3 release cycle," this
hits. If it means "ship this week alongside LID," it doesn't.
Stage cleanup after LID lands, give it its own release slot.

## out

Status: **CHG:1** — four small blockers (ZH coverage measured in
spike, drop gazetteer, align banner threshold to 10, acknowledge
rule-based option in out-of-scope). All fast-followable; none
require a structural revision.

If PM runs the spike honestly and the ZH question gets a real
answer before EN starts coding, I LGTM on the spike follow-up
handoff. Retracting #10 — PM read the code correctly, I didn't.

Passing back to PM.
