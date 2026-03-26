import XCTest
@testable import TensorLabsVoice

@MainActor
private final class MockASREngine: ASREngine {
    let id: String
    let requiresSpeechRecognitionPermission: Bool = false

    private let events: [ASREvent]

    init(id: String, events: [ASREvent]) {
        self.id = id
        self.events = events
    }

    func prepare() async throws {}

    func transcribe(audioStream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<ASREvent, Error> {
        let events = self.events
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await _ in audioStream {}
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func stop() async {}
}

@MainActor
private final class TimedMockASREngine: ASREngine {
    let id: String
    let requiresSpeechRecognitionPermission: Bool = false

    private let timedEvents: [(delayNs: UInt64, event: ASREvent)]

    init(id: String, timedEvents: [(delayNs: UInt64, event: ASREvent)]) {
        self.id = id
        self.timedEvents = timedEvents
    }

    func prepare() async throws {}

    func transcribe(audioStream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<ASREvent, Error> {
        let timedEvents = self.timedEvents
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await _ in audioStream {}
                    for timedEvent in timedEvents {
                        if timedEvent.delayNs > 0 {
                            try? await Task.sleep(nanoseconds: timedEvent.delayNs)
                        }
                        continuation.yield(timedEvent.event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func stop() async {}
}

final class ASRPipelineTests: XCTestCase {
    @MainActor
    func testHybridEngineUsesLocalFinalizationToReplaceRealtimeTranscript() async throws {
        let realtime = MockASREngine(id: "realtime", events: [
            .partial("hello life", scope: .fullTranscript),
            .final("hello life", scope: .fullTranscript),
        ])
        let finalization = MockASREngine(id: "finalization", events: [
            .final("hello live", scope: .fullTranscript),
        ])
        let engine = HybridStreamingASREngine(
            realtimeEngine: realtime,
            finalizationEngine: finalization,
            metricsLogger: LocalMetricsLogger()
        )

        try await engine.prepare()

        let stream = AsyncThrowingStream<[Float], Error> { continuation in
            continuation.yield([0.1, 0.2, 0.3])
            continuation.finish()
        }

        var observedEvents: [ASREvent] = []
        for try await event in engine.transcribe(audioStream: stream) {
            observedEvents.append(event)
        }

        XCTAssertTrue(observedEvents.contains(.partial("hello life", scope: .fullTranscript)))
        XCTAssertTrue(observedEvents.contains(.final("hello life", scope: .fullTranscript)))
        XCTAssertTrue(observedEvents.contains(.partial("hello live", scope: .fullTranscript)))
        XCTAssertEqual(observedEvents.last, .final("hello live", scope: .fullTranscript))
    }

    @MainActor
    func testHybridEngineStreamsLocalSegmentCorrectionsBeforeSessionEnds() async throws {
        let realtime = MockASREngine(id: "realtime", events: [
            .partial("hello world", scope: .fullTranscript),
        ])
        let finalization = MockASREngine(id: "finalization", events: [
            .final("hello world.", scope: .currentSegment),
            .final("how are you", scope: .currentSegment),
        ])
        let engine = HybridStreamingASREngine(
            realtimeEngine: realtime,
            finalizationEngine: finalization,
            metricsLogger: LocalMetricsLogger()
        )

        try await engine.prepare()

        let stream = AsyncThrowingStream<[Float], Error> { continuation in
            continuation.yield([0.1, 0.2, 0.3])
            continuation.finish()
        }

        var observedEvents: [ASREvent] = []
        for try await event in engine.transcribe(audioStream: stream) {
            observedEvents.append(event)
        }

        XCTAssertTrue(observedEvents.contains(.partial("hello world.", scope: .fullTranscript)))
        XCTAssertTrue(observedEvents.contains(.partial("hello world. how are you", scope: .fullTranscript)))
    }

    @MainActor
    func testHybridEngineSuppressesStaleRealtimePartialsAfterLiveFinalizationAppears() async throws {
        let realtime = TimedMockASREngine(id: "realtime", timedEvents: [
            (delayNs: 0, event: .partial("hello world", scope: .fullTranscript)),
            (delayNs: 20_000_000, event: .partial("hello world how are", scope: .fullTranscript)),
            (delayNs: 20_000_000, event: .final("hello world how are", scope: .fullTranscript)),
        ])
        let finalization = TimedMockASREngine(id: "finalization", timedEvents: [
            (delayNs: 10_000_000, event: .final("hello world.", scope: .currentSegment)),
            (delayNs: 10_000_000, event: .final("how are you", scope: .currentSegment)),
        ])
        let engine = HybridStreamingASREngine(
            realtimeEngine: realtime,
            finalizationEngine: finalization,
            metricsLogger: LocalMetricsLogger()
        )

        try await engine.prepare()

        let stream = AsyncThrowingStream<[Float], Error> { continuation in
            continuation.yield([0.1, 0.2, 0.3])
            continuation.finish()
        }

        var observedEvents: [ASREvent] = []
        for try await event in engine.transcribe(audioStream: stream) {
            observedEvents.append(event)
        }

        XCTAssertTrue(observedEvents.contains(.partial("hello world", scope: .fullTranscript)))
        XCTAssertTrue(observedEvents.contains(.partial("hello world.", scope: .fullTranscript)))
        XCTAssertTrue(observedEvents.contains(.partial("hello world. how are you", scope: .fullTranscript)))
        XCTAssertFalse(observedEvents.contains(.partial("hello world how are", scope: .fullTranscript)))
    }

    func testTranscriptComposerAppendsSegmentScopedResults() {
        var composer = TranscriptComposer()

        composer.apply(.partial("hello world", scope: .currentSegment))
        XCTAssertEqual(composer.renderedText, "hello world")

        composer.apply(.final("hello world", scope: .currentSegment))
        composer.apply(.partial("how are you", scope: .currentSegment))

        XCTAssertEqual(composer.renderedText, "hello world how are you")
        XCTAssertEqual(composer.finalTranscript, "hello world how are you")
    }

    func testTranscriptComposerLetsFullTranscriptResultsReviseEarlierPunctuation() {
        var composer = TranscriptComposer()

        composer.apply(.partial("Hello world.", scope: .fullTranscript))
        XCTAssertEqual(composer.renderedText, "Hello world.")

        composer.apply(.partial("Hello world and welcome", scope: .fullTranscript))
        XCTAssertEqual(composer.renderedText, "Hello world and welcome")

        composer.apply(.final("Hello world and welcome", scope: .fullTranscript))
        XCTAssertEqual(composer.finalTranscript, "Hello world and welcome")
    }

    func testTranscriptComposerFullTranscriptFinalOverridesSegmentHistory() {
        var composer = TranscriptComposer()

        composer.apply(.final("hello", scope: .currentSegment))
        composer.apply(.final("hello there", scope: .fullTranscript))

        XCTAssertEqual(composer.renderedText, "hello there")
        XCTAssertEqual(composer.finalTranscript, "hello there")
    }

    func testTranscriptStabilizerKeepsRecentTailVolatile() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.update(with: "hello world this is")
        let snapshot = stabilizer.update(with: "hello world this is a test")

        XCTAssertEqual(snapshot.stableText, "hello world this")
        XCTAssertEqual(snapshot.volatileText, "is a test")
        XCTAssertEqual(snapshot.displayText, "hello world this is a test")
    }

    func testTranscriptStabilizerCommitPromotesEntireTranscript() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.update(with: "hello life")
        let snapshot = stabilizer.commit("hello live")

        XCTAssertEqual(snapshot.stableText, "hello live")
        XCTAssertEqual(snapshot.volatileText, "")
        XCTAssertEqual(snapshot.displayText, "hello live")
    }

    func testLiveDictationAccumulatorPromotesCompletedSentenceBeforeNextOne() {
        var accumulator = LiveDictationAccumulator()

        XCTAssertEqual(
            accumulator.update(
                stableText: "Testing dictation",
                volatileText: "through the app.",
                isFinalEvent: false
            ),
            "Testing dictation through the app."
        )

        XCTAssertEqual(
            accumulator.update(
                stableText: "Testing dictation",
                volatileText: "I want to see if it deletes any words",
                isFinalEvent: false
            ),
            "Testing dictation through the app. I want to see if it deletes any words"
        )
    }

    func testLiveDictationAccumulatorAllowsAuthoritativeCorrectionOfCommittedSentence() {
        var accumulator = LiveDictationAccumulator()

        _ = accumulator.update(
            stableText: "Testing dictation",
            volatileText: "through the app.",
            isFinalEvent: false
        )
        _ = accumulator.update(
            stableText: "Testing dictation",
            volatileText: "I want to see if it deletes any words",
            isFinalEvent: false
        )

        XCTAssertEqual(
            accumulator.update(
                stableText: "Testing dictation through the application.",
                volatileText: "I want to see if it deletes any words",
                isFinalEvent: false
            ),
            "Testing dictation through the application. I want to see if it deletes any words"
        )
    }

    func testLiveDictationAccumulatorAppendsSegmentScopedStableUpdates() {
        var accumulator = LiveDictationAccumulator()

        XCTAssertEqual(
            accumulator.update(
                stableText: "Testing dictation through the app.",
                volatileText: "",
                isFinalEvent: true
            ),
            "Testing dictation through the app."
        )

        XCTAssertEqual(
            accumulator.update(
                stableText: "I want to see if it deletes",
                volatileText: "any words",
                isFinalEvent: false
            ),
            "Testing dictation through the app. I want to see if it deletes any words"
        )
    }

    func testLiveDictationAccumulatorKeepsUnpunctuatedPhraseActiveAcrossPause() {
        var accumulator = LiveDictationAccumulator()

        XCTAssertEqual(
            accumulator.update(
                stableText: "I think we should go",
                volatileText: "to the store",
                isFinalEvent: false
            ),
            "I think we should go to the store"
        )

        XCTAssertEqual(
            accumulator.update(
                stableText: "I think we should go to the store",
                volatileText: "",
                isFinalEvent: true
            ),
            "I think we should go to the store"
        )

        XCTAssertEqual(
            accumulator.update(
                stableText: "I think we should go to the store and",
                volatileText: "buy milk",
                isFinalEvent: false
            ),
            "I think we should go to the store and buy milk"
        )
    }

    func testLiveDictationAccumulatorCanReviseUnfinishedClauseAfterPause() {
        var accumulator = LiveDictationAccumulator()

        _ = accumulator.update(
            stableText: "I think we should go to the store",
            volatileText: "",
            isFinalEvent: true
        )

        XCTAssertEqual(
            accumulator.update(
                stableText: "I think we should go to the stores",
                volatileText: "nearby",
                isFinalEvent: false
            ),
            "I think we should go to the stores nearby"
        )
    }

    func testLiveDictationAccumulatorRenderedTextSuppressesStaleDuplicateTail() {
        var accumulator = LiveDictationAccumulator()

        _ = accumulator.update(
            stableText: "hello world.",
            volatileText: "hello world.",
            isFinalEvent: false
        )

        XCTAssertEqual(accumulator.renderedText, "hello world.")
    }

    func testLiveDictationAccumulatorFinalTranscriptReplacesBrokenIntermediateHypothesis() {
        var accumulator = LiveDictationAccumulator()

        _ = accumulator.update(
            stableText: "Testing dictation You want to see",
            volatileText: "if it deletes any word",
            isFinalEvent: false
        )

        XCTAssertEqual(
            accumulator.finalizeSession(
                with: "Testing dictation through the application. I want to see if it deletes any words."
            ),
            "Testing dictation through the application. I want to see if it deletes any words."
        )
    }

    func testLiveDictationAccumulatorDoesNotDuplicateWhenStableCatchesUpToPriorVolatileText() {
        var accumulator = LiveDictationAccumulator()

        XCTAssertEqual(
            accumulator.update(
                stableText: "",
                volatileText: "I validated the cold pack.",
                isFinalEvent: false
            ),
            "I validated the cold pack."
        )

        XCTAssertEqual(
            accumulator.update(
                stableText: "I validated the cold pack.",
                volatileText: "Stuff is getting written",
                isFinalEvent: false
            ),
            "I validated the cold pack. Stuff is getting written"
        )
    }

    func testLiveDictationAccumulatorReplacesCorrectedStablePrefixInsteadOfAppendingIt() {
        var accumulator = LiveDictationAccumulator()

        _ = accumulator.update(
            stableText: "I validated the cold pack.",
            volatileText: "Stuff is getting written",
            isFinalEvent: false
        )

        XCTAssertEqual(
            accumulator.update(
                stableText: "I validated the cold path.",
                volatileText: "Stuff is getting written twice again",
                isFinalEvent: false
            ),
            "I validated the cold path. Stuff is getting written twice again"
        )
    }

    func testPostProcessorNormalizesWhitespaceAndPunctuation() {
        let processor = PostProcessor()
        let output = processor.normalize("   hello    world   ")
        XCTAssertEqual(output, "Hello world.")
    }

    func testPostProcessorKeepsExistingQuestionMark() {
        let processor = PostProcessor()
        let output = processor.normalize("what time is it?")
        XCTAssertEqual(output, "What time is it?")
    }

    func testPostProcessorMapsSpokenPunctuation() {
        let processor = PostProcessor()
        let output = processor.normalize("hello comma world question mark")
        XCTAssertEqual(output, "Hello, world?")
    }

    func testPostProcessorSupportsParagraphCommands() {
        let processor = PostProcessor()
        let output = processor.normalize("first line new paragraph second line")
        XCTAssertEqual(output, "First line.\n\nSecond line.")
    }

    func testPostProcessorCollapsesDuplicateCommas() {
        let processor = PostProcessor()
        let output = processor.normalize("hello, comma world")
        XCTAssertEqual(output, "Hello, world.")
    }

    func testPostProcessorLiveNormalizationDoesNotForceSentencePunctuation() {
        let processor = PostProcessor()
        let output = processor.normalizeLive("hello comma world")
        XCTAssertEqual(output, "hello, world")
    }

    func testPostProcessorContextAwareNormalizationKeepsMidSentenceLowercase() {
        let processor = PostProcessor()
        let output = processor.normalize(
            "Hello world",
            context: LiveCompositionContext(prefixText: "We said ", suffixText: "")
        )
        XCTAssertEqual(output, "hello world.")
    }

    func testPostProcessorContextAwareNormalizationSkipsTerminalPeriodWhenSuffixContinues() {
        let processor = PostProcessor()
        let output = processor.normalize(
            "hello world",
            context: LiveCompositionContext(prefixText: "", suffixText: " and more text")
        )
        XCTAssertEqual(output, "hello world")
    }
}
