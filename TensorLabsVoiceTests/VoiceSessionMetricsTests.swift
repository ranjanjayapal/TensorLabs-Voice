import XCTest
@testable import TensorLabsVoice

final class VoiceSessionMetricsTests: XCTestCase {
    func testMetadataIncludesMilestonesInMilliseconds() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var metrics = VoiceSessionMetrics(startedAt: start)

        metrics.markFirstPartial(at: start.addingTimeInterval(0.12))
        metrics.markTranscriptionFinished(at: start.addingTimeInterval(0.75))
        metrics.markPostProcessingFinished(at: start.addingTimeInterval(0.83))
        metrics.markInsertionFinished(at: start.addingTimeInterval(0.91))

        let payload = metrics.metadata(endedAt: start.addingTimeInterval(1.0))

        XCTAssertEqual(payload["elapsed_ms"], "910")
        XCTAssertEqual(payload["first_partial_ms"], "120")
        XCTAssertEqual(payload["transcription_ms"], "750")
        XCTAssertEqual(payload["post_processing_ms"], "830")
        XCTAssertEqual(payload["insertion_ms"], "910")
    }

    func testInterruptedSessionSetsInterruptedFlag() {
        let start = Date(timeIntervalSinceReferenceDate: 200)
        var metrics = VoiceSessionMetrics(startedAt: start)

        metrics.markSpeechStarted(at: start.addingTimeInterval(0.4))
        metrics.markInterrupted(at: start.addingTimeInterval(0.65))

        let payload = metrics.metadata(endedAt: start.addingTimeInterval(0.8))

        XCTAssertEqual(payload["elapsed_ms"], "650")
        XCTAssertEqual(payload["speech_started_ms"], "400")
        XCTAssertEqual(payload["interrupted"], "true")
    }

    func testPermissionStatusCanSkipAccessibilityRequirement() {
        let status = PermissionStatus(
            microphoneGranted: true,
            speechGranted: false,
            accessibilityGranted: false
        )

        XCTAssertTrue(status.satisfiesRequirements(requiresSpeechRecognition: false, requiresAccessibility: false))
        XCTAssertFalse(status.satisfiesRequirements(requiresSpeechRecognition: true, requiresAccessibility: false))
        XCTAssertFalse(status.satisfiesRequirements(requiresSpeechRecognition: false, requiresAccessibility: true))
    }
}
