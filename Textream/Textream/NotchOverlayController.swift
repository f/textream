//
//  NotchOverlayController.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import SwiftUI
import Combine

@Observable
class NotchFrameTracker {
    var visibleHeight: CGFloat = 37 {
        didSet { updatePanel() }
    }
    var visibleWidth: CGFloat = 200 {
        didSet { updatePanel() }
    }
    weak var panel: NSPanel?
    var screenMidX: CGFloat = 0
    var screenMaxY: CGFloat = 0
    var menuBarHeight: CGFloat = 0

    func updatePanel() {
        guard let panel else { return }
        let x = screenMidX - visibleWidth / 2
        let y = screenMaxY - visibleHeight
        panel.setFrame(NSRect(x: x, y: y, width: visibleWidth, height: visibleHeight), display: false)
    }
}

@Observable
class OverlayContent {
    var words: [String] = []
    var totalCharCount: Int = 0
    var hasNextPage: Bool = false
    var highlightedCharCount: Int = 0
    var trackingState: TrackingState = .tracking
    var expectedWord: String = ""
    var nextCue: String = ""
    var confidenceLevel: TrackingConfidence = .low
    var confidenceScore: Double = 0
    var manualAsideMode: ManualAsideMode = .inactive
    var trackingStatusLine: String = ""
    var partialText: String = ""
    var manualIgnoreActive: Bool = false
    var attachedDiagnosticState: AttachedDiagnosticState = .inactive
    var attachedAnchorSourceLabel: String = "Inactive"
    var attachedTargetWindowLabel: String = ""
    var attachedStatusLine: String = ""
    var attachedDetailLine: String = ""
    var attachedRequiresAttention: Bool = false

    var statusLine: String {
        attachedStatusLine.isEmpty ? trackingStatusLine : attachedStatusLine
    }

    // Page picker
    var pageCount: Int = 1
    var currentPageIndex: Int = 0
    var pagePreviews: [String] = []
    var showPagePicker: Bool = false
    var jumpToPageIndex: Int? = nil
}

class NotchOverlayController: NSObject, NSWindowDelegate {
    private enum OverlayPresentationMode: Equatable {
        case pinned
        case floating
        case floatingFollowCursor
        case fullscreen
        case attached
    }

    private var panel: NSPanel?
    let speechRecognizer: SpeechRecognizer
    let overlayContent: OverlayContent
    var onComplete: (() -> Void)?
    var onNextPage: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var isDismissing = false
    private var frameTracker: NotchFrameTracker?
    private var mouseTrackingTimer: AnyCancellable?
    private var cursorTrackingTimer: AnyCancellable?
    private var currentScreenID: UInt32 = 0
    private var stopButtonPanel: NSPanel?
    private var escMonitor: Any?
    private var activePresentationMode: OverlayPresentationMode?
    private var isUserResizingPrimaryPanel = false
    private let windowAnchorService: WindowAnchorService
    private let attachedDiagnostics: AttachedDiagnosticsStore
    private let hotkeyController: any TrackingHotkeyControlling
    private let disablePermissionOnboarding: Bool
    private var shouldDriveLiveCursorTracking: Bool {
        !AppRuntime.isHeadlessTestRuntime
    }

    private var shouldShowFloatingStopButton: Bool {
        !AppRuntime.isHeadlessTestRuntime
    }

    init(
        speechRecognizer: SpeechRecognizer = SpeechRecognizer(),
        overlayContent: OverlayContent = OverlayContent(),
        windowAnchorService: WindowAnchorService = WindowAnchorService(),
        hotkeyController: any TrackingHotkeyControlling = TrackingHotkeyController.shared,
        attachedDiagnostics: AttachedDiagnosticsStore = .shared,
        disablePermissionOnboarding: Bool = AppRuntime.isRunningUITests
    ) {
        self.speechRecognizer = speechRecognizer
        self.overlayContent = overlayContent
        self.windowAnchorService = windowAnchorService
        self.hotkeyController = hotkeyController
        self.attachedDiagnostics = attachedDiagnostics
        self.disablePermissionOnboarding = disablePermissionOnboarding
        super.init()
        speechRecognizer.onTrackingSnapshot = { [weak self] snapshot, frame in
            self?.applyTrackingSnapshot(snapshot, frame: frame)
        }
        setAnchorDebugInactive()
    }

    deinit {
        hotkeyController.stop()
        mouseTrackingTimer?.cancel()
        cursorTrackingTimer?.cancel()
        cancellables.removeAll()
        windowAnchorService.stopTracking()
        windowAnchorService.onResolutionChanged = nil
        speechRecognizer.onTrackingSnapshot = nil
        removeEscMonitor()
    }

    private func applyTrackingSnapshot(_ snapshot: TrackingSnapshot, frame: SpeechRecognitionFrame?) {
        OverlayStateProjector.apply(snapshot: snapshot, frame: frame, to: overlayContent)
    }

    private func syncAttachedStatusFromDiagnostics() {
        overlayContent.attachedDiagnosticState = attachedDiagnostics.state
        overlayContent.attachedAnchorSourceLabel = attachedDiagnostics.anchorSourceLabel
        overlayContent.attachedTargetWindowLabel = attachedDiagnostics.targetWindowLabel
        overlayContent.attachedStatusLine = attachedDiagnostics.isDegraded ? attachedDiagnostics.statusLine : ""
        overlayContent.attachedDetailLine = attachedDiagnostics.isDegraded ? attachedDiagnostics.detailLine : ""
        overlayContent.attachedRequiresAttention = attachedDiagnostics.isDegraded
    }

    private func presentAttachedPermissionOnboardingIfNeeded() {
        guard !disablePermissionOnboarding else { return }
        guard !NotchSettings.shared.hasSeenAttachedOnboarding else { return }
        NotchSettings.shared.hasSeenAttachedOnboarding = true

        let alert = NSAlert()
        alert.messageText = "Allow Accessibility for Attached Overlay"
        alert.informativeText = "Attached Overlay needs Accessibility access before it can follow another app window. Until access is granted, Textream will stay in the screen corner."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Continue with Fallback")
        if alert.runModal() == .alertFirstButtonReturn {
            WindowAnchorService.openAccessibilitySettings()
        }
    }

    func show(text: String, hasNextPage: Bool = false, onComplete: (() -> Void)? = nil) {
        self.onComplete = onComplete
        self.onNextPage = {
            TextreamService.shared.advanceToNextPage()
        }
        self.isDismissing = false
        forceClose()
        observeDismiss()

        // Populate overlay content
        let normalized = splitTextIntoWords(text)
        overlayContent.words = normalized
        overlayContent.totalCharCount = normalized.joined(separator: " ").count
        overlayContent.hasNextPage = hasNextPage
        overlayContent.highlightedCharCount = 0
        overlayContent.partialText = ""
        overlayContent.manualIgnoreActive = false
        speechRecognizer.updateText(text, preservingCharCount: 0)

        let settings = NotchSettings.shared
        let preferredScreen = preferredScreen(for: settings)
        presentOverlay(using: settings, preferredScreen: preferredScreen)

        // Word tracking & silence-paused need the microphone; classic does not
        if settings.listeningMode != .classic {
            speechRecognizer.start(with: text)
        }
        updateHotkeyRegistration(for: settings.listeningMode)
    }

