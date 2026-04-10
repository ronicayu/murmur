import SwiftUI
import HotKey

struct MenuBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage: String = "auto"
    var onOpenSettings: () -> Void = {}

    /// Quick-access languages shown as capsule buttons in the menu bar
    private static let quickLanguages: [(code: String, label: String)] = [
        ("auto", "Auto"),
        ("en", "EN"),
        ("zh", "中文"),
        ("ja", "日"),
        ("ko", "한"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Status header
            statusHeader
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider().padding(.horizontal, 8)

            // Language quick-switcher
            languageSwitcher
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            Divider().padding(.horizontal, 8)

            // Transcription history
            if !coordinator.transcriptionHistory.isEmpty {
                transcriptionHistorySection
                Divider().padding(.horizontal, 8)
            }

            // Actions
            menuRow(icon: "keyboard", label: hotkeyLabel, shortcut: nil, dimmed: true)

            Divider().padding(.horizontal, 8)

            menuButton(icon: "gear", label: "Settings…") {
                onOpenSettings()
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title == "Murmur Settings" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }

            menuButton(icon: "power", label: "Quit Murmur") {
                coordinator.stop()
                NSApplication.shared.terminate(nil)
            }
            .padding(.bottom, 4)
        }
        .frame(width: 260)
    }

    // MARK: - Language Quick-Switcher

    private var languageSwitcher: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Language")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.tertiary)

            HStack(spacing: 6) {
                ForEach(Self.quickLanguages, id: \.code) { lang in
                    Button {
                        transcriptionLanguage = lang.code
                    } label: {
                        Text(lang.label)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                transcriptionLanguage == lang.code
                                    ? Color.accentColor
                                    : Color.secondary.opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(
                                transcriptionLanguage == lang.code
                                    ? .white
                                    : .primary
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Language: \(lang.label)")
                    .accessibilityAddTraits(transcriptionLanguage == lang.code ? .isSelected : [])
                }

                // "More" button — shown if current language isn't in quick list
                let isQuickLang = Self.quickLanguages.contains { $0.code == transcriptionLanguage }
                Button {
                    onOpenSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Group {
                        if !isQuickLang {
                            // Show the current non-quick language name
                            Text(currentLanguageName)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                        } else {
                            Image(systemName: "ellipsis")
                                .font(.system(.caption, weight: .medium))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        !isQuickLang
                            ? Color.accentColor
                            : Color.secondary.opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundStyle(
                        !isQuickLang ? .white : .primary
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Display name for the current language (used when it's not in the quick list)
    private var currentLanguageName: String {
        let allLanguages: [(code: String, name: String)] = [
            ("auto", "Auto"), ("en", "EN"), ("zh", "中文"), ("ja", "日"), ("ko", "한"),
            ("fr", "FR"), ("de", "DE"), ("es", "ES"), ("pt", "PT"),
            ("it", "IT"), ("nl", "NL"), ("pl", "PL"), ("el", "EL"),
            ("ar", "AR"), ("vi", "VI"),
        ]
        return allLanguages.first { $0.code == transcriptionLanguage }?.name ?? transcriptionLanguage.uppercased()
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack(spacing: 10) {
            statusDot
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Murmur")
                    .font(.system(.headline, design: .rounded))
                Text(coordinator.state.statusText)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(statusColor)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch coordinator.state {
        case .idle:
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        case .recording:
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .injecting:
            Image(systemName: "text.cursor")
                .font(.system(size: 18))
                .foregroundStyle(.blue)
        case .undoable:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.orange)
        }
    }

    private var statusColor: Color {
        switch coordinator.state {
        case .idle: return .secondary
        case .recording: return .red
        case .transcribing, .injecting: return .blue
        case .undoable: return .green
        case .error: return .orange
        }
    }

    // MARK: - Transcription History

    private var transcriptionHistorySection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(coordinator.transcriptionHistory.enumerated()), id: \.offset) { _, entry in
                        transcriptionRow(entry.text, language: entry.language)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    private func transcriptionRow(_ text: String, language: DetectedLanguage) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(text)
                        .font(.system(.callout, design: .rounded))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
                Text(languageLabel(language))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private func languageLabel(_ lang: DetectedLanguage) -> String {
        switch lang {
        case .chinese: return "中文"
        case .english: return "EN"
        case .unknown: return "?"
        }
    }

    // MARK: - Menu Rows

    private var hotkeyLabel: String {
        let trigger = UserDefaults.standard.object(forKey: "useRightCommand") as? Bool ?? true
        if trigger {
            return "Right Command"
        }
        // Show the actual custom hotkey from UserDefaults
        if let keyCode = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int,
           let key = Key(carbonKeyCode: UInt32(keyCode)) {
            var parts: [String] = []
            if let modsRaw = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? UInt {
                let mods = NSEvent.ModifierFlags(rawValue: modsRaw)
                if mods.contains(.control) { parts.append("Ctrl") }
                if mods.contains(.option) { parts.append("Opt") }
                if mods.contains(.shift) { parts.append("Shift") }
                if mods.contains(.command) { parts.append("Cmd") }
            }
            parts.append(key.description)
            return parts.joined(separator: " + ")
        }
        return "Right Command"
    }

    private func menuRow(icon: String, label: String, shortcut: String?, dimmed: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .center)
            Text(label)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(dimmed ? .secondary : .primary)
            Spacer()
            if let shortcut {
                Text(shortcut)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func menuButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .center)
                Text(label)
                    .font(.system(.callout, design: .rounded))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
    }
}

// MARK: - Button Style

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                configuration.isPressed
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
    }
}
