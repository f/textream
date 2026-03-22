//
//  RemoteStateTypes.swift
//  Textream
//
//  Created by OpenAI Codex on 21.03.2026.
//

import Foundation

// MARK: - Browser State

struct BrowserState: Codable {
    let words: [String]
    let highlightedCharCount: Int
    let totalCharCount: Int
    let audioLevels: [Double]
    let isListening: Bool
    let isDone: Bool
    let fontColor: String
    let cueColor: String
    let hasNextPage: Bool
    let isActive: Bool
    let highlightWords: Bool
    let lastSpokenText: String
    let trackingState: String
    let confidenceLevel: String
    let expectedWord: String
    let nextCue: String
    let manualAsideActive: Bool

    init(
        words: [String],
        highlightedCharCount: Int,
        totalCharCount: Int,
        audioLevels: [Double],
        isListening: Bool,
        isDone: Bool,
        fontColor: String,
        cueColor: String,
        hasNextPage: Bool,
        isActive: Bool,
        highlightWords: Bool,
        lastSpokenText: String,
        trackingState: String,
        confidenceLevel: String,
        expectedWord: String,
        nextCue: String,
        manualAsideActive: Bool
    ) {
        self.words = words
        self.highlightedCharCount = highlightedCharCount
        self.totalCharCount = totalCharCount
        self.audioLevels = audioLevels
        self.isListening = isListening
        self.isDone = isDone
        self.fontColor = fontColor
        self.cueColor = cueColor
        self.hasNextPage = hasNextPage
        self.isActive = isActive
        self.highlightWords = highlightWords
        self.lastSpokenText = lastSpokenText
        self.trackingState = trackingState
        self.confidenceLevel = confidenceLevel
        self.expectedWord = expectedWord
        self.nextCue = nextCue
        self.manualAsideActive = manualAsideActive
    }

    private enum CodingKeys: String, CodingKey {
        case words
        case highlightedCharCount
        case totalCharCount
        case audioLevels
        case isListening
        case isDone
        case fontColor
        case cueColor
        case hasNextPage
        case isActive
        case highlightWords
        case lastSpokenText
        case trackingState
        case confidenceLevel
        case expectedWord
        case nextCue
        case manualAsideActive
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        words = try container.decode([String].self, forKey: .words)
        highlightedCharCount = try container.decode(Int.self, forKey: .highlightedCharCount)
        totalCharCount = try container.decode(Int.self, forKey: .totalCharCount)
        audioLevels = try container.decode([Double].self, forKey: .audioLevels)
        isListening = try container.decode(Bool.self, forKey: .isListening)
        isDone = try container.decode(Bool.self, forKey: .isDone)
        fontColor = try container.decode(String.self, forKey: .fontColor)
        cueColor = try container.decode(String.self, forKey: .cueColor)
        hasNextPage = try container.decode(Bool.self, forKey: .hasNextPage)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        highlightWords = try container.decode(Bool.self, forKey: .highlightWords)
        lastSpokenText = try container.decode(String.self, forKey: .lastSpokenText)
        trackingState = try container.decodeIfPresent(String.self, forKey: .trackingState) ?? TrackingState.tracking.rawValue
        confidenceLevel = try container.decodeIfPresent(String.self, forKey: .confidenceLevel) ?? TrackingConfidence.low.rawValue
        expectedWord = try container.decodeIfPresent(String.self, forKey: .expectedWord) ?? ""
        nextCue = try container.decodeIfPresent(String.self, forKey: .nextCue) ?? ""
        manualAsideActive = try container.decodeIfPresent(Bool.self, forKey: .manualAsideActive) ?? false
    }
}

// MARK: - Director State (App → Web)

struct DirectorState: Codable {
    let words: [String]
    let highlightedCharCount: Int
    let totalCharCount: Int
    let isActive: Bool
    let isDone: Bool
    let isListening: Bool
    let fontColor: String
    let cueColor: String
    let lastSpokenText: String
    let audioLevels: [Double]
    let trackingState: String
    let confidenceLevel: String
    let expectedWord: String
    let nextCue: String
    let manualAsideActive: Bool

    init(
        words: [String],
        highlightedCharCount: Int,
        totalCharCount: Int,
        isActive: Bool,
        isDone: Bool,
        isListening: Bool,
        fontColor: String,
        cueColor: String,
        lastSpokenText: String,
        audioLevels: [Double],
        trackingState: String,
        confidenceLevel: String,
        expectedWord: String,
        nextCue: String,
        manualAsideActive: Bool
    ) {
        self.words = words
        self.highlightedCharCount = highlightedCharCount
        self.totalCharCount = totalCharCount
        self.isActive = isActive
        self.isDone = isDone
        self.isListening = isListening
        self.fontColor = fontColor
        self.cueColor = cueColor
        self.lastSpokenText = lastSpokenText
        self.audioLevels = audioLevels
        self.trackingState = trackingState
        self.confidenceLevel = confidenceLevel
        self.expectedWord = expectedWord
        self.nextCue = nextCue
        self.manualAsideActive = manualAsideActive
    }

    private enum CodingKeys: String, CodingKey {
        case words
        case highlightedCharCount
        case totalCharCount
        case isActive
        case isDone
        case isListening
        case fontColor
        case cueColor
        case lastSpokenText
        case audioLevels
        case trackingState
        case confidenceLevel
        case expectedWord
        case nextCue
        case manualAsideActive
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        words = try container.decode([String].self, forKey: .words)
        highlightedCharCount = try container.decode(Int.self, forKey: .highlightedCharCount)
        totalCharCount = try container.decode(Int.self, forKey: .totalCharCount)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        isDone = try container.decode(Bool.self, forKey: .isDone)
        isListening = try container.decode(Bool.self, forKey: .isListening)
        fontColor = try container.decode(String.self, forKey: .fontColor)
        cueColor = try container.decode(String.self, forKey: .cueColor)
        lastSpokenText = try container.decode(String.self, forKey: .lastSpokenText)
        audioLevels = try container.decode([Double].self, forKey: .audioLevels)
        trackingState = try container.decodeIfPresent(String.self, forKey: .trackingState) ?? TrackingState.tracking.rawValue
        confidenceLevel = try container.decodeIfPresent(String.self, forKey: .confidenceLevel) ?? TrackingConfidence.low.rawValue
        expectedWord = try container.decodeIfPresent(String.self, forKey: .expectedWord) ?? ""
        nextCue = try container.decodeIfPresent(String.self, forKey: .nextCue) ?? ""
        manualAsideActive = try container.decodeIfPresent(Bool.self, forKey: .manualAsideActive) ?? false
    }
}

// MARK: - Director Command (Web → App)

struct DirectorCommand: Codable {
    let type: String
    let text: String?
    let readCharCount: Int?
}
