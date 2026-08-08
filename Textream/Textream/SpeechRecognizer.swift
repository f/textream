//
//  SpeechRecognizer.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import Foundation
import Speech
import AVFoundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func allInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

            // Get UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let uidStatus = withUnsafeMutablePointer(to: &uid) { uidPointer in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, uidPointer)
            }
            guard uidStatus == noErr else { continue }

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let nameStatus = withUnsafeMutablePointer(to: &name) { namePointer in
                AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, namePointer)
            }
            guard nameStatus == noErr else { continue }

            result.append(AudioInputDevice(id: deviceID, uid: uid as String, name: name as String))
        }
        return result
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allInputDevices().first(where: { $0.uid == uid })?.id
    }
}

@Observable
class SpeechRecognizer {
    var recognizedCharCount: Int = 0
    var isListening: Bool = false
    var isStarting: Bool = false
    var error: String?
    var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    var lastSpokenText: String = ""
    var shouldDismiss: Bool = false
    var shouldAdvancePage: Bool = false

    /// True when recent audio levels indicate the user is actively speaking
    var isSpeaking: Bool {
        voiceActivityDetector.isActive(at: ProcessInfo.processInfo.systemUptime)
    }

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var sourceText: String = ""
    private var normalizedSource: String = ""
    private var annotationRanges: [Range<Int>] = []
    private var voiceActivityDetector = VoiceActivityDetector()
    private var matchStartOffset: Int = 0  // char offset to start matching from
    private var retryCount: Int = 0
    private let maxRetries: Int = 10
    private var configurationChangeObserver: Any?
    private var pendingRestart: DispatchWorkItem?
    private var sessionGeneration: Int = 0
    private var recognitionGeneration: Int = 0
    private var shouldListen: Bool = false
    private var suppressConfigChange: Bool = false
    private var requestLock = NSLock()
    private var preemptiveRestartTimer: Timer?
    /// Sliding window of recent match positions for confidence gating.
    /// We require 2-of-3 recent results to agree before committing a forward jump.
    private var recentMatchPositions: [Int] = []
    /// Transcript prefix to ignore when matching — set on jumps so the task
    /// can keep running instead of being restarted (a restart loses the words
    /// the user re-speaks right after the jump). Stored as the prefix string,
    /// not a char count: partial results revise earlier text, and trimming by
    /// the surviving common prefix avoids swallowing post-jump speech when
    /// the pre-jump portion changes length. Cleared whenever a new
    /// recognition task starts a fresh transcript.
    private var spokenAnchorPrefix: String = ""
    /// Results computed before a jump can be delivered after it; matching
    /// ignores results for a short window so pre-jump speech isn't matched
    /// against the text at the new offset.
    private var lastJumpAt: Date = .distantPast

    /// Update the source text while preserving the current recognized char count.
    /// Used by Director Mode to live-edit unread text without resetting read progress.
    func updateText(_ text: String, preservingCharCount: Int) {
        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        normalizedSource = Self.normalize(collapsed)
        annotationRanges = SpeechTextAlignment.annotationRanges(in: collapsed)
        recognizedCharCount = min(preservingCharCount, collapsed.count)
        recognizedCharCount = advancePastAnnotations(from: recognizedCharCount)
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
    }

    /// Jump highlight to a specific char offset (e.g. when user taps a word).
    /// Nearby jumps keep the recognition task alive and anchor matching past
    /// the already-spoken transcript, so tracking resumes on the first
    /// re-spoken word. Far jumps restart the task instead: contextualStrings
    /// are built for the section being read, and after a page-scale jump
    /// stale hints hurt recognition more than the task warm-up costs.
    /// retryCount is deliberately not touched here — resetting it on every
    /// tap would let a user keep a failing availability-retry loop alive
    /// forever.
    func jumpTo(charOffset: Int) {
        let clampedOffset = max(0, min(charOffset, sourceText.count))
        let targetOffset = advancePastAnnotations(from: clampedOffset)
        let distance = abs(targetOffset - recognizedCharCount)
        recognizedCharCount = targetOffset
        matchStartOffset = targetOffset
        recentMatchPositions = []
        if isListening && (distance > 500 || !audioEngine.isRunning) {
            // Far jump, or the engine died without a config-change callback —
            // fall back to a full restart (also refreshes contextualStrings).
            restartRecognition(resetRetryCount: false)
            return
        }
        spokenAnchorPrefix = lastSpokenText
        lastJumpAt = Date()
    }

