import XCTest
@testable import Murmur

// UAT 058 P1: when streaming stops mid-session because the CPU monitor tripped,
// the user must be told. Before this, the fallback branch in
// AppCoordinator.stopAndTranscribeStreaming rendered a pill *identical* to the
// normal success path — live text simply stopped appearing partway through with
// no explanation, which reads as a bug rather than a deliberate mode switch.

final class PillNoticeTests: XCTestCase {

    // MARK: - View plumbing

    func test_pillView_carriesNotice_whenProvided() {
        let view = FloatingPillView(
            state: .undoable(text: "hello", method: .clipboard),
            audioLevel: 0,
            notice: AppCoordinator.cpuFallbackNotice
        )
        XCTAssertEqual(view.notice, AppCoordinator.cpuFallbackNotice)
    }

    func test_pillView_noticeIsNil_byDefault() {
        // The overwhelmingly common case: no notice, no badge clutter.
        let view = FloatingPillView(state: .recording, audioLevel: 0, languageBadge: "EN")
        XCTAssertNil(view.notice,
            "A normal session must not render a notice badge")
    }

    func test_notice_isIndependentOfLanguageBadge() {
        // The notice must not be smuggled through the language-badge slot —
        // they have different visibility rules and different meanings.
        let view = FloatingPillView(
            state: .undoable(text: "hi", method: .clipboard),
            audioLevel: 0,
            languageBadge: "EN",
            notice: "1-pass"
        )
        XCTAssertEqual(view.languageBadge, "EN")
        XCTAssertEqual(view.notice, "1-pass")
    }

    // MARK: - Notice content

    func test_cpuFallbackNotice_isNonEmpty() {
        XCTAssertFalse(
            AppCoordinator.cpuFallbackNotice.trimmingCharacters(in: .whitespaces).isEmpty,
            "A blank notice would render an empty badge and explain nothing")
    }

    func test_cpuFallbackNotice_isShort() {
        // It sits inline in a compact pill; a sentence would blow out the layout.
        XCTAssertLessThanOrEqual(AppCoordinator.cpuFallbackNotice.count, 16)
    }

    // MARK: - Controller plumbing

    func test_spyPill_recordsNotice() {
        let spy = SpyPillController()
        spy.show(state: .undoable(text: "x", method: .clipboard), notice: "1-pass")
        XCTAssertEqual(spy.lastShownNotice, "1-pass")
        XCTAssertEqual(spy.shownNotices, ["1-pass"])
    }

    func test_spyPill_normalShow_recordsNoNotice() {
        let spy = SpyPillController()
        spy.show(state: .transcribing)
        spy.show(state: .undoable(text: "x", method: .clipboard))
        XCTAssertNil(spy.lastShownNotice)
        XCTAssertTrue(spy.shownNotices.isEmpty,
            "Normal sessions must produce no notices at all")
    }

    func test_spyPill_languageBadgeShow_stillCarriesNoNotice() {
        // The pre-existing show(state:languageBadge:) convenience must keep
        // working and must not accidentally set a notice.
        let spy = SpyPillController()
        spy.show(state: .recording, languageBadge: "ZH·")
        XCTAssertEqual(spy.lastShownBadge, "ZH·")
        XCTAssertNil(spy.lastShownNotice)
    }
}
