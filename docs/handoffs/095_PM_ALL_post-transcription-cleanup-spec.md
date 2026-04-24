---
from: PM
to: ALL
pri: P2
status: RDY
created: 2026-04-25
refs: 080, 091, 096, 097, 100, 102
---

## v3 changelog (2026-04-25)

Addresses DA CHG:1 in 102 (4 items) and restructures delivery into two
phased ships rather than one big classifier drop.

**CHG:1 items — all accepted:**

1. **ZH coverage honesty.** Primary candidate switched to
   `kredor/punctuate-all` (genuinely multilingual incl. ZH, ~180 MB Q8).
   Fallback = dual-head (EN `fullstop-multilang` + ZH-capable head) at
   ~300 MB total, with honest Settings copy. Spike (v0.3.1) decides;
   download-size copy is re-done then.
2. **Proper-noun gazetteer dropped.** Casing pass is sentence-initial
   only. `python` stays `python`, `sudo` stays `sudo`. Revisit only
   if dogfood raises it, and only behind a token-boundary safety rule.
3. **Onboarding threshold = 10.** Aligned to `V1UsageCounter.discoveryThreshold = 10`
   at `Murmur/Services/StreamingTranscriptionCoordinator.swift:253`.
4. **Rule-based option acknowledged** in "out of scope" (see below).

**Phased delivery (new in v3):**

