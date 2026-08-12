import CoreGraphics
import Foundation
import Observation

enum PromptScrollSpeedAdjustment {
    static let minimumSpeed = 0.5
    static let maximumSpeed = 8.0
    static let speedStep = 0.5

    static func isHorizontalSwipe(
        velocity: CGPoint,
        translation: CGPoint = .zero
    ) -> Bool {
        // Very slow drags can cross UIPanGestureRecognizer's movement
        // threshold while reporting almost no instantaneous velocity. Use
        // their accumulated translation only in that low-velocity case.
        let vector = max(abs(velocity.x), abs(velocity.y)) >= 24
            ? velocity
            : translation
        let horizontal = abs(vector.x)
        let vertical = abs(vector.y)
        return horizontal > vertical * 1.35
    }

    static func adjustedSpeed(
        startingSpeed: Double,
        horizontalTranslation: CGFloat,
        viewWidth: CGFloat
    ) -> Double {
        let effectiveWidth = max(160, Double(viewWidth))
        // A full-width swipe changes four words per second. The same gesture
        // therefore has a consistent feel in portrait and landscape.
        let delta = Double(horizontalTranslation) / effectiveWidth * 4
        let unsnapped = startingSpeed + delta
        let snapped = (unsnapped / speedStep).rounded() * speedStep
        return min(maximumSpeed, max(minimumSpeed, snapped))
    }
}

@Observable
@MainActor
final class PromptSessionController {
    let configuration: PromptSessionConfiguration
    let prompt: PromptScript
    let speechFollower: SpeechFollower
    let captureController: CaptureController

    private(set) var isPrepared = false
    private(set) var isPromptRunning = false
    private(set) var showsCamera: Bool
    private(set) var timerWordProgress: Double = 0
    private(set) var preparationMessage = "Preparing…"
    private(set) var isUserScrolling = false
    private(set) var isSpeechReady = false
    private(set) var scrollSpeed: Double
    private(set) var isAdjustingScrollSpeed = false

    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var lastTickTime: TimeInterval?
    @ObservationIgnored private var wasRunningBeforeManualScroll = false
    @ObservationIgnored private var scrollSpeedAtGestureStart: Double

    init(configuration: PromptSessionConfiguration) {
        self.configuration = configuration
        prompt = PromptScript(configuration.script)
        showsCamera = configuration.usesCamera
        let initialScrollSpeed = min(
            PromptScrollSpeedAdjustment.maximumSpeed,
            max(PromptScrollSpeedAdjustment.minimumSpeed, configuration.scrollSpeed)
        )
        scrollSpeed = initialScrollSpeed
        scrollSpeedAtGestureStart = initialScrollSpeed
        speechFollower = SpeechFollower()
        captureController = CaptureController()
        captureController.connectSpeechFollower(speechFollower)
    }

    var effectiveCharacterCount: Int {
        switch configuration.followMode {
        case .wordTracking:
            speechFollower.recognizedCharacterCount
        case .classic, .voiceActivated:
            prompt.characterOffset(forWordProgress: timerWordProgress)
        }
    }

    /// The fractional word position used by the two timer-driven modes.
    /// Keeping this value fractional is important: a character offset only
    /// changes in integer steps and cannot drive a genuinely smooth scroll.
    var continuousWordProgress: Double? {
        switch configuration.followMode {
        case .classic, .voiceActivated:
            timerWordProgress
        case .wordTracking:
            nil
        }
    }

    var progress: Double {
        guard prompt.characterCount > 0 else { return 0 }
        return min(1, Double(effectiveCharacterCount) / Double(prompt.characterCount))
    }

    var isFinished: Bool {
        prompt.characterCount > 0 && effectiveCharacterCount >= prompt.characterCount
    }

    var canRecord: Bool {
        isPrepared
            && captureController.recordingState == .idle
            && captureController.isCameraAvailable
            && captureController.isAudioAvailable
            && captureController.isPhotosAccessReady
            && !captureController.isSwitchingCamera
            && !captureController.canRetrySave
            && canStartPrompt
    }

    var canStartPrompt: Bool {
        isPrepared
            && (configuration.followMode != .wordTracking || isSpeechReady)
            && (!configuration.requiresAudioCapture || captureController.isAudioAvailable)
    }

    var canAdjustScrollSpeed: Bool {
        configuration.followMode == .classic || configuration.followMode == .voiceActivated
    }

    var errorMessage: String? {
        captureController.errorMessage ?? speechFollower.errorMessage
    }

    var statusText: String {
        if captureController.isSaving { return "Saving to Photos…" }
        if captureController.recordingState == .starting { return "Preparing recording…" }
        if captureController.recordingState == .stopping { return "Finishing recording…" }
        if captureController.isActivelyRecording {
            return Self.durationString(captureController.elapsedRecordingTime)
        }
        if !isPrepared { return preparationMessage }
        if isFinished { return "Script complete" }
        if !isPromptRunning {
            if configuration.sessionMode == .record {
                return captureController.canRetrySave
                    ? "Recording pending"
                    : (canRecord ? "Ready to record" : "Recording unavailable")
            }
            return "Paused"
        }
        switch configuration.followMode {
        case .classic:
            return "Auto-scrolling"
        case .voiceActivated:
            return speechFollower.isSpeaking ? "Following your voice" : "Waiting for your voice"
        case .wordTracking:
            return speechFollower.isStarting ? "Starting speech recognition…" : "Following your words"
        }
    }

