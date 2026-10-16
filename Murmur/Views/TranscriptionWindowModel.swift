import SwiftUI
import AppKit
import AVFoundation
import Carbon
import CoreMedia
import UniformTypeIdentifiers
import os

// MARK: - FilePickerService

/// Abstracts NSOpenPanel so it can be replaced with a mock in tests.
/// - Note: @MainActor because NSOpenPanel.runModal() must run on the main thread.
@MainActor
protocol FilePickerService {
    /// Presents an open panel restricted to audio files.
    /// Returns the selected URL, or nil if the user cancelled.
    func pickAudioFile() -> URL?
}

/// Production implementation backed by NSOpenPanel.
@MainActor
final class SystemFilePickerService: FilePickerService {
    func pickAudioFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "mp3")!,
            UTType(filenameExtension: "m4a")!,
            UTType(filenameExtension: "caf")!,
            UTType(filenameExtension: "wav")!,
            UTType(filenameExtension: "ogg") ?? .audio,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - TranscriptionWindowModel
//
// ViewModel bridging AppCoordinator + LongRecordingService + TranscriptionHistoryService
// for the main TranscriptionWindow state machine.

@MainActor
final class TranscriptionWindowModel: ObservableObject {
    @Published var windowState: TranscriptionWindowState = .idle

    private let historyService: TranscriptionHistoryService
    private let coordinator: AppCoordinator
    private let recordingService: LongRecordingService
    private let diskChecker: DiskSpaceChecking
    private let filePicker: FilePickerService
    /// Injected transcription service — if nil, falls through to coordinator.transcription.
    /// Provide a test double in unit tests to avoid loading the real speech model.
    private let injectedTranscriptionService: (any TranscriptionServiceProtocol)?
    private var transcriptionTask: Task<Void, Never>?

    /// Where the audio of a transcription came from. Murmur may delete only
    /// `.ownRecording` audio; a `.userFile` is the user's own and is never
    /// deleted, nor recorded as `m4aPath` in history.
    private enum AudioSource {
        case ownRecording
        case userFile
    }

    /// A recording made by this model, and its history entry.
    private struct OwnRecording {
        let url: URL
        let entryID: UUID
    }

    /// One transcription run. `generation` tells the current run from one
    /// that `cancelTranscription()` has superseded.
    private struct TranscriptionSession {
        let generation: Int
        let entryID: UUID
        let audioURL: URL
        let source: AudioSource
        /// The run transcribes a failed entry again. Cancelling it leaves the
        /// entry failed with its recording, as it was before.
        let isRetry: Bool
    }

    /// The recording in progress or waiting in the confirm screen: not yet
    /// transcribed or discarded.
    private var pendingRecording: OwnRecording?
    /// The transcription the window currently shows. nil once it finished or was cancelled.
    private var activeTranscription: TranscriptionSession?
    private var nextGeneration = 0
    /// Transcription tasks that have not unwound yet, including cancelled ones.
    /// Voice input stays paused until this reaches zero.
    private var inFlightTranscriptions = 0
    private static let log = Logger(subsystem: "com.murmur.app", category: "window-model")

    /// The effective transcription service: injected fake in tests, real service in production.
    private var transcriptionService: any TranscriptionServiceProtocol {
        injectedTranscriptionService ?? coordinator.transcription
    }

    var hasActiveSession: Bool {
        switch windowState {
        case .recording, .transcribing: return true
        default: return false
        }
    }

    init(
        historyService: TranscriptionHistoryService,
        coordinator: AppCoordinator,
        recordingService: LongRecordingService? = nil,
        diskChecker: DiskSpaceChecking = SystemDiskSpaceChecker(),
        filePicker: FilePickerService? = nil,
        transcriptionService: (any TranscriptionServiceProtocol)? = nil
    ) {
        self.historyService = historyService
        self.coordinator = coordinator
        self.recordingService = recordingService ?? LongRecordingService()
        self.diskChecker = diskChecker
        self.filePicker = filePicker ?? SystemFilePickerService()
        self.injectedTranscriptionService = transcriptionService
        self.recordingService.onAutoStop = { [weak self] url in
            self?.recordingDidAutoStop(url: url)
        }
    }

