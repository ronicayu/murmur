import Foundation
@testable import Murmur

// The app's two long-lived objects, built so that a test cannot reach the
// machine of the person who runs it.

/// An `AppCoordinator` with a stub engine and pill, and no system-wide
/// hotkey. Without arguments the app's initializer loads the real speech
/// model, shows the real pill and registers Right Command.
@MainActor
func makeTestCoordinator(
    transcription: any TranscriptionServiceProtocol = SpyTranscriptionService(),
    pill: any PillControlling = SpyPillController()
) -> AppCoordinator {
    AppCoordinator(transcription: transcription, pill: pill, registersGlobalHotkey: false)
}

/// A `ModelManager` whose model folders are below a temporary directory and
/// whose settings are in a `UserDefaults` of its own. Without arguments the
/// app's initializer reads the real Application Support and can turn the
/// user's VAD setting off.
@MainActor
func makeTestModelManager() -> ModelManager {
    let id = UUID().uuidString
    return ModelManager(
        applicationSupport: FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-test-appsupport-\(id)", isDirectory: true),
        defaults: UserDefaults(suiteName: "murmur-test-\(id)")!
    )
}
