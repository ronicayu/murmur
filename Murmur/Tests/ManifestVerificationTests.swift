import XCTest
import CryptoKit
@testable import Murmur

// MARK: - ManifestVerificationTests (FU-04)
//
// Covers:
//   1. Successful download writes a manifest with correct SHA-256 per file.
//   2. isModelDownloaded returns true only when manifest exists AND file sizes match.
//   3. isModelDownloaded returns false if a file is deleted, truncated, or manifest is missing.
//   4. verify() sets state to .corrupt when a file's SHA-256 does not match the manifest.
//   5. Migration: files on disk without manifest → manifest generated → .ready.
//   6. Termination-handler race: download() completes even when the subprocess exits
//      before the handler is attached (documented limitation; seam tracked below).

// Safety guard: every test class that writes into a backend's model directory
// checks for a real pre-existing model and skips to avoid destroying it.

@MainActor
final class ManifestBuildAndValidationTests: XCTestCase {

    private var manager: ModelManager!
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.set(ModelBackend.onnx.rawValue, forKey: "modelBackend")
        manager = ModelManager()

        // Redirect the ONNX model directory to an isolated temp dir so nothing
        // touches ~/Library/Application Support/Murmur/Models-ONNX/. This
        // replaces the earlier XCTSkipIf-on-real-model guard — tests now
        // always run and never risk deleting a user's installed model.
        tempDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager.__testing_setModelDirectory(tempDir, for: .onnx)

        let onnxSub = tempDir.appendingPathComponent("onnx")
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
        let manifest = try manager.buildManifest(for: .onnx)

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
        let manifest = try manager.buildManifest(for: .onnx)

        // Assert
        XCTAssertNil(manifest.files[ModelManager.ModelManifest.filename],
                     "manifest.json itself must not appear in the manifest entries")
    }

    func test_buildManifest_includesFilesInSubdirectories() throws {
        // Arrange — plant a file nested under onnx/
        let onnxSub = tempDir.appendingPathComponent("onnx")
        let nested = onnxSub.appendingPathComponent("encoder_model_q4f16.onnx")
        try Data("onnx model bytes".utf8).write(to: nested)

        // Act
        let manifest = try manager.buildManifest(for: .onnx)

        // Assert — relative path uses forward slash separators
        let key = "onnx/encoder_model_q4f16.onnx"
        XCTAssertNotNil(manifest.files[key],
                        "Nested files must be recorded with their relative path including subdirectory")
    }

    // MARK: 2 – manifestIsValid: true only when manifest present and sizes match

    func test_manifestIsValid_trueWhenManifestExistsAndSizesMatch() throws {
        // Arrange — plant a file and write a matching manifest
        let content = Data("exact size".utf8)
        let filePath = tempDir.appendingPathComponent("config.json")
        try content.write(to: filePath)

        let manifest = try manager.buildManifest(for: .onnx)
        try manager.writeManifest(manifest, for: .onnx)

        // Act + Assert
        XCTAssertTrue(manager.manifestIsValid(for: .onnx),
                      "manifestIsValid must return true when manifest exists and sizes match")
    }

    func test_manifestIsValid_falseWhenManifestMissing() throws {
        // Arrange — plant files but NO manifest
        let filePath = tempDir.appendingPathComponent("config.json")
        try Data("some data".utf8).write(to: filePath)

        // Ensure no manifest exists
        try? FileManager.default.removeItem(at: manager.manifestURL(for: .onnx))

        // Act + Assert
        XCTAssertFalse(manager.manifestIsValid(for: .onnx),
                       "manifestIsValid must return false when manifest.json is absent")
    }

    func test_manifestIsValid_falseWhenFileDeleted() throws {
        // Arrange — plant files, write manifest, then delete a file
        let filePath = tempDir.appendingPathComponent("config.json")
        try Data("some data".utf8).write(to: filePath)

        let manifest = try manager.buildManifest(for: .onnx)
        try manager.writeManifest(manifest, for: .onnx)

        // Delete the file the manifest references
        try FileManager.default.removeItem(at: filePath)

        // Act + Assert
        XCTAssertFalse(manager.manifestIsValid(for: .onnx),
                       "manifestIsValid must return false when a listed file is missing")
    }

    func test_manifestIsValid_falseWhenFileTruncated() throws {
        // Arrange — plant a file, write manifest with its real size, then truncate it
        let original = Data("original content with known length".utf8)
        let filePath = tempDir.appendingPathComponent("config.json")
        try original.write(to: filePath)

        let manifest = try manager.buildManifest(for: .onnx)
        try manager.writeManifest(manifest, for: .onnx)

        // Overwrite with fewer bytes — size will mismatch
        let truncated = Data("short".utf8)
        try truncated.write(to: filePath)

        // Act + Assert
        XCTAssertFalse(manager.manifestIsValid(for: .onnx),
                       "manifestIsValid must return false when a file has been truncated (size mismatch)")
    }

    // MARK: 3 – isModelDownloaded gates on manifest

    func test_isModelDownloaded_falseWhenNoManifest() throws {
        // Arrange — plant all required files but no manifest
        for file in ModelBackend.onnx.requiredFiles {
            let url = tempDir.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("stub".utf8).write(to: url)
        }
        try? FileManager.default.removeItem(at: manager.manifestURL(for: .onnx))

        manager.refreshState()

        // Act + Assert — no manifest means not considered downloaded
        XCTAssertFalse(manager.isModelDownloaded(for: .onnx),
                       "isModelDownloaded must return false when manifest.json is absent, even if files exist")
    }

    func test_isModelDownloaded_trueWhenManifestAndSizesMatch() throws {
        // Arrange — plant required files and write a valid manifest
        for file in ModelBackend.onnx.requiredFiles {
            let url = tempDir.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("stub".utf8).write(to: url)
        }
        let manifest = try manager.buildManifest(for: .onnx)
        try manager.writeManifest(manifest, for: .onnx)

        manager.refreshState()
        // After refreshState() with a valid manifest, state should be .ready
        XCTAssertEqual(manager.state, .ready, "Precondition: state must be .ready")

        // Act + Assert
        XCTAssertTrue(manager.isModelDownloaded(for: .onnx),
                      "isModelDownloaded must return true with a valid manifest")
    }
}

