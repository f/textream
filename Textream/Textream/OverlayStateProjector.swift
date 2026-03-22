//
//  OverlayStateProjector.swift
//  Textream
//
//  Created by OpenAI Codex on 21.03.2026.
//

import Foundation

struct OverlayProjectionState: Equatable {
    var highlightedCharCount: Int
    var trackingState: TrackingState
    var expectedWord: String
    var nextCue: String
    var confidenceLevel: TrackingConfidence
    var confidenceScore: Double
    var manualAsideMode: ManualAsideMode
    var trackingStatusLine: String
    var partialText: String
    var manualIgnoreActive: Bool

    init(
        highlightedCharCount: Int = 0,
        trackingState: TrackingState = .tracking,
        expectedWord: String = "",
        nextCue: String = "",
        confidenceLevel: TrackingConfidence = .low,
        confidenceScore: Double = 0,
        manualAsideMode: ManualAsideMode = .inactive,
        trackingStatusLine: String = "",
        partialText: String = "",
        manualIgnoreActive: Bool = false
    ) {
        self.highlightedCharCount = highlightedCharCount
        self.trackingState = trackingState
        self.expectedWord = expectedWord
        self.nextCue = nextCue
        self.confidenceLevel = confidenceLevel
        self.confidenceScore = confidenceScore
        self.manualAsideMode = manualAsideMode
        self.trackingStatusLine = trackingStatusLine
        self.partialText = partialText
        self.manualIgnoreActive = manualIgnoreActive
    }
}

enum OverlayStateProjector {
    static func projected(
        snapshot: TrackingSnapshot,
        frame: SpeechRecognitionFrame?
    ) -> OverlayProjectionState {
        OverlayProjectionState(
            highlightedCharCount: snapshot.highlightedCharCount,
            trackingState: snapshot.trackingState,
            expectedWord: snapshot.expectedWord,
            nextCue: snapshot.nextCue,
            confidenceLevel: snapshot.confidenceLevel,
            confidenceScore: snapshot.confidenceScore,
            manualAsideMode: snapshot.manualAsideMode,
            trackingStatusLine: snapshot.statusLine,
            partialText: frame?.partialText ?? "",
            manualIgnoreActive: snapshot.manualAsideMode == .hold
        )
    }

    static func apply(
        snapshot: TrackingSnapshot,
        frame: SpeechRecognitionFrame?,
        to content: OverlayContent
    ) {
        let projection = projected(snapshot: snapshot, frame: frame)
        content.highlightedCharCount = projection.highlightedCharCount
        content.trackingState = projection.trackingState
        content.expectedWord = projection.expectedWord
        content.nextCue = projection.nextCue
        content.confidenceLevel = projection.confidenceLevel
        content.confidenceScore = projection.confidenceScore
        content.manualAsideMode = projection.manualAsideMode
        content.trackingStatusLine = projection.trackingStatusLine
        content.manualIgnoreActive = projection.manualIgnoreActive
        content.partialText = projection.partialText
    }
}
