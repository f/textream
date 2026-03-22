//
//  QADebugStore.swift
//  Textream
//
//  Created by OpenAI Codex on 21.03.2026.
//

import CoreGraphics
import Foundation
import Observation
import OSLog

struct QALogEntry: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let category: String
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}

@Observable
final class QADebugStore {
    static let shared = QADebugStore()

    var trackingStateLabel: String = "Idle"
    var trackingExpectedWord: String = ""
    var trackingConfidenceLabel: String = "Low"
    var trackingFreezeReason: String = "None"
    var trackingDebugSummary: String = "Waiting for speech"
    var trackingPartialText: String = ""

    var anchorSourceLabel: String = "Inactive"
    var anchorMessage: String = "Attached mode inactive"
    var anchorWindowLabel: String = ""
    var anchorFrameLabel: String = ""
    var anchorAccessibilityTrusted: Bool = false

    var recentLogs: [QALogEntry] = []

    private let trackingLogger = Logger(subsystem: "dev.fka.textream", category: "qa.tracking")
    private let anchorLogger = Logger(subsystem: "dev.fka.textream", category: "qa.anchor")

    private var lastTrackingFingerprint: String = ""
    private var lastAnchorFingerprint: String = ""

    func recordTracking(snapshot: TrackingSnapshot, frame: SpeechRecognitionFrame?) {
        trackingStateLabel = snapshot.trackingState.label
        trackingExpectedWord = snapshot.expectedWord
        trackingConfidenceLabel = snapshot.confidenceLevel.label
        trackingFreezeReason = snapshot.decisionReason.freezeLabel
        trackingDebugSummary = snapshot.debugSummary
        trackingPartialText = frame?.partialText ?? trackingPartialText

        let fingerprint = [
            snapshot.trackingState.rawValue,
            snapshot.expectedWord,
            snapshot.confidenceLevel.rawValue,
            snapshot.decisionReason.rawValue,
            snapshot.debugSummary,
        ].joined(separator: "|")
        guard fingerprint != lastTrackingFingerprint else { return }
        lastTrackingFingerprint = fingerprint

        guard NotchSettings.shared.trackingDebugLoggingEnabled else { return }
        let message = """
        state=\(snapshot.trackingState.rawValue) expected=\(snapshot.expectedWord.isEmpty ? "-" : snapshot.expectedWord) confidence=\(snapshot.confidenceLevel.rawValue) freeze=\(snapshot.decisionReason.freezeLabel) detail=\(snapshot.debugSummary)
        """
        appendLog(category: "tracking", message: message, logger: trackingLogger)
    }

    func recordAnchor(_ resolution: WindowAnchorResolution) {
        anchorSourceLabel = resolution.source.label
        anchorMessage = resolution.message
        anchorWindowLabel = resolution.window?.displayName ?? ""
        anchorFrameLabel = resolution.frameLabel
        anchorAccessibilityTrusted = resolution.isAccessibilityTrusted

        let fingerprint = [
            resolution.source.rawValue,
            resolution.window?.displayName ?? "",
            resolution.frameLabel,
            String(resolution.isAccessibilityTrusted),
            resolution.message,
        ].joined(separator: "|")
        guard fingerprint != lastAnchorFingerprint else { return }
        lastAnchorFingerprint = fingerprint

        guard NotchSettings.shared.anchorDebugLoggingEnabled else { return }
        let message = """
        source=\(resolution.source.rawValue) trusted=\(resolution.isAccessibilityTrusted) window=\(resolution.window?.displayName ?? "-") frame=\(resolution.frameLabel) detail=\(resolution.message)
        """
        appendLog(category: "anchor", message: message, logger: anchorLogger)
    }

    func clearLogs() {
        recentLogs.removeAll()
    }

    private func appendLog(category: String, message: String, logger: Logger) {
        recentLogs.insert(QALogEntry(category: category, message: message), at: 0)
        if recentLogs.count > 120 {
            recentLogs.removeLast(recentLogs.count - 120)
        }
        logger.debug("\(message, privacy: .public)")
    }
}
