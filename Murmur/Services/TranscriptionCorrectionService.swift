import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Protocol

/// Corrects likely ASR errors (homophones, phonetic mistranscriptions) in a
/// raw transcription while preserving the original meaning. Also inserts
/// appropriate punctuation and sentence-initial casing so the output reads
/// as a well-formed sentence. Never translates — code-switched utterances
/// (English technical terms inside Chinese speech, etc.) must stay
/// code-switched.
///
/// Runs BEFORE `TranscriptionCleanup` in the coordinator pipeline:
///   `transcribe → correction → cleanup → inject`
/// Cleanup is a deterministic safety net for when correction is off or times
/// out; when correction runs and adds its own punctuation, cleanup is a no-op.
///
/// Implementations MUST be safe to time out: the coordinator enforces a hard
/// deadline and falls back to the raw text on any throw. The concrete Apple
/// Foundation Models implementation targets ≤ 2.5 s on M-series Macs; Intel
/// Macs and pre-macOS-26 systems fall through to the `NoOpCorrector` which
/// returns the input unchanged.
protocol TranscriptionCorrection: Sendable {
    /// Correct likely ASR errors in `text`.
    ///
    /// - Parameters:
    ///   - text: The raw transcription as emitted by the ASR engine.
    ///   - language: BCP-47 primary language code (e.g. `"en"`, `"zh"`).
    /// - Returns: The corrected transcription, or the original `text` when the
    ///   correction would violate a safety rail.
    /// - Throws: Any error from the backing model. The caller is expected to
    ///   catch and silently fall back to `text`.
    func correct(_ text: String, language: String) async throws -> String
}

// MARK: - No-op fallback

/// Fallback used when the Foundation Models framework is unavailable (pre-macOS 26,
/// Apple Intelligence disabled, model not downloaded yet, or device not eligible).
/// Always returns input unchanged. Wired in by `MurmurApp` so the coordinator
/// `correction` slot is never nil on recent systems but still behaves safely.
actor NoOpCorrector: TranscriptionCorrection {
    func correct(_ text: String, language: String) async throws -> String {
        return text
    }
}

// MARK: - Shared prompt façade

/// Façade between callers (the two corrector backends) and the user's
/// optional Settings overrides.
///
/// `defaultSystemPrompt` is the built-in prompt — also the seed for the
/// editable Settings field. `current` reads the user override, falling back
/// to the default when unset or whitespace-only. `currentGlossary()` parses
/// the comma-separated glossary the user enters in Settings.
enum CorrectionPrompts {

    /// `UserDefaults` key for the editable system-prompt override.
    static let systemPromptKey = "correctionSystemPrompt"

    /// `UserDefaults` key for the comma-separated glossary text.
    static let glossaryKey = "correctionGlossary"

    /// Built-in default prompt. The user can override it from Settings; an
    /// empty / whitespace-only override falls back here, so users who never
    /// touch Settings see this prompt verbatim.
    static let defaultSystemPrompt: String = """
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
    """

    /// Effective system prompt. Returns the trimmed user override when
    /// non-empty, else the built-in default. Both correctors call this on
    /// every correction so changes in Settings take effect immediately.
    static var current: String {
        let raw = UserDefaults.standard.string(forKey: systemPromptKey) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultSystemPrompt : trimmed
    }

