import Foundation

/// The WAV files Murmur writes to the temporary directory: dictations
/// (`murmur_<uuid>.wav`), streaming windows and chunks, and converted copies
/// of long files. Each is deleted when its work ends, but a crash or a forced
/// quit can leave one behind, and each holds the user's speech.
enum TemporaryAudio {
    static let prefix = "murmur_"

    /// Deletes Murmur's leftover WAV files in `directory`. Run at launch,
    /// before any recording or transcription has started.
    static func removeLeftovers(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".wav") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
