//
//  DictationManager.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 26.02.2026.
//

import Foundation
import Speech
import AVFoundation
import AppKit

@Observable
class DictationManager {
    var isRecording: Bool = false
    var isStarting: Bool = false
    var isFinalizing: Bool = false
    var audioLevels: [CGFloat] = Array(repeating: 0, count: 40)
    var error: String?

    /// Called on main thread with the latest recognized text for the current segment
    var onTextUpdate: ((String) -> Void)?
    /// Local models can also identify an append-only prefix. The test UI uses
    /// it to keep completed words fixed while the newest words stay tentative.
    var onLocalTextUpdate: ((
        _ text: String,
        _ stablePrefix: String,
        _ windowOverlapPrefix: String?
    ) -> Void)?
    /// Called on main thread when a new recognition segment begins (after silence/restart)
    var onNewSegment: (() -> Void)?
    /// Called only when a rolling local-model window carries audio overlap.
    var onLocalWindowRollover: (() -> Void)?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var configurationChangeObserver: Any?
    private var suppressConfigChange: Bool = false
    private var pendingRestart: DispatchWorkItem?
    private var requestLock = NSLock()
    private var recognitionGeneration: Int = 0
    private var shouldRecord: Bool = false
    private var retryCount: Int = 0
    private let maxRetries: Int = 10

    // Local model state. Dictation normally uses Apple Speech, while the
    // Guidance test can explicitly exercise the selected on-device model.
    private var engine: SpeechEngine = .apple
    private var localEngineInfo: LocalSpeechEngineInfo?
    private var ownsLocalModel = false
    private var currentLocalEngineIsActive = false
    private var localEngineSessionID: Int?
    private var localFinalizationCompletion: (() -> Void)?
    private var localAudioConverter: AVAudioConverter?
    private var localConverterInputFormat: AVAudioFormat?
    private var localConverterOutputFormat: AVAudioFormat?

    // Tracks the committed text from previous recognition segments
    private var committedText: String = ""
    private var sessionGeneration: Int = 0

    func start(engine: SpeechEngine = .apple) {
        guard !isRecording, !isStarting, !isFinalizing else { return }
        cleanup()
        releaseLocalModel()
        self.engine = engine
        localEngineInfo = nil
        committedText = ""
        audioLevels = Array(repeating: 0, count: 40)
        sessionGeneration &+= 1
        retryCount = 0
        error = nil
        shouldRecord = true
        isStarting = true
        isFinalizing = false
        requestMicrophoneAccessAndBegin(for: sessionGeneration)
    }

    func stop() {
        shouldRecord = false
        sessionGeneration &+= 1
        isRecording = false
        isStarting = false
        cleanup()
        isFinalizing = false
        releaseLocalModel()
    }

    /// Stops capturing and lets the local engine process its last queued audio
    /// before releasing the model. Final text is delivered before completion.
    func stopAndFinalizeLocal(completion: @escaping () -> Void) {
        guard engine == .local, currentLocalEngineIsActive else {
            stop()
            completion()
            return
        }
        guard !isFinalizing else { return }

        isRecording = false
        isStarting = false
        isFinalizing = true
        stopAudioCapture()

        guard let engineSessionID = localEngineSessionID else {
            stop()
            completion()
            return
        }
        currentLocalEngineIsActive = false
        localFinalizationCompletion = completion
        localAudioConverter = nil
        localConverterInputFormat = nil
        localConverterOutputFormat = nil
        LocalSpeechEngine.shared.stop(sessionID: engineSessionID)
    }

