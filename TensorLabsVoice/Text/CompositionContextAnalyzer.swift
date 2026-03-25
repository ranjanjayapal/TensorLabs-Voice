import Foundation

struct CompositionContextAnalysis: Equatable {
    let shouldLowercaseLeadingWord: Bool
    let shouldAppendTerminalPunctuation: Bool
    let likelyMidSentence: Bool
}

struct CompositionContextAnalyzer {
    private static let continuationOpeners: Set<String> = [
        "and", "or", "but", "because", "so", "then", "which", "that", "who", "when",
        "while", "if", "though", "although", "however", "also", "plus", "with", "without",
        "to", "for", "from", "into", "onto", "of", "in", "on", "at", "by", "as",
    ]

    func analyze(context: LiveCompositionContext, dictatedText: String) -> CompositionContextAnalysis {
        let dictatedWords = words(in: dictatedText)
        let firstDictatedWord = dictatedWords.first?.lowercased() ?? ""
        let prefixTrimmed = context.prefixText.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixTrimmed = context.suffixText.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixEndsMidSentence = prefixTrimmed.last.map { !".!?".contains($0) } ?? false
        let suffixContinuesSentence = context.hasContinuationSuffix
        let dictatedStartsAsContinuation = Self.continuationOpeners.contains(firstDictatedWord)
        let prefixLooksLikeLeadIn = prefixTrimmed.last.map { [",", ";", ":"].contains($0) } ?? false
        let suffixStartsLowercase = suffixTrimmed.first?.isLowercase ?? false

        let likelyMidSentence =
            prefixEndsMidSentence
            || suffixContinuesSentence
            || dictatedStartsAsContinuation
            || prefixLooksLikeLeadIn
            || suffixStartsLowercase

        return CompositionContextAnalysis(
            shouldLowercaseLeadingWord: likelyMidSentence,
            shouldAppendTerminalPunctuation: !suffixContinuesSentence,
            likelyMidSentence: likelyMidSentence
        )
    }

    private func words(in text: String) -> [String] {
        text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}
