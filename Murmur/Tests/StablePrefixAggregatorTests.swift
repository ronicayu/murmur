import XCTest
@testable import Murmur

/// LocalAgreement-2 stable-prefix aggregator: emit only what two consecutive
/// hypotheses agree on, suppressing one-pass hallucinations and boundary flicker.
final class StablePrefixAggregatorTests: XCTestCase {

    func test_firstPass_emitsNothing() {
        var agg = StablePrefixAggregator()
        XCTAssertEqual(agg.ingest("你好"), "", "LocalAgreement-2 needs a second pass before emitting")
        XCTAssertEqual(agg.confirmedText, "")
    }

    func test_secondIdenticalPass_confirmsAll() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("你好")
        XCTAssertEqual(agg.ingest("你好"), "你好")
        XCTAssertEqual(agg.confirmedText, "你好")
    }

    func test_growingStablePrefix_streamsConfirmedChunks() {
        var agg = StablePrefixAggregator()
        XCTAssertEqual(agg.ingest("我们用"), "")                    // pass 1: nothing yet
        XCTAssertEqual(agg.ingest("我们用 python"), "我们用")        // 我们用 now agreed
        XCTAssertEqual(agg.ingest("我们用 python 写"), " python")   // python now agreed (keeps the space)
        XCTAssertEqual(agg.confirmedText, "我们用 python")
    }

    func test_unstableTail_isWithheldUntilConfirmed() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("做 data")
        // Pass 2 revises the tail: "data" agrees, the new tail "science" does not yet.
        XCTAssertEqual(agg.ingest("做 data science"), "做 data")
        // Pass 3 confirms "science".
        XCTAssertEqual(agg.ingest("做 data science 也好"), " science")
        XCTAssertEqual(agg.confirmedText, "做 data science")
    }

    func test_onePassHallucination_neverEmitted() {
        var agg = StablePrefixAggregator()
        // A phantom phrase appears in the first hypothesis (classic near-silence hallucination)...
        XCTAssertEqual(agg.ingest("thank you"), "")
        // ...but the real audio's next pass disagrees entirely -> nothing committed from pass 1.
        XCTAssertEqual(agg.ingest("我好"), "")
        XCTAssertEqual(agg.ingest("我好"), "我好")
        XCTAssertEqual(agg.confirmedText, "我好")
        XCTAssertFalse(agg.confirmedText.contains("thank"))
    }

    func test_caseAndSpacingPreserved_butAgreementIsCaseInsensitive() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("use api")
        // Casing jitter on an agreed token must not block confirmation; emitted text
        // uses the current hypothesis's verbatim characters.
        XCTAssertEqual(agg.ingest("use API now"), "use API")
        XCTAssertEqual(agg.confirmedText, "use API")
    }

    func test_flushAndReset_emitsWithheldTail_thenResets() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("你好呀")
        _ = agg.ingest("你好呀 现在")          // confirms "你好呀", withholds "现在"
        XCTAssertEqual(agg.confirmedText, "你好呀")
        // Sentence-final pause: flush the withheld tail and reset.
        XCTAssertEqual(agg.flushAndReset(), " 现在")
        XCTAssertEqual(agg.confirmedText, "")
        // Next window starts clean.
        XCTAssertEqual(agg.ingest("下一句"), "")
        XCTAssertEqual(agg.ingest("下一句"), "下一句")
    }

    func test_concatenatedDeltas_reproduceConfirmedText() {
        var agg = StablePrefixAggregator()
        let hyps = ["所有只要", "所有只要处理 data", "所有只要处理 data 不管", "所有只要处理 data 不管你"]
        var assembled = ""
        for h in hyps { assembled += agg.ingest(h) }
        XCTAssertEqual(assembled, agg.confirmedText)
        assembled += agg.flushAndReset()
        XCTAssertEqual(assembled, "所有只要处理 data 不管你",
                       "deltas + flush must reproduce the final hypothesis verbatim")
    }

    func test_emptyHypothesis_isSafe() {
        var agg = StablePrefixAggregator()
        XCTAssertEqual(agg.ingest(""), "")
        XCTAssertEqual(agg.ingest("hi"), "")
        XCTAssertEqual(agg.flushAndReset(), "hi")
    }

    func test_shrinkingHypothesis_doesNotCrashOrEmitGarbage() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("one two three")
        _ = agg.ingest("one two three")       // confirm all three
        // A later pass returns fewer tokens (re-transcription got shorter).
        let delta = agg.ingest("one")
        XCTAssertEqual(delta, "", "no new confirmation when the hypothesis shrinks")
    }
}

/// Punctuation must not block agreement: punctuating models move commas and
/// full stops between passes of the same audio.
final class StablePrefixAggregatorPunctuationTests: XCTestCase {

