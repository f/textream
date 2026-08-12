@preconcurrency import AVFoundation
import Foundation
import Observation
import Photos
import UIKit

private final class SavedAssetIdentifier: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var storedValue: String?

    nonisolated var value: String? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

final class AudioLevelCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var maximumLevel: CGFloat = 0
    nonisolated(unsafe) private var lastPublicationTime = -TimeInterval.infinity

    nonisolated func levelToPublish(_ level: CGFloat, at timestamp: TimeInterval) -> CGFloat? {
        lock.withLock {
            maximumLevel = max(maximumLevel, level)
            guard timestamp - lastPublicationTime >= 1.0 / 15.0 else { return nil }
            lastPublicationTime = timestamp
            defer { maximumLevel = 0 }
            return maximumLevel
        }
    }
}

enum CaptureRecordingState: Equatable {
    case idle
    case starting
    case recording
    case stopping
    case saving

    /// A recording owns an additional idle-timer lease while media capture is
    /// actively starting or running. It shares the process-wide coordinator
    /// with the fullscreen prompter, so overlapping owners restore safely.
    var preventsIdleSleep: Bool {
        self == .starting || self == .recording
    }
}

enum CaptureIssue: LocalizedError {
    case cameraPermissionDenied
    case microphonePermissionDenied
    case cameraUnavailable
    case microphoneUnavailable
    case configurationFailed(String)
    case recordingUnavailable
    case photosPermissionDenied
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied:
            "Camera access is turned off for Textream."
        case .microphonePermissionDenied:
            "Microphone access is turned off for Textream."
        case .cameraUnavailable:
            "A camera is not available on this device."
        case .microphoneUnavailable:
            "A microphone is not available on this device."
        case .configurationFailed(let detail):
            "Camera setup failed: \(detail)"
        case .recordingUnavailable:
            "Video recording is not available."
        case .photosPermissionDenied:
            "Photos access is required to save this video."
        case .saveFailed(let detail):
            "The video could not be saved: \(detail)"
        }
    }
}

