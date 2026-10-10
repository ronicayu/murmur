import Foundation
import Darwin
import CryptoKit

/// The decisions of a model download from Hugging Face, kept free of UI state
/// so they can be tested: what the remote listing says, where a file may be
/// written, what is already on disk, and how curl is called. `ModelManager`
/// owns the state machine and the subprocess.
enum HFDownload {

    // MARK: - Listing

    struct File: Equatable, Sendable {
        /// Repo-relative path, already checked with `isSafeRelativePath`.
        let path: String
        let size: Int64
        let checksum: Checksum
    }

    enum Checksum: Equatable, Sendable {
        /// LFS file: SHA-256 of the content (`lfs.oid` in the listing).
        case sha256(String)
        /// Plain git file: the blob id (`oid`), which is the SHA-1 of
        /// `"blob <size>\0"` followed by the content.
        case gitBlobSHA1(String)
    }

    /// The file listing of `repo` at `revision`. With a commit SHA as the
    /// revision the answer cannot change after Murmur ships.
    static func listingURL(repo: String, revision: String) -> URL? {
        URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(revision)?recursive=true")
    }

    /// Shell-style match of a repo-relative path against the allow patterns.
    /// `*` also matches `/`, so `tokenizer/*` covers nested files; whether the
    /// path is safe to write is `isSafeRelativePath`'s job, not this one's.
    static func path(_ path: String, matchesAny patterns: [String]?) -> Bool {
        guard let patterns else { return true }
        return patterns.contains { fnmatch($0, path, 0) == 0 }
    }

    /// Whether a path from the remote listing may be written below `directory`.
    /// The listing is remote input: `tokenizer/../../x` matches `tokenizer/*`
    /// and curl's `--create-dirs --output` would follow it out of the folder.
    static func isSafeRelativePath(_ path: String, in directory: URL) -> Bool {
        guard !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        let root = directory.standardizedFileURL.path
        let destination = directory.appendingPathComponent(path).standardizedFileURL.path
        return destination.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Parses the tree API response into the files that match `patterns`.
    ///
    /// Throws when a matching file has an unsafe path or lacks a size or a
    /// checksum: a download that cannot be checked must not start.
    static func parseListing(_ data: Data, patterns: [String]?, into directory: URL) throws -> [File] {
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw MurmurError.transcriptionFailed("Unexpected response when listing model files")
        }
        var files: [File] = []
        for entry in entries {
            guard entry["type"] as? String == "file",
                  let path = entry["path"] as? String,
                  Self.path(path, matchesAny: patterns)
            else { continue }
            guard isSafeRelativePath(path, in: directory) else {
                throw MurmurError.transcriptionFailed("The model file listing contains an unsafe path: \(path)")
            }
            guard let size = (entry["size"] as? NSNumber)?.int64Value, size >= 0,
                  let checksum = checksum(of: entry)
            else {
                throw MurmurError.transcriptionFailed("The model file listing has no size or checksum for \(path)")
            }
            files.append(File(path: path, size: size, checksum: checksum))
        }
        return files
    }

    private static func checksum(of entry: [String: Any]) -> Checksum? {
        if let lfs = entry["lfs"] {
            guard let oid = (lfs as? [String: Any])?["oid"] as? String, isHex(oid, length: 64) else { return nil }
            return .sha256(oid.lowercased())
        }
        guard let oid = entry["oid"] as? String, isHex(oid, length: 40) else { return nil }
        return .gitBlobSHA1(oid.lowercased())
    }

    private static func isHex(_ string: String, length: Int) -> Bool {
        string.utf8.count == length && string.utf8.allSatisfy { UInt8(ascii: "0")...UInt8(ascii: "9") ~= $0
            || UInt8(ascii: "a")...UInt8(ascii: "f") ~= $0 || UInt8(ascii: "A")...UInt8(ascii: "F") ~= $0 }
    }

    // MARK: - Files on disk

    enum LocalStatus: Equatable, Sendable {
        case missing
        /// Smaller than listed: the rest can be fetched with a range request.
        case partial
        /// Full size and the content matches the listed checksum.
        case verified(sha256: String)
        /// Full size or larger with the wrong content. Resuming cannot repair it.
        case mismatch
    }

