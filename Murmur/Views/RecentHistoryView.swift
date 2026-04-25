import SwiftUI

/// Stand-alone view for the "Recent transcriptions" window. Shows the
/// in-memory list of recent V1/V3 transcriptions from `AppCoordinator`,
/// including the before/after diff when the LLM correction step rewrote the
/// text. Row click copies the (corrected) text to the pasteboard.
struct RecentHistoryView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 0) {
            if coordinator.transcriptionHistory.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 360, minHeight: 300)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No transcriptions yet")
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Use your hotkey to record. Results appear here.")
                .font(.system(.caption))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(coordinator.transcriptionHistory.enumerated()), id: \.offset) { _, entry in
                    row(text: entry.text,
                        rawText: entry.rawText,
                        language: entry.language,
                        date: entry.date)
                    Divider()
                        .opacity(0.35)
                }
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(text: String, rawText: String?, language: DetectedLanguage, date: Date) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                // Header: timestamp + language + copy glyph
                HStack(spacing: 8) {
                    Text(timestampLabel(date))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(languageLabel(language))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    if rawText != nil {
                        Label("Corrected", systemImage: "wand.and.stars")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                // Corrected (what was actually injected)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Raw — strike-through only when correction changed the text
                if let rawText, !rawText.isEmpty {
                    Text(rawText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .strikethrough(true, color: .secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func timestampLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if Calendar.current.isDateInYesterday(date) {
            return "Yesterday " + date.formatted(date: .omitted, time: .shortened)
        } else {
            formatter.dateFormat = "MMM d, HH:mm"
        }
        return formatter.string(from: date)
    }

    private func languageLabel(_ lang: DetectedLanguage) -> String {
        switch lang {
        case .chinese: return "中文"
        case .english: return "EN"
        case .unknown: return "?"
        }
    }
}
