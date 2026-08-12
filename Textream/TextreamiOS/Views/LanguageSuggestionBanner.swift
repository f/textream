import SwiftUI

struct LanguageSuggestionBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let suggestion: SpeechLanguageSuggestion
    let currentLocaleIdentifier: String
    let onUse: () -> Void
    let onDismiss: () -> Void

    private var currentLocaleName: String {
        Locale.current.localizedString(forIdentifier: currentLocaleIdentifier)
            ?? currentLocaleIdentifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        suggestionIcon
                        Spacer()
                        dismissButton
                    }
                    suggestionText
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    suggestionIcon
                    suggestionText
                    Spacer(minLength: 4)
                    dismissButton
                }
            }

            Button("Use \(suggestion.languageName)", action: onUse)
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .accessibilityHint("Changes Word Tracking to \(suggestion.localeName)")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.indigo.opacity(0.35), lineWidth: 1)
        }
        .accessibilityIdentifier("languageSuggestionBanner")
    }

    private var suggestionIcon: some View {
        Image(systemName: "character.bubble.fill")
            .foregroundStyle(.indigo)
            .accessibilityHidden(true)
    }

    private var suggestionText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("This script looks like \(suggestion.languageName).")
                .font(.subheadline.weight(.semibold))
            Text("Word Tracking is currently set to \(currentLocaleName).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Dismiss language suggestion")
    }
}
