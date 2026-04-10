import Foundation
import os

// MARK: - Domain types

struct TranscriptionEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    let audioDuration: TimeInterval   // seconds
    var text: String
    let language: String
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

    // MARK: - Init

    /// Designated initialiser — accepts any URL for testability.
    init(storeURL: URL) {
        self.storeURL = storeURL
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
            entries = Array(entries.prefix(Self.maxEntryCount))
        }
        try persist()
    }

    /// Removes the entry with the given id. No-op if not found.
    func delete(id: UUID) throws {
        entries.removeAll { $0.id == id }
        try persist()
    }

    /// Removes all entries.
    func clearAll() throws {
        entries = []
        try persist()
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

    /// Marks an entry as completed: sets text, language, status, and clears m4aPath.
    func completeEntry(id: UUID, text: String, language: String) throws {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text = text
        entries[idx].status = .completed
        entries[idx].m4aPath = nil
        try persist()
    }

    // MARK: - Orphan scan

    /// Called on app launch. Marks any inProgress entry whose m4a file no longer exists as failed.
    /// This handles crashes or force-quits that left entries stuck in inProgress.
    func scanAndRecoverOrphans() {
        var changed = false
        for idx in entries.indices {
            guard entries[idx].status == .inProgress else { continue }
            if let path = entries[idx].m4aPath {
                if !FileManager.default.fileExists(atPath: path) {
                    entries[idx].status = .failed
                    changed = true
                }
            } else {
                // inProgress with no m4aPath is also orphaned
                entries[idx].status = .failed
                changed = true
            }
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