// MARK: - ManifestVerifyCorruptionTests
//
// Tests verify() SHA-256 checking and .corrupt state.

@MainActor
final class ManifestVerifyCorruptionTests: XCTestCase {

    private var manager: ModelManager!
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.set(ModelBackend.onnx.rawValue, forKey: "modelBackend")
        manager = ModelManager()

        // Redirect to an isolated temp dir before any write — see
        // ManifestBuildAndValidationTests for rationale.
        tempDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("manifest-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager.__testing_setModelDirectory(tempDir, for: .onnx)

        // Plant the three ONNX required files so verify() doesn't fail at the
        // existence-check stage before reaching hash comparison.
        let onnxSub = tempDir.appendingPathComponent("onnx")
        try FileManager.default.createDirectory(at: onnxSub, withIntermediateDirectories: true)

        for file in ModelBackend.onnx.requiredFiles {
            let url = tempDir.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("original \(file)".utf8).write(to: url)
        }
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        manager = nil
        try super.tearDownWithError()
    }

    // MARK: 4 – verify() sets .corrupt when SHA-256 mismatches

    func test_verify_setsCorruptState_whenFileSHA256Mismatch() async throws {
        // Arrange — write a manifest with known hashes, then corrupt a file
        let manifest = try manager.buildManifest(for: .onnx)
        try manager.writeManifest(manifest, for: .onnx)

        // Corrupt config.json after manifest was written
        let configPath = tempDir.appendingPathComponent("config.json")
        try Data("CORRUPTED CONTENT".utf8).write(to: configPath)

        // Act
        manager.__testing_setState(.notDownloaded) // reset so verify() can set .verifying
        let result = try await manager.verify()

        // Assert
        XCTAssertFalse(result, "verify() must return false when a file's SHA-256 doesn't match")
        XCTAssertEqual(manager.state, .corrupt,
                       "verify() must set state to .corrupt on hash mismatch")
    }

