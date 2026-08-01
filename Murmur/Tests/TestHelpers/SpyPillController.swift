import Foundation
@testable import Murmur

/// Test double for `PillControlling` — records calls to `show` and `hide`
/// so coordinator-level tests can assert UX side effects without real UI.
final class SpyPillController: PillControlling, @unchecked Sendable {

    struct ShowCall {
        let state: AppState
        let audioLevel: Float
        let languageBadge: String?
        let notice: String?
    }

    private(set) var showCalls: [ShowCall] = []
    private(set) var hideCalls: [TimeInterval] = []

    var lastShownState: AppState? { showCalls.last?.state }
    var lastShownBadge: String? { showCalls.last?.languageBadge }
    var lastShownNotice: String? { showCalls.last?.notice }
    /// Every notice shown this session, in order (nils dropped).
    var shownNotices: [String] { showCalls.compactMap(\.notice) }

    func show(
        state: AppState,
        audioLevel: Float,
        languageBadge: String?,
        notice: String?,
        onCancel: (() -> Void)?
    ) {
        showCalls.append(
            ShowCall(state: state, audioLevel: audioLevel, languageBadge: languageBadge, notice: notice)
        )
    }

    func hide(after delay: TimeInterval) {
        hideCalls.append(delay)
    }

    func reset() {
        showCalls.removeAll()
        hideCalls.removeAll()
    }
}