    func test_commaJitter_doesNotStallConfirmation() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("所有，只要处理")
        // Same words, comma dropped: every word is still agreed.
        XCTAssertEqual(agg.ingest("所有只要处理 data"), "所有只要处理")
    }

    func test_trailingFullStopOnPartialHypothesis_isNotConfirmedEarly() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("今天天气。")
        // The words agree; the full stop that ended the partial pass must not be emitted.
        XCTAssertEqual(agg.ingest("今天天气很好。"), "今天天气")
    }

    func test_punctuationBetweenWords_isEmittedWithTheFollowingDelta() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("你好")
        _ = agg.ingest("你好，现在")
        XCTAssertEqual(agg.ingest("你好，现在可以"), "，现在")
    }

    func test_flush_includesTrailingPunctuation() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("你好呀，现在可以了吗？")
        XCTAssertEqual(agg.ingest("你好呀，现在可以了吗？"), "你好呀，现在可以了吗")
        XCTAssertEqual(agg.flushAndReset(), "？")
    }

    func test_lastPassFullyAgreed_onlyWhenWordsAreIdentical() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("你好")
        XCTAssertFalse(agg.lastPassFullyAgreed, "a first pass has nothing to agree with")
        _ = agg.ingest("你好，现在")
        XCTAssertFalse(agg.lastPassFullyAgreed, "the hypothesis is still growing")
        _ = agg.ingest("你好。现在")
        XCTAssertTrue(agg.lastPassFullyAgreed, "same words, different punctuation: the speaker paused")
    }

    func test_flickerInsideConfirmedText_doesNotBlockLaterWords() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("成为科隆群岛")
        XCTAssertEqual(agg.ingest("成为科隆群岛主要"), "成为科隆群岛")
        // A homophone flips inside the already-confirmed part; the words after it still agree.
        XCTAssertEqual(agg.ingest("成为克隆群岛主要的食草"), "主要")
        XCTAssertEqual(agg.ingest("成为科隆群岛主要的食草动物"), "的食草")
        XCTAssertEqual(agg.confirmedText, "成为科隆群岛主要的食草")
    }

    func test_wordInsertedBeforeConfirmedText_doesNotRepeatTypedWords() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("会丢掉一些词")
        XCTAssertEqual(agg.ingest("会丢掉一些词这段"), "会丢掉一些词")
        // Later passes hear an extra phrase at the start, shifting every position.
        XCTAssertEqual(agg.ingest("有时候会丢掉一些词这段话就是"), "这段",
                       "must continue after the typed words, not re-emit them")
        XCTAssertEqual(agg.ingest("有时候会丢掉一些词这段话就是我"), "话就是")
        XCTAssertEqual(agg.confirmedText, "会丢掉一些词这段话就是")
    }

    func test_hypothesisThatDropsTheTypedWords_emitsNothingAndFlushesNothing() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("今天天气很好")
        _ = agg.ingest("今天天气很好")
        // The next passes share nothing with what was typed: there is no safe place to continue from.
        XCTAssertEqual(agg.ingest("完全不同的内容"), "")
        XCTAssertEqual(agg.ingest("完全不同的内容"), "")
        XCTAssertEqual(agg.flushAndReset(), "")
    }
}

/// The model changes its mind about the last word it already had confirmed.
/// The stream must carry on after that word, and never repeat emitted text.
final class StablePrefixAggregatorRevisionTests: XCTestCase {

    func test_lastEmittedWordRevised_english_streamContinuesAfterIt() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("I think their")
        XCTAssertEqual(agg.ingest("I think their"), "I think their")
        // With more audio the model changes its mind about the last word.
        XCTAssertEqual(agg.ingest("I think there are many"), "",
                       "the revised word stands where one was already emitted")
        XCTAssertEqual(agg.ingest("I think there are many people"), " are many")
        XCTAssertEqual(agg.ingest("I think there are many people here"), " people")
        XCTAssertEqual(agg.confirmedText, "I think their are many people")
        XCTAssertEqual(agg.flushAndReset(), " here")
    }

    func test_lastEmittedWordRevised_chinese_streamContinuesAfterIt() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("我们今天")
        XCTAssertEqual(agg.ingest("我们今天"), "我们今天")
        XCTAssertEqual(agg.ingest("我们今田去公园"), "")
        XCTAssertEqual(agg.ingest("我们今田去公园玩"), "去公园")
        XCTAssertEqual(agg.confirmedText, "我们今天去公园",
                       "nothing already emitted may be emitted again")
    }

    func test_lastEmittedWordRevised_flushReturnsTheRest() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("我们今天")
        _ = agg.ingest("我们今天")
        _ = agg.ingest("我们今田去公园")
        XCTAssertEqual(agg.flushAndReset(), "去公园")
    }

    func test_lastTwoEmittedWordsRevised_streamContinuesAfterThem() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("a b c d")
        _ = agg.ingest("a b c d")
        _ = agg.ingest("a b x y e f")
        XCTAssertEqual(agg.ingest("a b x y e f g"), " e f")
    }

    func test_onlyEmittedWordRevised_continuesAtTheCountPosition() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("their")
        XCTAssertEqual(agg.ingest("their"), "their")
        _ = agg.ingest("there are")
        XCTAssertEqual(agg.ingest("there are many"), " are")
    }

    func test_oneWordConfirmedAfterTheRevisedOne_streamStillContinues() {
        // "their are" is in no later hypothesis either; the run before the
        // revised word is what lines the next pass up.
        var agg = StablePrefixAggregator()
        _ = agg.ingest("I think their")
        _ = agg.ingest("I think their")
        _ = agg.ingest("I think there are")
        XCTAssertEqual(agg.ingest("I think there are"), " are")
        _ = agg.ingest("I think there are many")
        XCTAssertEqual(agg.ingest("I think there are many"), " many")
    }

    func test_hypothesisThatEndsInsideTheEmittedWords_thenGrowsBack_repeatsNothing() {
        var agg = StablePrefixAggregator()
        _ = agg.ingest("a b a b")
        XCTAssertEqual(agg.ingest("a b a b"), "a b a b")
        XCTAssertEqual(agg.ingest("a b a"), "")
        XCTAssertEqual(agg.ingest("a b a b c d"), "")
        XCTAssertEqual(agg.ingest("a b a b c d"), " c d")
    }
}
