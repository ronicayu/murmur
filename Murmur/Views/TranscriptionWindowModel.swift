import SwiftUI
import AppKit
import AVFoundation
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
    /// Provide a test double in unit tests to avoid spawning a real Python process.
    private let injectedTranscriptionService: (any TranscriptionServiceProtocol)?
    private var transcriptionTask: Task<Void, Never>?
    private var activeEntryID: UUID?
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
                activeEntryID = entry.id
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
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? Int64) ?? 0

                // Estimate duration from file size (will be replaced with actual AVAsset duration)
                let estimatedDuration: TimeInterval
                if let avDur = await audioDuration(of: url) {
                    estimatedDuration = avDur
                } else {
                    estimatedDuration = 0
                }

                windowState = .recordingConfirm(
                    duration: estimatedDuration,
                    fileSizeBytes: size,
                    outputURL: url
                )
            } catch {
                Self.log.error("Stop recording failed: \(error)")
                windowState = .idle
            }
        }
    }

    func discardRecording(url: URL) {
        try? FileManager.default.removeItem(at: url)
        if let id = activeEntryID {
            try? historyService.delete(id: id)
            activeEntryID = nil
        }
        windowState = .idle
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
        let lang = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"
        windowState = .transcribing(progress: nil)

        // P0 fix: pause voice input (global hotkey) for the duration of
        // transcription. Recording uses only AVAudioRecorder and does not
        // compete with the model — so we must NOT pause during recording,
        // only here at transcription-start.
        coordinator.beginWindowTranscription()

        // Create history entry if we don't have one yet (upload mode)
        if activeEntryID == nil {
            let entry = TranscriptionEntry(
                id: UUID(),
                date: Date(),
                audioDuration: 0,
                text: "",
                language: lang == "auto" ? "auto" : lang,
                status: .inProgress,
                m4aPath: audioURL.path
            )
            activeEntryID = entry.id
            try? historyService.add(entry)
        }

        let entryID = activeEntryID!

        // C2: persist partial text every N chunks so a crash during transcription
        // leaves a recoverable inProgress entry with accumulated text rather than empty.
        let progressPersistInterval = 5

        transcriptionTask = Task {
            do {
                let result = try await transcriptionService.transcribeLong(
                    audioURL: audioURL,
                    language: lang == "auto" ? "en" : lang,
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
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

                // Complete the history entry
                let dur = await audioDuration(of: audioURL) ?? 0
                // Build completed entry
                let completedEntry = TranscriptionEntry(
                    id: entryID,
                    date: Date(),
                    audioDuration: dur,
                    text: result.text,
                    language: result.language.rawValue,
                    status: .completed,
                    m4aPath: nil
                )
                try? historyService.completeEntry(id: entryID, text: result.text, language: result.language.rawValue)

                // Delete the m4a after successful transcription
                if FileManager.default.fileExists(atPath: audioURL.path) {
                    try? FileManager.default.removeItem(at: audioURL)
                }

                activeEntryID = nil
                // P0 fix: resume voice input on success
                coordinator.endWindowTranscription()
                windowState = .result(entry: completedEntry)

            } catch is CancellationError {
                // Silent cleanup — cancellation is intentional, not a failure
                if let id = self.activeEntryID {
                    try? historyService.delete(id: id)
                    activeEntryID = nil
                }
                // P0 fix: resume voice input on cancel
                coordinator.endWindowTranscription()
                windowState = .idle
            } catch {
                Self.log.error("Transcription failed: \(error)")
                if let id = self.activeEntryID {
                    try? historyService.updateStatus(id: id, status: .failed)
                    activeEntryID = nil
                }
                // P0 fix: resume voice input on error
                coordinator.endWindowTranscription()
                windowState = .idle
            }
        }
    }

    func resumeAfterCancelConfirm() {
        // Return to in-progress transcribing view
        windowState = .transcribing(progress: nil)
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil

        if let id = activeEntryID {
            try? historyService.delete(id: id)
            activeEntryID = nil
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