    func updateContent(text: String, hasNextPage: Bool) {
        let normalized = splitTextIntoWords(text)

        // Fully reset speech state for new page
        speechRecognizer.recognizedCharCount = 0
        speechRecognizer.shouldDismiss = false
        speechRecognizer.shouldAdvancePage = false
        speechRecognizer.lastSpokenText = ""
        overlayContent.highlightedCharCount = 0
        overlayContent.partialText = ""
        overlayContent.manualIgnoreActive = false

        overlayContent.words = normalized
        overlayContent.totalCharCount = normalized.joined(separator: " ").count
        overlayContent.hasNextPage = hasNextPage
        speechRecognizer.updateText(text, preservingCharCount: 0)

        let settings = NotchSettings.shared
        if settings.listeningMode != .classic {
            speechRecognizer.start(with: text)
        }
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
    }

    private func preferredScreen(for settings: NotchSettings) -> NSScreen {
        switch settings.overlayMode {
        case .fullscreen:
            if settings.fullscreenScreenID != 0,
               let match = NSScreen.screens.first(where: { $0.displayID == settings.fullscreenScreenID }) {
                return match
            }
        case .pinned:
            if settings.notchDisplayMode == .fixedDisplay,
               let pinned = NSScreen.screens.first(where: { $0.displayID == settings.pinnedScreenID }) {
                return pinned
            }
        case .floating, .attached:
            break
        }

        if let panelScreen = panel?.screen {
            return panelScreen
        }
        return screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func desiredPresentationMode(for settings: NotchSettings) -> OverlayPresentationMode {
        switch settings.overlayMode {
        case .pinned:
            return .pinned
        case .floating:
            return settings.followCursorWhenUndocked ? .floatingFollowCursor : .floating
        case .fullscreen:
            return .fullscreen
        case .attached:
            return .attached
        }
    }

    private func presentOverlay(using settings: NotchSettings, preferredScreen: NSScreen) {
        switch desiredPresentationMode(for: settings) {
        case .fullscreen:
            setAnchorDebugInactive(message: "Attached mode inactive while fullscreen overlay is active")
            showFullscreen(settings: settings, screen: preferredScreen)
        case .attached:
            showAttached(settings: settings, fallbackScreen: preferredScreen)
        case .floatingFollowCursor:
            setAnchorDebugInactive(message: "Attached mode inactive while follow-cursor floating overlay is active")
            showFollowCursor(settings: settings, screen: preferredScreen)
            if shouldShowFloatingStopButton {
                showStopButton(on: preferredScreen)
            }
        case .pinned:
            setAnchorDebugInactive(message: "Attached mode inactive while pinned overlay is active")
            showPinned(settings: settings, screen: preferredScreen)
        case .floating:
            setAnchorDebugInactive(message: "Attached mode inactive while floating overlay is active")
            showFloating(settings: settings, screenFrame: preferredScreen.frame)
        }
    }

    func refreshPresentationForSettingsChange() {
        guard isShowing else { return }

        let settings = NotchSettings.shared
        let desiredMode = desiredPresentationMode(for: settings)
        let shouldRebuild = desiredMode == .pinned
            || desiredMode == .fullscreen
            || !canRefreshPresentationInPlace(from: activePresentationMode, to: desiredMode)

        if shouldRebuild {
            rebuildPresentation(using: settings)
            return
        }

        panel?.sharingType = settings.hideFromScreenShare ? .none : .readOnly

        switch desiredMode {
        case .floating:
            refreshFloatingPresentation(settings: settings, followingCursor: false)
        case .floatingFollowCursor:
            refreshFloatingPresentation(settings: settings, followingCursor: true)
        case .attached:
            refreshAttachedPresentation(settings: settings)
        case .pinned, .fullscreen:
            rebuildPresentation(using: settings)
        }
    }

    private func canRefreshPresentationInPlace(
        from current: OverlayPresentationMode?,
        to desired: OverlayPresentationMode
    ) -> Bool {
        switch (current, desired) {
        case (.floating, .floating),
             (.floating, .floatingFollowCursor),
             (.floatingFollowCursor, .floating),
             (.floatingFollowCursor, .floatingFollowCursor),
             (.attached, .attached):
            return true
        default:
            return false
        }
    }

    private func rebuildPresentation(using settings: NotchSettings) {
        stopMouseTracking()
        stopCursorTracking()
        removeStopButton()
        removeEscMonitor()
        windowAnchorService.stopTracking()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        frameTracker = nil
        activePresentationMode = nil

        let preferred = preferredScreen(for: settings)
        presentOverlay(using: settings, preferredScreen: preferred)
        updateHotkeyRegistration(for: settings.listeningMode)
    }

    private func startMouseTracking() {
        mouseTrackingTimer?.cancel()
        mouseTrackingTimer = Timer.publish(every: 0.3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkMouseScreen()
            }
    }

    private func stopMouseTracking() {
        mouseTrackingTimer?.cancel()
        mouseTrackingTimer = nil
    }

    private func startCursorTracking() {
        cursorTrackingTimer?.cancel()
        let interval = shouldDriveLiveCursorTracking ? (1.0 / 60.0) : 0.25
        cursorTrackingTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.shouldDriveLiveCursorTracking else { return }
                self.updateCursorPosition()
            }
    }

    private func stopCursorTracking() {
        cursorTrackingTimer?.cancel()
        cursorTrackingTimer = nil
    }

    private func updateCursorPosition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let cursorOffset: CGFloat = 8
        let x = mouse.x + cursorOffset
        let h = panel.frame.height
        let y = mouse.y - h
        let w = panel.frame.width

