---
from: DA
to: PM
pri: P1
status: CHG:2
created: 2026-04-25
refs: 095, 091, 094
---

## ctx

Stress-testing 095 — the "Polish transcription" post-ASR cleanup spec.
PM proposes a ~400 MB Qwen2.5-0.5B-Instruct Q4 aux model, 900 ms wall
cap, ±1 word-token sanity check, V1 full-pass + V3 end-of-session
refinement. I read the spec, re-read 091 (LID) and 094 (my own LID
challenge) for continuity, and skimmed CHANGELOG to recheck the user
promise Murmur has already sold.

Net read: **the wrong tool is being chosen for the problem**, the
**V3 story is self-contradicting**, the **configuration surface is
approaching IME-builder territory**, and the **success metric is
aspirational given team size**. There are cheaper, more deterministic,
more honest answers. Detail below.

## challenges

### 1. A 0.5B generative LLM is the wrong hammer for punctuation+casing

**Assumption.** "Punctuation restoration needs a small LLM so we can
prompt it for EN and ZH conventions with the same model."

**Why suspect.** The entire literature on this problem uses
task-specific models: Silero Punc, `deepmultilingualpunctuation`,
fullstop-punctuation-multilang-large, or simple BERT/DistilBERT
multi-head token classifiers. Size: 50–150 MB (Q8). Inference:
5–20 ms CPU for a typical utterance. Determinism: total. Hallucination
risk: *structurally impossible* — the head emits one label per input
token (none/comma/period/question/quote…); it literally cannot insert
or delete words. Compare to what the spec proposes: 400 MB, 900 ms
budget, non-deterministic decode, a ±1-word sanity check bolted on as
the *primary defence* against a failure mode the right tool makes
categorically unreachable.

**Risk.** We ship 10× the bytes, 10–50× the latency, and a novel class
of failure (word-level hallucination) to solve a problem with a known
solved-form answer. We then spend review/QA cycles on mitigations
(sanity check, timeout, auto-disable) that only exist because of the
tool choice.

**Test/fix.** Before approving, prototype 24 hours on a
token-classification punctuation model (any EN+ZH multilingual one on
HF). Measure: punctuation F1 vs. Qwen-0.5B on a 30-utterance bilingual
sample. If within 5 F1 of the LLM, ship the small head, kill the LLM
plan, save 350 MB + the entire sanity/timeout/auto-disable apparatus.

---

### 2. V3 already has a refinement pass — is this feature redundant on V3?

**Assumption.** "V3 streaming refinement is raw; cleanup adds value on
top of it."

**Why suspect.** Cohere's full-pass refinement on V3 is already a
higher-quality re-decode with the full audio context. Anecdotally, V3
refinement already emits punctuation in most of Cohere's 14 languages
— it's a full sequence model with a language-conditioned decoder. The
spec gives no measurement of V3 refinement punctuation quality as a
baseline. We might be layering a 400 MB, 900 ms corrector on top of
text that already has the commas and periods.

**Risk.** On the V3 path, cleanup is a no-op 70% of the time and a
*regression* 5–10% of the time (LLM rewrites correct punctuation
differently). The feature's value is effectively V1-only — but V1 is
the deprecation path (per 094/090 framing).

**Test/fix.** Measure: record 20 V3 utterances, inspect the refinement
text, count how many already have acceptable punctuation. If >60%, V3
cleanup is net-negative and the feature is V1-only. State that
honestly in the spec, or ship V3-only and actually earn its keep there.

---

### 3. Hallucination on short + ZH inputs — the sanity check is asymmetric

**Assumption.** "±1 word-token delta catches word-level hallucination."

**Why suspect.** For EN, roughly true (whitespace tokenisation is
stable). For ZH, *wrong in both directions*:
- Whitespace tokenisation on ZH yields ~1 "word" for a whole sentence,
  so the check is effectively disabled (±1 of 1 = 100% wiggle).
