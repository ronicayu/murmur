import XCTest
@testable import Murmur

/// How one decode is classified, and when a series of attempts is settled.
/// Pure logic — no speech model is loaded.
final class Qwen3DecodeJudgementTests: XCTestCase {

    typealias Service = Qwen3TranscriptionService
    typealias Attempt = Qwen3TranscriptionService.DecodeAttempt

    private let chineseAndEnglish: Set<WritingScript> = [.latin, .han]

    private func judge(_ text: String, speechSeconds: Double = 3,
                       expected: Set<WritingScript>? = nil) -> Service.DecodeJudgement {
        Service.judge(raw: text, cleaned: text, speechSeconds: speechSeconds,
                      expected: expected ?? chineseAndEnglish)
    }

    // MARK: - judge

    func test_judge_acceptsTextInAnExpectedScript() {
        XCTAssertEqual(judge("所有，只要处理data，不管你是做machine learning。"), .accepted)
        XCTAssertEqual(judge("Hello there, how are you?"), .accepted)
    }

    func test_judge_templateMarkersAndUndecodableBytesAreDebris() {
        XCTAssertEqual(
            Service.judge(raw: "<asr_text>system没有", cleaned: "没有", speechSeconds: 3, expected: chineseAndEnglish),
            .debris
        )
        XCTAssertEqual(judge("\u{FFFD}斯系统"), .debris)
        XCTAssertEqual(judge("会有更多。<|endoftext|>"), .debris)
    }

    func test_judge_nearlyNoTextForAudibleSpeechIsTooShort() {
        XCTAssertEqual(judge("好的好的", speechSeconds: 30), .tooShort)
    }

    func test_judge_shortReplyToShortAudioIsAccepted() {
        XCTAssertEqual(judge("好。", speechSeconds: 0.6), .accepted)
    }

    func test_judge_silenceTranscribedAsNothingIsAccepted() {
        XCTAssertEqual(judge("", speechSeconds: 0), .accepted)
    }

    func test_judge_textInAnotherScriptIsUnexpected() {
        XCTAssertEqual(judge("こんにちは、元気ですか"), .unexpectedScript(.kana))
        XCTAssertEqual(judge("Борсук, живущий в Киеве"), .unexpectedScript(.cyrillic))
        XCTAssertEqual(judge("สั่งฟรีสปายซี่ฟูด"), .unexpectedScript(.thai))
    }

    func test_judge_sameTextIsAcceptedOnceTheLanguageIsListed() {
        let withJapanese = SpokenLanguages.expectedScripts(forHint: "zh,en,ja")
        XCTAssertEqual(judge("こんにちは、元気ですか", expected: withJapanese), .accepted)
    }

    func test_judge_aForeignWordInsideExpectedTextIsAccepted() {
        // Mostly Chinese, with one word quoted in Japanese.
        XCTAssertEqual(judge("他说的那个词是ありがとう，我们都听懂了，然后大家继续开会讨论"), .accepted)
    }

    func test_judge_aLongRunOfOneShortUnitIsALoop() {
        let loop = "Okay. Hmm. Then I" + String(repeating: ", I", count: 40)
        XCTAssertEqual(judge(loop, speechSeconds: 39), .repetitionLoop)
        XCTAssertEqual(judge("我们" + String(repeating: "对", count: 30), speechSeconds: 10), .repetitionLoop)
    }

    func test_judge_realRepetitionIsAccepted() {
        XCTAssertEqual(judge("哈哈哈哈哈哈哈哈，太好笑了。"), .accepted)
        XCTAssertEqual(judge("嗯嗯嗯。对对对对，就是这样。"), .accepted)
        XCTAssertEqual(judge("Taiwan, from, from, from, from, from Taipei."), .accepted)
    }

    func test_collapsingLoops_keepsThreeOfTheUnit() {
        XCTAssertEqual(Service.collapsingLoops("Then I" + String(repeating: ", I", count: 40) + "."), "Then I, I, I, I.")
        XCTAssertEqual(Service.collapsingLoops("好的" + String(repeating: "对", count: 30)), "好的对对对")
        XCTAssertEqual(Service.collapsingLoops("哈哈哈哈，好。"), "哈哈哈哈，好。")
    }

    // MARK: - settledText

    func test_settled_acceptedAttemptSettlesImmediately() {
        XCTAssertEqual(Service.settledText([Attempt(text: "你好。", judgement: .accepted)]), "你好。")
    }

    func test_settled_debrisNeverSettles() {
        XCTAssertNil(Service.settledText([
            Attempt(text: "x", judgement: .debris),
            Attempt(text: "x", judgement: .debris),
        ]))
    }

    func test_settled_oneUnexpectedScriptAttemptIsNotEnough() {
        XCTAssertNil(Service.settledText([
            Attempt(text: "こんにちは、元気ですか", judgement: .unexpectedScript(.kana)),
        ]))
    }

    func test_settled_twoAgreeingAttemptsInTheSameUnexpectedScriptSettle() {
        // A language the user did not list, heard the same way twice (one
        // character differs between the passes).
        let first = "抜群の運動神経を用い合わせ、どんな要求にも応えてきた。"
        let second = "抜群の運動神経を持ち合わせ、どんな要求にも応えてきた。"
        XCTAssertEqual(
            Service.settledText([
                Attempt(text: first, judgement: .unexpectedScript(.kana)),
                Attempt(text: second, judgement: .unexpectedScript(.kana)),
            ]),
            first
        )
    }

