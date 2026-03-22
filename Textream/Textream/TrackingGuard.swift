//
//  TrackingGuard.swift
//  Textream
//
//  Created by OpenAI Codex on 21.03.2026.
//

import Foundation

enum TrackingState: String, Codable, CaseIterable, Identifiable {
    case tracking
    case uncertain
    case aside
    case lost

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tracking: return "Tracking"
        case .uncertain: return "Checking Script"
        case .aside: return "Aside"
        case .lost: return "Off Script"
        }
    }

    var shortLabel: String {
        switch self {
        case .tracking: return "Tracking"
        case .uncertain: return "Checking"
        case .aside: return "Aside"
        case .lost: return "Off Script"
        }
    }
}

enum TrackingConfidence: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var label: String {
        rawValue.capitalized
    }
}

enum ManualAsideMode: String, Codable, CaseIterable, Identifiable {
    case inactive
    case toggled
    case hold

    var id: String { rawValue }

    var isActive: Bool {
        self != .inactive
    }
}

enum TrackingDecisionReason: String, Codable, CaseIterable, Identifiable {
    case idle
    case reset
    case jumped
    case manualAside
    case advanced
    case recoveryPending
    case offScriptAudio
    case lowMatchScore
    case insufficientWordMatch
    case noSpeechSegments
    case legacyFallbackAdvance
    case legacyFallbackNoAdvance

    var id: String { rawValue }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .reset: return "Reset"
        case .jumped: return "Jumped"
        case .manualAside: return "Manual Aside"
        case .advanced: return "Advanced"
        case .recoveryPending: return "Recovery Pending"
        case .offScriptAudio: return "Off-script Audio"
        case .lowMatchScore: return "Low Match Score"
        case .insufficientWordMatch: return "Not Enough Matched Words"
        case .noSpeechSegments: return "No Speech Segments"
        case .legacyFallbackAdvance: return "Legacy Fallback Advanced"
        case .legacyFallbackNoAdvance: return "Legacy Fallback Frozen"
        }
    }

    var freezeLabel: String {
        switch self {
        case .advanced, .jumped, .reset, .idle, .legacyFallbackAdvance:
            return "None"
        default:
            return label
        }
    }
}

struct SpeechSegmentSnapshot: Codable, Hashable, Identifiable {
    let id: UUID
    let text: String
    let confidence: Double
    let timestamp: TimeInterval
    let duration: TimeInterval

    init(
        id: UUID = UUID(),
        text: String,
        confidence: Double,
        timestamp: TimeInterval,
        duration: TimeInterval
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.timestamp = timestamp
        self.duration = duration
    }
}

struct SpeechRecognitionFrame {
    let partialText: String
    let segments: [SpeechSegmentSnapshot]
    let isFinal: Bool
    let createdAt: Date

    var averageConfidence: Double {
        guard !segments.isEmpty else { return 0 }
        let total = segments.reduce(0) { $0 + $1.confidence }
        return total / Double(segments.count)
    }
}

struct TrackingSnapshot {
    let highlightedCharCount: Int
    let trackingState: TrackingState
    let expectedWord: String
    let nextCue: String
    let confidenceLevel: TrackingConfidence
    let manualAsideMode: ManualAsideMode
    let statusLine: String
    let confidenceScore: Double
    let decisionReason: TrackingDecisionReason
    let debugSummary: String
}

private struct ScriptToken {
    let raw: String
    let normalized: String
    let charStart: Int
    let charEnd: Int
    let participatesInTracking: Bool
}

private struct AlignmentResult {
    let score: Double
    let lastMatchedScriptIndex: Int?
    let matchedWordCount: Int
}

private struct CandidateResult {
    let endIndex: Int
    let score: Double
    let wordCount: Int
}

struct TrackingGuard {
    private(set) var sourceText: String = ""
    private var tokens: [ScriptToken] = []
    private var participatingTokenIndices: [Int] = []
    private(set) var highlightedCharCount: Int = 0
    private(set) var currentState: TrackingState = .tracking
    private(set) var confidenceLevel: TrackingConfidence = .low
    private(set) var confidenceScore: Double = 0
    private(set) var manualAsideMode: ManualAsideMode = .inactive
    private(set) var decisionReason: TrackingDecisionReason = .idle
    private(set) var debugSummary: String = "Waiting for speech"

    private var unmatchedFrameCount: Int = 0
    private var recoveryStreak: Int = 0
    private var lastStrongMatchAt: Date = Date()

    init(text: String = "") {
        if !text.isEmpty {
            reset(with: text)
        }
    }

