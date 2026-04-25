import Foundation
@testable import Murmur

/// Test double for `PillControlling` — records calls to `show` and `hide`
/// so coordinator-level tests can assert UX side effects without real UI.
final class SpyPillController: PillControlling, @unchecked Sendable {

    struct ShowCall {
        let state: AppState
        let audioLevel: Float
        let languageBadge: String?
    }

    private(set) var showCalls: [ShowCall] = []
    private(set) var hideCalls: [TimeInterval] = []

    var lastShownState: AppState? { showCalls.last?.state }
    var lastShownBadge: String? { showCalls.last?.languageBadge }

    func show(state: AppState, audioLevel: Float, languageBadge: String?, onCancel: (() -> Void)?) {
        showCalls.append(ShowCall(state: state, audioLevel: audioLevel, languageBadge: languageBadge))
    }

    func hide(after delay: TimeInterval) {
        hideCalls.append(delay)
    }

    func reset() {
        showCalls.removeAll()
        hideCalls.removeAll()
    }
}
