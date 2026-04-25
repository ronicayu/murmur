# Corrector glossary + editable prompt — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a user-editable correction system prompt and a glossary of speaker-specific terms that the corrector treats as authoritative spellings.

**Architecture:** Post-processing only. `CorrectionPrompts` becomes a thin façade reading two `UserDefaults` keys with sensible defaults. Both corrector backends (`OpenAICompatibleCorrector`, `FoundationModelsCorrector`) read this façade so behaviour is symmetric. The user message gains a `Glossary:` line that degrades to `(none)` when the user has not entered any terms. Settings UI exposes a `TextEditor` for the prompt and a `TextField` for the glossary, with a Reset button and a soft 4000-char counter. No A/B toggle — the soft fallback (empty glossary = current behaviour) is the on/off knob.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Foundation, FoundationModels (macOS 26+).

**Spec:** `docs/superpowers/specs/2026-04-25-corrector-glossary-design.md`

---

## File structure

| File | Responsibility | Status |
|------|----------------|--------|
| `Murmur/Services/TranscriptionCorrectionService.swift` | `CorrectionPrompts` façade (default + user override + glossary parsing); `FoundationModelsCorrector` user-message construction | modified |
| `Murmur/Services/OpenAICompatibleCorrector.swift` | Request construction including `Glossary:` line; reads `CorrectionPrompts.current` for system role | modified |
| `Murmur/Views/SettingsView.swift` | Add Glossary TextField + Correction prompt TextEditor + Reset + char counter under existing Correction section | modified |
| `Murmur/Tests/OpenAICompatibleCorrectorTests.swift` | Update assertions on user-message body | modified |
| `Murmur/Tests/TranscriptionCorrectionTests.swift` | Add `CorrectionPromptsTests` suite; existing tests untouched | modified |
| `Murmur/Tests/CorrectorGlossaryTests.swift` | New: glossary verbatim / near-miss / irrelevant / parity stubs | created |

---

## Phase 1 — CorrectionPrompts façade

### Task 1: Add `CorrectionPromptsTests` for the new façade

**Files:**
- Modify: `Murmur/Tests/TranscriptionCorrectionTests.swift` (append a new suite at the end)

- [ ] **Step 1: Write failing tests for `CorrectionPrompts.current` and `currentGlossary()`**

```swift
// Append at end of TranscriptionCorrectionTests.swift, before final closing brace if any,
// or at file end. The suite uses unique UserDefaults keys to avoid pollution.

final class CorrectionPromptsTests: XCTestCase {

    private let promptKey = "correctionSystemPrompt"
    private let glossaryKey = "correctionGlossary"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: promptKey)
        UserDefaults.standard.removeObject(forKey: glossaryKey)
        super.tearDown()
    }

    // current — system prompt resolution

    func test_current_returnsDefault_whenUnset() {
        UserDefaults.standard.removeObject(forKey: promptKey)
        XCTAssertEqual(CorrectionPrompts.current, CorrectionPrompts.defaultSystemPrompt)
    }

    func test_current_returnsDefault_whenEmptyString() {
        UserDefaults.standard.set("", forKey: promptKey)
        XCTAssertEqual(CorrectionPrompts.current, CorrectionPrompts.defaultSystemPrompt)
    }

    func test_current_returnsDefault_whenWhitespaceOnly() {
        UserDefaults.standard.set("   \n\t  ", forKey: promptKey)
        XCTAssertEqual(CorrectionPrompts.current, CorrectionPrompts.defaultSystemPrompt)
    }

    func test_current_returnsTrimmedOverride_whenSet() {
        UserDefaults.standard.set("  custom prompt body  ", forKey: promptKey)
        XCTAssertEqual(CorrectionPrompts.current, "custom prompt body")
    }

    // currentGlossary — comma-split + trim + drop empties

    func test_currentGlossary_returnsEmpty_whenUnset() {
        UserDefaults.standard.removeObject(forKey: glossaryKey)
        XCTAssertEqual(CorrectionPrompts.currentGlossary(), [])
    }

    func test_currentGlossary_returnsEmpty_whenEmptyString() {
        UserDefaults.standard.set("", forKey: glossaryKey)
        XCTAssertEqual(CorrectionPrompts.currentGlossary(), [])
    }

    func test_currentGlossary_splitsAndTrims() {
        UserDefaults.standard.set("OKR, shipping ,  对齐, k8s", forKey: glossaryKey)
        XCTAssertEqual(
            CorrectionPrompts.currentGlossary(),
            ["OKR", "shipping", "对齐", "k8s"]
        )
    }

    func test_currentGlossary_dropsEmptyEntries() {
        UserDefaults.standard.set(",, OKR ,,  ,k8s,", forKey: glossaryKey)
        XCTAssertEqual(CorrectionPrompts.currentGlossary(), ["OKR", "k8s"])
    }

    // defaultSystemPrompt — sanity invariants

    func test_defaultSystemPrompt_isNonEmpty() {
        XCTAssertFalse(CorrectionPrompts.defaultSystemPrompt.isEmpty)
    }

    func test_defaultSystemPrompt_mentionsGlossary() {
        XCTAssertTrue(CorrectionPrompts.defaultSystemPrompt.contains("Glossary"),
                      "Default prompt must explain the Glossary field")
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

```bash
cd Murmur && swift test --filter CorrectionPromptsTests
```

Expected: FAIL — `defaultSystemPrompt`, `current`, and `currentGlossary` don't exist yet.

### Task 2: Implement `CorrectionPrompts` façade and replace prompt content

**Files:**
- Modify: `Murmur/Services/TranscriptionCorrectionService.swift` (the `CorrectionPrompts` enum)

- [ ] **Step 1: Replace the existing `CorrectionPrompts` enum**

Locate the existing `enum CorrectionPrompts { static let systemPrompt = """ ... """ }` block. Replace its body with:

```swift
enum CorrectionPrompts {

