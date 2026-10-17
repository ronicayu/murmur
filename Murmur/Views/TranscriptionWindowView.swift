import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Window-level state machine

enum TranscriptionWindowState {
    case idle
    case recording(startTime: Date)
    case recordingConfirm(duration: TimeInterval, fileSizeBytes: Int64, outputURL: URL)
    case uploadConfirm(fileURL: URL, duration: TimeInterval)
    case transcribing(progress: TranscriptionProgress?)
    case cancelConfirm(progressPercent: Int)
    case result(entry: TranscriptionEntry)
}

// MARK: - Problems

/// News about something that went wrong, shown as a banner over whatever the
/// window shows. Not a state: a refused start must keep the confirm screen.
enum TranscriptionWindowProblem: Equatable {
    case unsupportedFormat(ext: String)
    case unreadableAudio
    case tooLong(duration: TimeInterval)
    case notEnoughDiskSpace
    case recordingFailed(reason: String)
    case dictationInProgress
    /// `retryEntryID` is set when Murmur kept its own recording, so Try Again
    /// can transcribe it again.
    case transcriptionFailed(reason: String, retryEntryID: UUID?)
    case recordingSavedForLater

    /// What happened.
    var title: String {
        switch self {
        case .unsupportedFormat(let ext): return "Murmur can't open .\(ext) files"
        case .unreadableAudio: return "Murmur couldn't read this file"
        case .tooLong: return "This file is longer than \(Self.hours(LongRecordingService.maxDurationSeconds))"
        case .notEnoughDiskSpace: return "Not enough free disk space"
        case .recordingFailed: return "Recording failed"
        case .dictationInProgress: return "Voice dictation is still running"
        case .transcriptionFailed: return "Transcription failed"
        case .recordingSavedForLater:
            return "Recording stopped at \(Self.hours(LongRecordingService.maxDurationSeconds))"
        }
    }

    /// What to do about it.
    var message: String {
        switch self {
        case .unsupportedFormat:
            return "Use \(Self.acceptedFormats) file."
        case .unreadableAudio:
            return "The file may be damaged or not an audio file."
        case .tooLong(let duration):
            let minutes = Int(duration) / 60
            return "It is \(minutes / 60) h \(minutes % 60) min long. "
                + "Files can be up to \(Self.hours(LongRecordingService.maxDurationSeconds)). "
                + "Split the file and try again."
        case .notEnoughDiskSpace:
            let gigabytes = LongRecordingService.minimumFreeSpaceBytes / (1024 * 1024 * 1024)
            return "Free at least \(gigabytes) GB, then try again."
        case .recordingFailed(let reason):
            return reason
        case .dictationInProgress:
            return "Start the transcription again when it is done."
        case .transcriptionFailed(let reason, let retryEntryID):
            return Self.sentence(reason) + (retryEntryID != nil
                ? " Your recording is saved."
                : " Try again with the same file.")
        case .recordingSavedForLater:
            return "It is saved in the list. Transcribe it when the current transcription is done."
        }
    }

    /// `text` with a full stop at the end. The engine's reasons have none
    /// ("The speech engine stopped unexpectedly"), and a second sentence follows.
    private static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?。！？".contains(last) else { return text }
        return text + "."
    }

    /// "2 hours" for the duration cap.
    private static func hours(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// "a CAF, M4A, MP3, OGG or WAV", from the formats the upload accepts.
    private static var acceptedFormats: String {
        let names = UploadFormatValidator.acceptedExtensions.sorted().map { $0.uppercased() }
        let list = names.count > 1
            ? names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
            : names.joined()
        // The article follows how the first name is read: "an MP3", "a WAV".
        let readWithAVowel = "AEFHILMNORSX"
        let article = names.first.map { readWithAVowel.contains($0.prefix(1)) } == true ? "an" : "a"
        return "\(article) \(list)"
    }
}

// MARK: - TranscriptionWindowView

struct TranscriptionWindowView: View {
    @ObservedObject var historyService: TranscriptionHistoryService
    @ObservedObject var coordinator: AppCoordinator
    /// Owned by the window controller, so a transcription, its progress and
    /// any problem outlive the window being closed and opened again.
    @ObservedObject var windowModel: TranscriptionWindowModel

    // Sidebar selection
    @State private var selectedEntryID: UUID?
    @State private var showCancelConfirm = false
    // P1-1: sidebar search
    @State private var searchQuery: String = ""
    @AppStorage(TranscriptFormat.showTimestampsKey) private var showTimestamps = true

    init(
        historyService: TranscriptionHistoryService,
        coordinator: AppCoordinator,
        windowModel: TranscriptionWindowModel
    ) {
        self.historyService = historyService
        self.coordinator = coordinator
        self.windowModel = windowModel
    }

