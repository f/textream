//
//  SettingsView.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI
import AppKit
import Speech
import Combine
import CoreImage.CIFilterBuiltins

// MARK: - Preview Panel Controller

class NotchPreviewController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<NotchPreviewContent>?
    private var originalFrame: NSRect?
    private var cursorTimer: AnyCancellable?
    private var trackingSettings: NotchSettings?

    func show(settings: NotchSettings) {
        // If panel already exists, just re-show it
        if let panel {
            panel.orderFront(nil)
            return
        }

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = screenFrame.maxY - visibleFrame.maxY

        let maxWidth = NotchSettings.maxWidth
        let maxHeight = menuBarHeight + NotchSettings.maxHeight + 40

        let xPosition = screenFrame.midX - maxWidth / 2
        let yPosition = screenFrame.maxY - maxHeight

        let content = NotchPreviewContent(settings: settings, menuBarHeight: menuBarHeight)
        let hostingView = NSHostingView(rootView: content)
        self.hostingView = hostingView

        let panel = NSPanel(
            contentRect: NSRect(x: xPosition, y: yPosition, width: maxWidth, height: maxHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.contentView = hostingView
        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func dismiss() {
        stopCursorTracking()
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        originalFrame = nil
    }

    var isAtCursor: Bool { originalFrame != nil }

    func animateToCursor(settings: NotchSettings) {
        guard let panel else { return }
        if originalFrame == nil {
            originalFrame = panel.frame
        }
        trackingSettings = settings

        // Animate to cursor, then start continuous tracking
        let target = cursorFrame(for: panel, settings: settings)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            self?.startCursorTracking()
        })
    }

    func animateFromCursor() {
        stopCursorTracking()
        guard let panel, let originalFrame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(originalFrame, display: true)
        }
        self.originalFrame = nil
        self.trackingSettings = nil
    }

    private func cursorFrame(for panel: NSPanel, settings: NotchSettings) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let cursorOffset: CGFloat = 8
        let screenEdgeMargin: CGFloat = 5
        let floatingTopPadding: CGFloat = 14
        let floatingVerticalOffset: CGFloat = 60
        let maxWidth = panel.frame.width
        let notchWidth = settings.notchWidth
        let panelHeight = panel.frame.height
        let visibleHeight = floatingTopPadding + settings.textAreaHeight
        let horizontalInset = (maxWidth - notchWidth) / 2

        var visibleLeft = mouse.x + cursorOffset
        var visibleBottom = mouse.y - visibleHeight

        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? panel.screen
            ?? NSScreen.main {
            let screenFrame = screen.frame
            let minimumVisibleLeft = screenFrame.minX + screenEdgeMargin
            let maximumVisibleLeft = max(
                minimumVisibleLeft,
                screenFrame.maxX - notchWidth - screenEdgeMargin
            )
            visibleLeft = min(max(visibleLeft, minimumVisibleLeft), maximumVisibleLeft)
            visibleBottom = max(visibleBottom, screenFrame.minY + screenEdgeMargin)
        }

        let panelX = visibleLeft - horizontalInset
        let panelY = visibleBottom - (panelHeight - floatingVerticalOffset - visibleHeight)
        return NSRect(x: panelX, y: panelY, width: maxWidth, height: panelHeight)
    }

    private func startCursorTracking() {
        cursorTimer?.cancel()
        cursorTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updatePreviewPosition()
            }
    }

    private func stopCursorTracking() {
        cursorTimer?.cancel()
        cursorTimer = nil
    }

    private func updatePreviewPosition() {
        guard let panel, let settings = trackingSettings else { return }
        let target = cursorFrame(for: panel, settings: settings)
        panel.setFrame(target, display: false)
    }
}

struct NotchPreviewContent: View {
    @Bindable var settings: NotchSettings
    let menuBarHeight: CGFloat

    private static let loremWords = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor [pause] incididunt ut labore et dolore magna aliqua Ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur Excepteur sint occaecat cupidatat non proident sunt in culpa qui officia deserunt mollit anim id est laborum Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium doloremque laudantium totam rem aperiam eaque ipsa quae ab illo inventore veritatis et quasi architecto beatae vitae dicta sunt explicabo Nemo enim ipsam voluptatem quia voluptas sit aspernatur aut odit aut fugit sed quia consequuntur magni dolores eos qui ratione voluptatem sequi nesciunt".split(separator: " ").map(String.init)