        var nextFrame = NSRect(x: x, y: y, width: w, height: h)

        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            nextFrame = clamp(frame: nextFrame, within: screen.visibleFrame)
            updateStopButton(on: screen)
        }

        panel.setFrame(nextFrame, display: false)
    }

    private func checkMouseScreen() {
        guard let panel, let frameTracker else { return }
        guard let mouseScreen = screenUnderMouse() else { return }
        let mouseScreenID = mouseScreen.displayID
        guard mouseScreenID != currentScreenID else { return }

        // Mouse moved to a different screen — reposition the notch
        // Keep the same panel dimensions since the SwiftUI view's menuBarHeight is fixed
        currentScreenID = mouseScreenID
        let screenFrame = mouseScreen.frame

        frameTracker.screenMidX = screenFrame.midX
        frameTracker.screenMaxY = screenFrame.maxY

        let w = frameTracker.visibleWidth
        let h = frameTracker.visibleHeight
        let x = screenFrame.midX - w / 2
        let y = screenFrame.maxY - h
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    private func refreshFloatingPresentation(settings: NotchSettings, followingCursor: Bool) {
        guard let panel else {
            rebuildPresentation(using: settings)
            return
        }

        let nextSize = CGSize(width: settings.notchWidth, height: settings.textAreaHeight)
        panel.contentView = makeFloatingPanelContentView(
            baseHeight: nextSize.height,
            followingCursor: followingCursor
        )
        panel.minSize = NSSize(width: NotchSettings.minWidth, height: NotchSettings.minHeight)
        panel.maxSize = NSSize(width: NotchSettings.maxWidth, height: NotchSettings.maxHeight)
        panel.ignoresMouseEvents = followingCursor
        panel.isMovableByWindowBackground = !followingCursor
        configureDirectResize(for: panel, enabled: !followingCursor)

        if followingCursor {
            activePresentationMode = .floatingFollowCursor
            let resized = CGRect(origin: panel.frame.origin, size: nextSize)
            panel.setFrame(resized, display: true)
            panel.orderFrontRegardless()
            startCursorTracking()
            if shouldDriveLiveCursorTracking {
                updateCursorPosition()
            }
            if shouldShowFloatingStopButton,
               let targetScreen = screenUnderMouse() ?? panel.screen ?? NSScreen.main {
                showStopButton(on: targetScreen)
            } else {
                removeStopButton()
            }
        } else {
            activePresentationMode = .floating
            stopCursorTracking()
            removeStopButton()

            let visibleFrame = (panel.screen ?? preferredScreen(for: settings)).visibleFrame
            var nextFrame = CGRect(origin: panel.frame.origin, size: nextSize)
            nextFrame = clamp(frame: nextFrame, within: visibleFrame)
            panel.setFrame(nextFrame, display: true)
        }

        installKeyMonitor()
    }

    private func refreshAttachedPresentation(settings: NotchSettings) {
        guard let panel else {
            rebuildPresentation(using: settings)
            return
        }

        activePresentationMode = .attached
        panel.minSize = NSSize(width: NotchSettings.minWidth, height: NotchSettings.minHeight)
        panel.maxSize = NSSize(width: NotchSettings.maxWidth, height: NotchSettings.maxHeight)
        configureDirectResize(for: panel, enabled: true)

        let nextSize = CGSize(width: settings.notchWidth, height: settings.textAreaHeight)
        panel.setFrame(CGRect(origin: panel.frame.origin, size: nextSize), display: true)

        attachedDiagnostics.beginAttachedSession(
            targetWindowID: settings.attachedTargetWindowID,
            targetWindowLabel: settings.attachedTargetWindowLabel
        )
        syncAttachedStatusFromDiagnostics()

        guard settings.attachedTargetWindowID != 0 else {
            windowAnchorService.stopTracking()
            let fallbackScreen = resolveFallbackScreen(preferred: preferredScreen(for: settings))
            let fallbackFrame = windowAnchorService.fallbackFrame(
                overlaySize: nextSize,
                corner: settings.attachedAnchorCorner,
                marginX: settings.attachedMarginX,
                marginY: settings.attachedMarginY,
                on: fallbackScreen
            )
            let fallbackResolution = WindowAnchorResolution(
                frame: fallbackFrame,
                window: nil,
                source: .fallback,
                isAccessibilityTrusted: WindowAnchorService.isAccessibilityTrusted(prompt: false),
                message: "No target window is selected. Using the screen corner."
            )
            updateAttachedFallbackFrame(on: fallbackScreen, resolution: fallbackResolution)
            installKeyMonitor()
            return
        }

        if windowAnchorService.trackedWindowID != settings.attachedTargetWindowID {
            windowAnchorService.startTracking(windowID: settings.attachedTargetWindowID)
        } else {
            windowAnchorService.emitCurrentResolution()
        }
        installKeyMonitor()
    }

    private func makeFloatingPanelContentView(baseHeight: CGFloat, followingCursor: Bool) -> NSView {
        if AppRuntime.isHeadlessTestRuntime {
            let placeholder = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: max(baseHeight, 1)))
            placeholder.wantsLayer = true
            placeholder.layer?.backgroundColor = NSColor.clear.cgColor
            return placeholder
        }

        let floatingView = FloatingOverlayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            baseHeight: baseHeight,
            followingCursor: followingCursor
        )
        return NSHostingView(rootView: floatingView)
    }

    private func showPinned(settings: NotchSettings, screen: NSScreen) {
        activePresentationMode = .pinned
        let notchWidth = settings.notchWidth
        let textAreaHeight = settings.textAreaHeight
        let maxExtraHeight: CGFloat = 350
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        // Menu bar / notch height from top of screen
        let menuBarHeight = screenFrame.maxY - visibleFrame.maxY

        let tracker = NotchFrameTracker()
        tracker.screenMidX = screenFrame.midX
        tracker.screenMaxY = screenFrame.maxY
        tracker.menuBarHeight = menuBarHeight
        // Set full expanded dimensions so mouse tracking uses the correct size
        tracker.visibleWidth = notchWidth
        tracker.visibleHeight = menuBarHeight + textAreaHeight
        self.frameTracker = tracker
        self.currentScreenID = screen.displayID

        let overlayView = NotchOverlayView(content: overlayContent, speechRecognizer: speechRecognizer, menuBarHeight: menuBarHeight, baseTextHeight: textAreaHeight, maxExtraHeight: maxExtraHeight, frameTracker: tracker)
        let contentView = NSHostingView(rootView: overlayView)

        // Start panel at full target size (SwiftUI animates the notch shape inside)
        let targetHeight = menuBarHeight + textAreaHeight
        let targetY = screenFrame.maxY - targetHeight
        let xPosition = screenFrame.midX - notchWidth / 2
        let panel = NSPanel(
            contentRect: NSRect(x: xPosition, y: targetY, width: notchWidth, height: targetHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        tracker.panel = panel

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false
        panel.sharingType = NotchSettings.shared.hideFromScreenShare ? .none : .readOnly
        panel.contentView = contentView

        panel.orderFrontRegardless()
        self.panel = panel

        // Start mouse tracking for follow-mouse mode
        if settings.notchDisplayMode == .followMouse {
            startMouseTracking()
        }
    }

    private func showFollowCursor(settings: NotchSettings, screen: NSScreen) {
        activePresentationMode = .floatingFollowCursor
        let panelWidth = settings.notchWidth
        let panelHeight = settings.textAreaHeight

        let mouse = NSEvent.mouseLocation
        let cursorOffset: CGFloat = 8
        let xPosition = mouse.x + cursorOffset
        let yPosition = mouse.y - panelHeight

        let contentView = makeFloatingPanelContentView(
            baseHeight: panelHeight,
            followingCursor: true
        )

        let panel = NSPanel(
            contentRect: NSRect(x: xPosition, y: yPosition, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.minSize = NSSize(width: NotchSettings.minWidth, height: NotchSettings.minHeight)
        panel.maxSize = NSSize(width: NotchSettings.maxWidth, height: NotchSettings.maxHeight)
        panel.sharingType = NotchSettings.shared.hideFromScreenShare ? .none : .readOnly
        panel.contentView = contentView
        panel.delegate = nil

        panel.orderFrontRegardless()
        self.panel = panel

        startCursorTracking()
        installKeyMonitor()
    }

    private func showFullscreen(settings: NotchSettings, screen: NSScreen) {
        activePresentationMode = .fullscreen
        let screenFrame = screen.frame

        let fullscreenView = ExternalDisplayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            mirrorAxis: nil
        )
        let contentView = NSHostingView(rootView: fullscreenView)

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
        panel.ignoresMouseEvents = false
        panel.sharingType = settings.hideFromScreenShare ? .none : .readOnly
        panel.contentView = contentView
        panel.setFrame(screenFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        installKeyMonitor()
    }

    private func showFloating(settings: NotchSettings, screenFrame: CGRect) {
        activePresentationMode = .floating
        let panelWidth = settings.notchWidth
        let panelHeight = settings.textAreaHeight

        let xPosition = screenFrame.midX - panelWidth / 2
        let yPosition = screenFrame.midY - panelHeight / 2 + 100

        let contentView = makeFloatingPanelContentView(
            baseHeight: panelHeight,
            followingCursor: false
        )

        let panel = NSPanel(
            contentRect: NSRect(x: xPosition, y: yPosition, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: NotchSettings.minWidth, height: NotchSettings.minHeight)
        panel.maxSize = NSSize(width: NotchSettings.maxWidth, height: NotchSettings.maxHeight)
        panel.sharingType = NotchSettings.shared.hideFromScreenShare ? .none : .readOnly
        panel.contentView = contentView
        panel.delegate = self

        panel.orderFrontRegardless()
        self.panel = panel

        installKeyMonitor()
    }

    private func showAttached(settings: NotchSettings, fallbackScreen: NSScreen) {
        activePresentationMode = .attached
        let panelWidth = settings.notchWidth
        let panelHeight = settings.textAreaHeight
        let fallbackFrame = windowAnchorService.fallbackFrame(
            overlaySize: CGSize(width: panelWidth, height: panelHeight),
            corner: settings.attachedAnchorCorner,
            marginX: settings.attachedMarginX,
            marginY: settings.attachedMarginY,
            on: fallbackScreen
        )

        let contentView = makeFloatingPanelContentView(
            baseHeight: panelHeight,
            followingCursor: false
        )

        let panel = NSPanel(
            contentRect: fallbackFrame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: NotchSettings.minWidth, height: NotchSettings.minHeight)
        panel.maxSize = NSSize(width: NotchSettings.maxWidth, height: NotchSettings.maxHeight)
        panel.sharingType = NotchSettings.shared.hideFromScreenShare ? .none : .readOnly
        panel.contentView = contentView
        panel.delegate = self
        panel.orderFrontRegardless()
        self.panel = panel

        attachedDiagnostics.beginAttachedSession(
            targetWindowID: settings.attachedTargetWindowID,
            targetWindowLabel: settings.attachedTargetWindowLabel
        )
        syncAttachedStatusFromDiagnostics()

        if !WindowAnchorService.isAccessibilityTrusted(prompt: false) {
            let fallbackResolution = WindowAnchorResolution(
                frame: fallbackFrame,
                window: nil,
                source: .fallback,
                isAccessibilityTrusted: false,
                message: "Accessibility access is not granted yet. Starting in the screen corner."
            )
            updateAttachedFallbackFrame(on: fallbackScreen, resolution: fallbackResolution)
            presentAttachedPermissionOnboardingIfNeeded()
        }

        windowAnchorService.onResolutionChanged = { [weak self] resolution in
            guard let self else { return }
            DispatchQueue.main.async {
                let settings = NotchSettings.shared
                let fallbackScreen = self.resolveFallbackScreen(
                    preferred: fallbackScreen,
                    targetFrame: resolution.frame ?? resolution.window?.bounds
                )
                let fallbackFrame = self.windowAnchorService.fallbackFrame(
                    overlaySize: self.panel?.frame.size ?? CGSize(width: settings.notchWidth, height: settings.textAreaHeight),
                    corner: settings.attachedAnchorCorner,
                    marginX: settings.attachedMarginX,
                    marginY: settings.attachedMarginY,
                    on: fallbackScreen
                )

                if !resolution.isAccessibilityTrusted {
                    let fallbackResolution = WindowAnchorResolution(
                        frame: fallbackFrame,
                        window: resolution.window,
                        source: .fallback,
                        isAccessibilityTrusted: false,
                        message: "Accessibility access is required. Using the screen corner."
                    )
                    self.updateAttachedFallbackFrame(on: fallbackScreen, resolution: fallbackResolution)
                    return
                }

                if let frame = resolution.frame {
                    self.applyAttachedFrame(frame, settings: settings)
                    self.attachedDiagnostics.updateResolution(
                        resolution,
                        targetWindowID: settings.attachedTargetWindowID,
                        targetWindowLabel: settings.attachedTargetWindowLabel,
                        overlayHidden: false
                    )
                    self.syncAttachedStatusFromDiagnostics()
                    QADebugStore.shared.recordAnchor(resolution)
                } else {
                    let fallbackResolution = resolution.with(
                        source: .fallback,
                        frame: fallbackFrame,
                        message: resolution.message
                    )
                    self.updateAttachedFallbackFrame(on: fallbackScreen, resolution: fallbackResolution)
                }
            }
        }

        if settings.attachedTargetWindowID != 0 {
            windowAnchorService.startTracking(windowID: settings.attachedTargetWindowID)
        } else {
            let fallbackResolution = WindowAnchorResolution(
                frame: fallbackFrame,
                window: nil,
                source: .fallback,
                isAccessibilityTrusted: WindowAnchorService.isAccessibilityTrusted(prompt: false),
                message: "No target window is selected. Using the screen corner."
            )
            updateAttachedFallbackFrame(on: fallbackScreen, resolution: fallbackResolution)
        }

        installKeyMonitor()
    }

    private func applyAttachedFrame(_ targetFrame: CGRect, settings: NotchSettings) {
        guard let panel else { return }
        let overlaySize = CGSize(width: panel.frame.width, height: panel.frame.height)
        let targetVisibleFrame = windowAnchorService.screen(
            for: targetFrame,
            corner: settings.attachedAnchorCorner
        )?.visibleFrame
        let origin = windowAnchorService.anchoredOrigin(
            targetFrame: targetFrame,
            overlaySize: overlaySize,
            corner: settings.attachedAnchorCorner,
            marginX: settings.attachedMarginX,
            marginY: settings.attachedMarginY,
            within: targetVisibleFrame
        )
        let nextFrame = CGRect(origin: origin, size: overlaySize)
        panel.setFrame(nextFrame, display: true)
        panel.alphaValue = 1
    }

    private func updateAttachedFallbackFrame(on _: NSScreen, resolution: WindowAnchorResolution) {
        guard let panel else { return }
        let settings = NotchSettings.shared
        let shouldForceVisibleFallback = !resolution.isAccessibilityTrusted || settings.attachedTargetWindowID == 0
        let isWindowAvailable = resolution.window != nil && resolution.source != .fallback && resolution.source != .unavailable

        if !shouldForceVisibleFallback &&
            !isWindowAvailable &&
            settings.attachedHideWhenWindowUnavailable &&
            settings.attachedFallbackBehavior == .hideOverlay {
            panel.alphaValue = 0
            let hiddenResolution = resolution.with(message: "\(resolution.message) Overlay hidden by attached fallback policy")
            attachedDiagnostics.updateResolution(
                hiddenResolution,
                targetWindowID: settings.attachedTargetWindowID,
                targetWindowLabel: settings.attachedTargetWindowLabel,
                overlayHidden: true
            )
            syncAttachedStatusFromDiagnostics()
            QADebugStore.shared.recordAnchor(hiddenResolution)
            return
        }

        if shouldForceVisibleFallback || settings.attachedFallbackBehavior == .screenCorner {
            panel.setFrame(resolution.frame ?? panel.frame, display: true)
            panel.alphaValue = 1
        } else {
            panel.alphaValue = isWindowAvailable ? 1 : 0
        }

        attachedDiagnostics.updateResolution(
            resolution,
            targetWindowID: settings.attachedTargetWindowID,
            targetWindowLabel: settings.attachedTargetWindowLabel,
            overlayHidden: panel.alphaValue == 0
        )
        syncAttachedStatusFromDiagnostics()
        QADebugStore.shared.recordAnchor(resolution)
    }

    private func startHotkeys() {
        hotkeyController.onToggleAside = { [weak self] in
            self?.speechRecognizer.toggleAsideMode()
        }
        hotkeyController.onHoldIgnoreChanged = { [weak self] active in
            self?.speechRecognizer.setTemporaryIgnoreActive(active)
        }
        hotkeyController.start()
    }

    private func updateHotkeyRegistration(for listeningMode: ListeningMode) {
        if listeningMode == .wordTracking {
            startHotkeys()
        } else {
            hotkeyController.stop()
        }
    }

    private func completeOverlayDismissal(anchorMessage: String) {
        stopMouseTracking()
        stopCursorTracking()
        removeStopButton()
        removeEscMonitor()
        cancellables.removeAll()
        windowAnchorService.stopTracking()
        windowAnchorService.onResolutionChanged = nil
        setAnchorDebugInactive(message: anchorMessage)
        hotkeyController.stop()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        frameTracker = nil
        activePresentationMode = nil
        speechRecognizer.shouldDismiss = false
        isDismissing = false
        onComplete?()
    }

    func dismiss() {
        guard panel != nil, !isDismissing else { return }
        isDismissing = true

        // Trigger the shrink animation
        speechRecognizer.shouldDismiss = true
        speechRecognizer.forceStop()
        hotkeyController.stop()
        windowAnchorService.stopTracking()
        setAnchorDebugInactive(message: "Overlay dismissed")

        let finalize = { [weak self] in
            self?.completeOverlayDismissal(anchorMessage: "Overlay dismissed")
        }
        if AppRuntime.isHeadlessTestRuntime {
            finalize()
        } else {
            // Wait for animation, then remove panel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                finalize()
            }
        }
    }

    private func installKeyMonitor() {
        removeEscMonitor()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // ESC
                if self.overlayContent.showPagePicker {
                    self.overlayContent.showPagePicker = false
                    return nil
                }
                self.dismiss()
                return nil
            }
            return event
        }
    }

    private func forceClose() {
        stopMouseTracking()
        stopCursorTracking()
        removeStopButton()
        removeEscMonitor()
        cancellables.removeAll()
        windowAnchorService.stopTracking()
        windowAnchorService.onResolutionChanged = nil
        setAnchorDebugInactive(message: "Overlay force-closed")
        hotkeyController.stop()
        speechRecognizer.forceStop()
        speechRecognizer.recognizedCharCount = 0
        overlayContent.highlightedCharCount = 0
        overlayContent.partialText = ""
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        frameTracker = nil
        activePresentationMode = nil
        isDismissing = false
        speechRecognizer.shouldDismiss = false
        speechRecognizer.shouldAdvancePage = false
    }

    private func observeDismiss() {
        // Poll for shouldAdvancePage (next page requested from overlay)
        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                if self.speechRecognizer.shouldAdvancePage {
                    self.speechRecognizer.shouldAdvancePage = false
                    self.onNextPage?()
                }
                // Poll for page jump from page picker
                if let targetIndex = self.overlayContent.jumpToPageIndex {
                    self.overlayContent.jumpToPageIndex = nil
                    TextreamService.shared.jumpToPage(index: targetIndex)
                }
            }
            .store(in: &cancellables)

        // Poll for shouldDismiss becoming true (from view setting it on completion)
        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.speechRecognizer.shouldDismiss, !self.isDismissing else { return }
                self.isDismissing = true
                let finalize = {
                    self.completeOverlayDismissal(anchorMessage: "Overlay dismissed after completion")
                }
                if AppRuntime.isHeadlessTestRuntime {
                    finalize()
                } else {
                    // Wait for shrink animation, then cleanup
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        finalize()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func resolveFallbackScreen(preferred: NSScreen, targetFrame: CGRect? = nil) -> NSScreen {
        if let targetFrame, let targetScreen = windowAnchorService.screen(for: targetFrame) {
            return targetScreen
        }
        if let panelScreen = panel?.screen {
            return panelScreen
        }
        return NSScreen.main ?? preferred
    }

    private func setAnchorDebugInactive(message: String = "Attached mode inactive") {
        attachedDiagnostics.markInactive(
            message: message,
            targetWindowID: NotchSettings.shared.attachedTargetWindowID,
            targetWindowLabel: NotchSettings.shared.attachedTargetWindowLabel
        )
        syncAttachedStatusFromDiagnostics()
        QADebugStore.shared.recordAnchor(
            WindowAnchorResolution(
                frame: nil,
                window: nil,
                source: .unavailable,
                isAccessibilityTrusted: WindowAnchorService.isAccessibilityTrusted(prompt: false),
                message: message
            )
        )
    }

    var isShowing: Bool {
        panel != nil
    }

    var debugPanelFrame: CGRect? {
        panel?.frame
    }

    var debugPanelAlpha: CGFloat {
        panel?.alphaValue ?? 0
    }

    var debugHotkeysRunning: Bool {
        hotkeyController.isRunning
    }

    var debugCursorTrackingRunning: Bool {
        cursorTrackingTimer != nil
    }

    var debugPresentationMode: String {
        switch activePresentationMode {
        case .pinned: return "pinned"
        case .floating: return "floating"
        case .floatingFollowCursor: return "floatingFollowCursor"
        case .fullscreen: return "fullscreen"
        case .attached: return "attached"
        case nil: return "inactive"
        }
    }

    var debugTrackedWindowID: Int? {
        windowAnchorService.trackedWindowID
    }

    func debugRefreshAttachedResolution() {
        windowAnchorService.emitCurrentResolution()
    }

    func debugSimulateUserResize(to size: CGSize) {
        guard let panel else { return }
        isUserResizingPrimaryPanel = true
        panel.setFrame(CGRect(origin: panel.frame.origin, size: size), display: true)
        syncPanelSizeToSettings(from: panel)
        isUserResizingPrimaryPanel = false
        if activePresentationMode == .attached {
            refreshAttachedPresentation(settings: NotchSettings.shared)
        }
    }

    func debugUpdateHotkeyRegistration(for listeningMode: ListeningMode) {
        updateHotkeyRegistration(for: listeningMode)
    }

    // MARK: - Floating Stop Button

    private func showStopButton(on screen: NSScreen) {
        if let stopButtonPanel {
            stopButtonPanel.setFrame(stopButtonFrame(on: screen), display: true)
            return
        }

        let stopView = NSHostingView(rootView: StopButtonView {
            self.dismiss()
        })

        let panel = NSPanel(
            contentRect: stopButtonFrame(on: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.sharingType = .none
        panel.contentView = stopView
        panel.orderFrontRegardless()
        stopButtonPanel = panel
    }

    private func removeStopButton() {
        stopButtonPanel?.contentView = nil
        stopButtonPanel?.close()
        stopButtonPanel = nil
    }

    private func stopButtonFrame(on screen: NSScreen) -> CGRect {
        let buttonSize: CGFloat = 36
        let margin: CGFloat = 8
        let screenFrame = screen.frame
        let menuBarBottom = screen.visibleFrame.maxY
        let x = screenFrame.midX - buttonSize / 2
        let y = menuBarBottom - buttonSize - margin
        return CGRect(x: x, y: y, width: buttonSize, height: buttonSize)
    }

    private func updateStopButton(on screen: NSScreen) {
        guard let stopButtonPanel else { return }
        stopButtonPanel.setFrame(stopButtonFrame(on: screen), display: true)
    }

    private func configureDirectResize(for panel: NSPanel, enabled: Bool) {
        var styleMask = panel.styleMask
        if enabled {
            styleMask.insert(.resizable)
            panel.delegate = self
        } else {
            styleMask.remove(.resizable)
            if panel.delegate === self {
                panel.delegate = nil
            }
        }
        panel.styleMask = styleMask
    }

    private func syncPanelSizeToSettings(from window: NSWindow) {
        guard window === panel else { return }

        let settings = NotchSettings.shared
        guard activePresentationMode == .floating || activePresentationMode == .attached else { return }
        guard activePresentationMode != .floatingFollowCursor else { return }

        let clampedWidth = min(max(window.frame.width, NotchSettings.minWidth), NotchSettings.maxWidth)
        let clampedHeight = min(max(window.frame.height, NotchSettings.minHeight), NotchSettings.maxHeight)

        if abs(settings.notchWidth - clampedWidth) > 0.5 {
            settings.notchWidth = clampedWidth
        }
        if abs(settings.textAreaHeight - clampedHeight) > 0.5 {
            settings.textAreaHeight = clampedHeight
        }
    }

    private func clamp(frame: CGRect, within visibleFrame: CGRect) -> CGRect {
        guard !visibleFrame.isEmpty else { return frame }

        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - height)

        return CGRect(
            x: min(max(frame.minX, visibleFrame.minX), maxX),
            y: min(max(frame.minY, visibleFrame.minY), maxY),
            width: width,
            height: height
        )
    }

    private func removeEscMonitor() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
        }
        escMonitor = nil
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard notification.object as AnyObject? === panel else { return }
        isUserResizingPrimaryPanel = true
    }

    func windowDidResize(_ notification: Notification) {
        guard isUserResizingPrimaryPanel,
              let window = notification.object as? NSWindow else { return }
        syncPanelSizeToSettings(from: window)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        syncPanelSizeToSettings(from: window)
        isUserResizingPrimaryPanel = false

        if activePresentationMode == .attached {
            refreshAttachedPresentation(settings: NotchSettings.shared)
        }
    }
}

// MARK: - Floating Stop Button View

struct StopButtonView: View {
    let onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.red.opacity(0.85))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dynamic Island Shape (concave top corners, convex bottom corners)

struct DynamicIslandShape: Shape {
    var topInset: CGFloat = 16
    var bottomRadius: CGFloat = 18

    // Enable smooth animation by providing animatable data
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topInset, bottomRadius) }
        set {
            topInset = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let t = topInset
        let br = bottomRadius
        var p = Path()

        // Start at top-left corner
        p.move(to: CGPoint(x: 0, y: 0))

        // Top-left curve: from (0,0) curve down-right to (t, t)
        // Control at (t, 0) makes it bow DOWNWARD (like DynamicNotchKit)
        p.addQuadCurve(
            to: CGPoint(x: t, y: t),
            control: CGPoint(x: t, y: 0)
        )

        // Left edge down
        p.addLine(to: CGPoint(x: t, y: h - br))

        // Bottom-left convex corner
        p.addQuadCurve(
            to: CGPoint(x: t + br, y: h),
            control: CGPoint(x: t, y: h)
        )

        // Bottom edge
        p.addLine(to: CGPoint(x: w - t - br, y: h))

        // Bottom-right convex corner
        p.addQuadCurve(
            to: CGPoint(x: w - t, y: h - br),
            control: CGPoint(x: w - t, y: h)
        )

        // Right edge up
        p.addLine(to: CGPoint(x: w - t, y: t))

        // Top-right curve: from (w-t, t) curve up-right to (w, 0)
        // Control at (w-t, 0) makes it bow DOWNWARD
        p.addQuadCurve(
            to: CGPoint(x: w, y: 0),
            control: CGPoint(x: w - t, y: 0)
        )

        // Top edge back to start
        p.closeSubpath()
        return p
    }
}

