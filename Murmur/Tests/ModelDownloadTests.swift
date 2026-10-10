import XCTest
import CryptoKit
@testable import Murmur

// Tests for the model download: the pure decisions in `HFDownload`, and
// `ModelManager.download()` run end to end against a fake listing and a
// /bin/sh stand-in for curl. Nothing here touches the network or the real
// model directory.

// MARK: - Fixtures

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The id git gives a blob with this content.
private func gitBlobHex(_ data: Data) -> String {
    Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data)
        .map { String(format: "%02x", $0) }.joined()
}

private func lfsFile(_ path: String, _ data: Data) -> HFDownload.File {
    HFDownload.File(path: path, size: Int64(data.count), checksum: .sha256(sha256Hex(data)))
}

private func gitFile(_ path: String, _ data: Data) -> HFDownload.File {
    HFDownload.File(path: path, size: Int64(data.count), checksum: .gitBlobSHA1(gitBlobHex(data)))
}

/// One entry of the Hugging Face tree API, in the shape the real API returns.
private func listingEntry(_ path: String, _ data: Data, lfs: Bool) -> [String: Any] {
    var entry: [String: Any] = ["type": "file", "path": path, "size": data.count, "oid": gitBlobHex(data)]
    if lfs {
        // For an LFS file `oid` is the id of the pointer file, not of the content.
        entry["oid"] = String(repeating: "0", count: 40)
        entry["lfs"] = ["oid": sha256Hex(data), "size": data.count, "pointerSize": 130]
    }
    return entry
}

private func json(_ entries: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: entries)
}

