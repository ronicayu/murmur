# Design: Editable corrector prompt + glossary protection

**Status:** Draft (pending user review)
**Date:** 2026-04-25
**Branch:** feat/post-transcription-cleanup

## Problem

Users want the post-transcription corrector to:

1. **Recognise and protect domain-specific terms** (acronyms, jargon, code-switched words) instead of "fixing" them as ASR errors. Example: `k8s` should stay `k8s`, not become `kates`.
2. **Snap obvious near-miss mistranscriptions of those terms** back to the canonical spelling. Example: `奥凯阿` → `OKR`, `对其` → `对齐` when the user has declared these terms.
3. **Tweak corrector behaviour without recompiling the app** — for power users who want to refine the prompt for their own ASR / LLM combination.

The original idea — feed text context into the ASR decoder prompt to influence
style — was empirically disproved. The Cohere ASR model has a `<|startofcontext|>`
slot in the decoder prompt but the official HuggingFace processor never fills it.
A spike on `test_chinese.wav` (see `Murmur/Tests/BPEContextHintSpike.swift`,
removed) showed that splicing BPE-encoded text between `<|startofcontext|>` and
`<|startoftranscript|>` causes severe early-EOS truncation:

| Prompt                                  | Output                       | Tokens |
|-----------------------------------------|------------------------------|-------:|
| Baseline (zh, no hint)                  | `你好呀,现在可以了吗?`       | 9      |
| + matched ZH context hint               | `你好。`                     | 3      |
| + mismatched EN context hint            | `你.`                        | 2      |

The model treats non-empty context as "already-transcribed prior text" and
emits EOS prematurely. So we move the hint mechanism to post-processing,
where there is no model-side dependency.

## Scope

**In:**

- New `Glossary` field added to the user message at correction time
- `CorrectionPrompts.systemPrompt` simplified from ~145 lines to ~28 lines
- The default prompt becomes overridable via Settings
- Settings UI: multi-line editor for the prompt + comma-separated glossary text field + Reset-to-default

**Out:**

- ASR decoder prompt changes (proven non-viable — see Problem section)
- Style/register hints (descoped during brainstorm)
- Per-language glossaries (single combined list — terms are language-agnostic)
- In-app live A/B between with-hint and without-hint outputs

## Architecture

### Pipeline (unchanged at the boundaries)

```
audio → transcribe → correction → cleanup → inject
```

The `correction` step now reads three settings instead of one:

- `correctionSystemPrompt` (String, optional override; empty = use default)
- `correctionGlossary` (String, comma-separated terms; empty = "(none)")
- (existing) `correctionEnabled`, `correctionEngine`, etc.

### `CorrectionPrompts` changes

```swift
enum CorrectionPrompts {
    /// Built-in default. Becomes the seed of the editable Settings field.
    /// When the user clears the field, this is what runs.
    static let defaultSystemPrompt: String = """
    ... 28-line content (see "Default prompt" section below) ...
    """

    /// Effective system prompt. Returns trimmed user override if non-empty,
    /// else the default. Single source of truth — both correctors call this.
    static var current: String {
        let raw = UserDefaults.standard.string(forKey: "correctionSystemPrompt") ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultSystemPrompt : trimmed
    }

    /// Effective glossary as a normalised list. Empty list when the user
    /// has not entered terms.
    static func currentGlossary() -> [String] {
        let raw = UserDefaults.standard.string(forKey: "correctionGlossary") ?? ""
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
```

### User message changes

Both `OpenAICompatibleCorrector.makeRequest` and the `FoundationModelsCorrector`
prompt construction build:

```
Language: \(language)
Glossary: \(glossary.isEmpty ? "(none)" : glossary.joined(separator: ", "))
Raw transcription: \(trimmed)
```

### Settings UI

In the existing `Section("Transcription Correction")` of `SettingsView.swift`
(currently around line 310), add — under the existing Engine picker and
related fields:

1. **Glossary** — single-line `TextField`, placeholder `"OKR, shipping, 对齐, k8s"`. Bound to `correctionGlossary` `@AppStorage`.
2. **Correction prompt** — multi-line `TextEditor`, ~10 visible rows, scrollable, monospaced. Bound to `correctionSystemPrompt` `@AppStorage`.
3. **Reset to default** — button below the editor. On click, sets `correctionSystemPrompt` to `CorrectionPrompts.defaultSystemPrompt`.
4. **Character count** — small grey text below the editor (`"\(count) / 4000"`). Turns red when count exceeds 4000. No hard enforcement — power users can override.

Accessibility:

- Editor labelled "Correction prompt — advanced"
- Glossary labelled "Glossary (comma-separated)"
- Reset button has `.help("Restore the built-in default prompt")`

## Default prompt (28 lines)

```
You are a dictation post-processor. Fix punctuation and obvious
sound-alike errors in the raw transcription. Return ONLY the corrected
sentence — no quotes, no commentary, no prefixes.

Input fields:
  Language          BCP-47 code, for context.
  Glossary          comma-separated terms the speaker uses, or "(none)".
  Raw transcription text from the speech recognizer.

Rules:

1. Add punctuation between clauses and at sentence ends.
   Chinese → use full-width: ，。？！；：
   English → use ASCII: . , ? ! ; :
   Capitalise the first letter of each English sentence.
   Sentences ending in 吗 / 呢 / or starting with 什么 / 怎么 / 为什么
   / 是不是 are questions — use ？ not 。.

2. Fix words the recognizer obviously got wrong because they sound like
   the intended one (e.g. 再/在, 得/的/地, their/there/they're, write/right).
   Only when context makes the right choice unambiguous.

3. If Glossary is not "(none)", treat its entries as the authoritative
   spelling. Snap clear phonetic near-misses to the glossary entry using
   its exact casing. Leave verbatim hits untouched. Don't force a match
   when the word isn't clearly the glossary term.

4. Never translate. Code-switched words stay in their original language
   (Python stays Python, 北京 stays 北京).

5. Never paraphrase, add, or remove content. Output length must stay
   within ±20% of input.
```

