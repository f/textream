//
//  UITestSupport.swift
//  Textream
//
//  Created by OpenAI Codex on 21.03.2026.
//

import AppKit
import SwiftUI

enum UITestRuntimeSupport {
    static let sampleText = "UI testing keeps the overlay visible while we verify attached positioning and HUD state."
    static let mockWindowID = 9001
    static let anchorProvider = UITestWindowAnchorProvider()
    static let hotkeyController = UITestTrackingHotkeyController()
    private static var didConfigure = false

    static func configureIfNeeded() {
        guard AppRuntime.isRunningUITests else { return }
        guard !didConfigure else { return }
        didConfigure = true
        WindowAnchorService.installSharedProvider(anchorProvider)
        TrackingHotkeyController.installShared(hotkeyController)
        anchorProvider.reset()
        hotkeyController.reset()

        let settings = NotchSettings.shared
        settings.browserServerEnabled = false
        settings.directorModeEnabled = false
        settings.showElapsedTime = false
        settings.qaDebugOverlayEnabled = false
        settings.trackingDebugLoggingEnabled = false
        settings.anchorDebugLoggingEnabled = false
        settings.persistentHUDEnabled = true
        settings.hudModules = [.trackingState, .expectedWord, .nextCue, .microphoneStatus]
        settings.overlayMode = .floating
        settings.listeningMode = .classic
        settings.attachedAnchorCorner = .topRight
        settings.attachedMarginX = 16
        settings.attachedMarginY = 14
        settings.attachedTargetWindowID = mockWindowID
        settings.attachedTargetWindowLabel = "UITest Anchor"
        settings.attachedHideWhenWindowUnavailable = false
        settings.attachedFallbackBehavior = .screenCorner
        settings.hasSeenAttachedOnboarding = true
    }

    static func resetIfNeeded() {
        guard AppRuntime.isRunningUITests else { return }
        didConfigure = false
        WindowAnchorService.resetSharedProvider()
        TrackingHotkeyController.resetShared()
    }
}

final class UITestWindowAnchorProvider: WindowAnchorProviding {
    struct MockWindow {
        var info: AttachedWindowInfo
        var accessibilityFrame: CGRect?
    }

    var accessibilityTrusted = true
    var didRequestAccessibilityPrompt = false
    var didOpenAccessibilitySettings = false
    private var windowsByID: [Int: MockWindow] = [:]

    init() {
        reset()
    }

    func reset() {
        accessibilityTrusted = true
        didRequestAccessibilityPrompt = false
        didOpenAccessibilitySettings = false
        let frame = CGRect(x: 360, y: 420, width: 720, height: 520)
        let window = AttachedWindowInfo(
            id: UITestRuntimeSupport.mockWindowID,
            ownerName: "UITestHost",
            title: "Mock Target",
            pid: 42,
            bounds: frame,
            layer: 0,
            isOnScreen: true
        )
        windowsByID = [
            window.id: MockWindow(info: window, accessibilityFrame: frame),
        ]
    }

    func isAccessibilityTrusted(prompt: Bool) -> Bool {
        if prompt {
            didRequestAccessibilityPrompt = true
        }
        return accessibilityTrusted
    }

    func openAccessibilitySettings() {
        didOpenAccessibilitySettings = true
    }

    func visibleWindows() -> [AttachedWindowInfo] {
        windowsByID.values.map(\.info)
    }

    func accessibilityFrame(for target: AttachedWindowInfo) -> CGRect? {
        windowsByID[target.id]?.accessibilityFrame
    }

    func updateWindow(frame: CGRect, axFrame: CGRect? = nil) {
        guard var window = windowsByID[UITestRuntimeSupport.mockWindowID] else { return }
        window.info = AttachedWindowInfo(
            id: window.info.id,
            ownerName: window.info.ownerName,
            title: window.info.title,
            pid: window.info.pid,
            bounds: frame,
            layer: window.info.layer,
            isOnScreen: window.info.isOnScreen
        )
        window.accessibilityFrame = axFrame ?? frame
        windowsByID[UITestRuntimeSupport.mockWindowID] = window
    }

