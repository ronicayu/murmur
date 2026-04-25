import XCTest
import os
@testable import Murmur

/// Glossary-feature regression suite. Asserts request shape (does the user
/// message embed the glossary?) and end-to-end flow with a stubbed
/// `URLSession`. The LLM's own judgement is validated subjectively after
/// the feature ships — these tests guard the wiring around it.
final class CorrectorGlossaryTests: XCTestCase {

    private let promptKey = CorrectionPrompts.systemPromptKey
    private let glossaryKey = CorrectionPrompts.glossaryKey

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: promptKey)
        UserDefaults.standard.removeObject(forKey: glossaryKey)
        StubProtocol.reset()
        super.tearDown()
    }

    // MARK: - User-message shape

    func test_userMessage_emptyGlossary_rendersNone() throws {
        let req = try OpenAICompatibleCorrector.makeRequest(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "m", apiKey: nil,
            language: "zh", glossary: [],
            trimmed: "你好世界"
        )
        let userContent = try userMessage(req)
        XCTAssertTrue(userContent.contains("Glossary: (none)"))
        XCTAssertTrue(userContent.contains("Language: zh"))
        XCTAssertTrue(userContent.contains("Raw transcription: 你好世界"))
    }

    func test_userMessage_glossaryOrderIsPreserved() throws {
        let terms = ["k8s", "OKR", "对齐", "tRPC"]
        let req = try OpenAICompatibleCorrector.makeRequest(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "m", apiKey: nil,
            language: "en", glossary: terms,
            trimmed: "we shipped to k8s"
        )
        let userContent = try userMessage(req)
        XCTAssertTrue(userContent.contains("Glossary: k8s, OKR, 对齐, tRPC"),
                      "Glossary terms must appear in caller-supplied order")
    }

    func test_userMessage_glossaryWithCJKAndASCII_isJoinedWithCommaSpace() throws {
        let req = try OpenAICompatibleCorrector.makeRequest(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "m", apiKey: nil,
            language: "zh", glossary: ["对齐", "shipping"],
            trimmed: "对其一下"
        )
        let userContent = try userMessage(req)
        XCTAssertTrue(userContent.contains("Glossary: 对齐, shipping"))
    }

    // MARK: - End-to-end with stubbed session

    func test_endToEnd_glossarySnap_flowsThroughSafetyRails() async throws {
        StubProtocol.cannedBody = """
        {"choices":[{"message":{"role":"assistant","content":"我们今天的 OKR 在下午三点对齐一下进度。"}}]}
        """
        let session = makeStubbedSession()
        let corrector = OpenAICompatibleCorrector(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "m",
            apiKey: nil,
            session: session
        )

        UserDefaults.standard.set("OKR, 对齐", forKey: glossaryKey)

        let raw = "我们今天的奥凯阿在下午三点对其一下进度"
        let result = try await corrector.correct(raw, language: "zh")

        // The stubbed response is what flows through validation; safety rails
        // accept it (length ratio inside [0.5, 1.6], no refusal markers).
        XCTAssertTrue(result.contains("OKR"))
        XCTAssertTrue(result.contains("对齐"))
        XCTAssertFalse(result.contains("奥凯阿"))
        XCTAssertFalse(result.contains("对其"))

        // Request shape: user message must have included the glossary line.
        let lastBody = try XCTUnwrap(StubProtocol.lastRequestBody)
        let lastJSON = try JSONSerialization.jsonObject(with: lastBody) as! [String: Any]
        let messages = lastJSON["messages"] as! [[String: String]]
        XCTAssertTrue(messages[1]["content"]!.contains("Glossary: OKR, 对齐"))
    }

    func test_endToEnd_emptyGlossary_pipelineUnchanged() async throws {
        StubProtocol.cannedBody = """
        {"choices":[{"message":{"role":"assistant","content":"Hello, world."}}]}
        """
        let session = makeStubbedSession()
        let corrector = OpenAICompatibleCorrector(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "m", apiKey: nil,
            session: session
        )

        UserDefaults.standard.removeObject(forKey: glossaryKey)
        let result = try await corrector.correct("hello world", language: "en")
        XCTAssertEqual(result, "Hello, world.")

        let lastBody = try XCTUnwrap(StubProtocol.lastRequestBody)
        let lastJSON = try JSONSerialization.jsonObject(with: lastBody) as! [String: Any]
        let messages = lastJSON["messages"] as! [[String: String]]
        XCTAssertTrue(messages[1]["content"]!.contains("Glossary: (none)"))
    }

    // MARK: - Helpers

    private func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    private func userMessage(_ request: URLRequest) throws -> String {
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        return try XCTUnwrap(messages[1]["content"])
    }
}

// MARK: - URLProtocol stub

/// In-process URL stub for end-to-end corrector tests. Records the most
/// recent request body and returns a canned response.
///
/// Mutable state lives behind an `OSAllocatedUnfairLock` so tests are safe
/// to run under `swift test --parallel` even if multiple `CorrectorGlossaryTests`
/// methods overlap. Each test calls `cannedBody=...; lastRequestBody=nil`
/// during setup; the lock keeps the read-modify pair from interleaving
/// with another test's `startLoading`.
private final class StubProtocol: URLProtocol, @unchecked Sendable {

    private struct State {
        var cannedBody: String = "{}"
        var lastRequestBody: Data?
    }

    private static let state = OSAllocatedUnfairLock<State>(initialState: State())

    static var cannedBody: String {
        get { state.withLock { $0.cannedBody } }
        set { state.withLock { $0.cannedBody = newValue } }
    }

    static var lastRequestBody: Data? {
        get { state.withLock { $0.lastRequestBody } }
        set { state.withLock { $0.lastRequestBody = newValue } }
    }

    static func reset() {
        state.withLock {
            $0.cannedBody = "{}"
            $0.lastRequestBody = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLRequest.httpBody is dropped when going through URLProtocol; the
        // body lives on httpBodyStream. Read it.
        let collectedBody: Data
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buffer, maxLength: 4096)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            collectedBody = data
        } else {
            collectedBody = request.httpBody ?? Data()
        }

        let canned = Self.state.withLock { state -> String in
            state.lastRequestBody = collectedBody
            return state.cannedBody
        }

        let body = canned.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