    func onAppear() {
        // Sync window state to coordinator — e.g. reopening during active transcription
        switch coordinator.state {
        case .transcribing:
            windowState = .transcribing(progress: nil)
        default:
            break
        }
    }

    // MARK: - Idle

    func transitionToIdle() {
        // Leaving the confirm screen without Start or Discard would otherwise
        // strand the recording: its entry would stay "in progress" for ever.
        // Keep the audio and mark the entry failed, like any unfinished one.
        if case .recordingConfirm = windowState, let recording = pendingRecording {
            pendingRecording = nil
            try? historyService.updateStatus(id: recording.entryID, status: .failed)
        }
        windowState = .idle
    }

    // MARK: - Recording

    func startRecording() {
        Task {
            do {
                try await recordingService.startRecording()
                windowState = .recording(startTime: Date())

                // Add an inProgress history entry immediately
                guard let outputURL = recordingService.currentOutputURL else { return }
                let entry = TranscriptionEntry(
                    id: UUID(),
                    date: Date(),
                    audioDuration: 0,
                    text: "",
                    language: "auto",
                    status: .inProgress,
                    m4aPath: outputURL.path
                )
                pendingRecording = OwnRecording(url: outputURL, entryID: entry.id)
                try? historyService.add(entry)

            } catch LongRecordingError.insufficientDiskSpace {
                // Surface inline — state remains idle with error shown via sheet/alert
                Self.log.error("Insufficient disk space for recording")
                windowState = .idle
            } catch {
                Self.log.error("Failed to start recording: \(error)")
                windowState = .idle
            }
        }
    }

    func stopRecording() {
        Task {
            do {
                let url = try await recordingService.stopRecording()
                await presentRecordingConfirm(url: url)
            } catch {
                Self.log.error("Stop recording failed: \(error)")
                // The 2-hour auto-stop may have finished this recording already
                // and be showing its confirm screen — do not replace that.
                if case .recording = windowState {
                    windowState = .idle
                }
            }
        }
    }

    /// The service stopped the recording at the 2-hour cap. Finalise it the same
    /// way as a manual stop, so the user is offered the transcription.
    private func recordingDidAutoStop(url: URL) {
        Task {
            switch windowState {
            case .transcribing, .cancelConfirm:
                // The window is busy with another transcription and cannot show
                // the confirm screen. Close the history entry; the m4a is kept.
                if let recording = takePendingRecording(at: url) {
                    try? historyService.updateStatus(id: recording.entryID, status: .failed)
                }
            default:
                await presentRecordingConfirm(url: url)
            }
        }
    }

    private func presentRecordingConfirm(url: URL) async {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let duration = await audioDuration(of: url) ?? 0

        // Update the history entry with the actual duration now that recording is done
        if let recording = pendingRecording, duration > 0 {
            try? historyService.updateDuration(id: recording.entryID, duration: duration)
        }

        windowState = .recordingConfirm(
            duration: duration,
            fileSizeBytes: size,
            outputURL: url
        )
    }

    func discardRecording(url: URL) {
        if let recording = takePendingRecording(at: url) {
            deleteAudio(at: url, source: .ownRecording)
            try? historyService.delete(id: recording.entryID)
        }
        windowState = .idle
    }

    // MARK: - Audio ownership

    /// Returns and clears the pending recording if `url` is that recording.
    /// This is the only way audio becomes `.ownRecording`.
    private func takePendingRecording(at url: URL) -> OwnRecording? {
        guard let recording = pendingRecording,
              recording.url.standardizedFileURL == url.standardizedFileURL else { return nil }
        pendingRecording = nil
        return recording
    }

