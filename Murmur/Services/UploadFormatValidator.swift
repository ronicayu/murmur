import Foundation

/// Validates audio file extensions accepted for the upload flow.
///
/// Recording output format (m4a) is included.
/// .wav is accepted in upload mode because soundfile can decode it natively
/// without ffmpeg — there is no reason to reject it.
enum UploadFormatValidator {

    /// Extensions accepted in upload mode.
    static let acceptedExtensions: Set<String> = ["mp3", "m4a", "caf", "ogg", "wav"]

    /// Returns true when `extension` (case-insensitive) is accepted for upload.
    static func isAccepted(extension ext: String) -> Bool {
        acceptedExtensions.contains(ext.lowercased())
    }
}
