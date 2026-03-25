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

        XCTAssertEqual(observedEvents, [
            .partial("hello life", scope: .fullTranscript),
            .final("hello life", scope: .fullTranscript),
            .final("hello live", scope: .fullTranscript),
        ])
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
