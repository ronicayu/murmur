import XCTest
@testable import Murmur

final class TranscriptFormatTests: XCTestCase {

    private let segments = [
        TranscriptSegment(start: 0.4, end: 12.25, text: "Hello there."),
        TranscriptSegment(start: 13.8, end: 25, text: "我们开始吧。"),
        TranscriptSegment(start: 75.05, end: 80.5, text: "Next topic.", startsParagraph: true),
    ]

    func test_timestamp_minutesAndSeconds() {
        XCTAssertEqual(TranscriptFormat.timestamp(0.4, withHours: false), "00:00")
        XCTAssertEqual(TranscriptFormat.timestamp(75.9, withHours: false), "01:15")
        XCTAssertEqual(TranscriptFormat.timestamp(3725, withHours: true), "1:02:05")
        XCTAssertEqual(TranscriptFormat.timestamp(65, withHours: true), "0:01:05")
    }

    func test_timestampedText_oneLinePerSegment_blankLineBeforeAParagraph() {
        XCTAssertEqual(
            TranscriptFormat.timestampedText(segments),
            "[00:00] Hello there.\n[00:13] 我们开始吧。\n\n[01:15] Next topic."
        )
    }

    func test_timestampedText_allStampsHaveHoursOnceTheTranscriptReachesAnHour() {
        let long = [
            TranscriptSegment(start: 5, end: 9, text: "a"),
            TranscriptSegment(start: 3600, end: 3605, text: "b"),
        ]
        XCTAssertEqual(TranscriptFormat.timestampedText(long), "[0:00:05] a\n[1:00:00] b")
    }

    func test_srt_numberedCuesWithMilliseconds() {
        XCTAssertEqual(TranscriptFormat.srt(segments), """
            1
            00:00:00,400 --> 00:00:12,250
            Hello there.

            2
            00:00:13,800 --> 00:00:25,000
            我们开始吧。

            3
            00:01:15,050 --> 00:01:20,500
            Next topic.

            """)
    }

    func test_displayText_plainWithoutSegmentsOrWhenTimestampsAreOff() {
        var entry = TranscriptionEntry(
            id: UUID(), date: Date(), audioDuration: 81, text: "plain", language: "en",
            status: .completed, m4aPath: nil
        )
        XCTAssertFalse(entry.hasTimestamps)
        XCTAssertEqual(entry.displayText(withTimestamps: true), "plain")

        entry.segments = segments
        XCTAssertTrue(entry.hasTimestamps)
        XCTAssertEqual(entry.displayText(withTimestamps: false), "plain")
        XCTAssertEqual(entry.displayText(withTimestamps: true), TranscriptFormat.timestampedText(segments))
    }
}
