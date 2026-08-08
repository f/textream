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

    // Page picker
    var pageCount: Int = 1
    var currentPageIndex: Int = 0
    var pagePreviews: [String] = []
    var showPagePicker: Bool = false
    var jumpToPageIndex: Int? = nil
}

class NotchOverlayController: NSObject {
    private let cursorOffset: CGFloat = 8
    private let screenEdgeMargin: CGFloat = 5
    private var panel: NSPanel?
    let speechRecognizer = SpeechRecognizer()
    let overlayContent = OverlayContent()
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

        let settings = NotchSettings.shared

        let screen: NSScreen
        switch settings.notchDisplayMode {
        case .followMouse:
            screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens[0]
        case .fixedDisplay:
            screen = NSScreen.screens.first(where: { $0.displayID == settings.pinnedScreenID }) ?? NSScreen.main ?? NSScreen.screens[0]
        }

        let screenFrame = screen.frame

        if settings.overlayMode == .fullscreen {
            let fsScreen: NSScreen
            if settings.fullscreenScreenID != 0,
               let match = NSScreen.screens.first(where: { $0.displayID == settings.fullscreenScreenID }) {
                fsScreen = match
            } else {
                fsScreen = screen
            }
            showFullscreen(settings: settings, screen: fsScreen)
        } else if settings.overlayMode == .floating && settings.followCursorWhenUndocked {
            showFollowCursor(settings: settings, screen: screen)
        } else {
            switch settings.overlayMode {
            case .pinned:
                showPinned(settings: settings, screen: screen)
            case .floating:
                showFloating(settings: settings, screenFrame: screenFrame)
            case .fullscreen:
                break // handled above
            }
        }

        // Show floating stop button only in follow-cursor mode (panel ignores mouse events)
        if settings.overlayMode == .floating && settings.followCursorWhenUndocked {
            showStopButton(on: screen)
        }

