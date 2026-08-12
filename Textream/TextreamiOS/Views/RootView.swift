import SwiftUI

struct RootView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var model: AppModel
    @State private var floatingActionOverlayHeight = RootFloatingActionLayout.fallbackOverlayHeight
    @State private var isShowingExpandedScriptEditor = false
    @State private var isInlineScriptEditorFocused = false
    @State private var languageSuggestions = SpeechLanguageSuggestionCoordinator()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppBackground()
                    .ignoresSafeArea()

                if geometry.size.width > 700 || geometry.size.width > geometry.size.height * 1.35 {
                    VStack(spacing: 18) {
                        header

                        HStack(spacing: 18) {
                            editorPanel
                            landscapeSetupColumn
                                .frame(width: min(390, geometry.size.width * 0.42))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                } else {
                    ZStack(alignment: .bottom) {
                        ScrollView {
                            VStack(spacing: 18) {
                                header

                                editorPanel
                                    .frame(height: max(280, min(380, geometry.size.height * 0.42)))

                                setupPanel
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 14)
                            .padding(
                                .bottom,
                                RootFloatingActionLayout.contentBottomClearance(
                                    measuredOverlayHeight: floatingActionOverlayHeight
                                )
                            )
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .scrollIndicators(.hidden)

                        floatingStartAction(
                            horizontalPadding: 18,
                            bottomPadding: RootFloatingActionLayout.portraitBottomPadding
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsView(model: model)
        }
        .fullScreenCover(isPresented: $isShowingExpandedScriptEditor) {
            ExpandedScriptEditor(
                model: model,
                languageSuggestions: languageSuggestions
            )
        }
        .fullScreenCover(isPresented: $model.isShowingSession) {
            PromptSessionView(
                configuration: model.configuration(),
                onScrollSpeedChanged: { speed in
                    model.scrollSpeed = speed
                },
                onDisplaySettingsChanged: { settings in
                    model.mirrorEnabled = settings.mirrorEnabled
                    model.mirrorAxis = settings.mirrorAxis
                    model.readingPosition = settings.readingPosition
                    model.fontSize = settings.fontSize
                }
            )
        }
        .onChange(of: model.sessionMode) { _, mode in
            if mode == .record { model.cameraEnabled = true }
        }
        .onChange(of: model.script) { _, script in
            languageSuggestions.schedule(
                text: script,
                currentLocaleIdentifier: model.speechLocaleIdentifier
            )
        }
        .onChange(of: model.speechLocaleIdentifier) { _, localeIdentifier in
            guard !isShowingExpandedScriptEditor else { return }
            languageSuggestions.reset(
                text: model.script,
                currentLocaleIdentifier: localeIdentifier
            )
        }
    }

    private var header: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        headerLogo
                        headerTitle
                        Spacer(minLength: 8)
                        settingsButton
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text("The teleprompter")
                            .font(.system(size: 17, weight: .medium))
                            .lineLimit(1)
                        Text("that follows you")
                            .font(.system(size: 17, weight: .medium))
                            .lineLimit(1)
                    }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("The teleprompter that follows you")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 12) {
                    headerLogo

                    VStack(alignment: .leading, spacing: 1) {
                        headerTitle
                        headerTagline
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(1)

                    Spacer()
                    settingsButton
                }
            }
        }
    }

    private var headerLogo: some View {
        Image("TextreamLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)
    }

    private var headerTitle: some View {
        Text("Textream")
            .font(.system(size: 24, weight: .bold, design: .rounded))
    }

    private var headerTagline: some View {
        Text("The teleprompter that follows you")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var settingsButton: some View {
        Button {
            model.isShowingSettings = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("settingsButton")
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Script", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                Text("\(model.normalizedScript.words.count) words")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    isInlineScriptEditorFocused = false
                    Task { @MainActor in
                        await Task.yield()
                        isShowingExpandedScriptEditor = true
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit script full screen")
                .accessibilityIdentifier("expandScriptEditorButton")
            }

            if let suggestion = languageSuggestions.suggestion {
                LanguageSuggestionBanner(
                    suggestion: suggestion,
                    currentLocaleIdentifier: model.speechLocaleIdentifier,
                    onUse: useSuggestedLanguage,
                    onDismiss: { languageSuggestions.dismiss(suggestion) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            BracketHighlightingTextEditor(
                text: $model.script,
                isFocused: $isInlineScriptEditorFocused,
                accessibilityLabel: "Script",
                accessibilityIdentifier: "scriptEditor"
            )
                .padding(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("Use [brackets] for stage directions. Textream displays them but skips them while following your voice.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .glassEffect(.regular.tint(.black.opacity(0.12)), in: .rect(cornerRadius: 28))
    }

    private func useSuggestedLanguage() {
        guard let localeIdentifier = languageSuggestions.useSuggestedLocale() else { return }
        model.speechLocaleIdentifier = localeIdentifier
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Session", selection: $model.sessionMode) {
                ForEach(SessionMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("sessionModePicker")

            VStack(alignment: .leading, spacing: 9) {
                Text("FOLLOW MODE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(FollowMode.allCases) { mode in
                            followModeButton(mode)
                        }
                    }
                }

                Text(model.followMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.followMode != .wordTracking {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Speed")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.1f words/s", model.scrollSpeed))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.scrollSpeed, in: 0.5...8, step: 0.5)
                        .tint(.indigo)
                        .accessibilityIdentifier("scrollSpeedSlider")
                }
            }

            Toggle(isOn: $model.cameraEnabled) {
                Label(
                    model.sessionMode == .record ? "Camera required for recording" : "Show camera behind prompt",
                    systemImage: model.cameraEnabled ? "camera.fill" : "camera"
                )
                .font(.subheadline.weight(.medium))
            }
            .disabled(model.sessionMode == .record)
            .tint(.indigo)
            .accessibilityIdentifier("cameraToggle")

            if model.sessionMode == .read {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $model.mirrorEnabled) {
                        Label(
                            "Mirror in landscape",
                            systemImage: "arrow.left.and.right"
                        )
                        .font(.subheadline.weight(.medium))
                    }
                    .tint(.indigo)
                    .accessibilityIdentifier("mirrorModeToggle")

                    if model.mirrorEnabled {
                        Picker("Mirror axis", selection: $model.mirrorAxis) {
                            ForEach(PromptMirrorAxis.allCases) { axis in
                                Text(axis.label).tag(axis)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("mirrorAxisPicker")

                        Text("Rotate to landscape for teleprompter glass. Prompt controls stay readable on the device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .glassEffect(.regular.tint(.black.opacity(0.1)), in: .rect(cornerRadius: 28))
    }

    private var landscapeSetupColumn: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                setupPanel
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(
                        .bottom,
                        RootFloatingActionLayout.contentBottomClearance(
                            measuredOverlayHeight: floatingActionOverlayHeight
                        )
                    )
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)

            floatingStartAction(
                horizontalPadding: 20,
                bottomPadding: RootFloatingActionLayout.landscapeBottomPadding
            )
        }
        .frame(maxHeight: .infinity)
    }

    private func floatingStartAction(horizontalPadding: CGFloat, bottomPadding: CGFloat) -> some View {
        startSessionButton
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                floatingActionOverlayHeight = height
            }
    }

    private var startSessionButton: some View {
        Button {
            model.startSession()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: startSessionIcon)
                Text(startSessionLabel)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: RootFloatingActionLayout.buttonMinimumHeight)
        }
        .buttonStyle(.glassProminent)
        .tint(.indigo)
        .disabled(!model.canStart)
        .accessibilityIdentifier("startSessionButton")
    }

    private var startSessionIcon: String {
        if model.sessionMode == .record { return "camera.fill" }
        return model.mirrorEnabled ? "arrow.left.and.right" : "play.fill"
    }

    private var startSessionLabel: String {
        if model.sessionMode == .record { return "Open Camera" }
        return model.mirrorEnabled ? "Start Mirror Mode" : "Start Prompter"
    }

    @ViewBuilder
    private func followModeButton(_ mode: FollowMode) -> some View {
        let button = Button {
            withAnimation(.snappy) { model.followMode = mode }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: mode.icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(mode.shortLabel)
                    .font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 54)
        }
        .accessibilityIdentifier("followMode_\(mode.rawValue)")

        if model.followMode == mode {
            button
                .buttonStyle(.glassProminent)
                .tint(.indigo)
        } else {
            button
                .buttonStyle(.glass)
        }
    }
}

enum RootFloatingActionLayout {
    static let buttonMinimumHeight: CGFloat = 48
    static let clearanceGap: CGFloat = 12
    static let portraitBottomPadding: CGFloat = 12
    static let landscapeBottomPadding: CGFloat = 18
    static let fallbackOverlayHeight: CGFloat = buttonMinimumHeight + landscapeBottomPadding

    static func contentBottomClearance(measuredOverlayHeight: CGFloat) -> CGFloat {
        max(measuredOverlayHeight, fallbackOverlayHeight) + clearanceGap
    }
}

private struct ExpandedScriptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let languageSuggestions: SpeechLanguageSuggestionCoordinator
    @State private var draft: String
    @State private var isEditorFocused = false

    init(model: AppModel, languageSuggestions: SpeechLanguageSuggestionCoordinator) {
        self.model = model
        self.languageSuggestions = languageSuggestions
        _draft = State(initialValue: model.script)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                if let suggestion = languageSuggestions.suggestion {
                    LanguageSuggestionBanner(
                        suggestion: suggestion,
                        currentLocaleIdentifier: model.speechLocaleIdentifier,
                        onUse: useSuggestedLanguage,
                        onDismiss: { languageSuggestions.dismiss(suggestion) }
                    )
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                BracketHighlightingTextEditor(
                    text: $draft,
                    isFocused: $isEditorFocused,
                    accessibilityLabel: "Script",
                    accessibilityIdentifier: "expandedScriptEditor"
                )
                .scrollDismissesKeyboard(.interactively)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
                .background(AppBackground().ignoresSafeArea())
                .navigationTitle("Edit Script")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            commitDraft()
                            dismiss()
                        }
                            .buttonStyle(.glassProminent)
                    }

                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { isEditorFocused = false }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .task {
            await Task.yield()
            isEditorFocused = true
        }
        .onChange(of: draft, initial: true) { _, text in
            languageSuggestions.schedule(
                text: text,
                currentLocaleIdentifier: model.speechLocaleIdentifier
            )
        }
        .onChange(of: model.speechLocaleIdentifier) { _, localeIdentifier in
            languageSuggestions.reset(
                text: draft,
                currentLocaleIdentifier: localeIdentifier
            )
        }
        .onDisappear { commitDraft() }
    }

    private func commitDraft() {
        guard model.script != draft else { return }
        model.script = draft
    }

    private func useSuggestedLanguage() {
        guard let localeIdentifier = languageSuggestions.useSuggestedLocale() else { return }
        model.speechLocaleIdentifier = localeIdentifier
    }
}

private struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.035, blue: 0.055), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(.indigo.opacity(0.22))
                .frame(width: 360, height: 360)
                .blur(radius: 90)
                .offset(x: -170, y: -270)
            Circle()
                .fill(.blue.opacity(0.14))
                .frame(width: 300, height: 300)
                .blur(radius: 100)
                .offset(x: 190, y: 320)
        }
    }
}
