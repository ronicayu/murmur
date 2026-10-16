import XCTest
@testable import Murmur

/// Tests for the pure request-construction and response-parsing helpers on
/// `OpenAICompatibleCorrector`. These do not hit a live server; the
/// end-to-end `correct(_:)` path is exercised via integration on a real
/// local Ollama or LM Studio instance.
final class OpenAICompatibleCorrectorTests: XCTestCase {

    // MARK: - makeRequest

    func test_makeRequest_postsToChatCompletionsOnBaseURL() throws {
        let base = URL(string: "http://localhost:11434/v1")!
        let request = try OpenAICompatibleCorrector.makeRequest(
            baseURL: base,
            modelName: "qwen2.5:3b-instruct",
            apiKey: nil,
            language: "en",
            glossary: [],
            trimmed: "hello world"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func test_makeRequest_setsJSONContentType() throws {
        let request = try OpenAICompatibleCorrector.makeRequest(
            baseURL: URL(string: "http://localhost:1234/v1")!,
            modelName: "local-model",
            apiKey: nil,
            language: "en",
            glossary: [],
            trimmed: "hello"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func test_makeRequest_omitsAuthHeader_whenApiKeyNil() throws {
        let request = try OpenAICompatibleCorrector.makeRequest(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "local-model",
            apiKey: nil,
            language: "en",
            glossary: [],
            trimmed: "hello"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func test_makeRequest_setsBearerAuth_whenApiKeyProvided() throws {
        let request = try OpenAICompatibleCorrector.makeRequest(
            baseURL: URL(string: "https://api.example.com/v1")!,
            modelName: "gpt-4o-mini",
            apiKey: "sk-test-123",
            language: "en",
            glossary: [],
            trimmed: "hello"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-123")
    }

    // MARK: - API key transport rule

    func test_isPrivateConnection_overHTTPS() {
        XCTAssertTrue(OpenAICompatibleCorrector.isPrivateConnection(to: URL(string: "https://api.example.com/v1")!))
        XCTAssertTrue(OpenAICompatibleCorrector.isPrivateConnection(to: URL(string: "HTTPS://api.example.com/v1")!))
    }

    func test_isPrivateConnection_overLoopbackHTTP() {
        for base in ["http://localhost:11434/v1", "http://LOCALHOST:1234/v1",
                     "http://127.0.0.1:11434/v1", "http://[::1]:11434/v1"] {
            XCTAssertTrue(OpenAICompatibleCorrector.isPrivateConnection(to: URL(string: base)!), base)
        }
    }

    func test_isPrivateConnection_refusesNonLoopbackHTTP() {
        for base in ["http://api.example.com/v1", "http://192.168.1.20:11434/v1",
                     "http://localhost.example.com/v1", "http://127.0.0.1.example.com/v1"] {
            XCTAssertFalse(OpenAICompatibleCorrector.isPrivateConnection(to: URL(string: base)!), base)
        }
    }

    func test_isPrivateConnection_refusesOtherSchemes() {
        XCTAssertFalse(OpenAICompatibleCorrector.isPrivateConnection(to: URL(string: "ftp://localhost/v1")!))
        XCTAssertFalse(OpenAICompatibleCorrector.isPrivateConnection(to: URL(string: "localhost:11434/v1")!))
    }

    func test_makeRequest_throws_whenTheTranscriptWouldCrossTheNetworkInClearText() {
        for apiKey in ["sk-test-123", nil] {
            XCTAssertThrowsError(try OpenAICompatibleCorrector.makeRequest(
                baseURL: URL(string: "http://192.168.1.20:11434/v1")!,
                modelName: "m",
                apiKey: apiKey,
                language: "en",
                glossary: [],
                trimmed: "hello"
            )) { error in
                guard case MurmurError.transcriptionFailed(let message) = error else {
                    return XCTFail("Expected transcriptionFailed, got \(error)")
                }
                XCTAssertTrue(message.contains("https"), "The error must tell the user what to change")
                XCTAssertFalse(message.contains("sk-test-123"), "The error must not carry the key")
            }
        }
    }

    func test_makeRequest_setsBearerAuth_overLoopbackHTTP() throws {
        let request = try OpenAICompatibleCorrector.makeRequest(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "m",
            apiKey: "sk-test-123",
            language: "en",
            glossary: [],
            trimmed: "hello"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-123")
    }

    func test_makeRequest_bodyContainsSystemAndUserMessages() throws {
        let request = try OpenAICompatibleCorrector.makeRequest(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "qwen2.5:3b-instruct",
            apiKey: nil,
            language: "zh",
            glossary: [],
            trimmed: "你好世界"
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "qwen2.5:3b-instruct")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(json["temperature"] as? Double, 0.0)

        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertTrue(messages[1]["content"]?.contains("你好世界") ?? false,
                      "User message must embed the raw utterance")
        XCTAssertTrue(messages[1]["content"]?.contains("zh") ?? false,
                      "User message must pass the language code")
    }

    func test_makeRequest_maxTokensScalesWithInputLength() throws {
        // Short input — floor of 64 tokens.
        let short = try OpenAICompatibleCorrector.makeRequest(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "m",
            apiKey: nil,
            language: "en",
            glossary: [],
            trimmed: "ok"
        )
        let shortJson = try JSONSerialization.jsonObject(with: short.httpBody!) as! [String: Any]
        XCTAssertEqual(shortJson["max_tokens"] as? Int, 64,
                       "Short inputs must clamp to the 64-token floor")

        // Long input — ceil(length × 1.6).
        let longText = String(repeating: "a", count: 100)
        let long = try OpenAICompatibleCorrector.makeRequest(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "m",
            apiKey: nil,
            language: "en",
            glossary: [],
            trimmed: longText
        )
        let longJson = try JSONSerialization.jsonObject(with: long.httpBody!) as! [String: Any]
        XCTAssertEqual(longJson["max_tokens"] as? Int, 160,
                       "Long inputs must scale max_tokens to ⌈length × 1.6⌉")
    }

    // MARK: - Glossary in user message

    func test_makeRequest_userMessage_includesGlossaryLine_whenEmpty() throws {
        let request = try OpenAICompatibleCorrector.makeRequest(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "m",
            apiKey: nil,
            language: "en",
            glossary: [],
            trimmed: "hello"
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        let userContent = try XCTUnwrap(messages[1]["content"])
        XCTAssertTrue(userContent.contains("Glossary: (none)"),
                      "Empty glossary must render as '(none)' so the prompt rule degrades gracefully")
    }

    func test_makeRequest_userMessage_includesGlossaryLine_withTerms() throws {
        let request = try OpenAICompatibleCorrector.makeRequest(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "m",
            apiKey: nil,
            language: "zh",
            glossary: ["OKR", "对齐", "k8s"],
            trimmed: "我们今天的奥凯阿"
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        let userContent = try XCTUnwrap(messages[1]["content"])
        XCTAssertTrue(userContent.contains("Glossary: OKR, 对齐, k8s"),
                      "Glossary terms must be joined with ', ' after the field label")
    }

    func test_makeRequest_systemMessage_isCurrentPrompt() throws {
        UserDefaults.standard.removeObject(forKey: CorrectionPrompts.systemPromptKey)
        let request = try OpenAICompatibleCorrector.makeRequest(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "m",
            apiKey: nil,
            language: "en",
            glossary: [],
            trimmed: "hello"
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], CorrectionPrompts.defaultSystemPrompt,
                       "System message must use CorrectionPrompts.current (default when no override)")
    }

    // MARK: - parseChatResponse

    func test_parseChatResponse_extractsAssistantContent() throws {
        let body = """
        {
          "id": "chatcmpl-abc",
          "object": "chat.completion",
          "choices": [
            {
              "index": 0,
              "message": { "role": "assistant", "content": "Hello, world." },
              "finish_reason": "stop"
            }
          ]
        }
        """.data(using: .utf8)!
        let parsed = try OpenAICompatibleCorrector.parseChatResponse(data: body)
        XCTAssertEqual(parsed, "Hello, world.")
    }

    func test_parseChatResponse_handlesOllamaV1Shape() throws {
        // Ollama's `/v1/chat/completions` matches OpenAI's shape.
        let body = """
        {
          "id": "chatcmpl-ollama",
          "object": "chat.completion",
          "created": 1730000000,
          "model": "qwen2.5:3b-instruct",
          "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": "你好世界。"},
            "finish_reason": "stop"
          }],
          "usage": {"prompt_tokens": 50, "completion_tokens": 5, "total_tokens": 55}
        }
        """.data(using: .utf8)!
        let parsed = try OpenAICompatibleCorrector.parseChatResponse(data: body)
        XCTAssertEqual(parsed, "你好世界。")
    }

    func test_parseChatResponse_throwsOnEmptyChoices() {
        let body = #"{"choices": []}"#.data(using: .utf8)!
        XCTAssertThrowsError(try OpenAICompatibleCorrector.parseChatResponse(data: body))
    }

    func test_parseChatResponse_throwsOnMissingMessage() {
        let body = #"{"choices": [{"index": 0}]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try OpenAICompatibleCorrector.parseChatResponse(data: body))
    }

    // MARK: - correct(): bearer token and error text

    func test_correct_sendsTheExplicitKeyAsABearerToken() async throws {
        StubURLProtocol.respond(status: 200, body: Self.chatBody("Hello, world."))
        let corrector = OpenAICompatibleCorrector(
            baseURL: URL(string: "https://llm.invalid/v1")!,
            modelName: "m",
            apiKey: "sk-explicit",
            session: StubURLProtocol.makeSession()
        )
        _ = try await corrector.correct("hello world", language: "en")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-explicit")
    }

    func test_correct_httpError_doesNotCarryResponseBody() async {
        // Servers echo request content in error bodies; the thrown error is
        // logged publicly by the coordinator, so the body must stay out of it.
        StubURLProtocol.respond(status: 500, body: Data("echo: my private dictation".utf8))
        let corrector = OpenAICompatibleCorrector(
            baseURL: URL(string: "https://llm.invalid/v1")!,
            modelName: "m",
            session: StubURLProtocol.makeSession()
        )
        do {
            _ = try await corrector.correct("hello world", language: "en")
            XCTFail("Expected an error for HTTP 500")
        } catch {
            let described = String(describing: error)
            XCTAssertTrue(described.contains("500"))
            XCTAssertFalse(described.contains("private dictation"))
        }
    }

    private static func chatBody(_ content: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": content]]]
        ])
    }
}

/// Answers every request made through `makeSession()` with a canned
/// response and records the request, so `correct` runs without a server.
private final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var canned: (status: Int, body: Data) = (200, Data())
    nonisolated(unsafe) private static var recorded: URLRequest?

    static var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func respond(status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        canned = (status, body)
        recorded = nil
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded = request
        let (status, body) = Self.canned
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
