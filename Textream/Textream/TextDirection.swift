import Foundation

enum TextBaseDirection: Equatable {
    case leftToRight
    case rightToLeft
    case natural
}

/// Infers the base direction from the first strong alphabetic character,
/// ignoring bracketed teleprompter cues such as `[pause]`.
func textBaseDirection(in text: String) -> TextBaseDirection {
    var isInsideAnnotation = false

    for scalar in text.unicodeScalars {
        if scalar == "[" {
            isInsideAnnotation = true
            continue
        }
        if scalar == "]", isInsideAnnotation {
            isInsideAnnotation = false
            continue
        }
        guard !isInsideAnnotation, scalar.properties.isAlphabetic else { continue }
        return isRightToLeftScript(scalar) ? .rightToLeft : .leftToRight
    }

    return .natural
}

/// Infers the base direction from whichever script dominates the text, ignoring
/// bracketed teleprompter cues such as `[pause]`.
///
/// First-strong detection is the Unicode default, but it misreads a script that
/// happens to open with a Latin product name, quote, or speaker label — a single
/// leading "Textream" would lay an entire Hebrew script out left-to-right. Scripts
/// are read whole, so the dominant script is the better signal for a whole page.
func dominantBaseDirection(in text: String) -> TextBaseDirection {
    var rightToLeftCount = 0
    var leftToRightCount = 0
    var isInsideAnnotation = false

    for scalar in text.unicodeScalars {
        if scalar == "[" {
            isInsideAnnotation = true
            continue
        }
        if scalar == "]", isInsideAnnotation {
            isInsideAnnotation = false
            continue
        }
        guard !isInsideAnnotation, scalar.properties.isAlphabetic else { continue }
        if isRightToLeftScript(scalar) {
            rightToLeftCount += 1
        } else {
            leftToRightCount += 1
        }
    }

    if rightToLeftCount == 0 && leftToRightCount == 0 { return .natural }
    return rightToLeftCount > leftToRightCount ? .rightToLeft : .leftToRight
}

// MARK: - Word-level bidi ordering

/// The bidi character type of a display token, reduced to what word-granularity
/// reordering needs.
enum WordDirectionClass {
    case rightToLeft
    case leftToRight
    /// Punctuation, dashes, emoji — takes its direction from its neighbours.
    case neutral
}

/// Classifies a word by its first strong character. Digit-only tokens count as
/// left-to-right because European numbers always resolve to an even (LTR)
/// embedding level, even inside right-to-left text.
func wordDirectionClass(_ word: String) -> WordDirectionClass {
    var sawNumber = false

    for scalar in word.unicodeScalars {
        if scalar.properties.isAlphabetic {
            return isRightToLeftScript(scalar) ? .rightToLeft : .leftToRight
        }
        if !sawNumber, Character(scalar).isNumber {
            sawNumber = true
        }
    }

    return sawNumber ? .leftToRight : .neutral
}

/// One word placed in visual order, carrying the direction of the run it landed in.
struct BidiOrderedWord<Element> {
    let element: Element
    /// True when the word sits in a right-to-left run and should resolve its own
    /// punctuation and bracket mirroring right-to-left.
    let isRightToLeft: Bool
}

/// Reorders one line of words from logical order into visual (left-to-right)
/// order using the Unicode Bidirectional Algorithm's reordering rule (UBA L2),
/// applied at word granularity.
///
/// Laying words out with a flipped `layoutDirection` reverses *every* word on the
/// line, which also reverses embedded left-to-right runs — "Claude Code" inside a
/// Hebrew sentence renders as "Code Claude". Resolving embedding levels and
/// reversing only the runs that need it keeps embedded runs in reading order.
func bidiVisualOrder<Element>(
    _ words: [Element],
    baseIsRightToLeft: Bool,
    classify: (Element) -> WordDirectionClass
) -> [BidiOrderedWord<Element>] {
    guard !words.isEmpty else { return [] }

    let baseLevel = baseIsRightToLeft ? 1 : 0

    // Strong (and numeric) words get their level directly; neutrals stay unresolved.
    var levels: [Int?] = words.map { word in
        switch classify(word) {
        case .rightToLeft: return 1
        case .leftToRight: return baseIsRightToLeft ? 2 : 0
        case .neutral: return nil
        }
    }

    // A run of neutrals between two matching levels joins them; otherwise it
    // falls back to the base level.
    var index = 0
    while index < levels.count {
        guard levels[index] == nil else {
            index += 1
            continue
        }
        var end = index
        while end < levels.count, levels[end] == nil { end += 1 }

        let before = index > 0 ? levels[index - 1] : nil
        let after = end < levels.count ? levels[end] : nil
        let resolved = (before != nil && before == after) ? before! : baseLevel

        for neutral in index..<end { levels[neutral] = resolved }
        index = end
    }

    let resolvedLevels = levels.map { $0 ?? baseLevel }
    var order = Array(words.indices)

    // UBA L2: from the highest level down to the lowest odd level, reverse every
    // contiguous run sitting at or above that level.
    if let lowestOddLevel = resolvedLevels.filter({ $0 % 2 == 1 }).min() {
        let highestLevel = resolvedLevels.max() ?? baseLevel
        var level = highestLevel
        while level >= lowestOddLevel {
            var start = 0
            while start < order.count {
                guard resolvedLevels[order[start]] >= level else {
                    start += 1
                    continue
                }
                var end = start
                while end < order.count, resolvedLevels[order[end]] >= level { end += 1 }
                order[start..<end].reverse()
                start = end
            }
            level -= 1
        }
    }

    return order.map {
        BidiOrderedWord(element: words[$0], isRightToLeft: resolvedLevels[$0] % 2 == 1)
    }
}

/// Wraps a word in a Unicode directional isolate so its own punctuation, digits
/// and bracket mirroring resolve against the run it belongs to rather than
/// against the surrounding layout direction.
func directionIsolated(_ word: String, isRightToLeft: Bool) -> String {
    let isolate = isRightToLeft ? "\u{2067}" : "\u{2066}" // RLI / LRI
    return isolate + word + "\u{2069}" // PDI
}

private func isRightToLeftScript(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0590...0x05FF,   // Hebrew
         0x0600...0x06FF,   // Arabic
         0x0700...0x074F,   // Syriac
         0x0750...0x077F,   // Arabic Supplement
         0x0780...0x07BF,   // Thaana
         0x07C0...0x07FF,   // NKo
         0x0800...0x083F,   // Samaritan
         0x0840...0x085F,   // Mandaic
         0x0870...0x089F,   // Arabic Extended-B
         0x08A0...0x08FF,   // Arabic Extended-A
         0xFB50...0xFDFF,   // Arabic Presentation Forms-A
         0xFE70...0xFEFF,   // Arabic Presentation Forms-B
         0x1E800...0x1E8DF, // Mende Kikakui
         0x1E900...0x1E95F, // Adlam
         0x1EE00...0x1EEFF: // Arabic Mathematical Alphabetic Symbols
        return true
    default:
        return false
    }
}
