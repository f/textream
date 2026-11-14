import Foundation

// MARK: - Director State (App → Web)

struct DirectorState: Codable {
    let formattedRuns: [TextColorRun]
    let editorPalette: [String]
    let readUTF16Count: Int
    let words: [String]
    let highlightedCharCount: Int
    let totalCharCount: Int
    let isActive: Bool
    let isDone: Bool
    let isListening: Bool
    let fontColor: String
    let cueColor: String
    let lastSpokenText: String
    let audioLevels: [Double]
}

// MARK: - Director Command (Web → App)

struct DirectorCommand: Codable {
    let type: String          // "setText", "updateText", "stop"
    let text: String?
    let readCharCount: Int?
    let formattedRuns: [TextColorRun]?

    var formattedPage: FormattedPage? {
        guard let text else { return nil }
        if let formattedRuns {
            guard formattedRuns.map(\.text).joined() == text else { return nil }
            return FormattedPage(runs: formattedRuns).normalizedForDirector
        }
        return FormattedPage(text).normalizedForDirector
    }
}
