import Foundation

// Preferences can be exercised without starting audio, networking, or the app.
final class TextreamService {
    static let shared = TextreamService()
    func updateKeepAwakeActivity(enabled: Bool) {}
    func updateBrowserServer() {}
    func updateDirectorServer() {}
}

@main
struct PrompterPreferencesTests {
    private struct LayoutWord: Identifiable { let id: Int }

    static func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        guard condition() else {
            fputs("FAIL: \(description)\n", stderr)
            exit(1)
        }
        print("PASS: \(description)")
    }

    static func main() throws {
        let savedFrame = NSRect(x: 140, y: 210, width: 1440, height: 680)
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--relaunch" {
            let defaults = UserDefaults(suiteName: CommandLine.arguments[2])!
            let settings = NotchSettings(defaults: defaults)
            check(settings.fontSize == 96, "96 pt survives a new process")
            check(settings.lineSpacingMultiplier == 1.6, "line spacing survives a new process")
            check(settings.floatingWindowFrame == savedFrame, "position and large window size survive a new process")
            check(settings.speechLocale == "en-US", "English speech language survives a new process")
            check(settings.listeningMode == .wordTracking, "word tracking survives a new process")
            check(settings.fontFamilyPreset == .mono, "font family survives a new process")
            check(settings.glassOpacity == 0, "zero glass opacity survives a new process")
            return
        }

        let suiteName = "dev.fka.textream.preferences-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = NotchSettings(defaults: defaults)
        check(settings.overlayMode == .floating, "new installs use a floating window")
        check(settings.listeningMode == .wordTracking, "new installs retain speech tracking")
        check(settings.fontSize == 48, "large-screen default font size")
        check(settings.lineSpacingMultiplier == 1, "existing line spacing is preserved by default")
        check(settings.floatingWindowFrame == nil, "a new install has no saved position")

        defaults.set("xl", forKey: "fontSizePreset")
        settings = NotchSettings(defaults: defaults)
        check(settings.fontSize == 24, "legacy font preset migrates without losing the choice")
        settings.fontSize = 96
        check(NotchSettings(defaults: defaults).fontSize == 96, "numeric font size takes precedence over a legacy preset")
        settings.fontSize = 1000
        check(settings.fontSize == 200, "large text size is bounded at 200 pt")
        settings.fontSize = -1
        check(settings.fontSize == 14, "text size cannot become negative")
        settings.fontSize = .nan
        check(settings.fontSize == 48, "invalid font sizes fall back to a usable value")
        settings.lineSpacingMultiplier = 5
        check(settings.lineSpacingMultiplier == 2.5, "line spacing has a usable upper limit")
        settings.lineSpacingMultiplier = 0
        check(settings.lineSpacingMultiplier == 1, "line spacing cannot collapse the rows")
        settings.lineSpacingMultiplier = .nan
        check(settings.lineSpacingMultiplier == 1, "invalid line spacing restores the default")

        settings.fontSize = 96
        settings.lineSpacingMultiplier = 1.6
        settings.fontFamilyPreset = .mono
        settings.floatingWindowFrame = savedFrame
        settings.speechLocale = "en-US"
        settings.listeningMode = .wordTracking
        settings.glassOpacity = 0
        defaults.synchronize()
        check(settings.font.pointSize == 96, "rendered font uses the numeric preference")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--relaunch", suiteName]
        try child.run()
        child.waitUntilExit()
        check(child.terminationStatus == 0, "preferences reload in a separate process")

        let main = NSRect(x: 0, y: 0, width: 1920, height: 1050)
        let left = NSRect(x: -2560, y: -400, width: 2560, height: 1440)
        let leftFrame = NSRect(x: -2450, y: -350, width: 2000, height: 1000)
        check(
            FloatingWindowGeometry.restoredFrame(saved: leftFrame, visibleFrames: [main, left], fallback: main) == leftFrame,
            "position and size on a display with negative coordinates are retained"
        )
        let recovered = FloatingWindowGeometry.restoredFrame(saved: leftFrame, visibleFrames: [main], fallback: main)
        check(main.contains(recovered), "a disconnected display cannot strand the window off screen")
        check(recovered.width == main.width, "an oversized window fits the remaining display")
        let small = NSRect(x: 0, y: 0, width: 1024, height: 700)
        let resized = FloatingWindowGeometry.restoredFrame(saved: savedFrame, visibleFrames: [small], fallback: small)
        check(small.contains(resized), "a resolution change keeps the restored window reachable")
        let tiny = NSRect(x: 25, y: 30, width: 50, height: 40)
        let minimum = FloatingWindowGeometry.restoredFrame(saved: tiny, visibleFrames: [main], fallback: main)
        check(minimum.size == FloatingWindowGeometry.minimumSize, "restored windows retain space for the controls")
        let initial = FloatingWindowGeometry.restoredFrame(saved: nil, visibleFrames: [main], fallback: main)
        check(initial.size == FloatingWindowGeometry.defaultSize, "the initial window is wider than the old 500-point cap")
        check(FloatingWindowGeometry.decode("invalid") == nil, "corrupt saved frames are ignored")
        check(FloatingWindowGeometry.decode(NSStringFromRect(savedFrame)) == savedFrame, "frame encoding round-trips")
        settings.floatingWindowFrame = nil
        check(NotchSettings(defaults: defaults).floatingWindowFrame == nil, "reset removes only the saved window frame")
        let lines = (0..<100).map { [LayoutWord(id: $0)] }
        let geometry = PrompterLineGeometry(
            rowHeight: 72, lineSpacing: 30, paragraphExtraSpacing: 14,
            paragraphPrefixCounts: Array(repeating: 0, count: 101)
        )
        let positions = geometry.fillingMissingPositions(measured: [0: 37], lines: lines)
        check(positions[0] == 37, "actual visible word measurements are preserved")
        check(positions.count == 100, "culled words still receive scroll coordinates")
        check(positions[80] == 8196, "a distant recovered word has a position beyond the viewport")
        check(500 - positions[80]! < -7000, "tracking can scroll to a recovered word outside the rendered area")
        let paragraphGeometry = PrompterLineGeometry(
            rowHeight: 72, lineSpacing: 30, paragraphExtraSpacing: 14,
            paragraphPrefixCounts: [0, 0, 1, 1]
        )
        let paragraphPositions = paragraphGeometry.fillingMissingPositions(measured: [:], lines: Array(lines.prefix(3)))
        check(paragraphPositions[1] == 152 && paragraphPositions[2] == 254, "offscreen coordinates include paragraph spacing")
        let widerSpacing = PrompterLineGeometry(
            rowHeight: 72, lineSpacing: 60, paragraphExtraSpacing: 14,
            paragraphPrefixCounts: Array(repeating: 0, count: 101)
        )
        let spacedPositions = widerSpacing.fillingMissingPositions(measured: [:], lines: lines)
        check(spacedPositions[80]! > positions[80]!, "live line-spacing changes update offscreen tracking coordinates")
        print("All prompter preference and window geometry checks passed.")
    }
}
