//
//  NotchSettings.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI

// MARK: - Font Size Preset

enum FontSizePreset: String, CaseIterable, Identifiable {
    case xs, sm, lg, xl

    var id: String { rawValue }

    var label: String {
        switch self {
        case .xs: return "XS"
        case .sm: return "SM"
        case .lg: return "LG"
        case .xl: return "XL"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .xs: return 14
        case .sm: return 16
        case .lg: return 20
        case .xl: return 24
        }
    }
}

// MARK: - Font Family Preset

enum FontFamilyPreset: String, CaseIterable, Identifiable {
    case sans, serif, mono, dyslexia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sans:     return "Sans"
        case .serif:    return "Serif"
        case .mono:     return "Mono"
        case .dyslexia: return "Dyslexia"
        }
    }

    var sampleText: String {
        switch self {
        case .sans:     return "Aa"
        case .serif:    return "Aa"
        case .mono:     return "Aa"
        case .dyslexia: return "Aa"
        }
    }

    func font(size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor
        switch self {
        case .sans:
            return base
        case .serif:
            if let designed = descriptor.withDesign(.serif) {
                return NSFont(descriptor: designed, size: size) ?? base
            }
            return base
        case .mono:
            if let designed = descriptor.withDesign(.monospaced) {
                return NSFont(descriptor: designed, size: size) ?? base
            }
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .dyslexia:
            if let dyslexicFont = NSFont(name: "OpenDyslexic3", size: size) {
                return dyslexicFont
            }
            // Fallback to rounded system font if OpenDyslexic not available
            if let designed = descriptor.withDesign(.rounded) {
                return NSFont(descriptor: designed, size: size) ?? base
            }
            return base
        }
    }
}

// MARK: - Font Color Preset

enum FontColorPreset: String, CaseIterable, Identifiable {
    case white, yellow, green, blue, pink, orange

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .white:  return .white
        case .yellow: return Color(red: 1.0, green: 0.84, blue: 0.04)
        case .green:  return Color(red: 0.2, green: 0.84, blue: 0.29)
        case .blue:   return Color(red: 0.31, green: 0.55, blue: 1.0)
        case .pink:   return Color(red: 1.0, green: 0.38, blue: 0.57)
        case .orange: return Color(red: 1.0, green: 0.62, blue: 0.04)
        }
    }

    var label: String {
        switch self {
        case .white:  return "White"
        case .yellow: return "Yellow"
        case .green:  return "Green"
        case .blue:   return "Blue"
        case .pink:   return "Pink"
        case .orange: return "Orange"
        }
    }

    var cssColor: String {
        switch self {
        case .white:  return "#ffffff"
        case .yellow: return "rgb(255,214,10)"
        case .green:  return "rgb(51,214,74)"
        case .blue:   return "rgb(79,140,255)"
        case .pink:   return "rgb(255,97,145)"
        case .orange: return "rgb(255,158,10)"
        }
    }
}

// MARK: - Cue Brightness

enum CueBrightness: String, CaseIterable, Identifiable {
    case dim, low, medium, bright

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dim:    return "Dim"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .bright: return "Bright"
        }
    }

    /// Opacity for unread annotations
    var unreadOpacity: Double {
        switch self {
        case .dim:    return 0.2
        case .low:    return 0.35
        case .medium: return 0.5
        case .bright: return 0.8
        }
    }

    /// Opacity for already-read annotations
    var readOpacity: Double {
        switch self {
        case .dim:    return 0.5
        case .low:    return 0.6
        case .medium: return 0.7
        case .bright: return 1.0
        }
    }
}

// MARK: - Overlay Mode

enum OverlayMode: String, CaseIterable, Identifiable {
    case pinned, floating, fullscreen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pinned:     return "Pinned to Notch"
        case .floating:   return "Floating Window"
        case .fullscreen: return "Fullscreen"
        }
    }

    var description: String {
        switch self {
        case .pinned:     return "Anchored below the notch at the top of your screen."
        case .floating:   return "A draggable window you can place anywhere. Always on top."
        case .fullscreen: return "Fullscreen teleprompter on the selected display. Press Esc to stop."
        }
    }

    var icon: String {
        switch self {
        case .pinned:     return "rectangle.topthird.inset.filled"
        case .floating:   return "macwindow.on.rectangle"
        case .fullscreen: return "rectangle.fill"
        }
    }
}

