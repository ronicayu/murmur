import Foundation
import os

/// The optional step between transcription and insertion that asks a language
/// model to fix likely recognition errors.
///
/// The engine is chosen by `reconfigure()` from the `correctionEngine`
/// UserDefault: `"apple"` → `FoundationModelsCorrector` (or no-op on older
/// systems), `"local"` → `OpenAICompatibleCorrector`. The step runs only when
/// the `correctTranscription` UserDefault is on.
@MainActor
final class CorrectionStep {
    /// The engine in use. Tests set a spy here.
    var engine: (any TranscriptionCorrection)?

    /// Hard cap for one correction. 2.5 s accommodates Apple Foundation
    /// Models first-token + generation on M-series; shorter would cause a
    /// fallback on nearly every invocation when the session is cold.
    static let timeoutSeconds: TimeInterval = 2.5

    private static let log = Logger(subsystem: "com.murmur.app", category: "correction")

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "correctTranscription")
    }

    /// Re-reads `correctionEngine`, `localLLMBaseURL`, `localLLMModel`, and
    /// `localLLMAPIKey` from UserDefaults and wires the matching engine.
    /// Cheap, and safe to call repeatedly: at launch and whenever Settings
    /// changes the engine picker, URL or model fields.
    func reconfigure() {
        let defaults = UserDefaults.standard
        let engineName = defaults.string(forKey: "correctionEngine") ?? "apple"

        switch engineName {
        case "local":
            // Any OpenAI-compatible local server (Ollama, LM Studio, llamafile, …).
            // User fills in the full base URL including `/v1`.
            let urlString = defaults.string(forKey: "localLLMBaseURL") ?? "http://localhost:11434/v1"
            let model = defaults.string(forKey: "localLLMModel") ?? "qwen2.5:3b-instruct"
            let apiKey = defaults.string(forKey: "localLLMAPIKey")
            if let url = URL(string: urlString) {
                engine = OpenAICompatibleCorrector(
                    baseURL: url,
                    modelName: model,
                    apiKey: (apiKey?.isEmpty ?? true) ? nil : apiKey
                )
                Self.log.info("correction engine: local @ \(urlString, privacy: .public) (\(model, privacy: .public))")
            } else {
                Self.log.error("correction engine: invalid local URL \(urlString, privacy: .public); falling back to NoOp")
                engine = NoOpCorrector()
            }

        default:
            // "apple" or unknown — prefer Foundation Models when available.
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), FoundationModelsCorrector.isSystemModelAvailable {
                engine = FoundationModelsCorrector()
                Self.log.info("correction engine: apple on-device")
                return
            }
            #endif
            engine = NoOpCorrector()
            Self.log.info("correction engine: noop (apple unavailable)")
        }
    }

    /// The corrected text, or `rawText` unchanged when the step is off, has
    /// no engine, times out, throws, or when the safety rails in
    /// `TranscriptionCorrection` reject the candidate.
    func apply(to rawText: String, language: String) async -> String {
        guard isEnabled, let engine else { return rawText }
        do {
            return try await withTimeout(seconds: Self.timeoutSeconds, operation: "correction") {
                try await engine.correct(rawText, language: language)
            }
        } catch {
            Self.log.warning("Correction failed, using raw text: \(String(describing: error), privacy: .public)")
            return rawText
        }
    }
}
