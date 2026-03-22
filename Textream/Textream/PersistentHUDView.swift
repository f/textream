//
//  PersistentHUDView.swift
//  Textream
//
//  Created by OpenAI Codex on 21.03.2026.
//

import SwiftUI

struct PersistentHUDStripView: View {
    let items: [HUDPresentationItem]
    var compact: Bool = true

    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: compact ? 6 : 8) {
                    ForEach(items) { item in
                        itemView(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: compact ? 28 : 36)
        }
    }

    @ViewBuilder
    private func itemView(_ item: HUDPresentationItem) -> some View {
        switch item.kind {
        case .pill:
            hudPill(item.text, tone: toneColor(for: item.tone))
        case .elapsedTime:
            ElapsedTimeView(fontSize: compact ? 10 : 13)
                .padding(.horizontal, compact ? 10 : 12)
                .padding(.vertical, compact ? 4 : 6)
                .background(.white.opacity(0.08))
                .clipShape(Capsule())
        }
    }

    private func hudPill(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.system(size: compact ? 10 : 12, weight: .medium))
            .foregroundStyle(tone)
            .lineLimit(1)
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 4 : 6)
            .background(.white.opacity(0.08))
            .clipShape(Capsule())
    }

    private func toneColor(for tone: HUDPresentationTone) -> Color {
        switch tone {
        case .success:
            return .green.opacity(0.85)
        case .warning:
            return .yellow.opacity(0.88)
        case .info:
            return .blue.opacity(0.88)
        case .attention:
            return .orange.opacity(0.9)
        case .neutral:
            return .white.opacity(0.72)
        }
    }
}

struct PersistentHUDView: View {
    @Bindable var content: OverlayContent
    @Bindable var speechRecognizer: SpeechRecognizer
    var compact: Bool = true

    private var items: [HUDPresentationItem] {
        PersistentHUDPresenter.items(
            content: content,
            isListening: speechRecognizer.isListening,
            configuration: HUDPresentationConfiguration(
                isEnabled: NotchSettings.shared.persistentHUDEnabled,
                modules: NotchSettings.shared.hudModules
            )
        )
    }

    var body: some View {
        PersistentHUDStripView(items: items, compact: compact)
    }
}

struct QADebugOverlayView: View {
    @Bindable var speechRecognizer: SpeechRecognizer
    var compact: Bool = true
    private let qaDebug = QADebugStore.shared

    var body: some View {
        if NotchSettings.shared.qaDebugOverlayEnabled {
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                Text(trackingLine)
                    .font(.system(size: compact ? 9 : 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
                    .textSelection(.enabled)
                Text(detailLine)
                    .font(.system(size: compact ? 9 : 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .textSelection(.enabled)
                if NotchSettings.shared.overlayMode == .attached || qaDebug.anchorSourceLabel != "Inactive" {
                    Text(anchorLine)
                        .font(.system(size: compact ? 9 : 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.58))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 6 : 8)
            .background(.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var trackingLine: String {
        let expected = speechRecognizer.expectedWord.isEmpty ? "-" : speechRecognizer.expectedWord
        return "TRACK \(speechRecognizer.trackingState.shortLabel) | expected \(expected) | conf \(speechRecognizer.confidenceLevel.label) | freeze \(speechRecognizer.trackingFreezeReason)"
    }

    private var detailLine: String {
        speechRecognizer.trackingDebugSummary
    }

    private var anchorLine: String {
        let window = qaDebug.anchorWindowLabel.isEmpty ? "-" : qaDebug.anchorWindowLabel
        let frame = qaDebug.anchorFrameLabel.isEmpty ? "-" : qaDebug.anchorFrameLabel
        let trusted = qaDebug.anchorAccessibilityTrusted ? "AX on" : "AX off"
        return "ANCHOR \(qaDebug.anchorSourceLabel) | \(trusted) | \(window) | \(frame) | \(qaDebug.anchorMessage)"
    }
}