// MARK: - Overlay SwiftUI View

struct NotchOverlayView: View {
    @Bindable var content: OverlayContent
    @Bindable var speechRecognizer: SpeechRecognizer
    let menuBarHeight: CGFloat
    let baseTextHeight: CGFloat
    let maxExtraHeight: CGFloat
    var frameTracker: NotchFrameTracker

    private var words: [String] { content.words }
    private var totalCharCount: Int { content.totalCharCount }
    private var hasNextPage: Bool { content.hasNextPage }

    // Animation state - 0.0 = notch size, 1.0 = full size
    @State private var expansion: CGFloat = 0
    @State private var contentVisible = false
    @State private var extraHeight: CGFloat = 0
    @State private var dragStartHeight: CGFloat = -1
    @State private var isHovering: Bool = false

    // Timer-based scroll for classic & silence-paused modes
    @State private var timerWordProgress: Double = 0
    @State private var isPaused: Bool = false
    @State private var isUserScrolling: Bool = false
    private let scrollTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    // Auto next page countdown
    @State private var countdownRemaining: Int = 0
    @State private var countdownTimer: Timer? = nil

    private let topInset: CGFloat = 16
    private let collapsedInset: CGFloat = 8

    // macOS notch dimensions (approximate)
    private let notchHeight: CGFloat = 37
    private let notchWidth: CGFloat = 200  // Hardware notch is ~200px wide

