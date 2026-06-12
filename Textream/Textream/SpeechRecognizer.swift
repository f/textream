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
            var uid: Unmanaged<CFString>? = nil
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { continue }
            let uidValue = uid?.takeRetainedValue() as String? ?? ""

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>? = nil
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr else { continue }
            let nameValue = name?.takeRetainedValue() as String? ?? ""

            result.append(AudioInputDevice(id: deviceID, uid: uidValue, name: nameValue))
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
    var error: String?
    var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    var lastSpokenText: String = ""
    var shouldDismiss: Bool = false
    var shouldAdvancePage: Bool = false
    private var lastSpokenContext: String = ""
    private var lastPartialSpoken: String = ""

    /// True when recent audio levels indicate the user is actively speaking
    var isSpeaking: Bool {
        let recent = audioLevels.suffix(10)
        guard !recent.isEmpty else { return false }
        let avg = recent.reduce(0, +) / CGFloat(recent.count)
        return avg > 0.08
    }

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var sourceText: String = ""
    private var normalizedSource: String = ""
    private var matchStartOffset: Int = 0  // char offset to start matching from
    private var retryCount: Int = 0
    private let maxRetries: Int = 10
    private var configurationChangeObserver: Any?
    private var pendingRestart: DispatchWorkItem?
    private var sessionGeneration: Int = 0
    private var suppressConfigChange: Bool = false
    private var requestLock = NSLock()
    private var preemptiveRestartTimer: Timer?
    /// Sliding window of recent match positions for confidence gating.
    /// We require 2-of-3 recent results to agree before committing a forward jump.
    private var recentMatchPositions: [Int] = []

    /// Update the source text while preserving the current recognized char count.
    /// Used by Director Mode to live-edit unread text without resetting read progress.
    func updateText(_ text: String, preservingCharCount: Int) {
        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        normalizedSource = Self.normalize(collapsed)
        recognizedCharCount = min(preservingCharCount, collapsed.count)
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
    }

    /// Jump highlight to a specific char offset (e.g. when user taps a word)
    func jumpTo(charOffset: Int) {
        recognizedCharCount = charOffset
        matchStartOffset = charOffset
        retryCount = 0
        recentMatchPositions = []
        if isListening {
            restartRecognition()
        }
    }

    private func forceRestartAfterTimeout() {
        print("Timeout restart - recreating audio engine")
        
        // Save state
        let savedOffset = recognizedCharCount
        let savedSource = sourceText
        
        // Full stop
        cleanupRecognition()
        
        // Recreate engine (essential!)
        audioEngine = AVAudioEngine()
        
        // Restore state
        sourceText = savedSource
        recognizedCharCount = savedOffset
        matchStartOffset = savedOffset
        recentMatchPositions = []
        retryCount = 0
        
        // Small delay to release resources
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.beginRecognition()
        }
    }
    
    func start(with text: String) {
        // Clean up any previous session immediately so pending restarts
        // and stale taps are removed before the async auth callback fires.
        cleanupRecognition()

        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        normalizedSource = Self.normalize(collapsed)
        recognizedCharCount = 0
        matchStartOffset = 0
        retryCount = 0
        recentMatchPositions = []
        error = nil
        sessionGeneration += 1

        // Check microphone permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            error = "Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow Textream."
            openMicrophoneSettings()
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.requestSpeechAuthAndBegin()
                    } else {
                        self?.error = "Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow Textream."
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

    private func requestSpeechAuthAndBegin() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self?.beginRecognition()
                default:
                    self?.error = "Speech recognition not authorized. Open System Settings → Privacy & Security → Speech Recognition to allow Textream."
                    self?.openSpeechRecognitionSettings()
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

    func stop() {
        isListening = false
        cleanupRecognition()
    }

    func forceStop() {
        isListening = false
        sourceText = ""
        retryCount = maxRetries
        recentMatchPositions = []
        cleanupRecognition()
    }

    func resume() {
        retryCount = 0
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        shouldDismiss = false
        beginRecognition()
    }

    private func cleanupRecognitionTask() {
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
    }

    /// Coalesces all delayed beginRecognition() calls into a single pending work item.
    /// Any previously scheduled restart is cancelled before the new one is queued.
    private func scheduleBeginRecognition(after delay: TimeInterval) {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestart = nil
            self.beginRecognition()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func beginRecognition() {
        // Ensure clean state
        cleanupRecognition()

        // Create a fresh engine so it picks up the current hardware format.
        // AVAudioEngine caches the device format internally and reset() alone
        // does not reliably flush it after a mic switch.
        audioEngine = AVAudioEngine()

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.suppressConfigChange = false
            }
        }

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: NotchSettings.shared.speechLocale))
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer not available"
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        
        // Add context from last spoken words
        var allContext: [String] = []
        if !lastSpokenContext.isEmpty {
            allContext.append(lastSpokenContext)
        }
        // Context for remaining text
        let upcoming = String(sourceText.dropFirst(matchStartOffset))
        let contextWords = upcoming.split(separator: " ")
            .map { String($0).lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { $0.count >= 5 }
        allContext.append(contentsOf: Array(Set(contextWords)).prefix(50))
        if !allContext.isEmpty {
            recognitionRequest.contextualStrings = allContext
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
                error = "Audio input unavailable"
                isListening = false
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
            guard let self, !self.suppressConfigChange, !self.sourceText.isEmpty else { return }
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
                self?.audioLevels.append(level)
                if (self?.audioLevels.count ?? 0) > 30 {
                    self?.audioLevels.removeFirst()
                }
            }
        }

        let currentGeneration = sessionGeneration
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let spoken = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    // Ignore stale results from a previous session
                    guard self.sessionGeneration == currentGeneration else { return }
                    self.lastPartialSpoken = spoken
                    self.retryCount = 0 // Reset on success
                    self.lastSpokenText = spoken
                    self.matchCharacters(spoken: spoken)
                }
            }
            if let error {
                DispatchQueue.main.async {
                    guard self.sessionGeneration == currentGeneration else { return }
                    guard self.recognitionRequest != nil else { return }
                    guard self.isListening && !self.shouldDismiss && !self.sourceText.isEmpty else {
                        self.isListening = false
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
                        self.retryCount = 0
                        // Advance with the last partial phrase before interruption
                        if !self.lastPartialSpoken.isEmpty {
                            let extraMatch = self.charLevelMatch(spoken: self.lastPartialSpoken)
                            self.recognizedCharCount = min(
                                self.matchStartOffset + extraMatch,
                                self.sourceText.count
                            )
                            self.matchStartOffset = self.recognizedCharCount
                        }
                        // After a timeout, ALWAYS perform a full engine restart
                        self.forceRestartAfterTimeout()
                    } else if self.retryCount < self.maxRetries {
                        self.retryCount += 1
                        let delay = min(Double(self.retryCount) * 0.5, 1.5)
                        self.scheduleBeginRecognition(after: delay)
                    } else {
                        self.isListening = false
                    }
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            startPreemptiveTimer()
        } catch {
            // Transient failure after a device switch — retry with longer delay
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                self.error = "Audio engine failed: \(error.localizedDescription)"
                isListening = false
            }
        }
    }

    private func restartRecognition() {
        retryCount = 0
        isListening = true
        if audioEngine.isRunning {
            restartTask()
        } else {
            cleanupRecognition()
            scheduleBeginRecognition(after: 0.5)
        }
    }

    // MARK: - Thread-safe buffer appending

    private func appendBufferToRequest(_ buffer: AVAudioPCMBuffer) {
        requestLock.lock()
        recognitionRequest?.append(buffer)
        requestLock.unlock()
    }

    // MARK: - Soft restart (task only, keeps audio engine running)

    private func restartTask() {
        // Update match offset before restarting
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        
        // Cancel any pending restart
        pendingRestart?.cancel()
        pendingRestart = nil
        
        // IMPORTANT: Do NOT stop audioEngine or remove the tap
        // Only stop the recognition task, not the audio stream
        
        // Lock the old request and task
        requestLock.lock()
        let oldRequest = recognitionRequest
        recognitionRequest = nil  // Prevent new appends
        requestLock.unlock()
        
        oldRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Create a NEW request but reuse the same audioEngine (still running)
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        
        // Add context from last spoken words
        var allContext: [String] = []
        if !lastSpokenContext.isEmpty {
            allContext.append(lastSpokenContext)
        }
        // Context for remaining text
        let upcoming = String(sourceText.dropFirst(matchStartOffset))
        let contextWords = upcoming.split(separator: " ")
            .map { String($0).lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { $0.count >= 5 }
        allContext.append(contentsOf: Array(Set(contextWords)).prefix(50))
        if !allContext.isEmpty {
            newRequest.contextualStrings = allContext
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
            error = "Speech recognizer not available"
            isListening = false
            return
        }

        let currentGeneration = sessionGeneration
        recognitionTask = speechRecognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let spoken = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    guard self.sessionGeneration == currentGeneration else { return }
                    self.lastPartialSpoken = spoken
                    self.retryCount = 0
                    self.lastSpokenText = spoken
                    self.matchCharacters(spoken: spoken)
                }
            }
            if let error {
                DispatchQueue.main.async {
                    guard self.recognitionRequest != nil else { return }
                    guard self.isListening && !self.shouldDismiss && !self.sourceText.isEmpty else {
                        self.isListening = false
                        return
                    }
                    
                    self.matchStartOffset = self.recognizedCharCount
                    let nsError = error as NSError
                    let isTimeout = nsError.code == 1110 || nsError.code == 216
                    
                    if isTimeout {
                        self.retryCount = 0
                        if !self.lastPartialSpoken.isEmpty {
                            let extraMatch = self.charLevelMatch(spoken: self.lastPartialSpoken)
                            self.recognizedCharCount = min(
                                self.matchStartOffset + extraMatch,
                                self.sourceText.count
                            )
                            self.matchStartOffset = self.recognizedCharCount
                        }
                        // CORRECT: full restart instead of restartTask()
                        self.forceRestartAfterTimeout()
                    } else if self.retryCount < self.maxRetries {
                        self.retryCount += 1
                        let delay = min(Double(self.retryCount) * 0.5, 1.5)
                        self.scheduleBeginRecognition(after: delay)
                    } else {
                        self.isListening = false
                    }
                }
            }
        }
    }
        
    // MARK: - Pre-emptive restart timer

    private func startPreemptiveTimer() {
        // Timer disabled - let natural timeout handle the restart
        // preemptiveRestartTimer?.invalidate()
        // preemptiveRestartTimer = Timer.scheduledTimer(withTimeInterval: 55.0, repeats: true) { [weak self] _ in
        //     guard let self, self.isListening, !self.sourceText.isEmpty else { return }
        //     self.restartTask()
        // }
    }

    private func stopPreemptiveTimer() {
        preemptiveRestartTimer?.invalidate()
        preemptiveRestartTimer = nil
    }

    // MARK: - Fuzzy character-level matching

    private func matchCharacters(spoken: String) {
        // Strategy 1: character-level fuzzy match from the start offset
        let charResult = charLevelMatch(spoken: spoken)

        // Strategy 2: word-level match (handles STT word substitutions)
        let wordResult = wordLevelMatch(spoken: spoken)

        // Use agreement-based selection instead of blind max().
        // If both strategies agree within a tolerance, use the average.
        // If they disagree wildly, use the more conservative (lower) result
        // to avoid false-positive jumps.
        let best: Int
        let tolerance = 20 // characters
        if abs(charResult - wordResult) <= tolerance {
            best = (charResult + wordResult) / 2
        } else {
            best = min(charResult, wordResult)
        }

        let newCount = matchStartOffset + best
        guard newCount > recognizedCharCount else { return }

        let candidate = min(newCount, sourceText.count)

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
        let smallStep = candidate - recognizedCharCount <= 15

        if confirmed || smallStep {
            recognizedCharCount = candidate
            
            // Preserve last 5 words for next restart context
            let contextWords = spoken.split(separator: " ").map(String.init).suffix(5)
            lastSpokenContext = contextWords.joined(separator: " ")
        }
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

                // Skip up to 3 chars in spoken (STT inserted extra chars)
                let maxSkipR = min(3, spk.count - ri - 1)
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

                // Skip up to 3 chars in source (STT missed some chars)
                let maxSkipS = min(3, src.count - si - 1)
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
        let spokenWords = spoken.lowercased().split(separator: " ").map { String($0) }

        var si = 0 // source word index
        var ri = 0 // spoken word index
        var matchedCharCount = 0

        while si < sourceWords.count && ri < spokenWords.count {
            // Auto-skip annotation words in source (brackets, emoji)
            if Self.isAnnotationWord(sourceWords[si]) {
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
                // Try skipping up to 3 spoken words (STT hallucinated words)
                var foundSpk = false
                let maxSpkSkip = min(3, spokenWords.count - ri - 1)
                for skip in 1...max(1, maxSpkSkip) where skip <= maxSpkSkip {
                    let nextSpk = spokenWords[ri + skip].filter { $0.isLetter || $0.isNumber }
                    if srcWord == nextSpk || isFuzzyMatch(srcWord, nextSpk) {
                        ri += skip
                        foundSpk = true
                        break
                    }
                }
                if foundSpk { continue }

                // Try skipping up to 3 source words (user read fast, STT missed words)
                var foundSrc = false
                let maxSrcSkip = min(3, sourceWords.count - si - 1)
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
        while si < sourceWords.count && Self.isAnnotationWord(sourceWords[si]) {
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
