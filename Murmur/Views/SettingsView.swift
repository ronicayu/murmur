import SwiftUI
import ServiceManagement
import HotKey
import AppKit

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var modelManager: ModelManager
    @AppStorage("recordingMode") private var recordingMode: String = RecordingMode.toggle.rawValue
    @AppStorage("handsFreeTrailingSilenceSeconds") private var handsFreeTrailingSilenceSeconds: Double = AppCoordinator.defaultHandsFreeTrailingSilenceSeconds
    @AppStorage("soundEffects") private var soundEffects: Bool = true
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = true
    @AppStorage("streamingInputEnabled") private var streamingInputEnabled: Bool = false
    @AppStorage("streamingDiscoveryBadgeDismissed") private var discoveryBadgeDismissed: Bool = false
    @AppStorage("undoAfterTranscription") private var undoAfterTranscription: Bool = false
    @AppStorage("correctTranscription") private var correctTranscription: Bool = false
    @AppStorage("correctionEngine") private var correctionEngine: String = "apple"
    @AppStorage("localLLMBaseURL") private var localLLMBaseURL: String = "http://localhost:11434/v1"
    @AppStorage("localLLMModel") private var localLLMModel: String = "qwen2.5:3b-instruct"
    @AppStorage(CorrectionPrompts.glossaryKey) private var correctionGlossary: String = ""
    @AppStorage(CorrectionPrompts.systemPromptKey) private var correctionSystemPrompt: String = ""

    @State private var useRightCommand: Bool = true
    @State private var showDeleteConfirmation = false
    @State private var legacyDataBytes: Int64 = 0
    @State private var showCancelDownloadConfirmation = false
    @State private var showRedownloadConfirmation = false
    @State private var showRemoveLegacyConfirmation = false
    @State private var hotkeyKey: Key = HotkeyPreference.defaultCustomKey
    @State private var hotkeyModifiers: NSEvent.ModifierFlags = HotkeyPreference.defaultCustomModifiers
    @AppStorage("localLLMAPIKey") private var localLLMAPIKey: String = ""

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
                    Toggle("Right Command", isOn: $useRightCommand)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: useRightCommand) { _, newValue in
                            if newValue {
                                coordinator.hotkey.register(trigger: .rightCommand)
                                HotkeyPreference.save(.rightCommand)
                            } else {
                                applyHotkey()
                            }
                        }
                }
            }

            Section("Recording") {
                LabeledContent("Mode") {
                    Picker("Mode", selection: $recordingMode) {
                        Text("Toggle").tag(RecordingMode.toggle.rawValue)
                        Text("Hold").tag(RecordingMode.hold.rawValue)
                        Text("Hands-free").tag(RecordingMode.handsFree.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .onChange(of: recordingMode) { _, newValue in
                        if let mode = RecordingMode(rawValue: newValue) {
                            coordinator.applyRecordingMode(mode)
                            if mode == .handsFree && !modelManager.useVAD {
                                _ = modelManager.setUseVAD(true)
                            }
                        }
                    }
                }
                if recordingMode == RecordingMode.handsFree.rawValue {
                    LabeledContent("Auto-stop after") {
                        HStack(spacing: 8) {
                            Slider(
                                value: $handsFreeTrailingSilenceSeconds,
                                in: 1.0...10.0,
                                step: 0.5
                            )
                            .frame(width: 160)
                            .accessibilityLabel("Auto-stop after")
                            .accessibilityValue(String(format: "%.1f seconds", handsFreeTrailingSilenceSeconds))
                            .onChange(of: handsFreeTrailingSilenceSeconds) { _, _ in
                                coordinator.applyRecordingMode(.handsFree)
                            }
                            Text(String(format: "%.1fs", handsFreeTrailingSilenceSeconds))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !modelManager.useVAD {
                        Text("Hands-free needs Silero VAD. Enable it in the Model tab — otherwise recording won't auto-stop.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                SpokenLanguagesSetting()
                LabeledContent("Sound effects") {
                    Toggle("Sound effects", isOn: $soundEffects)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                LabeledContent("Undo after transcription") {
                    Toggle("Undo after transcription", isOn: $undoAfterTranscription)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                LabeledContent("Launch at login") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, newValue in
                            setLaunchAtLogin(newValue)
                        }
                }
            }

            Section("Experimental") {
                LabeledContent {
                    Toggle("Streaming input", isOn: $streamingInputEnabled)
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

                Text("Text appears in a floating bubble while you speak. The final text is inserted once when you stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Version") {
                    Text(Self.appVersionString)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Reads `CFBundleShortVersionString` (set by Info.plist; CI overrides from
    /// the git tag at release time). Falls back to "?" if the dictionary is
    /// missing — should never happen in a real build but keeps the binding safe.
    private static var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // MARK: - Model Tab

    private var modelTab: some View {
        Form {
            Section("Speech Model") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ModelBackend.qwen3.displayName) · \(ModelBackend.qwen3.sizeDescription)")
                    Text(ModelBackend.qwen3.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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
                            // A corrupt model has nothing worth keeping.
                            if modelManager.state == .ready {
                                showRedownloadConfirmation = true
                            } else {
                                redownloadModel()
                            }
                        }
                        .alert("Re-download Model?", isPresented: $showRedownloadConfirmation) {
                            Button("Re-download", role: .destructive) { redownloadModel() }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("The working \(modelManager.activeBackend.shortName) model (\(modelManager.activeBackend.sizeDescription)) will be deleted and downloaded again. Dictation is unavailable until the download finishes.")
                        }
                    }
                }
            }

            Section("Voice Activity Detection") {
                vadToggleRow
            }

            if legacyDataBytes > 0 {
                Section("Old Models") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Free up \(Self.formatBytes(legacyDataBytes))")
                            Text("Models from earlier versions of Murmur are still on disk and are no longer used.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            showRemoveLegacyConfirmation = true
                        }
                        .alert("Remove Old Models?", isPresented: $showRemoveLegacyConfirmation) {
                            Button("Remove", role: .destructive) {
                                modelManager.deleteLegacyData()
                                legacyDataBytes = modelManager.legacyDataSize()
                            }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("\(Self.formatBytes(legacyDataBytes)) of models from earlier versions of Murmur will be permanently deleted.")
                        }
                    }
                }
            }

            Section("Transcription Correction") {
                transcriptionCorrectionRow
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
        .onAppear { legacyDataBytes = modelManager.legacyDataSize() }
    }

    @ViewBuilder
    private var transcriptionCorrectionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent {
                Toggle("Correct transcription errors", isOn: $correctTranscription)
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
                .accessibilityLabel("Glossary")
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
                    .accessibilityLabel("Correction prompt")
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
            Text(isOver ? "\(count) / 4000 (over limit)" : "\(count) / 4000")
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

            if !localLLMAPIKey.isEmpty,
               let url = URL(string: localLLMBaseURL),
               !OpenAICompatibleCorrector.allowsAPIKey(over: url) {
                Text("The API key is not sent over plain http:// to another machine, so correction is off for this server. Use an https:// URL, or clear the API key.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Toggle row for the Silero VAD aux model. When ON, drives the live
    /// silence gate and hands-free auto-stop.
    @ViewBuilder
    private var vadToggleRow: some View {
        let isOn = modelManager.useVAD
        let auxState = modelManager.auxiliaryState(for: .sileroVad)
        let isReady: Bool = {
            if case .ready = auxState { return true }
            return false
        }()
        let isDownloading: Bool = {
            if case .downloading = auxState { return true }
            return false
        }()

        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { isOn },
                set: { newValue in
                    if newValue && !isReady {
                        Task { await downloadVadFromToggle() }
                    } else {
                        _ = modelManager.setUseVAD(newValue)
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Silero voice activity detection")
                        .font(.body)
                    Text("\(AuxiliaryModel.sileroVad.sizeDescription) additional · "
                         + "More reliable silence detection, and required for "
                         + "hands-free auto-stop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isDownloading)

            if isDownloading,
               let progress = modelManager.auxiliaryProgress[.sileroVad] {
                ProgressView(value: progress).controlSize(.small)
            }
        }
    }

    /// Download the Silero VAD aux model on behalf of a user enabling
    /// the toggle. On success, commit the toggle ON; on failure, leave OFF.
    private func downloadVadFromToggle() async {
        do {
            try await modelManager.downloadAuxiliary(.sileroVad)
            _ = modelManager.setUseVAD(true)
        } catch {
            // Error surfaces via auxiliary state; toggle simply stays OFF.
        }
    }

    // MARK: - Helpers

    /// Registers the custom shortcut and persists it, so the next launch
    /// registers the same one.
    private func applyHotkey() {
        let trigger = HotkeyTrigger.keyCombo(key: hotkeyKey, modifiers: hotkeyModifiers)
        coordinator.hotkey.register(trigger: trigger)
        HotkeyPreference.save(trigger)
    }

    private func redownloadModel() {
        Task { try? modelManager.delete(); try? await modelManager.download() }
    }

    /// Mirrors what the app registered at launch, so the toggle never shows
    /// "off" while Right Command is the live trigger.
    private func loadSavedHotkey() {
        switch HotkeyPreference.load() {
        case .rightCommand:
            useRightCommand = true
        case .keyCombo(let key, let modifiers):
            hotkeyKey = key
            hotkeyModifiers = modifiers
            useRightCommand = false
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
