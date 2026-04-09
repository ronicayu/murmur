import AVFoundation
import AppKit
import os

enum PermissionState: Sendable {
    case granted
    case denied
    case notDetermined
}

struct PermissionsStatus: Sendable {
    let microphone: PermissionState
    let accessibility: PermissionState

    var allGranted: Bool {
        microphone == .granted && accessibility == .granted
    }
}

protocol PermissionsServiceProtocol {
    func checkAll() -> PermissionsStatus
    func requestMicrophone() async -> Bool
    func openAccessibilitySettings()
    func pollAccessibilityGranted() -> AsyncStream<Bool>
}

final class PermissionsService: PermissionsServiceProtocol {
    private let log = Logger(subsystem: "com.murmur.app", category: "permissions")

    func checkAll() -> PermissionsStatus {
        PermissionsStatus(
            microphone: checkMicrophone(),
            accessibility: checkAccessibility()
        )
    }

    func requestMicrophone() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            log.info("Microphone permission \(granted ? "granted" : "denied")")
            return granted
        default:
            log.warning("Microphone permission denied")
            return false
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        log.info("Opened Accessibility settings")
    }

    func pollAccessibilityGranted() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            Task {
                while !Task.isCancelled {
                    let trusted = AXIsProcessTrusted()
                    continuation.yield(trusted)
                    if trusted {
                        continuation.finish()
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    // MARK: - Private

    private func checkMicrophone() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    private func checkAccessibility() -> PermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }
}