    func test_verify_returnsTrueAndSetsReady_whenAllHashesMatch() async throws {
        // Arrange — write manifest matching the on-disk files (no corruption)
        let manifest = try manager.buildManifest(for: .onnx)
        try manager.writeManifest(manifest, for: .onnx)

        // Act
        manager.__testing_setState(.notDownloaded)
        let result = try await manager.verify()

        // Assert
        XCTAssertTrue(result, "verify() must return true when all hashes match")
        XCTAssertEqual(manager.state, .ready,
                       "verify() must set state to .ready on success")
    }

    func test_verify_writesManifest_whenNoneExists() async throws {
        // Arrange — ensure no manifest exists (only required files on disk)
        try? FileManager.default.removeItem(at: manager.manifestURL(for: .onnx))
        XCTAssertNil(manager.loadManifest(for: .onnx), "Precondition: no manifest")

        // Act
        manager.__testing_setState(.notDownloaded)
        let result = try await manager.verify()

        // Assert — verify() writes the manifest when none exists (first-time flow)
        XCTAssertTrue(result, "verify() must pass when files exist and no prior manifest")
        XCTAssertNotNil(manager.loadManifest(for: .onnx),
                        "verify() must write manifest.json when none exists")
    }

    func test_verify_setsCorrupt_whenRequiredFileMissing() async throws {
        // Arrange — plant manifest, then remove a required file
        let manifest = try manager.buildManifest(for: .onnx)
        try manager.writeManifest(manifest, for: .onnx)

        let configPath = tempDir.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: configPath)

        // Act
        manager.__testing_setState(.notDownloaded)
        let result = try await manager.verify()

        // Assert
        XCTAssertFalse(result, "verify() must return false when a required file is missing")
        XCTAssertEqual(manager.state, .corrupt)
    }
}

// MARK: - ManifestMigrationTests
//
// Tests migration path: existing users who have files on disk but no manifest.

@MainActor
final class ManifestMigrationTests: XCTestCase {

    private var manager: ModelManager!
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.set(ModelBackend.onnx.rawValue, forKey: "modelBackend")

        // Create an isolated temp dir and redirect the manager to it BEFORE
        // we call `migrateToManifestIfNeeded(for:)` in each test. The previous
        // strategy — using the real Application Support path with an
        // XCTSkipIf(modelPath != nil) guard — was unsafe: if a user had
        // downloaded the model via HuggingFace without Murmur's manifest.json
        // yet written, `modelPath` returns nil, the skip didn't fire, and the
        // tests' `removeItem(at: tempDir)` wiped the real model directory.
        //
        // This version: always temp-dir, no skip needed, and we exercise the
        // migration logic post-init by calling `migrateToManifestIfNeeded`
        // directly (the init-time invocation ran against a still-empty dir).
        manager = ModelManager()
        tempDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager.__testing_setModelDirectory(tempDir, for: .onnx)

        // Plant required files without a manifest to simulate a pre-manifest install.
        let onnxSub = tempDir.appendingPathComponent("onnx")
        try FileManager.default.createDirectory(at: onnxSub, withIntermediateDirectories: true)
        for file in ModelBackend.onnx.requiredFiles {
            let url = tempDir.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("pre-manifest content for \(file)".utf8).write(to: url)
        }