    func prepare() async {
        guard !isPrepared else { return }
        preparationMessage = "Preparing speech…"
        let speechReady = await speechFollower.prepare(
            source: prompt,
            mode: configuration.followMode,
            localeIdentifier: configuration.speechLocaleIdentifier
        )

        preparationMessage = showsCamera ? "Preparing camera…" : "Preparing microphone…"
        let captureReady = await captureController.prepare(
            cameraEnabled: showsCamera,
            audioEnabled: configuration.requiresAudioCapture,
            audioAnalysisEnabled: configuration.audioAnalysisEnabled,
            cameraRequired: configuration.sessionMode == .record
        )
        if configuration.sessionMode == .record, captureReady {
            preparationMessage = "Preparing Photos…"
            _ = await captureController.preparePhotosAccessForRecording()
        }
        guard !Task.isCancelled else { return }
        isSpeechReady = speechReady
        isPrepared = true
        startProgressTimer()

        guard configuration.sessionMode == .read else {
            isPromptRunning = false
            return
        }

        if canStartPrompt {
            startPrompt()
        } else {
            isPromptRunning = false
        }
    }

    func toggleReadPause() {
        isPromptRunning ? pausePrompt() : startPrompt()
    }

    func toggleRecording() async {
        guard configuration.sessionMode == .record else { return }
        if captureController.isRecording {
            captureController.stopRecording()
            pausePrompt()
        } else {
            guard canRecord else { return }
            let started = await captureController.startRecording()
            if started { startPrompt() }
        }
    }

    func retrySaving() async {
        await captureController.retrySaving()
    }

    func discardPendingRecording() {
        captureController.discardPendingRecording()
    }

    func switchCamera() {
        captureController.switchCamera()
    }

    func toggleCameraVisibility() async {
        guard configuration.sessionMode == .read, !captureController.isRecording else { return }
        showsCamera.toggle()
        _ = await captureController.prepare(
            cameraEnabled: showsCamera,
            audioEnabled: configuration.requiresAudioCapture,
            audioAnalysisEnabled: configuration.audioAnalysisEnabled
        )
    }

    func beginManualScroll() {
        guard !isUserScrolling else { return }
        wasRunningBeforeManualScroll = isPromptRunning
        isUserScrolling = true
    }

    func finishManualScroll(at characterOffset: Int) {
        let clamped = max(0, min(characterOffset, prompt.characterCount))
        switch configuration.followMode {
        case .wordTracking:
            speechFollower.jump(to: clamped)
        case .classic, .voiceActivated:
            timerWordProgress = prompt.wordProgress(forCharacterOffset: clamped)
        }
        isUserScrolling = false
        if wasRunningBeforeManualScroll { lastTickTime = ProcessInfo.processInfo.systemUptime }
    }

    func jump(to characterOffset: Int) {
        finishManualScroll(at: characterOffset)
    }

    func beginScrollSpeedAdjustment() {
        guard canAdjustScrollSpeed else { return }
        scrollSpeedAtGestureStart = scrollSpeed
        isAdjustingScrollSpeed = true
    }

    func updateScrollSpeedAdjustment(horizontalTranslation: CGFloat, viewWidth: CGFloat) {
        guard isAdjustingScrollSpeed, canAdjustScrollSpeed else { return }
        scrollSpeed = PromptScrollSpeedAdjustment.adjustedSpeed(
            startingSpeed: scrollSpeedAtGestureStart,
            horizontalTranslation: horizontalTranslation,
            viewWidth: viewWidth
        )
    }

    func setScrollSpeed(_ speed: Double) {
        scrollSpeed = min(
            PromptScrollSpeedAdjustment.maximumSpeed,
            max(PromptScrollSpeedAdjustment.minimumSpeed, speed)
        )
        scrollSpeedAtGestureStart = scrollSpeed
    }

    func finishScrollSpeedAdjustment() {
        isAdjustingScrollSpeed = false
    }

    func handleSceneBecameInactive() {
        if captureController.isRecording { captureController.stopRecording() }
        finishScrollSpeedAdjustment()
        pausePrompt()
    }

    func finish() async {
        if captureController.isRecording { captureController.stopRecording() }
        let deadline = Date().addingTimeInterval(12)
        while (captureController.isRecording || captureController.isSaving), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        shutdown()
    }

    func shutdown() {
        progressTimer?.invalidate()
        progressTimer = nil
        speechFollower.stop()
        captureController.stopSession()
        isAdjustingScrollSpeed = false
        isPromptRunning = false
    }

    private func startPrompt() {
        guard canStartPrompt, !isFinished else { return }
        isPromptRunning = true
        lastTickTime = ProcessInfo.processInfo.systemUptime
        switch configuration.followMode {
        case .classic:
            break
        case .wordTracking, .voiceActivated:
            if speechFollower.isListening {
                speechFollower.resume()
            } else {
                speechFollower.start()
            }
        }
    }

    private func pausePrompt() {
        isPromptRunning = false
        lastTickTime = nil
        if configuration.followMode != .classic { speechFollower.pause() }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        lastTickTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        progressTimer = timer
        // A scheduled timer uses the default run-loop mode and pauses while
        // UIKit is tracking touches. The prompter must continue advancing while
        // controls are held or the user is interacting with the camera UI.
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastTickTime = now }
        guard isPromptRunning, !isUserScrolling, !isFinished else { return }
        let elapsed = min(0.25, max(0, now - (lastTickTime ?? now)))
        switch configuration.followMode {
        case .classic:
            timerWordProgress = min(
                Double(prompt.words.count),
                timerWordProgress + scrollSpeed * elapsed
            )
        case .voiceActivated:
            if speechFollower.isListening && speechFollower.isSpeaking {
                timerWordProgress = min(
                    Double(prompt.words.count),
                    timerWordProgress + scrollSpeed * elapsed
                )
            }
        case .wordTracking:
            break
        }
    }

    private static func durationString(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
