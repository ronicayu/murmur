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
    ///   - apiKey: optional bearer token. nil for keyless local servers.
    ///   - session: injectable for tests; defaults to `.shared`.
    init(
        baseURL: URL,
        modelName: String,
        apiKey: String? = nil,
        session: URLSession = .shared
    ) {
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

        let glossary = CorrectionPrompts.currentGlossary()
        let request = try Self.makeRequest(
            baseURL: baseURL,
            modelName: modelName,
            apiKey: apiKey,
            language: language,
            glossary: glossary,
            trimmed: trimmed
        )

        // Debug log of the outgoing request — useful for verifying that the
        // glossary actually reaches the server and the prompt looks right.
        // Stream with: `log stream --predicate 'subsystem == "com.murmur.app"
        // AND category == "correction"' --level debug`. The transcript,
        // glossary and prompt are user content and are logged `.private`:
        // they show as <private> unless private logging is enabled on the Mac.
        Self.logOutgoingRequest(request: request, language: language, glossary: glossary, trimmed: trimmed)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MurmurError.transcriptionFailed("Local LLM: non-HTTP response")
        }
        guard http.statusCode == 200 else {
            // The body can echo the request, so it stays out of the thrown
            // error (the coordinator logs that publicly).
            let bodySnippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            Self.log.error("correction[local] HTTP \(http.statusCode, privacy: .public): \(bodySnippet, privacy: .private)")
            throw MurmurError.transcriptionFailed("Local LLM HTTP \(http.statusCode)")
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
    ///
    /// `glossary` is a normalised list of speaker-specific terms — see
    /// `CorrectionPrompts.currentGlossary()`. An empty list renders as
    /// `Glossary: (none)` in the user message so the system-prompt rule
    /// degrades gracefully when the user has not entered terms.
    static func makeRequest(
        baseURL: URL,
        modelName: String,
        apiKey: String?,
        language: String,
        glossary: [String],
        trimmed: String
    ) throws -> URLRequest {
        let endpoint = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The request carries the transcript, and the reply is typed into
        // the user's app: neither may cross the network in clear text.
        guard isPrivateConnection(to: baseURL) else {
            throw MurmurError.transcriptionFailed(
                "Local LLM: refusing to send the transcript over an unencrypted connection. Use an https:// base URL, or http:// to this Mac."
            )
        }
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Token cap: budget ≈ ⌈chars × 1.6⌉. OpenAI's `max_tokens` is output
        // tokens, which roughly matches character count for mixed CJK+Latin
        // instruction-tuned models; safety rails on length ratio are the real
        // guard, this is just a guardrail against runaway generations.
        let maxTokens = max(64, Int((Double(trimmed.count) * 1.6).rounded(.up)))

        let glossaryLine = glossary.isEmpty ? "(none)" : glossary.joined(separator: ", ")
        let userContent = """
        Language: \(language)
        Glossary: \(glossaryLine)
        Raw transcription: \(trimmed)
        """

        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "system", "content": CorrectionPrompts.current],
                ["role": "user", "content": userContent]
            ],
            "stream": false,
            "temperature": 0.0,
            "max_tokens": maxTokens,
            // Disable "thinking" / chain-of-thought on Qwen3 / DeepSeek-R1 / o1-style
            // reasoning variants. Without this, those models return their answer in
            // `message.reasoning` and leave `message.content` null, which our parser
            // reads as empty → safety-rail falls back to the raw transcription
            // (silent regression: punctuation never gets added). Backends that don't
            // honour this kwarg (Ollama, plain llama.cpp) ignore it harmlessly.
            "chat_template_kwargs": ["enable_thinking": false]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Whether the transcript and the API key may be sent to `baseURL`: only
    /// over https, or over plain http to this machine (the documented Ollama /
    /// LM Studio setup). Anything else would put them on the network in clear
    /// text, where anyone on the same Wi-Fi could read the transcript and
    /// change the reply that Murmur types.
    static func isPrivateConnection(to baseURL: URL) -> Bool {
        switch baseURL.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            // `URL.host` reports an IPv6 literal with or without brackets
            // depending on the OS version.
            let host = (baseURL.host ?? "").lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return ["localhost", "127.0.0.1", "::1"].contains(host)
        default:
            return false
        }
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

    /// Prints the outgoing chat-completion payload at `.debug` level so power
    /// users can verify the system prompt and glossary line. Truncates the
    /// system prompt preview because users typically only want to confirm
    /// length / overall shape, not re-read the full body each time. Only
    /// lengths and the language code are public.
    private static func logOutgoingRequest(
        request: URLRequest,
        language: String,
        glossary: [String],
        trimmed: String
    ) {
        let endpoint = request.url?.absoluteString ?? "<no url>"
        let glossaryPreview = glossary.isEmpty ? "(none)" : glossary.joined(separator: ", ")
        let trimmedPreview = String(trimmed.prefix(200))

        var systemPreview = "<missing>"
        var userPreview = "<missing>"
        if let body = request.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let messages = json["messages"] as? [[String: String]] {
            if let sys = messages.first(where: { $0["role"] == "system" })?["content"] {
                systemPreview = String(sys.prefix(120)) + (sys.count > 120 ? "…" : "")
            }
            if let usr = messages.first(where: { $0["role"] == "user" })?["content"] {
                // User message is short enough to log in full — that is the
                // line where Glossary needs to be visible to the LLM.
                userPreview = usr
            }
        }

        log.debug("""
        correction[local] outgoing → \(endpoint, privacy: .private)
          language=\(language, privacy: .public)
          glossary=[\(glossaryPreview, privacy: .private)]
          rawIn=\"\(trimmedPreview, privacy: .private)\" (len=\(trimmed.count, privacy: .public))
          system=\"\(systemPreview, privacy: .private)\"
          user=\"\(userPreview, privacy: .private)\"
        """)
    }

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
        raw=\"\(rawPreview, privacy: .private)\" \
        candidate=\"\(candidatePreview, privacy: .private)\" \
        final=\"\(finalPreview, privacy: .private)\" \
        rawLen=\(raw.count, privacy: .public) \
        candLen=\(candidate.count, privacy: .public) \
        finalLen=\(final.count, privacy: .public)
        """)
    }

}
