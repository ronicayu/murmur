import XCTest
@testable import Murmur

final class TemporaryAudioTests: XCTestCase {

    func test_removeLeftovers_deletesOnlyMurmursWavFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("temporary-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["murmur_1234.wav", "murmur_long_5678.wav", "murmur_notes.txt", "other.wav"]
        for name in names { try Data("x".utf8).write(to: directory.appendingPathComponent(name)) }

        TemporaryAudio.removeLeftovers(in: directory)

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(left, ["murmur_notes.txt", "other.wav"])
    }
}