    /// The only place this model deletes audio. Deletes nothing unless the
    /// audio is Murmur's own recording AND lies in the recordings directory.
    private func deleteAudio(at url: URL, source: AudioSource) {
        guard source == .ownRecording, recordingService.ownsRecording(at: url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Upload

    func openFilePicker() {
        guard let url = filePicker.pickAudioFile() else { return }
        handleDroppedFile(url)
    }

    func handleDroppedFile(_ url: URL?) {
        guard let url else { return }
        Task {
            await validateAndConfirmUpload(url: url)
        }
    }

    private func validateAndConfirmUpload(url: URL) async {
        // Format check — delegates to UploadFormatValidator so the accepted
        // set is defined in one place and testable independently.
        let ext = url.pathExtension.lowercased()
        guard UploadFormatValidator.isAccepted(extension: ext) else {
            // Return to idle — caller shows inline error
            windowState = .idle
            return
        }

        // Duration check
        guard let dur = await audioDuration(of: url) else {
            windowState = .idle
            return
        }
        guard dur <= LongRecordingService.maxDurationSeconds else {
            windowState = .idle
            return
        }

        // Disk space check
        let freeBytes = (try? diskChecker.availableCapacityBytes()) ?? 0
        guard freeBytes >= LongRecordingService.minimumFreeSpaceBytes else {
            windowState = .idle
            return
        }

        windowState = .uploadConfirm(fileURL: url, duration: dur)
    }

    // MARK: - Transcription

    func beginTranscription(audioURL: URL) {
        // Only one transcription is tracked at a time. Starting another one
        // supersedes the earlier task, but that is not the user discarding it:
        // its entry is marked failed and its audio is kept, as for any
        // transcription that did not finish.
        if let superseded = activeTranscription {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            activeTranscription = nil
            try? historyService.updateStatus(id: superseded.entryID, status: .failed)
        }

        let source: AudioSource
        let entryID: UUID
        if let recording = takePendingRecording(at: audioURL) {
            source = .ownRecording
            entryID = recording.entryID
        } else {
            // Upload mode: create the history entry now. m4aPath stays nil —
            // history must never hold a path to a file Murmur does not own.
            source = .userFile
            entryID = UUID()
            try? historyService.add(TranscriptionEntry(
                id: entryID,
                date: Date(),
                audioDuration: 0,
                text: "",
                language: "auto",
                status: .inProgress,
                m4aPath: nil
            ))
        }

        startTranscription(audioURL: audioURL, entryID: entryID, source: source, isRetry: false)
    }

    /// The audio of an entry whose transcription failed, when it is Murmur's
    /// own recording and is still on disk. `nil` means there is nothing to
    /// retry: a file the user picked is never kept.
    func retryableAudio(for entry: TranscriptionEntry) -> URL? {
        guard entry.status == .failed, let path = entry.m4aPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard recordingService.ownsRecording(at: url),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Transcribes the kept recording of a failed entry again, into the same
    /// entry. Does nothing while a recording or a transcription is under way.
    func retryTranscription(of entry: TranscriptionEntry) {
        switch windowState {
        case .idle, .result: break
        default: return
        }
        guard activeTranscription == nil, let url = retryableAudio(for: entry) else { return }
        try? historyService.updateStatus(id: entry.id, status: .inProgress)
        startTranscription(audioURL: url, entryID: entry.id, source: .ownRecording, isRetry: true)
    }

    private func startTranscription(audioURL: URL, entryID: UUID, source: AudioSource, isRetry: Bool) {
        // The model detects the language; the user's "Languages you speak"
        // only tell it which scripts to expect.
        let hint = SpokenLanguages.hint(for: SpokenLanguages.current())
        windowState = .transcribing(progress: nil)

        // P0 fix: pause voice input (global hotkey) for the duration of
        // transcription. Recording uses only AVAudioRecorder and does not
        // compete with the model — so we must NOT pause during recording,
        // only here at transcription-start.
        coordinator.beginWindowTranscription()

        let session = TranscriptionSession(
            generation: nextGeneration,
            entryID: entryID,
            audioURL: audioURL,
            source: source,
            isRetry: isRetry
        )
        nextGeneration += 1
        activeTranscription = session
        inFlightTranscriptions += 1

        // C2: persist partial text every N chunks so a crash during transcription
        // leaves a recoverable inProgress entry with accumulated text rather than empty.
        let progressPersistInterval = 5

        transcriptionTask = Task {
            // A long file takes many minutes; idle sleep would end the engine
            // process part-way through.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Transcribing an audio file"
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let outcome: Result<(TranscriptionResult, TimeInterval), Error>
            do {
                let result = try await transcriptionService.transcribeLong(
                    audioURL: audioURL,
                    language: hint,
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self, self.isCurrent(session) else { return }
                            self.windowState = .transcribing(progress: progress)
                            // Persist partial text every N chunks to reduce crash data loss
                            if progress.currentChunk % progressPersistInterval == 0,
                               !progress.partialText.isEmpty {
                                try? self.historyService.persistPartialText(
                                    id: entryID,
                                    partialText: progress.partialText
                                )
                            }
                        }
                    }
                )
                let dur = await audioDuration(of: audioURL) ?? 0
                outcome = .success((result, dur))
            } catch {
                outcome = .failure(error)
            }
            finishTranscription(session, outcome: outcome)
        }
    }

    private func isCurrent(_ session: TranscriptionSession) -> Bool {
        activeTranscription?.generation == session.generation
    }

    /// Runs once per transcription task, after its last suspension point.
    private func finishTranscription(
        _ session: TranscriptionSession,
        outcome: Result<(TranscriptionResult, TimeInterval), Error>
    ) {
        // P0 fix: resume voice input on success, cancel and error — but only
        // when no other transcription task is still running.
        inFlightTranscriptions -= 1
        if inFlightTranscriptions == 0 {
            coordinator.endWindowTranscription()
        }

        // A superseded task touches nothing else: cancelTranscription() already
        // cleaned up its entry, and the window may belong to a newer session.
        guard isCurrent(session) else { return }
        activeTranscription = nil
        transcriptionTask = nil

        switch outcome {
        case .success(let (result, dur)):
            let completedEntry = TranscriptionEntry(
                id: session.entryID,
                date: Date(),
                audioDuration: dur,
                text: result.text,
                language: result.language.rawValue,
                status: .completed,
                m4aPath: nil,
                segments: result.segments.isEmpty ? nil : result.segments
            )
            try? historyService.completeEntry(
                id: session.entryID,
                text: result.text,
                language: result.language.rawValue,
                audioDuration: dur,
                segments: completedEntry.segments
            )

            // Murmur's own recording is no longer needed once transcribed
            deleteAudio(at: session.audioURL, source: session.source)
            windowState = .result(entry: completedEntry)

        case .failure(let error) where error is CancellationError:
            // Silent cleanup — cancellation is intentional, not a failure
            abandon(session)
            windowState = .idle

        case .failure(let error):
            // Murmur's own recording is kept (entry.m4aPath) so it can be retried
            Self.log.error("Transcription failed: \(error)")
            try? historyService.updateStatus(id: session.entryID, status: .failed)
            windowState = .idle
        }
    }

    /// Cleans up after a cancelled session. A first transcription leaves
    /// nothing behind: its history entry goes, and its audio if that is
    /// Murmur's own recording. A retry leaves the entry failed and keeps the
    /// recording, as they were before it started.
    private func abandon(_ session: TranscriptionSession) {
        if session.isRetry {
            try? historyService.updateStatus(id: session.entryID, status: .failed)
            return
        }
        try? historyService.delete(id: session.entryID)
        deleteAudio(at: session.audioURL, source: session.source)
    }

    func resumeAfterCancelConfirm() {
        // Return to in-progress transcribing view
        windowState = .transcribing(progress: nil)
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil

        // Clearing activeTranscription supersedes the task: when it unwinds it
        // only releases the voice-input pause.
        if let session = activeTranscription {
            activeTranscription = nil
            abandon(session)
        }
        windowState = .idle
    }

    // MARK: - Audio duration helper

    private func audioDuration(of url: URL) async -> TimeInterval? {
        return await Task.detached {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else { return nil }
            return CMTimeGetSeconds(duration)
        }.value
    }
}
