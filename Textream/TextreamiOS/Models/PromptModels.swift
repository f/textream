import Observation
import SwiftUI
import UIKit

enum SessionMode: String, CaseIterable, Identifiable, Codable {
    case read
    case record

    var id: String { rawValue }

    var label: String {
        switch self {
        case .read: "Read"
        case .record: "Record"
        }
    }

    var icon: String {
        switch self {
        case .read: "text.line.first.and.arrowtriangle.forward"
        case .record: "video.fill"
        }
    }
}

enum FollowMode: String, CaseIterable, Identifiable, Codable {
    case wordTracking
    case classic
    case voiceActivated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wordTracking: "Word Tracking"
        case .classic: "Classic"
        case .voiceActivated: "Voice-Activated"
        }
    }

    var shortLabel: String {
        switch self {
        case .wordTracking: "Follow"
        case .classic: "Auto"
        case .voiceActivated: "Voice"
        }
    }

    var description: String {
        switch self {
        case .wordTracking: "Follows and highlights the words you say."
        case .classic: "Scrolls at a constant speed without the microphone."
        case .voiceActivated: "Scrolls while you speak and pauses in silence."
        }
    }

    var icon: String {
        switch self {
        case .wordTracking: "text.word.spacing"
        case .classic: "arrow.down.circle"
        case .voiceActivated: "waveform.circle"
        }
    }

    var requiresMicrophone: Bool { self != .classic }
}

enum PromptReadingPosition: String, CaseIterable, Identifiable, Codable {
    case nearCamera
    case center

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nearCamera: "Near Camera"
        case .center: "Center"
        }
    }

    var description: String {
        switch self {
        case .nearCamera: "Keeps the active line near the front camera for more natural eye contact."
        case .center: "Keeps the active line in the center of the screen."
        }
    }
}

enum PromptMirrorAxis: String, CaseIterable, Identifiable, Codable {
    case horizontal
    case vertical
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        case .both: "Both"
        }
    }

    var description: String {
        switch self {
        case .horizontal: "Flips left to right for standard teleprompter glass."
        case .vertical: "Flips top to bottom."
        case .both: "Flips both axes."
        }
    }

    var scaleX: CGFloat {
        switch self {
        case .horizontal, .both: -1
        case .vertical: 1
        }
    }

    var scaleY: CGFloat {
        switch self {
        case .vertical, .both: -1
        case .horizontal: 1
        }
    }
}

struct PromptMirrorPresentation {
    static func isActive(
        enabled: Bool,
        sessionMode: SessionMode,
        viewportSize: CGSize
    ) -> Bool {
        enabled
            && sessionMode == .read
            && viewportSize.width > viewportSize.height
    }

    /// SwiftUI's negative horizontal scale also reverses the UIKit view's
    /// local pan coordinates. Convert that content-space translation back to
    /// the direction of the user's gesture on the physical device so swiping
    /// right always increases speed.
    static func deviceHorizontalTranslation(
        from contentTranslation: CGFloat,
        isActive: Bool,
        axis: PromptMirrorAxis
    ) -> CGFloat {
        guard isActive else { return contentTranslation }
        return contentTranslation * axis.scaleX
    }
}

enum PromptFontFamily: String, CaseIterable, Identifiable, Codable {
    case sans
    case serif
    case mono
    case dyslexia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sans: "Sans"
        case .serif: "Serif"
        case .mono: "Mono"
        case .dyslexia: "Dyslexia"
        }
    }

    func uiFont(size: CGFloat, weight: UIFont.Weight = .semibold) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        switch self {
        case .sans:
            return base
        case .serif:
            guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
            return UIFont(descriptor: descriptor, size: size)
        case .mono:
            guard let descriptor = base.fontDescriptor.withDesign(.monospaced) else {
                return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            }
            return UIFont(descriptor: descriptor, size: size)
        case .dyslexia:
            return UIFont(name: "OpenDyslexicThree-Regular", size: size)
                ?? UIFont(name: "OpenDyslexic3", size: size)
                ?? UIFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size)
        }
    }

    func swiftUIFont(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        switch self {
        case .sans:
            return .system(size: size, weight: weight)
        case .serif:
            return .system(size: size, weight: weight, design: .serif)
        case .mono:
            return .system(size: size, weight: weight, design: .monospaced)
        case .dyslexia:
            return .custom("OpenDyslexicThree-Regular", size: size)
        }
    }
}

enum PromptFontSize: String, CaseIterable, Identifiable, Codable {
    case xs
    case sm
    case lg
    case xl

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    /// Fullscreen iPhone sizes corresponding to the four macOS size presets.
    var pointSize: CGFloat {
        switch self {
        case .xs: 28
        case .sm: 34
        case .lg: 44
        case .xl: 56
        }
    }
}

enum PromptColorPreset: String, CaseIterable, Identifiable, Codable {
    case white
    case yellow
    case green
    case blue
    case pink
    case orange

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var uiColor: UIColor {
        switch self {
        case .white: .white
        case .yellow: UIColor(red: 1, green: 214 / 255, blue: 10 / 255, alpha: 1)
        case .green: UIColor(red: 51 / 255, green: 214 / 255, blue: 74 / 255, alpha: 1)
        case .blue: UIColor(red: 79 / 255, green: 140 / 255, blue: 1, alpha: 1)
        case .pink: UIColor(red: 1, green: 97 / 255, blue: 145 / 255, alpha: 1)
        case .orange: UIColor(red: 1, green: 158 / 255, blue: 10 / 255, alpha: 1)
        }
    }

    var color: Color { Color(uiColor: uiColor) }
}

enum CueBrightness: String, CaseIterable, Identifiable, Codable {
    case dim
    case low
    case medium
    case bright

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var unreadOpacity: Double {
        switch self {
        case .dim: 0.2
        case .low: 0.35
        case .medium: 0.5
        case .bright: 0.8
        }
    }

    var readOpacity: Double {
        switch self {
        case .dim: 0.5
        case .low: 0.6
        case .medium: 0.7
        case .bright: 1
        }
    }
}

struct PromptSessionConfiguration: Equatable {
    let script: String
    let sessionMode: SessionMode
    let cameraEnabled: Bool
    let followMode: FollowMode
    let mirrorEnabled: Bool
    let mirrorAxis: PromptMirrorAxis
    let readingPosition: PromptReadingPosition
    let scrollSpeed: Double
    let fontFamily: PromptFontFamily
    let fontSize: PromptFontSize
    let textColor: PromptColorPreset
    let cueColor: PromptColorPreset
    let cueBrightness: CueBrightness
    let overlayOpacity: Double
    let speechLocaleIdentifier: String

    var usesCamera: Bool { cameraEnabled || sessionMode == .record }
    var requiresAudioCapture: Bool { followMode.requiresMicrophone || sessionMode == .record }
    /// Audio analysis powers Word Tracking and Voice-Activated scrolling. A
    /// Classic recording still captures microphone audio in the movie, but it
    /// does not need per-buffer speech or level processing.
    var audioAnalysisEnabled: Bool { followMode.requiresMicrophone }
}

struct PromptDisplaySettings: Equatable {
    var mirrorEnabled: Bool
    var mirrorAxis: PromptMirrorAxis
    var readingPosition: PromptReadingPosition
    var fontSize: PromptFontSize

    init(configuration: PromptSessionConfiguration) {
        mirrorEnabled = configuration.mirrorEnabled
        mirrorAxis = configuration.mirrorAxis
        readingPosition = configuration.readingPosition
        fontSize = configuration.fontSize
    }
}
