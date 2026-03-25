import Foundation

struct TranscriptStabilizer {
    struct Snapshot: Equatable {
        let stableText: String
        let volatileText: String
        let displayText: String
        let revisionCount: Int
        let stablePromotions: Int
        let maxVolatileWordCount: Int
        let stableWordCount: Int
        let volatileWordCount: Int
    }

    private let minimumStableObservations = 2
    private let minimumVolatileTailWords = 3

    private var previousWords: [String] = []
    private var previousStability: [Int] = []
    private var revisionCount = 0
    private var stablePromotions = 0
    private var maxVolatileWordCount = 0
    private var lastDisplayText = ""

    mutating func update(with hypothesis: String) -> Snapshot {
        let words = Self.words(from: hypothesis)
        let stability = mergedStability(for: words)
        let stablePrefixCount = computedStablePrefixCount(words: words, stability: stability)
        let stableWords = Array(words.prefix(stablePrefixCount))
        let volatileWords = Array(words.dropFirst(stablePrefixCount))
        let displayText = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        if displayText != lastDisplayText {
            revisionCount += 1
            lastDisplayText = displayText
        }

        let promotionsThisUpdate = max(0, stablePrefixCount - stableWordCount(from: previousWords, stability: previousStability))
        stablePromotions += promotionsThisUpdate
        maxVolatileWordCount = max(maxVolatileWordCount, volatileWords.count)

        previousWords = words
        previousStability = stability

        return Snapshot(
            stableText: stableWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            volatileText: volatileWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            displayText: displayText,
            revisionCount: revisionCount,
            stablePromotions: stablePromotions,
            maxVolatileWordCount: maxVolatileWordCount,
            stableWordCount: stableWords.count,
            volatileWordCount: volatileWords.count
        )
    }

    mutating func commit(_ hypothesis: String) -> Snapshot {
        let words = Self.words(from: hypothesis)
        let stableText = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        if stableText != lastDisplayText {
            revisionCount += 1
            lastDisplayText = stableText
        }

        let committedWordCount = words.count
        let previousStable = stableWordCount(from: previousWords, stability: previousStability)
        stablePromotions += max(0, committedWordCount - previousStable)
        previousWords = words
        previousStability = Array(repeating: minimumStableObservations, count: words.count)

        return Snapshot(
            stableText: stableText,
            volatileText: "",
            displayText: stableText,
            revisionCount: revisionCount,
            stablePromotions: stablePromotions,
            maxVolatileWordCount: maxVolatileWordCount,
            stableWordCount: words.count,
            volatileWordCount: 0
        )
    }

    private func mergedStability(for words: [String]) -> [Int] {
        guard !words.isEmpty else { return [] }

        var stability = Array(repeating: 1, count: words.count)
        let commonPrefixCount = zip(previousWords, words).prefix { $0 == $1 }.count
        if commonPrefixCount > 0 {
            for index in 0..<commonPrefixCount {
                stability[index] = min(previousStability[safe: index] ?? 1, minimumStableObservations) + 1
            }
        }
        return stability
    }

    private func computedStablePrefixCount(words: [String], stability: [Int]) -> Int {
        guard !words.isEmpty else { return 0 }

        let candidate = stableWordCount(from: words, stability: stability)
        let tailReserve = max(0, words.count - minimumVolatileTailWords)
        return min(candidate, tailReserve)
    }

    private func stableWordCount(from words: [String], stability: [Int]) -> Int {
        var count = 0
        for index in 0..<min(words.count, stability.count) {
            if stability[index] >= minimumStableObservations {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    private static func words(from text: String) -> [String] {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
