import SwiftUI
import ServiceManagement
import HotKey

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var modelManager: ModelManager
    @AppStorage("recordingMode") private var recordingMode: String = RecordingMode.toggle.rawValue
    @AppStorage("soundEffects") private var soundEffects: Bool = true
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = true
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage: String = "auto"
    @AppStorage("autoDetectLanguage") private var autoDetectLanguage: Bool = false
    @AppStorage("streamingInputEnabled") private var streamingInputEnabled: Bool = false
    @AppStorage("streamingDiscoveryBadgeDismissed") private var discoveryBadgeDismissed: Bool = false
    @AppStorage("streamingFocusAbandonSeconds") private var focusAbandonSeconds: Double = 10.0
    @AppStorage("undoAfterTranscription") private var undoAfterTranscription: Bool = false
    @AppStorage("cleanupTranscription") private var cleanupTranscription: Bool = false
    @AppStorage("correctTranscription") private var correctTranscription: Bool = false
    @AppStorage("correctionEngine") private var correctionEngine: String = "apple"
    @AppStorage("localLLMBaseURL") private var localLLMBaseURL: String = "http://localhost:11434/v1"
    @AppStorage("localLLMModel") private var localLLMModel: String = "qwen2.5:3b-instruct"
    @AppStorage("localLLMAPIKey") private var localLLMAPIKey: String = ""
    @AppStorage(CorrectionPrompts.glossaryKey) private var correctionGlossary: String = ""
    @AppStorage(CorrectionPrompts.systemPromptKey) private var correctionSystemPrompt: String = ""

    @State private var useRightCommand: Bool = true
    @State private var showDeleteConfirmation = false
    @State private var showCancelDownloadConfirmation = false
    @State private var hotkeyKey: Key = .space
    @State private var hotkeyModifiers: NSEvent.ModifierFlags = .command

    /// Minimum downloaded bytes before the cancel confirmation dialog is shown.
    /// Below this threshold a single click is fine — very little data would be lost.
    private static let cancelConfirmThresholdBytes: Int64 = 100 * 1_000_000 // 100 MB

    private var showDiscoveryBadge: Bool {
        V1UsageCounter.shouldShowDiscoveryBadge
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            modelTab
                .tabItem { Label("Model", systemImage: "cpu") }
        }
        .frame(width: 420, height: 460)
        .padding()
        .onAppear { loadSavedHotkey() }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Hotkey") {
                LabeledContent("Trigger") {
                    if useRightCommand {
                        Text("Right Command")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    } else {
                        HotkeyRecorderView(key: $hotkeyKey, modifiers: $hotkeyModifiers)
                            .onChange(of: hotkeyKey) { _, _ in applyHotkey() }
                            .onChange(of: hotkeyModifiers) { _, _ in applyHotkey() }
                    }
                }
                LabeledContent("Right Command") {
                    Toggle("", isOn: $useRightCommand)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: useRightCommand) { _, newValue in
                            if newValue {
                                coordinator.hotkey.register(trigger: .rightCommand)
                                UserDefaults.standard.removeObject(forKey: "hotkeyKeyCode")
                                UserDefaults.standard.removeObject(forKey: "hotkeyModifiers")
                                UserDefaults.standard.set(true, forKey: "useRightCommand")
                            } else {
                                applyHotkey()
                                UserDefaults.standard.set(false, forKey: "useRightCommand")
                            }
                        }
                }
            }

            Section("Recording") {
                LabeledContent("Mode") {
                    Picker("", selection: $recordingMode) {
                        Text("Toggle").tag(RecordingMode.toggle.rawValue)
                        Text("Hold").tag(RecordingMode.hold.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .onChange(of: recordingMode) { _, newValue in
                        if let mode = RecordingMode(rawValue: newValue) {
                            coordinator.hotkey.setMode(mode)
                        }
                    }
                }
                LabeledContent(autoDetectLanguage ? "Fallback language" : "Language") {
                    Picker("", selection: $transcriptionLanguage) {
                        Text("Auto").tag("auto")
                        Divider()
                        Text("English").tag("en")
                        Text("中文").tag("zh")
                        Text("日本語").tag("ja")
                        Text("한국어").tag("ko")
                        Divider()
                        Text("Français").tag("fr")
                        Text("Deutsch").tag("de")
                        Text("Español").tag("es")
                        Text("Português").tag("pt")
                        Text("Italiano").tag("it")
                        Text("Nederlands").tag("nl")
                        Text("Polski").tag("pl")
                        Text("Ελληνικά").tag("el")
                        Text("العربية").tag("ar")
                        Text("Tiếng Việt").tag("vi")
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                if autoDetectLanguage {
                    Text("Used as the initial guess. If the transcription comes back in another language, it's automatically re-transcribed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent {
                    Toggle("", isOn: $autoDetectLanguage)
                        .labelsHidden()
                        .toggleStyle(.switch)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-detect language")
                        Text("If the transcription engine reports a different language than the initial guess (above), Murmur re-transcribes once with the detected language. No extra model download.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if streamingInputEnabled {
                            Text("Streaming voice input always uses the language above — re-transcribe applies to V1 full-pass only.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Sound effects") {
                    Toggle("", isOn: $soundEffects)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                LabeledContent("Undo after transcription") {
                    Toggle("", isOn: $undoAfterTranscription)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                LabeledContent("Launch at login") {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, newValue in
                            setLaunchAtLogin(newValue)
                        }
                }
            }

            Section("Experimental") {
                LabeledContent {
                    Toggle("", isOn: $streamingInputEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: streamingInputEnabled) { _, newValue in
                            if newValue {
                                V1UsageCounter.dismissDiscoveryBadge()
                                discoveryBadgeDismissed = true
                            }
                        }
                } label: {
                    HStack(spacing: 6) {
                        Text("Streaming input")
                        Text("Beta")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }

                if streamingInputEnabled {
                    LabeledContent("Focus timeout") {
                        HStack(spacing: 8) {
                            Slider(value: $focusAbandonSeconds, in: 5...30, step: 5)
                                .frame(width: 120)
                            Text("\(Int(focusAbandonSeconds))s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Model Tab

    @State private var showAdvancedEngines = false

    private var modelTab: some View {
        Form {
            Section("Speech Engine") {
                engineRow(.onnx)
                if modelManager.activeBackend == .onnx {
                    fireRedToggleRow
                }

                DisclosureGroup("Advanced", isExpanded: $showAdvancedEngines) {
                    engineRow(.huggingface)
                    if modelManager.activeBackend == .huggingface {
                        fireRedToggleRow
                    }
                    engineRow(.whisper)
                    engineRow(.fireRed)
                }
            }

            Section("Model — \(modelManager.activeBackend.shortName)") {
                LabeledContent("Status") {
                    modelStatusBadge
                }

                LabeledContent("Location") {
                    Text(modelManager.modelDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if case .downloading(let progress, let speed) = modelManager.state {
                    VStack(spacing: 4) {
                        if progress >= 0 {
                            ProgressView(value: progress)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                        HStack {
                            if !modelManager.statusMessage.isEmpty {
                                Text(modelManager.statusMessage)
                            }
                            Spacer()
                            if speed > 0 {
                                Text(formatSpeed(speed))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else if !modelManager.statusMessage.isEmpty {
                    Text(modelManager.statusMessage)
                        .font(.caption)
                        .foregroundStyle(modelManager.statusMessage.hasPrefix("Error") ? .red : .secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Section {
                HStack {
                    if modelManager.state == .ready {
                        Button("Delete Model", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                        .alert("Delete Model?", isPresented: $showDeleteConfirmation) {
                            Button("Delete", role: .destructive) { try? modelManager.delete() }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("The \(modelManager.activeBackend.shortName) model (\(modelManager.activeBackend.sizeDescription)) will be removed.")
                        }
                    } else if case .downloading = modelManager.state {
                        Button("Cancel Download") {
                            if modelManager.downloadedBytes >= Self.cancelConfirmThresholdBytes {
                                showCancelDownloadConfirmation = true
                            } else {
                                modelManager.cancelDownload()
                            }
                        }
                        .confirmationDialog(
                            "Cancel Download?",
                            isPresented: $showCancelDownloadConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Cancel Download", role: .destructive) {
                                modelManager.cancelDownload()
                            }
                            Button("Keep Downloading", role: .cancel) { }
                        } message: {
                            let mb = modelManager.downloadedBytes / 1_000_000
                            Text("You've downloaded \(mb) MB — cancelling will discard it.")
                        }
                    } else {
                        Button("Download Model") { Task { try? await modelManager.download() } }
                            .buttonStyle(.borderedProminent)
                    }

                    Spacer()

                    if modelManager.state == .ready || modelManager.state == .corrupt {
                        Button("Re-download") {
                            Task { try? modelManager.delete(); try? await modelManager.download() }
                        }
                    }
                }
            }

            Section("Transcription Correction") {
                transcriptionCorrectionRow
            }

            Section("Transcription Cleanup") {
                transcriptionCleanupRow
            }

            Section {
                HStack {
                    Button("Open Model Folder") {
                        NSWorkspace.shared.open(modelManager.modelDirectory)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    Spacer()
                    Button("Open Log Folder") {
                        let logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("Murmur")
                        NSWorkspace.shared.open(logDir)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var transcriptionCorrectionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent {
                Toggle("", isOn: $correctTranscription)
                    .labelsHidden()
                    .toggleStyle(.switch)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Correct transcription errors")
                    Text("Fix homophone/phonetic errors, wrong Chinese characters, and add sentence punctuation. English words in a Chinese sentence (and vice versa) are preserved — the model never translates. Adds up to 2.5 s; falls back to the raw transcription on timeout. V1 full-pass only — streaming is bypassed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if correctTranscription {
                // Engine picker — only relevant when correction is on.
                Picker("Engine", selection: $correctionEngine) {
                    Text("Apple on-device").tag("apple")
                    Text("Local LLM (OpenAI-compatible)").tag("local")
                }
                .pickerStyle(.segmented)
                .onChange(of: correctionEngine) { _, _ in
                    coordinator.reconfigureCorrectionEngine()
                }

                if correctionEngine == "apple" {
                    Text("Uses Apple Intelligence. Requires macOS 26 and the on-device model to be downloaded and enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    localLLMConfigFields
                }

                Divider()
                    .padding(.vertical, 4)

                glossaryEditor
                correctionPromptEditor
            }
        }
    }

    @ViewBuilder
    private var glossaryEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Glossary")
                .font(.subheadline)
            Text("Comma-separated terms the speaker uses (acronyms, jargon, code-switched words). Treated as authoritative spellings — verbatim hits stay, near-miss mistranscriptions are snapped to these spellings. Both `,` and full-width `，` work as separators.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("OKR, shipping, 对齐, k8s", text: $correctionGlossary)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var correctionPromptEditor: some View {
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
            ZStack(alignment: .topLeading) {
                TextEditor(text: $correctionSystemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160, maxHeight: 240)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )

                // Placeholder — TextEditor lacks native placeholder support
                // on macOS 14. We overlay a hint when the field is empty so
                // the user knows leaving it blank uses the default prompt.
                if correctionSystemPrompt.isEmpty {
                    Text("Empty = use built-in default. Click Reset to load the default for editing.")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            promptCharacterCount
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var promptCharacterCount: some View {
        let count = correctionSystemPrompt.count
        let isOver = count > 4000
        let isEffectivelyEmpty = correctionSystemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack {
            Text(isEffectivelyEmpty ? "Using built-in default" : "Custom prompt")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count) / 4000")
                .font(.caption2)
                .foregroundStyle(isOver ? .red : .secondary)
        }
    }

    @ViewBuilder
    private var localLLMConfigFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Any OpenAI-compatible server. Examples — Ollama: http://localhost:11434/v1 · LM Studio: http://localhost:1234/v1 · llamafile / vLLM / a cloud OpenAI-compatible proxy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Base URL") {
                TextField("http://localhost:11434/v1", text: $localLLMBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { coordinator.reconfigureCorrectionEngine() }
            }

            LabeledContent("Model") {
                TextField("qwen2.5:3b-instruct", text: $localLLMModel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { coordinator.reconfigureCorrectionEngine() }
            }

            LabeledContent("API Key") {
                SecureField("optional — leave empty for local servers", text: $localLLMAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { coordinator.reconfigureCorrectionEngine() }
            }

            HStack {
                Spacer()
                Button("Apply") {
                    coordinator.reconfigureCorrectionEngine()
                }
                .controlSize(.small)
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private var transcriptionCleanupRow: some View {
        LabeledContent {
            Toggle("", isOn: $cleanupTranscription)
                .labelsHidden()
                .toggleStyle(.switch)
            // v0.3.0: always enabled — rule-based, no model download required.
            // v0.3.1 will gate this on AuxiliaryModel.punctuationCleanup being downloaded.
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean up punctuation and casing")
                Text("English: capitalises sentences and adds terminal periods. Chinese: appends 。 and converts ASCII terminals to full-width. Japanese, Korean, and other languages pass through unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var modelStatusBadge: some View {
        switch modelManager.state {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notDownloaded:
            Label("Not Downloaded", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .downloading:
            Label("Downloading...", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
        case .verifying:
            Label("Verifying...", systemImage: "magnifyingglass")
                .foregroundStyle(.orange)
        case .corrupt:
            Label("Corrupt", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func engineRow(_ backend: ModelBackend) -> some View {
        let isActive: Bool = modelManager.activeBackend == backend
        let isDownloaded: Bool = modelManager.isModelDownloaded(for: backend)
        let switchLocked: Bool = modelManager.isDownloadActive
        let isLocked: Bool = switchLocked && !isActive
        return Button {
            modelManager.setActiveBackend(backend)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(backend.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(backend.sizeDescription)
                        if isDownloaded {
                            Text("Downloaded")
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if isLocked {
                        Text("Locked during download")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Disable switching backends while a download or verification is running.
        // The didSet guard in ModelManager is the authoritative lock; this is a
        // defense-in-depth layer that also gives the user a visual affordance.
        .disabled(isLocked)
        .help(isLocked ? "Locked during download — wait for it to finish or cancel first." : "")
    }

    /// Sub-toggle visible under Cohere ONNX or HF backends. Routes Chinese
    /// audio to FireRed when ON. Triggers a download if the FireRed model is
    /// not yet on disk.
    @ViewBuilder
    private var fireRedToggleRow: some View {
        let isOn = modelManager.useFireRedForChinese
        let fireRedReady = modelManager.isModelDownloaded(for: .fireRed)
        let isDownloadingFireRed = (modelManager.statusMessage.contains("FireRed"))
            && (modelManager.isDownloadActive)

        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { isOn },
                set: { newValue in
                    if newValue && !fireRedReady {
                        Task { await downloadFireRedFromToggle() }
                    } else {
                        _ = modelManager.setUseFireRedForChinese(newValue)
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use FireRed for Chinese transcription")
                        .font(.body)
                    Text("\(ModelBackend.fireRed.sizeDescription) additional · "
                         + "Routes Chinese audio to FireRed for better accuracy. "
                         + "Other languages stay on Cohere. V1 only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(modelManager.isDownloadActive && !isDownloadingFireRed)

            if isDownloadingFireRed {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.leading, 24)
    }

    /// Download the FireRed model on behalf of a user enabling the toggle.
    /// On success, set the toggle ON. On failure or cancellation, leave it OFF.
    ///
    /// Note: `ModelManager.statusMessage` is `@Published private(set)` so we
    /// cannot set a custom "Downloading FireRed model..." string from here.
    /// The user-facing label comes from the existing `statusMessage` writes
    /// inside `download()` (e.g. "Downloading speech model...", "Downloading:
    /// X MB"). The Model Status section already reflects active backend, so
    /// the in-progress download is attributed to FireRed via the section
    /// header. The `isDownloadingFireRed` heuristic above looks for "FireRed"
    /// in the status string — see `engineRow(.fireRed)` style if richer state
    /// signaling becomes needed.
    private func downloadFireRedFromToggle() async {
        let savedBackend = modelManager.activeBackend
        // Temporarily flip activeBackend to .fireRed so download() targets it.
        // Restore after the download completes (success or failure).
        guard modelManager.setActiveBackend(.fireRed) else {
            return
        }
        do {
            try await modelManager.download()
            _ = modelManager.setActiveBackend(savedBackend)
            _ = modelManager.setUseFireRedForChinese(true)
        } catch {
            _ = modelManager.setActiveBackend(savedBackend)
            // Error alert is handled by the existing ModelManager status path.
        }
    }

    // MARK: - Helpers

    private func applyHotkey() {
        coordinator.hotkey.register(key: hotkeyKey, modifiers: hotkeyModifiers)
    }

    private func loadSavedHotkey() {
        useRightCommand = UserDefaults.standard.object(forKey: "useRightCommand") as? Bool ?? true
        if let keyCode = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int,
           let key = Key(carbonKeyCode: UInt32(keyCode)) {
            hotkeyKey = key
        }
        if let modsRaw = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? UInt {
            hotkeyModifiers = NSEvent.ModifierFlags(rawValue: modsRaw)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Silently fail — login item management is best-effort
        }
    }

    private func formatSpeed(_ bytesPerSec: Int64) -> String {
        if bytesPerSec > 1_000_000 {
            return "\(bytesPerSec / 1_000_000) MB/s"
        } else if bytesPerSec > 1_000 {
            return "\(bytesPerSec / 1_000) KB/s"
        } else {
            return "\(bytesPerSec) B/s"
        }
    }
}