// MARK: - Notch Display Mode

enum NotchDisplayMode: String, CaseIterable, Identifiable {
    case followMouse, fixedDisplay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followMouse:  return "Follow Mouse"
        case .fixedDisplay: return "Fixed Display"
        }
    }

    var description: String {
        switch self {
        case .followMouse:  return "The notch moves to whichever display your mouse is on."
        case .fixedDisplay: return "The notch stays on the selected display."
        }
    }
}

// MARK: - External Display Mode

enum ExternalDisplayMode: String, CaseIterable, Identifiable {
    case off, teleprompter, mirror

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:          return "Off"
        case .teleprompter: return "Teleprompter"
        case .mirror:       return "Mirror"
        }
    }

    var description: String {
        switch self {
        case .off:          return "No external display output."
        case .teleprompter: return "Fullscreen teleprompter on the selected display."
        case .mirror:       return "Horizontally flipped for use with a prompter mirror rig."
        }
    }
}

// MARK: - Mirror Axis

enum MirrorAxis: String, CaseIterable, Identifiable {
    case horizontal, vertical, both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .horizontal: return "Horizontal"
        case .vertical:   return "Vertical"
        case .both:       return "Both"
        }
    }

    var description: String {
        switch self {
        case .horizontal: return "Flipped left-to-right. Standard for prompter mirror rigs."
        case .vertical:   return "Flipped top-to-bottom."
        case .both:       return "Flipped on both axes (rotated 180°)."
        }
    }

    var scaleX: CGFloat {
        switch self {
        case .horizontal, .both: return -1
        case .vertical: return 1
        }
    }

    var scaleY: CGFloat {
        switch self {
        case .vertical, .both: return -1
        case .horizontal: return 1
        }
    }
}

// MARK: - Listening Mode

enum ListeningMode: String, CaseIterable, Identifiable {
    case wordTracking, classic, silencePaused

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic:        return "Classic"
        case .silencePaused:  return "Voice-Activated"
        case .wordTracking:   return "Word Tracking"
        }
    }

    var description: String {
        switch self {
        case .classic:        return "Auto-scrolls at a constant speed. No microphone needed."
        case .silencePaused:  return "Scrolls while you speak, pauses when you're silent."
        case .wordTracking:   return "Tracks each word you say and highlights it in real time."
        }
    }

    var icon: String {
        switch self {
        case .classic:        return "arrow.down.circle"
        case .silencePaused:  return "waveform.circle"
        case .wordTracking:   return "text.word.spacing"
        }
    }
}

// MARK: - Settings

@Observable
class NotchSettings {
    static let shared = NotchSettings()