    private var listeningMode: ListeningMode {
        NotchSettings.shared.listeningMode
    }

    private var hudItems: [HUDPresentationItem] {
        PersistentHUDPresenter.items(
            content: content,
            isListening: speechRecognizer.isListening,
            configuration: HUDPresentationConfiguration(
                isEnabled: NotchSettings.shared.persistentHUDEnabled,
                modules: NotchSettings.shared.hudModules
            )
        )
    }

    /// Convert fractional word index to char offset using actual word lengths
    private func charOffsetForWordProgress(_ progress: Double) -> Int {
        let wholeWord = Int(progress)
        let frac = progress - Double(wholeWord)
        var offset = 0
        for i in 0..<min(wholeWord, words.count) {
            offset += words[i].count + 1 // +1 for space
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
            return content.highlightedCharCount
        case .classic, .silencePaused:
            return charOffsetForWordProgress(timerWordProgress)
        }
    }

    var isDone: Bool {
        totalCharCount > 0 && effectiveCharCount >= totalCharCount
    }

    // Interpolated values based on expansion
    private var currentTopInset: CGFloat {
        collapsedInset + (topInset - collapsedInset) * expansion
    }

    private var currentBottomRadius: CGFloat {
        8 + (18 - 8) * expansion
    }

    var body: some View {
        GeometryReader { geo in
            let targetHeight = menuBarHeight + baseTextHeight + extraHeight
            let currentHeight = notchHeight + (targetHeight - notchHeight) * expansion
            let currentWidth = notchWidth + (geo.size.width - notchWidth) * expansion

            ZStack(alignment: .top) {
                // Container shape
                DynamicIslandShape(
                    topInset: currentTopInset,
                    bottomRadius: currentBottomRadius
                )
                .fill(.black)
                .frame(width: currentWidth, height: currentHeight)

                // Content - appears after container expands
                if contentVisible {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            if NotchSettings.shared.showElapsedTime {
                                ElapsedTimeView(fontSize: 11)
                                    .padding(.trailing, 12)
                            }
                        }
                        .frame(height: menuBarHeight)

                        if content.showPagePicker {
                            pagePickerView
                        } else if isDone {
                            doneView
                        } else {
                            prompterView
                        }
                    }
                    .padding(.horizontal, topInset)
                    .frame(width: currentWidth, height: targetHeight)
                    .clipped()
                    .transition(.opacity)
                }
            }
            .frame(width: currentWidth, height: currentHeight, alignment: .top)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .onChange(of: extraHeight) { _, _ in updateFrameTracker() }
        .onAppear {
            // Phase 1: Expand container with smooth easing
            withAnimation(.easeOut(duration: 0.4)) {
                expansion = 1
            }
            // Phase 2: Show content after container expands
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeOut(duration: 0.25)) {
                    contentVisible = true
                }
            }
        }
        .onChange(of: speechRecognizer.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss {
                // Reverse: hide content first, then shrink container
                withAnimation(.easeIn(duration: 0.15)) {
                    contentVisible = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.easeIn(duration: 0.3)) {
                        expansion = 0
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.5), value: isDone)
        .onChange(of: isDone) { _, done in
            if done {
                // Stop listening when page is done
                speechRecognizer.stop()
                if !hasNextPage {
                    // Show "Done" briefly, then auto-dismiss
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        speechRecognizer.shouldDismiss = true
                    }
                } else if NotchSettings.shared.autoNextPage {
                    startCountdown()
                }
            } else {
                cancelCountdown()
            }
        }
        .onReceive(scrollTimer) { _ in
            guard !isDone, !isUserScrolling else { return }
            let speed = NotchSettings.shared.scrollSpeed // words per second
            switch listeningMode {
            case .classic:
                if !isPaused {
                    timerWordProgress += speed * 0.05
                }
            case .silencePaused:
                if !isPaused && speechRecognizer.isListening && speechRecognizer.isSpeaking {
                    timerWordProgress += speed * 0.05
                }
            case .wordTracking:
                break
            }
        }
        .onChange(of: content.totalCharCount) { _, _ in
            timerWordProgress = 0
        }
    }

    private func updateFrameTracker() {
        let targetHeight = menuBarHeight + baseTextHeight + extraHeight
        let fullWidth = NotchSettings.shared.notchWidth
        frameTracker.visibleHeight = targetHeight
        frameTracker.visibleWidth = fullWidth
    }

    private var isEffectivelyListening: Bool {
        switch listeningMode {
        case .wordTracking, .silencePaused:
            return speechRecognizer.isListening
        case .classic:
            return !isPaused
        }
    }

    private var shouldShowStatusBlock: Bool {
        listeningMode == .wordTracking || content.attachedRequiresAttention
    }

    private var secondaryStatusText: String {
        if content.attachedRequiresAttention {
            return content.attachedDetailLine
        }
        return speechRecognizer.lastSpokenText.split(separator: " ").suffix(4).joined(separator: " ")
    }

    private var prompterView: some View {
        VStack(spacing: 0) {
            SpeechScrollView(
                words: words,
                highlightedCharCount: effectiveCharCount,
                font: NotchSettings.shared.font,
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
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))

            Group {
            HStack(alignment: .center, spacing: 8) {
                AudioWaveformProgressView(
                    levels: speechRecognizer.audioLevels,
                    progress: totalCharCount > 0
                        ? Double(effectiveCharCount) / Double(totalCharCount)
                        : 0
                )
                .frame(width: 80, height: 24)
                .clipped()

                if shouldShowStatusBlock {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(content.statusLine.isEmpty ? content.trackingState.label : content.statusLine)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        if !secondaryStatusText.isEmpty {
                            Text(secondaryStatusText)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.38))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }

                if content.pageCount > 1 {
                    if hasNextPage {
                        Button {
                            speechRecognizer.shouldAdvancePage = true
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    content.showPagePicker = true
                                }
                        )
                    } else {
                        Button {
                            content.jumpToPageIndex = 0
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    content.showPagePicker = true
                                }
                        )
                    }
                }

                if listeningMode == .classic {
                    Button {
                        isPaused.toggle()
                    } label: {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isPaused ? .white.opacity(0.6) : .yellow.opacity(0.8))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        if speechRecognizer.isListening {
                            speechRecognizer.stop()
                        } else {
                            speechRecognizer.resume()
                        }
                    } label: {
                        Image(systemName: speechRecognizer.isListening ? "mic.fill" : "mic.slash.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(speechRecognizer.isListening ? .yellow.opacity(0.8) : .white.opacity(0.6))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    speechRecognizer.forceStop()
                    speechRecognizer.shouldDismiss = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.15))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 24)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            if !hudItems.isEmpty {
                PersistentHUDStripView(items: hudItems, compact: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            if NotchSettings.shared.qaDebugOverlayEnabled {
                QADebugOverlayView(speechRecognizer: speechRecognizer, compact: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            // Resize handle - only visible on hover
            if isHovering {
                VStack(spacing: 0) {
                    Spacer().frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 36, height: 4)
                    Spacer().frame(height: 8)
                }
                .frame(height: 16)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in
                            if dragStartHeight < 0 {
                                dragStartHeight = extraHeight
                            }
                            let newExtra = dragStartHeight + value.translation.height
                            extraHeight = max(0, min(maxExtraHeight, newExtra))
                        }
                        .onEnded { _ in
                            dragStartHeight = -1
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeUpDown.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHovering = hovering
                }
            }
            .transition(.opacity)
        }
    }

    private var pagePickerView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Jump to page")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 2)

                ForEach(0..<content.pageCount, id: \.self) { i in
                    let preview = i < content.pagePreviews.count ? content.pagePreviews[i] : ""
                    if !preview.isEmpty {
                        Button {
                            content.jumpToPageIndex = i
                            content.showPagePicker = false
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(i + 1)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(i == content.currentPageIndex ? .yellow : .white.opacity(0.8))
                                    .frame(width: 20)
                                Text(preview)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(i == content.currentPageIndex ? .yellow.opacity(0.7) : .white.opacity(0.5))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(i == content.currentPageIndex ? Color.yellow.opacity(0.1) : Color.white.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Tap a page to jump")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .transition(.opacity)
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownRemaining = NotchSettings.shared.autoNextPageDelay
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            DispatchQueue.main.async {
                countdownRemaining -= 1
                if countdownRemaining <= 0 {
                    timer.invalidate()
                    countdownTimer = nil
                    speechRecognizer.shouldAdvancePage = true
                }
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
    }

    private var doneView: some View {
        VStack {
            Spacer()
            if hasNextPage {
                VStack(spacing: 6) {
                    if countdownRemaining > 0 {
                        Text("\(countdownRemaining)")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.3), value: countdownRemaining)
                    }
                    Button {
                        cancelCountdown()
                        speechRecognizer.shouldAdvancePage = true
                    } label: {
                        VStack(spacing: 4) {
                            Text("Next Page")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                            Image(systemName: "forward.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Done!")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            Spacer()
        }
        .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Glass Effect View

struct GlassEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

// MARK: - Floating Overlay View

struct FloatingOverlayView: View {
    @Bindable var content: OverlayContent
    @Bindable var speechRecognizer: SpeechRecognizer
    let baseHeight: CGFloat
    var followingCursor: Bool = false

    private var words: [String] { content.words }
    private var totalCharCount: Int { content.totalCharCount }
    private var hasNextPage: Bool { content.hasNextPage }

    @State private var appeared = false

    // Auto-advance countdown for follow-cursor mode (where buttons can't be clicked)
    @State private var countdownRemaining: Int = 0
    @State private var countdownTimer: Timer? = nil

    // Timer-based scroll for classic & silence-paused modes
    @State private var timerWordProgress: Double = 0
    @State private var isPaused: Bool = false
    @State private var isUserScrolling: Bool = false
    private let scrollTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var listeningMode: ListeningMode {
        NotchSettings.shared.listeningMode
    }

    private var hudItems: [HUDPresentationItem] {
        PersistentHUDPresenter.items(
            content: content,
            isListening: speechRecognizer.isListening,
            configuration: HUDPresentationConfiguration(
                isEnabled: NotchSettings.shared.persistentHUDEnabled,
                modules: NotchSettings.shared.hudModules
            )
        )
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
            return content.highlightedCharCount
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
            return !isPaused
        }
    }

    private var shouldShowStatusBlock: Bool {
        listeningMode == .wordTracking || content.attachedRequiresAttention
    }

    private var secondaryStatusText: String {
        if content.attachedRequiresAttention {
            return content.attachedDetailLine
        }
        return speechRecognizer.lastSpokenText.split(separator: " ").suffix(4).joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 0) {
            if content.showPagePicker {
                floatingPagePickerView
            } else if isDone {
                floatingDoneView
            } else {
                floatingPrompterView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if NotchSettings.shared.showElapsedTime {
                ElapsedTimeView(fontSize: 11)
                    .padding(.top, 6)
                    .padding(.trailing, 10)
            }
        }
        .background(
            Group {
                if NotchSettings.shared.floatingGlassEffect {
                    ZStack {
                        GlassEffectView()
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.black.opacity(NotchSettings.shared.glassOpacity))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.black)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.9)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) {
                appeared = true
            }
        }
        .onChange(of: speechRecognizer.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss {
                withAnimation(.easeIn(duration: 0.25)) {
                    appeared = false
                }
            }
        }
        .animation(.easeInOut(duration: 0.5), value: isDone)
        .onChange(of: isDone) { _, done in
            if done {
                // Stop listening when page is done
                speechRecognizer.stop()
                if !hasNextPage {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        speechRecognizer.shouldDismiss = true
                    }
                } else if followingCursor || NotchSettings.shared.autoNextPage {
                    startCountdown()
                }
            } else {
                cancelCountdown()
            }
        }
        .onReceive(scrollTimer) { _ in
            guard !isDone, !isUserScrolling else { return }
            let speed = NotchSettings.shared.scrollSpeed // words per second
            switch listeningMode {
            case .classic:
                if !isPaused {
                    timerWordProgress += speed * 0.05
                }
            case .silencePaused:
                if !isPaused && speechRecognizer.isListening && speechRecognizer.isSpeaking {
                    timerWordProgress += speed * 0.05
                }
            case .wordTracking:
                break
            }
        }
        .onChange(of: content.totalCharCount) { _, _ in
            timerWordProgress = 0
        }
    }

    private var floatingPrompterView: some View {
        VStack(spacing: 0) {
            SpeechScrollView(
                words: words,
                highlightedCharCount: effectiveCharCount,
                font: NotchSettings.shared.font,
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
            .padding(.horizontal, 16)
            .padding(.top, 12)

            HStack(alignment: .center, spacing: 8) {
                AudioWaveformProgressView(
                    levels: speechRecognizer.audioLevels,
                    progress: totalCharCount > 0
                        ? Double(effectiveCharCount) / Double(totalCharCount)
                        : 0
                )
                .frame(width: 160, height: 24)

                if shouldShowStatusBlock {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(content.statusLine.isEmpty ? content.trackingState.label : content.statusLine)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                        if !secondaryStatusText.isEmpty {
                            Text(secondaryStatusText)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.38))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer()
                }

                if !followingCursor && content.pageCount > 1 {
                    if hasNextPage {
                        Button {
                            speechRecognizer.shouldAdvancePage = true
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    content.showPagePicker = true
                                }
                        )
                    } else {
                        Button {
                            content.jumpToPageIndex = 0
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    content.showPagePicker = true
                                }
                        )
                    }
                }

                if !followingCursor {
                    if listeningMode == .classic {
                        Button {
                            isPaused.toggle()
                        } label: {
                            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isPaused ? .white.opacity(0.6) : .yellow.opacity(0.8))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            if speechRecognizer.isListening {
                                speechRecognizer.stop()
                            } else {
                                speechRecognizer.resume()
                            }
                        } label: {
                            Image(systemName: speechRecognizer.isListening ? "mic.fill" : "mic.slash.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(speechRecognizer.isListening ? .yellow.opacity(0.8) : .white.opacity(0.6))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        speechRecognizer.forceStop()
                        speechRecognizer.shouldDismiss = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 24)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if !hudItems.isEmpty {
                PersistentHUDStripView(items: hudItems, compact: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            if NotchSettings.shared.qaDebugOverlayEnabled {
                QADebugOverlayView(speechRecognizer: speechRecognizer, compact: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownRemaining = NotchSettings.shared.autoNextPageDelay
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            DispatchQueue.main.async {
                countdownRemaining -= 1
                if countdownRemaining <= 0 {
                    timer.invalidate()
                    countdownTimer = nil
                    speechRecognizer.shouldAdvancePage = true
                }
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
    }

    private var floatingPagePickerView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Jump to page")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 4)

                ForEach(0..<content.pageCount, id: \.self) { i in
                    let preview = i < content.pagePreviews.count ? content.pagePreviews[i] : ""
                    if !preview.isEmpty {
                        Button {
                            content.jumpToPageIndex = i
                            content.showPagePicker = false
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(i + 1)")
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundStyle(i == content.currentPageIndex ? .yellow : .white.opacity(0.8))
                                    .frame(width: 24)
                                Text(preview)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(i == content.currentPageIndex ? .yellow.opacity(0.7) : .white.opacity(0.5))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(i == content.currentPageIndex ? Color.yellow.opacity(0.1) : Color.white.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Tap a page to jump")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .transition(.opacity)
    }

    private var floatingDoneView: some View {
        VStack {
            Spacer()
            if hasNextPage {
                VStack(spacing: 6) {
                    if countdownRemaining > 0 {
                        Text("\(countdownRemaining)")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.3), value: countdownRemaining)
                    }
                    if followingCursor {
                        Text("Next Page")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Button {
                            cancelCountdown()
                            speechRecognizer.shouldAdvancePage = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Next Page")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Done!")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            Spacer()
        }
        .transition(.scale.combined(with: .opacity))
    }
}
