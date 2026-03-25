import Foundation

struct LiveCompositionContext {
    var prefixText: String = ""
    var suffixText: String = ""

    var isMidSentence: Bool {
        let trimmedPrefix = prefixText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmedPrefix.last {
            return !".!?".contains(last)
        }

        if let next = nextSignificantSuffixCharacter {
            return next.isLetter || next.isNumber || next == "," || next == ";"
        }

        return false
    }

    var hasContinuationSuffix: Bool {
        guard let next = nextSignificantSuffixCharacter else { return false }
        return !".!?".contains(next)
    }

    private var nextSignificantSuffixCharacter: Character? {
        suffixText.first { !$0.isWhitespace }
    }
}

struct LiveTranscriptFormatter {
    private let postProcessor = PostProcessor()
    private let analyzer = CompositionContextAnalyzer()

    func format(
        _ text: String,
        options: PostProcessor.Options = .default,
        context: LiveCompositionContext = LiveCompositionContext()
    ) -> String {
        let normalized = postProcessor.normalizeLive(text, options: options)
        let analysis = analyzer.analyze(context: context, dictatedText: normalized)
        guard analysis.shouldLowercaseLeadingWord else { return normalized }
        guard let first = normalized.first else { return normalized }
        let lowered = String(first).lowercased() + normalized.dropFirst()
        return lowered
    }
}
