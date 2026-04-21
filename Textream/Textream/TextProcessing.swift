//
//  TextProcessing.swift
//  Textream
//
//  Created by OpenAI Codex on 20.04.2026.
//

import Foundation

private let annotationBracketPairs: [(open: Character, close: Character)] = [
    ("[", "]"),
    ("【", "】"),
    ("〔", "〕"),
    ("（", "）"),
    ("［", "］"),
]

private let zhHansSpeechFillers = [
    "那个",
    "就是",
    "然后",
    "这个",
    "嗯",
    "呃",
    "额",
    "啊",
    "吧",
    "嘛",
]

extension Unicode.Scalar {
    var isCJK: Bool {
        let v = value
        return (v >= 0x4E00 && v <= 0x9FFF)
            || (v >= 0x3400 && v <= 0x4DBF)
            || (v >= 0x20000 && v <= 0x2A6DF)
            || (v >= 0xF900 && v <= 0xFAFF)
            || (v >= 0x3040 && v <= 0x309F)
            || (v >= 0x30A0 && v <= 0x30FF)
            || (v >= 0xAC00 && v <= 0xD7AF)
    }
}

extension Character {
    var isCJKCharacter: Bool {
        unicodeScalars.allSatisfy(\.isCJK)
    }
}

/// Splits text into display-ready words. CJK characters are split into single
/// display tokens, but bracketed cue blocks such as `【停顿】` stay intact so
/// they can be dimmed and skipped as a single annotation token.
func splitTextIntoWords(_ text: String) -> [String] {
    var result: [String] = []
    var buffer = ""
    var index = text.startIndex

    func flushBuffer() {
        guard !buffer.isEmpty else { return }
        result.append(buffer)
        buffer = ""
    }

    while index < text.endIndex {
        let char = text[index]

        if char.isWhitespace {
            flushBuffer()
            index = text.index(after: index)
            continue
        }

        if let annotation = annotationToken(in: text, startingAt: index) {
            flushBuffer()
            result.append(annotation.token)
            index = annotation.endIndex
            continue
        }

        if char.isCJKCharacter {
            flushBuffer()
            result.append(String(char))
            index = text.index(after: index)
            continue
        }

        buffer.append(char)
        index = text.index(after: index)
    }

    flushBuffer()
    return result
}

func isAnnotationToken(_ word: String) -> Bool {
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    if isBracketedCue(trimmed) {
        return true
    }

    let stripped = trimmed.filter { $0.isLetter || $0.isNumber }
    return stripped.isEmpty
}

func normalizedSpeechText(_ text: String) -> String {
    let folded = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
    return folded.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
}

func leadingSpeechFillerLength(in spoken: String, sourcePrefix: String, localeIdentifier: String) -> Int {
    guard localeIdentifier.hasPrefix("zh") else { return 0 }

    var remaining = spoken
    var remainingSource = sourcePrefix
    var totalLength = 0
    var iterations = 0

    while iterations < 3 {
        iterations += 1
        let trimmed = remaining.drop(while: { $0.isWhitespace })
        totalLength += remaining.distance(from: remaining.startIndex, to: trimmed.startIndex)
        remaining = String(trimmed)

        remainingSource = String(remainingSource.drop(while: { $0.isWhitespace }))

        guard let filler = zhHansSpeechFillers.first(where: {
            remaining.hasPrefix($0) && !remainingSource.hasPrefix($0)
        }) else { break }

        totalLength += filler.count
        remaining.removeFirst(filler.count)
    }

    return totalLength
}

private func annotationToken(in text: String, startingAt start: String.Index) -> (token: String, endIndex: String.Index)? {
    guard let pair = annotationBracketPairs.first(where: { text[start] == $0.open }) else {
        return nil
    }

    var search = text.index(after: start)
    while search < text.endIndex {
        let char = text[search]
        if char == pair.close {
            let token = String(text[start...search])
            return isBracketedCue(token) ? (token, text.index(after: search)) : nil
        }
        if char.isWhitespace {
            return nil
        }
        search = text.index(after: search)
    }

    return nil
}

private func isBracketedCue(_ word: String) -> Bool {
    guard let pair = annotationBracketPairs.first(where: {
        word.first == $0.open && word.last == $0.close
    }) else {
        return false
    }

    let inner = word.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !inner.isEmpty else { return false }

    let scalarCount = inner.unicodeScalars.count
    guard scalarCount <= 24 else { return false }

    let invalidCharacters = CharacterSet(charactersIn: "\n\r。！？!?;；")
    return inner.rangeOfCharacter(from: invalidCharacters) == nil && word.first == pair.open && word.last == pair.close
}
