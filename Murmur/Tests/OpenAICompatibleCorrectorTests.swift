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
            trimmed: longText
        )
        let longJson = try JSONSerialization.jsonObject(with: long.httpBody!) as! [String: Any]
        XCTAssertEqual(longJson["max_tokens"] as? Int, 160,
                       "Long inputs must scale max_tokens to ⌈length × 1.6⌉")
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
}