    private let highlightedCount = 42
    @State private var previewWordProgress: Double = 0
    private let scrollTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    // Phase 1: corners flatten (0=concave, 1=squared)
    @State private var cornerPhase: CGFloat = 0
    // Phase 2: detach from top (0=stuck to top, 1=moved down + rounded)
    @State private var offsetPhase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let topPadding = menuBarHeight * (1 - offsetPhase) + 14 * offsetPhase
            let contentHeight = topPadding + settings.textAreaHeight
            let currentWidth = settings.notchWidth
            let yOffset = 60 * offsetPhase

            ZStack(alignment: .top) {
                // Shape: concave corners flatten via cornerPhase, then cross-fade to rounded via offsetPhase
                let isTransparent = settings.overlayTransparency && settings.overlayMode == .pinned
                Group {
                    if isTransparent {
                        ZStack {
                            NotchBlurView()
                            DynamicIslandShape(
                                topInset: 16 * (1 - cornerPhase),
                                bottomRadius: 18
                            )
                            .fill(.black.opacity(1.0 - settings.overlayTransparencyOpacity))
                        }
                        .clipShape(DynamicIslandShape(
                            topInset: 16 * (1 - cornerPhase),
                            bottomRadius: 18
                        ))
                    } else {
                        DynamicIslandShape(
                            topInset: 16 * (1 - cornerPhase),
                            bottomRadius: 18
                        )
                        .fill(.black)
                    }
                }
                .opacity(Double(1 - offsetPhase))
                .frame(width: currentWidth, height: contentHeight)

                Group {
                    if settings.floatingGlassEffect {
                        ZStack {
                            GlassEffectView()
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.black.opacity(settings.glassOpacity))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.black)
                    }
                }
                .opacity(Double(offsetPhase))
                .frame(width: currentWidth, height: contentHeight)

                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        if settings.showElapsedTime {
                            ElapsedTimeView(fontSize: 11)
                                .padding(.trailing, 12)
                        }
                    }
                    .frame(height: topPadding)

                    SpeechScrollView(
                        words: Self.loremWords,
                        highlightedCharCount: settings.listeningMode == .wordTracking ? highlightedCount : Self.loremWords.count * 5,
                        font: settings.font,
                        highlightColor: settings.fontColorPreset.color,
                        cueColor: settings.cueColorPreset.color,
                        cueUnreadOpacity: settings.cueBrightness.unreadOpacity,
                        cueReadOpacity: settings.cueBrightness.readOpacity,
                        smoothScroll: settings.listeningMode != .wordTracking,
                        smoothWordProgress: previewWordProgress,
                        isListening: settings.listeningMode != .wordTracking
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }
                .padding(.horizontal, 20)
                .frame(width: currentWidth, height: contentHeight)
            }
            .frame(width: currentWidth, height: contentHeight, alignment: .top)
            .offset(y: yOffset)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .animation(.easeInOut(duration: 0.15), value: settings.notchWidth)
            .animation(.easeInOut(duration: 0.15), value: settings.textAreaHeight)
        }
        .onChange(of: settings.overlayMode) { _, mode in
            if mode == .floating {
                // Phase 1: flatten corners while at top
                withAnimation(.easeInOut(duration: 0.25)) {
                    cornerPhase = 1
                }
                // Phase 2: move down + round corners
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        offsetPhase = 1
                    }
                }
            } else {
                // Reverse Phase 1: move back up to top
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    offsetPhase = 0
                }
                // Reverse Phase 2: restore concave corners
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        cornerPhase = 0
                    }
                }
            }
        }
        .onAppear {
            let isFloating = settings.overlayMode == .floating
            cornerPhase = isFloating ? 1 : 0
            offsetPhase = isFloating ? 1 : 0
        }
        .onReceive(scrollTimer) { _ in
            guard settings.listeningMode != .wordTracking else { return }
            let wordCount = Double(Self.loremWords.count)
            previewWordProgress += settings.scrollSpeed * 0.05
            if previewWordProgress >= wordCount {
                previewWordProgress = 0
            }
        }
        .onChange(of: settings.listeningMode) { _, mode in
            if mode != .wordTracking {
                previewWordProgress = 0
            }
        }
    }
}