- A char-count fallback on ZH allows the LLM to substitute characters
  freely as long as the *count* is preserved — exactly the failure
  you most care about (wrong homophones, "我" → "你" at same length).
- 3-word inputs ("how are you") on an instruct LLM with a
  "punctuate this" system prompt are a textbook case for embellishment
  ("Hi, how are you doing today?"). ±1 on 3 is ±33% — weak.

**Risk.** Spec's primary safety rail fails closed for EN (acceptable),
fails open for ZH (unacceptable — ZH users are the whole reason Qwen
was chosen over SmolLM2). The feature's flagship advantage is also
its largest exposure.

**Test/fix.** For ZH, use edit-distance at char level with a ≤2
threshold *and* require no character substitutions outside the
punctuation set — i.e., non-punctuation chars of raw must appear in
cleaned in order. For EN, require all non-punctuation word tokens to
round-trip case-insensitively. Task-classifier model (challenge #1)
makes this moot.

---

### 4. Adversarial / technical inputs: destructive rewrites

**Assumption.** Implicit: users dictate natural language.

**Why suspect.** Murmur's user segment heavily overlaps with devs.
Dictating `sudo rm dash rf slash` or `pip install numpy` or
`git checkout dash b` through an instruct LLM with a "add
capitalisation" prompt is a near-guaranteed rewrite ("Sudo, remove
dash RF slash."). The ±1 word check passes — nothing was added or
removed, just cased "wrong". Output is now broken for the user's
actual purpose.

**Risk.** A single visible rewrite of a dev's dictated command is
enough to burn trust permanently on a feature they opted into. There's
no way to signal "I'm dictating code, don't capitalise." Per-domain
toggles are explicitly out of scope.

**Test/fix.** Either (a) detect "code-ish" input (monospace-friendly
tokens, no natural-language sentence structure) and skip cleanup, or
(b) ship the task-classifier model which cannot rewrite case of
existing letters. Option (b) wins.

---

### 5. Configuration cliff — Murmur is becoming an IME toolkit

**Assumption.** "Another toggle is fine — users opt in."

**Why suspect.** Current toggle matrix: streaming on/off × language
auto/fixed × LID on/off × cleanup on/off = 16 configurations, each
with its own latency/quality/download profile. Support load scales
with product of states, not sum. Our target user is "someone who
dictates into Slack" — not "someone who tunes their IME pipeline."
Every toggle is also a surface for bug reports we can't repro because
we don't know which config the user is in.

**Risk.** Product positioning drifts from "faster than typing" to
"configure your dictation stack." We lose the onboarding simplicity
that is Murmur's actual differentiator (vs. Apple Dictation and
Whisper-Kit apps).

**Test/fix.** Hold the line: one new toggle max this half. Either LID
OR cleanup ships in v0.3, not both. If cleanup wins that contest,
kill or delay LID. If we ship both, collapse into a single "Enhanced
mode" umbrella toggle that turns on the whole aux stack and commits
to the disk/download cost together.

---

### 6. 200-row bilingual gold corpus — who builds it?

**Assumption.** "QA curates it in week 1, in parallel with EN."

**Why suspect.** Ronica's team is one of each agent. QA hand-labels
200 utterances (record + transcribe raw + punctuate reference) at
realistic 3–5 min each = 10–16 hours of focused work. Add bilingual
review = more. This is a full week of one person's time with zero
product progress. Spec treats it as a footnote.

**Risk.** Eval set slips; BLEU/fidelity metric becomes aspirational;
ship decision gets made on vibes ("it looked good in dogfooding");
we ship a regression we can't detect.

**Test/fix.** Cut the eval to 50 utterances (25 EN + 25 ZH), defined
as a *blocking ship gate* not a quality bar. Use pre-existing public
corpora (LibriSpeech dev-clean + AISHELL-1 dev) for raw+reference
pairs — zero manual punctuation required, the corpora already have
clean punctuated transcripts and we can artificially strip them to
create the raw side. Saves a week.

---