## Behaviour contract

**With empty glossary:** behaviour is approximately equivalent to the current
corrector — same input/output mapping for plain Chinese / English transcription
with punctuation fixes and obvious homophone fixes. The simplified prompt may
produce slightly different choices for rare homophones (less explicit guidance),
but core behaviour is preserved. Validation is via the parity tests below.

**With non-empty glossary:**

- Verbatim hits preserved (`k8s` stays `k8s`)
- Near-miss snaps applied (`奥凯阿` → `OKR`, `对其` → `对齐`)
- Non-glossary words still handled by the general homophone rule (`再` / `在` still gets fixed even if neither is in the glossary)

The existing `CorrectionSafetyRails.validate(...)` (length ratio guard, refusal-marker guard) is unchanged.
A glossary-induced rewrite that triggers length ratio failure still falls back to raw — this is acceptable and deliberate.

## Testing

### Fixture-based regression suite

New test file `Murmur/Tests/CorrectorGlossaryTests.swift`. Categories:

1. **Default-prompt parity** (~6 fixtures, glossary empty) — assert each output:
   - contains expected punctuation marker (`。` / `.` / `?` / etc.)
   - has length within `[0.8x, 1.6x]` of raw
   - keeps a known-good content word (e.g. `北京` from input appears in output)

   Loose assertions, not exact string match — small models vary.

2. **Glossary verbatim** (~3 fixtures) — raw contains glossary term verbatim. Assert output contains the term character-for-character.

3. **Glossary near-miss** (~4 fixtures, mix ZH and EN) — raw contains a phonetic near-miss. Assert output contains the glossary term and **not** the near-miss spelling.

4. **Glossary irrelevant** (~3 fixtures) — raw contains no glossary terms. Output should match the no-glossary case.

Run against:

- `OpenAICompatibleCorrector` with a stub `URLSession` returning canned chat-completion responses (existing test pattern in `OpenAICompatibleCorrectorTests`).
- `FoundationModelsCorrector` if `FoundationModelsCorrector.isSystemModelAvailable`; otherwise skip.

The stub responses are themselves part of the test fixtures — we are testing
the **request shape** (does the user message include the glossary?) and the
**post-processing pipeline** (does the validated output flow through), not
the LLM's actual judgement. The LLM's judgement is validated subjectively (next).

### Subjective validation

After the fixture suite passes:

- Hand-test on real ASR outputs (Chinese + English) over ~1 week of normal use
- Default ON if better, OFF if regressed
- Update default value of `correctionGlossary` to remain empty in either case — only the prompt changes are persistent

## Open questions

- **None.** The original "transcriptionStyleHint ON/OFF UserDefault" is no longer needed: with the post-processing approach, the soft-fallback design means an empty glossary + default prompt = current behaviour, so no toggle is needed. Users opt in by entering glossary terms.

## Migration / rollout

- **No data migration.** New settings have empty defaults; existing users keep current correction behaviour.
- **Existing `CorrectionPrompts.systemPrompt` constant:** renamed to `defaultSystemPrompt`. All call sites in the codebase (Apple FM corrector, OpenAI-compatible corrector) are updated to read `CorrectionPrompts.current`.
- **Behavioural risk:** users on the previous (~145-line) default prompt will see slightly different correction output after this lands, because the default itself is shorter. Mitigation: parity tests above. If regression is observed in real use, the user can paste the old long prompt into the editor — that path is supported by design.

## Files touched

| File                                                          | Change                                                                                                            |
|---------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| `Murmur/Services/TranscriptionCorrectionService.swift`        | (1) `CorrectionPrompts`: rename `systemPrompt` → `defaultSystemPrompt`, add `current` + `currentGlossary()`, replace prompt with 28 lines. (2) `FoundationModelsCorrector.correct`: read `CorrectionPrompts.current` for instructions; build user message with `Glossary:` line. |
| `Murmur/Services/OpenAICompatibleCorrector.swift`             | `makeRequest`: read `CorrectionPrompts.current` for system role; build user message with `Glossary:` line.        |
| `Murmur/Views/SettingsView.swift`                             | Add Glossary `TextField`, Correction-prompt `TextEditor`, Reset button + char counter. Wire `@AppStorage`.        |
| `Murmur/Tests/CorrectorGlossaryTests.swift` (new)             | Glossary verbatim / near-miss / irrelevant / parity fixtures.                                                     |
| `Murmur/Tests/OpenAICompatibleCorrectorTests.swift`           | Update assertions on user-message body (now contains `Glossary:` line).                                           |
| `Murmur/Tests/TranscriptionCorrectionTests.swift`             | Update Foundation-Models-side user-message assertions same way.                                                   |

## Non-goals (explicit)

- We do **not** change the corrector engine selection logic.
- We do **not** add per-language glossaries — the term `OKR` works the same in both Chinese and English transcription.
- We do **not** persist the glossary as a structured list; it lives as a comma-separated `String` for UX simplicity.
- We do **not** add a "Show diff against default prompt" UI — Reset is enough.
- We do **not** add an in-app A/B toggle. Users get either current behaviour (empty fields) or hint-protected behaviour (filled fields), with no third state.
