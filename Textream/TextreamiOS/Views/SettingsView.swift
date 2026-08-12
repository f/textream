import Speech
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State private var locales: [Locale] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Mirror prompt in landscape", isOn: $model.mirrorEnabled)
                        .tint(.indigo)
                        .accessibilityIdentifier("settingsMirrorModeToggle")

                    if model.mirrorEnabled {
                        Picker("Axis", selection: $model.mirrorAxis) {
                            ForEach(PromptMirrorAxis.allCases) { axis in
                                Text(axis.label).tag(axis)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("settingsMirrorAxisPicker")

                        Text(model.mirrorAxis.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Mirror mode")
                } footer: {
                    Text("Available in a landscape Read session. The prompt is pre-flipped for use with teleprompter glass.")
                }

                Section {
                    Picker("Reading position", selection: $model.readingPosition) {
                        ForEach(PromptReadingPosition.allCases) { position in
                            Text(position.label).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("readingPositionPicker")
                } header: {
                    Text("Reading position")
                } footer: {
                    Text("Near Camera keeps the active line just below the camera and controls for better eye contact. Center keeps it in the middle of the screen.")
                }

                Section("Font") {
                    Picker("Family", selection: $model.fontFamily) {
                        ForEach(PromptFontFamily.allCases) { family in
                            Text(family.label)
                                .font(family.swiftUIFont(size: 17))
                                .tag(family)
                        }
                    }

                    Picker("Size", selection: $model.fontSize) {
                        ForEach(PromptFontSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Text color") {
                    ColorPresetPicker(selection: $model.textColor)
                }

                Section("Stage directions") {
                    ColorPresetPicker(selection: $model.cueColor)
                    Picker("Brightness", selection: $model.cueBrightness) {
                        ForEach(CueBrightness.allCases) { brightness in
                            Text(brightness.label).tag(brightness)
                        }
                    }
                }

                Section("Camera overlay") {
                    HStack {
                        Text("Opacity")
                        Slider(value: $model.overlayOpacity, in: 0.3...0.8, step: 0.05)
                            .tint(.indigo)
                        Text("\(Int(model.overlayOpacity * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }

                Section {
                    if locales.isEmpty {
                        HStack {
                            Text("Language")
                            Spacer()
                            ProgressView()
                        }
                        .accessibilityLabel("Loading speech languages")
                    } else {
                        Picker("Language", selection: $model.speechLocaleIdentifier) {
                            ForEach(locales, id: \.identifier) { locale in
                                Text(localizedName(for: locale)).tag(locale.identifier)
                            }
                        }
                    }
                } header: {
                    Text("Speech")
                } footer: {
                    Text("Word Tracking uses Apple Speech Recognition. Classic mode works without microphone or speech access.")
                }

                Section("About") {
                    VStack(spacing: 12) {
                        Image("TextreamLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                            .accessibilityHidden(true)

                        VStack(spacing: 3) {
                            Text("Textream")
                                .font(.title3.bold())
                            Text(TextreamAppInfo.versionLabel)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Text("A free, open-source teleprompter that highlights your script in real-time as you speak.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)

                    AboutLink(
                        title: "Textream for Mac",
                        subtitle: "Available on the Mac App Store",
                        systemImage: "macbook",
                        destination: TextreamAppInfo.macAppStoreURL,
                        accessibilityHint: "Opens the Textream for Mac App Store page"
                    )

                    AboutLink(
                        title: "GitHub",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        destination: URL(string: "https://github.com/f/textream")!
                    )

                    AboutLink(
                        title: "Privacy",
                        systemImage: "hand.raised.fill",
                        destination: URL(string: "https://textream.net/privacy.html")!
                    )

                    AboutLink(
                        title: "Support",
                        systemImage: "questionmark.circle.fill",
                        destination: URL(string: "https://textream.net/support.html")!
                    )

                    NavigationLink {
                        OpenDyslexicLicenseView()
                    } label: {
                        Label("Acknowledgements", systemImage: "doc.text.fill")
                    }
                    .accessibilityHint("Shows the OpenDyslexic font license")

                    VStack(spacing: 4) {
                        Text("Made by Fatih Kadir Akin")
                            .font(.footnote.weight(.medium))
                        Text("Original idea by Semih Kışlar")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .multilineTextAlignment(.center)
                }
            }
            .navigationTitle("Prompter Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard locales.isEmpty else { return }
            let supported = await Task.detached(priority: .userInitiated) {
                let currentLocale = Locale.current
                return SFSpeechRecognizer.supportedLocales().sorted {
                    let first = currentLocale.localizedString(forIdentifier: $0.identifier) ?? $0.identifier
                    let second = currentLocale.localizedString(forIdentifier: $1.identifier) ?? $1.identifier
                    return first.localizedStandardCompare(second) == .orderedAscending
                }
            }.value
            guard !Task.isCancelled else { return }
            locales = supported
            if !supported.contains(where: { $0.identifier == model.speechLocaleIdentifier }),
               let fallback = Self.bestLocale(in: supported, matching: Locale.current) {
                model.speechLocaleIdentifier = fallback.identifier
            }
        }
    }

    private func localizedName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private static func bestLocale(in supported: [Locale], matching preferred: Locale) -> Locale? {
        let normalized = preferred.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if let exact = supported.first(where: {
            $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == normalized
        }) {
            return exact
        }
        let language = preferred.language.languageCode?.identifier
        return supported.first(where: { $0.language.languageCode?.identifier == language })
            ?? supported.first(where: { $0.identifier == "en-US" })
            ?? supported.first
    }
}

struct OpenDyslexicLicenseView: View {
    private var licenseText: String {
        guard let url = Bundle.main.url(
            forResource: "OpenDyslexic-OFL",
            withExtension: "txt"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The OpenDyslexic font is distributed under the SIL Open Font License 1.1."
        }
        return text
    }

    var body: some View {
        ScrollView {
            Text(licenseText)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("OpenDyslexic License")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum TextreamAppInfo {
    static let macAppStoreURL = URL(string: "https://apps.apple.com/app/textream/id6800061488")!

    static var versionLabel: String {
        versionLabel(from: Bundle.main.infoDictionary ?? [:])
    }

    static func versionLabel(from infoDictionary: [String: Any]) -> String {
        guard let version = infoDictionary["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            return "Version unknown"
        }
        guard let build = infoDictionary["CFBundleVersion"] as? String,
              !build.isEmpty else {
            return "Version \(version)"
        }
        return "Version \(version) (\(build))"
    }
}

private struct AboutLink: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let destination: URL
    let accessibilityHint: String

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        destination: URL,
        accessibilityHint: String = "Opens in your browser"
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.destination = destination
        self.accessibilityHint = accessibilityHint
    }

    var body: some View {
        Link(destination: destination) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: systemImage)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityHint(accessibilityHint)
    }
}

private struct ColorPresetPicker: View {
    @Binding var selection: PromptColorPreset

    var body: some View {
        HStack(spacing: 14) {
            ForEach(PromptColorPreset.allCases) { preset in
                Button {
                    selection = preset
                } label: {
                    ZStack {
                        Circle()
                            .fill(preset.color)
                            .frame(width: 28, height: 28)
                        if selection == preset {
                            Circle()
                                .stroke(.white, lineWidth: 2)
                                .frame(width: 36, height: 36)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.label)
                .accessibilityAddTraits(selection == preset ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
