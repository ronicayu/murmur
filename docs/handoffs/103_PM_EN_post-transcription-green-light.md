---
from: PM
to: EN
pri: P2
status: RDY
created: 2026-04-25
refs: 095, 097, 100, 102
---

## ctx

v3 spec (095) is `RDY`. DA CHG:1 in 102 addressed in-spec. Scope split
into **v0.3.0 (this branch) = rule-based EN baseline + full scaffolding**
and **v0.3.1 (follow-up) = ONNX classifier + SentencePiece + ZH**.

Branch: `feat/post-transcription-cleanup` off `feat/lid-whisper-tiny`
(current working branch — already checked out in the repo).

Green light on v0.3.0. Ship the baseline as v1, classifier lands as v2
in a follow-up branch. The rule-based pass is explicitly transitional —
name the service and types as if the classifier already existed, so
v0.3.1 is a body swap, not a rename.

## scope for tonight (v0.3.0 baseline)

1. **Define `TranscriptionCleanup` protocol** (async, takes raw text +
   resolved language code, returns cleaned text). File:
   `Murmur/Services/TranscriptionCleanup.swift` (new).
2. **Implement `PunctuationCleanupService` actor** conforming to the
   protocol. v0.3.0 body = rule-based EN baseline:
   - EN (or unresolved ASCII-dominant): uppercase first alphabetic
     char of first word; append `.` to trimmed end if last non-ws char
     is not in `.!?`.
   - ZH / anything else: return input unchanged.
   - Internal hard cap 50 ms via `Task` + `Clock`; on timeout or throw,
     the caller (step 5) falls through to raw.
3. **Extend `AuxiliaryModel` enum in `ModelManager.swift`** — add
   `case cleanupPunctuation` with placeholder `modelRepo`,
   `modelSubdirectory`, `requiredDiskSpace`, `sizeDescription`,
   `allowPatterns`, `requiredFiles`. Mark each placeholder with a
   `// v0.3.1` comment. No download path exercised yet. Do not add the
   download mutex or preflight in this branch — both land in v0.3.1
   when the download is actually wired up.
4. **Inject `cleanup: any TranscriptionCleanup` into `AppCoordinator`**
   alongside the existing `lid`. Not added to `TranscriptionService`.
5. **V1 integration.** In the V1 full-pass path, after raw text is
   returned and before `TextInjectionService` is called, route through
   `cleanup.clean(text:language:)` if the toggle is on and active
   backend is V1. On any throw / timeout, inject raw and log `.public`.
   Persisted consecutive-failure counter in `UserDefaults`; auto-disable
   toggle after **10 consecutive failures**, surface via Settings banner
   (no NSAlert). V3 path unchanged.
6. **Settings toggle "Polish transcription"**, default off, outside
   the Experimental section. Copy:
   *"Adds a period and sentence-initial capitalisation to English
   transcriptions. Chinese support coming in a follow-up."*
   No download button in v0.3.0 (rules need no model).
7. **Onboarding nudge.** After **10 successful transcriptions**
   (cumulative, `UserDefaults` key — mirror
   `V1UsageCounter.discoveryThreshold = 10` at
   `Murmur/Services/StreamingTranscriptionCoordinator.swift:253` for
   consistency), show a one-time Settings-pane banner:
   *"Turn on Polish transcription to auto-capitalise and add periods
   to English transcriptions."* Dismissable; no re-show. Suppress if
   toggle is on or feature explicitly dismissed.
8. **Tests.** Unit-test `PunctuationCleanupService` over the 5 code-
   dictation cases from the v3 eval-set spec (round-trip invariant)
   plus 6–8 EN sentences (case + period). Integration smoke: V1 path
   with toggle on produces capitalised + period-terminated text.

## scope explicitly deferred to v0.3.1

- **Auto-disable counter (CR P2-D).** Persisted consecutive-failure counter in `UserDefaults`;
  auto-disable the cleanup toggle after 10 consecutive failures + surface a Settings-pane
  banner (no NSAlert). Not implemented in v0.3.0 — rule-based pass has near-zero failure rate
  so the omission is safe for the initial ship. Must land before the ONNX classifier path,
  which can produce model errors under resource pressure.
- **Onboarding nudge (CR P2-E).** One-time Settings-pane banner after 10 successful
  transcriptions (mirror `V1UsageCounter.discoveryThreshold = 10`). Text:
  *"Turn on Polish transcription to auto-capitalise and add periods to English transcriptions."*
  Dismissable; no re-show; suppressed if toggle is already on. Not implemented in v0.3.0.
- **ONNX classifier.** `kredor/punctuate-all` is the starting candidate;
  spike confirms before commit. Fallback: dual-head (~300 MB total,
  honest copy).
- **SentencePiece (BPE) tokenizer.** Net-new; budget a full day. Do
  not assume reuse from LID's Whisper BPE.
- **ZH coverage.** Lands with the classifier. v0.3.0 returns ZH input
  unchanged by design.
- **Download wiring.** Populate `AuxiliaryModel.cleanupPunctuation`
  metadata, add `DispatchSemaphore` download mutex to `ModelManager`,
  1.5× disk-space preflight, progress UI in Settings.
- **Preload on launch.** 2 s post-idle ONNX session warm, same pattern
  as LID.
- **Hard-cap tightening.** 50 ms (rules) → 500 ms (model path).
- **Eval gate.** ≥ 85 % bilingual F1 on the 50-utterance fixture
  blocks ship; ≥ 92 % is the target.
- **Settings copy rewrite.** Exact wording + download size (~180 MB
  vs. ~300 MB) chosen post-spike.

## refs

- `docs/handoffs/095_PM_ALL_post-transcription-cleanup-spec.md` (v3, RDY)
- `docs/handoffs/097_DA_PM_post-transcription-challenge.md` (round 1)
- `docs/handoffs/100_PM_DA_post-transcription-v2-revision.md` (round 2 ask)
- `docs/handoffs/102_DA_PM_post-transcription-v2-review.md` (CHG:1 addressed here)
- `Murmur/Services/ModelManager.swift` — `enum AuxiliaryModel` (add
  `case cleanupPunctuation` scaffold; metadata placeholder for v0.3.1)
- `Murmur/Services/StreamingTranscriptionCoordinator.swift:251-275` —
  `V1UsageCounter.discoveryThreshold = 10` precedent

## out

Status: **RDY**. Ship v0.3.0 when ready; file a fresh `EN_PM` handoff
on completion so PM/QA/UT can run the review cycle. v0.3.1 gets its own
spec + spike handoff after v0.3.0 lands.
