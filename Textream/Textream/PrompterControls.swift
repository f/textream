//
//  PrompterControls.swift
//  Textream
//
//  Live controls while the prompter is running: keyboard navigation
//  (sentence and word steps) and on-the-fly text size and margin changes.
//

import AppKit
import SwiftUI

enum PrompterStep: Equatable {
    case sentence(Int)
    case word(Int)
}

/// Shared state the key monitor writes and the prompter views read.
@Observable
class PrompterControls {
    static let shared = PrompterControls()

    /// Bumped on every navigation request so views can react with onChange.
    private(set) var stepID = 0
    private(set) var lastStep: PrompterStep = .word(0)

    /// Short label shown on the fullscreen prompter after a live adjustment.
    private(set) var hudText: String?
    private var hudGeneration = 0

    func requestStep(_ step: PrompterStep) {
        lastStep = step
        stepID &+= 1
    }

    func flashHUD(_ text: String) {
        hudText = text
        hudGeneration &+= 1
        let generation = hudGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, generation == self.hudGeneration else { return }
            self.hudText = nil
        }
    }

    // MARK: - Live adjustments

    /// True when the text size and margin keys should act on the fullscreen view.
    private var adjustsFullscreen: Bool {
        let settings = NotchSettings.shared
        return settings.overlayMode == .fullscreen || settings.externalDisplayMode != .off
    }

    func changeTextSize(by direction: Int) {
        let settings = NotchSettings.shared
        if adjustsFullscreen {
            let range = NotchSettings.fullscreenTextScaleRange
            let next = (settings.fullscreenTextScale + 0.05 * Double(direction)) * 100
            settings.fullscreenTextScale = min(range.upperBound, max(range.lowerBound, next.rounded() / 100))
            flashHUD("Text size \(Int((settings.fullscreenTextScale * 100).rounded()))%")
        } else {
            let presets = FontSizePreset.allCases
            guard let index = presets.firstIndex(of: settings.fontSizePreset) else { return }
            let next = min(presets.count - 1, max(0, index + direction))
            settings.fontSizePreset = presets[next]
        }
    }

    func changeSideMargin(by direction: Int) {
        guard adjustsFullscreen else { return }
        let settings = NotchSettings.shared
        let range = NotchSettings.fullscreenSideMarginRange
        let next = (settings.fullscreenSideMargin + 0.02 * Double(direction)) * 100
        settings.fullscreenSideMargin = min(range.upperBound, max(range.lowerBound, next.rounded() / 100))
        flashHUD("Margins \(Int((settings.fullscreenSideMargin * 100).rounded()))% each side")
    }
}

// MARK: - Sentence and word navigation

enum PrompterNavigation {
    private static let closingCharacters: Set<Character> = ["\"", "'", ")", "]", "}", "\u{201D}", "\u{2019}", "\u{00BB}"]
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "\u{2026}"]

    static func endsSentence(_ word: String) -> Bool {
        var trimmed = Substring(word)
        while let last = trimmed.last, closingCharacters.contains(last) {
            trimmed = trimmed.dropLast()
        }
        guard let last = trimmed.last else { return false }
        return sentenceEnders.contains(last)
    }

    /// Word indices where a sentence starts. Always includes 0.
    static func sentenceStarts(in words: [String]) -> [Int] {
        guard !words.isEmpty else { return [0] }
        var starts = [0]
        for index in 1..<words.count where endsSentence(words[index - 1]) {
            starts.append(index)
        }
        return starts
    }

    /// The word index to move to from `currentWord` (the next word to read).
    static func targetWordIndex(words: [String], currentWord: Int, step: PrompterStep) -> Int {
        let current = max(0, min(currentWord, words.count))
        switch step {
        case .word(let delta):
            return max(0, min(words.count, current + delta))
        case .sentence(let delta) where delta < 0:
            let starts = sentenceStarts(in: words)
            var target = starts.last(where: { $0 <= current }) ?? 0
            // Already at the start of this sentence: step into the one before.
            if current - target <= 1 {
                target = starts.last(where: { $0 < target }) ?? 0
            }
            for _ in 1..<max(1, -delta) {
                target = starts.last(where: { $0 < target }) ?? 0
            }
            return target
        case .sentence(let delta):
            let starts = sentenceStarts(in: words)
            var target = current
            for _ in 0..<max(1, delta) {
                target = starts.first(where: { $0 > target }) ?? words.count
            }
            return target
        }
    }

    /// Index of the next word to read, given how many characters are done.
    static func wordIndex(forCharCount charCount: Int, in words: [String]) -> Int {
        var offset = 0
        for (index, word) in words.enumerated() {
            if offset + word.count > charCount { return index }
            offset += word.count + 1
        }
        return words.count
    }

    /// Character offset where a word starts (words joined by single spaces).
    static func charOffset(forWordIndex index: Int, in words: [String]) -> Int {
        var offset = 0
        for word in words.prefix(max(0, index)) {
            offset += word.count + 1
        }
        return offset
    }
}

// MARK: - HUD

struct PrompterHUDView: View {
    var body: some View {
        if let text = PrompterControls.shared.hudText {
            Text(text)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.white.opacity(0.15))
                .clipShape(Capsule())
                .padding(.top, 20)
                .transition(.opacity)
        }
    }
}
