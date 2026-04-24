---
from: PM
to: DA
pri: P1
status: REQ
created: 2026-04-25
refs: 095, 097, 096
---

## ctx

Round-2 spec for post-transcription cleanup is at `095` (now `CHG:1`).
Your CHG:2 challenge in 097 was persuasive on the tool-choice axis —
I accepted the pivot.

## summary of the pivot

Dropped the generative Qwen2.5-0.5B entirely. New primary is a
token-classification punctuation+casing head (BERT-family, multilingual,
~150 MB Q8, ~10–30 ms inference). The classifier architecture makes
word-substitution, hallucination, and prompt injection structurally
impossible, which collapses the ±1 sanity check, 900 ms timeout, 5-strike
auto-disable, and code-dictation-detection machinery into a single
design choice. V3 is out of scope for v1 — your #2 and #11 together
convinced me that V3's refinement already does most of this work and
the double-replace would regress the flagship streaming path. Eval set
is cut to 50 utterances via public-corpus synthetic-raw per your #6.
Onboarding gets a 3-transcription-delayed banner per your #12.

## which challenges I accepted

- **#1 Wrong tool.** Pivoted. Classifier replaces LLM. Size: 150 MB
  instead of 400 MB. Latency: 500 ms hard cap instead of 900 ms.
- **#2 V3 incoherence.** V3 deferred to P2, gated on a measured
  baseline (if refinement F1 < 70 % on 20 recordings, we revisit).
- **#3 Asymmetric ZH sanity check.** Moot — no sanity check needed.
- **#4 Dev-dictation rewrites.** Moot — classifier cannot recase
  `sudo` to `Sudo`. Round-trip invariant guarantees it.
- **#6 200-row eval.** Cut to 50 via LibriSpeech + AISHELL-1
  synthetic-raw + 5 hand-written Ronica code cases. Half-day to build.
- **#8 Cold start silent degradation.** Adopted your LID pattern —
  preload session 2 s post-launch if toggle is on.
- **#11 V3 double-flicker.** Resolved by punting V3, not by merging.
- **#12 Ghost feature / discovery.** Added 3-transcription-delayed
  Settings banner. Still opt-in, still off by default, but not buried.
- **Contrarian Q6 prompt injection.** Structural solution via
  classifier architecture. Logit-masked decode was the right *LLM*
  answer, but dropping the LLM is simpler.

## which I partially accepted

- **#7 Packaging cliff.** Size drops to 150 MB, which dissolves most
  of the concern. Added disk-space preflight at 2× model size. Did not
  add "Enhanced mode" umbrella toggle.
- **#9 Auto-disable ghost-failure.** Kept the mechanism but tightened:
  persistent counter, Settings-pane banner not NSAlert, hard-cap
  timeouts only count. Threshold is 10 (up from 5) because false-positive
  probability is much lower with the classifier.

## which I rejected, with reasoning

- **#5 Config cliff.** Rejected single umbrella toggle. Shipping both
  LID and cleanup, **staged**: LID first (already RDY in 096), cleanup
  second. Each has a distinct user-visible tradeoff (LID is about
  *which* language, cleanup is about *formatting*). Hiding them behind
  one switch makes honest opt-in decisions impossible. The 16-state
  matrix is a real concern, but the answer is fewer *settings*, not
  fewer *toggles collapsed into one*. I'm willing to defend this in
  round 2 if you still object.
- **#10 AuxiliaryModel registry refactor.** Verified in
  `Murmur/Services/ModelManager.swift` lines 115–181. The enum already
  carries per-case `modelRepo`, `modelSubdirectory`, `requiredDiskSpace`,
  `sizeDescription`, `allowPatterns`, `requiredFiles`. Per-aux state is
  already dictionary-keyed at lines 234–238. Adding a second case is
  ~30 lines. The only genuinely missing behaviour is a shared download
  mutex — that's a `DispatchSemaphore` in `ModelManager`, not a
  refactor. Registry abstraction is a premature generalisation at N=2.
  Revisit at N=3.

## open questions for round 2 (in the spec)

1. Dual-model vs. single multilingual for EN+ZH — acceptable fallback
   to EN-only v1 if no single model clears the bar?
2. Deterministic casing (sentence-initial + gazetteer) vs. a true-case
   model — good enough for v1?
3. Onboarding nudge at 3 transcriptions — better threshold?
4. Disk preflight at 2× model size — honest or overkill?

## ask

Round-2 challenge on 095 (v2). Focus on: (a) the classifier-model
choice and dual-model fallback, (b) the config-cliff rejection, (c)
the AuxiliaryModel "no refactor needed" call. If you LGTM, I hand off
to UX for the Settings banner + download-row treatment, and to QA for
the 50-utterance fixture.

## out

Status: **REQ** to DA. Expected turnaround: one round of challenges,
then RDY-or-revise.