- **v0.3.0 (tonight's branch `feat/post-transcription-cleanup`).**
  Ship the plumbing, toggle, service protocol, download wiring, and a
  **rule-based EN baseline** (sentence-initial case + terminal period
  if missing). ZH = passthrough (raw). This is **transitional, not
  final.** Ships so the feature exists in the app and its scaffolding
  is review-able independently of model work.
- **v0.3.1 (follow-up branch).** Swap the rule-based engine for the
  real ONNX classifier (`kredor/punctuate-all` pending spike) +
  SentencePiece tokenizer. ZH coverage lands here. No user-facing UX
  change beyond output quality and a model download.

EN is green-lit to ship the baseline as v1 per 103. Classifier as v2.

---

## problem

Cohere Transcribe output is faithful to what was said, which means it
is often unpunctuated, inconsistently cased, and visually raw when
pasted into email, Slack, or a doc. Users who speak in complete
sentences still get `hello how are you doing today` — then fix it by
hand. The friction is small per-instance but chronic, and it undermines
the "text appears at your cursor and you're done" promise that makes
voice input feel faster than typing.

## success metric

**v0.3.0 (rule-based EN baseline).**

- Primary (quantitative): on 25 EN utterances from the eval fixture,
  cleaned output matches reference at **≥ 75 % punctuation-token F1**
  (rule-based floor — sentence-initial case + terminal period is a
  coarse pass; F1 is a sanity gate, not a quality bar) AND
  **100 % non-punctuation-character round-trip** (enforced by
  construction — rules only uppercase the first letter and append a
  period if absent).
- ZH: **no regression** vs. raw — toggle is no-op on ZH input.
- Secondary (UX): p95 record-stop → paste **stays under 2.3 s** on
  M2 Air. Rule-based pass runs in < 5 ms; budget is all session /
  paste-path overhead.
- Tertiary (adoption): N/A for v0.3.0 — dogfood-only; quality is known
  to be a floor not a ceiling.

**v0.3.1 (classifier).** ≥ 92 % punct-F1 bilingual on the 50-utterance
eval set. Classifier-F1 < 85 % blocks ship.

## scope (v0.3.0 — ships on this branch)

1. **`TranscriptionCleanup` protocol** (async, takes raw text + resolved
   language code, returns cleaned text). Injected into `AppCoordinator`
   alongside `lid`. Not part of the `TranscriptionService` protocol.
2. **`PunctuationCleanupService` actor** implementing the protocol.
   v0.3.0 implementation = **rule-based EN baseline**:
   - If language is EN (or unresolved but ASCII-dominant): uppercase
     first alphabetic char of the first word; append `.` to the trimmed
     end if the last non-whitespace char is not already in `.!?`.
   - If language is ZH or anything else: return input unchanged.
   - Hard cap 50 ms. Timeout ⇒ return raw.
3. **Opt-in Settings toggle "Polish transcription"**, default off.
   Not in the Experimental section. Toggle copy (v0.3.0):
   *"Adds a period and sentence-initial capitalisation to English
   transcriptions. Chinese support coming in a follow-up."*
   Toggle is always enabled in v0.3.0 (no download required for rules).
4. **AuxiliaryModel enum scaffolding.** Add `case cleanupPunctuation`
   with placeholder repo/subdirectory/size fields commented `// v0.3.1`.
   The download path is not exercised in v0.3.0; the enum case exists
   so the v0.3.1 swap is a diff, not a new feature.
5. **V1 integration.** `PunctuationCleanupService` called from V1
   full-pass after-transcribe, before inject. V3 coordinator is not
   modified. Toggle is a no-op when V3 is the active backend; Settings
   copy: *"Active in standard mode. Streaming mode already includes
   punctuation via refinement."* (Same as v2 spec.)
6. **Failure is never fatal.** Service throws / times out ⇒ inject raw,
   log at `.public`. Persisted consecutive-failure counter in
   `UserDefaults`. Auto-disable after **10 consecutive timeouts or
   throws**. Surfaces as a persistent Settings banner, no NSAlert.
   (Rule-based pass is unlikely to hit this; the machinery exists for
   v0.3.1.)
7. **Onboarding nudge.** After **10 successful transcriptions**
   (cumulative, `UserDefaults`, matches `V1UsageCounter.discoveryThreshold`),
   show a one-time Settings-pane banner:
   *"Turn on Polish transcription to auto-capitalise and add periods to
   English transcriptions."* Dismissable. No banner if toggle is already
   on or feature was explicitly dismissed.
8. **No preload needed in v0.3.0.** No model, no ONNX session. The
   2-s-post-launch preload hook lands in v0.3.1.

## scope (v0.3.1 — follow-up branch, not this ship)

Swap rule-based engine for the real classifier. Everything scaffolded
in v0.3.0 stays; only the `PunctuationCleanupService` body and the
`AuxiliaryModel.cleanupPunctuation` metadata change.

1. ONNX classifier — candidate `kredor/punctuate-all`, Q8, ~180 MB.
   Spike confirms before EN commits.
2. SentencePiece (BPE) tokenizer — net-new work; LID's Whisper BPE
   cannot be reused wholesale. Budget a day.
3. Download flow via `AuxiliaryModel.cleanupPunctuation`. Serial
   download mutex + 1.5× disk preflight in `ModelManager` (DA #7 +
   answer to Q4 in 102).
4. ZH support. Chinese punctuation labels map to `，。？！「」：；`.
5. Preload on launch 2 s post-idle, same pattern as LID.
6. Hard cap tightened to 500 ms (model-path budget).
7. Settings copy rewritten: download size honest ("~180 MB" if single
   model; "~300 MB total" if dual-head). Final wording picked after
   spike result.
8. Eval gate: ≥ 85 % bilingual F1 blocks ship; ≥ 92 % is the target.

## out of scope (defer)

- **Rule-based-only-forever as the feature.** Considered and rejected:
  a pure-rules approach (sentence-boundary heuristics + gazetteer)
  would land ~85 F1 on English but structurally cannot do ZH (no word
  boundaries, no pause-as-clause-boundary signal), so shipping two
  different architectures for EN and ZH doubles maintenance surface
  for marginal savings. Rules are the v0.3.0 baseline, not the v1.
- **Proper-noun gazetteer.** Dropped per DA CHG:1 #2 — silently
  regresses `python` → `Python`, `sudo` → `Sudo`. Reintroduces the
  exact failure mode DA round-1 #4 was about.
- Disfluency removal. **P2**, post-classifier ship.
- Grammar and spelling correction. **P3.**
- Style adapters. **Icebox.**
- Full rewrite. **Won't do.**
- Languages beyond EN + ZH. **P2.**
- Per-chunk streaming cleanup. **Won't do.**
- V3 cleanup. **Deferred**, gated on measured V3 refinement baseline.
- Telemetry for adoption metric. **Defer.** Dogfood for v1.
- Code-dictation detection. **Won't do** — moot because the classifier
  cannot rewrite `sudo rm -rf`, and the v0.3.0 rule-based pass only
  touches the first char and the trailing punctuation position.

## user flow

**First use v0.3.0 (via banner).** After 10 successful transcriptions,
user sees the Settings-pane banner. Clicks "Enable". Toggle flips on
(no download). Next EN transcription arrives with a leading capital
and a trailing period.

**First use v0.3.0 (via Settings).** User toggles "Polish transcription".
Same effect, no download prompt.

**Steady state EN.** "hello how are you doing today" → `Hello how are
you doing today.` (No comma in v0.3.0 — that waits for the classifier.)

**Steady state ZH.** Toggle on, user speaks Chinese. Input returned
unchanged. Settings copy already says ZH is coming.

**V3 user.** Toggle no-op, Settings copy explains why.

**Failure.** Raw text injected, `.public` log entry. After 10 consecutive
failures, auto-disable + Settings banner.

**v0.3.1 first use.** Toggle on ⇒ one-time ~180 MB (or ~300 MB)
download. Post-download, EN quality rises to ≥ 92 F1 and ZH starts
working. No UX change beyond download prompt + output quality.

## technical constraints

- **Privacy.** Fully on-device. No network in v0.3.0 (no model). No
  network at inference in v0.3.1 (one-time HF download only).
- **Latency.** v0.3.0 hard cap **50 ms** (rules are ~1 ms).
  v0.3.1 hard cap **500 ms**.
- **Size.** v0.3.0: 0 MB. v0.3.1: ~180 MB (single) or ~300 MB (dual),
  confirmed post-spike.
- **RAM.** v0.3.0: negligible. v0.3.1: ≤ 300 MB peak, unload on sleep.
- **Backend compatibility.** `TranscriptionCleanup` protocol +
  `PunctuationCleanupService` actor. Injected into `AppCoordinator`.
  Not in `TranscriptionService`.
- **V1-only integration** both versions.
- **Language plumbing.** Receives resolved language code from the
  existing resolver.
- **AuxiliaryModel enum.** `case cleanupPunctuation` added in v0.3.0
  with placeholder metadata; populated in v0.3.1. `DispatchSemaphore`
  download mutex and 1.5× preflight land in v0.3.1 alongside the
  actual download.

## model choice recommendation (v0.3.1 only)

**Primary candidate: `kredor/punctuate-all`** (XLM-R-based, 12 langs
including ZH, ~180 MB Q8 after conversion). Chosen over
`oliverguhr/fullstop-punctuation-multilang-large` because the latter
explicitly does not cover ZH and forces a dual-head ~300 MB ship that
contradicts honest download-size copy.

**Fallback: dual-head** — `fullstop-multilang` for EN/DE/FR/IT/NL +
a ZH-capable head (e.g. a bert-base-chinese punctuation fine-tune).
Ships only if `punctuate-all` clears < 85 F1 on either language. Copy
becomes "~300 MB total" honestly.

**Casing (v0.3.1).** Deterministic sentence-initial + post-punctuation
only. **No proper-noun gazetteer** per DA CHG:1 #2.

**Tokenizer.** SentencePiece (BPE). Separate from LID's Whisper BPE.
Budget a full day of EN work; not a 2-hour reuse.

**Quantisation.** Measure Q8 vs FP16 in spike — Q8 on XLM-R-base
sometimes costs 2–4 F1 points.

**Not recommended:** any generative LLM (wrong tool, DA #1), Silero
Punc (EN-only), Apple Foundation Models (macOS 15+ gate).

## eval set (v0.3.1 gate; partial use in v0.3.0)

**50 utterances total, assembled now, reused for v0.3.0 smoke + v0.3.1
gate.**

- 25 EN from LibriSpeech dev-clean. Target: punctuated reference;
  raw = stripped + lowercased.
- 20 ZH from AISHELL-1 dev. Same procedure.
- 5 hand-written code-dictation cases from Ronica's history
  (`sudo rm -rf`, `pip install numpy`, `git checkout -b feature/foo`,
  one with quoted strings, one with dashes). Target: round-trips
  character-for-character, only a trailing period allowed.

**v0.3.0 uses only 25 EN + 5 code** (ZH is passthrough, not meaningful
to measure). Rule-based baseline is expected to land ~60–75 F1 on EN;
that is acceptable for v0.3.0. **v0.3.1 full gate:** ≥ 85 F1 bilingual
to ship, ≥ 92 F1 target.

Owner: QA assembles the full 50-utterance JSON fixture as a one-shot
during the v0.3.0 branch (half-day), so v0.3.1 spike can hit the
ground running.

For the spike itself (v0.3.1, not a ship gate) DA recommends expanding
to 200 public-corpus utterances if the top-2 candidates are within 3 F1.
Ship gate stays at 50.

## open questions

None open. DA round-2 answered all four (102); accepted as written.

## rough size estimate

**v0.3.0: S — tonight / this branch.** Rule-based engine + protocol +
toggle + enum scaffolding + onboarding counter is a day of EN work.
QA fixture assembly runs in parallel.

**v0.3.1: M — 2–3 weeks.** Per DA's honest estimate in 102:
- Best case 2 weeks (model picked day 1, tokenizer smooth, F1 clears).
- Expected 3 weeks (SentencePiece is net-new, Q8 costs 1–2 F1).
- Risk 4 weeks (dual-head needed, Settings copy rework).

Staged after LID ships. Own release slot, not bundled.

## out

Status: **RDY** for EN on v0.3.0 (this branch). See 103 for the EN
green-light handoff.

v0.3.1 re-enters the loop as a new spec/spike once v0.3.0 ships and
the classifier work starts. DA LGTM on v0.3.1 is contingent on the
spike measuring ZH coverage honestly before EN commits to a model.
