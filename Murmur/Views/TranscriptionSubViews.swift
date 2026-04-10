import SwiftUI
import AppKit
import AVFoundation

// MARK: - IdleView
//
// Two action cards: Record and Upload. Entire area is a drop zone.

struct IdleView: View {
    let onRecord: () -> Void
    let onUpload: () -> Void
    let onFileDrop: ([URL]) -> Void

    @State private var isDragTarget = false

    var body: some View {
        ZStack {
            // Drop zone overlay
            if isDragTarget {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(16)
                    .overlay(
                        Text("Drop audio file here")
                            .font(.system(.headline, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                    )
            }

            VStack(spacing: 16) {
                Spacer()

                // Record card
                ActionCard(
                    icon: "mic.circle",
                    title: "Record Audio",
                    subtitle: "Tap to start recording",
                    action: onRecord
                )

                // Upload card
                ActionCard(
                    icon: "doc.badge.plus",
                    title: "Upload Audio File",
                    subtitle: ".mp3  .m4a  .caf  .ogg  ·  < 2hr  ·  on-device",
                    action: onUpload
                )

                Text("Drop audio file here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)

                Spacer()
            }
            .padding(.horizontal, 40)
        }
        .onDrop(of: [.audio, .fileURL], isTargeted: $isDragTarget) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async { onFileDrop([url]) }
                    }
                }
            }
            return true
        }
    }
}

// MARK: - ActionCard

private struct ActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: 320)
            .background(
                isHovered
                    ? Color(NSColor.tertiarySystemFill)
                    : Color(NSColor.secondarySystemFill),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
    }
}

// MARK: - RecordingView

struct RecordingView: View {
    let startTime: Date
    let audioLevel: Float
    let onStop: () -> Void

    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // Recording indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .symbolEffect(.pulse)
                Text("Recording")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.red)
            }

            // Timer
            Text(elapsedFormatted)
                .font(.system(.title, design: .monospaced))
                .monospacedDigit()

            // Waveform bars
            WaveformView(audioLevel: audioLevel)
                .frame(height: 24)
                .frame(maxWidth: 240)

            Spacer()

            // Stop button
            Button(action: onStop) {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Stop Recording")
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .frame(width: 240, height: 44)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])

            // Voice input pause notice
            Text("Voice input paused")
                .font(.caption2)
                .foregroundStyle(Color(NSColor.systemOrange))
                .padding(.bottom, 16)

            Spacer()
        }
        .onReceive(timer) { _ in
            elapsed = Date().timeIntervalSince(startTime)
        }
        .onAppear {
            elapsed = Date().timeIntervalSince(startTime)
        }
    }

    private var elapsedFormatted: String {
        let t = Int(elapsed)
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - WaveformView

struct WaveformView: View {
    let audioLevel: Float
    private let barCount = 8

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 6, height: barHeight(for: i))
                    .animation(.easeInOut(duration: 0.1), value: audioLevel)
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        // Slightly randomize bar heights around audio level for visual interest
        let base = max(4, CGFloat(audioLevel) * 24)
        let offset = CGFloat(sin(Double(index) * 1.3)) * 4
        return min(24, max(4, base + offset))
    }
}

// MARK: - RecordingConfirmView

struct RecordingConfirmView: View {
    let duration: TimeInterval
    let fileSizeBytes: Int64
    let onDiscard: () -> Void
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("Recording complete")
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.semibold)

                Divider()

                infoRow("Duration", value: durationLabel(duration))
                infoRow("File size", value: fileSizeLabel(fileSizeBytes))
                infoRow("Est. time", value: estimatedTimeLabel(duration))
            }
            .frame(maxWidth: 360)
            .padding(20)
            .background(Color(NSColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 16) {
                Button("Discard", action: onDiscard)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(NSColor.systemRed))

                Button("Start Transcription", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .rounded))
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func durationLabel(_ s: TimeInterval) -> String {
        let t = Int(s)
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%02d:%02d", t / 60, t % 60)
    }

    private func fileSizeLabel(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        return mb >= 1000
            ? String(format: "%.1f GB", mb / 1024)
            : String(format: "%.0f MB", mb)
    }

    /// Estimated transcription time range based on Phase 0 benchmark (RTF ≈ 1x on M1 8GB).
    /// Shows a range rather than a precise value per UX spec.
    private func estimatedTimeLabel(_ audioDuration: TimeInterval) -> String {
        guard audioDuration > 0 else { return "a few minutes" }
        let rtfLow = 0.8
        let rtfHigh = 1.2
        let low = Int(audioDuration * rtfLow / 60)
        let high = Int(ceil(audioDuration * rtfHigh / 60))
        if high < 1 {
            return "< 1 min"
        }
        return "~\(max(1, low))–\(high) min"
    }
}

// MARK: - UploadConfirmView

struct UploadConfirmView: View {
    let fileURL: URL
    let duration: TimeInterval
    let onCancel: () -> Void
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("Ready to transcribe")
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.semibold)

                Divider()

                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.secondary)
                    Text(fileURL.lastPathComponent)
                        .font(.system(.body, design: .rounded))
                        .lineLimit(1)
                }
                .padding(.vertical, 2)

                infoRow("Duration", value: durationLabel(duration))
                infoRow("Est. time", value: estimatedTimeLabel(duration))

                // Decision-point pause warning (UX spec §4.4.3)
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color(NSColor.systemOrange))
                    Text("Voice input will pause during transcription.")
                        .font(.caption)
                        .foregroundStyle(Color(NSColor.systemOrange))
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 360)
            .padding(20)
            .background(Color(NSColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 16) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Button("Start Transcription", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .rounded))
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func durationLabel(_ s: TimeInterval) -> String {
        let t = Int(s)
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%02d:%02d", t / 60, t % 60)
    }

    private func estimatedTimeLabel(_ audioDuration: TimeInterval) -> String {
        guard audioDuration > 0 else { return "a few minutes" }
        let low = Int(audioDuration * 0.8 / 60)
        let high = Int(ceil(audioDuration * 1.2 / 60))
        return high < 1 ? "< 1 min" : "~\(max(1, low))–\(high) min"
    }
}

