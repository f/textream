@preconcurrency import AVFoundation
import Foundation
import Observation
import Speech

@Observable
@MainActor
final class SpeechFollower {
    private(set) var recognizedCharacterCount = 0
    private(set) var isListening = false
    private(set) var isStarting = false
    private(set) var isSpeaking = false
    private(set) var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    private(set) var lastSpokenText = ""
    private(set) var errorMessage: String?

    @ObservationIgnored private var source = PromptScript("")
    @ObservationIgnored private var matcher = PromptMatcher(source: PromptScript(""))
    @ObservationIgnored private var mode: FollowMode = .classic
    @ObservationIgnored private var localeIdentifier = "en-US"
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var voiceActivityDetector = VoiceActivityDetector()
    @ObservationIgnored private var restartTimer: Timer?
    @ObservationIgnored private var pendingRestart: DispatchWorkItem?
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var shouldFollow = false
    @ObservationIgnored private var spokenAnchorPrefix = ""
    @ObservationIgnored private var lastJumpAt = Date.distantPast

    @ObservationIgnored nonisolated private let requestLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    func prepare(source: PromptScript, mode: FollowMode, localeIdentifier: String) async -> Bool {
        stop(resetProgress: true)
        self.source = source
        self.matcher = PromptMatcher(source: source)
        self.mode = mode
        self.localeIdentifier = localeIdentifier
        recognizedCharacterCount = matcher.recognizedCharacterCount
        errorMessage = nil

        guard mode == .wordTracking else { return true }
        let authorization = await Self.requestAuthorization()
        guard authorization == .authorized else {
            errorMessage = "Speech Recognition access is required for Word Tracking."
            return false
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            errorMessage = "Speech recognition is not supported for the selected language."
            return false
        }
        self.recognizer = recognizer
        return true
    }

    func start() {
        guard !source.text.isEmpty else { return }
        shouldFollow = true
        errorMessage = nil
        voiceActivityDetector.reset()
        isSpeaking = false
        retryCount = 0

        switch mode {
        case .classic:
            isStarting = false
            isListening = false
        case .voiceActivated:
            isStarting = false
            isListening = true
        case .wordTracking:
            beginRecognition()
        }
    }

    func pause() {
        shouldFollow = false
        isListening = false
        isStarting = false
        isSpeaking = false
        voiceActivityDetector.reset()
        cleanupRecognition()
    }

    func resume() {
        guard !source.text.isEmpty else { return }
        matcher.restartFromCurrentProgress()
        start()
    }

    func stop(resetProgress: Bool = false) {
        pause()
        if resetProgress {
            matcher.reset(source: source)
            recognizedCharacterCount = matcher.recognizedCharacterCount
            lastSpokenText = ""
            audioLevels = Array(repeating: 0, count: 30)
        }
    }

    func jump(to characterOffset: Int) {
        let previous = recognizedCharacterCount
        recognizedCharacterCount = matcher.jump(to: characterOffset)
        let distance = abs(recognizedCharacterCount - previous)
        if mode == .wordTracking, shouldFollow {
            if distance > 500 {
                beginRecognition()
            } else {
                spokenAnchorPrefix = lastSpokenText
                lastJumpAt = Date()
            }
        }
    }

    func processAudioLevel(_ level: CGFloat, at timestamp: TimeInterval? = nil) {
        let now = timestamp ?? ProcessInfo.processInfo.systemUptime
        var nextLevels = audioLevels
        nextLevels.append(level)
        if nextLevels.count > 30 {
            nextLevels.removeFirst(nextLevels.count - 30)
        }
        // Publish one snapshot per coalesced sample. Mutating the observed
        // array twice caused two SwiftUI invalidations for every meter tick.
        audioLevels = nextLevels
        voiceActivityDetector.process(level: level, at: now)
        let speaking = voiceActivityDetector.isActive(at: now)
        if isSpeaking != speaking { isSpeaking = speaking }
    }

    nonisolated func consumeAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        requestLock.lock()
        recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
        requestLock.unlock()
    }

    private func beginRecognition() {
        guard shouldFollow, mode == .wordTracking, !source.text.isEmpty else { return }
        cleanupRecognition()
        generation &+= 1
        let currentGeneration = generation
        matcher.restartFromCurrentProgress()
        spokenAnchorPrefix = ""
        lastSpokenText = ""
        isStarting = true
        isListening = false

        let activeRecognizer = recognizer ?? SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        guard let activeRecognizer else {
            fail("Speech recognition is not supported for the selected language.")
            return
        }
        recognizer = activeRecognizer
        guard activeRecognizer.isAvailable else {
            scheduleRestart(message: "Speech recognizer is temporarily unavailable.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        let upcoming = String(source.text.dropFirst(matcher.matchStartOffset))
        let contextualWords = upcoming.split(separator: " ")
            .map { String($0).lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { $0.count >= 5 }
        request.contextualStrings = Array(Set(contextualWords).prefix(50))

        requestLock.lock()
        recognitionRequest = request
        requestLock.unlock()

        recognitionTask = activeRecognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let speechError = error as NSError?
            let errorCode = speechError?.code
            let errorMessage = speechError?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration, self.shouldFollow else { return }
                if let transcript {
                    self.retryCount = 0
                    self.handleTranscript(transcript)
                }
                if let errorCode, let errorMessage {
                    let isExpectedTimeout = errorCode == 1110 || errorCode == 216
                    if isExpectedTimeout {
                        self.retryCount = 0
                        self.beginRecognition()
                    } else {
                        self.scheduleRestart(message: errorMessage)
                    }
                } else if isFinal {
                    self.retryCount = 0
                    self.beginRecognition()
                }
            }
        }

        isStarting = false
        isListening = true
        startPreemptiveRestartTimer()
    }

    private func handleTranscript(_ fullTranscript: String) {
        guard Date().timeIntervalSince(lastJumpAt) > 0.3 else { return }
        lastSpokenText = fullTranscript
        var transcript = fullTranscript
        if !spokenAnchorPrefix.isEmpty {
            let commonPrefixLength = zip(spokenAnchorPrefix, fullTranscript)
                .prefix(while: { $0 == $1 })
                .count
            let trimLength = min(
                fullTranscript.count,
                max(commonPrefixLength, spokenAnchorPrefix.count - 24)
            )
            transcript = String(fullTranscript.dropFirst(trimLength))
        }
        guard !transcript.isEmpty else { return }
        recognizedCharacterCount = matcher.match(transcript: transcript)
    }

    private func scheduleRestart(message: String) {
        guard shouldFollow, mode == .wordTracking else { return }
        if retryCount >= 10 {
            fail("Speech recognition stopped: \(message)")
            return
        }
        retryCount += 1
        isListening = false
        isStarting = true
        pendingRestart?.cancel()
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldFollow, self.generation == expectedGeneration else { return }
            self.beginRecognition()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(Double(retryCount) * 0.35, 1.5), execute: work)
    }

    private func startPreemptiveRestartTimer() {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 55, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.shouldFollow else { return }
                self.beginRecognition()
            }
        }
    }

    private func cleanupRecognition() {
        pendingRestart?.cancel()
        pendingRestart = nil
        restartTimer?.invalidate()
        restartTimer = nil
        generation &+= 1
        requestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func fail(_ message: String) {
        shouldFollow = false
        isListening = false
        isStarting = false
        isSpeaking = false
        errorMessage = message
        cleanupRecognition()
    }

    // Speech invokes its authorization completion on an arbitrary queue. Keep
    // the continuation bridge nonisolated so Swift does not attach MainActor
    // preconditions to the imported callback closure.
    nonisolated private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
