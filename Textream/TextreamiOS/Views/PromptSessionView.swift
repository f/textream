import AVFoundation
import SwiftUI

struct PromptSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var controller: PromptSessionController
    @State private var displaySettings: PromptDisplaySettings
    @State private var isClosing = false
    @State private var isConfirmingDiscard = false
    @State private var isShowingSavedRecordings = false
    @State private var isSavedRecordingPlaced = false
    @State private var closeControlMaxY: CGFloat = 0
    @State private var bottomControlOverlayHeight: CGFloat = 0
    @State private var idleTimerOwner = UUID()
    @State private var isPromptSessionVisible = false
    @State private var isShowingMirrorSettings = false
    @State private var showsSessionControls = true
    private let onScrollSpeedChanged: (Double) -> Void
    private let onDisplaySettingsChanged: (PromptDisplaySettings) -> Void

    init(
        configuration: PromptSessionConfiguration,
        onScrollSpeedChanged: @escaping (Double) -> Void = { _ in },
        onDisplaySettingsChanged: @escaping (PromptDisplaySettings) -> Void = { _ in }
    ) {
        self.onScrollSpeedChanged = onScrollSpeedChanged
        self.onDisplaySettingsChanged = onDisplaySettingsChanged
        _controller = State(initialValue: PromptSessionController(configuration: configuration))
        _displaySettings = State(
            initialValue: PromptDisplaySettings(configuration: configuration)
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let isMirrorActive = PromptMirrorPresentation.isActive(
                enabled: displaySettings.mirrorEnabled,
                sessionMode: controller.configuration.sessionMode,
                viewportSize: geometry.size
            )
            ZStack {
                stageBackground
                    .accessibilityHidden(isShowingMirrorSettings)

                if controller.showsCamera {
                    Color.black.opacity(controller.configuration.overlayOpacity)
                        .ignoresSafeArea()
                }

                PromptTextView(
                    prompt: controller.prompt,
                    highlightedCharacterCount: controller.effectiveCharacterCount,
                    font: controller.configuration.fontFamily.uiFont(
                        size: responsiveFontSize(isLandscape: isLandscape),
                        weight: .semibold
                    ),
                    textColor: controller.configuration.textColor.uiColor,
                    cueColor: controller.configuration.cueColor.uiColor,
                    cueUnreadOpacity: controller.configuration.cueBrightness.unreadOpacity,
                    cueReadOpacity: controller.configuration.cueBrightness.readOpacity,
                    wordTracking: controller.configuration.followMode == .wordTracking,
                    continuousWordProgress: controller.continuousWordProgress,
                    allowsHorizontalSpeedAdjustment: controller.canAdjustScrollSpeed,
                    readingPosition: displaySettings.readingPosition,
                    topOverlayClearance: max(
                        geometry.safeAreaInsets.top,
                        closeControlMaxY
                    ),
                    bottomOverlayClearance: bottomControlOverlayHeight,
                    horizontalTextInsets: UIEdgeInsets(
                        top: 0,
                        left: max(16, geometry.safeAreaInsets.leading + 12),
                        bottom: 0,
                        right: max(16, geometry.safeAreaInsets.trailing + 12)
                    ),
                    onWordTap: controller.jump,
                    onManualScrollBegan: controller.beginManualScroll,
                    onManualScrollEnded: controller.finishManualScroll,
                    onSpeedAdjustmentBegan: controller.beginScrollSpeedAdjustment,
                    onSpeedAdjustmentChanged: { translation, width in
                        controller.updateScrollSpeedAdjustment(
                            horizontalTranslation: PromptMirrorPresentation.deviceHorizontalTranslation(
                                from: translation,
                                isActive: isMirrorActive,
                                axis: displaySettings.mirrorAxis
                            ),
                            viewWidth: width
                        )
                    },
                    onSpeedAdjustmentEnded: finishScrollSpeedAdjustment
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .scaleEffect(
                    x: isMirrorActive ? displaySettings.mirrorAxis.scaleX : 1,
                    y: isMirrorActive ? displaySettings.mirrorAxis.scaleY : 1
                )
                .mask(verticalFade)
                .accessibilityHidden(isShowingMirrorSettings)
                .accessibilityIdentifier("promptText")
                .zIndex(0)

                if controller.isAdjustingScrollSpeed {
                    scrollSpeedIndicator
                        .allowsHitTesting(false)
                        .zIndex(2)
                }

                if showsSessionControls {
                    VStack(spacing: 0) {
                        Spacer()

                        bottomControls(isLandscape: isLandscape)
                            .padding(.leading, max(18, geometry.safeAreaInsets.leading + 18))
                            .padding(.trailing, max(18, geometry.safeAreaInsets.trailing + 18))
                            .padding(.bottom, geometry.safeAreaInsets.bottom + 10)
                            .background {
                                GeometryReader { controlsGeometry in
                                    Color.clear.preference(
                                        key: BottomControlOverlayHeightKey.self,
                                        value: controlsGeometry.size.height
                                    )
                                }
                            }
                    }
                    .transition(.opacity)
                    .accessibilityHidden(isShowingMirrorSettings)
                    .zIndex(3)
                }

                if isShowingMirrorSettings {
                    Color.black.opacity(0.24)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.snappy) { isShowingMirrorSettings = false }
                        }
                        .accessibilityHidden(true)
                        .zIndex(4)

                    MirrorSessionSettingsPanel(
                        settings: $displaySettings,
                        scrollSpeed: Binding(
                            get: { controller.scrollSpeed },
                            set: { speed in
                                controller.setScrollSpeed(speed)
                                onScrollSpeedChanged(controller.scrollSpeed)
                            }
                        ),
                        canAdjustScrollSpeed: controller.canAdjustScrollSpeed,
                        isLandscape: isLandscape,
                        showsSessionControls: $showsSessionControls,
                        onClose: {
                            withAnimation(.snappy) { isShowingMirrorSettings = false }
                        }
                    )
                    .frame(
                        width: min(
                            isLandscape ? 680 : 360,
                            max(
                                280,
                                geometry.size.width
                                    - geometry.safeAreaInsets.leading
                                    - geometry.safeAreaInsets.trailing
                                    - 32
                            )
                        )
                    )
                    .frame(
                        maxHeight: max(
                            180,
                            geometry.size.height
                                - geometry.safeAreaInsets.top
                                - geometry.safeAreaInsets.bottom
                                - 76
                        )
                    )
                    .padding(.top, max(58, geometry.safeAreaInsets.top + 48))
                    .padding(.trailing, max(16, geometry.safeAreaInsets.trailing + 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity))
                    .zIndex(5)
                }

                VStack(spacing: 0) {
                    HStack {
                        closeButton
                        Spacer(minLength: 0)
                        if controller.configuration.sessionMode == .read {
                            mirrorSettingsButton(isMirrorActive: isMirrorActive)
                        }
                    }
                    .frame(height: 44)
                    .padding(.top, 8)
                    .padding(.leading, max(24, geometry.safeAreaInsets.leading + 20))
                    .padding(.trailing, max(16, geometry.safeAreaInsets.trailing + 14))
                    .background {
                        GeometryReader { closeGeometry in
                            Color.clear.preference(
                                key: CloseControlMaxYKey.self,
                                value: closeGeometry.frame(in: .named("promptSessionStage")).maxY
                            )
                        }
                    }

                    Spacer(minLength: 0)
                }
                .ignoresSafeArea(edges: .top)
                .zIndex(6)
            }
            .coordinateSpace(name: "promptSessionStage")
            .onPreferenceChange(BottomControlOverlayHeightKey.self) { height in
                guard abs(bottomControlOverlayHeight - height) > 0.5 else { return }
                bottomControlOverlayHeight = height
            }
            .onPreferenceChange(CloseControlMaxYKey.self) { maxY in
                guard abs(closeControlMaxY - maxY) > 0.5 else { return }
                closeControlMaxY = maxY
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: displaySettings) { _, settings in
            onDisplaySettingsChanged(settings)
        }
        .onChange(of: showsSessionControls) { _, isVisible in
            if !isVisible { bottomControlOverlayHeight = 0 }
        }
        .onAppear {
            isPromptSessionVisible = true
            updateIdleTimer(for: scenePhase)
        }
        .task { await controller.prepare() }
        .onChange(of: scenePhase) { _, phase in
            updateIdleTimer(for: phase)
            if phase != .active {
                finishScrollSpeedAdjustment()
                controller.handleSceneBecameInactive()
            }
        }
        .onDisappear {
            finishScrollSpeedAdjustment()
            isShowingMirrorSettings = false
            if !isShowingSavedRecordings {
                isPromptSessionVisible = false
                PromptSessionIdleTimerCoordinator.shared.release(owner: idleTimerOwner)
                controller.shutdown()
            }
        }
        .confirmationDialog(
            "Discard pending recording?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Recording", role: .destructive) {
                controller.discardPendingRecording()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the recording that has not been saved to Photos.")
        }
        .sheet(isPresented: $isShowingSavedRecordings) {
            SavedRecordingsGallery(store: controller.captureController.savedRecordingsStore)
        }
        .onChange(of: controller.captureController.lastSavedRecording?.assetIdentifier) { _, identifier in
            guard identifier != nil else {
                isSavedRecordingPlaced = false
                return
            }
            guard !accessibilityReduceMotion else {
                isSavedRecordingPlaced = true
                return
            }
            isSavedRecordingPlaced = false
            Task { @MainActor in
                await Task.yield()
                withAnimation(.spring(response: 0.68, dampingFraction: 0.7)) {
                    isSavedRecordingPlaced = true
                }
            }
        }
    }

    @ViewBuilder
    private var stageBackground: some View {
        if controller.showsCamera, controller.captureController.isCameraAvailable {
            CameraPreview(controller: controller.captureController)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .accessibilityIdentifier("cameraPreview")
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.055, green: 0.055, blue: 0.085), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                if controller.showsCamera, controller.isPrepared {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 36, weight: .light))
                        Text(cameraUnavailableMessage)
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.2))
                    .accessibilityIdentifier("cameraUnavailablePlaceholder")
                }
            }
        }
    }

    private var closeButton: some View {
        Button {
            closeSession()
        } label: {
            HStack(spacing: 7) {
                if isClosing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Text("Close")
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isClosing)
        .accessibilityLabel("Close")
        .accessibilityIdentifier("closeSessionButton")
        .accessibilityHidden(isShowingMirrorSettings)
    }

    private func mirrorSettingsButton(isMirrorActive: Bool) -> some View {
        Button {
            withAnimation(.snappy) { isShowingMirrorSettings.toggle() }
        } label: {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .glassEffect(
                    .regular
                        .tint(
                            (isShowingMirrorSettings || isMirrorActive)
                                ? Color.indigo.opacity(0.32)
                                : Color.black.opacity(0.12)
                        )
                        .interactive(),
                    in: .circle
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mirror settings")
        .accessibilityValue(isMirrorActive ? "Mirror active" : "Mirror inactive")
        .accessibilityIdentifier("mirrorSessionSettingsButton")
    }

    private func bottomControls(isLandscape: Bool) -> some View {
        VStack(spacing: isLandscape ? 8 : 12) {
            HStack(spacing: 10) {
                if controller.configuration.audioAnalysisEnabled {
                    AudioMeter(follower: controller.speechFollower)
                        .frame(width: 82, height: 18)
                }

                ProgressView(value: controller.progress)
                    .tint(controller.configuration.textColor.color)

                Text("\(Int(controller.progress * 100))%")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(.horizontal, 15)
            .frame(height: 38)
            .glassEffect(.regular.tint(.black.opacity(0.2)), in: .capsule)
            .frame(maxWidth: isLandscape ? 500 : .infinity)
            .frame(maxWidth: .infinity)

            if controller.configuration.followMode == .wordTracking,
               !controller.speechFollower.lastSpokenText.isEmpty {
                Text(controller.speechFollower.lastSpokenText.split(separator: " ").suffix(4).joined(separator: " "))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .transition(.opacity)
                    .frame(maxWidth: isLandscape ? 500 : .infinity)
            }

            if controller.configuration.sessionMode == .record {
                if controller.captureController.canRetrySave {
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            Button("Retry Save") {
                                Task { await controller.retrySaving() }
                            }
                            .buttonStyle(.glassProminent)
                            .tint(.indigo)
                            .accessibilityIdentifier("retrySaveButton")

                            Button(role: .destructive) {
                                isConfirmingDiscard = true
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 40, height: 40)
                            }
                            .buttonStyle(.glass)
                            .accessibilityLabel("Discard pending recording")
                            .accessibilityIdentifier("discardPendingRecordingButton")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                }

                sessionFeedback(isLandscape: isLandscape)

                // Keep the recording row after every state-dependent view.
                // The bottom status has a fixed height, so clearing a saved
                // banner or showing recovery controls cannot move the record
                // button when capture changes state.
                recordingControls
            } else {
                GlassEffectContainer(spacing: 18) {
                    HStack(spacing: 18) {
                        Button {
                            Task { await controller.toggleCameraVisibility() }
                        } label: {
                            Image(systemName: controller.showsCamera ? "camera.fill" : "camera")
                                .frame(width: 42, height: 42)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel(controller.showsCamera ? "Hide camera" : "Show camera")
                        .accessibilityIdentifier("sessionCameraToggle")

                        Button {
                            controller.toggleReadPause()
                        } label: {
                            Image(systemName: controller.isPromptRunning ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .bold))
                                .frame(width: 58, height: 52)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.indigo)
                        .disabled(!controller.canStartPrompt || controller.isFinished)
                        .accessibilityLabel(controller.isPromptRunning ? "Pause" : "Play")
                        .accessibilityIdentifier("playPauseButton")

                        Button {
                            controller.jump(to: 0)
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .frame(width: 42, height: 42)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Restart script")
                        .accessibilityIdentifier("restartScriptButton")
                    }
                }

                sessionFeedback(isLandscape: isLandscape)
            }

            bottomStatus
                .frame(maxWidth: isLandscape ? 500 : .infinity)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var recordingControls: some View {
        GeometryReader { controlsGeometry in
            let sideControlSize: CGFloat = 58
            let recordControlSize: CGFloat = 84
            let controlSpacing: CGFloat = 12
            let preferredSideOffset = recordControlSize / 2 + controlSpacing + sideControlSize / 2
            let sideOffset = min(
                preferredSideOffset,
                max(0, controlsGeometry.size.width / 2 - sideControlSize / 2)
            )
            let canSwitchCamera = controller.showsCamera
                && controller.captureController.isCameraAvailable
                && controller.captureController.recordingState == .idle
                && !controller.captureController.isSwitchingCamera

            ZStack {
                savedRecordingsButton(dropOffset: sideOffset)
                    .offset(x: -sideOffset)

                RecordButton(
                    recordingState: controller.captureController.recordingState,
                    canStartRecording: controller.canRecord,
                    reduceMotion: accessibilityReduceMotion,
                    action: { Task { await controller.toggleRecording() } }
                )

                Button {
                    controller.switchCamera()
                } label: {
                    RecordSideControlSurface {
                        RecordSideControlSymbol(
                            systemName: "arrow.triangle.2.circlepath.camera.fill"
                        )
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSwitchCamera)
                .opacity(canSwitchCamera ? 1 : 0.45)
                .accessibilityLabel("Switch camera")
                .accessibilityIdentifier("switchCameraButton")
                .offset(x: sideOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 84)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func savedRecordingsButton(dropOffset: CGFloat) -> some View {
        if let savedRecording = controller.captureController.lastSavedRecording,
           controller.captureController.savedRecordingsStore.recordedAssetIdentifiers.contains(
               savedRecording.assetIdentifier
           ) {
            Button {
                isShowingSavedRecordings = true
            } label: {
                SavedRecordingThumbnail(image: savedRecording.thumbnail)
            }
            .buttonStyle(.plain)
            .disabled(controller.captureController.recordingState != .idle)
            .offset(
                x: isSavedRecordingPlaced ? 0 : dropOffset,
                y: isSavedRecordingPlaced ? 0 : -24
            )
            .scaleEffect(isSavedRecordingPlaced ? 1 : 0.28)
            .rotationEffect(.degrees(isSavedRecordingPlaced ? 0 : 14))
            .opacity(isSavedRecordingPlaced ? 1 : 0.15)
            .allowsHitTesting(isSavedRecordingPlaced)
            .accessibilityLabel("Show Textream recordings")
            .accessibilityHint("Opens videos saved by Textream in Photos")
            .accessibilityIdentifier("savedRecordingsButton")
        } else if controller.captureController.savedRecordingsStore.hasRememberedRecordings {
            Button {
                isShowingSavedRecordings = true
            } label: {
                SavedRecordingsLibraryIcon()
            }
            .buttonStyle(.plain)
            .disabled(controller.captureController.recordingState != .idle)
            .accessibilityLabel("Show Textream recordings")
            .accessibilityHint("Opens videos saved by Textream in Photos")
            .accessibilityIdentifier("savedRecordingsButton")
        } else {
            Color.clear
                .frame(width: 58, height: 58)
                .accessibilityHidden(true)
        }
    }

    private var bottomStatus: some View {
        HStack(spacing: 6) {
            if controller.captureController.isActivelyRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
            }

            Text(controller.statusText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption2.weight(.medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.68))
        .frame(minHeight: 16)
        .accessibilityIdentifier("sessionStatus")
    }

    @ViewBuilder
    private func sessionFeedback(isLandscape: Bool) -> some View {
        if let message = controller.errorMessage {
            errorBanner(message)
                .frame(maxWidth: isLandscape ? 500 : .infinity)
        } else if let saved = controller.captureController.lastSavedMessage {
            savedBanner(saved)
                .frame(maxWidth: isLandscape ? 500 : .infinity)
        }
    }

    private var verticalFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: 0.07),
                .init(color: .white, location: 0.9),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var scrollSpeedIndicator: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.left")
            Text(String(format: "%.1f words/s", controller.scrollSpeed))
                .font(.headline.monospacedDigit())
            Image(systemName: "chevron.right")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 50)
        .glassEffect(.regular.tint(.black.opacity(0.38)), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scroll speed")
        .accessibilityValue(String(format: "%.1f words per second", controller.scrollSpeed))
        .accessibilityIdentifier("scrollSpeedSwipeIndicator")
    }

    private func responsiveFontSize(isLandscape: Bool) -> CGFloat {
        displaySettings.fontSize.pointSize * (isLandscape ? 0.86 : 1)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.red.opacity(0.45), in: Capsule())
            .glassEffect(.regular.tint(.red.opacity(0.35)), in: .capsule)
            .lineLimit(2)
            .accessibilityIdentifier("sessionErrorBanner")
    }

    private func savedBanner(_ message: String) -> some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular.tint(.green.opacity(0.35)), in: .capsule)
            .accessibilityIdentifier("savedToPhotosBanner")
    }

    private func closeSession() {
        guard !isClosing else { return }
        isClosing = true
        Task {
            await controller.finish()
            dismiss()
        }
    }

    private func finishScrollSpeedAdjustment() {
        guard controller.isAdjustingScrollSpeed else { return }
        controller.finishScrollSpeedAdjustment()
        onScrollSpeedChanged(controller.scrollSpeed)
    }

    private func updateIdleTimer(for phase: ScenePhase) {
        PromptSessionIdleTimerCoordinator.shared.update(
            isActive: isPromptSessionVisible && phase == .active,
            owner: idleTimerOwner
        )
    }

    private var cameraUnavailableMessage: String {
        #if targetEnvironment(simulator)
        "Camera unavailable in Simulator"
        #else
        "Camera unavailable"
        #endif
    }
}

private struct MirrorSessionSettingsPanel: View {
    @Binding var settings: PromptDisplaySettings
    let scrollSpeed: Binding<Double>
    let canAdjustScrollSpeed: Bool
    let isLandscape: Bool
    @Binding var showsSessionControls: Bool
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                panelHeader

                if isLandscape {
                    HStack(alignment: .top, spacing: 16) {
                        mirrorControls
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                        Divider()

                        readingControls
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    mirrorControls
                    Divider()
                    readingControls
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .glassEffect(
            .regular.tint(.black.opacity(0.36)),
            in: .rect(cornerRadius: 24)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("mirrorSessionSettingsPanel")
    }

    private var panelHeader: some View {
        HStack(spacing: 10) {
            Label("Mirror settings", systemImage: "arrow.left.and.right")
                .font(.headline)

            Spacer(minLength: 8)

            Text(isLandscape ? "LANDSCAPE" : "ROTATE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(isLandscape ? Color.green : Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.08), in: Capsule())

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.08), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close mirror settings")
            .accessibilityIdentifier("closeMirrorSettingsButton")
        }
    }

    private var mirrorControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Mirror prompt", isOn: $settings.mirrorEnabled)
                .font(.subheadline.weight(.semibold))
                .tint(.indigo)
                .accessibilityIdentifier("sessionMirrorToggle")

            if settings.mirrorEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    settingLabel("MIRROR AXIS")

                    Picker("Mirror axis", selection: $settings.mirrorAxis) {
                        ForEach(PromptMirrorAxis.allCases) { axis in
                            Text(axis.label).tag(axis)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("sessionMirrorAxisPicker")

                    Text(
                        isLandscape
                            ? settings.mirrorAxis.description
                            : "Rotate the device to landscape to activate mirroring."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var readingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                settingLabel("READING POSITION")

                Picker("Reading position", selection: $settings.readingPosition) {
                    ForEach(PromptReadingPosition.allCases) { position in
                        Text(position.label).tag(position)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("sessionReadingPositionPicker")
            }

            VStack(alignment: .leading, spacing: 6) {
                settingLabel("TEXT SIZE")

                Picker("Text size", selection: $settings.fontSize) {
                    ForEach(PromptFontSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("sessionFontSizePicker")
            }

            if canAdjustScrollSpeed {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        settingLabel("SCROLL SPEED")
                        Spacer()
                        Text(String(format: "%.1f words/s", scrollSpeed.wrappedValue))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: scrollSpeed,
                        in: PromptScrollSpeedAdjustment.minimumSpeed...PromptScrollSpeedAdjustment.maximumSpeed,
                        step: PromptScrollSpeedAdjustment.speedStep
                    )
                    .tint(.indigo)
                    .accessibilityIdentifier("sessionScrollSpeedSlider")
                }
            }

            Toggle("Show playback controls", isOn: $showsSessionControls)
                .font(.subheadline.weight(.semibold))
                .tint(.indigo)
                .accessibilityIdentifier("sessionControlsToggle")
        }
    }

    private func settingLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
    }
}

private struct BottomControlOverlayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CloseControlMaxYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AudioMeter: View {
    @Bindable var follower: SpeechFollower

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(follower.audioLevels.suffix(14).enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.white.opacity(0.38 + min(0.5, level * 2)))
                    .frame(width: 3, height: max(3, min(18, 3 + level * 30)))
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct RecordControlPresentation: Equatable {
    let showsStopShape: Bool
    let showsActivity: Bool
    let isEnabled: Bool
    let accessibilityLabel: String
    let accessibilityValue: String

    init(recordingState: CaptureRecordingState, canStartRecording: Bool) {
        switch recordingState {
        case .idle:
            showsStopShape = false
            showsActivity = false
            isEnabled = canStartRecording
            accessibilityLabel = "Start recording"
            accessibilityValue = canStartRecording ? "Ready" : "Unavailable"
        case .starting:
            showsStopShape = false
            showsActivity = true
            isEnabled = true
            accessibilityLabel = "Stop recording"
            accessibilityValue = "Preparing recording"
        case .recording:
            showsStopShape = true
            showsActivity = false
            isEnabled = true
            accessibilityLabel = "Stop recording"
            accessibilityValue = "Recording"
        case .stopping:
            showsStopShape = true
            showsActivity = true
            isEnabled = false
            accessibilityLabel = "Finishing recording"
            accessibilityValue = "Finishing recording"
        case .saving:
            showsStopShape = false
            showsActivity = true
            isEnabled = false
            accessibilityLabel = "Saving recording"
            accessibilityValue = "Saving to Photos"
        }
    }
}

private struct RecordButton: View {
    let recordingState: CaptureRecordingState
    let canStartRecording: Bool
    let reduceMotion: Bool
    let action: () -> Void

    private var presentation: RecordControlPresentation {
        RecordControlPresentation(
            recordingState: recordingState,
            canStartRecording: canStartRecording
        )
    }

    private var stateAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.3)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(presentation.isEnabled ? 0.95 : 0.42), lineWidth: 4)
                    .frame(width: 76, height: 76)

                RoundedRectangle(
                    cornerRadius: presentation.showsStopShape ? 7 : 30,
                    style: .continuous
                )
                .fill(.red)
                .frame(
                    width: presentation.showsStopShape ? 30 : 60,
                    height: presentation.showsStopShape ? 30 : 60
                )
                .animation(stateAnimation, value: presentation.showsStopShape)

                if presentation.showsActivity {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                        .padding(5)
                        .background(.black.opacity(0.55), in: Circle())
                        .offset(x: 27, y: -27)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 84, height: 84)
            .animation(stateAnimation, value: presentation.showsActivity)
        }
        .buttonStyle(.plain)
        .disabled(!presentation.isEnabled)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityIdentifier("recordButton")
    }
}

private struct SavedRecordingThumbnail: View {
    let image: UIImage

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.18))
                .glassEffect(.regular.tint(.white.opacity(0.08)).interactive(), in: .circle)

            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 54, height: 54)
                .clipShape(Circle())
                .accessibilityHidden(true)

            RecordSideControlSymbol(systemName: "photo.on.rectangle.angled")
                .background(.black.opacity(0.36), in: Circle())
        }
        .frame(width: 58, height: 58)
        .overlay {
            Circle()
                .stroke(.white.opacity(0.5), lineWidth: 1)
        }
        .contentShape(Circle())
    }
}

private struct SavedRecordingsLibraryIcon: View {
    var body: some View {
        RecordSideControlSurface {
            RecordSideControlSymbol(systemName: "photo.on.rectangle.angled")
        }
    }
}

private struct RecordSideControlSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.18))

            content
        }
        .frame(width: 58, height: 58)
        .glassEffect(.regular.tint(.white.opacity(0.08)).interactive(), in: .circle)
        .overlay {
            Circle()
                .stroke(.white.opacity(0.5), lineWidth: 1)
        }
        .contentShape(Circle())
    }
}

private struct RecordSideControlSymbol: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.monochrome)
            .imageScale(.medium)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)
    }
}
