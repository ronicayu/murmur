import SwiftUI
import ServiceManagement
import HotKey

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var modelManager: ModelManager
    @AppStorage("recordingMode") private var recordingMode: String = RecordingMode.toggle.rawValue
    @AppStorage("soundEffects") private var soundEffects: Bool = true
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = true

    @State private var hotkeyKey: Key = .space
    @State private var hotkeyModifiers: NSEvent.ModifierFlags = .control

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            modelTab
                .tabItem { Label("Model", systemImage: "cpu") }
        }
        .frame(width: 420, height: 320)
        .padding()
        .onAppear { loadSavedHotkey() }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Hotkey") {
                HStack {
                    Text("Trigger:")
                    Spacer()
                    HotkeyRecorderView(key: $hotkeyKey, modifiers: $hotkeyModifiers)
                        .onChange(of: hotkeyKey) { _, _ in applyHotkey() }
                        .onChange(of: hotkeyModifiers) { _, _ in applyHotkey() }
                }
            }

            Section("Recording Mode") {
                Picker("Mode:", selection: $recordingMode) {
                    Text("Toggle (tap to start, tap to stop)")
                        .tag(RecordingMode.toggle.rawValue)
                    Text("Hold (hold to record, release to stop)")
                        .tag(RecordingMode.hold.rawValue)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: recordingMode) { _, newValue in
                    if let mode = RecordingMode(rawValue: newValue) {
                        coordinator.hotkey.setMode(mode)
                    }
                }
            }

            Section("Behavior") {
                Toggle("Sound effects", isOn: $soundEffects)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }
        }
    }

    // MARK: - Model Tab

    private var modelTab: some View {
        Form {
            Section("Cohere Transcribe") {
                LabeledContent("Status:") {
                    modelStatusBadge
                }

                LabeledContent("Location:") {
                    Text(modelManager.modelDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if case .downloading(let progress, let speed) = modelManager.state {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))% — \(formatSpeed(speed))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    if modelManager.state == .ready {
                        Button("Delete Model", role: .destructive) {
                            try? modelManager.delete()
                        }
                    } else if case .downloading = modelManager.state {
                        Button("Cancel Download") {
                            modelManager.cancelDownload()
                        }
                    } else {
                        Button("Download Model") {
                            Task { try? await modelManager.download() }
                        }
                    }

                    Spacer()

                    if modelManager.state == .ready || modelManager.state == .corrupt {
                        Button("Re-download") {
                            Task {
                                try? modelManager.delete()
                                try? await modelManager.download()
                            }
                        }
                    }
                }
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

    // MARK: - Helpers

    private func applyHotkey() {
        coordinator.hotkey.register(key: hotkeyKey, modifiers: hotkeyModifiers)
    }

    private func loadSavedHotkey() {
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