    mutating func reset(with text: String) {
        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        tokens = Self.makeTokens(from: words)
        participatingTokenIndices = tokens.enumerated().compactMap { index, token in
            token.participatesInTracking ? index : nil
        }
        highlightedCharCount = advanceHighlightPastSkippedTokens(from: 0)
        currentState = .tracking
        confidenceLevel = .low
        confidenceScore = 0
        manualAsideMode = .inactive
        decisionReason = .reset
        debugSummary = "Tracking cursor reset to the start of the script"
        unmatchedFrameCount = 0
        recoveryStreak = 0
        lastStrongMatchAt = Date()
    }

    mutating func updateText(_ text: String, preservingCharCount: Int) {
        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        tokens = Self.makeTokens(from: words)
        participatingTokenIndices = tokens.enumerated().compactMap { index, token in
            token.participatesInTracking ? index : nil
        }
        highlightedCharCount = advanceHighlightPastSkippedTokens(from: min(preservingCharCount, collapsed.count))
        decisionReason = .reset
        debugSummary = "Script updated while preserving highlight position at char \(highlightedCharCount)"
        unmatchedFrameCount = 0
        recoveryStreak = 0
        lastStrongMatchAt = Date()
    }

    mutating func jumpTo(charOffset: Int) {
        highlightedCharCount = advanceHighlightPastSkippedTokens(from: max(0, min(charOffset, sourceText.count)))
        currentState = .tracking
        confidenceLevel = .medium
        confidenceScore = 0.5
        decisionReason = .jumped
        debugSummary = "Jumped tracking cursor to char \(highlightedCharCount)"
        unmatchedFrameCount = 0
        recoveryStreak = 0
        lastStrongMatchAt = Date()
    }

    mutating func setManualAsideMode(_ mode: ManualAsideMode) -> TrackingSnapshot {
        manualAsideMode = mode
        currentState = mode.isActive ? .aside : .tracking
        confidenceLevel = mode.isActive ? .medium : .low
        confidenceScore = mode.isActive ? 0.5 : 0
        decisionReason = mode.isActive ? .manualAside : .idle
        debugSummary = mode.isActive
            ? (mode == .hold ? "Temporary ignore is active while Fn is held" : "Latched aside mode is active")
            : "Manual aside released"
        unmatchedFrameCount = 0
        recoveryStreak = 0
        return snapshot()
    }

