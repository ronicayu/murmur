import XCTest
import CryptoKit
@testable import Murmur

// MARK: - ManifestVerificationTests (FU-04)
//
// Covers:
//   1. Successful download writes a manifest with correct SHA-256 per file.
//   2. isModelDownloaded returns true only when manifest exists AND file sizes match.
//   3. isModelDownloaded returns false if a file is deleted, truncated, or manifest is missing.

// Safety guard: every test class that writes into a backend's model directory
// checks for a real pre-existing model and skips to avoid destroying it.

@MainActor
final class ManifestBuildAndValidationTests: XCTestCase {

    private var manager: ModelManager!
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.set(ModelBackend.qwen3.rawValue, forKey: "modelBackend")
        manager = ModelManager()

        // Redirect the ONNX model directory to an isolated temp dir so nothing
        // touches ~/Library/Application Support/Murmur/Models-Qwen3ASR/. This
        // replaces the earlier XCTSkipIf-on-real-model guard — tests now
        // always run and never risk deleting a user's installed model.
        tempDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager.__testing_setModelDirectory(tempDir, for: .qwen3)

        let onnxSub = tempDir.appendingPathComponent("qwen3")
        try FileManager.default.createDirectory(at: onnxSub, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        manager = nil
        try super.tearDownWithError()
    }

    // MARK: 1 – buildManifest records correct SHA-256 and size

    func test_buildManifest_recordsCorrectSHA256AndSize() throws {
        // Arrange — plant a known file
        let content = Data("hello manifest".utf8)
        let filePath = tempDir.appendingPathComponent("config.json")
        try content.write(to: filePath)

        // Act
        let manifest = try manager.buildManifest(for: .qwen3)

        // Assert
        guard let entry = manifest.files["config.json"] else {
            XCTFail("buildManifest must include the planted file")
            return
        }

        let expectedHash = SHA256.hash(data: content)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(entry.sha256, expectedHash,
                       "SHA-256 in manifest must match the actual file content")
        XCTAssertEqual(entry.size, Int64(content.count),
                       "File size in manifest must match the actual file size")
    }

    func test_buildManifest_excludesManifestFileItself() throws {
        // Arrange — plant a real file and an existing manifest
        let filePath = tempDir.appendingPathComponent("config.json")
        try Data("data".utf8).write(to: filePath)
        let manifestPath = tempDir.appendingPathComponent(ModelManager.ModelManifest.filename)
        try Data("{}".utf8).write(to: manifestPath)

        // Act
        let manifest = try manager.buildManifest(for: .qwen3)

        // Assert
        XCTAssertNil(manifest.files[ModelManager.ModelManifest.filename],
                     "manifest.json itself must not appear in the manifest entries")
    }

    func test_buildManifest_includesFilesInSubdirectories() throws {
        // Arrange — plant a file nested under tokenizer/
        let subdirectory = tempDir.appendingPathComponent("tokenizer")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let nested = subdirectory.appendingPathComponent("vocab.json")
        try Data("vocabulary bytes".utf8).write(to: nested)

        // Act
        let manifest = try manager.buildManifest(for: .qwen3)

        // Assert — relative path uses forward slash separators
        let key = "tokenizer/vocab.json"
        XCTAssertNotNil(manifest.files[key],
                        "Nested files must be recorded with their relative path including subdirectory")
    }

    // MARK: 2 – manifestIsValid: true only when manifest present and sizes match

    func test_manifestIsValid_trueWhenManifestExistsAndSizesMatch() throws {
        // Arrange — plant a file and write a matching manifest
        let content = Data("exact size".utf8)
        let filePath = tempDir.appendingPathComponent("config.json")
        try content.write(to: filePath)

        let manifest = try manager.buildManifest(for: .qwen3)
        try manager.writeManifest(manifest, for: .qwen3)

        // Act + Assert
        XCTAssertTrue(manager.manifestIsValid(for: .qwen3),
                      "manifestIsValid must return true when manifest exists and sizes match")
    }

    func test_manifestIsValid_falseWhenManifestMissing() throws {
        // Arrange — plant files but NO manifest
        let filePath = tempDir.appendingPathComponent("config.json")
        try Data("some data".utf8).write(to: filePath)

        // Ensure no manifest exists
        try? FileManager.default.removeItem(at: manager.manifestURL(for: .qwen3))

        // Act + Assert
        XCTAssertFalse(manager.manifestIsValid(for: .qwen3),
                       "manifestIsValid must return false when manifest.json is absent")
    }

    func test_manifestIsValid_falseWhenFileDeleted() throws {
        // Arrange — plant files, write manifest, then delete a file
        let filePath = tempDir.appendingPathComponent("config.json")
        try Data("some data".utf8).write(to: filePath)

        let manifest = try manager.buildManifest(for: .qwen3)
        try manager.writeManifest(manifest, for: .qwen3)

        // Delete the file the manifest references
        try FileManager.default.removeItem(at: filePath)

        // Act + Assert
        XCTAssertFalse(manager.manifestIsValid(for: .qwen3),
                       "manifestIsValid must return false when a listed file is missing")
    }

    func test_manifestIsValid_falseWhenFileTruncated() throws {
        // Arrange — plant a file, write manifest with its real size, then truncate it
        let original = Data("original content with known length".utf8)
        let filePath = tempDir.appendingPathComponent("config.json")
        try original.write(to: filePath)

        let manifest = try manager.buildManifest(for: .qwen3)
        try manager.writeManifest(manifest, for: .qwen3)

        // Overwrite with fewer bytes — size will mismatch
        let truncated = Data("short".utf8)
        try truncated.write(to: filePath)

        // Act + Assert
        XCTAssertFalse(manager.manifestIsValid(for: .qwen3),
                       "manifestIsValid must return false when a file has been truncated (size mismatch)")
    }

    // MARK: 3 – isModelDownloaded gates on manifest

    func test_isModelDownloaded_falseWhenNoManifest() throws {
        // Arrange — plant all required files but no manifest
        for file in ModelBackend.qwen3.requiredFiles {
            let url = tempDir.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("stub".utf8).write(to: url)
        }
        try? FileManager.default.removeItem(at: manager.manifestURL(for: .qwen3))

        manager.refreshState()

        // Act + Assert — no manifest means not considered downloaded
        XCTAssertFalse(manager.isModelDownloaded(for: .qwen3),
                       "isModelDownloaded must return false when manifest.json is absent, even if files exist")
    }

    func test_isModelDownloaded_trueWhenManifestAndSizesMatch() throws {
        // Arrange — plant required files and write a valid manifest
        for file in ModelBackend.qwen3.requiredFiles {
            let url = tempDir.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("stub".utf8).write(to: url)
        }
        let manifest = try manager.buildManifest(for: .qwen3)
        try manager.writeManifest(manifest, for: .qwen3)

        manager.refreshState()
        // After refreshState() with a valid manifest, state should be .ready
        XCTAssertEqual(manager.state, .ready, "Precondition: state must be .ready")

        // Act + Assert
        XCTAssertTrue(manager.isModelDownloaded(for: .qwen3),
                      "isModelDownloaded must return true with a valid manifest")
    }
}
