import Foundation
import Observation

enum PromptNavigationCommand {
    case beginning
    case backSentence
    case forwardSentence
    case forwardOneScreen
    case backOneScreen
}

extension Notification.Name {
    static let navigatePrompter = Notification.Name("navigatePrompter")
}

enum PromptNavigation {
    /// Uses the complete wrapped layout, including rows outside the viewport.
    static func targetWord(for command: PromptNavigationCommand, currentWord: Int,
                           viewportHeight: CGFloat, wordPositions: [Int: CGFloat], words: [String] = []) -> Int {
        if command == .beginning { return 0 }
        if command == .backSentence || command == .forwardSentence {
            guard !words.isEmpty else { return 0 }
            let current = max(0, min(currentWord, words.count))
            let text = words.joined(separator: " ")
            var offset = 0
            let wordStarts = words.map { word -> Int in
                defer { offset += word.count + 1 }
                return offset
            }
            var sentenceStarts: [Int] = []
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { _, range, _, _ in
                guard let firstCharacter = text[range].firstIndex(where: { !$0.isWhitespace }) else { return }
                let sentenceStart = text.distance(from: text.startIndex, to: firstCharacter)
                guard let startWord = wordStarts.firstIndex(where: { $0 >= sentenceStart }) else { return }
                sentenceStarts.append(startWord)
            }
            if command == .forwardSentence {
                return sentenceStarts.first(where: { $0 > current }) ?? min(current, words.count - 1)
            }
            return sentenceStarts.last(where: { $0 < current }) ?? 0
        }
        guard let currentY = wordPositions[currentWord], viewportHeight > 0 else {
            return currentWord
        }
        if command == .forwardOneScreen {
            let targetY = currentY + viewportHeight
            let following = wordPositions.filter { $0.value >= targetY }
            guard let lineY = following.values.min() ?? wordPositions.values.max() else { return currentWord }
            let firstWord = wordPositions.filter { abs($0.value - lineY) < 0.5 }.keys.min() ?? currentWord
            return max(currentWord, firstWord)
        }
        let targetY = currentY - viewportHeight
        let preceding = wordPositions.filter { $0.value <= targetY }
        guard let lineY = preceding.values.max() else { return 0 }
        return preceding.filter { abs($0.value - lineY) < 0.5 }.keys.min() ?? 0
    }

    static func positionsForTracking(layout: [Int: CGFloat], measured: [Int: CGFloat]) -> [Int: CGFloat] {
        measured.merging(layout, uniquingKeysWith: { _, layout in layout })
    }

    static func centeredOffset(wordY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        viewportHeight * 0.5 - wordY
    }
}

/// All local prompter windows share the same position and pause state.
@Observable final class PrompterPlayback {
    var wordProgress: Double = 0
    var isPaused = false
    var isUserScrolling = false
    var positionRevision = 0

    func seek(to progress: Double) {
        wordProgress = max(0, progress)
        isUserScrolling = false
        positionRevision &+= 1
    }
}
