import Foundation

struct PostProcessor {
    func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let collapsedWhitespace = trimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let sentence = ensureSentencePunctuation(collapsedWhitespace)
        return capitalizeFirstLetter(sentence)
    }

    private func ensureSentencePunctuation(_ text: String) -> String {
        guard let last = text.last else { return text }
        if [".", "!", "?"].contains(last) {
            return text
        }
        return text + "."
    }

    private func capitalizeFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
