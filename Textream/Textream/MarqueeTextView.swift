//
//  MarqueeTextView.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI

private let paragraphDividerExtraSpacing: CGFloat = 4

// MARK: - CJK-aware word splitting

extension Unicode.Scalar {
    var isCJK: Bool {
        let v = value
        return (v >= 0x4E00 && v <= 0x9FFF)    // CJK Unified Ideographs
            || (v >= 0x3400 && v <= 0x4DBF)    // CJK Extension A
            || (v >= 0x20000 && v <= 0x2A6DF)  // CJK Extension B
            || (v >= 0xF900 && v <= 0xFAFF)    // CJK Compatibility Ideographs
            || (v >= 0x3040 && v <= 0x309F)    // Hiragana
            || (v >= 0x30A0 && v <= 0x30FF)    // Katakana
            || (v >= 0xAC00 && v <= 0xD7AF)    // Hangul Syllables
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
        // Token contains CJK characters — split each CJK char individually;
        // consecutive non-CJK chars (e.g. Latin letters, digits) stay grouped.
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

/// Returns the word indices that begin a new paragraph. Consecutive and
/// whitespace-only lines collapse into a single visual separator.
func paragraphBreakWordIndices(in text: String) -> Set<Int> {
    let normalizedLineEndings = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalizedLineEndings.split(
        separator: "\n",
        omittingEmptySubsequences: false
    )

    var result = Set<Int>()
    var wordCount = 0
    var hasContent = false
    var hasPendingBreak = false

    for (index, line) in lines.enumerated() {
        let lineWords = splitTextIntoWords(String(line))
        if !lineWords.isEmpty {
            if hasContent && hasPendingBreak {
                result.insert(wordCount)
            }
            wordCount += lineWords.count
            hasContent = true
            hasPendingBreak = false
        }

        if index < lines.count - 1, hasContent {
            hasPendingBreak = true
        }
    }

    return result
}

// MARK: - Data

struct WordItem: Identifiable {
    let id: Int
    let word: String
    let charOffset: Int // char offset of this word in the full text (counting spaces)
    let isAnnotation: Bool // true for [bracket] words and emoji-only words
}

// MARK: - Preference key to report word Y positions

struct WordYPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Teleprompter

struct SpeechScrollView: View {
    let words: [String]
    let highlightedCharCount: Int
    var font: NSFont = .systemFont(ofSize: 18, weight: .semibold)
    var highlightColor: Color = .white
    var cueColor: Color = .white
    var cueUnreadOpacity: Double = 0.2
    var cueReadOpacity: Double = 0.5
    var onWordTap: ((Int) -> Void)? = nil
    /// Called when user starts/stops manual scrolling in smooth mode.
    /// Bool: true = scrolling started (pause timer), false = scrolling ended (resume timer).
    /// Double: new word progress to resume from (only meaningful when false).
    var onManualScroll: ((Bool, Double) -> Void)? = nil
    var smoothScroll: Bool = false
    /// Continuous word progress (e.g. 3.7 = 70% through 4th word). Drives scroll in smooth mode.
    var smoothWordProgress: Double = 0

    var isListening: Bool = true
    var readingPosition: ReadingPosition = .centered
    var paragraphBreakBeforeWordIndices: Set<Int> = []
    @State private var scrollOffset: CGFloat = 0
    @State private var manualOffset: CGFloat = 0
    @State private var wordYPositions: [Int: CGFloat] = [:]
    @State private var containerHeight: CGFloat = 0
    @State private var isUserScrolling: Bool = false
    @State private var stableTopLineCenter: CGFloat?
    @State private var stableLineAdvance: CGFloat?
    @State private var allowsNextBackwardTrackingUpdate = false
    @State private var hasAppliedTrackingTarget = false

    var body: some View {
        GeometryReader { geo in
            WordFlowLayout(
                words: words,
                highlightedCharCount: highlightedCharCount,
                font: font,
                highlightColor: highlightColor,
                cueColor: cueColor,
                cueUnreadOpacity: cueUnreadOpacity,
                cueReadOpacity: cueReadOpacity,
                highlightWords: !smoothScroll,
                paragraphBreakBeforeWordIndices: paragraphBreakBeforeWordIndices,
                containerWidth: geo.size.width,
                onWordTap: { charOffset in
                    let tappedWordIndex = wordIndex(at: charOffset)
                    manualOffset = 0
                    if charOffset < highlightedCharCount {
                        allowsNextBackwardTrackingUpdate = true
                    }
                    onWordTap?(charOffset)
                    // Reposition from the tapped word itself instead of waiting
                    // for the parent progress update. That update can arrive
                    // after a stale recalculation has consumed the one-time
                    // backward allowance.
                    repositionTracking(toWordIndex: tappedWordIndex)
                },
                scrollOffset: scrollOffset + manualOffset,
                viewportHeight: geo.size.height
            )
            .onPreferenceChange(WordYPreferenceKey.self) { positions in
                let wasEmpty = wordYPositions.isEmpty
                captureStableLineMetrics(from: positions)
                wordYPositions = positions
                // After a page switch, wordYPositions was cleared — recenter once new positions arrive
                if wasEmpty && !positions.isEmpty {
                    recalculateTracking(containerHeight: containerHeight)
                }
            }
            .offset(y: scrollOffset + manualOffset)
            .animation(smoothScroll ? .linear(duration: 0.06) : .easeOut(duration: 0.5), value: scrollOffset)
            .animation(.easeOut(duration: 0.15), value: manualOffset)
            .onChange(of: geo.size.height) { _, newHeight in
                containerHeight = newHeight
                hasAppliedTrackingTarget = false
                if highlightedCharCount == 0 && smoothWordProgress == 0 {
                    scrollOffset = initialScrollOffset(containerHeight: newHeight)
                } else if isListening {
                    recalculateTracking(containerHeight: newHeight)
                }
            }
            .onChange(of: highlightedCharCount) { _, _ in
                if isListening && !smoothScroll {
                    manualOffset = 0
                    recalculateTracking(containerHeight: containerHeight)
                }
            }
            .onChange(of: smoothWordProgress) { _, _ in
                if isListening && smoothScroll {
                    manualOffset = 0
                    recalculateTracking(containerHeight: containerHeight)
                }
            }
            .onChange(of: isListening) { _, listening in
                if listening {
                    manualOffset = 0
                    recalculateTracking(containerHeight: containerHeight)
                }
            }
            .onChange(of: words) { _, _ in
                scrollOffset = initialScrollOffset(containerHeight: containerHeight)
                manualOffset = 0
                wordYPositions = [:]
                stableTopLineCenter = nil
                stableLineAdvance = nil
                allowsNextBackwardTrackingUpdate = false
                hasAppliedTrackingTarget = false
            }
            .onChange(of: readingPosition) { _, _ in
                manualOffset = 0
                stableTopLineCenter = nil
                stableLineAdvance = nil
                allowsNextBackwardTrackingUpdate = false
                hasAppliedTrackingTarget = false
                scrollOffset = initialScrollOffset(containerHeight: containerHeight)
                DispatchQueue.main.async {
                    recalculateTracking(containerHeight: containerHeight)
                }
            }
            .onAppear {
                containerHeight = geo.size.height
                scrollOffset = initialScrollOffset(containerHeight: containerHeight)
            }
            .overlay(
                ScrollWheelView(
                    onScroll: { delta in
                        let canScroll = smoothScroll ? isListening : !isListening
                        guard canScroll else { return }

                        // Pause timer when user starts scrolling in smooth mode
                        if smoothScroll && !isUserScrolling {
                            isUserScrolling = true
                            onManualScroll?(true, 0)
                        }

                        let maxY = wordYPositions.values.max() ?? 0
                        let containerHeight = geo.size.height
                        let maxUp = containerHeight * 0.5
                        let maxDown = max(0, maxY - containerHeight * 0.5)

                        let newOffset = manualOffset + delta
                        let upperBound = maxUp
                        let lowerBound = -maxDown

                        if newOffset > upperBound {
                            let over = newOffset - upperBound
                            manualOffset = upperBound + over * 0.2
                        } else if newOffset < lowerBound {
                            let over = lowerBound - newOffset
                            manualOffset = lowerBound - over * 0.2
                        } else {
                            manualOffset = newOffset
                        }
                    },
                    onScrollEnd: {
                        if smoothScroll && isUserScrolling {
                            // Find the word at the active tracking anchor.
                            let newProgress = wordProgressAtCurrentOffset()
                            withAnimation(.easeOut(duration: 0.15)) {
                                manualOffset = 0
                            }
                            isUserScrolling = false
                            allowsNextBackwardTrackingUpdate = true
                            onManualScroll?(false, newProgress)
                        } else {
                            let maxY = wordYPositions.values.max() ?? 0
                            let containerHeight = geo.size.height
                            let upperBound = containerHeight * 0.5
                            let lowerBound = -max(0, maxY - containerHeight * 0.5)

                            if manualOffset > upperBound || manualOffset < lowerBound {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    manualOffset = min(upperBound, max(lowerBound, manualOffset))
                                }
                            }
                        }
                    }
                )
            )
        }
        .clipped()
        .mask(
            LinearGradient(
                stops: readingPosition == .nearTop
                    ? [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.95),
                        .init(color: .clear, location: 1.0)
                    ]
                    : [
                        .init(color: .clear, location: 0),
                        .init(color: .white, location: 0.05),
                        .init(color: .white, location: 0.95),
                        .init(color: .clear, location: 1.0)
                    ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func initialScrollOffset(containerHeight: CGFloat) -> CGFloat {
        switch readingPosition {
        case .centered:
            let lineHeight = font.pointSize * 1.4
            return containerHeight * 0.5 - lineHeight * 0.5
        case .nearTop:
            return 0
        }
    }

    private func recalculateTracking(containerHeight: CGFloat) {
        if readingPosition == .nearTop {
            recalcTopWithPreviousLine()
            return
        }

        let center = containerHeight * 0.5

        if smoothScroll {
            // Classic/silence-paused: anchor active word near the bottom, scrolling up
            let bottomAnchor = containerHeight - 20
            let wordIdx = Int(smoothWordProgress)
            let fraction = smoothWordProgress - Double(wordIdx)
            let clampedIdx = max(0, min(wordIdx, words.count - 1))
            guard let wordY = wordYPositions[clampedIdx] else { return }
            let nextY = wordYPositions[clampedIdx + 1] ?? wordY
            let interpolatedY = wordY + (nextY - wordY) * CGFloat(fraction)
            applyTrackingTarget(bottomAnchor - interpolatedY)
        } else {
            // Word-tracking/voice-activated: active word at vertical center
            let wordIdx = activeWordIndex()
            if let wordY = wordYPositions[wordIdx] {
                let target = center - wordY
                applyTrackingTarget(target)
            }
        }
    }

    private func recalcTopWithPreviousLine() {
        if smoothScroll {
            let wordIdx = Int(smoothWordProgress)
            let fraction = smoothWordProgress - Double(wordIdx)
            let clampedIdx = max(0, min(wordIdx, words.count - 1))
            guard let wordY = wordYPositions[clampedIdx] else { return }
            let nextY = wordYPositions[clampedIdx + 1] ?? wordY
            let interpolatedY = wordY + (nextY - wordY) * CGFloat(fraction)
            let target = min(interpolatedY, topReadingAnchor) - interpolatedY
            applyTrackingTarget(target)
        } else {
            let wordIdx = activeWordIndex()
            guard let wordY = wordYPositions[wordIdx] else { return }
            let target = min(wordY, topReadingAnchor) - wordY
            applyTrackingTarget(target)
        }
    }

    private func repositionTracking(toWordIndex wordIndex: Int) {
        guard let wordY = wordYPositions[wordIndex] else { return }

        let target: CGFloat
        switch readingPosition {
        case .centered:
            target = containerHeight * 0.5 - wordY
        case .nearTop:
            target = min(wordY, topReadingAnchor) - wordY
        }

        applyTrackingTarget(target, force: true)
    }

    private var topReadingAnchor: CGFloat {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let fallbackAdvance = lineHeight + (lineHeight / font.pointSize > 1.5 ? 2 : 8)
        return (stableTopLineCenter ?? lineHeight * 0.5)
            + (stableLineAdvance ?? fallbackAdvance)
    }

    /// Capture the actual row geometry once, before visibility culling changes
    /// which word frames participate in the preference dictionary.
    private func captureStableLineMetrics(from positions: [Int: CGFloat]) {
        guard readingPosition == .nearTop,
              stableTopLineCenter == nil || stableLineAdvance == nil else { return }

        let positionedWords = positions.sorted { $0.value < $1.value }
        let measuredLines = positionedWords.reduce(into: [(y: CGFloat, wordIDs: [Int])]()) { result, entry in
            if let lastIndex = result.indices.last,
               abs(result[lastIndex].y - entry.value) <= 0.5 {
                result[lastIndex].wordIDs.append(entry.key)
            } else {
                result.append((y: entry.value, wordIDs: [entry.key]))
            }
        }
        guard let firstLineY = measuredLines.first?.y else { return }
        if stableTopLineCenter == nil {
            stableTopLineCenter = firstLineY
        }
        if stableLineAdvance == nil, measuredLines.count > 1 {
            for index in 1..<measuredLines.count {
                let firstWordID = measuredLines[index].wordIDs.min() ?? -1
                guard !paragraphBreakBeforeWordIndices.contains(firstWordID) else { continue }
                stableLineAdvance = measuredLines[index].y - measuredLines[index - 1].y
                break
            }
        }
    }

    /// Normal reading progress may only move the text upward. Brief backward
    /// corrections from speech recognition must not produce a down/up bounce.
    /// Explicit taps and manual scrolling opt into one backward reposition.
    private func applyTrackingTarget(_ target: CGFloat, force: Bool = false) {
        if !hasAppliedTrackingTarget
            || target < scrollOffset - 1
            || allowsNextBackwardTrackingUpdate
            || force {
            scrollOffset = target
        }
        hasAppliedTrackingTarget = true
        allowsNextBackwardTrackingUpdate = false
    }

    private func wordIndex(at charOffset: Int) -> Int {
        var offset = 0
        for (index, word) in words.enumerated() {
            let end = offset + word.count
            if charOffset <= end { return index }
            offset = end + 1
        }
        return max(0, words.count - 1)
    }

    /// Find the word progress at the current visual position (scrollOffset + manualOffset)
    private func wordProgressAtCurrentOffset() -> Double {
        let trackingY: CGFloat
        switch readingPosition {
        case .centered:
            trackingY = containerHeight * 0.5
        case .nearTop:
            trackingY = topReadingAnchor
        }
        let targetY = trackingY - (scrollOffset + manualOffset)

        // Find the closest word and interpolate
        let sorted = wordYPositions.sorted { $0.key < $1.key }
        guard !sorted.isEmpty else { return smoothWordProgress }

        for i in 0..<sorted.count {
            let (wordIdx, wordY) = sorted[i]
            if i + 1 < sorted.count {
                let (_, nextY) = sorted[i + 1]
                if targetY >= wordY && targetY <= nextY {
                    let frac = (nextY - wordY) > 0 ? Double(targetY - wordY) / Double(nextY - wordY) : 0
                    return Double(wordIdx) + frac
                }
            } else if targetY >= wordY {
                return Double(wordIdx)
            }
        }
        // If scrolled above all words, return 0
        if targetY < (sorted.first?.value ?? 0) {
            return 0
        }
        return Double(words.count)
    }

    private func activeWordIndex() -> Int {
        var offset = 0
        for (i, word) in words.enumerated() {
            let end = offset + word.count
            if highlightedCharCount <= end { return i }
            offset = end + 1
        }
        return max(0, words.count - 1)
    }

    /// Returns (wordIndex, fractionThroughWord) for smooth interpolation
    private func activeWordFraction() -> (Int, Double) {
        var offset = 0
        for (i, word) in words.enumerated() {
            let end = offset + word.count
            if highlightedCharCount <= end {
                let wordLen = max(1, word.count)
                let into = highlightedCharCount - offset
                return (i, Double(into) / Double(wordLen))
            }
            offset = end + 1
        }
        return (max(0, words.count - 1), 1.0)
    }
}

// MARK: - Word Flow Layout

struct WordFlowLayout: View {
    let words: [String]
    let highlightedCharCount: Int
    let font: NSFont
    var highlightColor: Color = .white
    var cueColor: Color = .white
    var cueUnreadOpacity: Double = 0.2
    var cueReadOpacity: Double = 0.5
    var highlightWords: Bool = true
    var paragraphBreakBeforeWordIndices: Set<Int> = []
    let containerWidth: CGFloat
    var onWordTap: ((Int) -> Void)? = nil
    var scrollOffset: CGFloat = 0
    var viewportHeight: CGFloat = 0

    // Compute line spacing based on font metrics — fonts with large built-in
    // line height (e.g. OpenDyslexic) need less extra spacing
    private var lineSpacing: CGFloat {
        let intrinsicHeight = font.ascender - font.descender + font.leading
        let ratio = intrinsicHeight / font.pointSize
        // System fonts: ratio ~1.2, OpenDyslexic: ratio ~1.7+
        return ratio > 1.5 ? 2 : 8
    }

    // Simple layout cache to avoid re-measuring words on every highlight update
    private static var _cacheKey: String = ""
    private static var _cachedItems: [WordItem] = []
    private static var _cachedLines: [[WordItem]] = []
    private static var _cachedParagraphPrefixCounts: [Int] = []

    private func cachedLayout() -> ([WordItem], [[WordItem]], [Int]) {
        let paragraphKey = paragraphBreakBeforeWordIndices.sorted()
            .map(String.init)
            .joined(separator: ",")
        let key = "\(words.count)|\(words.first ?? "")|\(words.last ?? "")|\(font.pointSize)|\(Int(containerWidth))|\(paragraphKey)"
        if key == Self._cacheKey {
            return (Self._cachedItems, Self._cachedLines, Self._cachedParagraphPrefixCounts)
        }
        let items = buildItems()
        let lines = buildLines(items: items)
        var paragraphPrefixCounts = [0]
        for line in lines {
            let beginsParagraph = line.first.map {
                paragraphBreakBeforeWordIndices.contains($0.id)
            } ?? false
            paragraphPrefixCounts.append(
                paragraphPrefixCounts[paragraphPrefixCounts.count - 1] + (beginsParagraph ? 1 : 0)
            )
        }
        Self._cacheKey = key
        Self._cachedItems = items
        Self._cachedLines = lines
        Self._cachedParagraphPrefixCounts = paragraphPrefixCounts
        return (items, lines, paragraphPrefixCounts)
    }

    // Find the index of the next word to read (first non-fully-lit, non-annotation word)
    private func nextWordIndex(items: [WordItem]) -> Int {
        for item in items {
            if item.isAnnotation { continue }
            let charsIntoWord = highlightedCharCount - item.charOffset
            let litCount = max(0, min(item.word.count, charsIntoWord))
            let letterCount = max(1, item.word.filter { $0.isLetter || $0.isNumber }.count)
            if litCount < letterCount {
                return item.id
            }
        }
        return -1
    }

    private func isRightToLeft(items: [WordItem]) -> Bool {
        for item in items where !item.isAnnotation {
            switch textBaseDirection(in: item.word) {
            case .rightToLeft:
                return true
            case .leftToRight:
                return false
            case .natural:
                continue
            }
        }
        return false
    }

    var body: some View {
        let (items, lines, paragraphPrefixCounts) = cachedLayout()
        let nextIdx = nextWordIndex(items: items)
        let totalLines = lines.count
        let rtl = isRightToLeft(items: items)

        // Estimate line height for visibility culling using actual font metrics
        let rowHeight = ceil(font.ascender - font.descender + font.leading)
        let lineH = rowHeight + lineSpacing
        let lineTop: (Int) -> CGFloat = { lineIndex in
            CGFloat(lineIndex) * lineH
                + CGFloat(paragraphPrefixCounts[lineIndex]) * paragraphDividerExtraSpacing
        }
        let lineRowHeight: (Int) -> CGFloat = { lineIndex in
            let beginsParagraph = paragraphPrefixCounts[lineIndex + 1]
                > paragraphPrefixCounts[lineIndex]
            return rowHeight + (beginsParagraph ? paragraphDividerExtraSpacing : 0)
        }
        let totalContentHeight = max(0, lineTop(totalLines) - lineSpacing)

        // Determine visible range of lines
        let canCull = viewportHeight > 0 && totalLines > 0
        let buffer: CGFloat = 400
        let startLine: Int = {
            guard canCull else { return 0 }
            let visibleMinY = -scrollOffset - buffer
            var candidate = max(0, min(totalLines, Int(floor(max(0, visibleMinY) / lineH))))
            while candidate > 0, lineTop(candidate) > visibleMinY {
                candidate -= 1
            }
            while candidate < totalLines,
                  lineTop(candidate) + lineRowHeight(candidate) < visibleMinY {
                candidate += 1
            }
            return candidate
        }()
        let endLine: Int = {
            guard canCull else { return totalLines }
            let visibleMaxY = viewportHeight - scrollOffset + buffer
            var candidate = max(startLine, min(totalLines, Int(ceil(max(0, visibleMaxY) / lineH))))
            while candidate > startLine, lineTop(candidate) > visibleMaxY {
                candidate -= 1
            }
            while candidate < totalLines, lineTop(candidate) < visibleMaxY {
                candidate += 1
            }
            return max(startLine, candidate)
        }()

        // For RTL scripts (Arabic, Hebrew, Persian, Urdu), flip the layout direction
        // so words within each line flow right-to-left instead of left-to-right.
        VStack(alignment: rtl ? .trailing : .leading, spacing: lineSpacing) {
            if startLine > 0 {
                Color.clear.frame(
                    height: max(0, lineTop(startLine) - lineSpacing)
                )
            }

            ForEach(startLine..<endLine, id: \.self) { lineIdx in
                let beginsParagraph = paragraphPrefixCounts[lineIdx + 1]
                    > paragraphPrefixCounts[lineIdx]
                HStack(spacing: 0) {
                    ForEach(lines[lineIdx], id: \.id) { item in
                        wordView(for: item, isNextWord: item.id == nextIdx)
                            .id(item.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                .padding(.top, beginsParagraph ? paragraphDividerExtraSpacing : 0)
                .overlay(alignment: .top) {
                    if beginsParagraph {
                        Rectangle()
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 1)
                            .offset(
                                y: (paragraphDividerExtraSpacing - lineSpacing) * 0.5
                            )
                    }
                }
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            }

            if endLine < totalLines {
                Color.clear.frame(
                    height: max(0, totalContentHeight - lineTop(endLine))
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
        .coordinateSpace(name: "flowLayout")
    }

    private func wordView(for item: WordItem, isNextWord: Bool) -> some View {
        let wordLen = item.word.count
        let charsIntoWord = highlightedCharCount - item.charOffset
        let litCount = max(0, min(wordLen, charsIntoWord))
        let letterCount = max(1, item.word.filter { $0.isLetter || $0.isNumber }.count)
        let isFullyLit = litCount >= letterCount
        let isCurrentWord = isNextWord || (charsIntoWord >= 0 && !isFullyLit)

        // When highlighting is off (classic/silence-paused), use uniform color
        if !highlightWords {
            let uniformColor: Color = item.isAnnotation
                ? cueColor.opacity(cueUnreadOpacity)
                : highlightColor

            return Text(item.word + " ")
                .font(item.isAnnotation ? Font(font).italic() : Font(font))
                .foregroundStyle(uniformColor)
                .background(
                    GeometryReader { wordGeo in
                        Color.clear.preference(
                            key: WordYPreferenceKey.self,
                            value: [item.id: wordGeo.frame(in: .named("flowLayout")).midY]
                        )
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onWordTap?(item.charOffset)
                }
        }

        // Annotations: italic, dimmed with cue color
        if item.isAnnotation {
            let annotationColor: Color = isFullyLit
                ? cueColor.opacity(cueReadOpacity)
                : cueColor.opacity(cueUnreadOpacity)

            return Text(item.word + " ")
                .font(Font(font).italic())
                .foregroundStyle(annotationColor)
                .background(
                    GeometryReader { wordGeo in
                        Color.clear.preference(
                            key: WordYPreferenceKey.self,
                            value: [item.id: wordGeo.frame(in: .named("flowLayout")).midY]
                        )
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onWordTap?(item.charOffset)
                }
        }

        // Dim color: highlight color variant for current word, full for unread
        let dimColor: Color = isCurrentWord
            ? highlightColor.opacity(0.6)
            : highlightColor

        // Base color for the whole word
        let wordColor: Color = isFullyLit ? highlightColor.opacity(0.3) : dimColor

        return Text(item.word + " ")
            .font(Font(font))
            .foregroundStyle(wordColor)
            .underline(isCurrentWord, color: wordColor)
            .background(
                GeometryReader { wordGeo in
                    Color.clear.preference(
                        key: WordYPreferenceKey.self,
                        value: [item.id: wordGeo.frame(in: .named("flowLayout")).midY]
                    )
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onWordTap?(item.charOffset)
            }
    }

    private func buildItems() -> [WordItem] {
        var items: [WordItem] = []
        var offset = 0
        let annotationFlags = SpeechTextAlignment.annotationFlags(for: words)
        for (i, word) in words.enumerated() {
            let isAnnotation = annotationFlags[i] || Self.isAnnotationWord(word)
            items.append(WordItem(id: i, word: word, charOffset: offset, isAnnotation: isAnnotation))
            offset += word.count + 1 // +1 for space
        }
        return items
    }

    static func isAnnotationWord(_ word: String) -> Bool {
        // Words inside square brackets like [smile]
        if word.hasPrefix("[") && word.hasSuffix("]") { return true }
        // Emoji-only words (no letters or numbers)
        let stripped = word.filter { $0.isLetter || $0.isNumber }
        if stripped.isEmpty { return true }
        return false
    }

    private func buildLines(items: [WordItem]) -> [[WordItem]] {
        var lines: [[WordItem]] = [[]]
        var currentLineWidth: CGFloat = 0
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width

        for item in items {
            if paragraphBreakBeforeWordIndices.contains(item.id),
               !lines[lines.count - 1].isEmpty {
                lines.append([])
                currentLineWidth = 0
            }
            let wordWidth = (item.word as NSString).size(withAttributes: [.font: font]).width + spaceWidth
            if currentLineWidth + wordWidth > containerWidth && !lines[lines.count - 1].isEmpty {
                lines.append([])
                currentLineWidth = 0
            }
            lines[lines.count - 1].append(item)
            currentLineWidth += wordWidth
        }
        return lines
    }
}

// MARK: - Elapsed Time

struct ElapsedTimeView: View {
    let fontSize: CGFloat

    @State private var startDate = Date()

    var body: some View {
        TimelineView(.periodic(from: startDate, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let minutes = Int(elapsed) / 60
            let seconds = Int(elapsed) % 60
            Text(String(format: "%02d:%02d", minutes, seconds))
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

// MARK: - Audio Waveform + Progress

struct AudioWaveformProgressView: View {
    let levels: [CGFloat]
    let progress: Double // 0.0 to 1.0

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                let barProgress = Double(index) / Double(max(1, levels.count - 1))
                let isLit = barProgress <= progress

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isLit
                          ? Color.yellow.opacity(0.9)
                          : Color.white.opacity(0.15)
                    )
                    .frame(width: 3, height: max(3, level * 28))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }
}

// Keep the old one for backward compat
struct AudioWaveformView: View {
    let levels: [CGFloat]
    var color: Color = .white

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(0.4 + Double(level) * 0.6))
                    .frame(width: 3, height: max(3, level * 28 + 3))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }
}

// MARK: - Scroll Wheel Handler

struct ScrollWheelView: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void
    var onScrollEnd: (() -> Void)?

    init(onScroll: @escaping (CGFloat) -> Void, onScrollEnd: (() -> Void)? = nil) {
        self.onScroll = onScroll
        self.onScrollEnd = onScrollEnd
    }

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        view.onScrollEnd = onScrollEnd
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onScrollEnd = onScrollEnd
    }
}

class ScrollWheelNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    var onScrollEnd: (() -> Void)?
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window else { return event }
                // Only handle if event is in our window
                if event.window == window {
                    let delta = event.scrollingDeltaY
                    let scaled = event.hasPreciseScrollingDeltas ? delta : delta * 10
                    self.onScroll?(scaled)

                    if event.phase == .ended || event.momentumPhase == .ended {
                        self.onScrollEnd?()
                    }
                }
                return event
            }
        }
    }

    override func removeFromSuperview() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        super.removeFromSuperview()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}
