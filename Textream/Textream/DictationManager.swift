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

    // Tracks the committed text from previous recognition segments
    private var committedText: String = ""
    private var sessionGeneration: Int = 0

    func start() {
        guard !isRecording else { return }
        cleanup()
        committedText = ""
        sessionGeneration += 1
        error = nil

        // Check microphone permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            error = L10n.string("speech.microphoneDenied.short")
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.requestSpeechAuthAndBegin()
                    } else {
                        self?.error = L10n.string("speech.microphoneDenied.compact")
                    }
                }
            }
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        requestSpeechAuthAndBegin()
    }

    func stop() {
        isRecording = false
        cleanup()
    }

    private func requestSpeechAuthAndBegin() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self?.beginRecognition()
                default:
                    self?.error = L10n.string("speech.recognitionDenied.compact")
                }
            }
        }
    }

    private func cleanup() {
        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationChangeObserver = nil
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func beginRecognition() {
        cleanup()

        audioEngine = AVAudioEngine()

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
                self?.suppressConfigChange = false
            }
        }

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: NotchSettings.shared.speechLocale))
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = L10n.string("speech.recognizerUnavailable")
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            error = L10n.string("speech.audioInputUnavailable")
            return
        }

        // Observe audio configuration changes
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.suppressConfigChange, self.isRecording else { return }
            self.restartRecognition()
        }

        inputNode.removeTap(onBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            recognitionRequest.append(buffer)

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

        // Notify that a new recognition segment is starting
        onNewSegment?()

        let currentGeneration = sessionGeneration
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let spoken = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    guard self.sessionGeneration == currentGeneration else { return }
                    self.onTextUpdate?(spoken)
                }
            }
            if error != nil {
                DispatchQueue.main.async {
                    guard self.recognitionRequest != nil, self.isRecording else { return }
                    self.restartRecognition()
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            self.error = L10n.format("speech.audioEngineFailed", error.localizedDescription)
            isRecording = false
        }
    }

    private func restartRecognition() {
        guard isRecording else { return }
        cleanup()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isRecording else { return }
            self.beginRecognition()
        }
    }
}
