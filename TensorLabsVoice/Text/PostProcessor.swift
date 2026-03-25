import Foundation

struct PostProcessor {
    struct Options {
        var customWordReplacements: [String: String] = [:]
        var enableSmartListFormatting = true
        var applyEnglishCasingAndPunctuation = true
        var enableSpokenPunctuation = true

        static let `default` = Options()
    }

    func normalize(_ text: String, options: Options = .default) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if isBlankAudioArtifact(trimmed) { return "" }

        let deartifacted = removeTranscriptionArtifacts(trimmed)
        guard !deartifacted.isEmpty else { return "" }

        let replacedWords = applyCustomWordReplacements(deartifacted, replacements: options.customWordReplacements)
        let punctuatedWords = options.enableSpokenPunctuation ? applySpokenPunctuation(replacedWords) : replacedWords
        let collapsedWhitespace = normalizeWhitespace(punctuatedWords)
        if options.enableSmartListFormatting, let numberedList = convertSpokenNumberedList(collapsedWhitespace) {
            return numberedList
        }

        if !options.applyEnglishCasingAndPunctuation {
            return collapsedWhitespace
        }

        let paragraphAware = ensureParagraphBreakPunctuation(collapsedWhitespace)
        let sentence = ensureSentencePunctuation(paragraphAware)
        return capitalizeSentences(sentence)
    }

    func normalizeLive(_ text: String, options: Options = .default) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if isBlankAudioArtifact(trimmed) { return "" }

        let deartifacted = removeTranscriptionArtifacts(trimmed)
        guard !deartifacted.isEmpty else { return "" }

        let replacedWords = applyCustomWordReplacements(deartifacted, replacements: options.customWordReplacements)
        let punctuatedWords = options.enableSpokenPunctuation ? applySpokenPunctuation(replacedWords) : replacedWords
        return normalizeWhitespace(punctuatedWords)
    }

    func normalize(_ text: String, options: Options = .default, context: LiveCompositionContext) -> String {
        let liveNormalized = normalizeLive(text, options: options)
        guard !liveNormalized.isEmpty else { return "" }
        let analysis = CompositionContextAnalyzer().analyze(context: context, dictatedText: liveNormalized)

        if options.enableSmartListFormatting, let numberedList = convertSpokenNumberedList(liveNormalized) {
            return numberedList
        }

        if !options.applyEnglishCasingAndPunctuation {
            return liveNormalized
        }

        var output = liveNormalized
        if analysis.shouldAppendTerminalPunctuation {
            output = ensureParagraphBreakPunctuation(output)
            output = ensureSentencePunctuation(output)
        }

        if analysis.shouldLowercaseLeadingWord {
            return lowercaseLeadingLetter(output)
        }

        return capitalizeSentences(output)
    }

    private func removeTranscriptionArtifacts(_ text: String) -> String {
        var output = text
        let artifacts = ["[BLANK_AUDIO]", "<|nospeech|>", "<|nocaptions|>"]
        for artifact in artifacts {
            output = output.replacingOccurrences(of: artifact, with: "", options: [.caseInsensitive])
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isBlankAudioArtifact(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered == "[blank_audio]" || lowered == "blank audio" || lowered == "<|nospeech|>"
    }

    private func applyCustomWordReplacements(_ text: String, replacements: [String: String]) -> String {
        guard !replacements.isEmpty else { return text }

        var output = text
        let sortedPairs = replacements
            .map { ($0.key.trimmingCharacters(in: .whitespacesAndNewlines), $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.0.isEmpty && !$0.1.isEmpty }
            .sorted { $0.0.count > $1.0.count }

        for (spoken, written) in sortedPairs {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: spoken) + "\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(output.startIndex..<output.endIndex, in: output)
                output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: written)
            }
        }

        return output
    }

    private func convertSpokenNumberedList(_ text: String) -> String? {
        let numberWords: [String: Int] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        ]

        // Treat list markers only when they appear at likely item boundaries,
        // not in normal prose like "I have two requests".
        let pattern = #"(?i)(?:^|[.!?]\s+|\n+|;\s*|,\s*|\band\s+|\bthen\s+)(one|two|three|four|five|six|seven|eight|nine|ten|[1-9]|10)\b[\s,:-]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard matches.count >= 2 else { return nil }

        var extracted: [(index: Int, content: String)] = []
        for (i, match) in matches.enumerated() {
            guard
                let markerRange = Range(match.range(at: 1), in: text),
                let markerValue = markerValue(from: String(text[markerRange]), numberWords: numberWords)
            else { continue }

            let start = match.range.location + match.range.length
            let end = i + 1 < matches.count ? matches[i + 1].range.location : range.location + range.length
            guard start < end else { continue }

            guard let contentRange = Range(NSRange(location: start, length: end - start), in: text) else { continue }
            let content = text[contentRange]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-"))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

            guard !content.isEmpty else { continue }
            extracted.append((index: markerValue, content: content))
        }

        guard extracted.count >= 2 else { return nil }

        let expected = Array(1...(extracted.count))
        let actual = extracted.map(\.index)
        guard actual == expected else { return nil }

        let lines = extracted.map { item in
            let normalized = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = normalized.hasSuffix(".") ? String(normalized.dropLast()) : normalized
            return "\(item.index). \(capitalizeFirstLetter(content))"
        }
        let listBody = lines.joined(separator: "\n")

        if let first = matches.first {
            let introRange = NSRange(location: 0, length: first.range.location)
            if
                introRange.length > 0,
                let introTextRange = Range(introRange, in: text)
            {
                let introRaw = String(text[introTextRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !introRaw.isEmpty {
                    let intro = capitalizeFirstLetter(ensureSentencePunctuation(introRaw))
                    return "\(intro)\n\(listBody)"
                }
            }
        }

        return listBody
    }

    private func applySpokenPunctuation(_ text: String) -> String {
        let mappings: [(String, String)] = [
            ("new paragraph", "\n\n"),
            ("new line", "\n"),
            ("question mark", "?"),
            ("exclamation mark", "!"),
            ("full stop", "."),
            ("semicolon", ";"),
            ("colon", ":"),
            ("ellipsis", "..."),
            ("open parenthesis", "("),
            ("close parenthesis", ")"),
            ("open bracket", "["),
            ("close bracket", "]"),
            ("open quote", "\""),
            ("close quote", "\""),
            ("comma", ","),
            ("period", "."),
            ("dash", " - "),
            ("hyphen", "-"),
        ]

        var output = text
        for (spoken, symbol) in mappings.sorted(by: { $0.0.count > $1.0.count }) {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: spoken) + "\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(output.startIndex..<output.endIndex, in: output)
                output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: symbol)
            }
        }
        return cleanupPunctuationSpacing(output)
    }

    private func normalizeWhitespace(_ text: String) -> String {
        let normalizedNewlines = text
            .replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)

        let normalizedLines = normalizedNewlines
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }

        return normalizedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanupPunctuationSpacing(_ text: String) -> String {
        var output = text
        let rules: [(String, String)] = [
            (#"\s+([,.;:!?])"#, "$1"),
            (#"([(\[\"])\s+"#, "$1"),
            (#"\s+([)\]\"])"#, "$1"),
            (#"([,.;:!?])(?=[^\s)\]}\"'\n])"#, "$1 "),
            (#"\s*-\s*"#, " - "),
            (#"(,\s*){2,}"#, ", "),
            (#"([!?;:])(?:\s*\1)+"#, "$1"),
            (#"\.(?:\s*\.){3,}"#, "..."),
        ]

        for (pattern, replacement) in rules {
            output = output.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        return output
    }

    private func markerValue(from raw: String, numberWords: [String: Int]) -> Int? {
        let lowered = raw.lowercased()
        if let value = numberWords[lowered] {
            return value
        }
        if let value = Int(lowered), (1...10).contains(value) {
            return value
        }
        return nil
    }

    private func ensureSentencePunctuation(_ text: String) -> String {
        guard let last = text.last else { return text }
        if [".", "!", "?"].contains(last) {
            return text
        }
        return text + "."
    }

    private func ensureParagraphBreakPunctuation(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"([^\s.!?])\n\n"#,
            with: "$1.\n\n",
            options: .regularExpression
        )
    }

    private func capitalizeSentences(_ text: String) -> String {
        var output = ""
        var shouldCapitalize = true

        for character in text {
            if shouldCapitalize, character.isLetter {
                output.append(contentsOf: String(character).uppercased())
                shouldCapitalize = false
            } else {
                output.append(character)
            }

            if [".", "!", "?", "\n"].contains(character) {
                shouldCapitalize = true
            } else if !character.isWhitespace {
                shouldCapitalize = false
            }
        }

        return output.replacingOccurrences(of: #"\bi\b"#, with: "I", options: .regularExpression)
    }

    private func capitalizeFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func lowercaseLeadingLetter(_ text: String) -> String {
        guard let firstLetterIndex = text.firstIndex(where: \.isLetter) else { return text }
        let prefix = text[..<firstLetterIndex]
        let lowered = String(text[firstLetterIndex]).lowercased()
        let suffix = text[text.index(after: firstLetterIndex)...]
        return String(prefix) + lowered + suffix
    }
}