    func shiftWindow(dx: CGFloat, dy: CGFloat) {
        guard let current = windowsByID[UITestRuntimeSupport.mockWindowID] else { return }
        let nextFrame = current.info.bounds.offsetBy(dx: dx, dy: dy)
        let nextAXFrame = current.accessibilityFrame?.offsetBy(dx: dx, dy: dy)
        updateWindow(frame: nextFrame, axFrame: nextAXFrame)
    }

    func setAccessibilityFrameAvailable(_ isAvailable: Bool) {
        guard var window = windowsByID[UITestRuntimeSupport.mockWindowID] else { return }
        window.accessibilityFrame = isAvailable ? window.info.bounds : nil
        windowsByID[UITestRuntimeSupport.mockWindowID] = window
    }
}

final class UITestTrackingHotkeyController: TrackingHotkeyControlling {
    var onToggleAside: (() -> Void)?
    var onHoldIgnoreChanged: ((Bool) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false

    func start() {
        startCount += 1
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
        onHoldIgnoreChanged?(false)
    }

    func reset() {
        onToggleAside = nil
        onHoldIgnoreChanged = nil
        startCount = 0
        stopCount = 0
        isRunning = false
    }

    func simulateToggleAside() {
        onToggleAside?()
    }

    func simulateHoldIgnore(_ active: Bool) {
        onHoldIgnoreChanged?(active)
    }
}

struct UITestHarnessContainer<Content: View>: View {
    let content: Content
    private let diagnostics = AttachedDiagnosticsStore.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            ZStack(alignment: .bottomLeading) {
                content
                harness
            }
        }
    }

    private var harness: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Pinned") { launchOverlay(mode: .pinned) }
                    .accessibilityIdentifier("uiharness.run.pinned")
                Button("Floating") { launchOverlay(mode: .floating) }
                    .accessibilityIdentifier("uiharness.run.floating")
                Button("Attached") { launchOverlay(mode: .attached) }
                    .accessibilityIdentifier("uiharness.run.attached")
                Button("Fullscreen") { launchOverlay(mode: .fullscreen) }
                    .accessibilityIdentifier("uiharness.run.fullscreen")
                Button("Dismiss") { TextreamService.shared.overlayController.dismiss() }
                    .accessibilityIdentifier("uiharness.dismiss")
            }

            HStack(spacing: 8) {
                Button("HUD On") {
                    NotchSettings.shared.persistentHUDEnabled = true
                }
                .accessibilityIdentifier("uiharness.hud.on")
                Button("HUD Off") {
                    NotchSettings.shared.persistentHUDEnabled = false
                }
                .accessibilityIdentifier("uiharness.hud.off")
                Button("Hotkeys On") {
                    NotchSettings.shared.listeningMode = .wordTracking
                    TextreamService.shared.overlayController.debugUpdateHotkeyRegistration(for: .wordTracking)
                }
                .accessibilityIdentifier("uiharness.hotkeys.on")
                Button("Hotkeys Off") {
                    TextreamService.shared.overlayController.debugUpdateHotkeyRegistration(for: .classic)
                }
                .accessibilityIdentifier("uiharness.hotkeys.off")
            }

            HStack(spacing: 8) {
                Button("Aside Toggle") {
                    UITestRuntimeSupport.hotkeyController.simulateToggleAside()
                }
                .accessibilityIdentifier("uiharness.hotkeys.toggleAside")
                Button("Hold On") {
                    UITestRuntimeSupport.hotkeyController.simulateHoldIgnore(true)
                }
                .accessibilityIdentifier("uiharness.hotkeys.holdOn")
                Button("Hold Off") {
                    UITestRuntimeSupport.hotkeyController.simulateHoldIgnore(false)
                }
                .accessibilityIdentifier("uiharness.hotkeys.holdOff")
                Button("Move Anchor") {
                    UITestRuntimeSupport.anchorProvider.shiftWindow(dx: 48, dy: -24)
                    TextreamService.shared.overlayController.debugRefreshAttachedResolution()
                }
                .accessibilityIdentifier("uiharness.anchor.move")
                Button("Quartz") {
                    UITestRuntimeSupport.anchorProvider.setAccessibilityFrameAvailable(false)
                    TextreamService.shared.overlayController.debugRefreshAttachedResolution()
                }
                .accessibilityIdentifier("uiharness.anchor.quartz")
                Button("AX") {
                    UITestRuntimeSupport.anchorProvider.setAccessibilityFrameAvailable(true)
                    TextreamService.shared.overlayController.debugRefreshAttachedResolution()
                }
                .accessibilityIdentifier("uiharness.anchor.ax")
            }

            HStack(spacing: 8) {
                Button("Inset") {
                    NotchSettings.shared.attachedMarginX = 44
                    NotchSettings.shared.attachedMarginY = 30
                    TextreamService.shared.overlayController.debugRefreshAttachedResolution()
                }
                .accessibilityIdentifier("uiharness.settings.attachedInset")
                Button("Inset Reset") {
                    NotchSettings.shared.attachedMarginX = 16
                    NotchSettings.shared.attachedMarginY = 14
                    TextreamService.shared.overlayController.debugRefreshAttachedResolution()
                }
                .accessibilityIdentifier("uiharness.settings.attachedInsetReset")
                Button("HUD Minimal") {
                    NotchSettings.shared.hudModules = [.trackingState]
                }
                .accessibilityIdentifier("uiharness.settings.hud.minimal")
                Button("HUD Full") {
                    NotchSettings.shared.hudModules = [.trackingState, .expectedWord, .nextCue, .microphoneStatus]
                }
                .accessibilityIdentifier("uiharness.settings.hud.full")
            }

            Divider()

            statusLine("overlay.mode", NotchSettings.shared.overlayMode.rawValue)
            statusLine("overlay.status", TextreamService.shared.overlayController.overlayContent.statusLine)
            statusLine("tracking.state", TextreamService.shared.overlayController.overlayContent.trackingState.rawValue)
            statusLine("tracking.expected", TextreamService.shared.overlayController.overlayContent.expectedWord)
            statusLine("hud.enabled", NotchSettings.shared.persistentHUDEnabled ? "on" : "off")
            statusLine("hud.count", "\(hudItemCount)")
            statusLine("attached.margin", "\(Int(NotchSettings.shared.attachedMarginX)),\(Int(NotchSettings.shared.attachedMarginY))")
            statusLine("anchor.source", diagnostics.anchorSourceLabel)
            statusLine("anchor.state", diagnostics.state.rawValue)
            statusLine("anchor.frame", panelFrameLabel)
            statusLine("hotkeys.running", TextreamService.shared.overlayController.debugHotkeysRunning ? "true" : "false")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(12)
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var hudItemCount: Int {
        PersistentHUDPresenter.items(
            content: TextreamService.shared.overlayController.overlayContent,
            isListening: TextreamService.shared.overlayController.speechRecognizer.isListening,
            configuration: HUDPresentationConfiguration(
                isEnabled: NotchSettings.shared.persistentHUDEnabled,
                modules: NotchSettings.shared.hudModules
            )
        ).count
    }

    private var panelFrameLabel: String {
        guard let frame = TextreamService.shared.overlayController.debugPanelFrame else { return "-" }
        return "\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))"
    }

    @ViewBuilder
    private func statusLine(_ id: String, _ value: String) -> some View {
        let resolvedValue = value.isEmpty ? "-" : value
        Text(resolvedValue)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(resolvedValue)
            .accessibilityValue(resolvedValue)
            .accessibilityIdentifier("uiharness.\(id)")
    }

    private func launchOverlay(mode: OverlayMode) {
        let settings = NotchSettings.shared
        settings.overlayMode = mode
        settings.listeningMode = .classic
        settings.attachedTargetWindowID = UITestRuntimeSupport.mockWindowID
        settings.attachedTargetWindowLabel = "UITest Anchor"
        UITestRuntimeSupport.anchorProvider.reset()
        if TextreamService.shared.pages.isEmpty {
            TextreamService.shared.pages = [UITestRuntimeSupport.sampleText]
        } else {
            TextreamService.shared.pages = [UITestRuntimeSupport.sampleText]
        }
        TextreamService.shared.currentPageIndex = 0
        TextreamService.shared.readCurrentPage()
    }
}

struct UITestHarnessRootView: View {
    var body: some View {
        UITestHarnessContainer(
            content:
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    Text("Textream UI Harness")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        )
        .onAppear {
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
            }
        }
    }
}