    private func requestMicrophoneAccessAndBegin(for generation: Int) {
        guard shouldRecord, sessionGeneration == generation else { return }

        // Check microphone permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            fail("Microphone access denied. Open System Settings → Privacy & Security → Microphone.")
            openMicrophoneSettings()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self,
                          self.shouldRecord,
                          self.sessionGeneration == generation else { return }
                    if granted {
                        self.beginAfterMicrophoneAccess(for: generation)
                    } else {
                        self.fail("Microphone access denied. Open System Settings → Privacy & Security → Microphone.")
                    }
                }
            }
        case .authorized:
            beginAfterMicrophoneAccess(for: generation)
        @unknown default:
            fail("Microphone authorization is unavailable.")
        }
    }

    private func beginAfterMicrophoneAccess(for generation: Int) {
        guard shouldRecord, sessionGeneration == generation else { return }
        if engine == .local {
            prepareLocalRecognition(for: generation)
        } else {
            requestSpeechAuthAndBegin(for: generation)
        }
    }

    private func prepareLocalRecognition(for generation: Int) {
        guard shouldRecord, sessionGeneration == generation else { return }

        let filename = NotchSettings.shared.localModelFilename
        guard !filename.isEmpty else {
            fail("No local model selected. Open Settings → Guidance → Manage Models to download one.")
            return
        }

        let modelURL = LocalSpeechModelStore.modelsDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            fail("The local model \"\(filename)\" is missing. Download it again in Settings → Guidance → Manage Models.")
            return
        }

        ownsLocalModel = true
        LocalSpeechEngine.shared.loadModel(at: modelURL.path) { [weak self] result in
            guard let self,
                  self.shouldRecord,
                  self.sessionGeneration == generation else { return }
            switch result {
            case .success(let info):
                self.localEngineInfo = info
                self.beginRecognition()
            case .failure(let error):
                self.localEngineInfo = nil
                self.fail("Couldn't load the local model \"\(filename)\": \(error.localizedDescription)")
            }
        }
    }

    private func requestSpeechAuthAndBegin(for generation: Int) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self,
                      self.shouldRecord,
                      self.sessionGeneration == generation else { return }
                switch status {
                case .authorized:
                    self.beginRecognition()
                default:
                    self.fail("Speech recognition not authorized. Open System Settings → Privacy & Security → Speech Recognition.")
                    self.openSpeechRecognitionSettings()
                }
            }
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSpeechRecognitionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    private func fail(_ message: String) {
        shouldRecord = false
        isRecording = false
        isStarting = false
        error = message
        cleanup()
        isFinalizing = false
        releaseLocalModel()
    }

    private func cleanup() {
        stopAudioCapture()
        stopLocalEngineSession()
    }

    private func stopAudioCapture() {
        recognitionGeneration &+= 1
        pendingRestart?.cancel()
        pendingRestart = nil
        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationChangeObserver = nil
        }
        requestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func beginRecognition() {
        guard shouldRecord else { return }
        if engine == .local, localEngineInfo == nil {
            prepareLocalRecognition(for: sessionGeneration)
            return
        }

        let usesLocalEngine = engine == .local && localEngineInfo != nil
        let expectedSessionGeneration = sessionGeneration
        cleanup()
        guard shouldRecord, sessionGeneration == expectedSessionGeneration else { return }

        audioEngine = AVAudioEngine()
        suppressConfigChange = false

        // Set selected microphone if configured
        let micUID = NotchSettings.shared.selectedMicUID
        if !micUID.isEmpty, let deviceID = AudioInputDevice.deviceID(forUID: micUID) {
            suppressConfigChange = true
            if let audioUnit = audioEngine.inputNode.audioUnit {
                var devID = deviceID
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                AudioUnitUninitialize(audioUnit)
                AudioUnitInitialize(audioUnit)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self,
                      self.sessionGeneration == expectedSessionGeneration else { return }
                self.suppressConfigChange = false
            }
        }

        if usesLocalEngine {
            speechRecognizer = nil
            recognitionRequest = nil
        } else {
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: NotchSettings.shared.speechLocale))
            guard let speechRecognizer else {
                fail("Speech recognition isn't supported for the selected language.")
                return
            }
            guard speechRecognizer.isAvailable else {
                if retryCount < maxRetries {
                    retryCount += 1
                    scheduleRestart(after: 0.5)
                } else {
                    fail("Speech recognizer is not available.")
                }
                return
            }

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else {
                fail("Unable to create a speech recognition request.")
                return
            }
            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.taskHint = .dictation
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            if retryCount < maxRetries {
                retryCount += 1
                scheduleRestart(after: 0.5)
            } else {
                fail("Audio input is unavailable.")
            }
            return
        }

        guard let tapFormat = speechCaptureFormat(for: recordingFormat) else {
            fail("Audio input format is unsupported.")
            return
        }

        // Observe audio configuration changes
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  self.shouldRecord,
                  !self.suppressConfigChange else { return }
            self.restartRecognition()
        }

        inputNode.removeTap(onBus: 0)

        let waveformFrameInterval = AVAudioFrameCount(max(1, tapFormat.sampleRate / 20.0))
        var framesSinceWaveformUpdate = waveformFrameInterval

        inputNode.installTap(
            onBus: 0,
            bufferSize: speechCaptureBufferSize(for: tapFormat),
            format: tapFormat
        ) { [weak self] buffer, _ in
            self?.appendBuffer(buffer)

            framesSinceWaveformUpdate &+= buffer.frameLength
            guard framesSinceWaveformUpdate >= waveformFrameInterval else { return }
            framesSinceWaveformUpdate %= waveformFrameInterval

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrt(sum / Float(max(frameLength, 1)))
            let level = CGFloat(min(rms * 5, 1.0))

            DispatchQueue.main.async {
                self?.audioLevels.append(level)
                if (self?.audioLevels.count ?? 0) > 40 {
                    self?.audioLevels.removeFirst()
                }
            }
        }

        if let speechRecognizer, let recognitionRequest {
            recognitionGeneration &+= 1
            let currentRecognitionGeneration = recognitionGeneration
            let currentGeneration = sessionGeneration
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let spoken = result.bestTranscription.formattedString
                    DispatchQueue.main.async {
                        guard self.sessionGeneration == currentGeneration,
                              self.recognitionGeneration == currentRecognitionGeneration else { return }
                        self.retryCount = 0
                        self.onTextUpdate?(spoken)
                        if result.isFinal {
                            self.restartRecognition()
                        }
                    }
                }
                if error != nil {
                    DispatchQueue.main.async {
                        guard self.sessionGeneration == currentGeneration,
                              self.recognitionGeneration == currentRecognitionGeneration,
                              self.recognitionRequest != nil,
                              self.shouldRecord else { return }
                        self.restartRecognition()
                    }
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            guard shouldRecord, sessionGeneration == expectedSessionGeneration else {
                cleanup()
                return
            }
            retryCount = 0
            error = nil
            isStarting = false
            isRecording = true
            // Notify that a new recognition segment is starting
            onNewSegment?()
            if usesLocalEngine {
                startLocalEngineSession()
            }
        } catch {
            if retryCount < maxRetries {
                retryCount += 1
                scheduleRestart(after: 0.5)
            } else {
                fail("Audio engine failed: \(error.localizedDescription)")
            }
        }
    }

    private func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        if currentLocalEngineIsActive {
            feedLocalEngine(buffer)
            return
        }
        requestLock.lock()
        recognitionRequest?.append(buffer)
        requestLock.unlock()
    }

    // MARK: - Local model

    private func startLocalEngineSession() {
        guard let info = localEngineInfo else { return }

        let generation = sessionGeneration
        let localEngine = LocalSpeechEngine.shared
        currentLocalEngineIsActive = true

        localEngineSessionID = localEngine.start(
            language: Self.localLanguageHint(
                for: info,
                preferredLocale: NotchSettings.shared.speechLocale
            ),
            initialPrompt: nil,
            wordTimestamps: !info.supportsStreaming,
            onText: { [weak self] text, stablePrefix, windowOverlapPrefix, isNewWindow, engineSessionID in
                guard let self,
                      self.shouldRecord,
                      self.sessionGeneration == generation,
                      self.localEngineSessionID == engineSessionID else { return }
                if isNewWindow {
                    self.onLocalWindowRollover?()
                }
                self.retryCount = 0
                if let onLocalTextUpdate = self.onLocalTextUpdate {
                    onLocalTextUpdate(text, stablePrefix, windowOverlapPrefix)
                } else {
                    self.onTextUpdate?(text)
                }
            },
            onError: { [weak self] message, engineSessionID in
                guard let self,
                      self.shouldRecord,
                      self.sessionGeneration == generation,
                      self.localEngineSessionID == engineSessionID else { return }
                if self.isFinalizing {
                    self.error = message
                } else {
                    self.fail(message)
                }
            },
            onFinished: { [weak self] engineSessionID in
                self?.localEngineDidFinish(
                    engineSessionID,
                    managerGeneration: generation
                )
            }
        )
    }

    private func localEngineDidFinish(
        _ engineSessionID: Int,
        managerGeneration: Int
    ) {
        guard sessionGeneration == managerGeneration,
              localEngineSessionID == engineSessionID else { return }

        if isFinalizing {
            shouldRecord = false
            sessionGeneration &+= 1
            isFinalizing = false
            localEngineSessionID = nil
            let completion = localFinalizationCompletion
            localFinalizationCompletion = nil
            releaseLocalModel()
            completion?()
        } else if shouldRecord {
            retryCount = 0
        }
    }

    private func stopLocalEngineSession() {
        guard currentLocalEngineIsActive || isFinalizing else { return }
        currentLocalEngineIsActive = false

        if let engineSessionID = localEngineSessionID {
            LocalSpeechEngine.shared.cancel(sessionID: engineSessionID)
        }
        localEngineSessionID = nil
        localFinalizationCompletion = nil

        localAudioConverter = nil
        localConverterInputFormat = nil
        localConverterOutputFormat = nil
    }

    private func releaseLocalModel() {
        guard ownsLocalModel else { return }
        ownsLocalModel = false
        localEngineInfo = nil
        LocalSpeechEngine.shared.unloadModel()
    }

    /// Converts the selected microphone's hardware format to the 16 kHz mono
    /// float samples expected by transcribe.cpp.
    private func feedLocalEngine(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        let inputFormat = buffer.format
        if localAudioConverter == nil
            || localConverterInputFormat?.sampleRate != inputFormat.sampleRate
            || localConverterInputFormat?.channelCount != inputFormat.channelCount {
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return }
            localConverterOutputFormat = outputFormat
            localConverterInputFormat = inputFormat
            localAudioConverter = converter
        }

        guard let converter = localAudioConverter,
              let outputFormat = localConverterOutputFormat else { return }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return }

        var conversionError: NSError?
        var suppliedInput = false
        converter.convert(to: output, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              output.frameLength > 0,
              let channel = output.floatChannelData?[0] else { return }
        guard let localEngineSessionID else { return }
        LocalSpeechEngine.shared.feed(
            Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))),
            sessionID: localEngineSessionID
        )
    }

    private static func localLanguageHint(
        for info: LocalSpeechEngineInfo,
        preferredLocale: String
    ) -> String? {
        guard !info.languages.isEmpty else { return nil }

        // A free-speech test should preserve whatever language the user is
        // actually speaking. Unlike script tracking, it has no known source
        // language to pin, so let multilingual models detect it.
        if info.supportsLanguageDetection { return nil }

        let preferred = baseLanguageCode(preferredLocale)
        if !preferred.isEmpty {
            if let exact = info.languages.first(where: {
                $0.caseInsensitiveCompare(preferredLocale) == .orderedSame
            }) {
                return exact
            }
            if let sameLanguage = info.languages.first(where: {
                baseLanguageCode($0) == preferred
            }) {
                return sameLanguage
            }
        }

        if let english = info.languages.first(where: { baseLanguageCode($0) == "en" }) {
            return english
        }
        return info.languages.first
    }

    private static func baseLanguageCode(_ identifier: String) -> String {
        identifier
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map { String($0).lowercased() } ?? ""
    }

    private func restartRecognition() {
        guard shouldRecord else { return }
        isRecording = false
        isStarting = true
        cleanup()
        scheduleRestart(after: 0.3)
    }

    private func scheduleRestart(after delay: TimeInterval) {
        pendingRestart?.cancel()
        let expectedSessionGeneration = sessionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldRecord,
                  self.sessionGeneration == expectedSessionGeneration else { return }
            self.pendingRestart = nil
            self.beginRecognition()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
