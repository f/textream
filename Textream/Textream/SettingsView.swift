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
        let maxWidth = panel.frame.width
        let notchWidth = settings.notchWidth
        let panelHeight = panel.frame.height

        let panelX = mouse.x + cursorOffset - (maxWidth - notchWidth) / 2
        let panelY = mouse.y + 60 - panelHeight
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

    private var previewHUDItems: [HUDPresentationItem] {
        PersistentHUDPresenter.items(
            input: HUDPresentationInput(
                trackingState: .tracking,
                expectedWord: "[wave]",
                nextCue: "smile and continue the next line",
                attachedRequiresAttention: false,
                attachedDiagnosticState: .inactive,
                attachedStatusLine: ""
            ),
            isListening: settings.listeningMode != .classic,
            configuration: HUDPresentationConfiguration(
                isEnabled: settings.persistentHUDEnabled,
                modules: settings.hudModules
            )
        )
    }

    var body: some View {
        GeometryReader { geo in
            let topPadding = menuBarHeight * (1 - offsetPhase) + 14 * offsetPhase
            let contentHeight = topPadding + settings.textAreaHeight
            let currentWidth = settings.notchWidth
            let yOffset = 60 * offsetPhase

            ZStack(alignment: .top) {
                // Shape: concave corners flatten via cornerPhase, then cross-fade to rounded via offsetPhase
                DynamicIslandShape(
                    topInset: 16 * (1 - cornerPhase),
                    bottomRadius: 18
                )
                .fill(.black)
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

                    if !previewHUDItems.isEmpty {
                        PersistentHUDStripView(items: previewHUDItems, compact: true)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                    }

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
            if mode == .floating || mode == .attached {
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
            let isFloating = settings.overlayMode == .floating || settings.overlayMode == .attached
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
    case appearance, guidance, teleprompter, layout, external, browser, director, qa

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appearance: return "Appearance"
        case .guidance:   return "Guidance"
        case .teleprompter: return "Teleprompter"
        case .layout:     return "HUD"
        case .external:   return "External"
        case .browser:    return "Remote"
        case .director:   return "Director"
        case .qa:         return "QA & Debug"
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintpalette"
        case .guidance:   return "waveform"
        case .teleprompter: return "macwindow"
        case .layout:     return "rectangle.3.group"
        case .external:   return "rectangle.on.rectangle"
        case .browser:    return "antenna.radiowaves.left.and.right"
        case .director:   return "megaphone"
        case .qa:         return "ladybug"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    private struct OverlayRefreshFingerprint: Equatable {
        let notchWidth: CGFloat
        let textAreaHeight: CGFloat
        let notchDisplayMode: NotchDisplayMode
        let pinnedScreenID: UInt32
        let fullscreenScreenID: UInt32
        let attachedAnchorCorner: AttachedAnchorCorner
        let attachedMarginX: Double
        let attachedMarginY: Double
        let attachedFallbackBehavior: AttachedFallbackBehavior
        let attachedHideWhenWindowUnavailable: Bool
        let hideFromScreenShare: Bool
    }

    private enum FloatingPlacementOption: String, CaseIterable, Identifiable {
        case dragFreely
        case followPointer

        var id: String { rawValue }

        var label: String {
            switch self {
            case .dragFreely:
                return "Free Drag"
            case .followPointer:
                return "Follow Pointer"
            }
        }
    }

    @Bindable var settings: NotchSettings
    @Environment(\.dismiss) private var dismiss
    @State private var previewController = NotchPreviewController()
    @State private var selectedTab: SettingsTab
    @State private var showResetConfirmation = false
    @State private var attachableWindows: [AttachedWindowInfo] = []
    @State private var attachedDiagnostics = AttachedDiagnosticsStore.shared
    private let qaDebug = QADebugStore.shared

    init(settings: NotchSettings, initialTab: SettingsTab = .appearance) {
        self.settings = settings
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        configuredSettingsWindow(settingsRoot)
    }

    private var settingsRoot: some View {
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
            .frame(width: 185)
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
                case .layout:
                    layoutTab
                case .external:
                    externalTab
                case .browser:
                    browserTab
                case .director:
                    directorTab
                case .qa:
                    qaTab
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
    }

    private var overlayRefreshFingerprint: OverlayRefreshFingerprint {
        OverlayRefreshFingerprint(
            notchWidth: settings.notchWidth,
            textAreaHeight: settings.textAreaHeight,
            notchDisplayMode: settings.notchDisplayMode,
            pinnedScreenID: settings.pinnedScreenID,
            fullscreenScreenID: settings.fullscreenScreenID,
            attachedAnchorCorner: settings.attachedAnchorCorner,
            attachedMarginX: settings.attachedMarginX,
            attachedMarginY: settings.attachedMarginY,
            attachedFallbackBehavior: settings.attachedFallbackBehavior,
            attachedHideWhenWindowUnavailable: settings.attachedHideWhenWindowUnavailable,
            hideFromScreenShare: settings.hideFromScreenShare
        )
    }

    private var attachedTargetFingerprint: String {
        "\(settings.attachedTargetWindowID)|\(settings.attachedTargetWindowLabel)"
    }

    private var floatingPlacementSelection: Binding<FloatingPlacementOption> {
        Binding(
            get: {
                settings.followCursorWhenUndocked ? .followPointer : .dragFreely
            },
            set: { selection in
                settings.followCursorWhenUndocked = selection == .followPointer
            }
        )
    }

    private var shouldShowDetachedOverlayPreview: Bool {
        selectedTab == .teleprompter && settings.overlayMode != .fullscreen
    }

    private func configuredSettingsWindow<Content: View>(_ content: Content) -> some View {
        content
            .frame(minWidth: 820, idealWidth: 860, maxWidth: 940, minHeight: 560, idealHeight: 620, maxHeight: 760)
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
            .onAppear(perform: handleSettingsAppear)
            .onDisappear {
                previewController.dismiss()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                previewController.hide()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                handleAppDidBecomeActive()
            }
            .onChange(of: settings.followCursorWhenUndocked) { _, follow in
                handleFollowCursorChanged(follow)
            }
            .onChange(of: settings.overlayMode) { _, mode in
                handleOverlayModeChanged(mode)
            }
            .onChange(of: selectedTab) { _, _ in
                handleSelectedTabChanged()
            }
            .onChange(of: overlayRefreshFingerprint) { _, _ in
                refreshRunningOverlayLayout()
            }
            .onChange(of: attachedTargetFingerprint) { _, _ in
                handleAttachedTargetChanged()
            }
    }

    private func handleSettingsAppear() {
        refreshAttachedDiagnostics()
        showPreviewIfNeeded()
    }

    private func handleAppDidBecomeActive() {
        refreshAttachedDiagnostics()
        showPreviewIfNeeded()
    }

    private func showPreviewIfNeeded() {
        guard shouldShowDetachedOverlayPreview else {
            previewController.dismiss()
            return
        }

        previewController.show(settings: settings)

        if settings.followCursorWhenUndocked, settings.overlayMode == .floating {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                previewController.animateToCursor(settings: settings)
            }
        } else if previewController.isAtCursor {
            previewController.animateFromCursor()
        }
    }

    private func handleFollowCursorChanged(_ follow: Bool) {
        guard shouldShowDetachedOverlayPreview else {
            previewController.dismiss()
            refreshRunningOverlayLayout()
            return
        }

        if follow && settings.overlayMode == .floating {
            previewController.animateToCursor(settings: settings)
        } else {
            previewController.animateFromCursor()
        }
        refreshRunningOverlayLayout()
    }

    private func handleOverlayModeChanged(_ mode: OverlayMode) {
        refreshAttachedDiagnostics()
        showPreviewIfNeeded()
        refreshRunningOverlayLayout()
    }

    private func handleAttachedTargetChanged() {
        refreshAttachedDiagnostics()
        refreshRunningOverlayLayout()
    }

    private func handleSelectedTabChanged() {
        showPreviewIfNeeded()
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
            }
            .padding(16)
        }
    }

    // MARK: - Guidance Tab

    private var guidanceTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
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

                    Divider()

                    Toggle(isOn: $settings.strictTrackingEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Strict Tracking Guard")
                                .font(.system(size: 13, weight: .medium))
                            Text("Freeze instead of drifting when speech does not confidently match the script.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $settings.legacyTrackingFallbackEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow Legacy Fallback")
                                .font(.system(size: 13, weight: .medium))
                            Text("Keep the old matcher available when strict guard is turned off.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Match Window")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("\(settings.matchWindowSize) words")
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.matchWindowSize) },
                                set: { settings.matchWindowSize = Int($0.rounded()) }
                            ),
                            in: 5...12,
                            step: 1
                        )

                        HStack {
                            Text("Advance Threshold")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(String(format: "%.1f", settings.advanceThreshold))
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $settings.advanceThreshold,
                            in: 1.8...5.2,
                            step: 0.1
                        )

                        HStack {
                            Text("Off-script Freeze Delay")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(String(format: "%.1fs", settings.offScriptFreezeDelay))
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $settings.offScriptFreezeDelay,
                            in: 0.6...2.5,
                            step: 0.1
                        )
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Manual Aside Controls")
                            .font(.system(size: 13, weight: .medium))

                        HStack {
                            Text("Toggle Aside")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(settings.manualAsideHotkey.label)
                                .font(.system(size: 12, weight: .medium))
                        }

                        HStack {
                            Text("Hold to Ignore")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(settings.temporaryIgnoreHotkey.label)
                                .font(.system(size: 12, weight: .medium))
                        }
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

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { availableMics = AudioInputDevice.allInputDevices() }
    }

    @State private var availableMics: [AudioInputDevice] = []

    // MARK: - Teleprompter Tab

    @State private var overlayScreens: [NSScreen] = []

    private var teleprompterTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose where the teleprompter lives and tune only the controls that belong to the current mode. The HUD tab only manages the lightweight status strip.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Overlay Mode")
                        .font(.system(size: 13, weight: .medium))

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                        ],
                        spacing: 10
                    ) {
                        ForEach(OverlayMode.allCases) { mode in
                            overlayModeCard(for: mode)
                        }
                    }
                }

                Text(settings.overlayMode.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if settings.overlayMode == .floating {
                    Divider()

                    floatingPointerQuickSection
                }

                Divider()

                layoutPresetSection

                if settings.overlayMode != .attached {
                    Divider()

                    teleprompterSizeSection()
                }

                if settings.overlayMode == .pinned {
                    Divider()

                    Text("Pinned Placement")
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

                    Text("Pinned mode only follows the display your mouse is on. If you want the prompter to chase the pointer itself, switch to Floating Window and turn on Follow Cursor below.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if settings.notchDisplayMode == .fixedDisplay {
                        displayPicker(
                            screens: overlayScreens,
                            selectedID: $settings.pinnedScreenID,
                            onRefresh: { refreshOverlayScreens() }
                        )
                    }
                }

                if settings.overlayMode == .floating {
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

                if settings.overlayMode == .attached {
                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        if !settings.hasSeenAttachedOnboarding {
                            attachedOnboardingCard
                        }

                        attachedDiagnosticsCard

                        HStack {
                            Text("Target Window")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Button("Refresh") {
                                refreshAttachableWindows()
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                        }

                        windowPicker

                        teleprompterSizeSection(
                            title: "Attached Size",
                            description: "Resize the attached teleprompter here, or drag its edges directly. Textream saves the new size and keeps the selected window corner locked."
                        )

                        Text("Attached follows the selected app window instead of the mouse pointer. If you want the teleprompter to chase the mouse again, switch the mode card back to Floating.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Text("Corner")
                            .font(.system(size: 13, weight: .medium))
                        Picker("", selection: $settings.attachedAnchorCorner) {
                            ForEach(AttachedAnchorCorner.allCases) { corner in
                                Text(corner.label).tag(corner)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Horizontal Margin")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(settings.attachedMarginX))px")
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Slider(value: $settings.attachedMarginX, in: 0...40, step: 1)

                            HStack {
                                Text("Vertical Margin")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(settings.attachedMarginY))px")
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Slider(value: $settings.attachedMarginY, in: 0...40, step: 1)
                        }

                        Picker("Fallback", selection: $settings.attachedFallbackBehavior) {
                            ForEach(AttachedFallbackBehavior.allCases) { behavior in
                                Text(behavior.label).tag(behavior)
                            }
                        }
                        .pickerStyle(.segmented)

                        Toggle(isOn: $settings.attachedHideWhenWindowUnavailable) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Hide When Window Is Missing")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Hide instead of showing the fallback position when the target window disappears.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
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

                customPresetsSection

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
        .onAppear {
            refreshOverlayScreens()
            refreshAttachableWindows()
        }
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

    // MARK: - Layout & HUD Tab

    private var layoutTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Persistent HUD only controls the small always-visible status strip. Teleprompter placement and layout presets now live in the Teleprompter tab.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Toggle(isOn: $settings.persistentHUDEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Persistent HUD")
                            .font(.system(size: 13, weight: .medium))
                        Text("Keep only the most important tracking context visible while the prompter is active.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                if settings.persistentHUDEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("HUD Modules")
                            .font(.system(size: 13, weight: .medium))

                        ForEach(HUDModule.allCases) { module in
                            Toggle(isOn: Binding(
                                get: { settings.hudModules.contains(module) },
                                set: { enabled in
                                    if enabled {
                                        if !settings.hudModules.contains(module) {
                                            settings.hudModules.append(module)
                                        }
                                    } else {
                                        settings.hudModules.removeAll { $0 == module }
                                    }
                                }
                            )) {
                                Text(module.label)
                                    .font(.system(size: 12))
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                hudPreviewCard
            }
            .padding(16)
        }
    }

    private var floatingPointerQuickSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pointer Follow")
                .font(.system(size: 13, weight: .medium))

            Text("Movement")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Picker("", selection: floatingPlacementSelection) {
                ForEach(FloatingPlacementOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(settings.followCursorWhenUndocked
                 ? "The floating teleprompter follows your mouse pointer itself. Use this when you want the prompter to travel with the pointer instead of staying near the top camera area."
                 : "The floating teleprompter stays wherever you drag it. Switch to Follow Pointer if you want the prompter to move with the mouse instead.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func teleprompterSizeSection(
        title: String = "Window Size",
        description: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .medium))

            Text(description ?? teleprompterSizeDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

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
    }

    private var teleprompterSizeDescription: String {
        switch settings.overlayMode {
        case .attached:
            return "Resize the attached teleprompter here, or drag its edges directly. Textream will save the new size and keep the selected window corner anchored."
        case .floating:
            return settings.followCursorWhenUndocked
                ? "Resize the follow-pointer teleprompter here. It keeps tracking the pointer while staying inside the visible screen."
                : "Resize the floating teleprompter here, or drag its edges directly. It will keep its current position unless you drag it again."
        case .fullscreen:
            return "Resize the fullscreen layout baseline here. The content refreshes on the selected display immediately."
        case .pinned:
            return "Resize the pinned teleprompter here. Width and reading height stay aligned with the notch placement."
        }
    }

    private var layoutPresetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Layout Presets")
                .font(.system(size: 13, weight: .medium))

            Text("These presets shape the main teleprompter window, not the small HUD strip.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(LayoutPreset.recommendedCases) { preset in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settings.applyBuiltInPreset(preset)
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Text(preset.label)
                                .font(.system(size: 12, weight: .semibold))
                            Text(preset == settings.activeLayoutPreset ? "Active" : "Apply")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(settings.activeLayoutPreset == preset ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if settings.activeLayoutPreset.isLegacyBuiltIn {
                Text("Current layout preset was kept for compatibility and is no longer shown as a recommended default. Save it as a custom preset if you want to keep editing it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var customPresetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Custom Presets")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Save Current") {
                    settings.saveCurrentAsCustomPreset()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if settings.customPresets.isEmpty {
                Text("No custom presets yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(settings.customPresets) { preset in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.system(size: 12, weight: .semibold))
                                Text("\(preset.overlayMode.label) • \(Int(preset.notchWidth))×\(Int(preset.textAreaHeight))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Apply") {
                                settings.applyCustomPreset(preset)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button(role: .destructive) {
                                settings.deleteCustomPreset(preset)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                }
            }
        }
    }

    private var hudPreviewItems: [HUDPresentationItem] {
        PersistentHUDPresenter.items(
            input: HUDPresentationInput(
                trackingState: .tracking,
                expectedWord: "[wave]",
                nextCue: "smile and continue the next line",
                attachedRequiresAttention: settings.overlayMode == .attached && attachedDiagnostics.isDegraded,
                attachedDiagnosticState: settings.overlayMode == .attached ? attachedDiagnostics.state : .inactive,
                attachedStatusLine: settings.overlayMode == .attached ? attachedDiagnostics.statusLine : ""
            ),
            isListening: true,
            configuration: HUDPresentationConfiguration(
                isEnabled: settings.persistentHUDEnabled,
                modules: settings.hudModules
            )
        )
    }

    private var hudPreviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HUD Preview")
                .font(.system(size: 13, weight: .medium))

            Text("Updates instantly as you toggle modules, so you can see what will actually stay visible in the overlay.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.82))

                if hudPreviewItems.isEmpty {
                    Text("Persistent HUD is off. Turn it on to preview the live status strip.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 14)
                } else {
                    PersistentHUDStripView(items: hudPreviewItems, compact: false)
                        .padding(.horizontal, 14)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
        }
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

    // MARK: - QA Tab

    private var qaTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Use this panel during productization passes to inspect attached anchor source, tracking freeze reasons, and recent QA logs without attaching Xcode.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Overlay Debug")
                        .font(.system(size: 13, weight: .medium))

                    Toggle(isOn: $settings.qaDebugOverlayEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Debug Overlay")
                                .font(.system(size: 13, weight: .medium))
                            Text("Displays tracking and anchor source labels directly inside the teleprompter overlay.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $settings.trackingDebugLoggingEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tracking Logs")
                                .font(.system(size: 13, weight: .medium))
                            Text("Writes TrackingGuard state transitions and freeze reasons into the in-app QA log stream.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $settings.anchorDebugLoggingEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Anchor Logs")
                                .font(.system(size: 13, weight: .medium))
                            Text("Writes AX / Quartz / fallback resolution changes into the in-app QA log stream.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Live Tracking")
                        .font(.system(size: 13, weight: .medium))
                    qaValueRow("State", qaDebug.trackingStateLabel)
                    qaValueRow("Expected", qaDebug.trackingExpectedWord.isEmpty ? "-" : qaDebug.trackingExpectedWord)
                    qaValueRow("Confidence", qaDebug.trackingConfidenceLabel)
                    qaValueRow("Freeze Reason", qaDebug.trackingFreezeReason)
                    qaValueRow("Detail", qaDebug.trackingDebugSummary)
                    qaValueRow("Partial", qaDebug.trackingPartialText.isEmpty ? "-" : qaDebug.trackingPartialText)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Live Anchor")
                        .font(.system(size: 13, weight: .medium))
                    qaValueRow("Source", qaDebug.anchorSourceLabel)
                    qaValueRow("AX Trusted", qaDebug.anchorAccessibilityTrusted ? "Yes" : "No")
                    qaValueRow("Window", qaDebug.anchorWindowLabel.isEmpty ? "-" : qaDebug.anchorWindowLabel)
                    qaValueRow("Frame", qaDebug.anchorFrameLabel)
                    qaValueRow("Detail", qaDebug.anchorMessage)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recent QA Logs")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button("Clear") {
                            qaDebug.clearLogs()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if qaDebug.recentLogs.isEmpty {
                        Text("No QA logs yet. Turn on Tracking Logs or Anchor Logs and interact with the overlay.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.04))
                            )
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(qaDebug.recentLogs) { entry in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(entry.timestamp.formatted(date: .omitted, time: .standard)) • \(entry.category.uppercased())")
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Text(entry.message)
                                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.primary.opacity(0.04))
                                    )
                                }
                            }
                        }
                        .frame(minHeight: 220)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Regression Checklist")
                        .font(.system(size: 13, weight: .medium))
                    Text("See `docs/qa/regression-checklist.md` for the current macOS regression matrix, known issues, and exit criteria.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
        }
    }

    private var attachedOnboardingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Before you use Attached Overlay", systemImage: "hand.raised.square.on.square")
                .font(.system(size: 13, weight: .semibold))

            Text("1. Grant Accessibility so Textream can read app window geometry. 2. Choose the window you want to follow. 3. If macOS cannot provide precise geometry, Textream falls back from Accessibility to visible bounds, then to the screen corner.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Open System Settings") {
                    settings.hasSeenAttachedOnboarding = true
                    WindowAnchorService.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Got It") {
                    settings.hasSeenAttachedOnboarding = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
    }

    private var attachedDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Attached Diagnostics")
                        .font(.system(size: 13, weight: .semibold))
                    Text(attachedDiagnostics.anchorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if attachedDiagnostics.shouldOfferSystemSettings {
                    Button("Open System Settings") {
                        WindowAnchorService.openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            qaValueRow("Permission", attachedDiagnostics.permissionState.label)
            qaValueRow("State", attachedDiagnostics.state.label)
            qaValueRow("Anchor", attachedDiagnostics.anchorSourceLabel)
            qaValueRow("Target", attachedTargetDiagnosticLabel)
            qaValueRow("Frame", attachedDiagnostics.frameLabel)
            qaValueRow("Status", attachedDiagnostics.statusLine.isEmpty ? "Healthy" : attachedDiagnostics.statusLine)
            qaValueRow("Details", attachedDiagnostics.detailLine.isEmpty ? "No active fallback" : attachedDiagnostics.detailLine)

            Text(attachedDiagnostics.userFacingExplanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - Shared Components

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if attachableWindows.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("No attachable windows found. Open the app you want to attach to, then refresh.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.04))
                )
            } else {
                ForEach(attachableWindows.prefix(8)) { window in
                    Button {
                        settings.attachedTargetWindowID = window.id
                        settings.attachedTargetWindowLabel = window.displayName
                        refreshAttachedDiagnostics()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "macwindow")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(settings.attachedTargetWindowID == window.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(window.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(settings.attachedTargetWindowID == window.id ? Color.accentColor : .primary)
                                Text("\(Int(window.bounds.width))×\(Int(window.bounds.height))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.attachedTargetWindowID == window.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(settings.attachedTargetWindowID == window.id ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func overlayModeCard(for mode: OverlayMode) -> some View {
        Button {
            settings.overlayMode = mode
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(settings.overlayMode == mode ? Color.accentColor : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(settings.overlayMode == mode ? Color.accentColor : .primary)
                        .lineLimit(2)
                    Text(overlayModeSubtitle(for: mode))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(settings.overlayMode == mode ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(settings.overlayMode == mode ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func overlayModeSubtitle(for mode: OverlayMode) -> String {
        switch mode {
        case .pinned:
            return "Top center only; follows display, not pointer"
        case .floating:
            return settings.overlayMode == .floating && settings.followCursorWhenUndocked
                ? "Currently chasing the pointer"
                : "Drag freely or make it chase the pointer"
        case .fullscreen:
            return "Dedicated fullscreen teleprompter"
        case .attached:
            return settings.overlayMode == .attached
                ? "\(settings.attachedAnchorCorner.label) corner, resizable, with fallback"
                : "Window corner, resizable, with fallback"
        }
    }

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
        settings.followCursorWhenUndocked = false
        settings.strictTrackingEnabled = NotchSettings.defaultStrictTrackingEnabled
        settings.legacyTrackingFallbackEnabled = NotchSettings.defaultLegacyTrackingFallbackEnabled
        settings.matchWindowSize = NotchSettings.defaultMatchWindowSize
        settings.advanceThreshold = NotchSettings.defaultAdvanceThreshold
        settings.offScriptFreezeDelay = NotchSettings.defaultOffScriptFreezeDelay
        settings.attachedAnchorCorner = NotchSettings.defaultAttachedAnchorCorner
        settings.attachedMarginX = NotchSettings.defaultAttachedMarginX
        settings.attachedMarginY = NotchSettings.defaultAttachedMarginY
        settings.attachedFallbackBehavior = NotchSettings.defaultAttachedFallbackBehavior
        settings.attachedTargetWindowID = 0
        settings.attachedTargetWindowLabel = ""
        settings.attachedHideWhenWindowUnavailable = NotchSettings.defaultAttachedHideWhenWindowUnavailable
        settings.hasSeenAttachedOnboarding = false
        settings.hasSeenAccessibilityLaunchGuide = false
        settings.fullscreenScreenID = 0
        settings.externalDisplayMode = .off
        settings.externalScreenID = 0
        settings.mirrorAxis = .horizontal
        settings.listeningMode = .wordTracking
        settings.scrollSpeed = 3
        settings.showElapsedTime = true
        settings.activeLayoutPreset = NotchSettings.defaultActiveLayoutPreset
        settings.customPresets = []
        settings.persistentHUDEnabled = NotchSettings.defaultPersistentHUDEnabled
        settings.hudModules = NotchSettings.defaultHUDModules
        settings.qaDebugOverlayEnabled = false
        settings.trackingDebugLoggingEnabled = false
        settings.anchorDebugLoggingEnabled = false
        settings.selectedMicUID = ""
        settings.autoNextPage = false
        settings.autoNextPageDelay = 3
        settings.browserServerEnabled = false
        settings.browserServerPort = 7373
        settings.directorModeEnabled = false
        settings.directorServerPort = 7575
        qaDebug.clearLogs()
        refreshAttachedDiagnostics()
    }

    private func qaValueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var attachedTargetDiagnosticLabel: String {
        let label = attachedDiagnostics.targetWindowLabel.isEmpty
            ? settings.attachedTargetWindowLabel
            : attachedDiagnostics.targetWindowLabel
        if settings.attachedTargetWindowID == 0 {
            return "None selected"
        }
        let displayLabel = label.isEmpty ? "Window #\(settings.attachedTargetWindowID)" : label
        return "#\(settings.attachedTargetWindowID) • \(displayLabel)"
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

    private func refreshAttachableWindows() {
        attachableWindows = WindowAnchorService.visibleWindows()
        if settings.attachedTargetWindowID == 0, let first = attachableWindows.first {
            settings.attachedTargetWindowID = first.id
            settings.attachedTargetWindowLabel = first.displayName
        }
        refreshAttachedDiagnostics()
    }

    private func refreshAttachedDiagnostics() {
        attachedDiagnostics.refreshPermissionState()
        attachedDiagnostics.syncSelection(
            targetWindowID: settings.attachedTargetWindowID,
            targetWindowLabel: settings.attachedTargetWindowLabel
        )
        if settings.overlayMode != .attached {
            attachedDiagnostics.markInactive(
                message: "Attached mode inactive",
                targetWindowID: settings.attachedTargetWindowID,
                targetWindowLabel: settings.attachedTargetWindowLabel
            )
        } else if !TextreamService.shared.overlayController.isShowing || TextreamService.shared.overlayController.overlayContent.attachedDiagnosticState == .inactive {
            attachedDiagnostics.beginAttachedSession(
                targetWindowID: settings.attachedTargetWindowID,
                targetWindowLabel: settings.attachedTargetWindowLabel
            )
        }
    }

    private func refreshRunningOverlayLayout() {
        TextreamService.shared.overlayController.refreshPresentationForSettingsChange()
    }
}
