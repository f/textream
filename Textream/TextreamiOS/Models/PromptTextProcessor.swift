import Foundation

extension Unicode.Scalar {
    var isPromptCJK: Bool {
        let value = value
        return (value >= 0x4E00 && value <= 0x9FFF)
            || (value >= 0x3400 && value <= 0x4DBF)
            || (value >= 0x20000 && value <= 0x2A6DF)
            || (value >= 0xF900 && value <= 0xFAFF)
            || (value >= 0x3040 && value <= 0x309F)
            || (value >= 0x30A0 && value <= 0x30FF)
            || (value >= 0xAC00 && value <= 0xD7AF)
    }
}

func splitPromptTextIntoWords(_ text: String) -> [String] {
    let tokens = text.replacingOccurrences(of: "\n", with: " ")
        .split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        .map(String.init)

    var result: [String] = []
    for token in tokens {
        guard token.unicodeScalars.contains(where: \.isPromptCJK) else {
            result.append(token)
            continue
        }

        var buffer = ""
        for character in token {
            if character.unicodeScalars.first?.isPromptCJK == true {
                if !buffer.isEmpty {
                    result.append(buffer)
                    buffer = ""
                }
                result.append(String(character))
            } else {
                buffer.append(character)
            }
        }
        if !buffer.isEmpty {
            result.append(buffer)
        }
    }
    return result
}

enum PromptTextDirection: Equatable {
    case leftToRight
    case rightToLeft

    static func inferred(from text: String) -> PromptTextDirection {
        var insideCue = false
        for scalar in text.unicodeScalars {
            if scalar == "[" {
                insideCue = true
                continue
            }
            if scalar == "]" {
                insideCue = false
                continue
            }
            guard !insideCue, CharacterSet.letters.contains(scalar) else { continue }
            return scalar.isStrongRightToLeft ? .rightToLeft : .leftToRight
        }
        return .leftToRight
    }
}

private extension Unicode.Scalar {
    var isStrongRightToLeft: Bool {
        let value = value
        return (value >= 0x0590 && value <= 0x08FF)
            || (value >= 0xFB1D && value <= 0xFDFF)
            || (value >= 0xFE70 && value <= 0xFEFF)
            || (value >= 0x10800 && value <= 0x10FFF)
            || (value >= 0x1E800 && value <= 0x1EEFF)
    }
}

struct PromptWord: Identifiable, Equatable {
    let id: Int
    let text: String
    let characterRange: Range<Int>
    let isAnnotation: Bool
}

struct PromptScript: Equatable {
    let text: String
    let words: [PromptWord]
    let annotationRanges: [Range<Int>]
    let annotationStyleRanges: [Range<Int>]
    let direction: PromptTextDirection

    init(_ rawText: String) {
        let rawWords = splitPromptTextIntoWords(rawText)
        let collapsed = rawWords.joined(separator: " ")
        let flags = SpeechTextAlignment.annotationFlags(for: rawWords)
        var offset = 0
        var builtWords: [PromptWord] = []
        builtWords.reserveCapacity(rawWords.count)

        for (index, word) in rawWords.enumerated() {
            let range = offset..<(offset + word.count)
            let containsReadableCharacter = word.contains { $0.isLetter || $0.isNumber }
            builtWords.append(
                PromptWord(
                    id: index,
                    text: word,
                    characterRange: range,
                    isAnnotation: flags[index] || !containsReadableCharacter
                )
            )
            offset = range.upperBound + 1
        }

        let balancedAnnotationRanges = SpeechTextAlignment.annotationRanges(in: collapsed)
        text = collapsed
        words = builtWords
        annotationRanges = balancedAnnotationRanges
        annotationStyleRanges = Self.makeAnnotationStyleRanges(
            text: collapsed,
            words: builtWords,
            balancedRanges: balancedAnnotationRanges
        )
        direction = PromptTextDirection.inferred(from: collapsed)
    }

    var characterCount: Int { text.count }

    func characterOffset(forWordProgress progress: Double) -> Int {
        guard !words.isEmpty else { return 0 }
        let clamped = max(0, min(progress, Double(words.count)))
        let wholeWord = min(Int(clamped), words.count)
        guard wholeWord < words.count else { return characterCount }
        let fraction = clamped - Double(wholeWord)
        let word = words[wholeWord]
        return min(characterCount, word.characterRange.lowerBound + Int(Double(word.text.count) * fraction))
    }

    func wordProgress(forCharacterOffset offset: Int) -> Double {
        let clamped = max(0, min(offset, characterCount))
        for word in words {
            if clamped <= word.characterRange.upperBound {
                let position = max(0, clamped - word.characterRange.lowerBound)
                return Double(word.id) + Double(position) / Double(max(1, word.text.count))
            }
        }
        return Double(words.count)
    }

    func activeWord(atCharacterOffset offset: Int) -> PromptWord? {
        words.first(where: { offset <= $0.characterRange.upperBound }) ?? words.last
    }

    func nsRange(forCharacterRange range: Range<Int>) -> NSRange {
        let lower = text.index(text.startIndex, offsetBy: max(0, min(range.lowerBound, text.count)))
        let upper = text.index(text.startIndex, offsetBy: max(0, min(range.upperBound, text.count)))
        return NSRange(lower..<upper, in: text)
    }

    func nsRange(upToCharacterOffset offset: Int) -> NSRange {
        nsRange(forCharacterRange: 0..<max(0, min(offset, text.count)))
    }

    /// Exact character spans that use cue styling in the prompter.
    ///
    /// Balanced bracket cues stay whole so their brackets and internal spaces
    /// share one style. Standalone emoji/punctuation retain the macOS prompt's
    /// annotation treatment, without accidentally coloring prose attached to
    /// an embedded cue (for example, `[pause]continue`).
    private static func makeAnnotationStyleRanges(
        text: String,
        words: [PromptWord],
        balancedRanges: [Range<Int>]
    ) -> [Range<Int>] {
        let characters = Array(text)
        var result = balancedRanges

        for word in words {
            var remainingSegments = [word.characterRange]
            for balancedRange in balancedRanges {
                remainingSegments = remainingSegments.flatMap { segment in
                    guard segment.lowerBound < balancedRange.upperBound,
                          balancedRange.lowerBound < segment.upperBound else {
                        return [segment]
                    }

                    var pieces: [Range<Int>] = []
                    if segment.lowerBound < balancedRange.lowerBound {
                        pieces.append(segment.lowerBound..<balancedRange.lowerBound)
                    }
                    if balancedRange.upperBound < segment.upperBound {
                        pieces.append(balancedRange.upperBound..<segment.upperBound)
                    }
                    return pieces
                }
            }

            for segment in remainingSegments where !segment.isEmpty {
                let containsReadableCharacter = characters[segment].contains {
                    $0.isLetter || $0.isNumber
                }
                if !containsReadableCharacter {
                    result.append(segment)
                }
            }
        }

        return result.sorted { lhs, rhs in lhs.lowerBound < rhs.lowerBound }
    }
}
