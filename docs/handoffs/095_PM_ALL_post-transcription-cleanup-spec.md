---
from: PM
to: ALL
pri: P2
status: CHG:1
created: 2026-04-25
refs: 080, 091, 096, 097
---

## changelog (v2, 2026-04-25)

Revised after DA's CHG:2 challenge in 097. Summary of what changed:

- **Pivot to a token-classification punctuation+casing model.** Replaces
  the 400 MB generative Qwen2.5-0.5B. New primary: a BERT-family
  multilingual punctuation head (~150 MB Q8 on disk, ~10–30 ms inference).
  Rationale is architectural, not cosmetic: a classifier literally cannot
  insert, delete, or substitute words, so the ±1 sanity check, prompt
  injection defence, 900 ms timeout rail, auto-disable-on-failure, and
  "dev dictates `sudo rm -rf` → LLM rewrites it" concerns all collapse
  into a single design choice.
- **V3 is explicitly out of scope for v1.** Cleanup runs only on V1
  full-pass output. Rationale in "scope" #6 — V3's own full-pass
  refinement already emits punctuation in most cases per DA #2, and the
  double-replace would visibly degrade Murmur's streaming flagship.
- **Eval set cut from 200 to 50 utterances.** Built from public corpora
  (LibriSpeech dev-clean EN + AISHELL-1 dev ZH, synthetic-raw by
  stripping punctuation) plus up to 10 hand-written dev-dictation
  utterances from Ronica's history. Half-day to assemble, not a week.
- **Onboarding surfacing.** Added a one-time post-install nudge after
  the user's first successful transcription, inline with the main
  Settings pane. Still opt-in, still off by default, but discoverable
  (addresses DA #12 "ghost feature").
- **LID/cleanup sequencing.** Both ship in v0.3, but staged: LID first
  (already RDY per 096), cleanup second. A single "Enhanced mode"
  umbrella toggle is rejected — each has its own quality/size/latency
  profile and honest users deserve the separate switch.

**DA challenges accepted:** #1 (tool choice), #2 (V3 scope), #3
(asymmetric sanity check — moot after pivot), #4 (dev rewrites — moot),
#6 (eval size), #8 (cold start — preload on launch), #12 (discovery
nudge), contrarian answer Q6 (structural > defensive for injection —
solved by pivot).

**DA challenges partially accepted:** #7 (aux packaging — size drops
from 400 MB to ~150 MB, which dissolves the worst of it). #9 (auto-
disable — kept but tightened, see scope #8). #11 (V3 flicker — resolved
by punting V3, not by merging flickers).

**DA challenges rejected:** #5 (config cliff — ship both, staged; one
umbrella toggle hides honest tradeoffs from users). #10
(AuxiliaryModel registry refactor — verified in `ModelManager.swift`:
the enum already carries per-case `modelRepo`, `modelSubdirectory`,
`requiredDiskSpace`, `sizeDescription`, `allowPatterns`, `requiredFiles`;
per-aux state is already dictionary-keyed. Adding a second case is
~30 lines. Registry abstraction is a premature generalisation at N=2
and buys nothing v1 needs. Revisit at N=3).

---

## problem

Cohere Transcribe output is faithful to what was said, which means it
is often unpunctuated, inconsistently cased, and visually raw when
pasted into email, Slack, or a doc. Users who speak in complete
sentences still get `hello how are you doing today` — then fix it by
hand. The friction is small per-instance but chronic, and it undermines
the "text appears at your cursor and you're done" promise that makes
voice input feel faster than typing. Ronica's ask — "use a small but
good model to improve the result" — is satisfied by the smallest,
fastest, most deterministic model that can do the job. That model is a
token-classification punctuation head, not a generative LLM.

## success metric

Primary (quantitative): on a 50-utterance bilingual eval set (25 EN +
25 ZH, public-corpus synthetic-raw — see "eval set" below), the cleaned
output matches the reference at **≥ 92 % punctuation-token F1** AND
**100 % non-punctuation-character round-trip** (the classifier
architecture guarantees the second; we assert it as a regression gate).
If F1 falls below 85 % after prompt/model iteration, the feature does
not ship.

Secondary (UX): p95 end-to-end latency (record-stop → paste) **stays
under 2.3 s** on an M2 Air for a 10 s utterance — i.e. ≤ 300 ms
incremental over today's raw baseline. Inference is expected to be
well under 50 ms; the 300 ms budget is session-load + tokenise +
detokenise + paste-path overhead.

Tertiary (adoption): **≥ 50 % of dogfood team keeps the toggle on
after 7 days.** No external telemetry required for v1 — team of six
plus Ronica is the sample.

## scope (v1)

1. **Punctuation + casing only**, emitted by a token-classification
   head. The model predicts one label per input token from
   {None, Comma, Period, Question, Exclamation, Quote, Colon,
   Semicolon, Apostrophe} and a parallel case label from
   {Lower, UpperInitial, UpperAll}. No token generation. No
   substitution. Non-punctuation characters of the input are preserved
   byte-for-byte except for casing changes.
