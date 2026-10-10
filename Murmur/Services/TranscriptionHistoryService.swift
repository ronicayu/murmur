import Foundation
import os

// MARK: - Domain types

struct TranscriptionEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    var audioDuration: TimeInterval   // seconds
    var text: String
    var language: String
    var status: TranscriptionStatus
    var m4aPath: String?              // nil once transcription completes (m4a deleted)
}

enum TranscriptionStatus: String, Codable {
    case inProgress, completed, failed
}

// MARK: - TranscriptionHistoryService

/// Persists transcription history as a JSON file on disk.
///
/// - Storage: `storeURL` (defaults to App Support/Murmur/transcription_history.json)
/// - Capacity: 50 entries. Oldest entry pruned when limit is exceeded.
/// - Thread safety: Must be called on the Main actor.
@MainActor
final class TranscriptionHistoryService: ObservableObject {

    static let maxEntryCount = 50
    private static let log = Logger(subsystem: "com.murmur.app", category: "history")

    @Published private(set) var entries: [TranscriptionEntry] = []

    private let storeURL: URL
    /// Where Murmur's own recordings live. An entry's audio is deleted with
    /// the entry only when the file is directly inside this directory.
    private let recordingsDirectory: URL

    // MARK: - Init

    /// Designated initialiser — accepts any URL for testability.
    /// `recordingsDirectory` defaults to `Recordings` next to the store file,
    /// which is where `LongRecordingService()` writes.
    init(storeURL: URL, recordingsDirectory: URL? = nil) {
        self.storeURL = storeURL
        self.recordingsDirectory = recordingsDirectory
            ?? storeURL.deletingLastPathComponent().appendingPathComponent("Recordings", isDirectory: true)
        // Ensure parent directory exists before any read/write
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.entries = (try? Self.load(from: storeURL)) ?? []
    }

    /// Convenience initialiser using the default App Support path.
    convenience init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Murmur", isDirectory: true)
        let url = dir.appendingPathComponent("transcription_history.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(storeURL: url)
    }

    // MARK: - Read

    func getAll() -> [TranscriptionEntry] {
        return entries
    }

    // MARK: - Write

    /// Inserts a new entry at the front and prunes oldest beyond the 50-entry limit.
    func add(_ entry: TranscriptionEntry) throws {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntryCount {
            removeOwnedAudio(of: entries.suffix(from: Self.maxEntryCount))
            entries = Array(entries.prefix(Self.maxEntryCount))
        }
        try persist()
    }

    /// Removes the entry with the given id. No-op if not found.
    func delete(id: UUID) throws {
        removeOwnedAudio(of: entries.filter { $0.id == id })
        entries.removeAll { $0.id == id }
        try persist()
    }

    /// Removes all entries.
    func clearAll() throws {
        removeOwnedAudio(of: entries)
        entries = []
        try persist()
    }

    /// Deletes the recordings kept for entries that are going away (a failed
    /// transcription keeps its audio for a retry). Once the entry is gone
    /// nothing refers to the file any more. Only files directly inside the
    /// recordings directory are touched; `m4aPath` never holds a user's file,
    /// and this check holds even if it one day did.
    private func removeOwnedAudio<S: Sequence>(of removed: S) where S.Element == TranscriptionEntry {
        for entry in removed {
            guard let path = entry.m4aPath else { continue }
            let url = URL(fileURLWithPath: path)
            guard LongRecordingService.isFile(url, directlyInside: recordingsDirectory) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Updates only the `status` field of an existing entry.
    func updateStatus(id: UUID, status: TranscriptionStatus) throws {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].status = status
        try persist()
    }

    /// Persists partial transcription text for an inProgress entry.
    /// Called periodically during long transcription to reduce crash data-loss window.
    /// Does not change status — entry remains .inProgress.
    func persistPartialText(id: UUID, partialText: String) throws {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text = partialText
        try persist()
    }

    /// Marks an entry as completed: sets text, language, duration, status, and clears m4aPath.
    func completeEntry(id: UUID, text: String, language: String, audioDuration: TimeInterval? = nil) throws {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text = text
        entries[idx].language = language
        entries[idx].status = .completed
        entries[idx].m4aPath = nil
        if let dur = audioDuration {
            entries[idx].audioDuration = dur
        }
        try persist()
    }

    /// Updates the audio duration for an entry (e.g. after recording stops and duration is known).
    func updateDuration(id: UUID, duration: TimeInterval) throws {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].audioDuration = duration
        try persist()
    }

    // MARK: - Orphan scan

    /// Called on app launch. Nothing can still be in progress then, so every
    /// `inProgress` entry is one a crash or quit interrupted: mark it failed.
    /// Its recording, if any, is kept so the audio is not lost.
    func scanAndRecoverOrphans() {
        var changed = false
        for idx in entries.indices where entries[idx].status == .inProgress {
            entries[idx].status = .failed
            changed = true
        }
        if changed {
            try? persist()
        }
    }

    // MARK: - Persistence

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(entries)
        try data.write(to: storeURL, options: .atomic)
    }

    private static func load(from url: URL) throws -> [TranscriptionEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([TranscriptionEntry].self, from: data)
    }
}
