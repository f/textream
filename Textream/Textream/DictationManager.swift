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
    var audioLevels: [CGFloat] = Array(repeating: 0, count: 40)
    var error: String?

    /// Called on main thread with the latest recognized text for the current segment
    var onTextUpdate: ((String) -> Void)?
    /// Called on main thread when a new recognition segment begins (after silence/restart)
    var onNewSegment: (() -> Void)?

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

    // Tracks the committed text from previous recognition segments
    private var committedText: String = ""
    private var sessionGeneration: Int = 0

    func start() {
        guard !isRecording, !isStarting else { return }
        cleanup()
        committedText = ""
        sessionGeneration &+= 1
        retryCount = 0
        error = nil
        shouldRecord = true
        isStarting = true
        requestMicrophoneAccessAndBegin(for: sessionGeneration)
    }

    func stop() {
        shouldRecord = false
        sessionGeneration &+= 1
        isRecording = false
        isStarting = false
        cleanup()
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
                        self.requestSpeechAuthAndBegin(for: generation)
                    } else {
                        self.fail("Microphone access denied. Open System Settings → Privacy & Security → Microphone.")
                    }
                }
            }
        case .authorized:
            requestSpeechAuthAndBegin(for: generation)
        @unknown default:
            fail("Microphone authorization is unavailable.")
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
    }

    private func cleanup() {
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

        let monoFormat = AVAudioFormat(
            commonFormat: recordingFormat.commonFormat,
            sampleRate: recordingFormat.sampleRate,
            channels: 1,
            interleaved: recordingFormat.isInterleaved
        )
        let tapFormat = recordingFormat.channelCount > 1 ? monoFormat : recordingFormat

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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            self?.appendBuffer(buffer)

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
        requestLock.lock()
        recognitionRequest?.append(buffer)
        requestLock.unlock()
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