    func start(with text: String) {
        // Clean up any previous session immediately so pending restarts
        // and stale taps are removed before the async auth callback fires.
        cleanupRecognition()

        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        normalizedSource = Self.normalize(collapsed)
        annotationRanges = SpeechTextAlignment.annotationRanges(in: collapsed)
        recognizedCharCount = advancePastAnnotations(from: 0)
        matchStartOffset = recognizedCharCount
        retryCount = 0
        recentMatchPositions = []
        error = nil
        sessionGeneration &+= 1
        shouldListen = true
        isListening = false
        isStarting = true
        requestMicrophoneAccessAndBegin(for: sessionGeneration)
    }

    private func requestMicrophoneAccessAndBegin(for generation: Int) {
        guard shouldListen, sessionGeneration == generation else { return }

        // Check microphone permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            failListening("Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow Textream.")
            openMicrophoneSettings()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self,
                          self.shouldListen,
                          self.sessionGeneration == generation else { return }
                    if granted {
                        self.beginAfterMicrophoneAccess(for: generation)
                    } else {
                        self.failListening("Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow Textream.")
                    }
                }
            }
        case .authorized:
            beginAfterMicrophoneAccess(for: generation)
        @unknown default:
            failListening("Microphone authorization is unavailable.")
        }
    }

    private func beginAfterMicrophoneAccess(for generation: Int) {
        guard shouldListen, sessionGeneration == generation else { return }
        if NotchSettings.shared.listeningMode == .wordTracking {
            requestSpeechAuthAndBegin(for: generation)
        } else {
            beginRecognition()
        }
    }

    private func requestSpeechAuthAndBegin(for generation: Int) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self,
                      self.shouldListen,
                      self.sessionGeneration == generation else { return }
                switch status {
                case .authorized:
                    self.beginRecognition()
                default:
                    self.failListening("Speech recognition not authorized. Open System Settings → Privacy & Security → Speech Recognition to allow Textream.")
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

    private func failListening(_ message: String) {
        voiceActivityDetector.reset()
        shouldListen = false
        isListening = false
        isStarting = false
        error = message
        cleanupRecognition()
    }

    func stop() {
        shouldListen = false
        sessionGeneration &+= 1
        isListening = false
        isStarting = false
        cleanupRecognition()
    }

    func forceStop() {
        shouldListen = false
        sessionGeneration &+= 1
        isListening = false
        isStarting = false
        sourceText = ""
        annotationRanges = []
        retryCount = maxRetries
        recentMatchPositions = []
        cleanupRecognition()
    }

    func resume() {
        guard !sourceText.isEmpty else { return }
        cleanupRecognition()
        retryCount = 0
        recognizedCharCount = advancePastAnnotations(from: recognizedCharCount)
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        shouldDismiss = false
        error = nil
        sessionGeneration &+= 1
        shouldListen = true
        isListening = false
        isStarting = true
        requestMicrophoneAccessAndBegin(for: sessionGeneration)
    }

    private func cleanupRecognitionTask() {
        recognitionGeneration &+= 1
        // Cancel any pending restart to prevent overlapping beginRecognition calls
        pendingRestart?.cancel()
        pendingRestart = nil

        stopPreemptiveTimer()

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
    }

    private func cleanupAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func cleanupRecognition() {
        cleanupRecognitionTask()
        cleanupAudioEngine()
        voiceActivityDetector.reset()
    }

    /// Coalesces all delayed beginRecognition() calls into a single pending work item.
    /// Any previously scheduled restart is cancelled before the new one is queued.
    private func scheduleBeginRecognition(after delay: TimeInterval) {
        pendingRestart?.cancel()
        guard shouldListen, !sourceText.isEmpty else { return }
        isListening = false
        isStarting = true
        let expectedSessionGeneration = sessionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldListen,
                  self.sessionGeneration == expectedSessionGeneration,
                  !self.sourceText.isEmpty else { return }
            self.pendingRestart = nil
            self.beginRecognition()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func beginRecognition() {
        guard shouldListen, !sourceText.isEmpty else {
            isListening = false
            isStarting = false
            return
        }
        let expectedSessionGeneration = sessionGeneration
        let requiresSpeechRecognition = NotchSettings.shared.listeningMode == .wordTracking
        // Ensure clean state
        cleanupRecognition()
        guard shouldListen, sessionGeneration == expectedSessionGeneration else {
            isListening = false
            isStarting = false
            return
        }
        isListening = false
        isStarting = true
        // New session = fresh transcript (see restartTask for why
        // lastSpokenText must be cleared alongside the anchor)
        spokenAnchorPrefix = ""
        lastSpokenText = ""

        // Create a fresh engine so it picks up the current hardware format.
        // AVAudioEngine caches the device format internally and reset() alone
        // does not reliably flush it after a mic switch.
        audioEngine = AVAudioEngine()
        suppressConfigChange = false

        // Set selected microphone if configured
        let micUID = NotchSettings.shared.selectedMicUID
        if !micUID.isEmpty, let deviceID = AudioInputDevice.deviceID(forUID: micUID) {
            // Suppress config-change observer during our own device switch
            suppressConfigChange = true
            let inputUnit = audioEngine.inputNode.audioUnit
            if let audioUnit = inputUnit {
                var devID = deviceID
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                // Re-initialize audio unit so it picks up the new device's format
                AudioUnitUninitialize(audioUnit)
                AudioUnitInitialize(audioUnit)
            }
            // Allow config changes again after a settle period
            let expectedSessionGeneration = sessionGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self,
                      self.sessionGeneration == expectedSessionGeneration else { return }
                self.suppressConfigChange = false
            }
        }

        if requiresSpeechRecognition {
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: NotchSettings.shared.speechLocale))
            guard let speechRecognizer else {
                // nil means the locale isn't supported for speech recognition —
                // that's permanent, so fail immediately instead of retrying.
                failListening("Speech recognition isn't supported for the selected language.")
                return
            }
            guard speechRecognizer.isAvailable else {
                // Unavailability is often transient (the recognition service
                // churns briefly after a task cancellation or device change).
                // Giving up here leaves the engine stopped and the app deaf —
                // retry like the invalid-format guard below does.
                if retryCount < maxRetries {
                    retryCount += 1
                    scheduleBeginRecognition(after: 0.5)
                } else {
                    failListening("Speech recognizer is not available.")
                }
                return
            }

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else {
                failListening("Unable to create a speech recognition request.")
                return
            }
            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.taskHint = .dictation

            // Add contextual strings from the source text to improve STT accuracy
            let upcoming = String(sourceText.dropFirst(matchStartOffset))
            let contextWords = upcoming.split(separator: " ")
                .map { String($0).lowercased().filter { $0.isLetter || $0.isNumber } }
                .filter { $0.count >= 5 }
            let uniqueContextWords = Array(Set(contextWords).prefix(50))
            if !uniqueContextWords.isEmpty {
                recognitionRequest.contextualStrings = uniqueContextWords
            }
        } else {
            speechRecognizer = nil
            recognitionRequest = nil
        }

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        // Guard against invalid format during device transitions (e.g. mic switch)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            // Retry after a longer delay to let the audio system settle
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                failListening("Audio input is unavailable.")
            }
            return
        }

        // SFSpeechRecognizer requires mono audio. Multi-channel devices (e.g.
        // RODECaster Pro II at 2ch/48kHz) cause the recognition task to silently
        // return no results. Request a mono tap and let AVAudioEngine downmix.
        let monoFormat = AVAudioFormat(
            commonFormat: hardwareFormat.commonFormat,
            sampleRate: hardwareFormat.sampleRate,
            channels: 1,
            interleaved: hardwareFormat.isInterleaved
        )
        let tapFormat = (hardwareFormat.channelCount > 1) ? monoFormat : hardwareFormat

        // Observe audio configuration changes (e.g. mic switched externally) to restart gracefully
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  self.shouldListen,
                  !self.suppressConfigChange,
                  !self.sourceText.isEmpty else { return }
            self.restartRecognition()
        }

        // Belt-and-suspenders: ensure no stale tap exists before installing
        inputNode.removeTap(onBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            self?.appendBufferToRequest(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrt(sum / Float(max(frameLength, 1)))
            let level = CGFloat(min(rms * 5, 1.0))

            DispatchQueue.main.async {
                guard let self,
                      self.shouldListen,
                      self.sessionGeneration == expectedSessionGeneration else { return }
                self.recordAudioLevel(level)
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
                        // Ignore stale results from a previous session
                        guard self.sessionGeneration == currentGeneration,
                              self.recognitionGeneration == currentRecognitionGeneration else { return }
                        self.retryCount = 0 // Reset on success
                        self.lastSpokenText = spoken
                        self.matchCharacters(spoken: spoken)
                    }
                }
                if let error {
                    DispatchQueue.main.async {
                        guard self.sessionGeneration == currentGeneration,
                              self.recognitionGeneration == currentRecognitionGeneration else { return }
                        // If recognitionRequest is nil, cleanup already ran (intentional cancel) — don't retry
                        guard self.recognitionRequest != nil else { return }
                        guard self.shouldListen && !self.shouldDismiss && !self.sourceText.isEmpty else {
                            self.isListening = false
                            self.isStarting = false
                            return
                        }

                        self.matchStartOffset = self.recognizedCharCount

                        // Distinguish timeout errors (expected every ~60s) from real errors.
                        // SFSpeechRecognizer timeout is error code 1110 in kAFAssistantErrorDomain,
                        // or 216 (kAudioConverterErr_FormatNotSupported). Retry immediately for
                        // timeouts with no retry limit; use backoff for real errors.
                        let nsError = error as NSError
                        let isTimeout = nsError.code == 1110 || nsError.code == 216

                        if isTimeout {
                            // Expected timeout — restart immediately, no retry limit
                            self.retryCount = 0
                            if self.audioEngine.isRunning {
                                self.restartTask()
                            } else {
                                self.scheduleBeginRecognition(after: 0.1)
                            }
                        } else if self.retryCount < self.maxRetries {
                            self.retryCount += 1
                            let delay = min(Double(self.retryCount) * 0.5, 1.5)
                            self.scheduleBeginRecognition(after: delay)
                        } else {
                            self.failListening("Speech recognition stopped: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            guard shouldListen, sessionGeneration == expectedSessionGeneration else {
                cleanupRecognition()
                return
            }
            error = nil
            isStarting = false
            isListening = true
            if requiresSpeechRecognition {
                startPreemptiveTimer()
            }
        } catch {
            // Transient failure after a device switch — retry with longer delay
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                failListening("Audio engine failed: \(error.localizedDescription)")
            }
        }
    }

    private func restartRecognition(resetRetryCount: Bool = true) {
        guard shouldListen, !sourceText.isEmpty else {
            isListening = false
            isStarting = false
            return
        }
        if resetRetryCount {
            retryCount = 0
        }
        isListening = false
        isStarting = true
        cleanupRecognition()
        scheduleBeginRecognition(after: 0.5)
    }

    // MARK: - Thread-safe buffer appending

    private func recordAudioLevel(_ level: CGFloat) {
        audioLevels.append(level)
        if audioLevels.count > 30 {
            audioLevels.removeFirst()
        }
        voiceActivityDetector.process(level: level, at: ProcessInfo.processInfo.systemUptime)
    }

    private func appendBufferToRequest(_ buffer: AVAudioPCMBuffer) {
        requestLock.lock()
        recognitionRequest?.append(buffer)
        requestLock.unlock()
    }

    // MARK: - Soft restart (task only, keeps audio engine running)

    private func restartTask() {
        guard shouldListen, isListening, audioEngine.isRunning, !sourceText.isEmpty else {
            isListening = false
            if shouldListen, !sourceText.isEmpty {
                cleanupRecognition()
                scheduleBeginRecognition(after: 0.5)
            }
            return
        }
        recognitionGeneration &+= 1
        let currentRecognitionGeneration = recognitionGeneration
        // Update match offset before restarting
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        // New task = fresh transcript. lastSpokenText must be cleared too:
        // a jump taken before the first new result would otherwise anchor on
        // the old task's transcript and trim away everything the new task
        // ever produces.
        spokenAnchorPrefix = ""
        lastSpokenText = ""

        // Cancel any pending restart to avoid stale beginRecognition clobbering this session
        pendingRestart?.cancel()
        pendingRestart = nil

        // Cancel the old task and atomically swap to a new request under lock.
        // The lock prevents the audio tap from appending to the old request
        // between endAudio() and the new assignment.
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation

        // Add contextual strings for the remaining text
        let upcoming = String(sourceText.dropFirst(matchStartOffset))
        let contextWords = upcoming.split(separator: " ")
            .map { String($0).lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { $0.count >= 5 }
        let uniqueWords = Array(Set(contextWords).prefix(50))
        if !uniqueWords.isEmpty {
            newRequest.contextualStrings = uniqueWords
        }

        // Nil out recognitionRequest before cancelling the old task so the
        // old task's error callback sees nil and skips retry logic. Then set
        // the new request after cancellation.
        requestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil

        requestLock.lock()
        recognitionRequest = newRequest
        requestLock.unlock()

        // Start new recognition task
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            // Transient unavailability — fall back to a full session restart
            // with retries rather than going permanently deaf.
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                // Don't leave the mic hot with no session consuming it
                failListening("Speech recognizer is not available.")
            }
            return
        }

        let currentGeneration = sessionGeneration
        recognitionTask = speechRecognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let spoken = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    guard self.sessionGeneration == currentGeneration,
                          self.recognitionGeneration == currentRecognitionGeneration else { return }
                    self.retryCount = 0
                    self.lastSpokenText = spoken
                    self.matchCharacters(spoken: spoken)
                }
            }
            if let error {
                DispatchQueue.main.async {
                    guard self.sessionGeneration == currentGeneration,
                          self.recognitionGeneration == currentRecognitionGeneration else { return }
                    guard self.recognitionRequest != nil else { return }
                    guard self.shouldListen && !self.shouldDismiss && !self.sourceText.isEmpty else {
                        self.isListening = false
                        self.isStarting = false
                        return
                    }

                    self.matchStartOffset = self.recognizedCharCount

                    let nsError = error as NSError
                    let isTimeout = nsError.code == 1110 || nsError.code == 216

                    if isTimeout {
                        self.retryCount = 0
                        if self.audioEngine.isRunning {
                            self.restartTask()
                        } else {
                            self.scheduleBeginRecognition(after: 0.1)
                        }
                    } else if self.retryCount < self.maxRetries {
                        self.retryCount += 1
                        let delay = min(Double(self.retryCount) * 0.5, 1.5)
                        self.scheduleBeginRecognition(after: delay)
                    } else {
                        self.failListening("Speech recognition stopped: \(error.localizedDescription)")
                    }
                }
            }
        }

        startPreemptiveTimer()
    }

    // MARK: - Pre-emptive restart timer

    private func startPreemptiveTimer() {
        preemptiveRestartTimer?.invalidate()
        preemptiveRestartTimer = Timer.scheduledTimer(withTimeInterval: 55.0, repeats: true) { [weak self] _ in
            guard let self, self.isListening, !self.sourceText.isEmpty else { return }
            self.restartTask()
        }
    }

    private func stopPreemptiveTimer() {
        preemptiveRestartTimer?.invalidate()
        preemptiveRestartTimer = nil
    }

    // MARK: - Fuzzy character-level matching

    private func matchCharacters(spoken fullSpoken: String) {
        // Results computed before a jump can be delivered just after it —
        // don't match pre-jump speech against the text at the new offset.
        guard Date().timeIntervalSince(lastJumpAt) > 0.3 else { return }

        // Ignore transcript from before the most recent jump. Trim by the
        // common prefix that survived the recognizer's revisions, but never
        // less than the anchor length minus a small slack — a revision very
        // early in the transcript would otherwise leak the whole pre-jump
        // transcript back into matching.
        var spoken = fullSpoken
        if !spokenAnchorPrefix.isEmpty {
            let common = zip(spokenAnchorPrefix, fullSpoken).prefix(while: { $0 == $1 }).count
            let trimLen = min(fullSpoken.count, max(common, spokenAnchorPrefix.count - 24))
            spoken = String(fullSpoken.dropFirst(trimLen))
        }
        guard !spoken.isEmpty else { return }

        // Strategy 1: character-level fuzzy match from the start offset
        let charResult = charLevelMatch(spoken: spoken)

        // Strategy 2: word-level match (handles STT word substitutions)
        let wordResult = wordLevelMatch(spoken: spoken)

        // Combine the two strategies. When they agree, average; when they
        // disagree, prefer the further (word-level) match so fast reading can
        // catch up instead of being dragged back by the brittle character scan.
        let best = SpeechTextAlignment.bestOffset(characterResult: charResult, wordResult: wordResult)

        let rawCandidate = min(matchStartOffset + best, sourceText.count)
        let candidate = advancePastAnnotations(from: rawCandidate)
        guard candidate > recognizedCharCount else { return }

        // Confidence gating: require 2-of-3 recent results to agree on
        // forward movement to avoid single-result false-positive jumps.
        recentMatchPositions.append(candidate)
        if recentMatchPositions.count > 3 {
            recentMatchPositions.removeFirst()
        }

        // Check if at least 2 of the recent positions agree (within tolerance)
        let agreementThreshold = 10 // characters
        var confirmed = false
        if recentMatchPositions.count >= 2 {
            var agreeCount = 0
            for pos in recentMatchPositions {
                if abs(pos - candidate) <= agreementThreshold {
                    agreeCount += 1
                }
            }
            confirmed = agreeCount >= 2
        }

        // Small forward movements (< 1 word length) are always allowed
        // to keep the highlight responsive for normal reading
        if SpeechTextAlignment.shouldCommit(
            characterResult: charResult,
            wordResult: wordResult,
            current: recognizedCharCount,
            rawCandidate: rawCandidate,
            candidate: candidate,
            confirmed: confirmed
        ) {
            recognizedCharCount = candidate
        }
    }

    private func advancePastAnnotations(from offset: Int) -> Int {
        SpeechTextAlignment.advancePastAnnotations(
            in: sourceText,
            ranges: annotationRanges,
            from: offset
        )
    }

    private func charLevelMatch(spoken: String) -> Int {
        let remainingSource = String(sourceText.dropFirst(matchStartOffset))
        // Use Character arrays (not unicodeScalars) so counts match sourceText.count
        let src = Array(remainingSource.lowercased())
        let spk = Array(Self.normalize(spoken))

        var si = 0
        var ri = 0
        var lastGoodOrigIndex = 0

        while si < src.count && ri < spk.count {
            let sc = src[si]
            let rc = spk[ri]

            if sc == "[",
               let closingIndex = src[si...].firstIndex(of: "]") {
                si = closingIndex + 1
                lastGoodOrigIndex = si
                continue
            }

            // Skip non-alphanumeric in source
            if !sc.isLetter && !sc.isNumber {
                si += 1
                continue
            }
            // Skip non-alphanumeric in spoken
            if !rc.isLetter && !rc.isNumber {
                ri += 1
                continue
            }

            if sc == rc {
                si += 1
                ri += 1
                lastGoodOrigIndex = si
            } else {
                // Try to re-sync: look ahead in both strings
                var found = false

                // Skip up to 5 chars in spoken (STT inserted extra chars, or
                // fast reading outran the scan)
                let maxSkipR = min(5, spk.count - ri - 1)
                if maxSkipR >= 1 {
                    for skipR in 1...maxSkipR {
                        let nextRI = ri + skipR
                        if nextRI < spk.count && spk[nextRI] == sc {
                            ri = nextRI
                            found = true
                            break
                        }
                    }
                }
                if found { continue }

                // Skip up to 5 chars in source (STT missed some chars, or
                // fast reading outran the scan)
                let maxSkipS = min(5, src.count - si - 1)
                if maxSkipS >= 1 {
                    for skipS in 1...maxSkipS {
                        let nextSI = si + skipS
                        if nextSI < src.count && src[nextSI] == rc {
                            si = nextSI
                            found = true
                            break
                        }
                    }
                }
                if found { continue }

                // No resync found — advance spoken pointer only.
                // Do NOT advance lastGoodOrigIndex; this is a genuine mismatch,
                // not a confirmed match position.
                ri += 1
            }
        }

        while si < src.count {
            if src[si] == "[",
               let closingIndex = src[si...].firstIndex(of: "]") {
                si = closingIndex + 1
                lastGoodOrigIndex = si
            } else if !src[si].isLetter && !src[si].isNumber {
                si += 1
                lastGoodOrigIndex = si
            } else {
                break
            }
        }

        return lastGoodOrigIndex
    }

    private static func isAnnotationWord(_ word: String) -> Bool {
        if word.hasPrefix("[") && word.hasSuffix("]") { return true }
        let stripped = word.filter { $0.isLetter || $0.isNumber }
        return stripped.isEmpty
    }

    private func wordLevelMatch(spoken: String) -> Int {
        let remainingSource = String(sourceText.dropFirst(matchStartOffset))
        let sourceWords = remainingSource.split(separator: " ").map { String($0) }
        let spokenWords = splitTextIntoWords(spoken.lowercased())

        var si = 0 // source word index
        var ri = 0 // spoken word index
        var matchedCharCount = 0
        var isInsideAnnotation = false

        while si < sourceWords.count && ri < spokenWords.count {
            // Auto-skip annotation words in source (brackets, emoji)
            let beginsAnnotation = sourceWords[si].hasPrefix("[")
                && sourceWords[si...].contains(where: { $0.contains("]") })
            let skipsAnnotation = isInsideAnnotation || beginsAnnotation || Self.isAnnotationWord(sourceWords[si])
            if skipsAnnotation {
                if beginsAnnotation {
                    isInsideAnnotation = true
                }
                if sourceWords[si].contains("]") {
                    isInsideAnnotation = false
                }
                matchedCharCount += sourceWords[si].count
                if si < sourceWords.count - 1 { matchedCharCount += 1 }
                si += 1
                continue
            }

            let srcWord = sourceWords[si].lowercased()
                .filter { $0.isLetter || $0.isNumber }
            let spkWord = spokenWords[ri]
                .filter { $0.isLetter || $0.isNumber }

            if srcWord == spkWord || isFuzzyMatch(srcWord, spkWord) {
                // Count original chars including trailing punctuation
                matchedCharCount += sourceWords[si].count
                si += 1
                ri += 1
                // Add space separator only if there's a following word
                if si < sourceWords.count {
                    matchedCharCount += 1
                }
            } else {
                // Try skipping up to 5 spoken words (STT hallucinated words,
                // or fast reading produced a burst)
                var foundSpk = false
                let maxSpkSkip = min(5, spokenWords.count - ri - 1)
                for skip in 1...max(1, maxSpkSkip) where skip <= maxSpkSkip {
                    let nextSpk = spokenWords[ri + skip].filter { $0.isLetter || $0.isNumber }
                    if srcWord == nextSpk || isFuzzyMatch(srcWord, nextSpk) {
                        ri += skip
                        foundSpk = true
                        break
                    }
                }
                if foundSpk { continue }

                // Try skipping up to 5 source words (user read fast, STT missed words)
                var foundSrc = false
                let maxSrcSkip = min(5, sourceWords.count - si - 1)
                for skip in 1...max(1, maxSrcSkip) where skip <= maxSrcSkip {
                    let nextSrc = sourceWords[si + skip].lowercased().filter { $0.isLetter || $0.isNumber }
                    if nextSrc == spkWord || isFuzzyMatch(nextSrc, spkWord) {
                        // Add all skipped source words' char counts
                        for s in 0..<skip {
                            matchedCharCount += sourceWords[si + s].count + 1
                        }
                        si += skip
                        foundSrc = true
                        break
                    }
                }
                if foundSrc { continue }

                // Try treating current source word as punctuation-only and skip it
                if srcWord.isEmpty {
                    matchedCharCount += sourceWords[si].count
                    if si < sourceWords.count - 1 { matchedCharCount += 1 }
                    si += 1
                    continue
                }
                // No match, advance spoken
                ri += 1
            }
        }

        // Auto-skip trailing annotation words at end of source
        while si < sourceWords.count {
            let beginsAnnotation = sourceWords[si].hasPrefix("[")
                && sourceWords[si...].contains(where: { $0.contains("]") })
            let skipsAnnotation = isInsideAnnotation || beginsAnnotation || Self.isAnnotationWord(sourceWords[si])
            guard skipsAnnotation else { break }
            if beginsAnnotation {
                isInsideAnnotation = true
            }
            if sourceWords[si].contains("]") {
                isInsideAnnotation = false
            }
            matchedCharCount += sourceWords[si].count
            if si < sourceWords.count - 1 { matchedCharCount += 1 }
            si += 1
        }

        return matchedCharCount
    }

    private func isFuzzyMatch(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        // Exact match
        if a == b { return true }
        let shorter = min(a.count, b.count)
        // Prefix match — only for words with at least 3 chars to avoid
        // false positives like "or" matching "organization"
        if shorter >= 3 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        // Shared prefix >= 60% of shorter word (min 3 chars shared)
        let shared = zip(a, b).prefix(while: { $0 == $1 }).count
        if shorter >= 3 && shared >= max(3, shorter * 3 / 5) { return true }
        // Edit distance tolerance — stricter for very short words
        let dist = editDistance(a, b)
        if shorter <= 2 { return false } // 2-char words must be exact
        if shorter <= 4 { return dist <= 1 }
        if shorter <= 8 { return dist <= 2 }
        return dist <= max(a.count, b.count) / 3
    }

    private func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let temp = dp[j]
                dp[j] = a[i-1] == b[j-1] ? prev : min(prev, dp[j], dp[j-1]) + 1
                prev = temp
            }
        }
        return dp[b.count]
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    }
}
