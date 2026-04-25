import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Protocol

/// Corrects likely ASR errors (homophones, phonetic mistranscriptions) in a
/// raw transcription while preserving the original meaning. Distinct from
/// `TranscriptionCleanup` which only handles punctuation and casing — this
/// layer actually rewrites words / characters.
///
/// Runs BEFORE `TranscriptionCleanup` in the coordinator pipeline:
///   `transcribe → correction → cleanup → inject`
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

// MARK: - Safety rails (shared)

/// Rules every corrector applies to its candidate output before returning.
/// Exposed as a free function so both the Foundation Models path and future
/// local-LLM paths can use the same guard.
enum CorrectionSafetyRails {
    /// Maximum ratio between the corrected and the raw text length. A generative
    /// model that "corrects" a 10-character utterance into 60 characters is
    /// almost certainly hallucinating — fall back to raw.
    static let maxLengthRatio: Double = 1.5

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

    /// Instructions given to every session. Tightly scoped so the model
    /// behaves like a surgical transcript editor, not a rewriter.
    private static let instructions = """
    You are a transcript editor. Input is a single utterance produced by an \
    automatic speech recognizer that may contain homophone mistakes, phonetic \
    misspellings, or minor character substitutions.

    Your only job:
    - Correct obvious ASR mistakes (wrong homophones, typos, wrong Chinese characters).
    - Preserve the user's original meaning, tone, and word choice.
    - Do NOT add information the user did not say.
    - Do NOT rephrase, summarize, shorten, or expand the text.
    - Do NOT add punctuation or casing changes — that is handled downstream.
    - If the input looks correct or you are unsure, return it unchanged.

    Output ONLY the corrected text. No quotes, no commentary, no explanation.
    """

    /// Bound to `SystemLanguageModel.default` so we share the warm instance
    /// with any other Murmur consumer.
    private var session: LanguageModelSession?

    /// Returns true if Apple Intelligence is installed, enabled, and the model
    /// is ready to serve. Called by `MurmurApp` at wire-up time to decide
    /// between this corrector and `NoOpCorrector`.
    static var isSystemModelAvailable: Bool {
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
    }

    /// Lazily create (and prewarm) the session on first use.
    private func ensureSession() -> LanguageModelSession {
        if let session { return session }
        let newSession = LanguageModelSession(
            model: .default,
            instructions: Self.instructions
        )
        // Prewarm on init so the first real call is fast.
        newSession.prewarm()
        session = newSession
        return newSession
    }

    func correct(_ text: String, language: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        // Very short utterances (< 4 characters) are rarely "correctable" and
        // an LLM at this length is almost guaranteed to over-produce.
        guard trimmed.count >= 4 else { return text }

        let session = ensureSession()

        let prompt = "Language: \(language)\nRaw transcription: \(trimmed)"
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0.0,
            maximumResponseTokens: Self.maxTokensFor(inputLength: trimmed.count)
        )

        let response = try await session.respond(to: prompt, options: options)
        let candidate = response.content
        let validated = CorrectionSafetyRails.validate(candidate: candidate, raw: trimmed)

        if validated != trimmed {
            Self.log.info("correction: \(trimmed.count, privacy: .public) → \(validated.count, privacy: .public) chars")
        }

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