        // Word tracking & silence-paused need the microphone; classic does not
        if settings.listeningMode != .classic {
            speechRecognizer.start(with: text)
        }
    }

    func updateContent(text: String, hasNextPage: Bool) {
        let normalized = splitTextIntoWords(text)

        // Fully reset speech state for new page
        speechRecognizer.recognizedCharCount = 0
        speechRecognizer.shouldDismiss = false
        speechRecognizer.shouldAdvancePage = false
        speechRecognizer.lastSpokenText = ""

        overlayContent.words = normalized
        overlayContent.totalCharCount = normalized.joined(separator: " ").count
        overlayContent.hasNextPage = hasNextPage

        let settings = NotchSettings.shared
        if settings.listeningMode != .classic {
            speechRecognizer.start(with: text)
        }
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
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
        cursorTrackingTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateCursorPosition()
            }
    }

    private func stopCursorTracking() {
        cursorTrackingTimer?.cancel()
        cursorTrackingTimer = nil
    }

    private func updateCursorPosition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = screenUnderMouse() ?? panel.screen ?? NSScreen.main else { return }
        let frame = cursorFollowingFrame(mouse: mouse, panelSize: panel.frame.size, screen: screen)
        panel.setFrame(frame, display: false)
    }

    private func cursorFollowingFrame(mouse: NSPoint, panelSize: NSSize, screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame

        let minimumX = screenFrame.minX + screenEdgeMargin
        let maximumX = max(minimumX, screenFrame.maxX - panelSize.width - screenEdgeMargin)
        let x = min(max(mouse.x + cursorOffset, minimumX), maximumX)

        let minimumY = screenFrame.minY + screenEdgeMargin
        let maximumY = max(minimumY, screen.visibleFrame.maxY - panelSize.height)
        let y = min(max(mouse.y - panelSize.height, minimumY), maximumY)

        return NSRect(origin: NSPoint(x: x, y: y), size: panelSize)
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

    private func showPinned(settings: NotchSettings, screen: NSScreen) {
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

        installKeyMonitor()
    }

    private func showFollowCursor(settings: NotchSettings, screen: NSScreen) {
        let panelWidth = settings.notchWidth
        let panelHeight = settings.textAreaHeight

        let mouse = NSEvent.mouseLocation
        let cursorScreen = screenUnderMouse() ?? screen
        let initialFrame = cursorFollowingFrame(
            mouse: mouse,
            panelSize: NSSize(width: panelWidth, height: panelHeight),
            screen: cursorScreen
        )

        let floatingView = FloatingOverlayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            baseHeight: panelHeight,
            followingCursor: true
        )
        let contentView = NSHostingView(rootView: floatingView)

        let panel = NSPanel(
            contentRect: initialFrame,
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
        panel.sharingType = NotchSettings.shared.hideFromScreenShare ? .none : .readOnly
        panel.contentView = contentView

        panel.orderFrontRegardless()
        self.panel = panel

        startCursorTracking()
        installKeyMonitor()
    }

    private func showFullscreen(settings: NotchSettings, screen: NSScreen) {
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
        let panelWidth = settings.notchWidth
        let panelHeight = settings.textAreaHeight

        let xPosition = screenFrame.midX - panelWidth / 2
        let yPosition = screenFrame.midY - panelHeight / 2 + 100

        let floatingView = FloatingOverlayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            baseHeight: panelHeight
        )
        let contentView = NSHostingView(rootView: floatingView)

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
        panel.minSize = NSSize(width: 280, height: panelHeight)
        panel.maxSize = NSSize(width: 500, height: panelHeight + 350)
        panel.sharingType = NotchSettings.shared.hideFromScreenShare ? .none : .readOnly
        panel.contentView = contentView

        panel.orderFrontRegardless()
        self.panel = panel

        installKeyMonitor()
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true

        // Trigger the shrink animation
        speechRecognizer.shouldDismiss = true
        speechRecognizer.forceStop()

        // Wait for animation, then remove panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.stopMouseTracking()
            self.stopCursorTracking()
            self.removeStopButton()
            self.removeEscMonitor()
            self.cancellables.removeAll()
            self.panel?.orderOut(nil)
            self.panel = nil
            self.frameTracker = nil
            self.speechRecognizer.shouldDismiss = false
            self.isDismissing = false
            self.onComplete?()
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
        speechRecognizer.forceStop()
        speechRecognizer.recognizedCharCount = 0
        panel?.orderOut(nil)
        panel = nil
        frameTracker = nil
        speechRecognizer.shouldDismiss = false
        speechRecognizer.shouldAdvancePage = false
    }

    private func observeDismiss() {
        // Single timer polls all conditions instead of two separate timers
        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }

                // Check for page advance
                if self.speechRecognizer.shouldAdvancePage {
                    self.speechRecognizer.shouldAdvancePage = false
                    self.onNextPage?()
                }

                // Check for page jump from page picker
                if let targetIndex = self.overlayContent.jumpToPageIndex {
                    self.overlayContent.jumpToPageIndex = nil
                    TextreamService.shared.jumpToPage(index: targetIndex)
                }

                // Check for dismiss
                if self.speechRecognizer.shouldDismiss, !self.isDismissing {
                    self.isDismissing = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        guard let self else { return }
                        self.stopMouseTracking()
                        self.stopCursorTracking()
                        self.removeStopButton()
                        self.removeEscMonitor()
                        self.cancellables.removeAll()
                        self.panel?.orderOut(nil)
                        self.panel = nil
                        self.frameTracker = nil
                        self.speechRecognizer.shouldDismiss = false
                        self.onComplete?()
                    }
                }
            }
            .store(in: &cancellables)
    }

    var isShowing: Bool {
        panel != nil
    }

    // MARK: - Floating Stop Button

    private func showStopButton(on screen: NSScreen) {
        guard stopButtonPanel == nil else { return }

        let buttonSize: CGFloat = 36
        let margin: CGFloat = 8
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarBottom = visibleFrame.maxY
        let x = screenFrame.midX - buttonSize / 2
        let y = menuBarBottom - buttonSize - margin

        let stopView = NSHostingView(rootView: StopButtonView {
            self.dismiss()
        })

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
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
        stopButtonPanel?.orderOut(nil)
        stopButtonPanel = nil
    }

    private func removeEscMonitor() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
        }
        escMonitor = nil
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