    /// Effective glossary as a normalised list. Returns the user-entered
    /// terms with surrounding whitespace trimmed and empty entries dropped.
    /// Empty when the user has not set a glossary.
    ///
    /// Accepts both ASCII `,` and full-width `，` (U+FF0C) as separators —
    /// CJK IMEs frequently emit the full-width form, and a user pasting from
    /// a Chinese-language source would otherwise see the entire glossary
    /// silently collapse to one term.
    static func currentGlossary() -> [String] {
        let raw = UserDefaults.standard.string(forKey: glossaryKey) ?? ""
        let normalised = raw.replacingOccurrences(of: "，", with: ",")
        return normalised
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Safety rails (shared)

/// Rules every corrector applies to its candidate output before returning.
/// Exposed as a free function so both the Foundation Models path and future
/// local-LLM paths can use the same guard.
enum CorrectionSafetyRails {
    /// Maximum ratio between the corrected and the raw text length. A generative
    /// model that "corrects" a 10-character utterance into 60 characters is
    /// almost certainly hallucinating — fall back to raw. Bumped from 1.5× to
    /// 1.6× once the correction step started inserting punctuation: a short
    /// 10-char English utterance with three inserted commas + a period + two
    /// capitalisation tweaks can legitimately push past 1.5×.
    static let maxLengthRatio: Double = 1.6

    /// Minimum ratio — protect against pathological truncation.
    static let minLengthRatio: Double = 0.5

    /// Substrings that indicate a model refusal or meta-commentary rather than
    /// a plain correction. Matched case-insensitively as substrings anywhere in
    /// the output. The Apple model is trained to refuse sensitive prompts; we
    /// don't want those refusals leaking into the user's text.
    static let refusalMarkers: [String] = [
        "i cannot",
        "i can't",
        "i'm sorry",
        "sorry, i",
        "i apologize",
        "as an ai",
        "抱歉",     // sorry (zh)
        "我不能",    // I cannot (zh)
        "无法",     // unable (zh) — broad but any legitimate transcription containing 无法 is rare
    ]

    /// Validate a candidate correction against the raw text. Returns
    /// `candidate` if it passes all rails, otherwise `raw`.
    static func validate(candidate: String, raw: String) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty output → fall back.
        guard !trimmed.isEmpty else { return raw }

        // Length ratio guard. We use Character count, not byteCount, so Chinese
        // (where one character = one "word") and English score comparably.
        let rawCount = max(raw.count, 1)
        let ratio = Double(trimmed.count) / Double(rawCount)
        guard ratio <= maxLengthRatio && ratio >= minLengthRatio else { return raw }

        // Refusal / meta-commentary guard.
        let lower = trimmed.lowercased()
        for marker in refusalMarkers where lower.contains(marker.lowercased()) {
            return raw
        }

        return trimmed
    }
}

// MARK: - Apple Foundation Models implementation

#if canImport(FoundationModels)

/// On-device correction powered by Apple's system language model (macOS 26+).
/// Requires Apple Intelligence to be enabled; degrades gracefully via
/// `isAvailable` — `MurmurApp` should only wire an instance in when this is
/// true, otherwise use `NoOpCorrector`.
@available(macOS 26.0, *)
actor FoundationModelsCorrector: TranscriptionCorrection {
    private static let log = Logger(subsystem: "com.murmur.app", category: "correction")

    /// A cached session is tempting for latency, but each session carries a
    /// growing transcript of prior prompts+responses that biases subsequent
    /// calls. We instantiate a fresh session per correction so every input
    /// starts from the same priors — the cost is a single `init` per call,
    /// which is small relative to the inference latency budget.
    private var hasPrewarmedOnce = false

    /// Returns true if Apple Intelligence is installed, enabled, and the model
    /// is ready to serve. Called by `MurmurApp` at wire-up time to decide
    /// between this corrector and `NoOpCorrector`.
    static var isSystemModelAvailable: Bool {
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
    }

    /// Build a fresh session for a single correction call. The first call in
    /// the app lifecycle also prewarms the underlying model so subsequent
    /// calls hit warm weights.
    /// Build a session with the user's currently-effective system prompt.
    /// `CorrectionPrompts.current` is read per call so a Settings edit takes
    /// effect on the next correction without app restart. Safety rails
    /// (length ratio, refusal markers, empty output) are enforced post-hoc
    /// in `CorrectionSafetyRails`.
    private func makeSession() -> LanguageModelSession {
        let session = LanguageModelSession(
            model: .default,
            instructions: CorrectionPrompts.current
        )
        if !hasPrewarmedOnce {
            session.prewarm()
            hasPrewarmedOnce = true
        }
        return session
    }

    func correct(_ text: String, language: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        // Very short utterances (< 4 characters) are rarely "correctable" and
        // an LLM at this length is almost guaranteed to over-produce.
        guard trimmed.count >= 4 else { return text }

        let session = makeSession()

        let glossary = CorrectionPrompts.currentGlossary()
        let glossaryLine = glossary.isEmpty ? "(none)" : glossary.joined(separator: ", ")
        let prompt = """
        Language: \(language)
        Glossary: \(glossaryLine)
        Raw transcription: \(trimmed)
        """

        // Debug log — symmetric with OpenAICompatibleCorrector. Confirms
        // language + glossary made it into the user message. View with
        // `log stream --predicate 'subsystem == "com.murmur.app" AND
        // category == "correction"' --level debug`.
        let trimmedPreview = String(trimmed.prefix(200))
        let systemPreview = String(CorrectionPrompts.current.prefix(120))
            + (CorrectionPrompts.current.count > 120 ? "…" : "")
        Self.log.debug("""
        correction[apple] outgoing → on-device
          language=\(language, privacy: .public)
          glossary=[\(glossaryLine, privacy: .public)]
          rawIn=\"\(trimmedPreview, privacy: .public)\" (len=\(trimmed.count, privacy: .public))
          system=\"\(systemPreview, privacy: .public)\"
          user=\"\(prompt, privacy: .public)\"
        """)
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0.0,
            maximumResponseTokens: Self.maxTokensFor(inputLength: trimmed.count)
        )

        let response = try await session.respond(to: prompt, options: options)
        let candidate = response.content
        let validated = CorrectionSafetyRails.validate(candidate: candidate, raw: trimmed)

        // Diagnostic logging — promoted to .public so `log stream --predicate
        // 'subsystem == "com.murmur.app" AND category == "correction"'` shows
        // the full pipeline. Previews are capped at 120 chars to keep Console
        // readable; longer payloads are fine in the debugger.
        let rawPreview = String(trimmed.prefix(120))
        let candidatePreview = String(candidate.prefix(120))
        let validatedPreview = String(validated.prefix(120))
        let outcome: String
        if validated == candidate && validated != trimmed {
            outcome = "accepted-changed"
        } else if validated == candidate && validated == trimmed {
            outcome = "accepted-unchanged"
        } else if validated == trimmed {
            outcome = "rejected-by-safety-rails"
        } else {
            // Validated was whitespace-trimmed from candidate; still accepted.
            outcome = "accepted-trimmed"
        }
        Self.log.info("""
        correction [\(outcome, privacy: .public)] \
        raw=\"\(rawPreview, privacy: .public)\" \
        candidate=\"\(candidatePreview, privacy: .public)\" \
        final=\"\(validatedPreview, privacy: .public)\" \
        rawLen=\(trimmed.count, privacy: .public) \
        candLen=\(candidate.count, privacy: .public) \
        finalLen=\(validated.count, privacy: .public)
        """)

        // Preserve the original leading/trailing whitespace so downstream
        // cleanup sees a shape consistent with the raw input.
        if trimmed != text {
            // Find leading and trailing whitespace from the original.
            let leading = text.prefix { $0.isWhitespace || $0.isNewline }
            let trailing = text.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed()
            return String(leading) + validated + String(trailing)
        }
        return validated
    }

    /// Response token budget capped to the input size × 1.3 (rounded up) to
    /// discourage the model from expanding the text. Floor of 20 so very
    /// short inputs still have headroom for punctuation-adjacent fixes.
    private static func maxTokensFor(inputLength: Int) -> Int {
        let budget = Int((Double(inputLength) * 1.3).rounded(.up))
        return max(20, budget)
    }
}

#endif
