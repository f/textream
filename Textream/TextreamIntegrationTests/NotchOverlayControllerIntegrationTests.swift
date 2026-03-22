import XCTest
@testable import Textream

@MainActor
final class NotchOverlayControllerIntegrationTests: XCTestCase {
    private static var retainedAnchorServices: [WindowAnchorService] = []

    private struct SettingsSnapshot {
        let overlayMode: OverlayMode
        let listeningMode: ListeningMode
        let notchWidth: CGFloat
        let textAreaHeight: CGFloat
        let attachedAnchorCorner: AttachedAnchorCorner
        let attachedMarginX: Double
        let attachedMarginY: Double
        let attachedTargetWindowID: Int
        let attachedTargetWindowLabel: String
        let persistentHUDEnabled: Bool
        let hudModules: [HUDModule]
        let followCursorWhenUndocked: Bool

        @MainActor
        init(settings: NotchSettings) {
            overlayMode = settings.overlayMode
            listeningMode = settings.listeningMode
            notchWidth = settings.notchWidth
            textAreaHeight = settings.textAreaHeight
            attachedAnchorCorner = settings.attachedAnchorCorner
            attachedMarginX = settings.attachedMarginX
            attachedMarginY = settings.attachedMarginY
            attachedTargetWindowID = settings.attachedTargetWindowID
            attachedTargetWindowLabel = settings.attachedTargetWindowLabel
            persistentHUDEnabled = settings.persistentHUDEnabled
            hudModules = settings.hudModules
            followCursorWhenUndocked = settings.followCursorWhenUndocked
        }

        @MainActor
        func restore(on settings: NotchSettings) {
            settings.overlayMode = overlayMode
            settings.listeningMode = listeningMode
            settings.notchWidth = notchWidth
            settings.textAreaHeight = textAreaHeight
            settings.attachedAnchorCorner = attachedAnchorCorner
            settings.attachedMarginX = attachedMarginX
            settings.attachedMarginY = attachedMarginY
            settings.attachedTargetWindowID = attachedTargetWindowID
            settings.attachedTargetWindowLabel = attachedTargetWindowLabel
            settings.persistentHUDEnabled = persistentHUDEnabled
            settings.hudModules = hudModules
            settings.followCursorWhenUndocked = followCursorWhenUndocked
        }
    }