private func makeTempDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ data: Data, to path: String, in directory: URL) throws {
    let url = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

// MARK: - Path validation (D3)

final class HFDownloadPathTests: XCTestCase {

    private let directory = URL(fileURLWithPath: "/tmp/murmur-models/Models-Qwen3ASR")

    func test_safePath_acceptsPlainAndNestedPaths() {
        XCTAssertTrue(HFDownload.isSafeRelativePath("encoder.int8.onnx", in: directory))
        XCTAssertTrue(HFDownload.isSafeRelativePath("tokenizer/vocab.json", in: directory))
        XCTAssertTrue(HFDownload.isSafeRelativePath("a/b/c..d/.hidden", in: directory))
    }

    func test_safePath_rejectsParentComponents() {
        XCTAssertFalse(HFDownload.isSafeRelativePath("tokenizer/../../../LaunchAgents/x.plist", in: directory))
        XCTAssertFalse(HFDownload.isSafeRelativePath("../x", in: directory))
        XCTAssertFalse(HFDownload.isSafeRelativePath("..", in: directory))
        XCTAssertFalse(HFDownload.isSafeRelativePath("tokenizer/..", in: directory))
        // Stays inside the directory, but a ".." component is never legitimate.
        XCTAssertFalse(HFDownload.isSafeRelativePath("tokenizer/../vocab.json", in: directory))
    }

    func test_safePath_rejectsEmptyDotAndAbsolutePaths() {
        XCTAssertFalse(HFDownload.isSafeRelativePath("", in: directory))
        XCTAssertFalse(HFDownload.isSafeRelativePath(".", in: directory))
        XCTAssertFalse(HFDownload.isSafeRelativePath("./vocab.json", in: directory))
        XCTAssertFalse(HFDownload.isSafeRelativePath("tokenizer//vocab.json", in: directory))
        XCTAssertFalse(HFDownload.isSafeRelativePath("tokenizer/", in: directory))
        XCTAssertFalse(HFDownload.isSafeRelativePath("/etc/passwd", in: directory))
    }

    func test_pattern_matchesAcrossSlashes_soPathSafetyIsASeparateCheck() {
        // This is why the listing needs `isSafeRelativePath`: the allow
        // pattern alone accepts a traversal path.
        XCTAssertTrue(HFDownload.path("tokenizer/../../x.plist", matchesAny: ["tokenizer/*"]))
        XCTAssertTrue(HFDownload.path("tokenizer/vocab.json", matchesAny: ["tokenizer/*"]))
        XCTAssertFalse(HFDownload.path("test_wavs/de.wav", matchesAny: ["tokenizer/*", "encoder.int8.onnx"]))
        XCTAssertTrue(HFDownload.path("anything", matchesAny: nil))
    }
}

// MARK: - Listing (D2, D3)

final class HFDownloadListingTests: XCTestCase {

    private let directory = URL(fileURLWithPath: "/tmp/murmur-models/Models-Qwen3ASR")

    func test_listingURL_usesThePinnedRevision() {
        XCTAssertEqual(
            HFDownload.listingURL(repo: "owner/name", revision: "abc123")?.absoluteString,
            "https://huggingface.co/api/models/owner/name/tree/abc123?recursive=true"
        )
    }

    func test_backends_pinAFullCommitSHA_notABranch() {
        let revisions = ModelBackend.allCases.map(\.modelRevision) + AuxiliaryModel.allCases.map(\.modelRevision)
        for revision in revisions {
            XCTAssertEqual(revision.count, 40, "\(revision) must be a full commit SHA")
            XCTAssertTrue(revision.allSatisfy { $0.isHexDigit }, "\(revision) must be a commit SHA, not a branch name")
        }
    }

    func test_parse_readsSizeAndChecksum_forLFSAndPlainFiles() throws {
        let model = Data("model bytes".utf8)
        let merges = Data("merges".utf8)
        let data = json([
            ["type": "directory", "path": "tokenizer", "size": 0, "oid": "e462cb908206021fbcd12cf45315854e1c6f23f1"],
            listingEntry("encoder.int8.onnx", model, lfs: true),
            listingEntry("tokenizer/merges.txt", merges, lfs: false),
            listingEntry("test_wavs/de.wav", Data("wav".utf8), lfs: true),
        ])

        let files = try HFDownload.parseListing(
            data, patterns: ["encoder.int8.onnx", "tokenizer/*"], into: directory
        )

        XCTAssertEqual(files, [
            HFDownload.File(path: "encoder.int8.onnx", size: 11, checksum: .sha256(sha256Hex(model))),
            HFDownload.File(path: "tokenizer/merges.txt", size: 6, checksum: .gitBlobSHA1(gitBlobHex(merges))),
        ])
    }

    func test_parse_throwsOnUnsafePathThatMatchesAPattern() {
        let data = json([listingEntry("tokenizer/../../../LaunchAgents/x.plist", Data("x".utf8), lfs: false)])
        XCTAssertThrowsError(try HFDownload.parseListing(data, patterns: ["tokenizer/*"], into: directory))
    }

    func test_parse_ignoresUnsafePathThatMatchesNoPattern() throws {
        let data = json([listingEntry("../evil", Data("x".utf8), lfs: false)])
        XCTAssertEqual(try HFDownload.parseListing(data, patterns: ["tokenizer/*"], into: directory), [])
    }

    func test_parse_throwsWhenSizeOrChecksumIsMissingOrMalformed() {
        let good = listingEntry("a.onnx", Data("x".utf8), lfs: true)

        var noSize = good
        noSize["size"] = nil
        XCTAssertThrowsError(try HFDownload.parseListing(json([noSize]), patterns: nil, into: directory))

        var shortHash = good
        shortHash["lfs"] = ["oid": "abc123"]
        XCTAssertThrowsError(try HFDownload.parseListing(json([shortHash]), patterns: nil, into: directory))

        var notHex = good
        notHex["lfs"] = ["oid": String(repeating: "z", count: 64)]
        XCTAssertThrowsError(try HFDownload.parseListing(json([notHex]), patterns: nil, into: directory))

        // No lfs block and no usable git oid.
        let noChecksum: [String: Any] = ["type": "file", "path": "a.txt", "size": 1]
        XCTAssertThrowsError(try HFDownload.parseListing(json([noChecksum]), patterns: nil, into: directory))
    }

    func test_parse_throwsOnNonArrayResponse() {
        let data = try! JSONSerialization.data(withJSONObject: ["error": "Repository not found"])
        XCTAssertThrowsError(try HFDownload.parseListing(data, patterns: nil, into: directory))
    }
}

// MARK: - Files on disk and the fetch plan (D1, D2, D6)

final class HFDownloadLocalStatusTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTempDirectory("hfdownload-status")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func test_status_missing() {
        XCTAssertEqual(HFDownload.localStatus(of: lfsFile("a.onnx", Data("abc".utf8)), in: directory), .missing)
    }

    func test_status_partial_whenSmallerThanListed() throws {
        try write(Data("ab".utf8), to: "a.onnx", in: directory)
        XCTAssertEqual(HFDownload.localStatus(of: lfsFile("a.onnx", Data("abc".utf8)), in: directory), .partial)
    }

    func test_status_verified_forMatchingSHA256() throws {
        let data = Data("model bytes".utf8)
        try write(data, to: "a.onnx", in: directory)
        XCTAssertEqual(
            HFDownload.localStatus(of: lfsFile("a.onnx", data), in: directory),
            .verified(sha256: sha256Hex(data))
        )
    }

    func test_status_verified_forMatchingGitBlobID_andReportsSHA256() throws {
        let data = Data("merges".utf8)
        try write(data, to: "tokenizer/merges.txt", in: directory)
        XCTAssertEqual(
            HFDownload.localStatus(of: gitFile("tokenizer/merges.txt", data), in: directory),
            .verified(sha256: sha256Hex(data))
        )
    }

    func test_status_mismatch_whenSizeMatchesButContentDiffers() throws {
        try write(Data("xyz".utf8), to: "a.onnx", in: directory)
        XCTAssertEqual(HFDownload.localStatus(of: lfsFile("a.onnx", Data("abc".utf8)), in: directory), .mismatch)

        try write(Data("xyz".utf8), to: "a.txt", in: directory)
        XCTAssertEqual(HFDownload.localStatus(of: gitFile("a.txt", Data("abc".utf8)), in: directory), .mismatch)
    }

    func test_status_mismatch_whenLargerThanListed() throws {
        try write(Data("abcd".utf8), to: "a.onnx", in: directory)
        XCTAssertEqual(HFDownload.localStatus(of: lfsFile("a.onnx", Data("abc".utf8)), in: directory), .mismatch)
    }

    func test_digests_hashAFileLargerThanOneReadChunk() throws {
        // 2.5 MB: the streaming loop takes three reads.
        let data = Data((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try write(data, to: "big.bin", in: directory)

        let digests = try HFDownload.digests(
            of: directory.appendingPathComponent("big.bin"), gitBlobSize: Int64(data.count)
        )

        XCTAssertEqual(digests.sha256, sha256Hex(data))
        XCTAssertEqual(digests.gitBlobSHA1, gitBlobHex(data))
    }

    func test_gitBlobID_matchesGitForAKnownBlob() throws {
        // `printf 'hello\n' | git hash-object --stdin`
        try write(Data("hello\n".utf8), to: "hello.txt", in: directory)
        let digests = try HFDownload.digests(of: directory.appendingPathComponent("hello.txt"), gitBlobSize: 6)
        XCTAssertEqual(digests.gitBlobSHA1, "ce013625030ba8dba906f756967f9e9ca394464a")
    }
}

final class HFDownloadPlanTests: XCTestCase {

    private let a = lfsFile("a.onnx", Data("a".utf8))
    private let b = lfsFile("b.onnx", Data("b".utf8))
    private let c = lfsFile("c.onnx", Data("c".utf8))
    private let d = gitFile("d.txt", Data("d".utf8))

    func test_plan_skipsVerified_fetchesMissingAndPartial_deletesMismatch() {
        let plan = HFDownload.plan(
            for: [a, b, c, d],
            statuses: [.verified(sha256: "aa"), .missing, .mismatch, .partial]
        )

        XCTAssertEqual(plan.verified, ["a.onnx": "aa"])
        XCTAssertEqual(plan.fetch, [b, c, d])
        XCTAssertEqual(plan.delete, [c], "a wrong file must be deleted so curl does not resume it")
    }

    func test_rejection_nilWhenEveryFetchedFileIsVerified() {
        let plan = HFDownload.plan(for: [a, b], statuses: [.verified(sha256: "aa"), .verified(sha256: "bb")])
        XCTAssertNil(HFDownload.rejection(afterFetch: plan))
    }

    func test_rejection_incomplete_whenAFileIsMissingOrShortAfterCurlSucceeded() {
        for status in [HFDownload.LocalStatus.missing, .partial] {
            let plan = HFDownload.plan(for: [a, b], statuses: [.verified(sha256: "aa"), status])
            guard case .incomplete(let message) = HFDownload.rejection(afterFetch: plan) else {
                return XCTFail("\(status) after a download must be rejected as incomplete")
            }
            XCTAssertTrue(message.contains("b.onnx"))
        }
    }

    func test_rejection_corrupt_whenContentDoesNotMatch_evenIfAnotherFileIsShort() {
        let plan = HFDownload.plan(for: [a, b], statuses: [.partial, .mismatch])
        guard case .corrupt(let message) = HFDownload.rejection(afterFetch: plan) else {
            return XCTFail("a checksum mismatch must be reported as corrupt")
        }
        XCTAssertTrue(message.contains("b.onnx"))
    }
}

// MARK: - curl arguments and result (D1, D5)

final class HFDownloadCurlTests: XCTestCase {

    private let directory = URL(fileURLWithPath: "/tmp/murmur-models/Models-Qwen3ASR")

    func test_transfer_usesPinnedRevision_andEncodesThePath() {
        let file = lfsFile("tokenizer/my vocab#1[a]{b}?.json", Data("x".utf8))

        let transfer = HFDownload.transfer(for: file, repo: "owner/name", revision: "abc123", into: directory)

        XCTAssertEqual(
            transfer.url,
            "https://huggingface.co/owner/name/resolve/abc123/tokenizer/my%20vocab%231%5Ba%5D%7Bb%7D%3F.json"
        )
        XCTAssertEqual(
            transfer.destination,
            "/tmp/murmur-models/Models-Qwen3ASR/tokenizer/my vocab#1[a]{b}?.json"
        )
    }

    func test_arguments_startWithQ_soCurlrcIsNotRead() {
        let arguments = HFDownload.curlArguments(for: [HFDownload.Transfer(url: "https://h/a", destination: "/d/a")])
        XCTAssertEqual(arguments.first, "-q", "-q only works as the first argument")
    }

    func test_arguments_failEarly_andRestrictProtocolsToHTTPS() {
        let arguments = HFDownload.curlArguments(for: [HFDownload.Transfer(url: "https://h/a", destination: "/d/a")])

        XCTAssertTrue(arguments.contains("--fail"))
        XCTAssertTrue(arguments.contains("--fail-early"))
        XCTAssertEqual(value(after: "--proto", in: arguments), "=https")
        XCTAssertEqual(value(after: "--proto-redir", in: arguments), "=https")
        XCTAssertEqual(value(after: "--continue-at", in: arguments), "-")
    }

    func test_arguments_pairEachOutputWithItsURL_inOrder() {
        let arguments = HFDownload.curlArguments(for: [
            HFDownload.Transfer(url: "https://h/a", destination: "/d/a"),
            HFDownload.Transfer(url: "https://h/b", destination: "/d/b"),
        ])

        XCTAssertEqual(Array(arguments.suffix(6)), ["--output", "/d/a", "https://h/a", "--output", "/d/b", "https://h/b"])
    }

    func test_failureMessage_nilOnlyForExitZero() {
        XCTAssertNil(HFDownload.failureMessage(for: .exit(0), stderr: ""))
        XCTAssertNotNil(HFDownload.failureMessage(for: .exit(22), stderr: ""))
        XCTAssertNotNil(HFDownload.failureMessage(for: .signal(15), stderr: ""))
        XCTAssertNotNil(HFDownload.failureMessage(for: .launchFailed, stderr: ""))
    }

    func test_failureMessage_explainsCurlExitCodes_withTheLastStderrLine() {
        let stderr = "curl: (6) Could not resolve host\n\ncurl: (22) The requested URL returned error: 404\n"

        let refused = HFDownload.failureMessage(for: .exit(22), stderr: stderr) ?? ""
        XCTAssertTrue(refused.contains("refused"))
        XCTAssertTrue(refused.contains("error: 404"))
        XCTAssertFalse(refused.contains("resolve host"))

        XCTAssertTrue((HFDownload.failureMessage(for: .exit(6), stderr: "") ?? "").contains("Could not reach"))
        XCTAssertTrue((HFDownload.failureMessage(for: .exit(60), stderr: "") ?? "").contains("TLS"))
        XCTAssertTrue((HFDownload.failureMessage(for: .exit(23), stderr: "") ?? "").contains("disk"))
        XCTAssertTrue((HFDownload.failureMessage(for: .exit(99), stderr: "") ?? "").contains("curl exit 99"))
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

// MARK: - download() end to end

/// What the fake "curl" factory was asked to do.
@MainActor
private final class ProcessRecorder {
    var calls: [[String]] = []
    /// Whether the file under test was on disk when the subprocess was built.
    var fileExistedAtBuild: Bool?

    /// The `--output` destinations of the last call.
    var destinations: [String] {
        guard let arguments = calls.last else { return [] }
        return arguments.indices.filter { arguments[$0] == "--output" }.map { arguments[$0 + 1] }
    }
}

private func shell(_ script: String, _ arguments: [String] = []) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script, "sh"] + arguments
    return process
}

@MainActor
final class ModelDownloadFlowTests: XCTestCase {

    private var manager: ModelManager!
    private var directory: URL!
    private var recorder: ProcessRecorder!

    private let lfsPaths: Set<String> = ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx"]

    private func content(_ path: String) -> Data { Data("content of \(path)".utf8) }

    private var listing: Data {
        json(ModelBackend.qwen3.requiredFiles.map { listingEntry($0, content($0), lfs: lfsPaths.contains($0)) })
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        manager = ModelManager()
        directory = try makeTempDirectory("model-download-flow")
        manager.__testing_setModelDirectory(directory, for: .qwen3)
        manager.__testing_setState(.notDownloaded)
        recorder = ProcessRecorder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        manager = nil
        try super.tearDownWithError()
    }

    private func plantRequiredFiles(except missing: String? = nil) throws {
        for path in ModelBackend.qwen3.requiredFiles where path != missing {
            try write(content(path), to: path, in: directory)
        }
    }

    /// Installs a fake listing and a fake curl. `makeProcess` gets the
    /// destination of the first requested file.
    private func install(
        listing: Data? = nil,
        stallTimeout: TimeInterval = 90,
        makeProcess: @escaping @MainActor (_ firstDestination: String) -> Process = { _ in shell("exit 0") }
    ) {
        let listing = listing ?? self.listing
        let recorder = self.recorder!
        var environment = ModelManager.DownloadEnvironment()
        environment.fetchListing = { _ in listing }
        environment.makeProcess = { arguments in
            recorder.calls.append(arguments)
            return makeProcess(recorder.destinations.first ?? "")
        }
        environment.stallTimeout = stallTimeout
        manager.__testing_setDownloadEnvironment(environment)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path)
    }

    // MARK: Accepting a download

    func test_download_allFilesAlreadyCorrect_becomesReadyWithoutASubprocess() async throws {
        try plantRequiredFiles()
        install()

        try await manager.download()

        XCTAssertEqual(manager.state, .ready)
        XCTAssertTrue(recorder.calls.isEmpty, "verified files must not be fetched again")
        XCTAssertTrue(manager.isModelDownloaded(for: .qwen3))
        let manifest = try XCTUnwrap(manager.loadManifest(for: .qwen3))
        XCTAssertEqual(Set(manifest.files.keys), Set(ModelBackend.qwen3.requiredFiles))
        XCTAssertEqual(
            manifest.files["tokenizer/merges.txt"]?.sha256, sha256Hex(content("tokenizer/merges.txt")),
            "the manifest records SHA-256 for plain git files too"
        )
    }

    func test_download_fetchesOnlyTheMissingFile_andBecomesReady() async throws {
        try plantRequiredFiles(except: "decoder.int8.onnx")
        let payload = String(decoding: content("decoder.int8.onnx"), as: UTF8.self)
        install { destination in shell("printf '%s' \"$2\" > \"$1\"", [destination, payload]) }

        try await manager.download()

        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.destinations, [directory.appendingPathComponent("decoder.int8.onnx").path])
        XCTAssertEqual(recorder.calls.first?.first, "-q")
    }

    // MARK: D1 — curl's exit status is not proof

    func test_download_subprocessSucceedsButFileIsMissing_isAnError_notReady() async throws {
        try plantRequiredFiles(except: "decoder.int8.onnx")
        install()

        do {
            try await manager.download()
            XCTFail("download() must throw when a listed file never arrived")
        } catch {}

        guard case .error = manager.state else {
            return XCTFail("expected .error, got \(manager.state)")
        }
        XCTAssertFalse(manager.isModelDownloaded(for: .qwen3))
        XCTAssertNil(manager.loadManifest(for: .qwen3), "no manifest may be written for an incomplete model")
    }

    func test_download_subprocessSucceedsButFileIsTruncated_isAnError_andKeepsThePartialFile() async throws {
        try plantRequiredFiles(except: "decoder.int8.onnx")
        install { destination in shell("printf 'con' > \"$1\"", [destination]) }

        try? await manager.download()

        guard case .error = manager.state else {
            return XCTFail("expected .error, got \(manager.state)")
        }
        XCTAssertTrue(exists("decoder.int8.onnx"), "a short file is kept so the next attempt can resume it")
    }

    func test_unverifiedDownload_isNotBlessedByManifestMigration() async throws {
        // A failed download leaves every required file name on disk, one of
        // them wrong. The launch-time migration must not turn that into a model.
        try plantRequiredFiles(except: "decoder.int8.onnx")
        install { destination in shell("printf 'con' > \"$1\"", [destination]) }
        try? await manager.download()

        manager.migrateToManifestIfNeeded(for: .qwen3)
        manager.refreshState()

        XCTAssertNil(manager.loadManifest(for: .qwen3))
        XCTAssertEqual(manager.state, .notDownloaded)
    }

    // MARK: D2 — content must match the listed checksum

    func test_download_fetchedLFSFileWithWrongContent_isCorrupt_andDeleted() async throws {
        try plantRequiredFiles(except: "decoder.int8.onnx")
        let wrong = String(repeating: "x", count: content("decoder.int8.onnx").count)
        install { destination in shell("printf '%s' \"$2\" > \"$1\"", [destination, wrong]) }

        try? await manager.download()

        XCTAssertEqual(manager.state, .corrupt)
        XCTAssertTrue(manager.statusMessage.contains("decoder.int8.onnx"), manager.statusMessage)
        XCTAssertFalse(exists("decoder.int8.onnx"), "a file with the wrong content must not stay on disk")
        XCTAssertFalse(manager.isModelDownloaded(for: .qwen3))
    }

    func test_download_fetchedPlainGitFileWithWrongContent_isCorrupt() async throws {
        try plantRequiredFiles(except: "tokenizer/merges.txt")
        let wrong = String(repeating: "x", count: content("tokenizer/merges.txt").count)
        install { destination in shell("printf '%s' \"$2\" > \"$1\"", [destination, wrong]) }

        try? await manager.download()

        XCTAssertEqual(manager.state, .corrupt)
    }

    // MARK: D6 — a matching size is not enough to skip

    func test_download_sizeMatchingWrongFileOnDisk_isDeletedBeforeCurl_andFetchedAgain() async throws {
        try plantRequiredFiles()
        let good = content("encoder.int8.onnx")
        try write(Data(repeating: 0x41, count: good.count), to: "encoder.int8.onnx", in: directory)
        manager.__testing_setState(.corrupt)

        let payload = String(decoding: good, as: UTF8.self)
        install { [recorder] destination in
            recorder!.fileExistedAtBuild = FileManager.default.fileExists(atPath: destination)
            return shell("printf '%s' \"$2\" > \"$1\"", [destination, payload])
        }

        try await manager.download()

        XCTAssertEqual(recorder.destinations, [directory.appendingPathComponent("encoder.int8.onnx").path])
        XCTAssertEqual(recorder.fileExistedAtBuild, false, "curl resumes whatever is on disk, so the bad file must be gone")
        XCTAssertEqual(manager.state, .ready)
    }

    // MARK: D3 — unsafe listing

    func test_download_listingWithTraversalPath_isAnError_andStartsNoSubprocess() async throws {
        var entries = ModelBackend.qwen3.requiredFiles.map { listingEntry($0, content($0), lfs: false) }
        entries.append(listingEntry("tokenizer/../../../LaunchAgents/x.plist", Data("x".utf8), lfs: false))
        install(listing: json(entries))

        try? await manager.download()

        guard case .error(let message) = manager.state else {
            return XCTFail("expected .error, got \(manager.state)")
        }
        XCTAssertTrue(message.contains("unsafe path"), message)
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func test_download_listingWithoutARequiredFile_isAnError() async throws {
        let entries = ModelBackend.qwen3.requiredFiles.dropLast().map { listingEntry($0, content($0), lfs: false) }
        install(listing: json(Array(entries)))

        try? await manager.download()

        guard case .error = manager.state else {
            return XCTFail("expected .error, got \(manager.state)")
        }
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    // MARK: D4 — cancel and stall keep their own state

    func test_cancelDuringListing_endsNotDownloaded_andStartsNoSubprocess() async throws {
        let listing = self.listing
        let recorder = self.recorder!
        var environment = ModelManager.DownloadEnvironment()
        environment.fetchListing = { [manager] _ in
            manager!.cancelDownload()
            return listing
        }
        environment.makeProcess = { arguments in
            recorder.calls.append(arguments)
            return shell("exit 0")
        }
        manager.__testing_setDownloadEnvironment(environment)

        do {
            try await manager.download()
            XCTFail("a cancelled download() must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        XCTAssertEqual(manager.state, .notDownloaded)
        XCTAssertEqual(manager.statusMessage, "")
        XCTAssertTrue(recorder.calls.isEmpty, "the download must not start after a cancel")
    }

    func test_cancelDuringFailingListing_endsNotDownloaded_notError() async throws {
        var environment = ModelManager.DownloadEnvironment()
        environment.fetchListing = { [manager] _ in
            manager!.cancelDownload()
            throw URLError(.timedOut)
        }
        manager.__testing_setDownloadEnvironment(environment)

        try? await manager.download()

        XCTAssertEqual(manager.state, .notDownloaded)
        XCTAssertEqual(manager.statusMessage, "")
    }

    func test_cancelWhileSubprocessRuns_endsNotDownloaded_withEmptyStatus() async throws {
        install { _ in shell("exec sleep 30") }
        let manager = self.manager!

        let download = Task { @MainActor () -> Error? in
            do {
                try await manager.download()
                return nil
            } catch {
                return error
            }
        }
        while !manager.__testing_hasActiveDownloadProcess {
            try await Task.sleep(for: .milliseconds(10))
        }
        manager.cancelDownload()
        let error = await download.value

        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        XCTAssertEqual(manager.state, .notDownloaded, "a user cancel is not an error")
        XCTAssertEqual(manager.statusMessage, "")
    }

    func test_stall_keepsTheStallError() async throws {
        // A zero timeout makes the first one-second poll report a stall.
        install(stallTimeout: 0) { _ in shell("exec sleep 30") }

        do {
            try await manager.download()
            XCTFail("a stalled download() must throw")
        } catch {
            guard case MurmurError.downloadStalled = error else {
                return XCTFail("expected downloadStalled, got \(error)")
            }
        }

        XCTAssertEqual(manager.state, .error(MurmurError.downloadStalled.shortMessage))
        XCTAssertEqual(manager.statusMessage, MurmurError.downloadStalled.alertTitle)
    }

    // MARK: Subprocess failures

    func test_download_curlFailure_isAnErrorWithTheCurlMessage() async throws {
        install { _ in shell("echo 'curl: (22) The requested URL returned error: 404' >&2; exit 22") }

        try? await manager.download()

        guard case .error(let message) = manager.state else {
            return XCTFail("expected .error, got \(manager.state)")
        }
        XCTAssertTrue(message.contains("error: 404"), message)
    }

    func test_download_subprocessThatCannotLaunch_isAnError() async throws {
        install { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/nonexistent/curl")
            return process
        }

        try? await manager.download()

        guard case .error = manager.state else {
            return XCTFail("expected .error, got \(manager.state)")
        }
    }
}

// MARK: - Auxiliary download

@MainActor
final class AuxiliaryDownloadFlowTests: XCTestCase {

    private var manager: ModelManager!
    private var directory: URL!

    private let model = Data("vad model".utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        manager = ModelManager()
        directory = try makeTempDirectory("aux-download-flow")
        manager.__testing_setAuxiliaryDirectory(directory, for: .sileroVad)
        manager.__testing_setAuxiliaryState(.notDownloaded, for: .sileroVad)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        manager = nil
        try super.tearDownWithError()
    }

    /// Installs a listing for the VAD model and a fake curl that writes `payload`.
    private func install(payload: String) {
        let listing = json([listingEntry("onnx/model.onnx", model, lfs: true)])
        let destination = directory.appendingPathComponent("onnx/model.onnx").path
        var environment = ModelManager.DownloadEnvironment()
        environment.fetchListing = { _ in listing }
        environment.makeProcess = { _ in
            shell("mkdir -p \"$(dirname \"$1\")\" && printf '%s' \"$2\" > \"$1\"", [destination, payload])
        }
        manager.__testing_setDownloadEnvironment(environment)
    }

    func test_downloadAuxiliary_correctContent_becomesReady() async throws {
        install(payload: "vad model")

        try await manager.downloadAuxiliary(.sileroVad)

        XCTAssertEqual(manager.auxiliaryState(for: .sileroVad), .ready)
        XCTAssertTrue(manager.isAuxiliaryDownloaded(.sileroVad))
    }

    func test_downloadAuxiliary_wrongContent_isCorrupt_andNotDownloaded() async throws {
        install(payload: "vad MODEL")

        try? await manager.downloadAuxiliary(.sileroVad)

        XCTAssertEqual(manager.auxiliaryState(for: .sileroVad), .corrupt)
        XCTAssertFalse(manager.isAuxiliaryDownloaded(.sileroVad))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("onnx/model.onnx").path)
        )
    }
}
