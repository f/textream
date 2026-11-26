import AppKit

/// Navigation keys are handled only by the focused reading panel.
enum PrompterKeyboardShortcuts {
    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> PromptNavigationCommand? {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        if flags.isEmpty {
            switch keyCode {
            case 123: return .backSentence // Left
            case 126: return .backOneScreen // Up
            case 124: return .forwardSentence // Right
            case 125: return .forwardOneScreen // Down
            default: return nil
            }
        }
        if flags == .command && keyCode == 126 { return .beginning }
        return nil
    }
}