    /// Compares the file on disk with its listing entry. Hashes a full-size
    /// file, so call it off the main actor.
    static func localStatus(of file: File, in directory: URL) -> LocalStatus {
        let url = directory.appendingPathComponent(file.path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let onDisk = (attributes[.size] as? NSNumber)?.int64Value
        else { return .missing }
        if onDisk < file.size { return .partial }
        guard onDisk == file.size, let digests = try? digests(of: url, gitBlobSize: file.size) else { return .mismatch }
        switch file.checksum {
        case .sha256(let expected):
            return digests.sha256 == expected ? .verified(sha256: digests.sha256) : .mismatch
        case .gitBlobSHA1(let expected):
            return digests.gitBlobSHA1 == expected ? .verified(sha256: digests.sha256) : .mismatch
        }
    }

    /// Hashes the file in 1 MB pieces, so a 750 MB model file never sits in memory.
    static func digests(of url: URL, gitBlobSize: Int64) throws -> (sha256: String, gitBlobSHA1: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256()
        var sha1 = Insecure.SHA1()
        sha1.update(data: Data("blob \(gitBlobSize)\0".utf8))
        while true {
            let atEnd = try autoreleasepool { () -> Bool in
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return true }
                sha256.update(data: chunk)
                sha1.update(data: chunk)
                return false
            }
            if atEnd { break }
        }
        return (hex(sha256.finalize()), hex(sha1.finalize()))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// What to do with each listed file, given what is on disk.
    struct Plan: Equatable, Sendable {
        /// Already correct on disk: path -> SHA-256. Not fetched again.
        var verified: [String: String] = [:]
        /// Wrong content. Delete before fetching, so curl does not resume them.
        var delete: [File] = []
        /// To fetch; includes everything in `delete`.
        var fetch: [File] = []
    }

    static func plan(for files: [File], statuses: [LocalStatus]) -> Plan {
        var plan = Plan()
        for (file, status) in zip(files, statuses) {
            switch status {
            case .verified(let sha256):
                plan.verified[file.path] = sha256
            case .mismatch:
                plan.delete.append(file)
                plan.fetch.append(file)
            case .missing, .partial:
                plan.fetch.append(file)
            }
        }
        return plan
    }

    /// Why a finished download is not accepted.
    enum Rejection: Equatable, Sendable {
        /// A file has the wrong content. The message is user-facing.
        case corrupt(String)
        /// A file is missing or short although curl reported success.
        case incomplete(String)
    }

    /// Judges the files curl was asked to fetch, from a `plan` computed on
    /// them after it finished. nil means every one of them is verified.
    static func rejection(afterFetch plan: Plan) -> Rejection? {
        if let file = plan.delete.first {
            return .corrupt("Model integrity check failed: \(file.path) does not match its published checksum. Download the model again.")
        }
        if let file = plan.fetch.first {
            return .incomplete("The download is incomplete: \(file.path) is missing or truncated. Try again to resume.")
        }
        return nil
    }

    // MARK: - curl

    struct Transfer: Equatable, Sendable {
        let url: String
        let destination: String
    }

    static func transfer(for file: File, repo: String, revision: String, into directory: URL) -> Transfer {
        let encodedPath = file.path
            .split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return Transfer(
            url: "https://huggingface.co/\(repo)/resolve/\(revision)/\(encodedPath)",
            destination: directory.appendingPathComponent(file.path).path
        )
    }

    /// Arguments for one /usr/bin/curl that fetches every transfer in order.
    ///
    /// - `-q` must come first: it stops curl from reading `~/.curlrc`, where an
    ///   `insecure` or `proxy` line would silently apply to the download.
    /// - `--fail-early`: without it the exit status is that of the last
    ///   transfer only, and a failed large file hides behind a later success.
    /// - `--proto` / `--proto-redir`: the transfer and every redirect stay on HTTPS.
    static func curlArguments(for transfers: [Transfer]) -> [String] {
        [
            "-q", "--fail", "--fail-early", "--location",
            "--proto", "=https", "--proto-redir", "=https",
            "--silent", "--show-error",
            "--retry", "3", "--retry-delay", "2", "--connect-timeout", "30",
            "--create-dirs", "--continue-at", "-",
        ] + transfers.flatMap { ["--output", $0.destination, $0.url] }
    }

    /// How the download subprocess ended.
    enum ProcessEnd: Equatable, Sendable {
        case exit(Int32)
        case signal(Int32)
        case launchFailed
    }

    /// User-facing reason the download subprocess failed, or nil when it
    /// succeeded. A user cancel and a stall also end in `.signal`; the caller
    /// handles those before asking.
    static func failureMessage(for end: ProcessEnd, stderr: String) -> String? {
        switch end {
        case .exit(0): return nil
        case .exit(let status): return curlErrorMessage(exitStatus: status, stderr: stderr)
        case .signal: return "The download was interrupted."
        case .launchFailed: return "Could not start the download."
        }
    }

    /// User-facing explanation for a curl exit code.
    static func curlErrorMessage(exitStatus: Int32, stderr: String) -> String {
        let detail = stderr
            .components(separatedBy: "\n")
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? "curl exit \(exitStatus)"
        switch exitStatus {
        case 5, 6, 7, 28:
            return "Could not reach huggingface.co. Check your network or try again later. (\(detail))"
        case 35, 51, 58, 60, 77:
            return "TLS certificate verification failed. If you use Cloudflare WARP / Zero Trust or another TLS-intercepting proxy, make sure its root certificate is trusted in Keychain Access. (\(detail))"
        case 22, 56:
            return "huggingface.co refused the download. (\(detail))"
        case 23:
            return "Could not write the model files to disk. (\(detail))"
        default:
            return "Download failed. (\(detail))"
        }
    }
}