    var body: some View {
        HSplitView {
            sidebarView
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 280)

            mainAreaView
                .frame(minWidth: 440)
        }
        .frame(minWidth: 640, idealWidth: 780, minHeight: 480, idealHeight: 560)
        // `initial`: a problem set while the window was closed is announced
        // when it opens again.
        .onChange(of: windowModel.problemsPosted, initial: true) {
            // The banner does not take focus, so VoiceOver would not read it.
            guard let problem = windowModel.problem, let app = NSApp else { return }
            NSAccessibility.post(
                element: app,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "\(problem.title). \(problem.message)",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(spacing: 0) {
            // "New" button
            Button {
                selectedEntryID = nil
                windowModel.transitionToIdle()
            } label: {
                Label("New", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.top, 8)
            // "New" would hide a running recording or transcription with no
            // way back to it.
            .disabled(windowModel.hasActiveSession)
            .help(windowModel.hasActiveSession ? "Finish or cancel the current recording or transcription first." : "")

            Divider()

            // P1-1: search bar
            TextField("Search", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            Divider()

            // Active session indicator (if recording/transcribing)
            if windowModel.hasActiveSession {
                activeSessionRow
                    .padding(.vertical, 4)
                Divider()
            }

            // History list
            historyList

            Divider()

            // Settings button
            Button {
                // Post notification for settings — AppCoordinator opens settings window
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private var activeSessionRow: some View {
        switch windowModel.windowState {
        case .recording(let startTime):
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .pulsing()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recording")
                        .font(.system(.caption, design: .rounded))
                        .fontWeight(.medium)
                    Text(elapsedTime(from: startTime))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)

        case .transcribing(let progress):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Transcribing")
                        .font(.system(.caption, design: .rounded))
                        .fontWeight(.medium)
                    if let p = progress {
                        Text("\(Int(Double(p.currentChunk) / Double(p.totalChunks) * 100))%")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)

        default:
            EmptyView()
        }
    }

    private var historyList: some View {
        List(selection: $selectedEntryID) {
            ForEach(filteredGroupedHistory, id: \.key) { group in
                Section(group.key) {
                    ForEach(group.entries) { entry in
                        historyRow(entry)
                            .tag(entry.id)
                            .contextMenu { historyContextMenu(for: entry) }
                    }
                    .onDelete { indices in
                        let toDelete = indices.map { group.entries[$0] }
                        toDelete.forEach { try? historyService.delete(id: $0.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selectedEntryID) { _, newID in
            if let id = newID,
               let entry = historyService.getAll().first(where: { $0.id == id }) {
                windowModel.windowState = .result(entry: entry)
            }
        }
    }

    @ViewBuilder
    private func historyContextMenu(for entry: TranscriptionEntry) -> some View {
        if windowModel.retryableAudio(for: entry) != nil {
            Button {
                selectedEntryID = nil
                windowModel.retryTranscription(of: entry)
            } label: {
                Label("Retry Transcription", systemImage: "arrow.clockwise")
            }
            .disabled(windowModel.hasActiveSession)
        }
        Button(role: .destructive) {
            try? historyService.delete(id: entry.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        Button {
            exportEntry(entry)
        } label: {
            Label("Export .txt", systemImage: "square.and.arrow.up")
        }
        Button {
            copyToClipboard(entry.displayText(withTimestamps: showTimestamps))
        } label: {
            Label("Copy All", systemImage: "doc.on.doc")
        }
    }

    private func historyRow(_ entry: TranscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.date, format: .dateTime.hour().minute())
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(.medium)
                Spacer()
                Text(durationLabel(entry.audioDuration))
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
                statusBadge(entry.status)
            }
            if !entry.text.isEmpty {
                Text(entry.text.prefix(50))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusBadge(_ status: TranscriptionStatus) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .accessibilityLabel("Completed")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .accessibilityLabel("Failed")
        case .inProgress:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("In progress")
        }
    }

    // MARK: - Main area

    private var mainAreaView: some View {
        VStack(spacing: 0) {
            if let problem = windowModel.problem {
                ProblemBanner(
                    problem: problem,
                    onRetry: retryAction(for: problem),
                    onDismiss: { windowModel.dismissProblem() }
                )
            }
            windowStateView
        }
    }

    /// Try Again, only for a failed transcription whose recording Murmur kept.
    private func retryAction(for problem: TranscriptionWindowProblem) -> (() -> Void)? {
        guard case .transcriptionFailed(_, let entryID?) = problem else { return nil }
        return {
            selectedEntryID = nil
            windowModel.retryFailedTranscription(entryID: entryID)
        }
    }

    @ViewBuilder
    private var windowStateView: some View {
        switch windowModel.windowState {
        case .idle:
            IdleView(
                onRecord: { windowModel.startRecording() },
                onUpload: { windowModel.openFilePicker() },
                onFileDrop: { urls in windowModel.handleDroppedFile(urls.first) }
            )

        case .recording(let startTime):
            RecordingView(
                startTime: startTime,
                audioLevel: coordinator.currentAudioLevel,
                onStop: { windowModel.stopRecording() }
            )

        case .recordingConfirm(let duration, let size, let url):
            RecordingConfirmView(
                duration: duration,
                fileSizeBytes: size,
                onDiscard: { windowModel.discardRecording(url: url) },
                onStart: { windowModel.beginTranscription(audioURL: url) }
            )

        case .uploadConfirm(let fileURL, let duration):
            UploadConfirmView(
                fileURL: fileURL,
                duration: duration,
                onCancel: { windowModel.transitionToIdle() },
                onStart: { windowModel.beginTranscription(audioURL: fileURL) }
            )

        case .transcribing(let progress):
            TranscribingView(
                progress: progress,
                onCancel: {
                    if let p = progress {
                        let pct = Int(Double(p.currentChunk) / Double(p.totalChunks) * 100)
                        windowModel.windowState = .cancelConfirm(progressPercent: pct)
                    } else {
                        windowModel.windowState = .cancelConfirm(progressPercent: 0)
                    }
                }
            )

        case .cancelConfirm(let pct):
            CancelConfirmView(
                progressPercent: pct,
                onKeepGoing: { windowModel.resumeAfterCancelConfirm() },
                onCancelAnyway: { windowModel.cancelTranscription() }
            )

        case .result(let entry):
            ResultView(
                entry: entry,
                isHistoryMode: selectedEntryID != nil,
                onNew: {
                    selectedEntryID = nil
                    windowModel.transitionToIdle()
                },
                onBack: { selectedEntryID = nil },
                onRetry: windowModel.retryableAudio(for: entry) == nil ? nil : {
                    selectedEntryID = nil
                    windowModel.retryTranscription(of: entry)
                }
            )
        }
    }

    // MARK: - Helpers

    /// History entries after applying the sidebar search filter.
    private var filteredEntries: [TranscriptionEntry] {
        TranscriptionHistoryFilter.filter(historyService.getAll(), query: searchQuery)
    }

    /// Grouped and filtered entries for the sidebar list.
    private var filteredGroupedHistory: [(key: String, entries: [TranscriptionEntry])] {
        groupedEntries(filteredEntries)
    }

    private func groupedEntries(_ allEntries: [TranscriptionEntry]) -> [(key: String, entries: [TranscriptionEntry])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        var groups: [(key: String, entries: [TranscriptionEntry])] = []
        var buckets: [String: [TranscriptionEntry]] = [:]

        for entry in allEntries {
            let entryDay = calendar.startOfDay(for: entry.date)
            let key: String
            if entryDay == today {
                key = "Today"
            } else if entryDay == yesterday {
                key = "Yesterday"
            } else if calendar.dateComponents([.day], from: entryDay, to: today).day ?? 0 < 7 {
                key = entry.date.formatted(.dateTime.weekday(.wide))
            } else {
                key = entry.date.formatted(.dateTime.month(.abbreviated).day())
            }
            buckets[key, default: []].append(entry)
        }

        // Preserve display order: Today → Yesterday → remaining buckets sorted by
        // the date of their newest entry (descending), so most-recent days appear first.
        let remainingKeys = buckets.keys
            .filter { $0 != "Today" && $0 != "Yesterday" }
            .sorted { lhs, rhs in
                let lhsDate = buckets[lhs]?.first?.date ?? .distantPast
                let rhsDate = buckets[rhs]?.first?.date ?? .distantPast
                return lhsDate > rhsDate
            }
        let orderedKeys = ["Today", "Yesterday"] + remainingKeys
        for key in orderedKeys {
            if let entries = buckets[key], !entries.isEmpty {
                groups.append((key: key, entries: entries))
            }
        }
        return groups
    }

    private func elapsedTime(from start: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(start))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        let m = t / 60
        let s = t % 60
        return m > 60
            ? String(format: "%dh %02dm", m / 60, m % 60)
            : String(format: "%d:%02d", m, s)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportEntry(_ entry: TranscriptionEntry) {
        let panel = NSSavePanel()
        let dateStr = entry.date.formatted(.dateTime.year().month().day().hour().minute())
        panel.nameFieldStringValue = "Transcription \(dateStr).txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? entry.displayText(withTimestamps: showTimestamps).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let openSettings = Notification.Name("com.murmur.openSettings")
    static let openTranscriptionWindow = Notification.Name("com.murmur.openTranscriptionWindow")
}
