import Foundation

struct TranscriptComposer {
    private var finalizedSegments: [String] = []
    private var currentSegmentPartial: String?
    private var fullTranscriptHypothesis: String?

    mutating func apply(_ event: ASREvent) {
        switch event {
        case let .partial(text, scope):
            applyPartial(text, scope: scope)
        case let .final(text, scope):
            applyFinal(text, scope: scope)
        }
    }

    var renderedText: String {
        if let fullTranscript = normalized(fullTranscriptHypothesis), !fullTranscript.isEmpty {
            return fullTranscript
        }

        let parts = finalizedSegments + [normalized(currentSegmentPartial)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var finalTranscript: String {
        renderedText
    }

    private mutating func applyPartial(_ text: String, scope: ASRTextScope) {
        switch scope {
        case .currentSegment:
            currentSegmentPartial = normalized(text)
            fullTranscriptHypothesis = nil
        case .fullTranscript:
            fullTranscriptHypothesis = normalized(text)
            currentSegmentPartial = nil
        }
    }

    private mutating func applyFinal(_ text: String, scope: ASRTextScope) {
        let trimmed = normalized(text)

        switch scope {
        case .currentSegment:
            if let trimmed, !trimmed.isEmpty {
                finalizedSegments.append(trimmed)
            }
            currentSegmentPartial = nil
            fullTranscriptHypothesis = nil
        case .fullTranscript:
            // Some streaming engines briefly emit an empty final before a corrected
            // full-transcript replacement arrives. Preserve the current composition
            // instead of wiping the dictated text in that gap.
            guard let trimmed, !trimmed.isEmpty else {
                currentSegmentPartial = nil
                return
            }
            fullTranscriptHypothesis = trimmed
            currentSegmentPartial = nil
            finalizedSegments = [trimmed]
        }
    }

    private func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
