import AVFoundation
import Foundation
import os

/// Murmur's speech engine: Qwen3-ASR-0.6B int8, run through the vendored
/// sherpa-onnx Swift API on 16 kHz mono Float32 audio.
///
/// Thread-safety: actor-isolated. The underlying `SherpaOnnxOfflineRecognizer` C
/// session is not thread-safe, so all transcribe calls serialise here.
///
/// Lifetime: the recognizer is created on first use (or `preloadModel`) and
/// kept until `unloadModel` or until it has been idle for `idleUnloadSeconds`.
/// Loading the three ONNX graphs takes ~1 s on a Mac M-series, so it is not
/// reloaded per request.
actor Qwen3TranscriptionService: TranscriptionServiceProtocol {

    private let logger = Logger(subsystem: "com.murmur.app", category: "qwen3")
    private let modelDirectory: URL
    private var recognizer: SherpaOnnxOfflineRecognizer?

    /// The loaded model holds 2–4 GB. It is released when nothing has used
    /// it for this long, and loaded again (about a second) at the next use.
    private let idleUnloadSeconds: TimeInterval
    private var idleUnload: IdleTrigger?
    private var lastUse = Date.distantPast

    /// A silence this long becomes a paragraph break in `transcribeLong` output.
    static let paragraphBreakGapSeconds: Double = 2.0

    // Conservative: callers always go through `preloadModel`, which is a
    // no-op once the recognizer exists.
    nonisolated var isModelLoaded: Bool { false }

    /// - Parameter modelDirectory: directory containing `conv_frontend.onnx`,
    ///   `encoder.int8.onnx`, `decoder.int8.onnx`, and `tokenizer/` from the
    ///   `csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25` HF repo. It
    ///   does not need to exist yet; loading fails with `modelNotFound` until
    ///   the model has been downloaded.
    init(modelDirectory: URL, idleUnloadSeconds: TimeInterval = 300) {
        self.modelDirectory = modelDirectory
        self.idleUnloadSeconds = idleUnloadSeconds
    }

    // MARK: - TranscriptionServiceProtocol

    func preloadModel() async throws {
        defer { noteUse() }
        _ = try loadedRecognizer()
    }

    func unloadModel() async {
        idleUnload?.cancel()
        recognizer = nil
    }

    /// Restarts the idle countdown. Called when a use of the model ends.
    private func noteUse() {
        lastUse = Date()
        if idleUnload == nil {
            idleUnload = IdleTrigger(seconds: idleUnloadSeconds) { [weak self] in
                await self?.unloadIfIdle()
            }
        }
        idleUnload?.touch()
    }

    /// The countdown can end while a long transcription holds the actor;
    /// this then runs after it, when the model has just been used.
    private func unloadIfIdle() {
        guard recognizer != nil, Date().timeIntervalSince(lastUse) >= idleUnloadSeconds else { return }
        recognizer = nil
        logger.info("Qwen3-ASR model unloaded after \(Int(self.idleUnloadSeconds)) s without use")
    }

    func killProcess() async {
        await unloadModel()
    }

    /// Transcribe one recording. `language` is the user's spoken languages as
    /// produced by `SpokenLanguages.hint(for:)`. The model detects the spoken
    /// language itself; the hint only says which scripts to expect (see `judge`).
    func transcribe(audioURL: URL, language: String) async throws -> TranscriptionResult {
        defer { noteUse() }
        let start = CFAbsoluteTimeGetCurrent()
        let samples = try Self.loadAudio(url: audioURL)
        let text = try decode(samples: samples, language: language)
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        return TranscriptionResult(text: text, language: Self.detectLanguage(text), durationMs: elapsedMs)
    }

    /// Transcribe a long file, reporting progress after each piece. Silences
    /// are skipped; long ones become paragraph breaks. Each decoded piece is a
    /// segment of the result, with the time it was said.
    ///
    /// The file stays on disk: one pass finds the loud stretches, a second
    /// finds where to cut, and each piece is read only to be decoded. At most
    /// one piece (`maxSegmentSeconds`) is in memory at a time.
    func transcribeLong(
        audioURL: URL,
        language: String,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        defer { noteUse() }
        let start = CFAbsoluteTimeGetCurrent()
        let recognizer = try loadedRecognizer()
        let source = try LongAudioSource(url: audioURL)
        let sampleRate = LongAudioSource.sampleRate

        // Stretches of speech first (split at pauses), then each stretch into
        // pieces short enough for one decode. Every piece is a segment with
        // its own time stamp.
        let loud = try Self.loudFrames(of: source)
        var spans: [(span: SpeechSpan, pieces: [Range<Int>])] = []
        for span in Self.speechSpans(loud: loud, sampleCount: source.count, sampleRate: sampleRate) {
            try Task.checkCancellation()
            spans.append((span, try Self.segmentRanges(of: span.range, in: source)))
        }
        let totalPieces = spans.reduce(0) { $0 + $1.pieces.count }

        var segments = SegmentBuilder(sampleRate: sampleRate)
        var done = 0
        for (span, pieces) in spans {
            for (index, range) in pieces.enumerated() {
                try Task.checkCancellation()
                let text = decodeWithRetry(try source.read(range), sampleRate: sampleRate, language: language, recognizer: recognizer)
                segments.add(text, piece: range, index: index, of: pieces.count, in: span)
                done += 1
                onProgress(TranscriptionProgress(currentChunk: done, totalChunks: totalPieces, partialText: Self.text(of: segments.segments)))
            }
        }

        let fullText = Self.text(of: segments.segments)
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        return TranscriptionResult(
            text: fullText,
            language: Self.detectLanguage(fullText),
            durationMs: elapsedMs,
            segments: segments.segments
        )
    }

    /// Turns decoded pieces into time-stamped segments.
    struct SegmentBuilder {
        let sampleRate: Int
        private(set) var segments: [TranscriptSegment] = []
        /// A paragraph break that no segment has carried yet: the span after
        /// the long silence may decode to nothing (a cough), and the break
        /// then belongs to the next speech.
        private var paragraphPending = false

        init(sampleRate: Int) { self.sampleRate = sampleRate }

        /// Adds piece `index` of the `count` pieces of `span`, which decoded to
        /// `text`. The span's speech, not its margin, gives the first start
        /// and the last end; inside the span the cuts do.
        mutating func add(_ text: String, piece range: Range<Int>, index: Int, of count: Int, in span: SpeechSpan) {
            if index == 0, span.startsParagraph { paragraphPending = true }
            guard !text.isEmpty else { return }
            let from = index == 0 ? span.speech.lowerBound : range.lowerBound
            let to = index == count - 1 ? span.speech.upperBound : range.upperBound
            segments.append(TranscriptSegment(
                start: Double(from) / Double(sampleRate),
                end: Double(to) / Double(sampleRate),
                text: text,
                startsParagraph: paragraphPending && !segments.isEmpty
            ))
            paragraphPending = false
        }
    }

    /// The transcript of `segments`: paragraphs separated by a blank line.
    nonisolated static func text(of segments: [TranscriptSegment]) -> String {
        var paragraphs: [[String]] = []
        for segment in segments {
            if segment.startsParagraph || paragraphs.isEmpty {
                paragraphs.append([segment.text])
            } else {
                paragraphs[paragraphs.count - 1].append(segment.text)
            }
        }
        return paragraphs.map(joined).joined(separator: "\n\n")
    }

    /// Transcribe samples already in memory (16 kHz mono).
    func transcribe(samples: [Float], sampleRate: Int, language: String = "") async throws -> String {
        precondition(sampleRate == 16000,
                     "Qwen3TranscriptionService requires 16 kHz audio; got \(sampleRate)")
        defer { noteUse() }
        return try decode(samples: samples, language: language)
    }

    // MARK: - Loading

    private func loadedRecognizer() throws -> SherpaOnnxOfflineRecognizer {
        if let recognizer { return recognizer }

        let fm = FileManager.default
        let allPresent = ModelBackend.qwen3.requiredFiles.allSatisfy {
            fm.fileExists(atPath: modelDirectory.appendingPathComponent($0).path)
        }
        guard allPresent else {
            throw MurmurError.modelNotFound
        }

        // maxTotalLen caps prompt + audio + generated tokens; the audio encoder
        // emits ~13 tokens per second, so 2048 leaves ample room for the 40 s
        // pieces `segmentRanges` produces. Hotwords are deliberately left
        // empty: in benchmarking, a fixed term list made mixed zh-en output
        // worse and occasionally sent the decoder into a repetition loop.
        let qwen3Asr = sherpaOnnxOfflineQwen3ASRModelConfig(
            convFrontend: modelDirectory.appendingPathComponent("conv_frontend.onnx").path,
            encoder: modelDirectory.appendingPathComponent("encoder.int8.onnx").path,
            decoder: modelDirectory.appendingPathComponent("decoder.int8.onnx").path,
            tokenizer: modelDirectory.appendingPathComponent("tokenizer").path,
            maxTotalLen: 2048,
            maxNewTokens: 512
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: "",
            numThreads: 4,
            provider: "cpu",
            debug: 0,
            qwen3Asr: qwen3Asr
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 128)
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig, modelConfig: modelConfig
        )
        let loaded = SherpaOnnxOfflineRecognizer(config: &config)
        recognizer = loaded
        logger.info("Qwen3-ASR model loaded from \(self.modelDirectory.path, privacy: .public)")
        return loaded
    }

    // MARK: - Decoding

    private func decode(samples: [Float], language: String) throws -> String {
        let recognizer = try loadedRecognizer()
        // One decode is bounded by `maxTotalLen`; a long recording would be
        // cut off part-way. Decode it in pieces split at quiet points instead.
        var pieces: [String] = []
        for range in Self.segmentRanges(samples: samples, sampleRate: 16000) {
            let piece = decodeWithRetry(Array(samples[range]), sampleRate: 16000, language: language, recognizer: recognizer)
            if !piece.isEmpty { pieces.append(piece) }
        }
        let text = Self.joined(pieces)
        // Speech stays out of the shared system log: private, so redacted
        // unless private logging is turned on for debugging.
        logger.info("Qwen3 text (\(text.count) characters): \(text.prefix(200), privacy: .private)")
        return text
    }

    /// Strips chat-template debris from raw model output.
    ///
    /// Qwen3-ASR is a language model that answers in the form
    /// `language Chinese<asr_text>…text…<|im_end|>`. sherpa-onnx normally returns
    /// only the text, but on some clips the scaffolding leaks through — e.g.
    /// `<asr_text>system没有…` — and would be typed at the cursor.
    nonisolated static func cleaned(_ raw: String) -> String {
        var text = raw
        // Generation past an end marker is the model continuing on its own.
        for endMarker in ["<|im_end|>", "<|endoftext|>"] {
            if let range = text.range(of: endMarker) {
                text = String(text[..<range.lowerBound])
            }
        }
        var sawScaffolding = false
        if let range = text.range(of: "<asr_text>", options: .backwards) {
            text = String(text[range.upperBound...])
            sawScaffolding = true
        }
        let tagPattern = "<\\|[^|>]*\\|>|</?asr_text>"
        if text.range(of: tagPattern, options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: tagPattern, with: "", options: .regularExpression)
            sawScaffolding = true
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A chat role name left stranded where a marker was removed.
        if sawScaffolding {
            for role in ["system", "assistant", "user"] where text.hasPrefix(role) {
                text = String(text.dropFirst(role.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return text
    }

    /// Start offsets (in samples) tried in turn when a decode is not accepted.
    private static let retryOffsets = [0, 160, 320, 480]

    /// Decode one segment, decoding again from a slightly later start when the
    /// result cannot be trusted as it stands.
    ///
    /// Two kinds of thing can be wrong with a result (see `judge`):
    ///
    /// - **Corrupt.** The int8 model has a rare failure where a clip of
    ///   ordinary speech comes back as a few characters of chat-template debris
    ///   (`�斯系统`, `<asr_text>system…`). It is deterministic for a given
    ///   input but chaotic — moving the start by a single sample gives a
    ///   correct transcript — so decoding again 10 ms later recovers it.
    ///   A **repetition loop** ("Then I, I, I, I, …" for 39 s of speech) is
    ///   the same kind of failure and is recovered the same way.
    /// - **Unexpected script.** Text in a writing system none of the user's
    ///   languages uses. That is either a misfire or the user speaking a
    ///   language they have not listed, and a second decode tells them apart:
    ///   real speech comes back in the same script with nearly the same
    ///   words, a misfire does not. When two attempts agree, the transcript is
    ///   accepted — the user's speech is never dropped for being unexpected.
    ///
    /// A third case needs only one more decode: **nothing at all** for several
    /// seconds of audible sound. That is usually sound with no speech in it
    /// (a fan, typing), and a second empty result confirms it (see `settledText`).
    private func decodeWithRetry(
        _ samples: [Float], sampleRate: Int, language: String, recognizer: SherpaOnnxOfflineRecognizer
    ) -> String {
        let speechSeconds = Self.speechSeconds(samples, sampleRate: sampleRate)
        let expected = SpokenLanguages.expectedScripts(forHint: language)
        var attempts: [DecodeAttempt] = []
        for offset in Self.retryOffsets where offset < samples.count {
            let clip = offset == 0 ? samples : Array(samples[offset...])
            let raw = recognizer.decode(samples: clip, sampleRate: sampleRate).text
            let text = Self.cleaned(raw)
            let judgement = Self.judge(raw: raw, cleaned: text, speechSeconds: speechSeconds, expected: expected)
            attempts.append(DecodeAttempt(text: text, judgement: judgement))
            if let settled = Self.settledText(attempts) {
                if offset > 0 { logger.info("Qwen3 decode settled after retry at +\(offset) samples") }
                return settled
            }
            logger.warning("Qwen3 decode not accepted at +\(offset) samples (\(String(describing: judgement), privacy: .public)): \(raw.prefix(60), privacy: .private)")
        }
        return Self.lastResort(attempts, expected: expected)
    }

    // MARK: - Judging a decode

    enum DecodeJudgement: Equatable, Sendable {
        /// Usable as it stands.
        case accepted
        /// Template markers or undecodable bytes: never usable.
        case debris
        /// Almost no text for several seconds of audible speech.
        case tooShort
        /// The decoder got stuck repeating a few characters ("I, I, I, …") and
        /// the speech after that point is lost.
        case repetitionLoop
        /// Clean text, but mostly in a script the user's languages do not use.
        case unexpectedScript(WritingScript)
    }

    struct DecodeAttempt: Equatable, Sendable {
        let text: String
        let judgement: DecodeJudgement
    }

    /// Classifies one decode.
    ///
    /// - Parameters:
    ///   - speechSeconds: how much of the audio was audible (see `speechSeconds`).
    ///     Normal speech runs at 3–5 characters per second; under 0.5 for four
    ///     seconds or more means the model gave up.
    ///   - expected: scripts of the user's languages.
    nonisolated static func judge(
        raw: String, cleaned: String, speechSeconds: Double, expected: Set<WritingScript>
    ) -> DecodeJudgement {
        if raw.contains("<asr_text>") || raw.contains("<|") || raw.contains("\u{FFFD}") { return .debris }
        if !repetitionLoops(in: cleaned).isEmpty { return .repetitionLoop }
        if speechSeconds >= 4 && Double(cleaned.count) < speechSeconds * 0.5 { return .tooShort }

        if let script = unexpectedScript(in: cleaned, expected: expected) { return .unexpectedScript(script) }
        return .accepted
    }

    /// The script `text` is mostly written in, when that is not one of the
    /// `expected` scripts; nil otherwise.
    ///
    /// A transcript is "in" an unexpected script when letters outside the
    /// expected scripts outnumber the letters inside them. A stray foreign
    /// word in an otherwise expected transcript is not a reason to distrust it.
    nonisolated static func unexpectedScript(in text: String, expected: Set<WritingScript>) -> WritingScript? {
        let counts = WritingScript.counts(in: text)
        let inside = counts.filter { expected.contains($0.key) }.reduce(0) { $0 + $1.value }
        let outside = counts.filter { !expected.contains($0.key) }
        let outsideTotal = outside.reduce(0) { $0 + $1.value }
        guard outsideTotal > inside else { return nil }
        return outside.max(by: { $0.value < $1.value })?.key
    }

    /// How alike two transcripts must be (character edit distance over the
    /// longer length) to count as the same speech heard twice. Genuine speech
    /// re-decoded from 10 ms later differs by a word or two at most.
    static let agreementMaxEditRatio = 0.4

    /// The text to return given the attempts so far, or nil to decode again.
    ///
    /// - An accepted attempt settles it.
    /// - Two attempts in the same unexpected script with nearly the same text
    ///   settle it too: that is the user speaking an unlisted language.
    /// - Two empty attempts settle on no text. The misfire a retry is for
    ///   gives a few wrong characters and changes when the start moves, so
    ///   silence from two different starts is the model hearing no speech.
    ///   Without this rule a window of steady noise costs every retry on
    ///   every streaming pass, and the stream falls behind the speaker.
    nonisolated static func settledText(_ attempts: [DecodeAttempt]) -> String? {
        guard let latest = attempts.last else { return nil }
        if latest.judgement == .accepted { return latest.text }
        if latest.text.isEmpty, latest.judgement == .tooShort,
           attempts.dropLast().contains(where: { $0.text.isEmpty && $0.judgement == .tooShort }) {
            return ""
        }
        guard case .unexpectedScript(let script) = latest.judgement else { return nil }
        for earlier in attempts.dropLast() {
            if case .unexpectedScript(script) = earlier.judgement,
               editRatio(earlier.text, latest.text) <= agreementMaxEditRatio {
                return earlier.text
            }
        }
        return nil
    }

    /// What to return when no attempt settled. A transcript that is merely
    /// short is still the best guess, and so is one stuck in a loop once the
    /// loop is cut down; debris and an unconfirmed foreign script are not
    /// worth typing, so the result may be empty. `judge` decides "too short"
    /// before it looks at the script, so the script is checked here.
    nonisolated static func lastResort(_ attempts: [DecodeAttempt], expected: Set<WritingScript>) -> String {
        attempts
            .compactMap { attempt -> String? in
                switch attempt.judgement {
                case .tooShort: return attempt.text
                case .repetitionLoop: return collapsingLoops(attempt.text)
                default: return nil
                }
            }
            .filter { unexpectedScript(in: $0, expected: expected) == nil }
            .max { $0.count < $1.count } ?? ""
    }

    // MARK: - Repetition loops

    /// A unit of up to 20 characters said again and again. Eight times over 24
    /// characters or more is a loop; real repetition ("哈哈哈哈", "嗯嗯嗯",
    /// "from, from, from") is shorter.
    private static let loopPattern = try! NSRegularExpression(
        pattern: "(.{1,20}?)\\1{7,}", options: [.dotMatchesLineSeparators])
    private static let minLoopCharacters = 24
    /// How many times a loop's unit is kept when nothing better was decoded.
    private static let keptLoopRepeats = 3

    /// The loops in `text`, each with its repeated unit.
    nonisolated static func repetitionLoops(in text: String) -> [(range: Range<String.Index>, unit: String)] {
        let whole = NSRange(text.startIndex..., in: text)
        return loopPattern.matches(in: text, range: whole).compactMap { match in
            guard let range = Range(match.range, in: text),
                  let unitRange = Range(match.range(at: 1), in: text),
                  text[range].count >= minLoopCharacters else { return nil }
            return (range, String(text[unitRange]))
        }
    }

    /// `text` with each loop cut down to `keptLoopRepeats` of its unit.
    nonisolated static func collapsingLoops(_ text: String) -> String {
        var result = text
        for loop in repetitionLoops(in: text).reversed() {
            result.replaceSubrange(loop.range, with: String(repeating: loop.unit, count: keptLoopRepeats))
        }
        return result
    }

    /// Character edit distance divided by the longer length (0 = identical).
    nonisolated static func editRatio(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 0 }
        if x.isEmpty || y.isEmpty { return 1 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    /// Seconds of `samples` whose 100 ms frames reach whisper level (≈ −50 dBFS).
    nonisolated static func speechSeconds(_ samples: [Float], sampleRate: Int) -> Double {
        let frame = max(1, sampleRate / 10)
        var loud = 0
        var start = 0
        while start < samples.count {
            let end = min(start + frame, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            if (sum / Float(end - start)).squareRoot() >= 0.00316 { loud += 1 }
            start = end
        }
        return Double(loud) / 10
    }

    /// Longest stretch decoded in one go.
    static let maxSegmentSeconds = 40.0
    /// How far back from that limit to look for a quiet point to cut at.
    static let splitSearchSeconds = 10.0

    /// Splits `samples` into ranges of at most `maxSegmentSeconds`, each cut at
    /// the quietest 0.3 s within the last `splitSearchSeconds` of the limit so
    /// a cut lands in a pause rather than through a word. Audio that already
    /// fits is returned as a single range.
    nonisolated static func segmentRanges(samples: [Float], sampleRate: Int) -> [Range<Int>] {
        let maxLength = Int(maxSegmentSeconds * Double(sampleRate))
        guard samples.count > maxLength else { return [0..<samples.count] }

        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLength {
            let cut = start + quietestCut(in: samples[start..<(start + maxLength)], sampleRate: sampleRate)
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<samples.count)
        return ranges
    }

    /// The same split as `segmentRanges(samples:sampleRate:)` for the part
    /// `range` of a recording on disk. Reads one `maxSegmentSeconds` window at
    /// a time.
    nonisolated static func segmentRanges(of range: Range<Int>, in source: LongAudioSource) throws -> [Range<Int>] {
        let sampleRate = LongAudioSource.sampleRate
        let maxLength = Int(maxSegmentSeconds * Double(sampleRate))
        var ranges: [Range<Int>] = []
        var start = range.lowerBound
        while range.upperBound - start > maxLength {
            let window = try source.read(start..<(start + maxLength))
            // A file shorter than its header says: stop instead of looping.
            guard window.count == maxLength else { break }
            let cut = start + quietestCut(in: window[...], sampleRate: sampleRate)
            ranges.append(start..<cut)
            start = cut
        }
        if start < range.upperBound { ranges.append(start..<range.upperBound) }
        return ranges
    }

    /// Where to cut a window that is exactly `maxSegmentSeconds` long: the
    /// middle of its quietest 0.3 s within the last `splitSearchSeconds`, as
    /// an offset from the start of the window.
    private nonisolated static func quietestCut(in window: ArraySlice<Float>, sampleRate: Int) -> Int {
        let search = Int(splitSearchSeconds * Double(sampleRate))
        let frame = max(1, sampleRate * 3 / 10)
        let hop = max(1, frame / 3)
        let base = window.startIndex
        let limit = window.count
        var bestCut = limit
        var bestEnergy = Float.greatestFiniteMagnitude
        var position = limit - search
        while position + frame <= limit {
            var energy: Float = 0
            for i in position..<(position + frame) { energy += window[base + i] * window[base + i] }
            if energy < bestEnergy {
                bestEnergy = energy
                bestCut = position + frame / 2
            }
            position += hop
        }
        return bestCut
    }

    /// Joins per-segment transcripts. A space is added only between two Latin
    /// words; CJK text and punctuation need none.
    nonisolated static func joined(_ pieces: [String]) -> String {
        var text = ""
        for piece in pieces {
            if let last = text.last, let first = piece.first,
               last.isASCII, first.isASCII,
               last.isLetter || last.isNumber || ".,!?".contains(last),
               first.isLetter || first.isNumber {
                text += " "
            }
            text += piece
        }
        return text
    }

    // MARK: - Long audio

    /// A stretch of speech in a long recording.
    struct SpeechSpan: Equatable, Sendable {
        /// The samples to decode: the speech and a short margin on each side,
        /// so no word edge is clipped.
        let range: Range<Int>
        /// The speech alone, to 100 ms. Its edges are the time stamps.
        let speech: Range<Int>
        /// The silence before it is at least `paragraphBreakGapSeconds`.
        let startsParagraph: Bool
    }

    /// A pause this long ends a span once the span is `minSpanSeconds` long.
    static let spanPauseSeconds: Double = 1.0
    /// Spans shorter than this run on through pauses shorter than a paragraph
    /// break: very short pieces give the model too little context.
    static let minSpanSeconds: Double = 10.0

    /// Splits a recording into spans of speech, dropping the silence between
    /// them. A span ends at every silence of `paragraphBreakGapSeconds`, and at
    /// a pause of `spanPauseSeconds` once it is `minSpanSeconds` long. Audio
    /// with no such pause comes back as one span; all-silent audio as none.
    nonisolated static func speechSpans(samples: [Float], sampleRate: Int) -> [SpeechSpan] {
        var loud: [Bool] = []
        appendLoudFrames(of: samples, sampleRate: sampleRate, to: &loud)
        return speechSpans(loud: loud, sampleCount: samples.count, sampleRate: sampleRate)
    }

    /// Whether each 100 ms frame of a recording on disk reaches whisper level.
    nonisolated static func loudFrames(of source: LongAudioSource) throws -> [Bool] {
        let sampleRate = LongAudioSource.sampleRate
        let frame = max(1, sampleRate / 10)
        var loud: [Bool] = []
        loud.reserveCapacity(source.count / frame + 1)
        // Blocks are a whole number of frames, so frame edges fall where they
        // would in one pass over all the samples.
        try source.forEachBlock(of: frame * 100) { block in
            appendLoudFrames(of: block, sampleRate: sampleRate, to: &loud)
        }
        return loud
    }

    private nonisolated static func appendLoudFrames(of samples: [Float], sampleRate: Int, to loud: inout [Bool]) {
        let frame = max(1, sampleRate / 10)
        var start = 0
        while start < samples.count {
            let end = min(start + frame, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            loud.append((sum / Float(end - start)).squareRoot() >= 0.00316)
            start = end
        }
    }

    /// `speechSpans(samples:sampleRate:)` from the per-frame loudness.
    nonisolated static func speechSpans(loud: [Bool], sampleCount: Int, sampleRate: Int) -> [SpeechSpan] {
        let frame = max(1, sampleRate / 10)
        let paragraphGapFrames = Int(paragraphBreakGapSeconds * 10)
        let pauseFrames = Int(spanPauseSeconds * 10)
        let minSpanFrames = Int(minSpanSeconds * 10)
        let margin = 3  // 0.3 s of the silence kept around speech

        var spans: [(frames: Range<Int>, startsParagraph: Bool)] = []
        var spanStart: Int?
        var startsParagraph = false
        var lastLoud = -1
        for index in 0..<loud.count where loud[index] {
            if let start = spanStart {
                let silent = index - lastLoud - 1
                let paragraphBreak = silent >= paragraphGapFrames
                if paragraphBreak || (silent >= pauseFrames && lastLoud + 1 - start >= minSpanFrames) {
                    spans.append((start..<(lastLoud + 1), startsParagraph))
                    spanStart = index
                    startsParagraph = paragraphBreak
                }
            } else {
                spanStart = index
            }
            lastLoud = index
        }
        if let start = spanStart { spans.append((start..<(lastLoud + 1), startsParagraph)) }

        return spans.map { span in
            let frames = span.frames
            return SpeechSpan(
                range: (max(0, frames.lowerBound - margin) * frame)..<min(sampleCount, (frames.upperBound + margin) * frame),
                speech: (frames.lowerBound * frame)..<min(sampleCount, frames.upperBound * frame),
                startsParagraph: span.startsParagraph
            )
        }
    }

    // MARK: - Audio loading and language tagging

    /// Load an audio file as 16 kHz mono Float32 samples, converting if needed.
    nonisolated static func loadAudio(url: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let srcFormat = audioFile.processingFormat
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

        if srcFormat.sampleRate == 16000 && srcFormat.channelCount == 1
            && srcFormat.commonFormat == .pcmFormatFloat32 {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(audioFile.length)
            ) else {
                throw MurmurError.transcriptionFailed("Failed to create audio buffer")
            }
            try audioFile.read(into: buffer)
            guard let data = buffer.floatChannelData?[0] else {
                throw MurmurError.transcriptionFailed("No audio data")
            }
            return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw MurmurError.transcriptionFailed("Cannot create audio converter")
        }
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: 4096)!
        var allSamples = [Float]()
        var convertError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            do {
                inputBuffer.frameLength = 0
                try audioFile.read(into: inputBuffer)
                if inputBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
        }
        var status: AVAudioConverterOutputStatus
        repeat {
            let chunk = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096)!
            status = converter.convert(to: chunk, error: &convertError, withInputFrom: inputBlock)
            if let data = chunk.floatChannelData?[0], chunk.frameLength > 0 {
                allSamples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(chunk.frameLength)))
            }
        } while status == .haveData

        if allSamples.isEmpty {
            throw MurmurError.transcriptionFailed("No audio data after conversion")
        }
        return allSamples
    }

    /// Tags a transcript by content, since the model does not report a language.
    /// Counts Chinese characters against Latin *words* (a word is many letters,
    /// so counting letters would call "我们用 Python 写 machine learning 的代码"
    /// English): Chinese when its characters are over 30% of those units,
    /// English when the rest is Latin, and unknown for any other script.
    nonisolated static func detectLanguage(_ text: String) -> DetectedLanguage {
        var chinese = 0, latinWords = 0, other = 0
        var inLatinWord = false
        for scalar in text.unicodeScalars {
            let isLetter = CharacterSet.letters.contains(scalar)
            let isLatin = isLetter && scalar.value <= 0x024F
            if isLatin {
                if !inLatinWord { latinWords += 1 }
                inLatinWord = true
                continue
            }
            inLatinWord = false
            guard isLetter else { continue }
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF: chinese += 1
            default: other += 1
            }
        }
        let total = chinese + latinWords + other
        guard total > 0 else { return .unknown }
        // Japanese is written with many of the same characters as Chinese, but
        // always alongside kana; do not let those characters claim it.
        let scripts = WritingScript.counts(in: text)
        if scripts[.kana, default: 0] + scripts[.hangul, default: 0] > 0 { return .unknown }
        if Double(chinese) / Double(total) > 0.3 { return .chinese }
        return other > latinWords ? .unknown : .english
    }
}
