import Foundation

enum MurmurError: Error, Sendable {
    case microphoneBusy
    case diskFull
    case modelNotFound
    case downloadStalled
    case silenceDetected
    case permissionRevoked(Permission)
    case transcriptionFailed(String)
    case injectionFailed(String)
    case timeout(operation: String)
    case sessionAbandoned

    enum Permission: String, Sendable {
        case microphone
        case accessibility
        case inputMonitoring
    }

    enum Severity: Sendable {
        /// Blocks the user from the main flow and requires an action or
        /// explicit acknowledgement — surface via NSAlert.
        case critical
        /// Informational or momentary — surface via the pill and auto-hide.
        case transient
    }

    /// How the error should be presented. `critical` = NSAlert, `transient` = pill.
    var severity: Severity {
        switch self {
        case .modelNotFound, .diskFull, .downloadStalled, .permissionRevoked:
            return .critical
        case .microphoneBusy, .silenceDetected, .transcriptionFailed,
             .injectionFailed, .timeout, .sessionAbandoned:
            return .transient
        }
    }

    /// One-line label for the pill (≤ ~20 chars). Callers needing a full
    /// explanation read `errorDescription`; critical errors get both the
    /// short title (NSAlert messageText) and the full body (informativeText).
    var shortMessage: String {
        switch self {
        case .microphoneBusy: return "Mic in use"
        case .diskFull: return "Disk full"
        case .modelNotFound: return "Model missing"
        case .downloadStalled: return "Download stalled"
        case .silenceDetected: return "Didn't catch that"
        case .permissionRevoked(let perm): return "\(perm.rawValue.capitalized) needed"
        case .transcriptionFailed: return "Transcription failed"
        case .injectionFailed: return "Couldn't insert text"
        case .timeout: return "Timed out"
        case .sessionAbandoned: return "Session ended"
        }
    }

    /// Short title for NSAlert (messageText) when severity == .critical.
    var alertTitle: String {
        switch self {
        case .modelNotFound: return "Speech model not installed"
        case .diskFull: return "Not enough disk space"
        case .downloadStalled: return "Download stopped making progress"
        case .permissionRevoked(let perm): return "\(perm.rawValue.capitalized) Permission Required"
        default: return shortMessage
        }
    }
}

extension MurmurError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .microphoneBusy:
            return "Microphone is in use by another app."
        case .diskFull:
            return "Not enough disk space to record. Free up space and try again."
        case .modelNotFound:
            return "Murmur needs to download the transcription model before it can work. Open Settings and start the download."
        case .downloadStalled:
            return "The download isn't receiving data. Check your internet connection and try again."
        case .silenceDetected:
            return "Didn't catch that. Try again."
        case .permissionRevoked(let perm):
            return "Murmur needs \(perm.rawValue) access to work. Please grant it in System Settings."
        case .transcriptionFailed(let msg):
            return "Transcription failed: \(msg)"
        case .injectionFailed(let msg):
            return "Could not insert text: \(msg)"
        case .timeout(let op):
            return "\(op) timed out."
        case .sessionAbandoned:
            return "Session ended — switched away too long."
        }
    }
}