    var notchWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(notchWidth), forKey: "notchWidth") }
    }
    var textAreaHeight: CGFloat {
        didSet { UserDefaults.standard.set(Double(textAreaHeight), forKey: "textAreaHeight") }
    }

    var speechLocale: String {
        didSet { UserDefaults.standard.set(speechLocale, forKey: "speechLocale") }
    }

    var fontSizePreset: FontSizePreset {
        didSet { UserDefaults.standard.set(fontSizePreset.rawValue, forKey: "fontSizePreset") }
    }

    var fontFamilyPreset: FontFamilyPreset {
        didSet { UserDefaults.standard.set(fontFamilyPreset.rawValue, forKey: "fontFamilyPreset") }
    }

    var fontColorPreset: FontColorPreset {
        didSet { UserDefaults.standard.set(fontColorPreset.rawValue, forKey: "fontColorPreset") }
    }

    var cueColorPreset: FontColorPreset {
        didSet { UserDefaults.standard.set(cueColorPreset.rawValue, forKey: "cueColorPreset") }
    }

    var cueBrightness: CueBrightness {
        didSet { UserDefaults.standard.set(cueBrightness.rawValue, forKey: "cueBrightness") }
    }

    var overlayMode: OverlayMode {
        didSet { UserDefaults.standard.set(overlayMode.rawValue, forKey: "overlayMode") }
    }

    var notchDisplayMode: NotchDisplayMode {
        didSet { UserDefaults.standard.set(notchDisplayMode.rawValue, forKey: "notchDisplayMode") }
    }

    var pinnedScreenID: UInt32 {
        didSet { UserDefaults.standard.set(Int(pinnedScreenID), forKey: "pinnedScreenID") }
    }

    var floatingGlassEffect: Bool {
        didSet { UserDefaults.standard.set(floatingGlassEffect, forKey: "floatingGlassEffect") }
    }

    var glassOpacity: Double {
        didSet { UserDefaults.standard.set(glassOpacity, forKey: "glassOpacity") }
    }

    var overlayTransparency: Bool {
        didSet { UserDefaults.standard.set(overlayTransparency, forKey: "overlayTransparency") }
    }

    var overlayTransparencyOpacity: Double {
        didSet { UserDefaults.standard.set(overlayTransparencyOpacity, forKey: "overlayTransparencyOpacity") }
    }

    var followCursorWhenUndocked: Bool {
        didSet { UserDefaults.standard.set(followCursorWhenUndocked, forKey: "followCursorWhenUndocked") }
    }

    var externalDisplayMode: ExternalDisplayMode {
        didSet { UserDefaults.standard.set(externalDisplayMode.rawValue, forKey: "externalDisplayMode") }
    }

    var externalScreenID: UInt32 {
        didSet { UserDefaults.standard.set(Int(externalScreenID), forKey: "externalScreenID") }
    }

    var mirrorAxis: MirrorAxis {
        didSet { UserDefaults.standard.set(mirrorAxis.rawValue, forKey: "mirrorAxis") }
    }

    var listeningMode: ListeningMode {
        didSet { UserDefaults.standard.set(listeningMode.rawValue, forKey: "listeningMode") }
    }

    /// Words per second for classic and silence-paused modes
    var scrollSpeed: Double {
        didSet { UserDefaults.standard.set(scrollSpeed, forKey: "scrollSpeed") }
    }

    var hideFromScreenShare: Bool {
        didSet { UserDefaults.standard.set(hideFromScreenShare, forKey: "hideFromScreenShare") }
    }

    var showElapsedTime: Bool {
        didSet { UserDefaults.standard.set(showElapsedTime, forKey: "showElapsedTime") }
    }

    var selectedMicUID: String {
        didSet { UserDefaults.standard.set(selectedMicUID, forKey: "selectedMicUID") }
    }

    var autoNextPage: Bool {
        didSet { UserDefaults.standard.set(autoNextPage, forKey: "autoNextPage") }
    }

    var autoNextPageDelay: Int {
        didSet { UserDefaults.standard.set(autoNextPageDelay, forKey: "autoNextPageDelay") }
    }

    var fullscreenScreenID: UInt32 {
        didSet { UserDefaults.standard.set(Int(fullscreenScreenID), forKey: "fullscreenScreenID") }
    }

    var browserServerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(browserServerEnabled, forKey: "browserServerEnabled")
            TextreamService.shared.updateBrowserServer()
        }
    }

    var browserServerPort: UInt16 {
        didSet { UserDefaults.standard.set(Int(browserServerPort), forKey: "browserServerPort") }
    }

    var directorModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(directorModeEnabled, forKey: "directorModeEnabled")
            TextreamService.shared.updateDirectorServer()
        }
    }

    var directorServerPort: UInt16 {
        didSet { UserDefaults.standard.set(Int(directorServerPort), forKey: "directorServerPort") }
    }

    var font: NSFont {
        fontFamilyPreset.font(size: fontSizePreset.pointSize)
    }

    static let defaultWidth: CGFloat = 340
    static let defaultHeight: CGFloat = 150
    static let defaultLocale: String = SpeechLocaleSupport.closestSupportedLocale(to: Locale.current.identifier)?.identifier
        ?? Locale.current.identifier

    static let minWidth: CGFloat = 310
    static let maxWidth: CGFloat = 500
    static let minHeight: CGFloat = 100
    static let maxHeight: CGFloat = 400

    init() {
        let savedWidth = UserDefaults.standard.double(forKey: "notchWidth")
        let savedHeight = UserDefaults.standard.double(forKey: "textAreaHeight")
        self.notchWidth = savedWidth > 0 ? CGFloat(savedWidth) : Self.defaultWidth
        self.textAreaHeight = savedHeight > 0 ? CGFloat(savedHeight) : Self.defaultHeight
        let preferredSpeechLocale = UserDefaults.standard.string(forKey: "speechLocale") ?? Self.defaultLocale
        self.speechLocale = SpeechLocaleSupport.closestSupportedLocale(to: preferredSpeechLocale)?.identifier
            ?? Self.defaultLocale
        self.fontSizePreset = FontSizePreset(rawValue: UserDefaults.standard.string(forKey: "fontSizePreset") ?? "") ?? .lg
        self.fontFamilyPreset = FontFamilyPreset(rawValue: UserDefaults.standard.string(forKey: "fontFamilyPreset") ?? "") ?? .sans
        self.fontColorPreset = FontColorPreset(rawValue: UserDefaults.standard.string(forKey: "fontColorPreset") ?? "") ?? .white
        self.cueColorPreset = FontColorPreset(rawValue: UserDefaults.standard.string(forKey: "cueColorPreset") ?? "") ?? .white
        self.cueBrightness = CueBrightness(rawValue: UserDefaults.standard.string(forKey: "cueBrightness") ?? "") ?? .dim
        self.overlayMode = OverlayMode(rawValue: UserDefaults.standard.string(forKey: "overlayMode") ?? "") ?? .pinned
        self.notchDisplayMode = NotchDisplayMode(rawValue: UserDefaults.standard.string(forKey: "notchDisplayMode") ?? "") ?? .followMouse
        let savedPinnedScreenID = UserDefaults.standard.integer(forKey: "pinnedScreenID")
        self.pinnedScreenID = UInt32(savedPinnedScreenID)
        self.floatingGlassEffect = UserDefaults.standard.object(forKey: "floatingGlassEffect") as? Bool ?? false
        let savedOpacity = UserDefaults.standard.double(forKey: "glassOpacity")
        self.glassOpacity = savedOpacity > 0 ? savedOpacity : 0.15
        self.overlayTransparency = UserDefaults.standard.object(forKey: "overlayTransparency") as? Bool ?? false
        let savedTransparencyOpacity = UserDefaults.standard.double(forKey: "overlayTransparencyOpacity")
        self.overlayTransparencyOpacity = savedTransparencyOpacity > 0 ? savedTransparencyOpacity : 0.85
        self.followCursorWhenUndocked = UserDefaults.standard.object(forKey: "followCursorWhenUndocked") as? Bool ?? false
        self.externalDisplayMode = ExternalDisplayMode(rawValue: UserDefaults.standard.string(forKey: "externalDisplayMode") ?? "") ?? .off
        let savedScreenID = UserDefaults.standard.integer(forKey: "externalScreenID")
        self.externalScreenID = UInt32(savedScreenID)
        self.mirrorAxis = MirrorAxis(rawValue: UserDefaults.standard.string(forKey: "mirrorAxis") ?? "") ?? .horizontal
        self.listeningMode = ListeningMode(rawValue: UserDefaults.standard.string(forKey: "listeningMode") ?? "") ?? .wordTracking
        let savedSpeed = UserDefaults.standard.double(forKey: "scrollSpeed")
        self.scrollSpeed = savedSpeed > 0 ? savedSpeed : 3
        self.hideFromScreenShare = UserDefaults.standard.object(forKey: "hideFromScreenShare") as? Bool ?? true
        self.showElapsedTime = UserDefaults.standard.object(forKey: "showElapsedTime") as? Bool ?? true
        self.selectedMicUID = UserDefaults.standard.string(forKey: "selectedMicUID") ?? ""
        self.autoNextPage = UserDefaults.standard.object(forKey: "autoNextPage") as? Bool ?? false
        let savedDelay = UserDefaults.standard.integer(forKey: "autoNextPageDelay")
        self.autoNextPageDelay = savedDelay > 0 ? savedDelay : 3
        let savedFullscreenScreenID = UserDefaults.standard.integer(forKey: "fullscreenScreenID")
        self.fullscreenScreenID = UInt32(savedFullscreenScreenID)
        self.browserServerEnabled = UserDefaults.standard.object(forKey: "browserServerEnabled") as? Bool ?? false
        let savedPort = UserDefaults.standard.integer(forKey: "browserServerPort")
        self.browserServerPort = savedPort > 0 ? UInt16(savedPort) : 7373
        self.directorModeEnabled = UserDefaults.standard.object(forKey: "directorModeEnabled") as? Bool ?? false
        let savedDirectorPort = UserDefaults.standard.integer(forKey: "directorServerPort")
        self.directorServerPort = savedDirectorPort > 0 ? UInt16(savedDirectorPort) : 7575
    }
}
