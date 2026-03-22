//
//  PersistentHUDPresenter.swift
//  Textream
//
//  Created by OpenAI Codex on 21.03.2026.
//

import Foundation

enum HUDPresentationTone: String, Equatable {
    case neutral
    case success
    case warning
    case info
    case attention
}

enum HUDPresentationItemKind: String, Equatable {
    case pill
    case elapsedTime
}

struct HUDPresentationItem: Identifiable, Equatable {
    let id: String
    let kind: HUDPresentationItemKind
    let text: String
    let tone: HUDPresentationTone
}

struct HUDPresentationConfiguration: Equatable {
    let isEnabled: Bool
    let modules: [HUDModule]
}

struct HUDPresentationInput: Equatable {
    let trackingState: TrackingState
    let expectedWord: String
    let nextCue: String
    let attachedRequiresAttention: Bool
    let attachedDiagnosticState: AttachedDiagnosticState
    let attachedStatusLine: String

    init(
        trackingState: TrackingState = .tracking,
        expectedWord: String = "",
        nextCue: String = "",
        attachedRequiresAttention: Bool = false,
        attachedDiagnosticState: AttachedDiagnosticState = .inactive,
        attachedStatusLine: String = ""
    ) {
        self.trackingState = trackingState
        self.expectedWord = expectedWord
        self.nextCue = nextCue
        self.attachedRequiresAttention = attachedRequiresAttention
        self.attachedDiagnosticState = attachedDiagnosticState
        self.attachedStatusLine = attachedStatusLine
    }

    init(content: OverlayContent) {
        self.init(
            trackingState: content.trackingState,
            expectedWord: content.expectedWord,
            nextCue: content.nextCue,
            attachedRequiresAttention: content.attachedRequiresAttention,
            attachedDiagnosticState: content.attachedDiagnosticState,
            attachedStatusLine: content.attachedStatusLine
        )
    }
}

enum PersistentHUDPresenter {
    static func items(
        content: OverlayContent,
        isListening: Bool,
        configuration: HUDPresentationConfiguration
    ) -> [HUDPresentationItem] {
        items(
            input: HUDPresentationInput(content: content),
            isListening: isListening,
            configuration: configuration
        )
    }

    static func items(
        input: HUDPresentationInput,
        isListening: Bool,
        configuration: HUDPresentationConfiguration
    ) -> [HUDPresentationItem] {
        guard configuration.isEnabled else { return [] }

        var items: [HUDPresentationItem] = []

        if input.attachedRequiresAttention && !input.attachedStatusLine.isEmpty {
            items.append(
                HUDPresentationItem(
                    id: "attached-status",
                    kind: .pill,
                    text: input.attachedStatusLine,
                    tone: attachedTone(for: input.attachedDiagnosticState)
                )
            )
        }

        for module in configuration.modules {
            switch module {
            case .trackingState:
                items.append(
                    HUDPresentationItem(
                        id: module.rawValue,
                        kind: .pill,
                        text: input.trackingState.label,
                        tone: tone(for: input.trackingState)
                    )
                )
            case .expectedWord:
                if !input.expectedWord.isEmpty {
                    items.append(
                        HUDPresentationItem(
                            id: module.rawValue,
                            kind: .pill,
                            text: "Now: \(input.expectedWord)",
                            tone: .neutral
                        )
                    )
                }
            case .nextCue:
                if !input.nextCue.isEmpty {
                    items.append(
                        HUDPresentationItem(
                            id: module.rawValue,
                            kind: .pill,
                            text: "Next: \(input.nextCue)",
                            tone: .neutral
                        )
                    )
                }
            case .microphoneStatus:
                items.append(
                    HUDPresentationItem(
                        id: module.rawValue,
                        kind: .pill,
                        text: isListening ? "Mic On" : "Mic Off",
                        tone: isListening ? .warning : .neutral
                    )
                )
            case .elapsedTime:
                items.append(
                    HUDPresentationItem(
                        id: module.rawValue,
                        kind: .elapsedTime,
                        text: "Elapsed Time",
                        tone: .neutral
                    )
                )
            }
        }

        return items
    }

    private static func tone(for state: TrackingState) -> HUDPresentationTone {
        switch state {
        case .tracking:
            return .success
        case .uncertain:
            return .warning
        case .aside:
            return .info
        case .lost:
            return .attention
        }
    }

    private static func attachedTone(for state: AttachedDiagnosticState) -> HUDPresentationTone {
        switch state {
        case .permissionRequired:
            return .warning
        case .quartzFallback:
            return .info
        case .targetUnreadable, .targetLostFallback, .hiddenFallback:
            return .attention
        case .inactive, .attachedLive, .noTargetSelected:
            return .neutral
        }
    }
}