        // Remove any manifest that may have leaked in.
        let manifestURL = tempDir.appendingPathComponent(ModelManager.ModelManifest.filename)
        try? FileManager.default.removeItem(at: manifestURL)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        manager = nil
        try super.tearDownWithError()
    }

    // MARK: 5 – Migration generates manifest and sets .ready

    func test_migration_generatesManifest_fromExistingFiles() throws {
        // Act — explicit migration call post-init (init-time invocation was
        // before the redirect, so it ran against an empty real directory and
        // was effectively a no-op).
        manager.migrateToManifestIfNeeded(for: .onnx)

        let manifestURL = tempDir.appendingPathComponent(ModelManager.ModelManifest.filename)

        // Assert — manifest was written during migration
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path),
                      "Migration must write manifest.json when required files exist but no manifest does")

        let manifest = manager.loadManifest(for: .onnx)
        XCTAssertNotNil(manifest, "loadManifest must return the newly-written manifest")
        XCTAssertGreaterThan(manifest?.files.count ?? 0, 0,
                             "Migrated manifest must contain at least one file entry")
    }

    func test_migration_setsStateReady_afterManifestGenerated() throws {
        // Act — explicit migration + refreshState.
        manager.migrateToManifestIfNeeded(for: .onnx)
        manager.refreshState()

        XCTAssertEqual(manager.state, .ready,
                       "State must be .ready after migration writes a valid manifest")
    }

    func test_migration_isIdempotent_doesNotOverwriteExistingManifest() throws {
        // Arrange — run migration once.
        manager.migrateToManifestIfNeeded(for: .onnx)
        let manifestURL = tempDir.appendingPathComponent(ModelManager.ModelManifest.filename)

        let attrs = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        let firstWriteDate = attrs[.modificationDate] as? Date

        Thread.sleep(forTimeInterval: 0.05)

        // Act — run migration again; manifest exists, must not be rewritten.
        manager.migrateToManifestIfNeeded(for: .onnx)

        let attrs2 = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        let secondDate = attrs2[.modificationDate] as? Date

        XCTAssertEqual(firstWriteDate, secondDate,
                       "Migration must be idempotent: must not overwrite an existing manifest")
    }

    func test_migration_doesNotRun_whenNoRequiredFilesOnDisk() throws {
        // Arrange — remove all planted files from the tempdir.
        try FileManager.default.removeItem(at: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let manifestURL = tempDir.appendingPathComponent(ModelManager.ModelManifest.filename)

        // Act
        manager.migrateToManifestIfNeeded(for: .onnx)

        // Assert
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path),
                       "Migration must not write a manifest when required files are absent")
    }
}

// MARK: - TerminationHandlerRaceDocumentation
//
// The termination-handler race fix (process exits before handler attach) is
// exercised in the real download() flow when the HF cache already contains
// the model files. The subprocess exits in milliseconds and the race triggers.
//
// Unit-testing this path directly requires injecting a fast-exiting Process
// into download(). The test seam `__testing_injectDownloadProcess(_:)` is
// tracked as FU-03 / handoff 068. Until that seam exists, this class documents
// the limitation and verifies the guard-flag mechanics in isolation.

final class TerminationHandlerAtomicGuardTests: XCTestCase {

    // Test that the NSLock + Bool guard correctly prevents double-resume
    // when the terminationHandler fires AND the defensive post-run check
    // both attempt to resume the continuation.
    func test_atomicGuard_preventsDoubleResume() async {
        // Arrange
        let lock = NSLock()
        var alreadyResumed = false
        var resumeCount = 0

        // Simulate the guard pattern from download()
        func tryResume() {
            lock.lock()
            defer { lock.unlock() }
            guard !alreadyResumed else { return }
            alreadyResumed = true
            resumeCount += 1
        }

        // Act — simulate both the handler and the defensive check firing
        tryResume() // terminationHandler fires
        tryResume() // defensive post-run check fires

        // Assert — only one resume happened
        XCTAssertEqual(resumeCount, 1,
                       "NSLock guard must ensure only one resume() call reaches the continuation")
        XCTAssertTrue(alreadyResumed)
    }

    func test_atomicGuard_allowsResumeFromConcurrentQueues() async {
        // Stress: fire tryResume from multiple concurrent queues, as would
        // happen when terminationHandler (background queue) and defensive check
        // (calling actor) overlap.
        let lock = NSLock()
        var alreadyResumed = false
        var resumeCount = 0

        func tryResume() {
            lock.lock()
            defer { lock.unlock() }
            guard !alreadyResumed else { return }
            alreadyResumed = true
            resumeCount += 1
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { tryResume() }
            }
        }

        XCTAssertEqual(resumeCount, 1,
                       "Concurrent tryResume calls must result in exactly one resume under NSLock")
    }
}
