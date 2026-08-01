import XCTest
@testable import Murmur

// Matrix for the window-boundary separator decision used by
// StreamingTranscriptionCoordinator.injectDelta. Extracted into a pure function
// so the "space or no space across a window reset" rule is exhaustively testable
// without driving the whole async streaming pipeline.
//
// Rule: a leading space is added only at a window boundary, only when text
// already exists, and only when the next delta begins a Latin word.

final class StreamingSeparatorTests: XCTestCase {

    // MARK: Latin word starts → need a separator (at a boundary, with prior text)

    func test_asciiLetterStart_atBoundary_withPriorText_needsSpace() {
        XCTAssertTrue(StreamingSeparator.needsLeadingSpace(
            delta: "hello", atWindowBoundary: true, hasPriorText: true))
    }

    func test_uppercaseAsciiStart_needsSpace() {
        // Casing doesn't matter — "API" is still a Latin word start.
        XCTAssertTrue(StreamingSeparator.needsLeadingSpace(
            delta: "API", atWindowBoundary: true, hasPriorText: true))
    }

    // MARK: CJK / kana / Hangul starts → no separator

    func test_cjkStart_neverNeedsSpace() {
        XCTAssertFalse(StreamingSeparator.needsLeadingSpace(
            delta: "你好", atWindowBoundary: true, hasPriorText: true),
            "Chinese text is written without inter-word spaces")
    }

    func test_kanaStart_neverNeedsSpace() {
        XCTAssertFalse(StreamingSeparator.needsLeadingSpace(
            delta: "こんにちは", atWindowBoundary: true, hasPriorText: true))
    }

    func test_hangulStart_neverNeedsSpace() {
        XCTAssertFalse(StreamingSeparator.needsLeadingSpace(
            delta: "안녕", atWindowBoundary: true, hasPriorText: true))
    }

    // MARK: Punctuation / digit starts → no separator

    func test_punctuationStart_neverNeedsSpace() {
        XCTAssertFalse(StreamingSeparator.needsLeadingSpace(
            delta: ", world", atWindowBoundary: true, hasPriorText: true),
            "A leading space before a comma would be wrong")
    }

    func test_cjkPunctuationStart_neverNeedsSpace() {
        XCTAssertFalse(StreamingSeparator.needsLeadingSpace(
            delta: "。下一句", atWindowBoundary: true, hasPriorText: true))
    }

    func test_digitStart_neverNeedsSpace() {
        // "3D" — a rare boundary case; joining beats splitting a number.
        XCTAssertFalse(StreamingSeparator.needsLeadingSpace(
            delta: "3D", atWindowBoundary: true, hasPriorText: true))
    }

    // MARK: Not at a boundary, or no prior text → never a separator

    func test_notAtBoundary_neverNeedsSpace_evenForLatin() {
        XCTAssertFalse(StreamingSeparator.needsLeadingSpace(
            delta: "hello", atWindowBoundary: false, hasPriorText: true),
            "Within a window, deltas already carry their own spacing")
    }

    func test_noPriorText_neverNeedsSpace() {
        XCTAssertFalse(StreamingSeparator.needsLeadingSpace(
            delta: "hello", atWindowBoundary: true, hasPriorText: false),
            "The very first delta of a session has nothing to separate from")
    }

    func test_emptyDelta_neverNeedsSpace() {
        XCTAssertFalse(StreamingSeparator.needsLeadingSpace(
            delta: "", atWindowBoundary: true, hasPriorText: true))
    }
}