    /// Built-in default prompt, also the seed for the editable Settings field.
    /// When the user clears the Settings editor, this is what runs.
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

    /// UserDefaults key for the editable system prompt override.
    static let systemPromptKey = "correctionSystemPrompt"

    /// UserDefaults key for the comma-separated glossary.
    static let glossaryKey = "correctionGlossary"

    /// Effective system prompt. Returns the trimmed user override if non-empty,
    /// else the default. Single source of truth — both correctors call this.
    static var current: String {
        let raw = UserDefaults.standard.string(forKey: systemPromptKey) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultSystemPrompt : trimmed
    }

    /// Effective glossary as a normalised list. Empty when the user has not
    /// entered terms; rendered as `(none)` in the user message by callers.
    static func currentGlossary() -> [String] {
        let raw = UserDefaults.standard.string(forKey: glossaryKey) ?? ""
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
```

- [ ] **Step 2: Update existing call sites in the same file**

`FoundationModelsCorrector.instructions` reference: change `CorrectionPrompts.systemPrompt` → `CorrectionPrompts.current`. Note: `instructions` is `private static let` — convert it to a computed property or remove the cached binding so it re-reads each time (the model session is rebuilt per-call anyway).

```swift
// In FoundationModelsCorrector, replace:
//   private static let instructions = CorrectionPrompts.systemPrompt
// with no static binding — pass `CorrectionPrompts.current` directly into
// LanguageModelSession at construction time:

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
```

- [ ] **Step 3: Run unit tests and confirm they pass**

```bash
cd Murmur && swift test --filter CorrectionPromptsTests
```

Expected: all 9 tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Murmur/Services/TranscriptionCorrectionService.swift \
        Murmur/Tests/TranscriptionCorrectionTests.swift
git commit -m "feat(correction): add editable prompt façade with default fallback"
```

---

## Phase 2 — Glossary in user message (OpenAI-compatible)

### Task 3: Add failing test for `Glossary:` line in OpenAI request

**Files:**
- Modify: `Murmur/Tests/OpenAICompatibleCorrectorTests.swift`

- [ ] **Step 1: Add failing tests asserting glossary line presence**

Append to `OpenAICompatibleCorrectorTests`:

```swift
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
                  "Empty glossary must render as '(none)' so the prompt rule degrades")
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
                  "Glossary terms must be joined with `, ` after the field label")
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
    XCTAssertEqual(messages[0]["content"], CorrectionPrompts.defaultSystemPrompt)
}
```

- [ ] **Step 2: Update existing `makeRequest` callers in this test file**

Existing tests call `makeRequest` without `glossary:`. Add `glossary: []` to every call. Search-and-replace candidates:

- `test_makeRequest_postsToChatCompletionsOnBaseURL`
- `test_makeRequest_setsJSONContentType`
- `test_makeRequest_omitsAuthHeader_whenApiKeyNil`
- `test_makeRequest_setsBearerAuth_whenApiKeyProvided`
- `test_makeRequest_bodyContainsSystemAndUserMessages`
- `test_makeRequest_maxTokensScalesWithInputLength` (two call sites)

Each becomes e.g.:

```swift
let request = try OpenAICompatibleCorrector.makeRequest(
    baseURL: ...,
    modelName: ...,
    apiKey: ...,
    language: ...,
    glossary: [],
    trimmed: ...
)
```

- [ ] **Step 3: Run tests; expect compile failures**

```bash
cd Murmur && swift test --filter OpenAICompatibleCorrectorTests
```

Expected: FAIL — compile error, signature change.

### Task 4: Implement glossary parameter in `makeRequest`

**Files:**
- Modify: `Murmur/Services/OpenAICompatibleCorrector.swift`

- [ ] **Step 1: Change `makeRequest` signature and body**

```swift
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
    if let apiKey, !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

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
        "max_tokens": maxTokens
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
}
```

- [ ] **Step 2: Update `correct(_:language:)` to pass the glossary**

In `OpenAICompatibleCorrector.correct`:

```swift
let request = try Self.makeRequest(
    baseURL: baseURL,
    modelName: modelName,
    apiKey: apiKey,
    language: language,
    glossary: CorrectionPrompts.currentGlossary(),
    trimmed: trimmed
)
```

(Replace the existing call that omits `glossary:`.)

- [ ] **Step 3: Run tests**

```bash
cd Murmur && swift test --filter OpenAICompatibleCorrectorTests
```

Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add Murmur/Services/OpenAICompatibleCorrector.swift \
        Murmur/Tests/OpenAICompatibleCorrectorTests.swift
git commit -m "feat(correction): include glossary line in OpenAI-compatible user message"
```

---

## Phase 3 — Glossary in user message (Foundation Models)

### Task 5: Update `FoundationModelsCorrector` user message

**Files:**
- Modify: `Murmur/Services/TranscriptionCorrectionService.swift`

This corrector cannot be unit-tested without macOS 26 + Apple Intelligence. Symmetry with the OpenAI side is enforced by code review and the integration coverage in `CoordinatorCorrectionTests`.

- [ ] **Step 1: Update the user-message construction inside `correct(_:language:)`**

Replace:

```swift
let prompt = "Language: \(language)\nRaw transcription: \(trimmed)"
```

with:

```swift
let glossary = CorrectionPrompts.currentGlossary()
let glossaryLine = glossary.isEmpty ? "(none)" : glossary.joined(separator: ", ")
let prompt = """
Language: \(language)
Glossary: \(glossaryLine)
Raw transcription: \(trimmed)
"""
```

- [ ] **Step 2: Compile-check**

```bash
cd Murmur && swift build
```

Expected: build succeeds.

- [ ] **Step 3: Run all corrector-related tests for regression**

```bash
cd Murmur && swift test --filter CorrectionPromptsTests
cd Murmur && swift test --filter OpenAICompatibleCorrectorTests
cd Murmur && swift test --filter CoordinatorCorrectionTests
cd Murmur && swift test --filter CorrectionSafetyRailsTests
cd Murmur && swift test --filter NoOpCorrectorTests
```

Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add Murmur/Services/TranscriptionCorrectionService.swift
git commit -m "feat(correction): include glossary line in Foundation Models user message"
```

---

## Phase 4 — Settings UI

### Task 6: Add Glossary TextField + prompt TextEditor + Reset

**Files:**
- Modify: `Murmur/Views/SettingsView.swift`

- [ ] **Step 1: Declare the two new `@AppStorage` bindings**

In `SettingsView`, near the existing correction-related bindings:

```swift
@AppStorage(CorrectionPrompts.glossaryKey) private var correctionGlossary: String = ""
@AppStorage(CorrectionPrompts.systemPromptKey) private var correctionSystemPrompt: String = ""
```

(Use the static keys exposed in `CorrectionPrompts` so there is one source of truth for the key strings.)

- [ ] **Step 2: Extend `transcriptionCorrectionRow` to render the new controls**

Add these inside the `if correctTranscription { ... }` block, after the existing engine picker / config fields:

```swift
Divider()
    .padding(.vertical, 4)

VStack(alignment: .leading, spacing: 6) {
    Text("Glossary")
        .font(.subheadline)
    Text("Comma-separated terms the speaker uses (acronyms, jargon, code-switched words). Treated as authoritative spellings — verbatim hits stay, near-miss mistranscriptions are snapped to these spellings.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    TextField("OKR, shipping, 对齐, k8s", text: $correctionGlossary)
        .textFieldStyle(.roundedBorder)
}

VStack(alignment: .leading, spacing: 6) {
    HStack {
        Text("Correction prompt")
            .font(.subheadline)
        Spacer()
        Button("Reset to default") {
            correctionSystemPrompt = ""
        }
        .controlSize(.small)
        .help("Restore the built-in default prompt")
    }
    Text("Advanced. Sent to the correction model as the system message. Leave empty to use the built-in default.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    TextEditor(text: $correctionSystemPrompt)
        .font(.system(.body, design: .monospaced))
        .frame(minHeight: 160, maxHeight: 240)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
        )
    promptCharacterCount
}
.padding(.top, 6)
```

- [ ] **Step 3: Add the helper view for the character count**

Inside `SettingsView`:

```swift
@ViewBuilder
private var promptCharacterCount: some View {
    let count = correctionSystemPrompt.count
    let isOver = count > 4000
    HStack {
        if correctionSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Using built-in default")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("Custom prompt")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        Spacer()
        Text("\(count) / 4000")
            .font(.caption2)
            .foregroundStyle(isOver ? .red : .secondary)
    }
}
```

- [ ] **Step 4: Build and visually inspect**

```bash
cd Murmur && swift build
```

Expected: build succeeds. Run the app (`open .build/debug/Murmur.app` after assembling, or launch via Xcode if available) and confirm:
- Settings → General tab → Transcription Correction section shows new Glossary field and Correction prompt editor
- Reset button populates the editor seed back to default
- Char counter goes red beyond 4000

- [ ] **Step 5: Commit**

```bash
git add Murmur/Views/SettingsView.swift
git commit -m "feat(settings): add editable correction prompt + glossary UI"
```

---

## Phase 5 — Glossary regression suite

### Task 7: Write `CorrectorGlossaryTests`

**Files:**
- Create: `Murmur/Tests/CorrectorGlossaryTests.swift`

These tests exercise **request shape** (does the user message include the glossary?) and **response handling** (does a stubbed glossary-aware response flow through validation?). They are not LLM-judgement tests — actual LLM behaviour is validated subjectively after the feature lands.

- [ ] **Step 1: Create the test file**

```swift
import XCTest
@testable import Murmur

/// Glossary-feature regression suite. Asserts request shape (user-message
/// embedding) and end-to-end flow with a stubbed `URLSession`. The LLM's
/// own judgement is validated subjectively after the feature ships.
final class CorrectorGlossaryTests: XCTestCase {

    private let promptKey = "correctionSystemPrompt"
    private let glossaryKey = "correctionGlossary"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: promptKey)
        UserDefaults.standard.removeObject(forKey: glossaryKey)
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
        let stub = StubURLSession(canned: """
            {"choices":[{"message":{"role":"assistant","content":"我们今天的 OKR 在下午三点对齐一下进度。"}}]}
            """)
        let corrector = OpenAICompatibleCorrector(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "m",
            apiKey: nil,
            session: stub.urlSession()
        )

        UserDefaults.standard.set("OKR, 对齐", forKey: glossaryKey)

        let raw = "我们今天的奥凯阿在下午三点对其一下进度"
        let result = try await corrector.correct(raw, language: "zh")

        // Output should contain both glossary terms and not the near-misses.
        XCTAssertTrue(result.contains("OKR"))
        XCTAssertTrue(result.contains("对齐"))
        XCTAssertFalse(result.contains("奥凯阿"))
        XCTAssertFalse(result.contains("对其"))

        // Request shape: user message must include the glossary line.
        let lastBody = try XCTUnwrap(stub.lastRequestBody())
        let lastJSON = try JSONSerialization.jsonObject(with: lastBody) as! [String: Any]
        let messages = lastJSON["messages"] as! [[String: String]]
        XCTAssertTrue(messages[1]["content"]!.contains("Glossary: OKR, 对齐"))
    }

    func test_endToEnd_emptyGlossary_pipelineUnchanged() async throws {
        let stub = StubURLSession(canned: """
            {"choices":[{"message":{"role":"assistant","content":"Hello, world."}}]}
            """)
        let corrector = OpenAICompatibleCorrector(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            modelName: "m", apiKey: nil,
            session: stub.urlSession()
        )

        UserDefaults.standard.removeObject(forKey: glossaryKey)
        let result = try await corrector.correct("hello world", language: "en")
        XCTAssertEqual(result, "Hello, world.")

        let lastBody = try XCTUnwrap(stub.lastRequestBody())
        let lastJSON = try JSONSerialization.jsonObject(with: lastBody) as! [String: Any]
        let messages = lastJSON["messages"] as! [[String: String]]
        XCTAssertTrue(messages[1]["content"]!.contains("Glossary: (none)"))
    }

    // MARK: - Helpers

    private func userMessage(_ request: URLRequest) throws -> String {
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        return try XCTUnwrap(messages[1]["content"])
    }
}

// MARK: - Tiny URLProtocol stub

/// In-process URL stub for end-to-end corrector tests. Records the most
/// recent request body and returns a canned response. Configured per test.
private final class StubURLSession {
    private let canned: String
    init(canned: String) { self.canned = canned }

    func urlSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.cannedBody = canned
        StubProtocol.lastRequestBody = nil
        return URLSession(configuration: config)
    }

    func lastRequestBody() -> Data? {
        StubProtocol.lastRequestBody
    }
}

private final class StubProtocol: URLProtocol {
    static var cannedBody: String = "{}"
    static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLRequest.httpBody is dropped when going through URLProtocol; the
        // body lives on httpBodyStream. Read it.
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
            StubProtocol.lastRequestBody = data
        } else {
            StubProtocol.lastRequestBody = request.httpBody
        }

        let body = StubProtocol.cannedBody.data(using: .utf8)!
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
```

- [ ] **Step 2: Run tests**

```bash
cd Murmur && swift test --filter CorrectorGlossaryTests
```

Expected: all PASS.

- [ ] **Step 3: Commit**

```bash
git add Murmur/Tests/CorrectorGlossaryTests.swift
git commit -m "test(correction): glossary regression suite — request shape + end-to-end"
```

---

## Phase 6 — Build, full-test, code review

### Task 8: Whole-suite verification

- [ ] **Step 1: Full build**

```bash
cd Murmur && swift build 2>&1 | tail -40
```

Expected: build succeeds; pre-existing Sendable/`@unchecked` warnings are allowed (already present on main).

- [ ] **Step 2: Full test run**

```bash
cd Murmur && swift test --parallel 2>&1 | tail -60
```

Expected: all tests PASS (skips for model-required tests are fine).

- [ ] **Step 3: Dispatch staff-code-reviewer**

Use the Agent tool with subagent_type=staff-code-reviewer to review the diff vs. main. Apply any P0/P1 findings inline; defer P2/P3 with brief notes.

- [ ] **Step 4: Final commit (if review fixes needed)**

```bash
git add -A
git commit -m "fix(correction): address code review findings"
```

---

## Self-review against spec

| Spec section                                  | Covered by                               |
|-----------------------------------------------|------------------------------------------|
| New `Glossary` field in user message          | Task 4 (OpenAI), Task 5 (FM)             |
| Simplified default prompt (~28 lines)         | Task 2                                   |
| Default prompt overridable via Settings       | Task 2 (façade), Task 6 (UI)             |
| Settings: prompt editor + glossary + reset    | Task 6                                   |
| Out-of-scope: ASR decoder prompt              | Not implemented (deliberate)             |
| Out-of-scope: per-language glossaries         | Not implemented (deliberate)             |
| Out-of-scope: in-app A/B toggle               | Not implemented (deliberate)             |
| Behaviour contract: empty glossary parity     | Task 7 `test_endToEnd_emptyGlossary…`    |
| Behaviour contract: verbatim / near-miss      | Task 7 `test_endToEnd_glossarySnap…`     |
| Existing safety rails preserved               | Task 4 keeps `CorrectionSafetyRails.validate` flow unchanged |
| Migration: existing users unaffected          | Default `@AppStorage` values empty → fall back to default behaviour |