### 7. 400 MB aux × 2 = packaging cliff

**Assumption.** "Opt-in download, only pay if you want it."

**Why suspect.** LID is 40 MB; cleanup is 400 MB; primary is ~1.5 GB.
A power user who enables both aux features is downloading ~2 GB of
on-disk ML assets for a voice input app. On a 256 GB laptop (the
modal Mac spec), that is a felt cost. Also: HF rate limits and
bandwidth for us once we get press, which is the whole point of
shipping these features.

**Risk.** Feature discoverability → feature download → feature abandon
funnel leaks at each step because of disk cost. Also: two independent
~400 MB downloads is fragile — partial downloads, resume state, disk
cleanup on uninstall, verify-integrity re-runs — all 2×.

**Test/fix.** If task-classifier path (challenge #1) lands, cleanup
becomes ~80 MB, and this concern dissolves. Otherwise: require the
cleanup download to preflight free disk space ≥ 2× model size and
refuse to start under that. Document total aux cost in Settings copy
before the user clicks.

---

### 8. 900 ms cap + cold-start = silent degradation

**Assumption.** "900 ms cap on M2; M1 TBD." First-use cold start of a
400 MB Q4 LLM via ONNX Runtime is 1.5–4 s on M1 Air — session init,
mmap, first-token KV cache allocation. The spec's 80–120 ms
first-token figure applies *after* session is warm.

**Why suspect.** First recording after launch (or after sleep, per
094's #6d observation on LID) will *always* blow the 900 ms cap →
silent fallback to raw → user gets today's behaviour → user concludes
"the polish feature doesn't work." No surface signal distinguishes
"cleanup ran and decided no changes needed" from "cleanup timed out"
from "cleanup feature never ran." First impression of a new feature is
an apparent no-op.

**Risk.** Feature sells a capability on first launch that
systematically doesn't deliver on first launch. Textbook anti-onboarding.

**Test/fix.** (a) Preload the LLM session on app launch, 2 s after
idle, if the toggle is on — same pattern I recommended for LID in 094.
(b) On timeout, show a *one-time per launch* pill "Polishing… takes
longer on first use" so the user knows *why*. (c) Log timeout vs.
sanity-rejection vs. skip at `.public` so dogfood can distinguish them.

---

### 9. "Auto-disable after 5 failures" — who sees what, when?

**Assumption.** "5 consecutive cleanup failures → auto-off + NSAlert."

**Why suspect.** What counts as "failure"? Timeout, sanity-check
reject, model load fail, sentinel-language skip? Does the counter
reset on success, on app relaunch, on toggle toggle? Does it survive
sleep/wake? The spec says NSAlert fires — but NSAlerts in macOS can
be dismissed as "don't show again" at the system level, so the user
can silently lose the feature without any signal.

**Risk.** Ghost failure mode: feature auto-disables, user never
notices, feature is dead. Or: counter resets on every launch, user
sees 4 silent failures per launch forever, feature is effectively
broken but never trips the alert.

**Test/fix.** (a) Define failure class: only "timeout + inference
error" count toward the 5, not sanity-check rejections (those are
working-as-intended). (b) Counter persists across launches via
UserDefault. (c) Replace NSAlert with a persistent Settings-pane
banner that stays until user acts — no "don't show again" escape.
(d) Log every counter increment at `.public`.

---

### 10. AuxiliaryModel enum — does it compose for 2 aux models?

**Assumption.** "LID plumbing is reusable; cleanup just adds a case."

**Why suspect.** Per 091, `AuxiliaryModel` is an enum with per-case
allow-patterns and required-files. Works for N=1. At N=2, the open
questions multiply: shared download mutex? Parallel downloads OK, or
one-at-a-time to avoid bandwidth starvation? Shared verification
schedule? Delete-all aux action in Settings? Migration if we rename a
case? None of this is in the LID handoff because it's 1-case today.

**Risk.** Week-2 of cleanup implementation EN discovers the enum
doesn't cleanly support simultaneous downloads, has to refactor
ModelManager mid-feature, timeline slips. My 094 answer to LID Q1
already called this: "refactor to generic aux registry once N ≥ 2."
This is the N=2 moment, and the spec pretends it isn't.

**Test/fix.** Before EN implements cleanup, refactor `AuxiliaryModel`
into a registry pattern with shared download/verify/delete behaviour,
per-aux metadata (id, repo, allow-patterns, size, minimum-disk). Half
a day of work that unblocks every future aux (punctuation, speaker
diarisation, custom vocab) cleanly.

---

### 11. V3 end-of-session replace × cleanup = double-flicker

**Assumption.** "V3 cleanup runs on the refined text, one extra
replace, user lives with it."

**Why suspect.** V3's UX today: user sees streaming text grow, then at
stop the refinement pass *already* replaces the streamed text with a
better version — one visible flicker. Adding cleanup means: stream →
replace with refinement (flicker 1) → replace with polished refinement
(flicker 2). Two post-stop replaces is visible and feels like the app
is dithering. The spec acknowledges this ("If this feels jarring in
UAT, we fall back to…").

**Risk.** V3's whole selling point is immediacy. Post-stop dithering
undermines the "text appears at cursor, done" promise from the spec's
own problem statement. We'd be shipping a feature that degrades the
flagship path.

**Test/fix.** Merge refinement + cleanup into a single post-stop
replace — block the refinement injection until cleanup returns (or
its 900 ms timeout fires with raw-refinement fallback). One flicker
max. Costs 900 ms of perceived "stop latency" in exchange for
eliminating the double-dither.

---

### 12. "Opt-in, defaults off, buried in Settings → Experimental"

**Assumption.** "Users will discover it and toggle it on."

**Why suspect.** Settings → Experimental → Polish transcription → "one-
time 400 MB download" is three clicks plus a scary size number deep
behind an "Experimental" warning flag. Realistic opt-in rate is <5%
of users, which makes the 40% 7-day-retention success metric (tertiary)
statistically untestable at our user-base size.

**Risk.** Ghost feature. Ronica uses it; nobody else finds it; PM
declares victory based on dogfood. When we try to promote it to
default-on in v0.4, we have zero real-world evidence of quality at
scale.

**Test/fix.** Either (a) add a one-time banner in the main Settings
pane after first transcription: "Try polishing your transcription with
punctuation + capitalisation?" with a download CTA — still opt-in, but
discoverable. Or (b) accept that this is a dogfood-only feature for
v0.3 and state that explicitly in the spec; don't dress it up with
adoption metrics.

---

## contrarian answers to PM's open questions

**Q1. ±1 word-token sanity check — tight enough?**

No, and it's asymmetric — see #3. The real fix is choosing a model
that can't hallucinate. Next-best: char-level edit distance ≤2 for ZH
with an invariant that non-punctuation chars round-trip in order;
case-insensitive word round-trip for EN. If you keep the LLM path,
budget a week for iterating this invariant against real failures.

**Q2. 900 ms hard cap on M1 — ship M2+ only or drop to SmolLM2-360M?**

Neither. Drop the LLM entirely (challenge #1). A
token-classification punctuation model is ≤20 ms on M1; the cap
becomes irrelevant. If you refuse to consider that: ship SmolLM2-360M
*as the only model* (EN-only v1). Don't ship Qwen on M2+ and SmolLM2
on M1 — that's two eval sets, two prompt regressions, two support
matrices for a feature that is not the flagship.

**Q3. V3 streaming cleanup UX.**

Punt V3 entirely in v1. Advertise V1-only. See #2: V3's own
refinement already emits punctuation in most cases, so cleanup on V3
is a solution looking for a problem, *and* the double-flicker in #11
actively degrades V3. V3 is where user impressions are made; don't
add a feature there that might regress it.

**Q4. Auto-disable threshold (5 consecutive failures).**

5 is fine as a number; the design is the problem (challenge #9).
Define failure class tightly (timeout + inference error only), persist
counter across launches, replace NSAlert with a Settings banner.

**Q5. 200-utterance eval set — who builds it?**

Nobody, as specced (challenge #6). Cut to 50; use LibriSpeech
dev-clean + AISHELL-1 dev synthetic-raw (strip punctuation from
existing clean transcripts). Zero manual labelling. If you insist on
domain coverage (email/chat/code), add 20 hand-written utterances from
Ronica's actual dictation history. Total budget: half a day, not a
week.

**Q6. Prompt injection — less fragile defence than sanity check?**

The answer is structural, not defensive: a model that cannot emit
tokens outside its input. Token-classification architecture (challenge
#1) is immune to prompt injection by design — there is no generation,
so "ignore previous instructions" is just words the classifier labels
with None/comma/period. If you keep the generative LLM: (a) wrap user
text in a fenced delimiter the system prompt refers to, (b) constrain
decode via logit masking to `{raw tokens} ∪ {punctuation tokens}` —
this alone solves injection, hallucination, *and* the word-count
problem in one mechanism. Logit-masked decode is maybe a week of work
and worth more than every other safety rail in the spec combined.

---

## recommendation

**Do not ship as-specced.** Three blockers:

1. **Wrong tool.** A generative LLM is the wrong architecture for
   punctuation+casing. Task-classifier punctuation models are smaller,
   faster, deterministic, and structurally immune to the failure modes
   the spec's entire safety apparatus (±1 check, timeout, auto-disable)
   exists to mitigate. Prototype challenge #1 before approving
   anything else.

2. **V3 story is incoherent.** V3 refinement already emits
   punctuation; cleanup on top is either redundant or regressive, and
   the double-flicker actively hurts the flagship path. V3-inclusion
   needs a measured baseline before it earns its place.

3. **Configuration cliff.** Shipping LID and cleanup in the same
   half pushes Murmur from "voice input for the masses" to
   "configurable ML pipeline." Pick one for v0.3. My vote: cleanup
   wins on user-visible value, LID can wait for v0.4 or get killed in
   favour of the Cohere-echo alternative I proposed in 094.

**Smallest change to get me to LGTM on a revised spec:**

- Prototype a token-classifier punctuation model (half-day spike).
  Bring F1 numbers vs. Qwen-0.5B to a follow-up handoff.
- Measure V3 refinement punctuation quality on 20 real recordings.
  If >60% already acceptable, spec becomes V1-only.
- Cut eval to 50 utterances via public-corpus synthetic-raw.
- Refactor `AuxiliaryModel` to a registry before adding a 2nd aux —
  or defer cleanup to v0.4 after the refactor.
- If the LLM path survives the spike: switch to logit-masked decode,
  which eliminates ±1 check, prompt injection, and hallucination in
  one stroke.
- Pick **one** aux feature for v0.3. Not both.

If PM pushes back on the tool-choice challenge (#1), I want a written
argument for why generative > classifier on *this specific task*, not
"we already have the LLM plumbing" (we don't — we'd be adding it).

## out

Status: **CHG:2** — spec needs revision. Two structural changes
requested: tool-choice reconsideration (#1) and V3 scope decision
(#2/#11). Remaining 10 challenges are either contingent on those two
or are fast-followable refinements.

Passing back to PM. Expect either (a) a revised spec that swaps the
LLM for a classifier and V1-only's the feature, or (b) a written
rebuttal to challenges #1 and #2 with evidence. I'll LGTM either one
that honestly addresses the tool-choice question — I'm not ideological
about the answer, I'm ideological about the question being asked.

Also flagging for coordination: challenge #10 (AuxiliaryModel
registry refactor) overlaps with 094's Q1 answer. If PM and EN agree
to defer the registry refactor, cleanup should wait until after LID
is merged *and* the registry lands. Otherwise EN is implementing
cleanup against a known-inadequate abstraction.