    mutating func process(
        frame: SpeechRecognitionFrame,
        isSpeaking: Bool,
        strictTrackingEnabled: Bool,
        advanceThreshold: Double,
        windowSize: Int,
        offScriptFreezeDelay: TimeInterval,
        useLegacyFallback: Bool,
        legacyAdvance: ((String, Int) -> Int)? = nil
    ) -> TrackingSnapshot {
        guard !sourceText.isEmpty, !tokens.isEmpty else {
            return snapshot()
        }

        if manualAsideMode.isActive {
            currentState = .aside
            decisionReason = .manualAside
            debugSummary = manualAsideMode == .hold
                ? "Ignoring speech while hold-to-ignore is active"
                : "Ignoring speech while aside mode is toggled on"
            return snapshot()
        }

        if !strictTrackingEnabled, useLegacyFallback, let legacyAdvance {
            let newCount = advanceHighlightPastSkippedTokens(
                from: legacyAdvance(frame.partialText, highlightedCharCount)
            )
            if newCount > highlightedCharCount {
                highlightedCharCount = min(newCount, sourceText.count)
                currentState = .tracking
                confidenceLevel = .medium
                confidenceScore = 0.5
                decisionReason = .legacyFallbackAdvance
                debugSummary = "Legacy fallback advanced highlight to char \(highlightedCharCount)"
                unmatchedFrameCount = 0
                recoveryStreak = 0
                lastStrongMatchAt = frame.createdAt
            } else if isSpeaking {
                transitionToUncertainOrLost(
                    now: frame.createdAt,
                    offScriptFreezeDelay: offScriptFreezeDelay,
                    reason: .legacyFallbackNoAdvance,
                    summary: "Legacy fallback heard speech but did not advance the cursor"
                )
            }
            return snapshot()
        }

        let recentWords = Self.normalizeSpokenWords(from: frame.segments)
        guard !recentWords.isEmpty else {
            if isSpeaking {
                transitionToUncertainOrLost(
                    now: frame.createdAt,
                    offScriptFreezeDelay: offScriptFreezeDelay,
                    reason: .noSpeechSegments,
                    summary: "Audio was active but Speech returned no usable segments"
                )
            }
            return snapshot()
        }

        let best = bestCandidate(
            for: recentWords,
            averageConfidence: frame.averageConfidence,
            windowSize: windowSize
        )
        let requiredMatches = requiredMatchCount(for: recentWords.count)

        if let best,
           best.score >= advanceThreshold,
           best.wordCount >= requiredMatches {
            let newCharCount = advanceHighlightPastSkippedTokens(
                from: min(tokens[best.endIndex].charEnd, sourceText.count)
            )
            let canAdvance = newCharCount >= highlightedCharCount

            if canAdvance {
                if currentState == .lost || currentState == .aside {
                    recoveryStreak += 1
                    if recoveryStreak < 2 {
                        currentState = .uncertain
                        confidenceLevel = confidence(from: best.score)
                        confidenceScore = best.score
                        decisionReason = .recoveryPending
                        debugSummary = "Recovery confirmation 1/2 • score \(Self.format(best.score)) • matched \(best.wordCount) words"
                        return snapshot()
                    }
                }

                highlightedCharCount = newCharCount
                currentState = .tracking
                confidenceLevel = confidence(from: best.score)
                confidenceScore = best.score
                decisionReason = .advanced
                debugSummary = "Advanced \(best.wordCount) words • score \(Self.format(best.score)) • cursor \(highlightedCharCount)"
                unmatchedFrameCount = 0
                recoveryStreak = 0
                lastStrongMatchAt = frame.createdAt
                return snapshot()
            }
        }

        if isSpeaking {
            let spokenSummary = recentWords.joined(separator: " ")
            if let best, best.wordCount < requiredMatches, best.score >= advanceThreshold {
                transitionToUncertainOrLost(
                    now: frame.createdAt,
                    offScriptFreezeDelay: offScriptFreezeDelay,
                    reason: .insufficientWordMatch,
                    summary: "Matched only \(best.wordCount)/\(requiredMatches) words for \"\(spokenSummary)\""
                )
            } else if let best {
                transitionToUncertainOrLost(
                    now: frame.createdAt,
                    offScriptFreezeDelay: offScriptFreezeDelay,
                    reason: .lowMatchScore,
                    summary: "Best score \(Self.format(best.score)) stayed below threshold \(Self.format(advanceThreshold)) for \"\(spokenSummary)\""
                )
            } else {
                transitionToUncertainOrLost(
                    now: frame.createdAt,
                    offScriptFreezeDelay: offScriptFreezeDelay,
                    reason: .offScriptAudio,
                    summary: "No aligned script window found for \"\(spokenSummary)\""
                )
            }
        }

        return snapshot()
    }

    func snapshot() -> TrackingSnapshot {
        TrackingSnapshot(
            highlightedCharCount: highlightedCharCount,
            trackingState: currentState,
            expectedWord: expectedWord(),
            nextCue: nextCue(),
            confidenceLevel: confidenceLevel,
            manualAsideMode: manualAsideMode,
            statusLine: statusLine(),
            confidenceScore: confidenceScore,
            decisionReason: decisionReason,
            debugSummary: debugSummary
        )
    }

    func currentWordIndex() -> Int {
        currentParticipatingWordIndex() ?? max(tokens.count - 1, 0)
    }

    private func expectedWord() -> String {
        guard let index = currentParticipatingWordIndex() else { return "" }
        guard tokens.indices.contains(index) else { return "" }
        return tokens[index].raw
    }

    private func nextCue() -> String {
        guard let currentIndex = currentParticipatingWordIndex(),
              let currentOrdinal = participatingOrdinal(forTokenIndex: currentIndex) else {
            return ""
        }

        let startOrdinal = currentOrdinal + 1
        let endOrdinal = min(startOrdinal + 5, participatingTokenIndices.count)
        guard startOrdinal < endOrdinal else { return "" }

        return participatingTokenIndices[startOrdinal..<endOrdinal]
            .map { tokens[$0].raw }
            .joined(separator: " ")
    }

    private func statusLine() -> String {
        switch currentState {
        case .tracking:
            let word = expectedWord()
            return word.isEmpty ? "Tracking your script" : "Tracking: \(word)"
        case .uncertain:
            return "Heard you. Checking the script before moving."
        case .aside:
            return manualAsideMode == .hold
                ? "Aside active. Tracking is paused while you hold."
                : "Aside mode is on. Tracking is paused."
        case .lost:
            return "Off script. Waiting to lock back on."
        }
    }

