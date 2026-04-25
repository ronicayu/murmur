import SwiftUI
import HotKey

struct MenuBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage: String = "auto"
    @AppStorage("streamingInputEnabled") private var streamingInputEnabled: Bool = false
    var onOpenSettings: () -> Void = {}
    var onOpenTranscription: () -> Void = {}
    var onOpenRecentHistory: () -> Void = {}

    private static let allLanguages: [(code: String, label: String)] = [
        ("auto", "Auto"),
        ("en", "English"),
        ("zh", "中文"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("pt", "Português"),
        ("it", "Italiano"),
        ("nl", "Nederlands"),
        ("pl", "Polski"),
        ("el", "Ελληνικά"),
        ("ar", "العربية"),
        ("vi", "Tiếng Việt"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // ── Status header ──
            statusHeader
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            sectionDivider

            // ── Actions ──
            VStack(spacing: 0) {
                menuButton(
                    icon: "clock.arrow.circlepath",
                    label: "Recent Transcriptions",
                    trailing: recentHistoryTrailing
                ) {
                    onOpenRecentHistory()
                }

                menuButton(icon: "waveform", label: "Transcription", trailing: .shortcut("⌘⇧T")) {
                    onOpenTranscription()
                }

                // Language picker — styled as inline menu row
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .center)
                    Text("Language")
                        .font(.system(size: 13))
                    Spacer()
                    Picker("", selection: $transcriptionLanguage) {
                        ForEach(Self.allLanguages, id: \.code) { lang in
                            Text(lang.label).tag(lang.code)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)

                menuButton(icon: "gear", label: "Settings...") {
                    onOpenSettings()
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.title == "Murmur Settings" }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }
            .padding(.vertical, 4)

            sectionDivider

            // ── Quit ──
            menuButton(icon: "power", label: "Quit Murmur") {
                coordinator.stop()
                NSApplication.shared.terminate(nil)
            }
            .padding(.vertical, 4)
        }
        .frame(width: 300)
    }

    // MARK: - Section Divider

    private var sectionDivider: some View {
        Divider()
            .padding(.horizontal, 12)
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("Murmur")
                        .font(.system(size: 13, weight: .semibold, design: .default))
                    if streamingInputEnabled, case .idle = coordinator.state {
                        Text("Streaming")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
                Text(coordinator.state.statusText)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(statusColor)
            }

            Spacer()

            // Active session indicator in header
            if isRecordingOrTranscribing {
                recordingPulse
            }
        }
    }

    private var isRecordingOrTranscribing: Bool {
        switch coordinator.state {
        case .recording, .streaming, .transcribing: return true
        default: return false
        }
    }

    private var recordingPulse: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.red.opacity(0.3), lineWidth: 2)
                    .frame(width: 14, height: 14)
            )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch coordinator.state {
        case .idle:
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
        case .recording:
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
        case .streaming:
            Image(systemName: "waveform")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .injecting:
            Image(systemName: "text.cursor")
                .font(.system(size: 20))
                .foregroundStyle(.blue)
        case .undoable:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
        }
    }

    private var statusColor: Color {
        switch coordinator.state {
        case .idle: return .secondary
        case .recording: return .red
        case .streaming: return .orange
        case .transcribing, .injecting: return .blue
        case .undoable: return .green
        case .error: return .orange
        }
    }


    private var currentLanguageLabel: String {
        Self.allLanguages.first { $0.code == transcriptionLanguage }?.label ?? transcriptionLanguage.uppercased()
    }

    /// Trailing label for the Recent menu row: show the entry count in
    /// muted text when non-empty so the row is useful even without opening
    /// the window.
    private var recentHistoryTrailing: TrailingContent {
        let count = coordinator.transcriptionHistory.count
        return count > 0 ? .dimText("\(count)") : .none
    }

    // MARK: - Menu Rows

    /// Trailing content types for menu rows
    private enum TrailingContent {
        case shortcut(String)
        case dimText(String)
        case none
    }

    private func menuButton(
        icon: String,
        label: String,
        trailing: TrailingContent = .none,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .center)

                Text(label)
                    .font(.system(size: 13))

                Spacer()

                switch trailing {
                case .shortcut(let key):
                    Text(key)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.tertiary)
                case .dimText(let text):
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                case .none:
                    EmptyView()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
    }
}

// MARK: - Button Style

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                configuration.isPressed
                    ? Color.primary.opacity(0.08)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}

#if canImport(PreviewsMacros)
#Preview("Idle") {
    MenuBarView(coordinator: AppCoordinator())
        .frame(width: 300)
}
#endif