    func test_settled_unexpectedScriptThatChangesBetweenAttemptsDoesNotSettle() {
        XCTAssertNil(Service.settledText([
            Attempt(text: "สั่งฟรีสปายซี่ฟูด", judgement: .unexpectedScript(.thai)),
            Attempt(text: "Борсук живущий", judgement: .unexpectedScript(.cyrillic)),
        ]))
    }

    func test_settled_sameScriptButUnrelatedTextDoesNotSettle() {
        XCTAssertNil(Service.settledText([
            Attempt(text: "こんにちは、元気ですか", judgement: .unexpectedScript(.kana)),
            Attempt(text: "まったく別の文章がここにあります", judgement: .unexpectedScript(.kana)),
        ]))
    }

    func test_settled_aLaterAcceptedAttemptWinsOverEarlierMisfires() {
        XCTAssertEqual(
            Service.settledText([
                Attempt(text: "สั่งฟรี", judgement: .unexpectedScript(.thai)),
                Attempt(text: "x", judgement: .debris),
                Attempt(text: "一份非常辣的食物。", judgement: .accepted),
            ]),
            "一份非常辣的食物。"
        )
    }

    // MARK: - lastResort

    func test_lastResort_prefersTheLongestMerelyShortTranscript() {
        XCTAssertEqual(
            Service.lastResort([
                Attempt(text: "x", judgement: .debris),
                Attempt(text: "好", judgement: .tooShort),
                Attempt(text: "好的", judgement: .tooShort),
            ], expected: chineseAndEnglish),
            "好的"
        )
    }

    func test_aLoopIsNeverSettled_butIsTheLastResortCutDown() {
        let loop = Attempt(text: "Then I" + String(repeating: ", I", count: 40), judgement: .repetitionLoop)
        XCTAssertNil(Service.settledText([loop, loop]))
        XCTAssertEqual(Service.lastResort([loop, Attempt(text: "x", judgement: .debris)], expected: chineseAndEnglish),
                       "Then I, I, I, I")
    }

    func test_lastResort_isEmptyWhenOnlyDebrisOrUnconfirmedScriptsRemain() {
        XCTAssertEqual(
            Service.lastResort([
                Attempt(text: "x", judgement: .debris),
                Attempt(text: "สั่งฟรี", judgement: .unexpectedScript(.thai)),
            ], expected: chineseAndEnglish),
            ""
        )
    }

    func test_lastResort_neverReturnsAShortTranscriptInAnUnexpectedScript() {
        // Four misfires of "да" on five seconds of speech, for a Chinese-only
        // user. Each is judged too short before its script is looked at.
        let chineseOnly: Set<WritingScript> = [.han]
        let attempts = (0..<4).map { _ in
            Attempt(text: "да",
                    judgement: Service.judge(raw: "да", cleaned: "да", speechSeconds: 5, expected: chineseOnly))
        }
        XCTAssertEqual(attempts.first?.judgement, .tooShort)
        XCTAssertNil(Service.settledText(attempts), "a short misfire must not settle by repetition")
        XCTAssertEqual(Service.lastResort(attempts, expected: chineseOnly), "")
    }

    func test_lastResort_keepsAShortTranscriptInAnExpectedScriptOverAForeignOne() {
        XCTAssertEqual(
            Service.lastResort([
                Attempt(text: "да да да", judgement: .tooShort),
                Attempt(text: "好", judgement: .tooShort),
            ], expected: chineseAndEnglish),
            "好"
        )
    }

    // MARK: - empty results (sound without speech)

    func test_judge_nothingForSeveralSecondsOfSoundIsTooShort() {
        XCTAssertEqual(judge("", speechSeconds: 5), .tooShort)
    }

    func test_settled_oneEmptyResultForAudibleSoundIsDecodedAgain() {
        XCTAssertNil(Service.settledText([Attempt(text: "", judgement: .tooShort)]))
    }

    func test_settled_twoEmptyResultsSettleOnNoText() {
        XCTAssertEqual(
            Service.settledText([
                Attempt(text: "", judgement: .tooShort),
                Attempt(text: "", judgement: .tooShort),
            ]),
            ""
        )
    }

    func test_settled_anEmptyResultAfterAShortOneDoesNotSettle() {
        // The first decode heard something; one empty retry does not overrule it.
        XCTAssertNil(Service.settledText([
            Attempt(text: "好", judgement: .tooShort),
            Attempt(text: "", judgement: .tooShort),
        ]))
    }

    func test_settled_twoShortButNonEmptyResultsDoNotSettle() {
        XCTAssertNil(Service.settledText([
            Attempt(text: "好", judgement: .tooShort),
            Attempt(text: "好", judgement: .tooShort),
        ]))
    }

    // MARK: - editRatio

    func test_editRatio() {
        XCTAssertEqual(Service.editRatio("abc", "abc"), 0)
        XCTAssertEqual(Service.editRatio("", ""), 0)
        XCTAssertEqual(Service.editRatio("abc", ""), 1)
        XCTAssertEqual(Service.editRatio("abcd", "abxd"), 0.25)
    }
}
