import Foundation
import Observation
import Speech

@Observable
@MainActor
final class AppModel {
    private enum Key {
        static let script = "ios.script"
        static let sessionMode = "ios.sessionMode"
        static let cameraEnabled = "ios.cameraEnabled"
        static let followMode = "ios.followMode"
        static let mirrorEnabled = "ios.mirrorEnabled"
        static let mirrorAxis = "ios.mirrorAxis"
        static let readingPosition = "ios.readingPosition"
        static let scrollSpeed = "ios.scrollSpeed"
        static let fontFamily = "ios.fontFamily"
        static let fontSize = "ios.fontSize"
        static let textColor = "ios.textColor"
        static let cueColor = "ios.cueColor"
        static let cueBrightness = "ios.cueBrightness"
        static let overlayOpacity = "ios.overlayOpacity"
        static let speechLocale = "ios.speechLocale"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var script: String { didSet { defaults.set(script, forKey: Key.script) } }
    var sessionMode: SessionMode { didSet { defaults.set(sessionMode.rawValue, forKey: Key.sessionMode) } }
    var cameraEnabled: Bool { didSet { defaults.set(cameraEnabled, forKey: Key.cameraEnabled) } }
    var followMode: FollowMode { didSet { defaults.set(followMode.rawValue, forKey: Key.followMode) } }
    var mirrorEnabled: Bool { didSet { defaults.set(mirrorEnabled, forKey: Key.mirrorEnabled) } }
    var mirrorAxis: PromptMirrorAxis { didSet { defaults.set(mirrorAxis.rawValue, forKey: Key.mirrorAxis) } }
    var readingPosition: PromptReadingPosition {
        didSet { defaults.set(readingPosition.rawValue, forKey: Key.readingPosition) }
    }
    var scrollSpeed: Double { didSet { defaults.set(scrollSpeed, forKey: Key.scrollSpeed) } }
    var fontFamily: PromptFontFamily { didSet { defaults.set(fontFamily.rawValue, forKey: Key.fontFamily) } }
    var fontSize: PromptFontSize { didSet { defaults.set(fontSize.rawValue, forKey: Key.fontSize) } }
    var textColor: PromptColorPreset { didSet { defaults.set(textColor.rawValue, forKey: Key.textColor) } }
    var cueColor: PromptColorPreset { didSet { defaults.set(cueColor.rawValue, forKey: Key.cueColor) } }
    var cueBrightness: CueBrightness { didSet { defaults.set(cueBrightness.rawValue, forKey: Key.cueBrightness) } }
    var overlayOpacity: Double { didSet { defaults.set(overlayOpacity, forKey: Key.overlayOpacity) } }
    var speechLocaleIdentifier: String { didSet { defaults.set(speechLocaleIdentifier, forKey: Key.speechLocale) } }
    var isShowingSession = false
    var isShowingSettings = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        script = defaults.string(forKey: Key.script) ?? Self.sampleScript
        let restoredSessionMode = SessionMode(
            rawValue: defaults.string(forKey: Key.sessionMode) ?? ""
        ) ?? .read
        sessionMode = restoredSessionMode
        cameraEnabled = restoredSessionMode == .record
            || (defaults.object(forKey: Key.cameraEnabled) as? Bool ?? false)
        followMode = FollowMode(rawValue: defaults.string(forKey: Key.followMode) ?? "") ?? .wordTracking
        mirrorEnabled = defaults.object(forKey: Key.mirrorEnabled) as? Bool ?? false
        mirrorAxis = PromptMirrorAxis(
            rawValue: defaults.string(forKey: Key.mirrorAxis) ?? ""
        ) ?? .horizontal
        readingPosition = PromptReadingPosition(
            rawValue: defaults.string(forKey: Key.readingPosition) ?? ""
        ) ?? .nearCamera
        let savedSpeed = defaults.double(forKey: Key.scrollSpeed)
        scrollSpeed = savedSpeed > 0 ? savedSpeed : 3
        fontFamily = PromptFontFamily(rawValue: defaults.string(forKey: Key.fontFamily) ?? "") ?? .sans
        fontSize = PromptFontSize(rawValue: defaults.string(forKey: Key.fontSize) ?? "") ?? .lg
        textColor = PromptColorPreset(rawValue: defaults.string(forKey: Key.textColor) ?? "") ?? .white
        cueColor = PromptColorPreset(rawValue: defaults.string(forKey: Key.cueColor) ?? "") ?? .white
        cueBrightness = CueBrightness(rawValue: defaults.string(forKey: Key.cueBrightness) ?? "") ?? .dim
        let savedOpacity = defaults.double(forKey: Key.overlayOpacity)
        overlayOpacity = savedOpacity > 0 ? savedOpacity : 0.52
        if let savedLocale = defaults.string(forKey: Key.speechLocale), !savedLocale.isEmpty {
            speechLocaleIdentifier = savedLocale
        } else {
            // Asking Speech for every supported locale can synchronously load
            // linguistic assets. Keep cold launch lightweight; Settings loads
            // the full list only when the user opens it.
            // en-US is guaranteed by Speech on supported iOS devices and is a
            // valid Picker tag until Settings lazily resolves a closer locale.
            speechLocaleIdentifier = "en-US"
            defaults.set(speechLocaleIdentifier, forKey: Key.speechLocale)
        }

    }

    var normalizedScript: PromptScript { PromptScript(script) }
    var canStart: Bool { !normalizedScript.text.isEmpty }

    func startSession() {
        guard canStart else { return }
        isShowingSession = true
    }

    func configuration() -> PromptSessionConfiguration {
        PromptSessionConfiguration(
            script: script,
            sessionMode: sessionMode,
            cameraEnabled: cameraEnabled,
            followMode: followMode,
            mirrorEnabled: mirrorEnabled,
            mirrorAxis: mirrorAxis,
            readingPosition: readingPosition,
            scrollSpeed: scrollSpeed,
            fontFamily: fontFamily,
            fontSize: fontSize,
            textColor: textColor,
            cueColor: cueColor,
            cueBrightness: cueBrightness,
            overlayOpacity: overlayOpacity,
            speechLocaleIdentifier: speechLocaleIdentifier
        )
    }

    private static let sampleScript = """
    Welcome to Textream for iPhone. [smile]

    Read naturally and Textream follows every word you say. Switch to Classic for steady auto-scrolling, or Voice-Activated to move only while you speak.

    In Record mode, your camera stays full screen while this script floats above it. Tap the red record button when you are ready. [pause]
    """
}
