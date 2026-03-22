//
//  ExternalDisplayController.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import SwiftUI
import Combine

class ExternalDisplayController {
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    let overlayContent = OverlayContent()

    /// Find the target external screen based on saved screen ID, or first non-main screen
    func targetScreen() -> NSScreen? {
        let settings = NotchSettings.shared
        let screens = NSScreen.screens.filter { $0 != NSScreen.main }
        guard !screens.isEmpty else { return nil }

        // Try to find saved screen
        if settings.externalScreenID != 0 {
            if let match = screens.first(where: { $0.displayID == settings.externalScreenID }) {
                return match
            }
        }
        return screens.first
    }

    func show(speechRecognizer: SpeechRecognizer, words: [String], totalCharCount: Int, hasNextPage: Bool = false) {
        let settings = NotchSettings.shared
        guard settings.externalDisplayMode != .off else { return }
        guard let screen = targetScreen() else { return }

        dismiss()

        overlayContent.words = words
        overlayContent.totalCharCount = totalCharCount
        overlayContent.hasNextPage = hasNextPage

        let mirrorAxis = settings.externalDisplayMode == .mirror ? settings.mirrorAxis : nil
        let screenFrame = screen.frame

        let content = ExternalDisplayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            mirrorAxis: mirrorAxis
        )

        let hostingView = NSHostingView(rootView: content)

        let panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
        panel.setFrame(screenFrame, display: true)
        panel.orderFront(nil)
        self.panel = panel

        // Poll for dismiss signal
        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, speechRecognizer.shouldDismiss else { return }
                self.cancellables.removeAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.dismiss()
                }
            }
            .store(in: &cancellables)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        cancellables.removeAll()
    }
}

// MARK: - NSScreen extension to get display ID

extension NSScreen {
    var displayID: UInt32 {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 0
        }
        return screenNumber.uint32Value
    }

    var displayName: String {
        return localizedName
    }
}

// MARK: - External Display SwiftUI View

struct ExternalDisplayView: View {
    @Bindable var content: OverlayContent
    @Bindable var speechRecognizer: SpeechRecognizer
    let mirrorAxis: MirrorAxis?

    private var words: [String] { content.words }
    private var totalCharCount: Int { content.totalCharCount }
    private var hasNextPage: Bool { content.hasNextPage }

    // Timer-based scroll for classic & silence-paused modes
    @State private var timerWordProgress: Double = 0
    @State private var isUserScrolling: Bool = false
    private let scrollTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var listeningMode: ListeningMode {
        NotchSettings.shared.listeningMode
    }

    /// Convert fractional word index to char offset using actual word lengths
    private func charOffsetForWordProgress(_ progress: Double) -> Int {
        let wholeWord = Int(progress)
        let frac = progress - Double(wholeWord)
        var offset = 0
        for i in 0..<min(wholeWord, words.count) {
            offset += words[i].count + 1
        }
        if wholeWord < words.count {
            offset += Int(Double(words[wholeWord].count) * frac)
        }
        return min(offset, totalCharCount)
    }

    /// Convert char offset back to fractional word index (for taps)
    private func wordProgressForCharOffset(_ charOffset: Int) -> Double {
        var offset = 0
        for (i, word) in words.enumerated() {
            let end = offset + word.count
            if charOffset <= end {
                let frac = Double(charOffset - offset) / Double(max(1, word.count))
                return Double(i) + frac
            }
            offset = end + 1
        }
        return Double(words.count)
    }

    private var effectiveCharCount: Int {
        switch listeningMode {
        case .wordTracking:
            return speechRecognizer.recognizedCharCount
        case .classic, .silencePaused:
            return charOffsetForWordProgress(timerWordProgress)
        }
    }

    var isDone: Bool {
        totalCharCount > 0 && effectiveCharCount >= totalCharCount
    }