// MARK: - Notch Blur View (for transparency mode)

struct NotchBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.material = .hudWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
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
            return speechRecognizer.recognizedCharCount
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
                // Container shape — solid black or transparent with blur
                let isTransparent = NotchSettings.shared.overlayTransparency
                let transparencyOpacity = NotchSettings.shared.overlayTransparencyOpacity

                if isTransparent {
                    // Blurred background layer clipped to the Dynamic Island shape
                    NotchBlurView()
                        .clipShape(DynamicIslandShape(
                            topInset: currentTopInset,
                            bottomRadius: currentBottomRadius
                        ))
                        .frame(width: currentWidth, height: currentHeight)

                    // Dark tint overlay so text remains readable
                    DynamicIslandShape(
                        topInset: currentTopInset,
                        bottomRadius: currentBottomRadius
                    )
                    .fill(.black.opacity(1.0 - transparencyOpacity))
                    .frame(width: currentWidth, height: currentHeight)
                } else {
                    DynamicIslandShape(
                        topInset: currentTopInset,
                        bottomRadius: currentBottomRadius
                    )
                    .fill(.black)
                    .frame(width: currentWidth, height: currentHeight)
                }

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
                        } else if isDone && (listeningMode == .wordTracking || hasNextPage) {
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
                // In word tracking mode, stop listening when page is done
                if listeningMode == .wordTracking {
                    speechRecognizer.stop()
                }
                if !hasNextPage {
                    // Only auto-dismiss in word tracking mode.
                    // In classic/silence-paused modes the speaker may still be
                    // talking after the auto-scroll finishes, so keep the text
                    // visible and let them dismiss manually (X button or Esc).
                    if listeningMode == .wordTracking {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            speechRecognizer.shouldDismiss = true
                        }
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

                if let error = speechRecognizer.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(error)
                } else if listeningMode == .wordTracking {
                    Text(speechRecognizer.lastSpokenText.split(separator: " ").suffix(3).joined(separator: " "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.head)
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
                        if speechRecognizer.isListening || speechRecognizer.isStarting {
                            speechRecognizer.stop()
                        } else {
                            speechRecognizer.resume()
                        }
                    } label: {
                        Group {
                            if speechRecognizer.isStarting {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(.white.opacity(0.8))
                            } else {
                                Image(systemName: speechRecognizer.isListening ? "mic.fill" : "mic.slash.fill")
                                    .font(.system(size: 10, weight: .bold))
                            }
                        }
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
            return !isPaused
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if content.showPagePicker {
                floatingPagePickerView
            } else if isDone && (listeningMode == .wordTracking || hasNextPage) {
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
                if listeningMode == .wordTracking {
                    speechRecognizer.stop()
                }
                if !hasNextPage {
                    if listeningMode == .wordTracking {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            speechRecognizer.shouldDismiss = true
                        }
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

                if let error = speechRecognizer.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(error)
                } else if listeningMode == .wordTracking {
                    Text(speechRecognizer.lastSpokenText.split(separator: " ").suffix(3).joined(separator: " "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.head)
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
                            if speechRecognizer.isListening || speechRecognizer.isStarting {
                                speechRecognizer.stop()
                            } else {
                                speechRecognizer.resume()
                            }
                        } label: {
                            Group {
                                if speechRecognizer.isStarting {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .tint(.white.opacity(0.8))
                                } else {
                                    Image(systemName: speechRecognizer.isListening ? "mic.fill" : "mic.slash.fill")
                                        .font(.system(size: 10, weight: .bold))
                                }
                            }
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
            .padding(.bottom, 12)
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