2. **Languages: English + Chinese (Simplified).** Chosen model is
   multilingual (candidates in "model choice" below). Chinese
   punctuation labels map to `，。？！「」：；` as appropriate.
3. **Opt-in toggle in Settings → "Polish transcription"**, defaults
   **off**. **Moved out of the Experimental section** — the feature is
   deterministic and low-risk per the architecture, so the Experimental
   warning copy is dishonest. Toggle is disabled until the aux model is
   downloaded.
4. **Download flow** uses the existing `AuxiliaryModel` enum. Add
   `case cleanupPunctuation`. Per-aux state dictionaries
   (`auxiliaryStates`, `auxiliaryProgress`, etc.) already handle N ≥ 2
   with no change. Add a serial download mutex in `ModelManager` so
   two aux downloads cannot race. Preflight disk-space check at 2 ×
   model size before starting (addresses DA #7).
5. **Runs synchronously** between transcribe and inject on V1
   full-pass. Soft budget **200 ms**, hard cap **500 ms**. On hard-cap
   hit, inject raw and log at `.public`.
6. **V3 streaming is out of scope for v1.** V3's full-pass refinement
   already emits punctuation in most cases (per DA #2), and a second
   post-stop replace would degrade the streaming UX. V3 cleanup is
   P2, gated on a measured baseline: if refinement punctuation F1 on
   20 real recordings < 70 %, we revisit. Until then, toggle is a no-op
   when V3 is the active backend, with Settings copy: *"Active in
   standard mode. Streaming mode already includes punctuation via
   refinement."*
7. **Pipes the resolved language code** (from IME/LID resolver) into
   the classifier's language token. Unknown/unsupported → skip cleanup,
   inject raw.
8. **Failure is never fatal.** Model missing, load error, inference
   error, or hard-cap timeout all fall through to raw text. Counter
   persists across launches in `UserDefaults`. Auto-disable after
   **10 consecutive hard-cap timeouts or load failures** (sanity
   rejections do not count — there are no sanity rejections with a
   classifier). Auto-disable surfaces as a persistent banner in the
   Settings pane, not an NSAlert — no "don't show again" escape hatch.
9. **Preload on app launch.** If toggle is on, load the ONNX session
   2 s after launch idle, same pattern as LID. First-recording cold
   start must not blow the 500 ms cap.
10. **Onboarding surfacing.** After the user's first three successful
    transcriptions (cumulative across sessions), show a one-time
    Settings-pane banner: *"Add punctuation + capitalisation
    automatically? One-time ~150 MB download."* Dismissable. No banner
    if toggle is already on or feature was explicitly dismissed.

## out of scope (defer)

- Disfluency removal. **P2**, post-v1 ship.
- Grammar and spelling correction. **P3** — needs a generative model
  with tight guardrails; we are explicitly not going there in v1.
- Style adapters. **Icebox.**
- Full rewrite. **Won't do.** Violates "don't change the user's voice."
- Languages beyond EN + ZH. **P2.**
- Per-chunk streaming cleanup. **Won't do.**
- V3 cleanup. **Deferred**, see scope #6.
- Telemetry for adoption metric. **Defer.** Dogfood-based for v1.
- Code-dictation detection. **Won't do** — moot because a classifier
  cannot rewrite `sudo rm -rf` into `Sudo, remove RF`. It can only add
  a period at the end, which is correct behaviour.

## user flow

**First use (onboarded via banner).** After 3 successful transcriptions,
user sees the Settings-pane banner. Clicks "Enable". Download begins
(~150 MB, ~30–60 s on fast Wi-Fi). Toggle flips on automatically when
ready. First polished transcription arrives ~200 ms slower than raw.

**First use (via Settings).** User navigates to Settings → Polish
transcription. Sees: *"Adds punctuation and fixes casing. Deterministic,
on-device, one-time ~150 MB download."* Clicks "Download". Same flow.

**Steady state.** User presses Right Command, speaks "hello how are
you doing today", releases. Raw transcription returns in ~1.8 s.
Classifier runs for ~20 ms + session overhead. `Hello, how are you
doing today?` is injected at cursor. No visible pause increment.

**V3 user.** Toggle is on but user is on V3 streaming. Text streams
as today. Refinement replaces at stop as today. No cleanup pass.
Settings copy explains why.

**Failure.** Raw text injected silently, `.public` log entry written.
If 10 consecutive hard-cap timeouts, toggle auto-disables; Settings
banner surfaces until dismissed.

**Toggle off.** Zero cleanup code runs. Model remains on disk unless
user deletes it from Settings.

## technical constraints

- **Privacy.** Fully on-device. ONNX Runtime via existing Swift bindings.
  No network at inference. One-time HF download.
- **Latency.** Hard cap **500 ms** (down from 900 ms — the classifier is
  an order of magnitude faster). Measured in CI integration test on a
  synthetic fixture.
- **Size.** ~150 MB Q8 ONNX on disk. Shown to user before download.
- **RAM.** Loaded model ≤ 300 MB peak. Unload on sleep, same hook as LID.
- **Backend compatibility.** New `TranscriptionCleanup` protocol +
  `PunctuationCleanupService` actor. Injected into `AppCoordinator`
  alongside `lid`. Not in the `TranscriptionService` protocol.
- **V1-only integration.** Called from V1 full-pass after-transcribe,
  before inject. V3 coordinator is not modified.
- **Language plumbing.** Receives resolved language code from the
  existing resolver.
- **License.** Candidate models are Apache-2.0 or MIT (see "model
  choice"). No Llama / Gemma license friction.
- **AuxiliaryModel enum.** Add `case cleanupPunctuation`. Add a
  `DispatchSemaphore`-backed serial download mutex in `ModelManager`
  around `downloadAuxiliary`. Preflight disk check. No registry
  refactor. Revisit at N=3.

## model choice recommendation

**Primary: `oliverguhr/fullstop-punctuation-multilang-large` converted
to ONNX, Q8 (~150 MB).** XLM-RoBERTa base, supports EN + DE + FR + IT
+ NL; published F1 ~92 on English benchmarks. Chinese coverage is
weak — we will need to pair or swap for ZH (see fallback).

**Chinese head: `deepmultilingualpunctuation/kredor-punctuate-all`**
or similar BERT-multilingual Chinese-capable variant. If a single
model that does both at acceptable quality is available post-spike,
prefer that. A half-day spike by EN before full implementation
confirms the model choice — this is the one prototype we insist on.

**Casing.** If the chosen model only predicts punctuation, casing is a
second deterministic pass (sentence-initial + post-period + proper-noun
gazetteer for top-200 English names — cheap, no ML). Fallback: a tiny
secondary BERT head for `truecase` on EN only.

**Not recommended:**
- Any generative LLM. Rejected per DA #1 — wrong tool.
- Silero Punc — English-only, pushes us to two models for ZH.
- Apple Foundation Models — macOS 15+ gate; our floor is Sonoma.

## eval set

**50 utterances total.**

- 25 EN from LibriSpeech dev-clean. Take the punctuated reference as
  the target; strip punctuation + lowercase to synthesise "raw" input.
- 20 ZH from AISHELL-1 dev. Same procedure.
- 5 hand-written code-dictation cases from Ronica
  (`sudo rm -rf`, `pip install numpy`, `git checkout -b feature/foo`,
  one command with quoted strings, one with dashes). Target: raw
  round-trips character-for-character, only adding a trailing period
  if the user paused at the end. The classifier's round-trip invariant
  means this should pass by construction.

Owner: QA spends a half-day assembling the fixture JSON.
Blocking gate: below 85 % F1 after iteration, we do not ship.

## open questions for DA round 2

1. **Dual-model vs. single multilingual model for EN+ZH.** Spike is in
   EN's lap (half-day). If a single model at ≥ 88 F1 on both is
   available, we ship it. If not, we ship EN-only in v1 and defer ZH
   to a v1.1. DA: is this an acceptable fallback, or is ZH-from-day-one
   a hard requirement?
2. **Casing strategy.** Deterministic rules (sentence-initial +
   post-punctuation) cover 95 % of English capitalisation needs. Proper
   nouns beyond that rely on a fixed gazetteer. Is this good enough, or
   do we need a true-case model? I claim yes for v1.
3. **Onboarding nudge threshold (3 successful transcriptions).** Too
   eager and users dismiss before forming an opinion; too late and they
   never see it. 3 is a guess. DA: better number?
4. **Disk-space preflight at 2 × model size.** Standard practice, but
   the 2× is rule-of-thumb. Is 1.5× more honest? The download is
   atomic-rename so we don't actually need 2×.

## rough size estimate

**S–M — 1 to 2 weeks** from spec-approved to ship.

- Day 1: EN spike on 2–3 candidate models. Pick primary. Convert to
  ONNX if needed.
- Week 1: `TranscriptionCleanup` protocol, `PunctuationCleanupService`,
  `AuxiliaryModel.cleanupPunctuation` case, download mutex, preflight
  check, Settings UI, V1 integration, onboarding banner, auto-disable
  counter + banner. Parallel: QA assembles the 50-row fixture (half a day).
- Week 2 (buffer): CR + DA review, QA eval-set pass, UT dogfood,
  prompt iteration (minimal — no prompts in a classifier), ship.

No 3rd week needed because the safety-rail complexity of v1 is gone.

## out

Status: **CHG:1**. Awaiting DA round-2 on the four open questions
above. Will LGTM-or-revise as needed, then hand off to UX for the
Settings-banner and download-row treatment, and in parallel to QA for
the 50-utterance fixture assembly. Cleanup ships after LID (which is
RDY in 096) — staged, not bundled.
