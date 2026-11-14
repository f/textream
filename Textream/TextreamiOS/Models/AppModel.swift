import Foundation
import Observation
import Speech

@Observable
@MainActor
final class AppModel {
    static let maximumPaletteColors = 8
    static let defaultEditorPalette = Array(TextColorRun.defaultPalette.prefix(maximumPaletteColors))
    private enum Key {
        static let script = "ios.script"
        static let formattedScript = "ios.formattedScript"
        static let palette = "editorColorPaletteHex"
        static let sessionMode = "ios.sessionMode"
        static let cameraEnabled = "ios.cameraEnabled"
        static let followMode = "ios.followMode"
        static let mirrorEnabled = "ios.mirrorEnabled"
        static let mirrorAxis = "ios.mirrorAxis"
        static let readingPosition = "ios.readingPosition"
        static let scrollSpeed = "ios.scrollSpeed"
        static let fontFamily = "ios.fontFamily"
        static let fontSize = "ios.fontSize"
        static let cueColor = "ios.cueColor"
        static let cueBrightness = "ios.cueBrightness"
        static let overlayOpacity = "ios.overlayOpacity"
        static let speechLocale = "ios.speechLocale"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var formattedScript: FormattedPage {
        didSet {
            defaults.set(try? JSONEncoder().encode(formattedScript), forKey: Key.formattedScript)
            defaults.set(formattedScript.text, forKey: Key.script)
        }
    }
    var script: String {
        get { formattedScript.text }
        set { formattedScript = formattedScript.updatingText(newValue) }
    }
    private(set) var editorPalette: [ScriptPaletteEntry] {
        didSet { defaults.set(editorPalette.map(\.hex), forKey: Key.palette) }
    }
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
    private(set) var cuePalette: [ScriptPaletteEntry] {
        didSet {
            if !cuePalette.contains(where: { $0.id == selectedCueID }), !cuePalette.isEmpty {
                let previousIndex = oldValue.firstIndex(where: { $0.id == selectedCueID }) ?? 0
                selectedCueID = cuePalette[min(previousIndex, cuePalette.count - 1)].id
            }
            defaults.set(cuePalette.map(\.hex), forKey: "cueColorPaletteHex")
            persistCueSelection()
        }
    }
    var selectedCueID: UUID { didSet { persistCueSelection() } }
    var cueColorHex: String { cuePalette.first(where: { $0.id == selectedCueID })?.hex ?? "#ffffff" }

    private func persistCueSelection() {
        guard let index = cuePalette.firstIndex(where: { $0.id == selectedCueID }) else { return }
        defaults.set(index, forKey: "selectedCuePaletteIndex")
        defaults.set(cuePalette[index].hex, forKey: "ios.cueColorHex")
    }

    var cueBrightness: CueBrightness { didSet { defaults.set(cueBrightness.rawValue, forKey: Key.cueBrightness) } }
    var overlayOpacity: Double { didSet { defaults.set(overlayOpacity, forKey: Key.overlayOpacity) } }
    var speechLocaleIdentifier: String { didSet { defaults.set(speechLocaleIdentifier, forKey: Key.speechLocale) } }
    var isShowingSession = false
    var isShowingSettings = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.formattedScript), let page = try? JSONDecoder().decode(FormattedPage.self, from: data) {
            formattedScript = FormattedPage(runs: page.runs)
        } else {
            formattedScript = FormattedPage(defaults.string(forKey: Key.script) ?? Self.sampleScript)
        }
        let colors = Array((defaults.stringArray(forKey: Key.palette) ?? Self.defaultEditorPalette).compactMap(TextColorRun.canonicalHex).prefix(Self.maximumPaletteColors))
        editorPalette = (colors.isEmpty ? ["#ffffff"] : colors).map { ScriptPaletteEntry(hex: $0) }
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
        let cueColors = Array((defaults.stringArray(forKey: "cueColorPaletteHex") ?? Self.defaultEditorPalette).compactMap(TextColorRun.canonicalHex).prefix(Self.maximumPaletteColors))
        var restoredCues = cueColors.isEmpty ? ["#ffffff"] : cueColors
        let legacyCue = PromptColorPreset(rawValue: defaults.string(forKey: Key.cueColor) ?? "") ?? .white
        let selectedCue = defaults.string(forKey: "ios.cueColorHex").flatMap(TextColorRun.canonicalHex) ?? legacyCue.uiColor.rgbHex
        let savedCueIndex = defaults.object(forKey: "selectedCuePaletteIndex") as? Int
        let cueIndex: Int
        if let savedCueIndex, restoredCues.indices.contains(savedCueIndex) {
            cueIndex = savedCueIndex
        } else if let matchingIndex = restoredCues.firstIndex(of: selectedCue) {
            cueIndex = matchingIndex
        } else {
            restoredCues[0] = selectedCue
            cueIndex = 0
        }
        let restoredEntries = restoredCues.map { ScriptPaletteEntry(hex: $0) }
        cuePalette = restoredEntries
        selectedCueID = restoredEntries[cueIndex].id

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

    var normalizedScript: PromptScript { PromptScript(formattedScript) }
    var canStart: Bool { !normalizedScript.text.isEmpty }

    func setPaletteColor(_ hex: String, id: UUID) {
        guard let color = TextColorRun.canonicalHex(hex), let index = editorPalette.firstIndex(where: { $0.id == id }) else { return }
        editorPalette[index].hex = color
    }

    func addPaletteColor() {
        guard editorPalette.count < Self.maximumPaletteColors else { return }
        let preset = Self.defaultEditorPalette.first { color in !editorPalette.contains(where: { $0.hex == color }) } ?? "#8e8e93"
        editorPalette.append(ScriptPaletteEntry(hex: preset))
    }

    func removePaletteColor(id: UUID) {
        guard editorPalette.count > 1 else { return }
        editorPalette.removeAll { $0.id == id }
    }

    func setCuePaletteColor(_ hex: String, id: UUID) {
        guard let color = TextColorRun.canonicalHex(hex), let index = cuePalette.firstIndex(where: { $0.id == id }) else { return }
        cuePalette[index].hex = color
    }

    func addCuePaletteColor() {
        guard cuePalette.count < Self.maximumPaletteColors else { return }
        let color = Self.defaultEditorPalette.first { color in !cuePalette.contains(where: { $0.hex == color }) } ?? "#8e8e93"
        cuePalette.append(ScriptPaletteEntry(hex: color))
    }

    func removeCuePaletteColor(id: UUID) {
        guard cuePalette.count > 1 else { return }
        cuePalette.removeAll { $0.id == id }
    }

    func startSession() {
        guard canStart else { return }
        isShowingSession = true
    }

    func configuration() -> PromptSessionConfiguration {
        PromptSessionConfiguration(
            formattedScript: formattedScript,
            sessionMode: sessionMode,
            cameraEnabled: cameraEnabled,
            followMode: followMode,
            mirrorEnabled: mirrorEnabled,
            mirrorAxis: mirrorAxis,
            readingPosition: readingPosition,
            scrollSpeed: scrollSpeed,
            fontFamily: fontFamily,
            fontSize: fontSize,
            cueColorHex: cueColorHex,
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
