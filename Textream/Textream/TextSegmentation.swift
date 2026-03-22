//
//  TextSegmentation.swift
//  Textream
//
//  Created by OpenAI Codex on 21.03.2026.
//

import Foundation

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

/// Splits text into display-ready words. CJK characters (Chinese, Japanese, Korean)
/// are split into individual characters so the flow layout can wrap them properly.
func splitTextIntoWords(_ text: String) -> [String] {
    let tokens = text.replacingOccurrences(of: "\n", with: " ")
        .split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        .map { String($0) }

    var result: [String] = []
    for token in tokens {
        guard token.unicodeScalars.contains(where: { $0.isCJK }) else {
            result.append(token)
            continue
        }

        var buffer = ""
        for char in token {
            if char.unicodeScalars.first.map({ $0.isCJK }) == true {
                if !buffer.isEmpty {
                    result.append(buffer)
                    buffer = ""
                }
                result.append(String(char))
            } else {
                buffer.append(char)
            }
        }

        if !buffer.isEmpty {
            result.append(buffer)
        }
    }

    return result
}

func isBracketCueWord(_ word: String) -> Bool {
    word.hasPrefix("[") && word.hasSuffix("]") && word.count > 2
}

/// Token used by speech matching and cue progression.
func normalizedTrackingToken(_ word: String) -> String {
    word.lowercased().filter { $0.isLetter || $0.isNumber }
}

/// Spoken tracking should ignore stage directions like `[wave]`, while still
/// rendering them distinctly in the teleprompter.
func wordParticipatesInTracking(_ word: String) -> Bool {
    !isBracketCueWord(word) && !normalizedTrackingToken(word).isEmpty
}

func isStyledAnnotationWord(_ word: String) -> Bool {
    if isBracketCueWord(word) { return true }
    return !wordParticipatesInTracking(word)
}

func shouldAutoSkipForTracking(_ word: String) -> Bool {
    !wordParticipatesInTracking(word)
}
