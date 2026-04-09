import SwiftUI

struct MenuBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status
            HStack {
                statusIcon
                Text(coordinator.state.statusText)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Last transcription
            if let text = coordinator.lastTranscription {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Last transcription")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(text)
                                .font(.system(.body, design: .rounded))
                                .lineLimit(2)
                        }
                        Spacer()
                        if let lang = coordinator.lastLanguage {
                            Text(lang == .chinese ? "中" : "EN")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()
            }

            // Hotkey reminder
            HStack {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)
                Text("Ctrl + Space")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Settings
            Button("Settings...") {
                onOpenSettings()
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title == "Murmur Settings" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Quit
            Button("Quit Murmur") {
                coordinator.stop()
                NSApplication.shared.terminate(nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch coordinator.state {
        case .idle:
            Image(systemName: "mic")
                .foregroundStyle(.secondary)
        case .recording:
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .injecting:
            Image(systemName: "text.cursor")
                .foregroundStyle(.blue)
        case .undoable:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
