//
//  LocalSpeechEngine.swift
//  Textream
//
//  Runs custom Whisper-family GGML/GGUF models entirely on-device through
//  transcribe.cpp (the engine Handy uses). Two transcription paths:
//
//  * Streaming models (Parakeet, Nemotron, Moonshine Streaming, …) use the
//    engine's native low-latency stream API.
//  * Batch-only models (Whisper and friends) are re-transcribed on a rolling
//    window (~1.5 s cadence) so Word Tracking still gets live partial text,
//    with the window capped at ~26 s and a small audio overlap when it rolls.
//
//  All native state lives on a private serial queue; audio is handed over
//  through a lock-protected buffer so the realtime tap never blocks.
//

import Foundation
import TranscribeCpp

struct LocalSpeechEngineInfo: Equatable {
    var arch: String
    var variant: String
    var backend: String
    var supportsStreaming: Bool
    var supportsLanguageDetection: Bool
    var languages: [String]

    var usesRollingWindow: Bool { !supportsStreaming }
}

nonisolated final class LocalSpeechEngine: @unchecked Sendable {
    /// One engine per app process: the loaded model stays resident so session
    /// restarts (mic switches, jumps) don't pay the load cost again.
    static let shared = LocalSpeechEngine()

    private struct SessionCallbacks {
        var onText: (
            _ text: String,
            _ stablePrefix: String,
            _ windowOverlapPrefix: String?,
            _ isNewWindow: Bool,
            _ sessionID: Int
        ) -> Void
        var onError: (_ message: String, _ sessionID: Int) -> Void
        var onFinished: (_ sessionID: Int) -> Void
    }

    /// Mutable session storage. Every property is accessed under `bufferLock`;
    /// reference semantics avoid copying the growing audio array on each tap.
    private final class SessionState: @unchecked Sendable {
        let callbacks: SessionCallbacks
        var pendingAudio: [Float] = []
        var stopRequested = false
        var isCancelled = false
        var terminalCallbackScheduled = false

        init(callbacks: SessionCallbacks) {
            self.callbacks = callbacks
        }
    }

    private let queue = DispatchQueue(label: "dev.fka.textream.local-speech-engine", qos: .userInitiated)
    private let bufferLock = NSLock()
    /// Protected by `bufferLock`; audio, stop state, and callbacks stay with
    /// their owning session even when another session is queued behind it.
    private var sessionsByID: [Int: SessionState] = [:]
    private var activeSessionID: Int?
    private var generation = 0
    private let wake = DispatchSemaphore(value: 0)

    // Worker-owned state — only touched on `queue`.
    private var model: Model?
    private var session: Session?
    private var stream: TranscribeCpp.Stream?
    private var loadedPath: String?
    private var info: LocalSpeechEngineInfo?
    private var active = false
    private var workerGeneration = 0
    private var language: String?
    private var initialPrompt: String?
    private var requestWordTimestamps = false
    private var windowAudio: [Float] = []
    private var lastWindowTranscript = ""
    private var samplesSinceRun = 0
    private var windowNeedsFinalRetry = false
    private var windowNeedsReanchor = false
    private var windowHasAudioOverlap = false

    private static let runIntervalSamples = 16_000 * 3 / 2
    private static let windowLimitSamples = 16_000 * 26
    private static let windowOverlapSamples = 16_000

    private init() {}

    var isSessionActive: Bool {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return activeSessionID != nil
    }

    // MARK: - Model lifecycle

    /// Loads (or reuses) a model and reports its capabilities on the main queue.
    func loadModel(at path: String, completion: @escaping (Result<LocalSpeechEngineInfo, Error>) -> Void) {
        if isSessionActive { stop() }
        queue.async { [self] in
            if loadedPath == path, let info {
                DispatchQueue.main.async { completion(.success(info)) }
                return
            }
            do {
                let model = try Model(path: path)
                let session = try model.session()
                let capabilities = model.capabilities
                let info = LocalSpeechEngineInfo(
                    arch: model.arch,
                    variant: model.variant,
                    backend: model.backend,
                    supportsStreaming: capabilities.supportsStreaming,
                    supportsLanguageDetection: capabilities.supportsLanguageDetect,
                    languages: capabilities.languages
                )
                self.model = model
                self.session = session
                self.loadedPath = path
                self.info = info
                DispatchQueue.main.async { completion(.success(info)) }
            } catch {
                self.model = nil
                self.session = nil
                self.loadedPath = nil
                self.info = nil
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func unloadModel() {
        if isSessionActive { stop() }
        queue.async { [self] in
            stream = nil
            session = nil
            model = nil
            loadedPath = nil
            info = nil
        }
    }

    /// Releases the model synchronously. Call at app termination: the native
    /// Metal backend asserts if its device is torn down during static
    /// destruction while a model is still alive (upstream ggml constraint).
    func unloadModelSynchronously() {
        if isSessionActive { stop() }
        queue.sync { [self] in
            stream = nil
            session = nil
            model = nil
            loadedPath = nil
            info = nil
        }
    }

    // MARK: - Session control

    /// Begins a new transcription session. `language` is a short ISO code
    /// (`en`, `tr`, …) or nil for auto-detection; `initialPrompt` (Whisper only)
    /// biases the decoder towards upcoming script words.
    @discardableResult
    func start(
        language: String?,
        initialPrompt: String?,
        wordTimestamps: Bool,
        onText: @escaping (
            _ text: String,
            _ stablePrefix: String,
            _ windowOverlapPrefix: String?,
            _ isNewWindow: Bool,
            _ sessionID: Int
        ) -> Void,
        onError: @escaping (_ message: String, _ sessionID: Int) -> Void,
        onFinished: @escaping (_ sessionID: Int) -> Void
    ) -> Int {
        bufferLock.lock()
        let replacedSessionID = activeSessionID
        if let replacedSessionID, let replacedState = sessionsByID[replacedSessionID] {
            replacedState.stopRequested = true
        }
        generation += 1
        let sessionGeneration = generation
        sessionsByID[sessionGeneration] = SessionState(
            callbacks: SessionCallbacks(
                onText: onText,
                onError: onError,
                onFinished: onFinished
            )
        )
        activeSessionID = sessionGeneration
        bufferLock.unlock()
        if replacedSessionID != nil {
            wake.signal()
        }

        queue.async { [self] in
            bufferLock.lock()
            let sessionExists = sessionsByID[sessionGeneration] != nil
            bufferLock.unlock()
            // A hard-cancelled queued session has no work or callbacks left.
            guard sessionExists else { return }
            workerGeneration = sessionGeneration

            guard let session, let info else {
                fail("No local model is loaded.")
                return
            }
            stream = nil
            windowAudio.removeAll(keepingCapacity: true)
            lastWindowTranscript = ""
            samplesSinceRun = 0
            windowNeedsFinalRetry = false
            windowNeedsReanchor = false
            self.language = language
            self.initialPrompt = initialPrompt
            requestWordTimestamps = wordTimestamps
            windowHasAudioOverlap = false

            if info.supportsStreaming {
                do {
                    stream = try session.stream(
                        RunOptions(task: .transcribe, language: language),
                        StreamOptions()
                    )
                } catch {
                    fail("Could not start streaming: \(error.localizedDescription)")
                    return
                }
            }
            active = true
            consumeLoop(sessionGeneration: sessionGeneration)
        }
        return sessionGeneration
    }

    /// Queue 16 kHz mono float32 samples. Safe to call from the audio tap.
    func feed(_ samples: [Float], sessionID: Int) {
        guard !samples.isEmpty else { return }
        bufferLock.lock()
        guard activeSessionID == sessionID,
              let state = sessionsByID[sessionID],
              !state.stopRequested else {
            bufferLock.unlock()
            return
        }
        state.pendingAudio.append(contentsOf: samples)
        bufferLock.unlock()
        wake.signal()
    }

    /// Ends the session. Final text (if any) is delivered before `onFinished`.
    func stop(sessionID: Int) {
        bufferLock.lock()
        guard let state = sessionsByID[sessionID] else {
            bufferLock.unlock()
            return
        }
        state.stopRequested = true
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
        bufferLock.unlock()
        wake.signal()
    }

    /// Cancels one session without delivering additional callbacks.
    func cancel(sessionID: Int) {
        bufferLock.lock()
        if let state = sessionsByID.removeValue(forKey: sessionID) {
            state.isCancelled = true
        }
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
        bufferLock.unlock()
        wake.signal()
    }

    /// Cancels every session. Used only while replacing or unloading a model.
    private func stop() {
        bufferLock.lock()
        for state in sessionsByID.values {
            state.isCancelled = true
        }
        sessionsByID.removeAll()
        activeSessionID = nil
        bufferLock.unlock()
        wake.signal()
    }

    // MARK: - Worker loop

    private func consumeLoop(sessionGeneration: Int) {
        while true {
            wake.wait()
            bufferLock.lock()
            guard let state = sessionsByID[sessionGeneration] else {
                bufferLock.unlock()
                abortWorkerSession()
                return
            }
            let chunk = state.pendingAudio
            state.pendingAudio.removeAll(keepingCapacity: true)
            let shouldStop = state.stopRequested
            bufferLock.unlock()

            if !chunk.isEmpty {
                if let stream {
                    if let error = feedStream(stream, chunk) {
                        finish(error: error)
                        return
                    }
                } else {
                    feedWindow(chunk)
                }
            }

            if !active {
                return
            }
            if shouldStop {
                finish()
                return
            }
        }
    }

    /// Drops worker-owned state for a hard-cancelled session. Unlike `finish`,
    /// this deliberately does not run a final inference or deliver callbacks.
    private func abortWorkerSession() {
        active = false
        stream = nil
        windowAudio.removeAll(keepingCapacity: true)
        lastWindowTranscript = ""
        samplesSinceRun = 0
        windowNeedsFinalRetry = false
        windowNeedsReanchor = false
        windowHasAudioOverlap = false
    }

    private func feedStream(
        _ stream: TranscribeCpp.Stream,
        _ chunk: [Float]
    ) -> String? {
        do {
            let update = try stream.feed(chunk)
            if update.committedChanged || update.tentativeChanged {
                let text = stream.text
                emit(
                    text.display,
                    stablePrefix: text.committed,
                    windowOverlapPrefix: nil,
                    isNewWindow: false
                )
            }
            return nil
        } catch {
            return "Local model streaming failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Rolling-window (Whisper) path

    private func feedWindow(_ chunk: [Float]) {
        windowAudio.append(contentsOf: chunk)
        samplesSinceRun += chunk.count

        if windowAudio.count >= Self.windowLimitSamples {
            if let error = runWindow(final: true) {
                finish(error: error)
                return
            }
            windowNeedsFinalRetry = false
            let overlap = windowAudio.suffix(Self.windowOverlapSamples)
            windowAudio = Array(overlap)
            lastWindowTranscript = ""
            samplesSinceRun = 0
            windowNeedsReanchor = true
            windowHasAudioOverlap = true
            return
        }

        guard samplesSinceRun >= Self.runIntervalSamples, windowAudio.count >= 8_000 else { return }
        samplesSinceRun = 0
        // Retry a failed live inference on the normal cadence, but remember it
        // for Stop so the final audio is never silently treated as processed.
        windowNeedsFinalRetry = runWindow(final: false) != nil
    }

    /// Returns a user-facing error on failure. Live partial failures are
    /// retried; final failures become terminal through `finish(error:)`.
    private func runWindow(final: Bool) -> String? {
        guard let session, !windowAudio.isEmpty else { return nil }

        var options = RunOptions(
            task: .transcribe,
            timestamps: requestWordTimestamps ? .word : .auto,
            language: language
        )
        // Whisper accepts an initial prompt; attaching the extension to any
        // other architecture is rejected by the engine, so gate on arch.
        if let initialPrompt, !initialPrompt.isEmpty, info?.arch == "whisper" {
            options.family = .whisper(WhisperRunOptions(initialPrompt: initialPrompt))
        }

        do {
            let transcript = try session.run(windowAudio, options: options)
            let text = transcript.text
            if text != lastWindowTranscript || final {
                let isNewWindow = windowNeedsReanchor
                windowNeedsReanchor = false
                lastWindowTranscript = text
                emit(
                    text,
                    stablePrefix: stablePrefix(in: transcript, final: final),
                    windowOverlapPrefix: windowHasAudioOverlap
                        ? leadingOverlapPrefix(in: transcript)
                        : nil,
                    isNewWindow: isNewWindow
                )
            }
            return nil
        } catch {
            return "Local model transcription failed: \(error.localizedDescription)"
        }
    }

    /// Text before the newest audio is safe to append permanently in the UI.
    /// Batch models expose timestamped segments rather than native streaming
    /// commit state, so keep roughly the newest inference interval tentative.
    private func stablePrefix(in transcript: Transcript, final: Bool) -> String {
        if final { return transcript.text }

        let audioEndMs = Int64(windowAudio.count) * 1_000 / 16_000
        let stableCutoffMs = audioEndMs - 1_500
        guard stableCutoffMs > 0 else { return "" }

        var stableEnd = transcript.text.startIndex
        var searchStart = transcript.text.startIndex
        for segment in transcript.segments {
            guard segment.t1Ms > 0, segment.t1Ms <= stableCutoffMs else { break }
            guard let range = transcript.text.range(
                of: segment.text,
                range: searchStart..<transcript.text.endIndex
            ) else { continue }
            stableEnd = range.upperBound
            searchStart = range.upperBound
        }
        return String(transcript.text[..<stableEnd])
    }

    /// Exact text decoded from the first second of the current window. Once a
    /// rolling window has restarted, that first second is carried audio rather
    /// than newly spoken content, so the UI can remove it without guessing.
    private func leadingOverlapPrefix(in transcript: Transcript) -> String? {
        // A backend may return coarser timestamps than requested. In that
        // case nil tells the UI it must use its conservative text fallback;
        // an empty string with word metadata means there truly was no decoded
        // text in the carried second.
        switch transcript.timestampKind {
        case .word, .token:
            break
        case .none, .auto, .segment:
            return nil
        }
        guard !transcript.words.isEmpty else { return "" }
        let overlapWords = transcript.words
            .filter { $0.t1Ms > 0 && $0.t1Ms <= 1_000 }
            .map(\.text)
        guard !overlapWords.isEmpty else { return "" }

        let raw = overlapWords.joined()
        if transcript.text.hasPrefix(raw) { return raw }

        let spaced = overlapWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if transcript.text.hasPrefix(spaced) { return spaced }

        // Last fallback: preserve an exact prefix from the displayed text,
        // using Foundation's language-aware word boundaries.
        var wordRanges: [Range<String.Index>] = []
        transcript.text.enumerateSubstrings(
            in: transcript.text.startIndex..<transcript.text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, _ in
            wordRanges.append(range)
        }
        guard wordRanges.count >= overlapWords.count else { return raw }
        let end = wordRanges[overlapWords.count - 1].upperBound
        return String(transcript.text[..<end])
    }

    // MARK: - Completion

    private func finish(error initialError: String? = nil) {
        var terminalError = initialError
        if let stream {
            if terminalError != nil {
                _ = stream.reset()
            } else {
                do {
                    _ = try stream.finalize()
                    let text = stream.text.full
                    emit(
                        text,
                        stablePrefix: text,
                        windowOverlapPrefix: nil,
                        isNewWindow: false
                    )
                } catch {
                    terminalError = "Could not finish local transcription: \(error.localizedDescription)"
                }
            }
            self.stream = nil
        } else if terminalError == nil,
                  !windowAudio.isEmpty,
                  (samplesSinceRun > 0 || windowNeedsFinalRetry) {
            terminalError = runWindow(final: true)
        }
        active = false
        finishCallbacks(for: workerGeneration, error: terminalError)
    }

    private func fail(_ message: String) {
        finish(error: message)
    }

    private func emit(
        _ text: String,
        stablePrefix: String,
        windowOverlapPrefix: String?,
        isNewWindow: Bool
    ) {
        let emittingSessionID = workerGeneration
        bufferLock.lock()
        let state = sessionsByID[emittingSessionID]
        let callback = state?.callbacks.onText
        bufferLock.unlock()
        guard let state, let callback else { return }
        DispatchQueue.main.async { [weak self, state] in
            guard let self else { return }
            self.bufferLock.lock()
            let isCancelled = state.isCancelled
            self.bufferLock.unlock()
            guard !isCancelled else { return }
            callback(
                text,
                stablePrefix,
                windowOverlapPrefix,
                isNewWindow,
                emittingSessionID
            )
        }
    }

    private func finishCallbacks(for sessionID: Int, error: String? = nil) {
        bufferLock.lock()
        guard let state = sessionsByID[sessionID],
              !state.terminalCallbackScheduled else {
            bufferLock.unlock()
            return
        }
        state.terminalCallbackScheduled = true
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
        bufferLock.unlock()
        let callbacks = state.callbacks

        DispatchQueue.main.async { [weak self, state] in
            guard let self else { return }
            self.bufferLock.lock()
            let isCancelled = state.isCancelled
            if self.sessionsByID[sessionID] === state {
                self.sessionsByID.removeValue(forKey: sessionID)
            }
            self.bufferLock.unlock()
            guard !isCancelled else { return }
            if let error {
                callbacks.onError(error, sessionID)
            }
            callbacks.onFinished(sessionID)
        }
    }
}
