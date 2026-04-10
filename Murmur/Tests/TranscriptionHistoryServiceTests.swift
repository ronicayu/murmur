import XCTest
@testable import Murmur

// MARK: - TranscriptionHistoryService Tests
//
// Tests use a temp directory for isolation — never touch real App Support.
// @MainActor required because TranscriptionHistoryService is MainActor-isolated.

@MainActor
final class TranscriptionHistoryServiceTests: XCTestCase {

    private var storeURL: URL!
    private var sut: TranscriptionHistoryService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("transcription_history.json")
        sut = TranscriptionHistoryService(storeURL: storeURL)
    }

    override func tearDownWithError() throws {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    // MARK: - add

    func test_add_entry_persists_to_disk() throws {
        // Arrange
        let entry = makeEntry(text: "Hello world", duration: 10)

        // Act
        try sut.add(entry)

        // Assert — reload from disk
        let fresh = TranscriptionHistoryService(storeURL: storeURL)
        let all = fresh.getAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].id, entry.id)
        XCTAssertEqual(all[0].text, "Hello world")
    }

    func test_add_multiple_entries_preserves_insertion_order() throws {
        // Arrange
        let first = makeEntry(text: "First")
        let second = makeEntry(text: "Second")

        // Act
        try sut.add(first)
        try sut.add(second)

        // Assert — newest entry is first (insertion order: most recent at index 0)
        let all = sut.getAll()
        XCTAssertEqual(all[0].id, second.id)
        XCTAssertEqual(all[1].id, first.id)
    }

    // MARK: - 50-entry limit

    func test_prune_enforces_50_entry_limit() throws {
        // Arrange — add 51 entries
        var firstEntry: TranscriptionEntry?
        for i in 0..<51 {
            let e = makeEntry(text: "Entry \(i)")
            if i == 0 { firstEntry = e }
            try sut.add(e)
        }

        // Assert — exactly 50 remain; oldest (first) was pruned
        let all = sut.getAll()
        XCTAssertEqual(all.count, 50)
        XCTAssertNil(all.first(where: { $0.id == firstEntry!.id }),
                     "Oldest entry should have been pruned")
    }

    func test_adding_exactly_50_entries_does_not_prune() throws {
        // Arrange
        for i in 0..<50 {
            try sut.add(makeEntry(text: "Entry \(i)"))
        }

        // Assert
        XCTAssertEqual(sut.getAll().count, 50)
    }

    // MARK: - delete

    func test_delete_entry_removes_from_store() throws {
        // Arrange
        let entry = makeEntry(text: "To be deleted")
        try sut.add(entry)

        // Act
        try sut.delete(id: entry.id)

        // Assert
        XCTAssertTrue(sut.getAll().isEmpty)
    }

    func test_delete_nonexistent_entry_does_not_throw() throws {
        // Act & Assert — deleting unknown UUID must not throw
        XCTAssertNoThrow(try sut.delete(id: UUID()))
    }

    func test_delete_removes_only_target_entry() throws {
        // Arrange
        let keep = makeEntry(text: "Keep me")
        let remove = makeEntry(text: "Remove me")
        try sut.add(keep)
        try sut.add(remove)

        // Act
        try sut.delete(id: remove.id)

        // Assert
        let all = sut.getAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].id, keep.id)
    }

    // MARK: - clearAll

    func test_clearAll_empties_store() throws {
        // Arrange
        for i in 0..<5 {
            try sut.add(makeEntry(text: "Entry \(i)"))
        }

        // Act
        try sut.clearAll()

        // Assert
        XCTAssertTrue(sut.getAll().isEmpty)
    }

    func test_clearAll_persists_empty_state_to_disk() throws {
        // Arrange
        try sut.add(makeEntry(text: "entry"))
        try sut.clearAll()

        // Assert — reload from disk
        let fresh = TranscriptionHistoryService(storeURL: storeURL)
        XCTAssertTrue(fresh.getAll().isEmpty)
    }

    // MARK: - updateStatus

    func test_updateStatus_changes_entry_status() throws {
        // Arrange
        var entry = makeEntry(text: "In progress", status: .inProgress)
        try sut.add(entry)

        // Act
        try sut.updateStatus(id: entry.id, status: .completed)

        // Assert
        let all = sut.getAll()
        XCTAssertEqual(all[0].status, .completed)
    }

    func test_updateStatus_persists_to_disk() throws {
        // Arrange
        let entry = makeEntry(text: "In progress", status: .inProgress)
        try sut.add(entry)
        try sut.updateStatus(id: entry.id, status: .completed)

        // Act — reload
        let fresh = TranscriptionHistoryService(storeURL: storeURL)

        // Assert
        XCTAssertEqual(fresh.getAll()[0].status, .completed)
    }

    func test_updateStatus_with_text_sets_transcript() throws {
        // Arrange
        let entry = makeEntry(text: "", status: .inProgress)
        try sut.add(entry)

        // Act
        try sut.completeEntry(id: entry.id, text: "Final text", language: "en")

        // Assert
        let updated = sut.getAll()[0]
        XCTAssertEqual(updated.text, "Final text")
        XCTAssertEqual(updated.language, "en")
        XCTAssertEqual(updated.status, .completed)
    }

    // MARK: - m4aPath management

    func test_completed_entry_has_nil_m4aPath() throws {
        // Arrange
        let entry = makeEntry(text: "done", status: .inProgress, m4aPath: "/tmp/rec.m4a")
        try sut.add(entry)

        // Act — complete clears m4a path
        try sut.completeEntry(id: entry.id, text: "done", language: "en")

        // Assert
        XCTAssertNil(sut.getAll()[0].m4aPath)
    }

    // MARK: - orphan scan

    func test_scanOrphanM4a_marks_inProgress_entries_as_failed() throws {
        // Arrange — add an inProgress entry whose m4a does NOT exist
        let entry = makeEntry(text: "", status: .inProgress, m4aPath: "/nonexistent/fake.m4a")
        try sut.add(entry)

        // Act
        sut.scanAndRecoverOrphans()

        // Assert
        XCTAssertEqual(sut.getAll()[0].status, .failed)
    }

    func test_scanOrphanM4a_leaves_completed_entries_unchanged() throws {
        // Arrange — completed entry (no m4aPath, no scan action needed)
        let entry = makeEntry(text: "done", status: .completed)
        try sut.add(entry)

        // Act
        sut.scanAndRecoverOrphans()

        // Assert — status unchanged
        XCTAssertEqual(sut.getAll()[0].status, .completed)
    }

    // MARK: - getAll

    func test_getAll_returns_empty_when_no_store_file() {
        // Arrange — fresh service, no file yet
        let noFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        let fresh = TranscriptionHistoryService(storeURL: noFile)

        // Assert
        XCTAssertTrue(fresh.getAll().isEmpty)
    }

    // MARK: - Helpers

    private func makeEntry(
        text: String,
        duration: TimeInterval = 60,
        status: TranscriptionStatus = .completed,
        m4aPath: String? = nil
    ) -> TranscriptionEntry {
        TranscriptionEntry(
            id: UUID(),
            date: Date(),
            audioDuration: duration,
            text: text,
            language: "en",
            status: status,
            m4aPath: m4aPath
        )
    }
}