    private var settings: NotchSettings!
    private var snapshot: SettingsSnapshot!
    private var retainedControllers: [NotchOverlayController] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        settings = NotchSettings.shared
        snapshot = SettingsSnapshot(settings: settings)
        settings.listeningMode = .classic
        settings.notchWidth = 260
        settings.textAreaHeight = 120
        settings.persistentHUDEnabled = true
        settings.hudModules = [.trackingState, .expectedWord, .microphoneStatus]
        settings.followCursorWhenUndocked = false
        UITestRuntimeSupport.anchorProvider.reset()
        retainedControllers = []
    }

    override func tearDown() {
        retainedControllers.forEach { $0.dismiss() }
        waitForSettledPanels()
        retainedControllers.removeAll()
        Self.retainedAnchorServices.forEach {
            $0.stopTracking()
            $0.onResolutionChanged = nil
        }
        Self.retainedAnchorServices.removeAll()
        snapshot.restore(on: settings)
        WindowAnchorService.resetSharedProvider()
        TrackingHotkeyController.resetShared()
        super.tearDown()
    }

    func testOverlayModesShowPanelAcrossPinnedFloatingAndFullscreen() {
        for mode in [OverlayMode.pinned, .floating, .fullscreen] {
            settings.overlayMode = mode
            let controller = makeController()
            controller.show(text: "overlay modes should all present")

            XCTAssertTrue(controller.isShowing, "Expected \(mode.rawValue) to create a panel")
            XCTAssertNotNil(controller.debugPanelFrame)
            XCTAssertGreaterThan(controller.debugPanelAlpha, 0)

            controller.dismiss()
            waitForSettledPanels()
        }
    }

    func testManualAsideHotkeyLifecycleStartsStopsAndUpdatesSpeechState() {
        let hotkeys = UITestTrackingHotkeyController()
        let controller = makeController(hotkeyController: hotkeys)

        controller.debugUpdateHotkeyRegistration(for: .wordTracking)
        XCTAssertTrue(hotkeys.isRunning)
        XCTAssertTrue(controller.debugHotkeysRunning)

        hotkeys.simulateToggleAside()
        XCTAssertEqual(controller.speechRecognizer.manualAsideMode, .toggled)
        XCTAssertEqual(controller.overlayContent.trackingState, .aside)

        hotkeys.simulateToggleAside()
        XCTAssertEqual(controller.speechRecognizer.manualAsideMode, .inactive)
        XCTAssertEqual(controller.overlayContent.trackingState, .tracking)

        hotkeys.simulateHoldIgnore(true)
        XCTAssertEqual(controller.speechRecognizer.manualAsideMode, .hold)
        XCTAssertEqual(controller.overlayContent.trackingState, .aside)

        hotkeys.simulateHoldIgnore(false)
        XCTAssertEqual(controller.speechRecognizer.manualAsideMode, .inactive)
        XCTAssertEqual(controller.overlayContent.trackingState, .tracking)

        controller.debugUpdateHotkeyRegistration(for: .classic)
        XCTAssertFalse(hotkeys.isRunning)
        XCTAssertFalse(controller.debugHotkeysRunning)
    }

    func testAttachedModeUpdatesPositionFromMockAnchorProvider() throws {
        let provider = UITestRuntimeSupport.anchorProvider
        provider.reset()
        let service = WindowAnchorService(provider: provider)
        Self.retainedAnchorServices.append(service)
        let controller = makeController(windowAnchorService: service)

        settings.overlayMode = .attached
        settings.attachedTargetWindowID = UITestRuntimeSupport.mockWindowID
        settings.attachedTargetWindowLabel = "Mock Window"
        settings.attachedAnchorCorner = .topRight
        settings.attachedMarginX = 16
        settings.attachedMarginY = 12

        controller.show(text: "attached mode should follow the mock window")
        waitForSettledPanels()

        let firstFrame = try XCTUnwrap(controller.debugPanelFrame)
        let expectedFirstOrigin = service.anchoredOrigin(
            targetFrame: provider.visibleWindows().first!.bounds,
            overlaySize: firstFrame.size,
            corner: .topRight,
            marginX: 16,
            marginY: 12
        )
        XCTAssertEqual(firstFrame.origin.x, expectedFirstOrigin.x, accuracy: 6.0)
        XCTAssertEqual(firstFrame.origin.y, expectedFirstOrigin.y, accuracy: 6.0)

        provider.shiftWindow(dx: 64, dy: -32)
        controller.debugRefreshAttachedResolution()
        waitForSettledPanels()

        let secondFrame = try XCTUnwrap(controller.debugPanelFrame)
        XCTAssertNotEqual(secondFrame.origin.x, firstFrame.origin.x, accuracy: 0.5)
        XCTAssertNotEqual(secondFrame.origin.y, firstFrame.origin.y, accuracy: 0.5)

        controller.dismiss()
        waitForSettledPanels()
    }

    func testAttachedSettingsChangeRepositionsOverlayOnNextAnchorRefresh() throws {
        let provider = UITestRuntimeSupport.anchorProvider
        provider.reset()
        let service = WindowAnchorService(provider: provider)
        Self.retainedAnchorServices.append(service)
        let controller = makeController(windowAnchorService: service)

        settings.overlayMode = .attached
        settings.attachedTargetWindowID = UITestRuntimeSupport.mockWindowID
        settings.attachedTargetWindowLabel = "Mock Window"
        settings.attachedAnchorCorner = .topLeft
        settings.attachedMarginX = 10
        settings.attachedMarginY = 10

        controller.show(text: "settings should reposition the attached overlay")
        waitForSettledPanels()
        let firstFrame = try XCTUnwrap(controller.debugPanelFrame)

        settings.attachedMarginX = 42
        settings.attachedMarginY = 36
        controller.debugRefreshAttachedResolution()
        waitForSettledPanels()

        let secondFrame = try XCTUnwrap(controller.debugPanelFrame)
        XCTAssertNotEqual(secondFrame.origin.x, firstFrame.origin.x, accuracy: 0.5)
        XCTAssertNotEqual(secondFrame.origin.y, firstFrame.origin.y, accuracy: 0.5)

        controller.dismiss()
        waitForSettledPanels()
    }

    func testFloatingOverlayCanSwitchIntoFollowCursorDuringActiveSession() throws {
        settings.overlayMode = .floating
        settings.followCursorWhenUndocked = false

        let controller = makeController()
        controller.show(text: "floating should switch into follow cursor live")
        waitForSettledPanels()

        XCTAssertEqual(controller.debugPresentationMode, "floating")
        XCTAssertFalse(controller.debugCursorTrackingRunning)

        settings.followCursorWhenUndocked = true
        controller.refreshPresentationForSettingsChange()
        waitForSettledPanels()

        XCTAssertEqual(controller.debugPresentationMode, "floatingFollowCursor")
        XCTAssertTrue(controller.debugCursorTrackingRunning)

        settings.followCursorWhenUndocked = false
        controller.refreshPresentationForSettingsChange()
        waitForSettledPanels()

        XCTAssertEqual(controller.debugPresentationMode, "floating")
        XCTAssertFalse(controller.debugCursorTrackingRunning)
        XCTAssertNotNil(try XCTUnwrap(controller.debugPanelFrame))

        controller.dismiss()
        waitForSettledPanels()
    }

    func testAttachedOverlayResizesAndReanchorsDuringActiveSession() throws {
        let provider = UITestRuntimeSupport.anchorProvider
        provider.reset()
        let service = WindowAnchorService(provider: provider)
        Self.retainedAnchorServices.append(service)
        let controller = makeController(windowAnchorService: service)

        settings.overlayMode = .attached
        settings.attachedTargetWindowID = UITestRuntimeSupport.mockWindowID
        settings.attachedTargetWindowLabel = "Mock Window"
        settings.attachedAnchorCorner = .topRight
        settings.attachedMarginX = 16
        settings.attachedMarginY = 12
        settings.notchWidth = 260
        settings.textAreaHeight = 120

        controller.show(text: "attached should resize live")
        waitForSettledPanels()

        let firstFrame = try XCTUnwrap(controller.debugPanelFrame)

        settings.notchWidth = 360
        settings.textAreaHeight = 180
        settings.attachedMarginX = 28
        settings.attachedMarginY = 20
        controller.refreshPresentationForSettingsChange()
        waitForSettledPanels()

        let secondFrame = try XCTUnwrap(controller.debugPanelFrame)
        XCTAssertNotEqual(secondFrame.width, firstFrame.width, accuracy: 0.5)
        XCTAssertNotEqual(secondFrame.height, firstFrame.height, accuracy: 0.5)
        XCTAssertNotEqual(secondFrame.origin.x, firstFrame.origin.x, accuracy: 0.5)
        XCTAssertNotEqual(secondFrame.origin.y, firstFrame.origin.y, accuracy: 0.5)

        controller.dismiss()
        waitForSettledPanels()
    }

    func testAttachedOverlayDirectResizePersistsBackIntoSettings() throws {
        let provider = UITestRuntimeSupport.anchorProvider
        provider.reset()
        let service = WindowAnchorService(provider: provider)
        Self.retainedAnchorServices.append(service)
        let controller = makeController(windowAnchorService: service)

        settings.overlayMode = .attached
        settings.attachedTargetWindowID = UITestRuntimeSupport.mockWindowID
        settings.attachedTargetWindowLabel = "Mock Window"
        settings.attachedAnchorCorner = .topRight
        settings.attachedMarginX = 16
        settings.attachedMarginY = 12
        settings.notchWidth = 260
        settings.textAreaHeight = 120
        settings.followCursorWhenUndocked = true

        controller.show(text: "attached should persist direct resize")
        waitForSettledPanels()

        controller.debugSimulateUserResize(to: CGSize(width: 340, height: 180))
        waitForSettledPanels()

        XCTAssertEqual(settings.notchWidth, 340, accuracy: 0.5)
        XCTAssertEqual(settings.textAreaHeight, 180, accuracy: 0.5)

        let frame = try XCTUnwrap(controller.debugPanelFrame)
        let targetFrame = try XCTUnwrap(provider.visibleWindows().first?.bounds)
        let expectedOrigin = service.anchoredOrigin(
            targetFrame: targetFrame,
            overlaySize: frame.size,
            corner: .topRight,
            marginX: 16,
            marginY: 12
        )
        XCTAssertEqual(frame.origin.x, expectedOrigin.x, accuracy: 6.0)
        XCTAssertEqual(frame.origin.y, expectedOrigin.y, accuracy: 6.0)

        controller.dismiss()
        waitForSettledPanels()
    }

    private func makeController(
        windowAnchorService: WindowAnchorService? = nil,
        hotkeyController: (any TrackingHotkeyControlling)? = nil
    ) -> NotchOverlayController {
        let controller = NotchOverlayController(
            windowAnchorService: windowAnchorService ?? WindowAnchorService(),
            hotkeyController: hotkeyController ?? UITestTrackingHotkeyController(),
            attachedDiagnostics: AttachedDiagnosticsStore(),
            disablePermissionOnboarding: true
        )
        retainedControllers.append(controller)
        return controller
    }

    private func waitForSettledPanels() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
    }
}
