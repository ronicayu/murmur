import Foundation
import os

/// One dictation session's measurements.
///
/// Every field the 10x plan tracks as a target metric lives here so progress is
/// observable without attaching a debugger. Optional fields are genuinely
/// mode-dependent: a V1 (full-pass) session has no time-to-first-word or
/// streamed-vs-final edit distance, because nothing is streamed.
struct SessionMetrics: Codable, Equatable {
    /// Which pipeline produced this session.
    enum Mode: String, Codable {
        case v1FullPass = "v1"
        case v3Streaming = "v3"
    }

    /// How the session ended.
    enum Outcome: String, Codable {
        case injected
        /// The silence gate discarded the recording.
        case silenceGated
        case cancelled
        case failed
    }

    let date: Date
    let mode: Mode
    let outcome: Outcome
    let language: String

    /// Length of the captured audio.
    var audioDurationMs: Int?
    /// Stop-speaking to final text at the cursor. The plan's headline metric
    /// (target < 700 ms).
    var stopToFinalTextMs: Int?
    /// First streamed word visible while still speaking (V3 only, target < 1 s).
    var timeToFirstWordMs: Int?
    /// Duration of the closing full pass (V3 only).
    var finalizeLatencyMs: Int?
    /// Levenshtein ratio between streamed text and the full-pass text (V3
    /// only). Lower is better; the plan wants this consistently < 1%.
    var editDistanceRatio: Double?
    /// Streaming stopped early because the CPU monitor tripped.
    var cpuFallback: Bool = false
    /// Number of streamed deltas injected (V3 only).
    var chunkCount: Int?

    init(
        date: Date,
        mode: Mode,
        outcome: Outcome,
        language: String,
        audioDurationMs: Int? = nil,
        stopToFinalTextMs: Int? = nil,
        timeToFirstWordMs: Int? = nil,
        finalizeLatencyMs: Int? = nil,
        editDistanceRatio: Double? = nil,
        cpuFallback: Bool = false,
        chunkCount: Int? = nil
    ) {
        self.date = date
        self.mode = mode
        self.outcome = outcome
        self.language = language
        self.audioDurationMs = audioDurationMs
        self.stopToFinalTextMs = stopToFinalTextMs
        self.timeToFirstWordMs = timeToFirstWordMs
        self.finalizeLatencyMs = finalizeLatencyMs
        self.editDistanceRatio = editDistanceRatio
        self.cpuFallback = cpuFallback
        self.chunkCount = chunkCount
    }
}

/// Appends `SessionMetrics` to a local JSON-lines file so latency and accuracy
/// trends are visible while dogfooding.
///
/// **Local only — this is not telemetry.** Nothing is transmitted; the file
/// lives in Application Support and is capped so it cannot grow without bound.
/// One JSON object per line means a corrupt or partially-written line costs a
/// single session rather than the whole history, and the file stays greppable.
///
/// Failures are swallowed by design: metrics are diagnostics, and losing a
/// measurement must never disturb a dictation the user is in the middle of.
final class SessionMetricsRecorder: @unchecked Sendable {

    private let fileURL: URL
    private let maxRecords: Int
    /// Extra lines tolerated before compaction, so we don't rewrite the file on
    /// every single append once the cap is reached.
    private let compactionSlack: Int
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.murmur.app", category: "metrics")

    /// Default on-disk location: alongside the other Murmur app data.
    static func defaultFileURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
            .appendingPathComponent("session-metrics.jsonl")
    }

    init(fileURL: URL = SessionMetricsRecorder.defaultFileURL(),
         maxRecords: Int = 1000,
         compactionSlack: Int = 200) {
        self.fileURL = fileURL
        self.maxRecords = max(1, maxRecords)
        self.compactionSlack = max(0, compactionSlack)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        // Sorted keys keep lines diffable and stable across runs.
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Append one session. Never throws — a metrics failure must not surface
    /// to the user mid-dictation.
    func record(_ metrics: SessionMetrics) {
        guard let data = try? Self.encoder.encode(metrics),
              var line = String(data: data, encoding: .utf8) else {
            logger.warning("SessionMetricsRecorder: encode failed; dropping record")
            return
        }
        line += "\n"

        lock.lock()
        defer { lock.unlock() }
        do {
            try appendLocked(line)
            try compactIfNeededLocked()
        } catch {
            logger.warning("SessionMetricsRecorder: write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Most recent sessions, newest last (file order). Malformed lines are
    /// skipped rather than failing the whole read — a truncated final line
    /// from a crash must not hide the preceding history.
    func recent(limit: Int = 100) -> [SessionMetrics] {
        lock.lock()
        defer { lock.unlock() }
        let all = readAllLocked()
        return Array(all.suffix(max(0, limit)))
    }

    /// Delete the metrics file. Used by tests and by a future "clear" action.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Private (caller holds `lock`)

    private func appendLocked(_ line: String) throws {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    private func readAllLocked() -> [SessionMetrics] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? Self.decoder.decode(SessionMetrics.self, from: data)
            }
    }

    private func compactIfNeededLocked() throws {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maxRecords + compactionSlack else { return }
        let kept = lines.suffix(maxRecords).joined(separator: "\n") + "\n"
        try kept.write(to: fileURL, atomically: true, encoding: .utf8)
        logger.info("SessionMetricsRecorder: compacted to \(self.maxRecords) records")
    }
}
