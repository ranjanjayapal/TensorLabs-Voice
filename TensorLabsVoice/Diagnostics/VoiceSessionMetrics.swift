import Foundation

struct VoiceSessionMetrics {
    let startedAt: Date

    private(set) var firstPartialAt: Date?
    private(set) var transcriptionFinishedAt: Date?
    private(set) var postProcessingFinishedAt: Date?
    private(set) var insertionFinishedAt: Date?
    private(set) var firstVisibleTextAt: Date?
    private(set) var thinkingStartedAt: Date?
    private(set) var replyReadyAt: Date?
    private(set) var speechStartedAt: Date?
    private(set) var speechFinishedAt: Date?
    private(set) var interruptedAt: Date?
    private(set) var transcriptRevisionCount: Int = 0
    private(set) var stableWordPromotions: Int = 0
    private(set) var maxVolatileWordCount: Int = 0

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    mutating func markFirstPartial(at date: Date = Date()) {
        if firstPartialAt == nil {
            firstPartialAt = date
        }
    }

    mutating func markTranscriptionFinished(at date: Date = Date()) {
        transcriptionFinishedAt = date
    }

    mutating func markFirstVisibleText(at date: Date = Date()) {
        if firstVisibleTextAt == nil {
            firstVisibleTextAt = date
        }
    }

    mutating func markPostProcessingFinished(at date: Date = Date()) {
        postProcessingFinishedAt = date
    }

    mutating func markInsertionFinished(at date: Date = Date()) {
        insertionFinishedAt = date
    }

    mutating func markThinkingStarted(at date: Date = Date()) {
        thinkingStartedAt = date
    }

    mutating func markReplyReady(at date: Date = Date()) {
        replyReadyAt = date
    }

    mutating func markSpeechStarted(at date: Date = Date()) {
        speechStartedAt = date
    }

    mutating func markSpeechFinished(at date: Date = Date()) {
        speechFinishedAt = date
    }

    mutating func markInterrupted(at date: Date = Date()) {
        if interruptedAt == nil {
            interruptedAt = date
        }
    }

    mutating func recordTranscriptStabilization(_ snapshot: TranscriptStabilizer.Snapshot) {
        transcriptRevisionCount = max(transcriptRevisionCount, snapshot.revisionCount)
        stableWordPromotions = max(stableWordPromotions, snapshot.stablePromotions)
        maxVolatileWordCount = max(maxVolatileWordCount, snapshot.maxVolatileWordCount)
    }

    func metadata(
        endedAt: Date = Date(),
        additional: [String: String] = [:]
    ) -> [String: String] {
        var payload = additional
        payload["elapsed_ms"] = durationString(from: startedAt, to: terminalDate(defaultingTo: endedAt))

        if let firstPartialAt {
            payload["first_partial_ms"] = durationString(from: startedAt, to: firstPartialAt)
        }

        if let firstVisibleTextAt {
            payload["first_visible_text_ms"] = durationString(from: startedAt, to: firstVisibleTextAt)
        }

        if let transcriptionFinishedAt {
            payload["transcription_ms"] = durationString(from: startedAt, to: transcriptionFinishedAt)
        }

        if let postProcessingFinishedAt {
            payload["post_processing_ms"] = durationString(from: startedAt, to: postProcessingFinishedAt)
        }

        if let insertionFinishedAt {
            payload["insertion_ms"] = durationString(from: startedAt, to: insertionFinishedAt)
        }

        if let thinkingStartedAt {
            payload["thinking_started_ms"] = durationString(from: startedAt, to: thinkingStartedAt)
        }

        if let replyReadyAt {
            payload["reply_ready_ms"] = durationString(from: startedAt, to: replyReadyAt)
        }

        if let speechStartedAt {
            payload["speech_started_ms"] = durationString(from: startedAt, to: speechStartedAt)
        }

        if let speechFinishedAt {
            payload["speech_finished_ms"] = durationString(from: startedAt, to: speechFinishedAt)
        }

        if interruptedAt != nil {
            payload["interrupted"] = "true"
        }

        payload["transcript_revision_count"] = "\(transcriptRevisionCount)"
        payload["stable_word_promotions"] = "\(stableWordPromotions)"
        payload["max_volatile_word_count"] = "\(maxVolatileWordCount)"

        return payload
    }

    private func terminalDate(defaultingTo endedAt: Date) -> Date {
        interruptedAt
            ?? speechFinishedAt
            ?? insertionFinishedAt
            ?? postProcessingFinishedAt
            ?? replyReadyAt
            ?? transcriptionFinishedAt
            ?? endedAt
    }

    private func durationString(from start: Date, to end: Date) -> String {
        String(Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }
}
