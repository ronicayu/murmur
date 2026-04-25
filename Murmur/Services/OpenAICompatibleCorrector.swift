import Foundation
import os

/// `TranscriptionCorrection` that talks to any server exposing an
/// OpenAI-compatible `POST /v1/chat/completions` endpoint. Works with
/// Ollama (`http://localhost:11434/v1`), LM Studio (`http://localhost:1234/v1`),
/// llamafile, vLLM, and any hosted OpenAI-shape proxy — the user supplies
/// the base URL and model name in Settings.
///
/// The corrector never streams and uses `temperature = 0` for determinism;
/// safety rails (length ratio, refusal markers, empty output) are applied
/// to the returned text just like the Apple on-device path.
actor OpenAICompatibleCorrector: TranscriptionCorrection {
    static let log = Logger(subsystem: "com.murmur.app", category: "correction")

    let baseURL: URL
    let modelName: String
    /// Optional bearer token for hosted endpoints. nil for local servers.
    let apiKey: String?
    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: the endpoint root (e.g. `http://localhost:11434/v1`).
    ///     `chat/completions` is appended by this class.
    ///   - modelName: the model identifier the server recognises.
    ///   - apiKey: nil for local servers; set for hosted OpenAI-compatible providers.
    ///   - session: injectable for tests; defaults to `.shared`.
    init(baseURL: URL, modelName: String, apiKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.modelName = modelName
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Protocol

    func correct(_ text: String, language: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard trimmed.count >= 4 else { return text }

        let request = try Self.makeRequest(
            baseURL: baseURL,
            modelName: modelName,
            apiKey: apiKey,
            language: language,
            trimmed: trimmed
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MurmurError.transcriptionFailed("Local LLM: non-HTTP response")
        }
        guard http.statusCode == 200 else {
            let bodySnippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw MurmurError.transcriptionFailed("Local LLM HTTP \(http.statusCode): \(bodySnippet)")
        }

        let candidate = try Self.parseChatResponse(data: data)
        let validated = CorrectionSafetyRails.validate(candidate: candidate, raw: trimmed)

        Self.logOutcome(raw: trimmed, candidate: candidate, final: validated)

        // Preserve original leading/trailing whitespace — matches
        // FoundationModelsCorrector so downstream code sees consistent shape.
        if trimmed != text {
            let leading = text.prefix { $0.isWhitespace || $0.isNewline }
            let trailing = text.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed()
            return String(leading) + validated + String(trailing)
        }
        return validated
    }

    // MARK: - Request construction (testable)

    /// Builds the `POST {baseURL}/chat/completions` request body. Broken out
    /// from `correct` so tests can assert payload shape without a live server.
    static func makeRequest(
        baseURL: URL,
        modelName: String,
        apiKey: String?,
        language: String,
        trimmed: String
    ) throws -> URLRequest {
        let endpoint = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Token cap: budget ≈ ⌈chars × 1.6⌉. OpenAI's `max_tokens` is output
        // tokens, which roughly matches character count for mixed CJK+Latin
        // instruction-tuned models; safety rails on length ratio are the real
        // guard, this is just a guardrail against runaway generations.
        let maxTokens = max(64, Int((Double(trimmed.count) * 1.6).rounded(.up)))

        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": "Language: \(language)\nRaw transcription: \(trimmed)"]
            ],
            "stream": false,
            "temperature": 0.0,
            "max_tokens": maxTokens
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Parse an OpenAI-compatible non-streaming chat completion response.
    static func parseChatResponse(data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let first = decoded.choices.first else {
            throw MurmurError.transcriptionFailed("Local LLM: empty choices array")
        }
        return first.message.content
    }

    // MARK: - Logging

    private static func logOutcome(raw: String, candidate: String, final: String) {
        let outcome: String
        if final == candidate && final != raw {
            outcome = "accepted-changed"
        } else if final == candidate && final == raw {
            outcome = "accepted-unchanged"
        } else if final == raw {
            outcome = "rejected-by-safety-rails"
        } else {
            outcome = "accepted-trimmed"
        }
        let rawPreview = String(raw.prefix(120))
        let candidatePreview = String(candidate.prefix(120))
        let finalPreview = String(final.prefix(120))
        log.info("""
        correction[local] [\(outcome, privacy: .public)] \
        raw=\"\(rawPreview, privacy: .public)\" \
        candidate=\"\(candidatePreview, privacy: .public)\" \
        final=\"\(finalPreview, privacy: .public)\" \
        rawLen=\(raw.count, privacy: .public) \
        candLen=\(candidate.count, privacy: .public) \
        finalLen=\(final.count, privacy: .public)
        """)
    }

    // MARK: - Prompt

    static let systemPrompt = """
    You are a dictation post-processor. The input is a single utterance from \
    a speech recognizer with no punctuation. You MUST return the same \
    utterance with punctuation inserted and minor transcription errors fixed.

    You MUST do these things on every input:
    - Insert punctuation between clauses and at the end of sentences.
    - For CHINESE text you MUST use FULL-WIDTH punctuation only:
        comma → ， (NOT the ASCII , )
        period → 。 (NOT the ASCII . )
        question → ？ (NOT the ASCII ? )
        exclamation → ！ (NOT the ASCII ! )
        semicolon → ； colon → ：
      Examples (input → output):
        "我今天去北京开会然后吃了麻辣烫" → "我今天去北京开会，然后吃了麻辣烫。"
        "你好你叫什么名字" → "你好，你叫什么名字？"
        "对不起我不知道" → "对不起，我不知道。"
    - For ENGLISH text use ASCII punctuation: . , ? ! ; :
      Examples:
        "hello how are you" → "Hello, how are you?"
        "i went to the store and bought milk" → "I went to the store and bought milk."
    - Capitalise the first letter of each English sentence.
    - Fix obvious homophone or wrong-character errors when confident:
        "write" vs "right"; "名子" vs "名字"; "北经" vs "北京"

    You MUST NOT do any of these:
    - Translate anything. If the user said an English word, it stays in \
      English with the exact same letters. If the user said a Chinese \
      character, it stays in Chinese. Code-switched utterances (English \
      technical terms, brand names, library names, identifiers embedded \
      in Chinese speech, or vice versa) must stay code-switched. Never \
      replace `Python` with `派森`; never replace `北京` with `Beijing`.
    - Use ASCII punctuation in Chinese text. `,` is wrong in Chinese — \
      always use `，`. `.` is wrong in Chinese — always use `。`.
    - Add words or meaning the user did not say.
    - Delete words or phrases the user said.
    - Rewrite for style, tone, or clarity beyond punctuation and casing.

    The output length in characters MUST be close to the input length — \
    typically within ±20% when punctuation is the main change.

    Return ONLY the corrected sentence. No quotes, no commentary, no \
    explanation, no prefixes, no "Here is" lines.
    """
}
