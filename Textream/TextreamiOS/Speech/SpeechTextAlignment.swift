import Foundation

enum SpeechTextAlignment {
    static func annotationFlags(for words: [String]) -> [Bool] {
        var closingAtOrAfter = Array(repeating: false, count: words.count)
        var hasClosing = false
        for index in words.indices.reversed() {
            if words[index].contains("]") { hasClosing = true }
            closingAtOrAfter[index] = hasClosing
        }

        var flags: [Bool] = []
        var isInsideAnnotation = false
        for (index, word) in words.enumerated() {
            let beginsAnnotation = word.hasPrefix("[") && closingAtOrAfter[index]
            flags.append(isInsideAnnotation || beginsAnnotation)
            if beginsAnnotation { isInsideAnnotation = true }
            if isInsideAnnotation && word.contains("]") { isInsideAnnotation = false }
        }
        return flags
    }

    static func annotationRanges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var openingIndex: Int?
        for (index, character) in text.enumerated() {
            if character == "[", openingIndex == nil {
                openingIndex = index
            } else if character == "]", let start = openingIndex {
                // Speech ranges intentionally include `[]`, matching the
                // macOS follower. Editor visuals use their own nonempty regex.
                ranges.append(start..<(index + 1))
                openingIndex = nil
            }
        }
        return ranges
    }

    static func advancePastAnnotations(in text: String, ranges: [Range<Int>], from offset: Int) -> Int {
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
            while next < characters.count && characters[next].isWhitespace { next += 1 }
            if let range = ranges.first(where: { $0.lowerBound == next }) {
                current = range.upperBound
                skippedAnnotation = true
                continue
            }
            return skippedAnnotation ? next : current
        }
        return current
    }

    static func bestOffset(characterResult: Int, wordResult: Int, agreementTolerance: Int = 20) -> Int {
        abs(characterResult - wordResult) <= agreementTolerance
            ? (characterResult + wordResult) / 2
            : max(characterResult, wordResult)
    }

    static func shouldCommit(
        characterResult: Int,
        wordResult: Int,
        current: Int,
        rawCandidate: Int,
        candidate: Int,
        confirmed: Bool
    ) -> Bool {
        let bothProgressed = min(characterResult, wordResult) > 0
        let skippedAnnotation = candidate > rawCandidate
        let smallStep = candidate - current <= 15
        return bothProgressed || skippedAnnotation || confirmed || smallStep
    }
}
