import Foundation

enum SpeechTextAlignment {
    static func annotationFlags(for words: [String]) -> [Bool] {
        var closingAtOrAfter = Array(repeating: false, count: words.count)
        var hasClosing = false
        for index in words.indices.reversed() {
            if words[index].contains("]") {
                hasClosing = true
            }
            closingAtOrAfter[index] = hasClosing
        }

        var flags: [Bool] = []
        var isInsideAnnotation = false
        for (index, word) in words.enumerated() {
            let beginsAnnotation = word.hasPrefix("[") && closingAtOrAfter[index]
            let isAnnotation = isInsideAnnotation || beginsAnnotation
            flags.append(isAnnotation)
            if beginsAnnotation {
                isInsideAnnotation = true
            }
            if isInsideAnnotation && word.contains("]") {
                isInsideAnnotation = false
            }
        }
        return flags
    }

    static func annotationRanges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var openingIndex: Int?

        for (index, character) in text.enumerated() {
            if character == "[" && openingIndex == nil {
                openingIndex = index
            } else if character == "]", let start = openingIndex {
                ranges.append(start..<(index + 1))
                openingIndex = nil
            }
        }

        return ranges
    }

    static func advancePastAnnotations(
        in text: String,
        ranges: [Range<Int>],
        from offset: Int
    ) -> Int {
        let characters = Array(text)
        var current = max(0, min(offset, characters.count))
        var skippedAnnotation = false

        while current < characters.count {
            if let range = ranges.first(where: { $0.contains(current) }) {
                current = range.upperBound
                skippedAnnotation = true
                continue
            }

            var next = current
            while next < characters.count && characters[next].isWhitespace {
                next += 1
            }

            if let range = ranges.first(where: { $0.lowerBound == next }) {
                current = range.upperBound
                skippedAnnotation = true
                continue
            }

            return skippedAnnotation ? next : current
        }

        return current
    }

    /// Combine the character-level and word-level match results into a single
    /// forward offset. When they roughly agree, average them. When they
    /// disagree, prefer the further match: the word-level scan advances
    /// in-order and monotonically, so trusting it lets fast reading catch up
    /// instead of being dragged back by the brittle character scan that
    /// desyncs over long spans. `shouldCommit` still gates single-strategy
    /// (one result is zero) jumps behind confirmation.
    static func bestOffset(
        characterResult: Int,
        wordResult: Int,
        agreementTolerance: Int = 20
    ) -> Int {
        if abs(characterResult - wordResult) <= agreementTolerance {
            return (characterResult + wordResult) / 2
        }
        return max(characterResult, wordResult)
    }

    static func shouldCommit(
        characterResult: Int,
        wordResult: Int,
        current: Int,
        rawCandidate: Int,
        candidate: Int,
        confirmed: Bool
    ) -> Bool {
        // When both the character and word strategies independently found
        // forward progress, trust the (conservative) match even if they land
        // at different offsets. A false positive would require both strategies
        // to hallucinate the same advance, which is unlikely — so this keeps
        // multi-word phrases (e.g. "following your voice") responsive without
        // waiting for a streaming partial to repeat the same position.
        let bothProgressed = min(characterResult, wordResult) > 0
        // A single strategy matching forward is riskier, so it still needs
        // either a small step or confirmation from repeated results.
        let skippedAnnotation = candidate > rawCandidate
        let smallStep = candidate - current <= 15
        return bothProgressed || skippedAnnotation || confirmed || smallStep
    }
}
