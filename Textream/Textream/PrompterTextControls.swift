import SwiftUI

/// Settings and the live prompter share the same saved typography preferences.
struct PrompterTextControls: View {
    @Bindable var settings: NotchSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            fontSizeControl
            Divider()
            lineSpacingControl
        }
    }

    private var fontSizeControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Text Size")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                TextField("Text Size", value: $settings.fontSize, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .accessibilityIdentifier("prompterFontSize")
                Text("pt")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    settings.fontSize -= 2
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .help("Decrease text size")
                .accessibilityLabel("Decrease text size")
                .disabled(settings.fontSize <= NotchSettings.fontSizeRange.lowerBound)

                Slider(value: $settings.fontSize, in: NotchSettings.fontSizeRange, step: 1)
                    .accessibilityLabel("Text size")

                Button {
                    settings.fontSize += 2
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .help("Increase text size")
                .accessibilityLabel("Increase text size")
                .disabled(settings.fontSize >= NotchSettings.fontSizeRange.upperBound)
            }
            .buttonStyle(.borderless)
        }
    }

    private var lineSpacingControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Line Spacing")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                TextField("Line Spacing", value: $settings.lineSpacingMultiplier, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .accessibilityIdentifier("prompterLineSpacing")
                Text("×")
                    .foregroundStyle(.secondary)
            }
            Slider(value: $settings.lineSpacingMultiplier, in: NotchSettings.lineSpacingMultiplierRange, step: 0.1)
                .accessibilityLabel("Line spacing")
            Text("Space between lines. Your choice is saved automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
