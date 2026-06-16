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
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { continue }

            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr else { continue }

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
    var error: String?
    var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    var lastSpokenText: String = ""
    var shouldDismiss: Bool = false
    var shouldAdvancePage: Bool = false

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
    private var compactSourceCharacters: [Character] = []
    private var compactSourceToOriginalOffset: [Int] = []
    private var matchStartOffset: Int = 0
    private var retryCount: Int = 0
    private let maxRetries: Int = 10
    private var configurationChangeObserver: Any?
    private var pendingRestart: DispatchWorkItem?
    private var sessionGeneration: Int = 0
    private var suppressConfigChange: Bool = false
    private var requestLock = NSLock()
    private var preemptiveRestartTimer: Timer?
    private var recentMatchPositions: [Int] = []
    private var requiresTranscription: Bool = true
    private var transcriptionBackend: TranscriptionBackend = .none
    private var localSenseVoiceRunner: LocalSenseVoiceRunner?
    private var pendingAnchorJumpTarget: Int?
    private var pendingAnchorJumpHits: Int = 0
    private var pendingAnchorJumpTimestamp: TimeInterval = 0

    private enum TranscriptionBackend {
        case none
        case appleSpeech
        case localSenseVoice
    }

    func updateText(_ text: String, preservingCharCount: Int) {
        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        normalizedSource = Self.normalize(collapsed)
        rebuildCompactSourceIndex()
        recognizedCharCount = min(preservingCharCount, collapsed.count)
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        resetPendingAnchorJumpConfirmation()
    }

    func jumpTo(charOffset: Int) {
        recognizedCharCount = charOffset
        matchStartOffset = charOffset
        retryCount = 0
        recentMatchPositions = []
        resetPendingAnchorJumpConfirmation()
        if isListening {
            restartRecognition()
        }
    }

    func start(with text: String) {
        cleanupRecognition()

        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        normalizedSource = Self.normalize(collapsed)
        rebuildCompactSourceIndex()
        recognizedCharCount = 0
        matchStartOffset = 0
        retryCount = 0
        recentMatchPositions = []
        resetPendingAnchorJumpConfirmation()
        error = nil
        sessionGeneration += 1
        let settings = NotchSettings.shared
        requiresTranscription = settings.listeningMode == .wordTracking
        if requiresTranscription {
            transcriptionBackend = settings.speechEngineMode == .localSenseVoice ? .localSenseVoice : .appleSpeech
        } else {
            transcriptionBackend = .none
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            error = "麦克风权限被拒绝。请前往 系统设置 → 隐私与安全性 → 麦克风，允许 auto-cue。"
            openMicrophoneSettings()
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        if self?.transcriptionBackend == .appleSpeech {
                            self?.requestSpeechAuthAndBegin()
                        } else {
                            self?.beginRecognition()
                        }
                    } else {
                        self?.error = "麦克风权限被拒绝。请前往 系统设置 → 隐私与安全性 → 麦克风，允许 auto-cue。"
                    }
                }
            }
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        if transcriptionBackend == .appleSpeech {
            requestSpeechAuthAndBegin()
        } else {
            beginRecognition()
        }
    }

    private func requestSpeechAuthAndBegin() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self?.beginRecognition()
                default:
                    self?.error = "语音识别未授权。请前往 系统设置 → 隐私与安全性 → 语音识别，允许 auto-cue。"
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
        resetPendingAnchorJumpConfirmation()
        shouldDismiss = false
        beginRecognition()
    }

    private func cleanupRecognitionTask() {
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
        localSenseVoiceRunner?.stop()
        localSenseVoiceRunner = nil
        resetPendingAnchorJumpConfirmation()
    }

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
        cleanupRecognition()

        audioEngine = AVAudioEngine()

        let micUID = NotchSettings.shared.selectedMicUID
        if !micUID.isEmpty, let deviceID = AudioInputDevice.deviceID(forUID: micUID) {
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
                AudioUnitUninitialize(audioUnit)
                AudioUnitInitialize(audioUnit)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.suppressConfigChange = false
            }
        }

        if transcriptionBackend == .appleSpeech {
            let resolvedLocale = Self.resolveSpeechLocaleIdentifier(
                preferred: NotchSettings.shared.speechLocale,
                text: sourceText
            )
            if resolvedLocale != NotchSettings.shared.speechLocale {
                NotchSettings.shared.speechLocale = resolvedLocale
            }

            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: resolvedLocale))
            guard let speechRecognizer, speechRecognizer.isAvailable else {
                error = "语音识别器不可用"
                return
            }

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else { return }
            recognitionRequest.shouldReportPartialResults = true

            let upcoming = String(sourceText.dropFirst(matchStartOffset))
            let contextWords = Self.cjkContextWords(from: upcoming)
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

        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                error = "音频输入不可用"
                isListening = false
            }
            return
        }

        let monoFormat = AVAudioFormat(
            commonFormat: hardwareFormat.commonFormat,
            sampleRate: hardwareFormat.sampleRate,
            channels: 1,
            interleaved: hardwareFormat.isInterleaved
        )
        let tapFormat = (hardwareFormat.channelCount > 1) ? monoFormat : hardwareFormat

        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.suppressConfigChange, !self.sourceText.isEmpty else { return }
            self.restartRecognition()
        }

        inputNode.removeTap(onBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            if self?.transcriptionBackend == .appleSpeech {
                self?.recognitionRequest?.append(buffer)
            }

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

        if transcriptionBackend == .appleSpeech,
           let speechRecognizer,
           let recognitionRequest {
            let currentGeneration = sessionGeneration
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let spoken = result.bestTranscription.formattedString
                    DispatchQueue.main.async {
                        guard self.sessionGeneration == currentGeneration else { return }
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
                            self.isListening = false
                        }
                    }
                }
            }
        } else {
            recognitionTask = nil
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            startPreemptiveTimer()
            if transcriptionBackend == .localSenseVoice {
                let currentGeneration = sessionGeneration
                guard startLocalSenseVoiceTranscription(generation: currentGeneration) else {
                    cleanupRecognition()
                    isListening = false
                    return
                }
            }
        } catch {
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                self.error = "音频引擎失败：\(error.localizedDescription)"
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

    private func restartTask() {
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        resetPendingAnchorJumpConfirmation()

        pendingRestart?.cancel()
        pendingRestart = nil

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true

        let upcoming = String(sourceText.dropFirst(matchStartOffset))
        let contextWords = Self.cjkContextWords(from: upcoming)
        let uniqueWords = Array(Set(contextWords).prefix(50))
        if !uniqueWords.isEmpty {
            newRequest.contextualStrings = uniqueWords
        }

        requestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil

        requestLock.lock()
        recognitionRequest = newRequest
        requestLock.unlock()

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = "语音识别器不可用"
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
                        self.isListening = false
                    }
                }
            }
        }

        startPreemptiveTimer()
    }

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

    private func startLocalSenseVoiceTranscription(generation: Int) -> Bool {
        let settings = NotchSettings.shared
        let configuredExecutablePath = settings.localSenseVoiceExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let executablePath = resolveLocalSenseVoiceExecutablePath(configuredExecutablePath) else {
            if configuredExecutablePath.isEmpty {
                error = "未配置本地识别程序。请在 设置 → 引导 → 本地模型 中导入 sense-voice-stream。"
            } else {
                error = "识别程序无效：\(configuredExecutablePath)\n请导入 sense-voice-stream 可执行文件。"
            }
            return false
        }
        let modelPath = settings.localSenseVoiceModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileManager = FileManager.default

        guard !modelPath.isEmpty else {
            error = "未配置本地模型文件。请在 设置 → 引导 → 本地模型 中导入 .gguf 文件。"
            return false
        }
        guard fileManager.fileExists(atPath: modelPath) else {
            error = "本地模型文件不存在：\(modelPath)"
            return false
        }

        let language = resolveLocalSenseVoiceLanguage()
        let dyldLibraryPaths = resolveLocalSenseVoiceLibraryPaths(executablePath: executablePath)

        let runner = LocalSenseVoiceRunner()
        let started = runner.start(
            config: LocalSenseVoiceRunner.Config(
                executablePath: executablePath,
                modelPath: modelPath,
                language: language,
                disableGPU: settings.localSenseVoiceDisableGPU,
                dyldLibraryPaths: dyldLibraryPaths
            ),
            onTranscript: { [weak self] transcript in
                DispatchQueue.main.async {
                    self?.handleLocalSenseVoiceTranscript(transcript, generation: generation)
                }
            },
            onError: { [weak self] stderrLine in
                guard let self else { return }
                let normalized = stderrLine.lowercased()
                let isImportant = normalized.contains("error")
                    || normalized.contains("failed")
                    || normalized.contains("dyld")
                    || normalized.contains("couldn't")
                guard isImportant else { return }
                DispatchQueue.main.async {
                    guard self.sessionGeneration == generation else { return }
                    self.error = "本地模型错误：\(stderrLine)"
                }
            },
            onExit: { [weak self] code in
                DispatchQueue.main.async {
                    self?.handleLocalSenseVoiceExit(code: code, generation: generation)
                }
            }
        )

        if !started {
            error = runner.lastError ?? "启动本地识别失败"
            return false
        }

        localSenseVoiceRunner = runner
        return true
    }

    private func handleLocalSenseVoiceTranscript(_ transcript: String, generation: Int) {
        guard sessionGeneration == generation else { return }
        let cleaned = Self.sanitizeLocalTranscript(transcript)
        guard !cleaned.isEmpty else { return }
        retryCount = 0
        lastSpokenText = cleaned
        matchCharacters(spoken: cleaned)
    }

    private func handleLocalSenseVoiceExit(code: Int32, generation: Int) {
        guard sessionGeneration == generation else { return }
        guard isListening, !shouldDismiss, !sourceText.isEmpty else { return }
        if retryCount < maxRetries {
            retryCount += 1
            let delay = min(Double(retryCount) * 0.5, 1.5)
            scheduleBeginRecognition(after: delay)
        } else {
            isListening = false
            error = "本地识别进程已停止（退出码：\(code)）"
        }
    }

    private func resolveLocalSenseVoiceLanguage() -> String {
        let configured = NotchSettings.shared.localSenseVoiceLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if configured != "auto", !configured.isEmpty {
            return configured
        }

        if let code = Self.languageCode(of: NotchSettings.shared.speechLocale) {
            switch code {
            case "zh", "en", "yue", "ja", "ko":
                return code
            default:
                break
            }
        }

        if let hint = Self.dominantLanguageHint(from: sourceText) {
            return hint
        }

        return "auto"
    }

    private func resolveLocalSenseVoiceExecutablePath(_ configuredPath: String) -> String? {
        if isValidLocalSenseVoiceExecutable(configuredPath) {
            return configuredPath
        }

        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/Tools/本地语音大模型/SenseVoice.cpp/build/bin/sense-voice-stream",
            "\(home)/Tools/SenseVoice.cpp/build/bin/sense-voice-stream",
        ]

        for candidate in candidates where isValidLocalSenseVoiceExecutable(candidate) {
            if NotchSettings.shared.localSenseVoiceExecutablePath != candidate {
                NotchSettings.shared.localSenseVoiceExecutablePath = candidate
            }
            return candidate
        }
        return nil
    }

    private func isValidLocalSenseVoiceExecutable(_ path: String) -> Bool {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        guard FileManager.default.fileExists(atPath: normalized) else { return false }
        let executableName = URL(fileURLWithPath: normalized).lastPathComponent.lowercased()
        guard executableName.contains("sense-voice-stream") else { return false }
        return ensureExecutablePermissionIfNeeded(at: normalized)
    }

    private func resolveLocalSenseVoiceLibraryPaths(executablePath: String) -> [String] {
        let fileManager = FileManager.default
        let executableURL = URL(fileURLWithPath: executablePath)
        let executableDirectory = executableURL.deletingLastPathComponent()

        let candidates = [
            executableDirectory.appendingPathComponent("../lib").standardizedFileURL.path,
            executableDirectory.appendingPathComponent("../../lib").standardizedFileURL.path,
            executableDirectory.path,
        ]

        var seen = Set<String>()
        var paths: [String] = []
        for path in candidates {
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                paths.append(path)
            }
        }
        return paths
    }

    private func ensureExecutablePermissionIfNeeded(at path: String) -> Bool {
        let fileManager = FileManager.default
        if fileManager.isExecutableFile(atPath: path) {
            return true
        }
        do {
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: path)
        } catch {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    // MARK: - Fuzzy character-level matching

    private func matchCharacters(spoken: String) {
        let charResult = charLevelMatch(spoken: spoken)
        let wordResult = wordLevelMatch(spoken: spoken)
        let spokenCompactCount = compactCharacters(from: spoken).count
        let isCJK = Self.hasCJKCharacters(sourceText)

        let best: Int
        if isCJK {
            best = max(charResult, wordResult)
        } else {
            let tolerance = 20
            if abs(charResult - wordResult) <= tolerance {
                best = (charResult + wordResult) / 2
            } else {
                best = min(charResult, wordResult)
            }
        }

        var newCount = matchStartOffset + best
        if transcriptionBackend == .localSenseVoice {
            let maxBaseAdvance = max(28, min(180, spokenCompactCount * 7))
            newCount = min(newCount, recognizedCharCount + maxBaseAdvance)
        }

        if transcriptionBackend == .localSenseVoice,
           let anchoredOffset = globalAnchorMatch(spoken: spoken),
           shouldAcceptAnchorJump(to: anchoredOffset, spokenCompactCount: spokenCompactCount) {
            newCount = max(newCount, anchoredOffset)
        }

        guard newCount > recognizedCharCount else {
            if transcriptionBackend == .localSenseVoice {
                if Date().timeIntervalSinceReferenceDate - pendingAnchorJumpTimestamp > 1.8 {
                    resetPendingAnchorJumpConfirmation()
                }
            }
            return
        }

        let candidate = min(newCount, sourceText.count)

        recentMatchPositions.append(candidate)
        if recentMatchPositions.count > 3 {
            recentMatchPositions.removeFirst()
        }

        let agreementThreshold = isCJK ? 25 : 10
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

        let smallStep = isCJK
            ? (candidate - recognizedCharCount <= 25)
            : (candidate - recognizedCharCount <= 15)

        if confirmed || smallStep {
            recognizedCharCount = candidate
            if transcriptionBackend == .localSenseVoice {
                matchStartOffset = max(0, recognizedCharCount - 24)
            }
        }
    }

    private func resetPendingAnchorJumpConfirmation() {
        pendingAnchorJumpTarget = nil
        pendingAnchorJumpHits = 0
        pendingAnchorJumpTimestamp = 0
    }

    private func shouldAcceptAnchorJump(to anchoredOffset: Int, spokenCompactCount: Int) -> Bool {
        guard anchoredOffset > recognizedCharCount else {
            resetPendingAnchorJumpConfirmation()
            return false
        }

        let delta = anchoredOffset - recognizedCharCount
        let immediateLimit = max(90, min(260, spokenCompactCount * 7))
        guard delta > immediateLimit else {
            resetPendingAnchorJumpConfirmation()
            return true
        }

        let now = Date().timeIntervalSinceReferenceDate
        let timeout: TimeInterval = 1.8
        let targetTolerance = max(60, spokenCompactCount * 6)

        if let pending = pendingAnchorJumpTarget,
           abs(pending - anchoredOffset) <= targetTolerance,
           now - pendingAnchorJumpTimestamp <= timeout {
            pendingAnchorJumpHits += 1
        } else {
            pendingAnchorJumpTarget = anchoredOffset
            pendingAnchorJumpHits = 1
        }
        pendingAnchorJumpTimestamp = now

        if pendingAnchorJumpHits >= 2 {
            resetPendingAnchorJumpConfirmation()
            return true
        }
        return false
    }

    private func rebuildCompactSourceIndex() {
        compactSourceCharacters.removeAll(keepingCapacity: true)
        compactSourceToOriginalOffset.removeAll(keepingCapacity: true)

        let sourceChars = Array(sourceText)
        compactSourceCharacters.reserveCapacity(sourceChars.count)
        compactSourceToOriginalOffset.reserveCapacity(sourceChars.count)

        for (index, char) in sourceChars.enumerated() {
            for lowered in String(char).lowercased() where lowered.isLetter || lowered.isNumber {
                compactSourceCharacters.append(lowered)
                compactSourceToOriginalOffset.append(index + 1)
            }
        }
    }

    private func compactCharacters(from text: String) -> [Character] {
        var result: [Character] = []
        for char in text.lowercased() where char.isLetter || char.isNumber {
            result.append(char)
        }
        return result
    }

    private func globalAnchorMatch(spoken: String) -> Int? {
        guard !sourceText.isEmpty, !compactSourceCharacters.isEmpty else { return nil }

        let spokenCompact = compactCharacters(from: spoken)
        guard spokenCompact.count >= 4 else { return nil }
        guard spokenCompact.count <= compactSourceCharacters.count else { return nil }
        let hasPriorExact = hasPriorExactOccurrence(of: spokenCompact, beforeOriginalOffset: recognizedCharCount)
        let hasPriorSeed = hasPriorSeedOccurrence(of: spokenCompact, beforeOriginalOffset: recognizedCharCount)
        let hasForwardDuplicateSeed = hasForwardDuplicateSeedOccurrence(of: spokenCompact, fromOriginalOffset: recognizedCharCount)
        let preferNearestForward = hasPriorExact || hasPriorSeed || hasForwardDuplicateSeed
        let allowFarJump = !preferNearestForward

        if spokenCompact.count >= 6,
           let exact = findBestForwardEndOffset(
            for: spokenCompact,
            allowFarJump: allowFarJump,
            preferNearest: preferNearestForward
           ) {
            return exact
        }

        return fuzzyForwardEndOffset(
            for: spokenCompact,
            allowFarJump: allowFarJump,
            preferNearest: preferNearestForward
        )
    }

    private func findBestForwardEndOffset(for query: [Character], allowFarJump: Bool, preferNearest: Bool) -> Int? {
        guard !query.isEmpty else { return nil }
        guard query.count <= compactSourceCharacters.count else { return nil }

        let upperBound = compactSourceCharacters.count - query.count
        let localDistanceLimit = max(70, min(220, query.count * 6))
        var bestOffset: Int?
        var bestDistance = Int.max

        if upperBound < 0 { return nil }
        for start in 0...upperBound {
            var matched = true
            for index in 0..<query.count where compactSourceCharacters[start + index] != query[index] {
                matched = false
                break
            }
            guard matched else { continue }

            let endCompactIndex = start + query.count
            guard endCompactIndex > 0, endCompactIndex <= compactSourceToOriginalOffset.count else { continue }
            let endOffset = compactSourceToOriginalOffset[endCompactIndex - 1]

            guard endOffset >= recognizedCharCount else { continue }

            let distance = endOffset - recognizedCharCount
            if !allowFarJump && !preferNearest && distance > localDistanceLimit {
                continue
            }
            if distance < bestDistance {
                bestDistance = distance
                bestOffset = endOffset
                if distance == 0 { break }
            }
        }

        return bestOffset
    }

    private func fuzzyForwardEndOffset(for query: [Character], allowFarJump: Bool, preferNearest: Bool) -> Int? {
        let queryCount = query.count
        guard queryCount >= 4 else { return nil }

        let sourceCount = compactSourceCharacters.count
        let upperBound = sourceCount - queryCount
        guard upperBound >= 0 else { return nil }

        let queryString = String(query)
        let baseThreshold: Double
        switch queryCount {
        case 0...7:
            baseThreshold = 0.45
        case 8...11:
            baseThreshold = 0.52
        default:
            baseThreshold = 0.58
        }
        let threshold = preferNearest ? max(0.32, baseThreshold - 0.12) : baseThreshold

        var candidateStarts: [Int] = []
        if let first = query.first {
            for start in 0...upperBound where compactSourceCharacters[start] == first {
                candidateStarts.append(start)
            }
        }

        if candidateStarts.count > 240, queryCount >= 2 {
            let second = query[1]
            candidateStarts = candidateStarts.filter { start in
                start + 1 < sourceCount && compactSourceCharacters[start + 1] == second
            }
        }

        if candidateStarts.isEmpty {
            let coarseStep = max(1, queryCount / 3)
            candidateStarts = Array(stride(from: 0, through: upperBound, by: coarseStep))
        } else if candidateStarts.count > 320 {
            let strideStep = max(1, candidateStarts.count / 320)
            candidateStarts = candidateStarts.enumerated().compactMap { index, value in
                index % strideStep == 0 ? value : nil
            }
        }

        let queryPrefix = Array(query.prefix(min(3, queryCount)))
        let querySuffix = Array(query.suffix(min(3, queryCount)))
        let strictLocalLimit = max(70, min(220, queryCount * 6))
        let localBiasLimit: Int
        switch queryCount {
        case 0...6:
            localBiasLimit = 220
        case 7...10:
            localBiasLimit = 320
        case 11...14:
            localBiasLimit = 450
        default:
            localBiasLimit = 600
        }
        let softJumpLimit: Int
        switch queryCount {
        case 0...6:
            softJumpLimit = 420
        case 7...10:
            softJumpLimit = 700
        case 11...14:
            softJumpLimit = 1000
        default:
            softJumpLimit = Int.max
        }
        let farJumpSimilarityGate = 0.82

        struct FuzzyCandidate {
            let endOffset: Int
            let similarity: Double
            let distance: Int
        }
        var candidates: [FuzzyCandidate] = []
        candidates.reserveCapacity(min(candidateStarts.count, 128))

        for start in candidateStarts {
            let end = start + queryCount
            guard end <= sourceCount else { continue }

            let window = Array(compactSourceCharacters[start..<end])
            let windowPrefix = Array(window.prefix(queryPrefix.count))
            let windowSuffix = Array(window.suffix(querySuffix.count))
            let prefixMatchCount = zip(queryPrefix, windowPrefix).filter { $0 == $1 }.count
            let suffixMatchCount = zip(querySuffix, windowSuffix).filter { $0 == $1 }.count

            if queryCount >= 8 && prefixMatchCount == 0 && suffixMatchCount == 0 {
                continue
            }

            let distance = editDistance(queryString, String(window))
            let similarity = 1.0 - (Double(distance) / Double(queryCount))
            guard similarity >= threshold else { continue }

            let endOffset = compactSourceToOriginalOffset[end - 1]
            guard endOffset >= recognizedCharCount else { continue }

            let forwardDistance = endOffset - recognizedCharCount
            if !allowFarJump && !preferNearest && forwardDistance > strictLocalLimit {
                continue
            }
            if forwardDistance > softJumpLimit && similarity < farJumpSimilarityGate {
                continue
            }

            candidates.append(FuzzyCandidate(
                endOffset: endOffset,
                similarity: similarity,
                distance: forwardDistance
            ))
        }

        guard !candidates.isEmpty else { return nil }

        if preferNearest {
            let nearest = candidates.sorted { lhs, rhs in
                if lhs.distance != rhs.distance {
                    return lhs.distance < rhs.distance
                }
                if abs(lhs.similarity - rhs.similarity) > 0.0001 {
                    return lhs.similarity > rhs.similarity
                }
                return lhs.endOffset < rhs.endOffset
            }
            return nearest.first?.endOffset
        }

        let bestSimilarity = candidates.map(\.similarity).max() ?? threshold

        let localSimilarityFloor = max(threshold + 0.08, bestSimilarity - 0.10)
        let nearLimit = allowFarJump ? localBiasLimit : strictLocalLimit
        let nearCandidates = candidates.filter { candidate in
            candidate.distance <= nearLimit && candidate.similarity >= localSimilarityFloor
        }
        if !nearCandidates.isEmpty {
            let nearSorted = nearCandidates.sorted { lhs, rhs in
                if lhs.distance != rhs.distance {
                    return lhs.distance < rhs.distance
                }
                if abs(lhs.similarity - rhs.similarity) > 0.0001 {
                    return lhs.similarity > rhs.similarity
                }
                return lhs.endOffset < rhs.endOffset
            }
            return nearSorted.first?.endOffset
        }
        if !allowFarJump {
            return nil
        }

        let similaritySlack: Double
        switch queryCount {
        case 0...7:
            similaritySlack = 0.02
        case 8...11:
            similaritySlack = 0.05
        default:
            similaritySlack = 0.08
        }
        let keptSimilarity = max(threshold, bestSimilarity - similaritySlack)
        let filtered = candidates.filter { $0.similarity >= keptSimilarity }
        let sorted = filtered.sorted { lhs, rhs in
            if lhs.distance != rhs.distance {
                return lhs.distance < rhs.distance
            }
            if abs(lhs.similarity - rhs.similarity) > 0.0001 {
                return lhs.similarity > rhs.similarity
            }
            return lhs.endOffset < rhs.endOffset
        }

        return sorted.first?.endOffset
    }

    private func compactIndex(forOriginalOffset offset: Int) -> Int {
        guard !compactSourceToOriginalOffset.isEmpty else { return 0 }
        if offset <= 0 { return 0 }
        if offset > compactSourceToOriginalOffset.last! {
            return compactSourceToOriginalOffset.count
        }

        var low = 0
        var high = compactSourceToOriginalOffset.count - 1
        var answer = compactSourceToOriginalOffset.count

        while low <= high {
            let mid = (low + high) / 2
            if compactSourceToOriginalOffset[mid] >= offset {
                answer = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return answer
    }

    private func hasForwardDuplicateSeedOccurrence(of query: [Character], fromOriginalOffset offset: Int) -> Bool {
        let seedLength = min(max(4, query.count / 2), 6)
        guard query.count >= seedLength else { return false }
        guard seedLength <= compactSourceCharacters.count else { return false }

        let seed = Array(query.prefix(seedLength))
        let startCompact = max(0, compactIndex(forOriginalOffset: offset) - 1)
        let upperBound = compactSourceCharacters.count - seedLength
        guard startCompact <= upperBound else { return false }

        var matchCount = 0
        for start in startCompact...upperBound {
            var matched = true
            for index in 0..<seedLength where compactSourceCharacters[start + index] != seed[index] {
                matched = false
                break
            }
            guard matched else { continue }

            let endOffset = compactSourceToOriginalOffset[start + seedLength - 1]
            guard endOffset >= offset else { continue }

            matchCount += 1
            if matchCount >= 2 {
                return true
            }
        }
        return false
    }

    private func hasPriorExactOccurrence(of query: [Character], beforeOriginalOffset offset: Int) -> Bool {
        let queryCount = query.count
        guard queryCount >= 4 else { return false }
        guard queryCount <= compactSourceCharacters.count else { return false }

        let limitCompact = compactIndex(forOriginalOffset: offset)
        guard limitCompact >= queryCount else { return false }

        let lastStart = limitCompact - queryCount
        if lastStart < 0 { return false }

        for start in 0...lastStart {
            var matched = true
            for index in 0..<queryCount where compactSourceCharacters[start + index] != query[index] {
                matched = false
                break
            }
            if matched {
                return true
            }
        }
        return false
    }

    private func hasPriorSeedOccurrence(of query: [Character], beforeOriginalOffset offset: Int) -> Bool {
        let seedLength = min(max(4, query.count / 2), 6)
        guard query.count >= seedLength else { return false }
        let seed = Array(query.prefix(seedLength))
        return hasPriorExactOccurrence(of: seed, beforeOriginalOffset: offset)
    }

    private func charLevelMatch(spoken: String) -> Int {
        let remainingSource = String(sourceText.dropFirst(matchStartOffset))
        let src = Array(remainingSource.lowercased().unicodeScalars).map { Character($0) }
        let spk = Array(Self.normalize(spoken).unicodeScalars).map { Character($0) }

        var si = 0
        var ri = 0
        var lastGoodOrigIndex = 0

        while si < src.count && ri < spk.count {
            let sc = src[si]
            let rc = spk[ri]

            if !sc.isLetter && !sc.isNumber {
                si += 1
                continue
            }
            if !rc.isLetter && !rc.isNumber {
                ri += 1
                continue
            }

            if sc == rc {
                si += 1
                ri += 1
                lastGoodOrigIndex = si
            } else {
                var found = false

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

                si += 1
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

        var si = 0
        var ri = 0
        var matchedCharCount = 0

        while si < sourceWords.count && ri < spokenWords.count {
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
                matchedCharCount += sourceWords[si].count
                si += 1
                ri += 1
                if si < sourceWords.count {
                    matchedCharCount += 1
                }
            } else {
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

                var foundSrc = false
                let maxSrcSkip = min(3, sourceWords.count - si - 1)
                for skip in 1...max(1, maxSrcSkip) where skip <= maxSrcSkip {
                    let nextSrc = sourceWords[si + skip].lowercased().filter { $0.isLetter || $0.isNumber }
                    if nextSrc == spkWord || isFuzzyMatch(nextSrc, spkWord) {
                        for s in 0..<skip {
                            matchedCharCount += sourceWords[si + s].count + 1
                        }
                        si += skip
                        foundSrc = true
                        break
                    }
                }
                if foundSrc { continue }

                if srcWord.isEmpty {
                    matchedCharCount += sourceWords[si].count
                    if si < sourceWords.count - 1 { matchedCharCount += 1 }
                    si += 1
                    continue
                }
                ri += 1
            }
        }

        while si < sourceWords.count && Self.isAnnotationWord(sourceWords[si]) {
            matchedCharCount += sourceWords[si].count
            if si < sourceWords.count - 1 { matchedCharCount += 1 }
            si += 1
        }

        return matchedCharCount
    }

    private func isFuzzyMatch(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        if a.hasPrefix(b) || b.hasPrefix(a) { return true }
        if a.contains(b) || b.contains(a) { return true }

        let shorter = min(a.count, b.count)
        if shorter <= 2 && Self.hasCJKCharacters(a) { return false }
        if shorter <= 2 && Self.hasCJKCharacters(b) { return false }

        let shared = zip(a, b).prefix(while: { $0 == $1 }).count
        if shorter >= 2 && shared >= max(2, shorter * 3 / 5) { return true }
        let dist = editDistance(a, b)
        if shorter <= 4 { return dist <= 1 }
        if shorter <= 8 { return dist <= 2 }
        return dist <= max(a.count, b.count) / 3
    }

    private static func cjkContextWords(from splitText: String) -> [String] {
        let parts = splitText.split(separator: " ").map(String.init)
        var words: [String] = []
        var buffer = ""
        for part in parts {
            let cleaned = part.lowercased().filter { $0.isLetter || $0.isNumber }
            if cleaned.count == 1, Self.hasCJKCharacters(cleaned) {
                buffer += cleaned
            } else {
                if !buffer.isEmpty {
                    words.append(buffer)
                    buffer = ""
                }
                if !cleaned.isEmpty {
                    words.append(cleaned)
                }
            }
        }
        if !buffer.isEmpty {
            words.append(buffer)
        }
        return words
    }

    private static func hasCJKCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (v >= 0x4E00 && v <= 0x9FFF)
                || (v >= 0x3400 && v <= 0x4DBF)
                || (v >= 0x20000 && v <= 0x2A6DF)
                || (v >= 0xF900 && v <= 0xFAFF)
        }
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

    private static func sanitizeLocalTranscript(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: "\\[[0-9]+(?:\\.[0-9]+)?-[0-9]+(?:\\.[0-9]+)?\\]",
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "<\\|[^>]+\\|>",
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveSpeechLocaleIdentifier(preferred: String, text: String) -> String {
        let supported = SFSpeechRecognizer.supportedLocales()
        guard !supported.isEmpty else { return preferred }

        if supported.contains(where: { sameLocale($0.identifier, preferred) }) {
            return preferred
        }

        if let code = languageCode(of: preferred),
           let match = supported.first(where: { languageCode(of: $0.identifier) == code }) {
            return match.identifier
        }

        if let code = dominantLanguageHint(from: text),
           let match = supported.first(where: { languageCode(of: $0.identifier) == code }) {
            return match.identifier
        }

        let currentID = Locale.current.identifier
        if supported.contains(where: { sameLocale($0.identifier, currentID) }) {
            return currentID
        }
        if let code = languageCode(of: currentID),
           let match = supported.first(where: { languageCode(of: $0.identifier) == code }) {
            return match.identifier
        }

        if let en = supported.first(where: { languageCode(of: $0.identifier) == "en" }) {
            return en.identifier
        }
        return supported.first?.identifier ?? preferred
    }

    private static func sameLocale(_ a: String, _ b: String) -> Bool {
        let na = canonicalLocaleKey(a)
        let nb = canonicalLocaleKey(b)
        return na == nb
    }

    private static func canonicalLocaleKey(_ id: String) -> String {
        id.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    private static func languageCode(of localeID: String) -> String? {
        let components = NSLocale.components(fromLocaleIdentifier: localeID)
        return components[NSLocale.Key.languageCode.rawValue]?.lowercased()
    }

    private static func dominantLanguageHint(from text: String) -> String? {
        var zh = 0
        var ja = 0
        var ko = 0

        for scalar in text.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF:
                zh += 1
            case 0x3040...0x309F, 0x30A0...0x30FF:
                ja += 1
            case 0xAC00...0xD7AF:
                ko += 1
            default:
                break
            }
        }

        if zh == 0 && ja == 0 && ko == 0 {
            return nil
        }
        if zh >= ja && zh >= ko { return "zh" }
        if ja >= zh && ja >= ko { return "ja" }
        return "ko"
    }
}

private final class LocalSenseVoiceRunner {
    struct Config {
        let executablePath: String
        let modelPath: String
        let language: String
        let disableGPU: Bool
        let dyldLibraryPaths: [String]
    }

    var lastError: String?

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var outputBuffer = ""
    private var stderrBuffer = ""
    private var intentionallyStopped = false
    private var lastEmittedTranscript = ""

    private var onTranscript: ((String) -> Void)?
    private var onError: ((String) -> Void)?
    private var onExit: ((Int32) -> Void)?

    private let parserQueue = DispatchQueue(label: "auto-cue.LocalSenseVoiceRunner")

    func start(
        config: Config,
        onTranscript: @escaping (String) -> Void,
        onError: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) -> Bool {
        stop()
        lastError = nil
        intentionallyStopped = false
        outputBuffer = ""
        stderrBuffer = ""
        lastEmittedTranscript = ""
        self.onTranscript = onTranscript
        self.onError = onError
        self.onExit = onExit

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.executablePath)

        var args = [
            "-m", config.modelPath,
            "-l", config.language,
            "--use-vad",
            "--chunk-size", "80",
            "-mmc", "8",
            "-mnc", "120",
            "--speech-prob-threshold", "0.2",
        ]
        if config.disableGPU {
            args.append("-ng")
        }
        process.arguments = args

        var environment = ProcessInfo.processInfo.environment
        let existingDYLD = (environment["DYLD_LIBRARY_PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var mergedDYLD: [String] = []
        for path in config.dyldLibraryPaths + existingDYLD where !path.isEmpty {
            if !mergedDYLD.contains(path) {
                mergedDYLD.append(path)
            }
        }
        if !mergedDYLD.isEmpty {
            environment["DYLD_LIBRARY_PATH"] = mergedDYLD.joined(separator: ":")
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.parserQueue.async {
                self?.consumeOutputData(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.parserQueue.async {
                self?.consumeErrorData(data)
            }
        }

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.parserQueue.async {
                self.clearReadHandlers()
                let status = process.terminationStatus
                let shouldNotify = !self.intentionallyStopped
                self.process = nil
                if shouldNotify {
                    self.onExit?(status)
                }
            }
        }

        do {
            try process.run()
            self.process = process
            return true
        } catch {
            clearReadHandlers()
            self.process = nil
            self.lastError = "无法启动本地识别程序：\(error.localizedDescription)"
            return false
        }
    }

    func stop() {
        intentionallyStopped = true
        clearReadHandlers()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    private func clearReadHandlers() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func consumeOutputData(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        outputBuffer.append(stripANSIEscapeCodes(from: chunk))
        drainBuffer(&outputBuffer, handleLine: parseOutputLine)
    }

    private func consumeErrorData(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        stderrBuffer.append(stripANSIEscapeCodes(from: chunk))
        drainBuffer(&stderrBuffer) { [weak self] line in
            guard let self else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.onError?(trimmed)
        }
    }

    private func drainBuffer(_ buffer: inout String, handleLine: (String) -> Void) {
        while let index = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<index])
            handleLine(line)
            var next = buffer.index(after: index)
            while next < buffer.endIndex, buffer[next] == "\n" || buffer[next] == "\r" {
                next = buffer.index(after: next)
            }
            buffer.removeSubrange(buffer.startIndex..<next)
        }
    }

    private func parseOutputLine(_ rawLine: String) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let timestampPattern = "\\[[0-9]+(?:\\.[0-9]+)?-[0-9]+(?:\\.[0-9]+)?\\]"
        let hasTimestamp = trimmed.range(of: timestampPattern, options: .regularExpression) != nil
        let hasSenseVoiceTag = trimmed.contains("<|")

        guard hasTimestamp || hasSenseVoiceTag else {
            return
        }

        var text = trimmed
        if hasTimestamp {
            text = text.replacingOccurrences(of: timestampPattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<\\|[^>]+\\|>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return }
        guard text != lastEmittedTranscript else { return }
        lastEmittedTranscript = text
        onTranscript?(text)
    }

    private func stripANSIEscapeCodes(from text: String) -> String {
        text.replacingOccurrences(of: "\\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