    private var isEffectivelyListening: Bool {
        switch listeningMode {
        case .wordTracking, .silencePaused:
            return speechRecognizer.isListening
        case .classic:
            return true
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isDone {
                doneView
            } else {
                prompterView
            }
        }
        .overlay(alignment: .topTrailing) {
            if NotchSettings.shared.showElapsedTime {
                ElapsedTimeView(fontSize: 24)
                    .padding(.top, 20)
                    .padding(.trailing, 40)
            }
        }
        .scaleEffect(x: mirrorAxis?.scaleX ?? 1, y: mirrorAxis?.scaleY ?? 1)
        .animation(.easeInOut(duration: 0.5), value: isDone)
        .onChange(of: isDone) { _, done in
            if done {
                speechRecognizer.stop()
            }
        }
        .onReceive(scrollTimer) { _ in
            guard !isDone, !isUserScrolling else { return }
            let speed = NotchSettings.shared.scrollSpeed // words per second
            switch listeningMode {
            case .classic:
                timerWordProgress += speed * 0.05
            case .silencePaused:
                if speechRecognizer.isListening && speechRecognizer.isSpeaking {
                    timerWordProgress += speed * 0.05
                }
            case .wordTracking:
                break
            }
        }
    }

    private var prompterView: some View {
        GeometryReader { geo in
            let fontSize = NotchSettings.shared.fontSize
            let hPad = max(40, geo.size.width * 0.08)

            VStack(spacing: 0) {
                Spacer().frame(height: 20)

                SpeechScrollView(
                    words: words,
                    highlightedCharCount: effectiveCharCount,
                    font: NotchSettings.shared.fontFamilyPreset.font(size: fontSize),
                    highlightColor: NotchSettings.shared.fontColorPreset.color,
                    cueColor: NotchSettings.shared.cueColorPreset.color,
                    cueUnreadOpacity: NotchSettings.shared.cueBrightness.unreadOpacity,
                    cueReadOpacity: NotchSettings.shared.cueBrightness.readOpacity,
                    onWordTap: { charOffset in
                        if listeningMode == .wordTracking {
                            speechRecognizer.jumpTo(charOffset: charOffset)
                        } else {
                            timerWordProgress = wordProgressForCharOffset(charOffset)
                        }
                    },
                    onManualScroll: { scrolling, newProgress in
                        isUserScrolling = scrolling
                        if !scrolling {
                            timerWordProgress = max(0, min(Double(words.count), newProgress))
                        }
                    },
                    smoothScroll: listeningMode != .wordTracking,
                    smoothWordProgress: timerWordProgress,
                    isListening: isEffectivelyListening
                )
                .padding(.horizontal, hPad)

                Spacer().frame(height: 20)

                HStack(alignment: .center, spacing: 16) {
                    AudioWaveformProgressView(
                        levels: speechRecognizer.audioLevels,
                        progress: totalCharCount > 0
                            ? Double(effectiveCharCount) / Double(totalCharCount)
                            : 0
                    )
                    .frame(width: 240, height: 32)

                    if listeningMode == .wordTracking {
                        Text(speechRecognizer.lastSpokenText.split(separator: " ").suffix(5).joined(separator: " "))
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer()
                    }

                    if listeningMode != .classic {
                        Button {
                            if speechRecognizer.isListening {
                                speechRecognizer.stop()
                            } else {
                                speechRecognizer.resume()
                            }
                        } label: {
                            Image(systemName: speechRecognizer.isListening ? "mic.fill" : "mic.slash.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(speechRecognizer.isListening ? .yellow.opacity(0.8) : .white.opacity(0.4))
                                .frame(width: 40, height: 40)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, hPad)
                .padding(.bottom, 40)
            }
        }
    }

    private var doneView: some View {
        VStack(spacing: 12) {
            if hasNextPage {
                Button {
                    speechRecognizer.shouldAdvancePage = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 28, weight: .bold))
                        Text("Next Page")
                            .font(.system(size: 28, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                Text("Done!")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .transition(.scale.combined(with: .opacity))
    }
}
