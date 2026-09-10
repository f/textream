import Foundation

/// Reacquires a nearby phrase after a misread word or a short omission.
/// It never advances just because sound or an unrelated transcript arrives.
struct SpeechRecoveryMatcher {
    private struct Word {
        let normalized: String
        let endOffset: Int
    }

    private let words: [Word]
    private let locale: Locale

    init(text: String, locale: Locale) {
        self.locale = locale
        let sourceWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let annotations = SpeechTextAlignment.annotationFlags(for: sourceWords)
        var offset = 0
        var indexed: [Word] = []
        for (index, word) in sourceWords.enumerated() {
            offset += word.count
            let normalized = Self.normalize(word, locale: locale)
            if !annotations[index] && !normalized.isEmpty {
                indexed.append(Word(normalized: normalized, endOffset: offset))
            }
            offset += 1 // The recognizer's source text has collapsed whitespace.
        }
        words = indexed
    }

    func recoveredOffset(spoken: String, currentOffset: Int) -> Int? {
        let recent = spoken.split(whereSeparator: \.isWhitespace)
            .suffix(6)
            .map { Self.normalize(String($0), locale: locale) }
            .filter { !$0.isEmpty }
        guard recent.count >= 3,
              let currentWord = words.firstIndex(where: { $0.endOffset > currentOffset }) else {
            return nil
        }

        // Include the already-read phrase when checking ambiguity. Otherwise
        // a repeated/stale transcript could jump to its next occurrence.
        let lowerBound = max(0, currentWord - 6)
        // A short phrase can repair a nearby misread. A larger accumulated lag
        // needs at least five matching words before skipping the unread section.
        for (lookAhead, minimumLength) in [(24, 3), (80, 5)] {
            let upperBound = min(words.count, currentWord + lookAhead)
            guard recent.count >= minimumLength else { continue }
            for length in stride(from: recent.count, through: minimumLength, by: -1) {
                let phrase = Array(recent.suffix(length))
                guard phrase.reduce(0, { $0 + $1.count }) >= 12,
                      upperBound - lowerBound >= length else { continue }

                var matches: [Int] = []
                for start in lowerBound...(upperBound - length) {
                    if phrase.indices.allSatisfy({ words[start + $0].normalized == phrase[$0] }) {
                        matches.append(words[start + length - 1].endOffset)
                    }
                }
                // A longer unique phrase can disambiguate a repeated short phrase.
                if matches.count == 1, let end = matches.first {
                    return end - currentOffset >= 12 ? end : nil
                }
            }
        }
        return nil
    }

    private static func normalize(_ word: String, locale: Locale) -> String {
        word.lowercased(with: locale).folding(options: .diacriticInsensitive, locale: locale)
            .filter { $0.isLetter || $0.isNumber }
    }
}
