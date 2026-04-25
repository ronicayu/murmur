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
                    Text("Used when audio detection is unsure.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent {
                    Toggle("", isOn: $autoDetectLanguage)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!modelManager.isAuxiliaryDownloaded(.lidWhisperTiny))
                        .onChange(of: autoDetectLanguage) { _, newValue in
                            if newValue && !modelManager.isAuxiliaryDownloaded(.lidWhisperTiny) {
                                Task { try? await modelManager.downloadAuxiliary(.lidWhisperTiny) }
                            }
                        }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-detect language from audio")
                        Text("Uses a separate small model (~40 MB). Overrides manual selection when confident.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if streamingInputEnabled {
                            Text("Streaming voice input uses the active input source — audio detection runs on full-pass transcription only.")
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

                DisclosureGroup("Advanced", isExpanded: $showAdvancedEngines) {
                    engineRow(.huggingface)
                    engineRow(.whisper)
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

            Section("Language Detection") {
                lidModelRow
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
    private var lidModelRow: some View {
        let state = modelManager.auxiliaryState(for: .lidWhisperTiny)
        let isDownloaded = modelManager.isAuxiliaryDownloaded(.lidWhisperTiny)
        let isBusy: Bool = {
            if case .downloading = state { return true }
            if case .verifying = state { return true }
            return false
        }()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AuxiliaryModel.lidWhisperTiny.displayName)
                        .font(.body)
                    Text(AuxiliaryModel.lidWhisperTiny.sizeDescription
                        + (isDownloaded ? " · Downloaded" : ""))
                        .font(.caption)
                        .foregroundStyle(isDownloaded ? .green : .secondary)
                }
                Spacer()
                if isDownloaded {
                    Button("Delete", role: .destructive) {
                        try? modelManager.deleteAuxiliary(.lidWhisperTiny)
                    }
                    .buttonStyle(.bordered)
                } else if !isBusy {
                    Button("Download") {
                        Task { try? await modelManager.downloadAuxiliary(.lidWhisperTiny) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if case .downloading(_, let speed) = state {
                ProgressView().progressViewStyle(.linear)
                HStack {
                    if let msg = modelManager.auxiliaryStatusMessage[.lidWhisperTiny], !msg.isEmpty {
                        Text(msg)
                    }
                    Spacer()
                    if speed > 0 { Text(formatSpeed(speed)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if case .error(let msg) = state {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if case .verifying = state {
                Text("Verifying…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var transcriptionCorrectionRow: some View {
        LabeledContent {
            Toggle("", isOn: $correctTranscription)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Correct transcription errors")
                Text("Uses Apple's on-device model to fix homophone mistakes and phonetic errors while preserving your original meaning. Adds up to 2.5 s; falls back to the raw transcription on timeout. Requires macOS 26 and Apple Intelligence. V1 full-pass only — streaming is bypassed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