    private mutating func transitionToUncertainOrLost(
        now: Date,
        offScriptFreezeDelay: TimeInterval,
        reason: TrackingDecisionReason,
        summary: String
    ) {
        unmatchedFrameCount += 1
        recoveryStreak = 0
        confidenceScore = 0.15
        confidenceLevel = .low
        decisionReason = reason
        debugSummary = summary
        let elapsed = now.timeIntervalSince(lastStrongMatchAt)
        if unmatchedFrameCount >= 2 && elapsed >= offScriptFreezeDelay {
            currentState = .lost
        } else {
            currentState = .uncertain
        }
    }

    private func bestCandidate(
        for recentWords: [String],
        averageConfidence: Double,
        windowSize: Int
    ) -> CandidateResult? {
        guard !tokens.isEmpty,
              let cursor = currentParticipatingWordIndex(),
              let cursorOrdinal = participatingOrdinal(forTokenIndex: cursor),
              !participatingTokenIndices.isEmpty else {
            return nil
        }

        let maxStart = max(participatingTokenIndices.count - 1, 0)
        let startWindow = max(0, cursorOrdinal - 2)
        let endWindow = min(maxStart, cursorOrdinal + max(4, windowSize))
        let maxAdvanceOrdinal = min(participatingTokenIndices.count - 1, cursorOrdinal + 6)
        let maxAdvanceTokenIndex = participatingTokenIndices[maxAdvanceOrdinal]

        var best: CandidateResult?

        for candidateStart in startWindow...endWindow {
            let sliceEnd = min(participatingTokenIndices.count, candidateStart + recentWords.count + 4)
            guard candidateStart < sliceEnd else { continue }

            let candidateTokenIndices = Array(participatingTokenIndices[candidateStart..<sliceEnd])
            let scriptSlice = candidateTokenIndices.map { tokens[$0].normalized }
            let alignment = Self.align(spoken: recentWords, script: scriptSlice)
            guard let lastMatchedLocalIndex = alignment.lastMatchedScriptIndex else { continue }
            guard candidateTokenIndices.indices.contains(lastMatchedLocalIndex) else { continue }
            let endIndex = candidateTokenIndices[lastMatchedLocalIndex]
            guard endIndex >= cursor && endIndex <= maxAdvanceTokenIndex else { continue }

            let distance = abs(candidateStart - cursorOrdinal)
            let proximityBonus = max(0, 1.25 - Double(distance) * 0.12)
            let score = alignment.score + proximityBonus + averageConfidence * 1.4
            let candidate = CandidateResult(endIndex: endIndex, score: score, wordCount: alignment.matchedWordCount)

            if let currentBest = best {
                if candidate.score > currentBest.score {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }

        return best
    }

    private func confidence(from score: Double) -> TrackingConfidence {
        if score >= 3.8 { return .high }
        if score >= 2.4 { return .medium }
        return .low
    }

    private func requiredMatchCount(for spokenWordCount: Int) -> Int {
        guard spokenWordCount > 1 else { return 1 }
        return max(2, Int(ceil(Double(spokenWordCount) * 0.5)))
    }

    private static func makeTokens(from words: [String]) -> [ScriptToken] {
        var offset = 0
        return words.enumerated().map { index, word in
            let start = offset
            offset += word.count
            let end = offset
            if index < words.count - 1 {
                offset += 1
            }
            let participates = wordParticipatesInTracking(word)
            return ScriptToken(
                raw: word,
                normalized: participates ? normalizeWord(word) : "",
                charStart: start,
                charEnd: end,
                participatesInTracking: participates
            )
        }
    }

    private static func normalizeSpokenWords(from segments: [SpeechSegmentSnapshot]) -> [String] {
        let allWords = segments
            .suffix(5)
            .flatMap { segment in
                segment.text
                    .split(whereSeparator: \.isWhitespace)
                    .map { normalizeWord(String($0)) }
            }
            .filter { !$0.isEmpty }
        if allWords.count <= 5 { return allWords }
        return Array(allWords.suffix(5))
    }

    private static func normalizeWord(_ word: String) -> String {
        normalizedTrackingToken(word)
    }

    private static func wordIndex(for charOffset: Int, in tokens: [ScriptToken]) -> Int {
        for (index, token) in tokens.enumerated() where charOffset < token.charEnd {
            return index
        }
        return max(tokens.count - 1, 0)
    }

    private func currentParticipatingWordIndex() -> Int? {
        guard !tokens.isEmpty,
              !participatingTokenIndices.isEmpty,
              highlightedCharCount < sourceText.count else {
            return nil
        }
        let rawIndex = tokens.firstIndex(where: { highlightedCharCount < $0.charEnd }) ?? tokens.count
        return nextParticipatingTokenIndex(startingAt: rawIndex)
    }

    private func nextParticipatingTokenIndex(startingAt index: Int) -> Int? {
        guard !participatingTokenIndices.isEmpty else { return nil }
        for candidate in max(0, index)..<tokens.count where tokens[candidate].participatesInTracking {
            return candidate
        }
        return nil
    }

    private func participatingOrdinal(forTokenIndex index: Int) -> Int? {
        participatingTokenIndices.firstIndex(of: index)
    }

    private func advanceHighlightPastSkippedTokens(from charCount: Int) -> Int {
        guard !tokens.isEmpty else { return max(0, min(charCount, sourceText.count)) }

        var nextCount = max(0, min(charCount, sourceText.count))
        var index = Self.wordIndex(for: nextCount, in: tokens)

        while tokens.indices.contains(index), !tokens[index].participatesInTracking {
            nextCount = max(nextCount, tokens[index].charEnd)
            index += 1
        }

        if participatingTokenIndices.isEmpty {
            return sourceText.count
        }

        return min(nextCount, sourceText.count)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func align(spoken: [String], script: [String]) -> AlignmentResult {
        guard !spoken.isEmpty, !script.isEmpty else {
            return AlignmentResult(score: 0, lastMatchedScriptIndex: nil, matchedWordCount: 0)
        }

        var scores = Array(
            repeating: Array(repeating: 0.0, count: script.count + 1),
            count: spoken.count + 1
        )
        var matches = Array(
            repeating: Array(repeating: 0, count: script.count + 1),
            count: spoken.count + 1
        )
        var lastMatch = Array(
            repeating: Array(repeating: -1, count: script.count + 1),
            count: spoken.count + 1
        )

        var bestScore = 0.0
        var bestMatchCount = 0
        var bestLastMatch = -1

        for i in 1...spoken.count {
            for j in 1...script.count {
                let wordScore: Double
                if spoken[i - 1] == script[j - 1] {
                    wordScore = 1.3
                } else if fuzzyMatch(spoken[i - 1], script[j - 1]) {
                    wordScore = 0.9
                } else {
                    wordScore = -0.45
                }

                let diag = scores[i - 1][j - 1] + wordScore
                let up = scores[i - 1][j] - 0.25
                let left = scores[i][j - 1] - 0.15

                var bestCell = 0.0
                var matchCount = 0
                var last = -1

                if diag >= up, diag >= left, diag > 0 {
                    bestCell = diag
                    matchCount = matches[i - 1][j - 1]
                    last = lastMatch[i - 1][j - 1]
                    if wordScore > 0 {
                        matchCount += 1
                        last = j - 1
                    }
                } else if up >= left, up > 0 {
                    bestCell = up
                    matchCount = matches[i - 1][j]
                    last = lastMatch[i - 1][j]
                } else if left > 0 {
                    bestCell = left
                    matchCount = matches[i][j - 1]
                    last = lastMatch[i][j - 1]
                }

                scores[i][j] = bestCell
                matches[i][j] = matchCount
                lastMatch[i][j] = last

                if bestCell > bestScore || (bestCell == bestScore && matchCount > bestMatchCount) {
                    bestScore = bestCell
                    bestMatchCount = matchCount
                    bestLastMatch = last
                }
            }
        }

        return AlignmentResult(
            score: bestScore,
            lastMatchedScriptIndex: bestLastMatch >= 0 ? bestLastMatch : nil,
            matchedWordCount: bestMatchCount
        )
    }

    private static func fuzzyMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        if a.hasPrefix(b) || b.hasPrefix(a) { return true }
        if a.contains(b) || b.contains(a) { return true }

        let sharedPrefix = zip(a, b).prefix(while: { $0 == $1 }).count
        let shorter = min(a.count, b.count)
        if shorter >= 2 && sharedPrefix >= max(2, shorter * 3 / 5) {
            return true
        }

        return editDistance(a, b) <= (shorter <= 4 ? 1 : 2)
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let lhs = Array(a)
        let rhs = Array(b)
        var dp = Array(0...rhs.count)
        for i in 1...lhs.count {
            var previous = dp[0]
            dp[0] = i
            for j in 1...rhs.count {
                let current = dp[j]
                if lhs[i - 1] == rhs[j - 1] {
                    dp[j] = previous
                } else {
                    dp[j] = min(previous, dp[j - 1], dp[j]) + 1
                }
                previous = current
            }
        }
        return dp[rhs.count]
    }
}