// MARK: - Settings Tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance, guidance, teleprompter, external, browser, director

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appearance: return "Appearance"
        case .guidance:   return "Guidance"
        case .teleprompter: return "Teleprompter"
        case .external:   return "External"
        case .browser:    return "Remote"
        case .director:   return "Director"
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintpalette"
        case .guidance:   return "waveform"
        case .teleprompter: return "macwindow"
        case .external:   return "rectangle.on.rectangle"
        case .browser:    return "antenna.radiowaves.left.and.right"
        case .director:   return "megaphone"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Bindable var settings: NotchSettings
    @Environment(\.dismiss) private var dismiss
    @State private var previewController = NotchPreviewController()
    @State private var selectedTab: SettingsTab = .appearance
    @State private var showResetConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)

                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 16)
                            Text(tab.label)
                                .font(.system(size: 13, weight: .regular))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(12)
            .frame(width: 155)
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.04))

            Divider()

            // Content
            VStack(spacing: 0) {
                switch selectedTab {
                case .appearance:
                    appearanceTab
                case .guidance:
                    guidanceTab
                case .teleprompter:
                    teleprompterTab
                case .external:
                    externalTab
                case .browser:
                    browserTab
                case .director:
                    directorTab
                }

                Divider()

                HStack {
                    Button("Reset All") {
                        showResetConfirmation = true
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .controlSize(.regular)

                    Spacer()

                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 500)
        .frame(minHeight: 280, maxHeight: 500)
        .background(.ultraThinMaterial)
        .alert("Reset All Settings?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    resetAllSettings()
                }
            }
        } message: {
            Text("This will restore all settings to their defaults.")
        }
        .onAppear {
            if settings.overlayMode != .fullscreen {
                previewController.show(settings: settings)
                if settings.followCursorWhenUndocked && settings.overlayMode == .floating {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        previewController.animateToCursor(settings: settings)
                    }
                }
            }
        }
        .onDisappear {
            previewController.dismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            previewController.hide()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if settings.overlayMode != .fullscreen {
                previewController.show(settings: settings)
                if settings.followCursorWhenUndocked && settings.overlayMode == .floating {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        previewController.animateToCursor(settings: settings)
                    }
                }
            }
        }
        .onChange(of: settings.followCursorWhenUndocked) { _, follow in
            if follow && settings.overlayMode == .floating {
                previewController.animateToCursor(settings: settings)
            } else {
                previewController.animateFromCursor()
            }
        }
        .onChange(of: settings.overlayMode) { _, mode in
            if mode == .fullscreen {
                previewController.hide()
            } else {
                previewController.show(settings: settings)
                if mode == .floating && settings.followCursorWhenUndocked {
                    previewController.animateToCursor(settings: settings)
                } else if previewController.isAtCursor {
                    previewController.animateFromCursor()
                }
            }
        }
    }

    // MARK: - Appearance Tab

    private var appearanceTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                // Font Family
                Text("Font")
                    .font(.system(size: 13, weight: .medium))

                HStack(spacing: 8) {
                    ForEach(FontFamilyPreset.allCases) { preset in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                settings.fontFamilyPreset = preset
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Text("Ag")
                                    .font(Font(preset.font(size: 16)))
                                    .foregroundStyle(settings.fontFamilyPreset == preset ? Color.accentColor : .primary)
                                Text(preset.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(settings.fontFamilyPreset == preset ? Color.accentColor : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(settings.fontFamilyPreset == preset ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(settings.fontFamilyPreset == preset ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Text Size
                Text("Size")
                    .font(.system(size: 13, weight: .medium))

                HStack(spacing: 8) {
                    ForEach(FontSizePreset.allCases) { preset in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                settings.fontSizePreset = preset
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Text("Ag")
                                    .font(Font(settings.fontFamilyPreset.font(size: preset.pointSize * 0.7)))
                                    .foregroundStyle(settings.fontSizePreset == preset ? Color.accentColor : .primary)
                                Text(preset.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(settings.fontSizePreset == preset ? Color.accentColor : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(settings.fontSizePreset == preset ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(settings.fontSizePreset == preset ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

                // Highlight Color
                Text("Highlight Color")
                    .font(.system(size: 13, weight: .medium))

                HStack(spacing: 8) {
                    ForEach(FontColorPreset.allCases) { preset in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                settings.fontColorPreset = preset
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(preset.color)
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                                    )
                                    .overlay(
                                        settings.fontColorPreset == preset
                                            ? Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(preset == .white ? .black : .white)
                                            : nil
                                    )
                                Text(preset.label)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(settings.fontColorPreset == preset ? .primary : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(settings.fontColorPreset == preset ? preset.color.opacity(0.1) : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(settings.fontColorPreset == preset ? preset.color.opacity(0.4) : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Cue Color
                Text("Cue Color")
                    .font(.system(size: 13, weight: .medium))

                HStack(spacing: 8) {
                    ForEach(FontColorPreset.allCases) { preset in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                settings.cueColorPreset = preset
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(preset.color)
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                                    )
                                    .overlay(
                                        settings.cueColorPreset == preset
                                            ? Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(preset == .white ? .black : .white)
                                            : nil
                                    )
                                Text(preset.label)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(settings.cueColorPreset == preset ? .primary : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(settings.cueColorPreset == preset ? preset.color.opacity(0.1) : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(settings.cueColorPreset == preset ? preset.color.opacity(0.4) : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Cue Brightness
                Text("Cue Brightness")
                    .font(.system(size: 13, weight: .medium))

                Picker("", selection: $settings.cueBrightness) {
                    ForEach(CueBrightness.allCases) { brightness in
                        Text(brightness.label).tag(brightness)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Divider()

                // Dimensions
                Text("Dimensions")
                    .font(.system(size: 13, weight: .medium))

                VStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Width")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(settings.notchWidth))px")
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Slider(
                            value: $settings.notchWidth,
                            in: NotchSettings.minWidth...NotchSettings.maxWidth,
                            step: 10
                        )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Height")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(settings.textAreaHeight))px")
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Slider(
                            value: $settings.textAreaHeight,
                            in: NotchSettings.minHeight...NotchSettings.maxHeight,
                            step: 10
                        )
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Guidance Tab

    private var guidanceTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $settings.listeningMode) {
                ForEach(ListeningMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(settings.listeningMode.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if settings.listeningMode == .wordTracking {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Speech Language")
                        .font(.system(size: 13, weight: .medium))
                    Picker("", selection: $settings.speechLocale) {
                        ForEach(SFSpeechRecognizer.supportedLocales().sorted(by: { $0.identifier < $1.identifier }), id: \.identifier) { locale in
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                .tag(locale.identifier)
                        }
                    }
                    .labelsHidden()
                }
            }

            if settings.listeningMode != .classic {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Microphone")
                        .font(.system(size: 13, weight: .medium))
                    Picker("", selection: $settings.selectedMicUID) {
                        Text("System Default").tag("")
                        ForEach(availableMics) { mic in
                            Text(mic.name).tag(mic.uid)
                        }
                    }
                    .labelsHidden()
                }
            }

            if settings.listeningMode != .wordTracking {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Scroll Speed")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(String(format: "%.1f words/s", settings.scrollSpeed))
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $settings.scrollSpeed,
                        in: 0.5...8,
                        step: 0.5
                    )
                    HStack {
                        Text("Slower")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("Faster")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()
        }
        .padding(16)
        .onAppear { availableMics = AudioInputDevice.allInputDevices() }
    }

    @State private var availableMics: [AudioInputDevice] = []

    // MARK: - Teleprompter Tab

    @State private var overlayScreens: [NSScreen] = []

    private var teleprompterTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                // Overlay mode picker
                Picker("", selection: $settings.overlayMode) {
                    ForEach(OverlayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(settings.overlayMode.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if settings.overlayMode == .pinned {
                    Divider()

                    Text("Display")
                        .font(.system(size: 13, weight: .medium))

                    Picker("", selection: $settings.notchDisplayMode) {
                        ForEach(NotchDisplayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(settings.notchDisplayMode.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if settings.notchDisplayMode == .fixedDisplay {
                        displayPicker(
                            screens: overlayScreens,
                            selectedID: $settings.pinnedScreenID,
                            onRefresh: { refreshOverlayScreens() }
                        )
                    }

                    Divider()

                    Toggle(isOn: $settings.overlayTransparency) {
                        Text("Transparency")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Text("Makes the overlay see-through so desktop content shows through.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if settings.overlayTransparency {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Amount")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(settings.overlayTransparencyOpacity * 100))%")
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Slider(
                                value: $settings.overlayTransparencyOpacity,
                                in: 0.2...0.95,
                                step: 0.05
                            )
                            HStack {
                                Text("More transparent")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Text("Less transparent")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                if settings.overlayMode == .floating {
                    Divider()

                    Toggle(isOn: $settings.followCursorWhenUndocked) {
                        Text("Follow Cursor")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Text("The window follows your cursor and sticks to its bottom-right.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Divider()

                    Toggle(isOn: $settings.floatingGlassEffect) {
                        Text("Glass Effect")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    if settings.floatingGlassEffect {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Opacity")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(settings.glassOpacity * 100))%")
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Slider(
                                value: $settings.glassOpacity,
                                in: 0.0...0.6,
                                step: 0.05
                            )
                        }
                    }
                }

                if settings.overlayMode == .fullscreen {
                    Divider()

                    Text("Display")
                        .font(.system(size: 13, weight: .medium))

                    displayPicker(
                        screens: overlayScreens,
                        selectedID: $settings.fullscreenScreenID,
                        onRefresh: { refreshOverlayScreens() }
                    )

                    HStack(spacing: 6) {
                        Image(systemName: "escape")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Press Esc to stop the teleprompter.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.04))
                    )
                }

                Divider()

                // Options
                Toggle(isOn: $settings.showElapsedTime) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Elapsed Time")
                            .font(.system(size: 13, weight: .medium))
                        Text("Display a running timer while the teleprompter is active.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: $settings.hideFromScreenShare) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide from Screen Sharing")
                            .font(.system(size: 13, weight: .medium))
                        Text("Hide the overlay from screen recordings and video calls.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                Divider()

                // Pagination
                Text("Pagination")
                    .font(.system(size: 13, weight: .semibold))

                Toggle(isOn: $settings.autoNextPage) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto Next Page")
                            .font(.system(size: 13, weight: .medium))
                        Text("Automatically advance to the next page after a countdown.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                if settings.autoNextPage {
                    HStack {
                        Text("Countdown")
                            .font(.system(size: 13))
                        Spacer()
                        Picker("", selection: $settings.autoNextPageDelay) {
                            Text("3 seconds").tag(3)
                            Text("5 seconds").tag(5)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                }
            }
            .padding(16)
        }
        .onAppear { refreshOverlayScreens() }
    }

    // MARK: - External Tab

    @State private var availableScreens: [NSScreen] = []

    private var externalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Show the teleprompter on an external display or Sidecar iPad.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("", selection: $settings.externalDisplayMode) {
                ForEach(ExternalDisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(settings.externalDisplayMode.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if settings.externalDisplayMode == .mirror {
                Divider()

                Text("Mirror Axis")
                    .font(.system(size: 13, weight: .medium))

                Picker("", selection: $settings.mirrorAxis) {
                    ForEach(MirrorAxis.allCases) { axis in
                        Text(axis.label).tag(axis)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(settings.mirrorAxis.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if settings.externalDisplayMode != .off {
                Divider()

                Text("Target Display")
                    .font(.system(size: 13, weight: .medium))

                displayPicker(
                    screens: availableScreens,
                    selectedID: $settings.externalScreenID,
                    onRefresh: { refreshScreens() },
                    emptyMessage: "No external displays detected. Connect a display or enable Sidecar."
                )
            }
            Spacer()
        }
        .padding(16)
        .onAppear { refreshScreens() }
    }

    // MARK: - Remote Tab

    @State private var localIP: String = BrowserServer.localIPAddress() ?? "localhost"
    @State private var showAdvanced: Bool = false

    private var browserTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scan the QR code or open the URL with your iPhone, Android or TV browser on the same Wi-Fi network.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle(isOn: $settings.browserServerEnabled) {
                Text("Enable Remote Connection")
                    .font(.system(size: 13, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if settings.browserServerEnabled {
                Divider()

                let url = "http://\(localIP):\(settings.browserServerPort)"

                if let qrImage = generateQRCode(from: url) {
                    HStack {
                        Spacer()
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Spacer()
                    }
                }

                HStack(spacing: 10) {
                    Text(url)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.08))
                )

                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Port")
                                .font(.system(size: 13, weight: .medium))
                            HStack(spacing: 8) {
                                TextField("Port", text: Binding(
                                    get: { String(settings.browserServerPort) },
                                    set: { str in
                                        if let val = UInt16(str), val >= 1024 {
                                            settings.browserServerPort = val
                                        }
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)

                                Text("Restart required after change")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)

                                Spacer()

                                Button("Restart") {
                                    TextreamService.shared.browserServer.stop()
                                    TextreamService.shared.browserServer.start()
                                    localIP = BrowserServer.localIPAddress() ?? "localhost"
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                            }
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("Uses ports \(String(settings.browserServerPort)) (HTTP) and \(String(settings.browserServerPort + 1)) (WebSocket).")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }

        }
        .padding(16)
        }
        .onAppear { localIP = BrowserServer.localIPAddress() ?? "localhost" }
    }

    // MARK: - Director Tab

    @State private var directorLocalIP: String = BrowserServer.localIPAddress() ?? "localhost"
    @State private var showDirectorAdvanced: Bool = false

    private var directorTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 14) {
            Text("Director Mode lets a remote person control your teleprompter script in real-time via a web browser. The editor will be disabled while active.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle(isOn: $settings.directorModeEnabled) {
                Text("Enable Director Mode")
                    .font(.system(size: 13, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if settings.directorModeEnabled {
                Divider()

                let url = "http://\(directorLocalIP):\(settings.directorServerPort)"

                if let qrImage = generateQRCode(from: url) {
                    HStack {
                        Spacer()
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Spacer()
                    }
                }

                HStack(spacing: 10) {
                    Text(url)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.08))
                )

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Word tracking is forced when the director starts reading.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Advanced", isExpanded: $showDirectorAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Port")
                                .font(.system(size: 13, weight: .medium))
                            HStack(spacing: 8) {
                                TextField("Port", text: Binding(
                                    get: { String(settings.directorServerPort) },
                                    set: { str in
                                        if let val = UInt16(str), val >= 1024 {
                                            settings.directorServerPort = val
                                        }
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)

                                Text("Restart required after change")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)

                                Spacer()

                                Button("Restart") {
                                    TextreamService.shared.directorServer.stop()
                                    TextreamService.shared.directorServer.start()
                                    directorLocalIP = BrowserServer.localIPAddress() ?? "localhost"
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                            }
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("Uses ports \(String(settings.directorServerPort)) (HTTP) and \(String(settings.directorServerPort + 1)) (WebSocket).")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }

        }
        .padding(16)
        }
        .onAppear { directorLocalIP = BrowserServer.localIPAddress() ?? "localhost" }
    }

    // MARK: - Shared Components

    private func displayPicker(
        screens: [NSScreen],
        selectedID: Binding<UInt32>,
        onRefresh: @escaping () -> Void,
        emptyMessage: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if screens.isEmpty, let emptyMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(emptyMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.08))
                )
            } else {
                ForEach(screens, id: \.displayID) { screen in
                    Button {
                        selectedID.wrappedValue = screen.displayID
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "display")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(selectedID.wrappedValue == screen.displayID ? Color.accentColor : .secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(screen.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(selectedID.wrappedValue == screen.displayID ? Color.accentColor : .primary)
                                Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedID.wrappedValue == screen.displayID {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedID.wrappedValue == screen.displayID ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button(action: onRefresh) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Refresh")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - QR Code

    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scale = 10.0
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    // MARK: - Helpers

    private func resetAllSettings() {
        settings.notchWidth = NotchSettings.defaultWidth
        settings.textAreaHeight = NotchSettings.defaultHeight
        settings.fontSizePreset = .lg
        settings.fontFamilyPreset = .sans
        settings.fontColorPreset = .white
        settings.cueColorPreset = .white
        settings.cueBrightness = .dim
        settings.overlayMode = .pinned
        settings.notchDisplayMode = .followMouse
        settings.pinnedScreenID = 0
        settings.floatingGlassEffect = false
        settings.glassOpacity = 0.15
        settings.overlayTransparency = false
        settings.overlayTransparencyOpacity = 0.85
        settings.followCursorWhenUndocked = false
        settings.fullscreenScreenID = 0
        settings.externalDisplayMode = .off
        settings.externalScreenID = 0
        settings.mirrorAxis = .horizontal
        settings.listeningMode = .wordTracking
        settings.scrollSpeed = 3
        settings.showElapsedTime = true
        settings.selectedMicUID = ""
        settings.autoNextPage = false
        settings.autoNextPageDelay = 3
        settings.browserServerEnabled = false
        settings.browserServerPort = 7373
        settings.directorModeEnabled = false
        settings.directorServerPort = 7575
    }

    private func refreshScreens() {
        availableScreens = NSScreen.screens.filter { $0 != NSScreen.main }
        if settings.externalScreenID == 0, let first = availableScreens.first {
            settings.externalScreenID = first.displayID
        }
    }

    private func refreshOverlayScreens() {
        overlayScreens = NSScreen.screens
        if settings.pinnedScreenID == 0, let main = NSScreen.main {
            settings.pinnedScreenID = main.displayID
        }
        if settings.fullscreenScreenID == 0, let main = NSScreen.main {
            settings.fullscreenScreenID = main.displayID
        }
    }
}
