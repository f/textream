import XCTest

final class TextreamUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launchEnvironment["TEXTREAM_UI_TESTING"] = "1"
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()
        bringAppToFront()
        XCTAssertTrue(app.staticTexts["uiharness.overlay.mode"].waitForExistence(timeout: 5))
    }

    override func tearDown() {
        if app?.state != .notRunning {
            app.terminate()
        }
        super.tearDown()
    }

    func testOverlayModeSwitchesExposeCurrentModeInHarness() {
        app.buttons["uiharness.run.floating"].click()
        assertValue(of: "uiharness.overlay.mode", equals: "floating")

        app.buttons["uiharness.run.pinned"].click()
        assertValue(of: "uiharness.overlay.mode", equals: "pinned")

        app.buttons["uiharness.run.attached"].click()
        assertValue(of: "uiharness.overlay.mode", equals: "attached")

        app.buttons["uiharness.run.fullscreen"].click()
        assertValue(of: "uiharness.overlay.mode", equals: "fullscreen")
    }

    func testManualAsideHotkeyLifecycleThroughMockController() {
        app.buttons["uiharness.hotkeys.on"].click()
        assertValue(of: "uiharness.hotkeys.running", equals: "true")

        app.buttons["uiharness.hotkeys.toggleAside"].click()
        assertValue(of: "uiharness.tracking.state", equals: "aside")

        app.buttons["uiharness.hotkeys.toggleAside"].click()
        assertValue(of: "uiharness.tracking.state", equals: "tracking")

        app.buttons["uiharness.hotkeys.holdOn"].click()
        assertValue(of: "uiharness.tracking.state", equals: "aside")

        app.buttons["uiharness.hotkeys.holdOff"].click()
        assertValue(of: "uiharness.tracking.state", equals: "tracking")

        app.buttons["uiharness.hotkeys.off"].click()
        assertValue(of: "uiharness.hotkeys.running", equals: "false")
    }

    func testHUDVisibilityAndAttachedAnchorPositionUpdate() {
        app.buttons["uiharness.run.attached"].click()
        let firstFrame = waitForValue(of: "uiharness.anchor.frame", matching: { $0 != "-" })
        XCTAssertFalse(firstFrame.isEmpty)

        app.buttons["uiharness.hud.off"].click()
        assertValue(of: "uiharness.hud.enabled", equals: "off")
        assertValue(of: "uiharness.hud.count", equals: "0")

        app.buttons["uiharness.hud.on"].click()
        assertValue(of: "uiharness.hud.enabled", equals: "on")

        app.buttons["uiharness.anchor.move"].click()
        let movedFrame = waitForDifferentValue(of: "uiharness.anchor.frame", from: firstFrame)
        XCTAssertNotEqual(firstFrame, movedFrame)

        app.buttons["uiharness.anchor.quartz"].click()
        assertValue(of: "uiharness.overlay.mode", equals: "attached")
        assertValue(of: "uiharness.hud.enabled", equals: "on")

        app.buttons["uiharness.anchor.ax"].click()
        assertValue(of: "uiharness.overlay.mode", equals: "attached")
    }

    func testSettingsChangesApplyImmediatelyToAttachedOverlayAndHUD() {
        app.buttons["uiharness.run.attached"].click()
        let initialFrame = waitForValue(of: "uiharness.anchor.frame")
        assertValue(of: "uiharness.attached.margin", equals: "16,14")

        app.buttons["uiharness.settings.attachedInset"].click()
        assertValue(of: "uiharness.attached.margin", equals: "44,30")
        XCTAssertNotEqual(initialFrame, waitForDifferentValue(of: "uiharness.anchor.frame", from: initialFrame))

        app.buttons["uiharness.settings.hud.minimal"].click()
        assertValue(of: "uiharness.hud.count", equals: "1")

        app.buttons["uiharness.settings.hud.full"].click()
        assertValue(of: "uiharness.hud.count", equals: "4")
    }

    private func assertValue(of identifier: String, equals expected: String, timeout: TimeInterval = 2.5) {
        let actual = waitForValue(of: identifier, matching: { $0 == expected }, timeout: timeout)
        XCTAssertEqual(actual, expected)
    }

    private func waitForDifferentValue(of identifier: String, from original: String, timeout: TimeInterval = 2.5) -> String {
        waitForValue(of: identifier, matching: { $0 != original }, timeout: timeout)
    }

    @discardableResult
    private func waitForValue(
        of identifier: String,
        matching predicate: ((String) -> Bool)? = nil,
        timeout: TimeInterval = 2.5
    ) -> String {
        bringAppToFront()
        let text = app.staticTexts[identifier]
        XCTAssertTrue(text.waitForExistence(timeout: timeout))

        let deadline = Date().addingTimeInterval(timeout)
        var lastValue = rawValue(of: identifier)

        while Date() < deadline {
            if predicate?(lastValue) ?? true {
                return lastValue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            bringAppToFront()
            lastValue = rawValue(of: identifier)
        }

        return lastValue
    }

    private func rawValue(of identifier: String) -> String {
        bringAppToFront()
        let text = app.staticTexts[identifier]
        XCTAssertTrue(text.waitForExistence(timeout: 2))
        if let value = text.value as? String, !value.isEmpty {
            return value
        }
        return text.label
    }

    private func bringAppToFront(timeout: TimeInterval = 5) {
        if app.state != .runningForeground {
            app.activate()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch app.state {
            case .runningForeground:
                return
            case .notRunning:
                XCTFail("UI harness app is not running")
                return
            default:
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        }

        XCTFail("UI harness app failed to reach foreground state")
    }
}