// MARK: - TranscribingView

struct TranscribingView: View {
    let progress: TranscriptionProgress?
    let onCancel: () -> Void

    private var progressFraction: Double {
        guard let p = progress, p.totalChunks > 0 else { return 0 }
        return Double(p.currentChunk) / Double(p.totalChunks)
    }

    private var progressPercent: Int {
        Int(progressFraction * 100)
    }

    private var remainingTimeLabel: String {
        guard let p = progress, p.totalChunks > 0, p.currentChunk > 0 else {
            return "Estimating..."
        }
        // Rough ETA: assume remaining chunks take proportional time
        // We show a range — never a precise second count
        let done = p.currentChunk
        let remaining = p.totalChunks - done
        // Ballpark: each chunk ~30s audio at ~1x RTF
        let estLow = max(1, remaining / 2)
        let estHigh = remaining + 1
        if estHigh <= 1 {
            return "< 1 min remaining"
        }
        return "About \(estLow)–\(estHigh) min remaining"
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("Transcribing...")
                .font(.system(.title2, design: .rounded))
                .fontWeight(.semibold)

            VStack(spacing: 8) {
                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(NSColor.separatorColor))
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * progressFraction, height: 4)
                            .animation(.linear(duration: 0.3), value: progressFraction)
                    }
                }
                .frame(maxWidth: 400, maxHeight: 4)

                HStack {
                    Text(remainingTimeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(progressPercent)%")
                        .font(.system(.body, design: .rounded))
                        .monospacedDigit()
                }
                .frame(maxWidth: 400)

                if let p = progress {
                    Text("Processing segment \(p.currentChunk) of \(p.totalChunks)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Button("Cancel") { onCancel() }
                .buttonStyle(.plain)
                .foregroundStyle(Color(NSColor.systemRed))

            // Voice input pause notice
            Text("Voice input paused")
                .font(.caption2)
                .foregroundStyle(Color(NSColor.systemOrange))
                .padding(.top, 8)

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - CancelConfirmView

struct CancelConfirmView: View {
    let progressPercent: Int
    let onKeepGoing: () -> Void
    let onCancelAnyway: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 12) {
                Text("Cancel transcription?")
                    .font(.system(.headline, design: .rounded))

                Text("Progress will be lost (\(progressPercent)% done).")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(Color(NSColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 16) {
                Button("Keep going", action: onKeepGoing)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.escape, modifiers: [])

                Button("Cancel anyway", action: onCancelAnyway)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(NSColor.systemRed))
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - ResultView

struct ResultView: View {
    let entry: TranscriptionEntry
    let isHistoryMode: Bool
    let onNew: () -> Void
    let onBack: () -> Void

    @State private var copyButtonLabel = "Copy All"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isHistoryMode ? entry.date.formatted(date: .long, time: .shortened) : "Transcription complete")
                        .font(.system(.headline, design: .rounded))

                    HStack(spacing: 8) {
                        Text(durationLabel(entry.audioDuration))
                        Text("·")
                        Text(entry.language.uppercased())
                        if !isHistoryMode {
                            Text("·")
                            Text(entry.date.formatted(date: .omitted, time: .shortened))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Transcript text — NSTextView via ScrollView for full selection + Cmd+F support
            SelectableTextView(text: entry.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            // Actions
            HStack(spacing: 0) {
                actionButton(
                    icon: "doc.on.doc",
                    label: copyButtonLabel,
                    shortcut: "C"
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    copyButtonLabel = "Copied!"
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copyButtonLabel = "Copy All"
                    }
                }

                Divider().frame(height: 24)

                actionButton(
                    icon: "square.and.arrow.up",
                    label: "Export .txt",
                    shortcut: "S"
                ) {
                    exportText(entry)
                }

                Divider().frame(height: 24)

                actionButton(
                    icon: isHistoryMode ? "arrow.left" : "arrow.counterclockwise",
                    label: isHistoryMode ? "Back" : "New",
                    shortcut: isHistoryMode ? nil : "N"
                ) {
                    if isHistoryMode { onBack() } else { onNew() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.secondarySystemFill))
        }
        .keyboardShortcut("n", modifiers: .command, action: { onNew() })
    }

    private func actionButton(
        icon: String,
        label: String,
        shortcut: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(label)
                    .font(.system(.callout, design: .rounded))
                if let sc = shortcut {
                    Text("⌘\(sc)")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func durationLabel(_ s: TimeInterval) -> String {
        let t = Int(s)
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%02d:%02d", t / 60, t % 60)
    }

    private func exportText(_ entry: TranscriptionEntry) {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        panel.nameFieldStringValue = "Transcription \(formatter.string(from: entry.date)).txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? entry.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - SelectableTextView (NSTextView wrapper)
//
// SwiftUI TextEditor is not read-only. We wrap NSTextView directly
// to get: read-only, selectable, Cmd+F find, scroll.

struct SelectableTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
}

// MARK: - View extension for keyboard shortcuts on buttons

private extension View {
    @ViewBuilder
    func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers, action: @escaping () -> Void) -> some View {
        // This extension provides a workaround for adding keyboard shortcuts inside non-Button views.
        // Shortcuts attached directly to Button(action:) are preferred; this handles edge cases.
        self.background(
            Button("", action: action)
                .keyboardShortcut(key, modifiers: modifiers)
                .opacity(0)
        )
    }
}