@Observable
@MainActor
final class CaptureController: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
    AVCaptureFileOutputRecordingDelegate, @unchecked Sendable
{
    private(set) var isSessionRunning = false
    private(set) var isCameraAvailable = false
    private(set) var isAudioAvailable = false
    private(set) var recordingState: CaptureRecordingState = .idle {
        didSet {
            idleTimerCoordinator.update(
                isActive: recordingState.preventsIdleSleep,
                owner: recordingIdleTimerOwner
            )
        }
    }
    private(set) var cameraPosition: AVCaptureDevice.Position = .front
    private(set) var activeVideoDevice: AVCaptureDevice?
    private(set) var elapsedRecordingTime: TimeInterval = 0
    private(set) var lastSavedMessage: String?
    private(set) var errorMessage: String?
    private(set) var isInterrupted = false
    private(set) var failedRecordingURL: URL?
    private(set) var isPhotosAccessReady = false
    private(set) var lastSavedRecording: SavedRecording?
    private(set) var isSwitchingCamera = false
    private(set) var isAudioAnalysisEnabled = false

    @ObservationIgnored let savedRecordingsStore = SavedRecordingsStore()

    var isRecording: Bool {
        switch recordingState {
        case .starting, .recording, .stopping: true
        case .idle, .saving: false
        }
    }

    var isActivelyRecording: Bool {
        recordingState == .recording || recordingState == .stopping
    }

    var isSaving: Bool { recordingState == .saving }
    var canRetrySave: Bool { failedRecordingURL != nil && recordingState == .idle }

    @ObservationIgnored nonisolated let session = AVCaptureSession()
    @ObservationIgnored nonisolated private let sessionQueue = DispatchQueue(
        label: "dev.fka.textream.ios.capture.session",
        qos: .userInitiated
    )
    @ObservationIgnored nonisolated private let sampleQueue = DispatchQueue(
        label: "dev.fka.textream.ios.capture.samples",
        qos: .userInitiated
    )
    @ObservationIgnored nonisolated(unsafe) private let movieOutput = AVCaptureMovieFileOutput()
    @ObservationIgnored nonisolated(unsafe) private let audioDataOutput = AVCaptureAudioDataOutput()
    @ObservationIgnored nonisolated(unsafe) private var videoInput: AVCaptureDeviceInput?
    @ObservationIgnored nonisolated(unsafe) private var audioInput: AVCaptureDeviceInput?
    @ObservationIgnored nonisolated(unsafe) private var captureRotationAngle: CGFloat = 90
    @ObservationIgnored nonisolated(unsafe) private weak var speechFollower: SpeechFollower?
    @ObservationIgnored nonisolated private let audioLevelCoalescer = AudioLevelCoalescer()
    @ObservationIgnored private var elapsedTimer: Timer?
    @ObservationIgnored private var recordingStartedAt: Date?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var configurationGeneration = 0
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var recordingAttemptURL: URL?
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let idleTimerCoordinator = PromptSessionIdleTimerCoordinator.shared
    @ObservationIgnored private let recordingIdleTimerOwner = UUID()

    override init() {
        super.init()
        failedRecordingURL = Self.recoverablePendingRecordingURL()
        installSessionObservers()
    }

    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    func connectSpeechFollower(_ follower: SpeechFollower) {
        speechFollower = follower
    }

    @discardableResult
    func prepare(
        cameraEnabled: Bool,
        audioEnabled: Bool,
        audioAnalysisEnabled: Bool,
        cameraRequired: Bool = false
    ) async -> Bool {
        configurationGeneration &+= 1
        let generation = configurationGeneration
        errorMessage = nil
        lastSavedMessage = nil

        var mayUseCamera = cameraEnabled
        var mayUseAudio = audioEnabled
        var mayAnalyzeAudio = Self.shouldInstallAudioAnalysisOutput(
            audioEnabled: audioEnabled,
            audioAnalysisEnabled: audioAnalysisEnabled
        )

        if !cameraEnabled, !audioEnabled {
            return await disableCaptureSession(generation: generation)
        }

        if cameraEnabled {
            let cameraExists = Self.cameraDevice(position: cameraPosition) != nil
                || Self.cameraDevice(position: cameraPosition == .front ? .back : .front) != nil
            if cameraExists {
                let granted = await Self.requestCaptureAccess(for: .video)
                guard generation == configurationGeneration, !Task.isCancelled else { return false }
                if !granted {
                    errorMessage = CaptureIssue.cameraPermissionDenied.localizedDescription
                    mayUseCamera = false
                }
            } else {
                errorMessage = CaptureIssue.cameraUnavailable.localizedDescription
                mayUseCamera = false
            }
        }

        if cameraRequired, !mayUseCamera {
            _ = await disableCaptureSession(generation: generation)
            return false
        }

        if audioEnabled {
            guard AVCaptureDevice.default(for: .audio) != nil else {
                errorMessage = CaptureIssue.microphoneUnavailable.localizedDescription
                mayUseAudio = false
                _ = await configureAndStart(
                    cameraEnabled: mayUseCamera,
                    audioEnabled: false,
                    audioAnalysisEnabled: false,
                    generation: generation
                )
                return false
            }
            let granted = await Self.requestCaptureAccess(for: .audio)
            guard generation == configurationGeneration, !Task.isCancelled else { return false }
            if !granted {
                errorMessage = CaptureIssue.microphonePermissionDenied.localizedDescription
                mayUseAudio = false
                mayAnalyzeAudio = false
            }
        }

        guard generation == configurationGeneration, !Task.isCancelled else { return false }
        let configured = await configureAndStart(
            cameraEnabled: mayUseCamera,
            audioEnabled: mayUseAudio,
            audioAnalysisEnabled: mayAnalyzeAudio,
            generation: generation
        )
        return configured
            && (!cameraEnabled || isCameraAvailable)
            && (!audioEnabled || isAudioAvailable)
    }

    func stopSession() {
        configurationGeneration &+= 1
        if isRecording { stopRecording() }
        idleTimerCoordinator.release(owner: recordingIdleTimerOwner)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            Task { @MainActor [weak self] in self?.isSessionRunning = false }
        }
    }

    func preparePhotosAccessForRecording() async -> Bool {
        let ready = await requestPhotosAddPermission()
        guard !Task.isCancelled else { return false }
        isPhotosAccessReady = ready
        if !ready { errorMessage = CaptureIssue.photosPermissionDenied.localizedDescription }
        return ready
    }

    func switchCamera() {
        guard recordingState == .idle, isCameraAvailable, !isSwitchingCamera else { return }
        isSwitchingCamera = true
        let target: AVCaptureDevice.Position = cameraPosition == .front ? .back : .front
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = Self.cameraDevice(position: target),
                  let newInput = try? AVCaptureDeviceInput(device: device) else {
                Task { @MainActor [weak self] in self?.isSwitchingCamera = false }
                return
            }

            self.session.beginConfiguration()
            let previousInput = self.videoInput
            if let previousInput { self.session.removeInput(previousInput) }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
                self.applyMovieConnectionSettings()
                self.session.commitConfiguration()
                Task { @MainActor [weak self] in
                    self?.cameraPosition = target
                    self?.activeVideoDevice = device
                    self?.isSwitchingCamera = false
                }
            } else {
                if let previousInput, self.session.canAddInput(previousInput) {
                    self.session.addInput(previousInput)
                }
                self.session.commitConfiguration()
                Task { @MainActor [weak self] in self?.isSwitchingCamera = false }
            }
        }
    }

    func setCaptureRotationAngle(_ angle: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureRotationAngle = angle
            if Self.shouldApplyCaptureRotationImmediately(isRecording: self.movieOutput.isRecording) {
                self.applyMovieConnectionSettings()
            }
        }
    }

    func startRecording() async -> Bool {
        guard isCameraAvailable,
              isAudioAvailable,
              isSessionRunning,
              !isSwitchingCamera,
              isPhotosAccessReady,
              recordingState == .idle,
              failedRecordingURL == nil else {
            errorMessage = CaptureIssue.recordingUnavailable.localizedDescription
            return false
        }
        let url: URL
        do {
            url = try Self.makePendingRecordingURL()
        } catch {
            errorMessage = CaptureIssue.recordingUnavailable.localizedDescription + " \(error.localizedDescription)"
            return false
        }
        errorMessage = nil
        lastSavedMessage = nil
        stopRequested = false
        recordingAttemptURL = url
        recordingState = .starting

        sessionQueue.async { [weak self, url] in
            guard let self,
                  self.session.isRunning,
                  self.movieOutput.connection(with: .video) != nil else {
                Task { @MainActor [weak self, url] in
                    self?.failRecordingStart(
                        for: url,
                        message: CaptureIssue.recordingUnavailable.localizedDescription
                    )
                }
                return
            }
            self.applyMovieConnectionSettings()
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }

        let deadline = Date().addingTimeInterval(5)
        while recordingState == .starting, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(40))
        }
        if Task.isCancelled {
            stopRecording()
            return false
        }
        if recordingState == .starting {
            errorMessage = CaptureIssue.recordingUnavailable.localizedDescription
            stopRecording()
            return false
        }
        return recordingState == .recording
    }

    func stopRecording() {
        guard recordingState == .starting || recordingState == .recording else { return }
        let wasStarting = recordingState == .starting
        let attemptURL = recordingAttemptURL
        stopRequested = true
        beginBackgroundTaskIfNeeded()
        recordingState = .stopping
        sessionQueue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
        if wasStarting, let attemptURL {
            scheduleStartingStopFailsafe(for: attemptURL)
        }
    }

    func retrySaving() async {
        guard recordingState == .idle, let failedRecordingURL else { return }
        recordingState = .saving
        errorMessage = nil
        beginBackgroundTaskIfNeeded()
        await persistRecording(at: failedRecordingURL)
    }

    func discardPendingRecording() {
        guard recordingState == .idle, let failedRecordingURL else { return }
        do {
            try FileManager.default.removeItem(at: failedRecordingURL)
            self.failedRecordingURL = nil
            errorMessage = nil
        } catch {
            errorMessage = "The pending recording could not be deleted: \(error.localizedDescription)"
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard output === audioDataOutput else { return }
        speechFollower?.consumeAudioSampleBuffer(sampleBuffer)

        let level = AudioSampleLevelMeter.normalizedRMS(from: sampleBuffer) ?? {
            let decibels = connection.audioChannels.map(\.averagePowerLevel).max() ?? -80
            let clamped = max(-80, min(0, Double(decibels)))
            return CGFloat(pow(10, clamped / 20))
        }()
        let now = ProcessInfo.processInfo.systemUptime
        guard let publishedLevel = audioLevelCoalescer.levelToPublish(level, at: now) else { return }
        Task { @MainActor [weak self] in
            self?.speechFollower?.processAudioLevel(publishedLevel, at: now)
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.recordingAttemptURL?.standardizedFileURL == fileURL.standardizedFileURL else {
                self.sessionQueue.async { [weak self] in
                    guard let self, self.movieOutput.isRecording else { return }
                    self.movieOutput.stopRecording()
                }
                return
            }
            self.recordingStartedAt = Date()
            self.startElapsedTimer()
            if self.stopRequested || self.recordingState != .starting {
                self.beginBackgroundTaskIfNeeded()
                self.recordingState = .stopping
                self.sessionQueue.async { [weak self] in
                    guard let self, self.movieOutput.isRecording else { return }
                    self.movieOutput.stopRecording()
                }
            } else {
                self.recordingState = .recording
            }
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let recordingSucceeded = error == nil
            || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        let errorDescription = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.recordingAttemptURL?.standardizedFileURL == outputFileURL.standardizedFileURL else {
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }
            self.recordingAttemptURL = nil
            self.stopElapsedTimer()
            self.stopRequested = false
            if !recordingSucceeded, let errorDescription {
                self.recordingState = .idle
                self.errorMessage = CaptureIssue.saveFailed(errorDescription).localizedDescription
                try? FileManager.default.removeItem(at: outputFileURL)
                self.endBackgroundTask()
                return
            }
            self.recordingState = .saving
            self.beginBackgroundTaskIfNeeded()
            await self.persistRecording(at: outputFileURL)
        }
    }

    private func failRecordingStart(for url: URL, message: String) {
        guard recordingAttemptURL?.standardizedFileURL == url.standardizedFileURL else { return }
        recordingAttemptURL = nil
        stopRequested = false
        recordingState = .idle
        errorMessage = message
        try? FileManager.default.removeItem(at: url)
        endBackgroundTask()
    }

    private func scheduleStartingStopFailsafe(for url: URL) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self,
                  self.recordingAttemptURL?.standardizedFileURL == url.standardizedFileURL,
                  self.recordingState == .stopping else { return }
            let outputIsRecording: Bool = await withCheckedContinuation { continuation in
                self.sessionQueue.async { [weak self] in
                    continuation.resume(returning: self?.movieOutput.isRecording == true)
                }
            }
            guard self.recordingAttemptURL?.standardizedFileURL == url.standardizedFileURL,
                  self.recordingState == .stopping else { return }
            if outputIsRecording {
                self.sessionQueue.async { [weak self] in
                    guard let self, self.movieOutput.isRecording else { return }
                    self.movieOutput.stopRecording()
                }
            } else {
                self.failRecordingStart(
                    for: url,
                    message: self.errorMessage ?? CaptureIssue.recordingUnavailable.localizedDescription
                )
            }
        }
    }

    private func configureAndStart(
        cameraEnabled: Bool,
        audioEnabled: Bool,
        audioAnalysisEnabled: Bool,
        generation: Int
    ) async -> Bool {
        if !cameraEnabled, !audioEnabled {
            return await disableCaptureSession(generation: generation)
        }

        let requestedPosition = cameraPosition
        let result: Result<(AVCaptureDevice?, Bool), Error> = await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .failure(CaptureIssue.configurationFailed("Session ended.")))
                    return
                }
                do {
                    let device = try self.configureSession(
                        cameraEnabled: cameraEnabled,
                        audioEnabled: audioEnabled,
                        audioAnalysisEnabled: audioAnalysisEnabled,
                        cameraPosition: requestedPosition
                    )
                    if !self.session.isRunning, cameraEnabled || audioEnabled {
                        self.session.startRunning()
                    }
                    let hasMovieAudio = !cameraEnabled || self.movieOutput.connection(with: .audio) != nil
                    continuation.resume(
                        returning: .success((device, audioEnabled && self.audioInput != nil && hasMovieAudio))
                    )
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }

        guard generation == configurationGeneration, !Task.isCancelled else {
            return false
        }

        switch result {
        case .success(let (device, audioConfigured)):
            activeVideoDevice = device
            isCameraAvailable = device != nil
            isAudioAvailable = audioConfigured
            isAudioAnalysisEnabled = audioConfigured && audioAnalysisEnabled
            isSessionRunning = session.isRunning
            if let device { cameraPosition = device.position }
            return (cameraEnabled ? device != nil : true) && (audioEnabled ? audioConfigured : true)
        case .failure(let error):
            errorMessage = error.localizedDescription
            isSessionRunning = false
            isCameraAvailable = false
            isAudioAvailable = false
            isAudioAnalysisEnabled = false
            return false
        }
    }

    private func disableCaptureSession(generation: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                if let self, self.session.isRunning { self.session.stopRunning() }
                continuation.resume()
            }
        }
        guard generation == configurationGeneration, !Task.isCancelled else { return false }
        activeVideoDevice = nil
        isCameraAvailable = false
        isAudioAvailable = false
        isAudioAnalysisEnabled = false
        isSessionRunning = false
        return true
    }

    nonisolated private func configureSession(
        cameraEnabled: Bool,
        audioEnabled: Bool,
        audioAnalysisEnabled: Bool,
        cameraPosition: AVCaptureDevice.Position
    ) throws -> AVCaptureDevice? {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        audioDataOutput.setSampleBufferDelegate(nil, queue: nil)
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        videoInput = nil
        audioInput = nil

        var configuredVideoDevice: AVCaptureDevice?
        if cameraEnabled {
            let preferred = Self.cameraDevice(position: cameraPosition)
                ?? Self.cameraDevice(position: cameraPosition == .front ? .back : .front)
            guard let preferred else { throw CaptureIssue.cameraUnavailable }
            let input = try AVCaptureDeviceInput(device: preferred)
            guard session.canAddInput(input) else {
                throw CaptureIssue.configurationFailed("Video input could not be added.")
            }
            session.addInput(input)
            videoInput = input
            configuredVideoDevice = preferred
        }

        if audioEnabled {
            guard let device = AVCaptureDevice.default(for: .audio) else {
                throw CaptureIssue.microphoneUnavailable
            }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw CaptureIssue.configurationFailed("Audio input could not be added.")
            }
            session.addInput(input)
            audioInput = input
        }

        if configuredVideoDevice != nil {
            guard session.canAddOutput(movieOutput) else {
                throw CaptureIssue.configurationFailed("Movie output could not be added.")
            }
            session.addOutput(movieOutput)
        }

        if Self.shouldInstallAudioAnalysisOutput(
            audioEnabled: audioEnabled,
            audioAnalysisEnabled: audioAnalysisEnabled
        ) {
            guard session.canAddOutput(audioDataOutput) else {
                throw CaptureIssue.configurationFailed("Audio monitoring output could not be added.")
            }
            session.addOutput(audioDataOutput)
            audioDataOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        }

        if audioEnabled {
            session.usesApplicationAudioSession = true
            session.automaticallyConfiguresApplicationAudioSession = true
            session.configuresApplicationAudioSessionForBluetoothHighQualityRecording = true
        }
        applyMovieConnectionSettings()
        return configuredVideoDevice
    }

    nonisolated static func shouldInstallAudioAnalysisOutput(
        audioEnabled: Bool,
        audioAnalysisEnabled: Bool
    ) -> Bool {
        audioEnabled && audioAnalysisEnabled
    }

    nonisolated static func shouldApplyCaptureRotationImmediately(isRecording: Bool) -> Bool {
        !isRecording
    }

    nonisolated private func applyMovieConnectionSettings() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(captureRotationAngle) {
            connection.videoRotationAngle = captureRotationAngle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    // Photos invokes both handlers on an arbitrary serial queue. Keep this bridge
    // nonisolated so Swift doesn't attach the app's default MainActor executor.
    nonisolated private static func saveVideoToPhotos(_ url: URL) async throws -> String {
        let status = await photosAddAuthorizationStatus()
        guard status == .authorized || status == .limited else {
            throw CaptureIssue.photosPermissionDenied
        }

        return try await withCheckedThrowingContinuation { continuation in
            let identifier = SavedAssetIdentifier()
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                identifier.value = request?.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { success, error in
                if success, let assetIdentifier = identifier.value {
                    continuation.resume(returning: assetIdentifier)
                } else {
                    continuation.resume(
                        throwing: CaptureIssue.saveFailed(
                            error?.localizedDescription ?? "Photos did not save the recording."
                        )
                    )
                }
            })
        }
    }

    nonisolated private static func photosAddAuthorizationStatus() async -> PHAuthorizationStatus {
        let existing = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard existing == .notDetermined else { return existing }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestPhotosAddPermission() async -> Bool {
        let status = await Self.photosAddAuthorizationStatus()
        return status == .authorized || status == .limited
    }

    private func persistRecording(at url: URL) async {
        do {
            let thumbnail = await Self.makeVideoThumbnail(at: url)
            let duration = await Self.videoDuration(at: url)
            let assetIdentifier = try await Self.saveVideoToPhotos(url)
            failedRecordingURL = nil
            lastSavedMessage = "Saved to Photos"
            savedRecordingsStore.remember(assetIdentifier: assetIdentifier)
            lastSavedRecording = SavedRecording(
                assetIdentifier: assetIdentifier,
                thumbnail: thumbnail ?? UIImage(systemName: "video.fill") ?? UIImage(),
                createdAt: Date(),
                duration: duration
            )
            try? FileManager.default.removeItem(at: url)
        } catch {
            failedRecordingURL = url
            errorMessage = "\(error.localizedDescription) The recording is kept so you can retry."
        }
        recordingState = .idle
        endBackgroundTask()
    }

    nonisolated private static func makeVideoThumbnail(at url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        do {
            let (image, _) = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
            return UIImage(cgImage: image)
        } catch {
            return nil
        }
    }

    nonisolated private static func videoDuration(at url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return 0 }
        return max(0, duration.seconds)
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Finish Textream Recording") {
            Task { @MainActor [weak self] in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        let identifier = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    // AVFoundation also completes permission requests on an arbitrary queue.
    // This bridge must not inherit CaptureController's MainActor isolation.
    nonisolated private static func requestCaptureAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    nonisolated private static func cameraDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    nonisolated private static func makePendingRecordingURL() throws -> URL {
        let baseURL = try pendingRecordingsDirectory(createIfNeeded: true)
        return baseURL
            .appendingPathComponent("Textream-\(UUID().uuidString)")
            .appendingPathExtension("mov")
    }

    nonisolated private static func recoverablePendingRecordingURL() -> URL? {
        guard let directory = try? pendingRecordingsDirectory(createIfNeeded: false),
              let candidates = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                  options: [.skipsHiddenFiles]
              ) else { return nil }

        return candidates
            .filter { url in
                guard url.pathExtension.lowercased() == "mov",
                      let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return false }
                return (values.fileSize ?? 0) > 0
            }
            .max { first, second in
                let firstDate = (try? first.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                let secondDate = (try? second.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                return firstDate < secondDate
            }
    }

    nonisolated private static func pendingRecordingsDirectory(createIfNeeded: Bool) throws -> URL {
        var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pending Recordings", isDirectory: true)
        if createIfNeeded {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
        return directory
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedRecordingTime = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recordingStartedAt = self.recordingStartedAt else { return }
                self.elapsedRecordingTime = Date().timeIntervalSince(recordingStartedAt)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartedAt = nil
    }

    private func installSessionObservers() {
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.isInterrupted = true }
            }
        )
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.isInterrupted = false }
            }
        )
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: nil
            ) { [weak self] notification in
                let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                    ?? "The capture session stopped unexpectedly."
                Task { @MainActor [weak self] in self?.errorMessage = message }
            }
        )
    }
}
