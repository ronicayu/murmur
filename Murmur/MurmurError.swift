import Foundation

enum MurmurError: Error, Sendable {
    case microphoneBusy
    case diskFull
    case modelNotFound
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
}

extension MurmurError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .microphoneBusy:
            return "Microphone is in use by another app."
        case .diskFull:
            return "Not enough disk space to record."
        case .modelNotFound:
            return "Transcription model not found. Please run onboarding."
        case .silenceDetected:
            return "Didn't catch that. Try again."
        case .permissionRevoked(let perm):
            return "\(perm.rawValue.capitalized) permission is required. Open System Settings to grant access."
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
