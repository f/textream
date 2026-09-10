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

    /// Latest transcript. Called on the main queue. `isNewWindow` is true when
    /// the rolling window restarted (Whisper path), meaning the consumer must
    /// re-anchor its text matching at the current progress before consuming it.
    var onText: ((_ text: String, _ isNewWindow: Bool) -> Void)?
    /// Terminal failure; the engine has stopped. Called on the main queue.
    var onError: ((String) -> Void)?
    /// The session ended cleanly after `stop()`. Called on the main queue.
    var onFinished: (() -> Void)?

    private let queue = DispatchQueue(label: "dev.fka.textream.local-speech-engine", qos: .userInitiated)
    private let bufferLock = NSLock()
    private var pendingAudio: [Float] = []
    private var stopRequested = false
    private var sessionActive = false
    /// Bumped by both `start` and `stop`; a running worker loop exits as soon
    /// as it sees a generation it doesn't own, so a stop→start pair can never
    /// strand the queue behind a stale loop.
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
    private var windowAudio: [Float] = []
    private var lastWindowTranscript = ""
    private var samplesSinceRun = 0
    private var windowNeedsReanchor = false

    private static let runIntervalSamples = 16_000 * 3 / 2
    private static let windowLimitSamples = 16_000 * 26
    private static let windowOverlapSamples = 16_000

    private init() {}

    var isSessionActive: Bool {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return sessionActive
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
    func start(language: String?, initialPrompt: String?) {
        bufferLock.lock()
        generation += 1
        let sessionGeneration = generation
        pendingAudio.removeAll(keepingCapacity: true)
        stopRequested = false
        sessionActive = true
        bufferLock.unlock()
        while wake.wait(timeout: .now()) == .success {}

        queue.async { [self] in
            bufferLock.lock()
            let isCurrent = generation == sessionGeneration
            bufferLock.unlock()
            guard isCurrent else { return }
            workerGeneration = sessionGeneration

            guard let session, let info else {
                fail("No local model is loaded.")
                return
            }
            stream = nil
            windowAudio.removeAll(keepingCapacity: true)
            lastWindowTranscript = ""
            samplesSinceRun = 0
            windowNeedsReanchor = false
            self.language = language
            self.initialPrompt = initialPrompt

            if info.supportsStreaming {
                do {
                    stream = try session.stream(RunOptions(language: language), StreamOptions())
                } catch {
                    fail("Could not start streaming: \(error.localizedDescription)")
                    return
                }
            }
            active = true
            consumeLoop(sessionGeneration: sessionGeneration)
        }
    }

    /// Queue 16 kHz mono float32 samples. Safe to call from the audio tap.
    func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        bufferLock.lock()
        pendingAudio.append(contentsOf: samples)
        bufferLock.unlock()
        wake.signal()
    }

    /// Ends the session. Final text (if any) is delivered before `onFinished`.
    func stop() {
        bufferLock.lock()
        generation += 1
        stopRequested = true
        sessionActive = false
        bufferLock.unlock()
        wake.signal()
    }

    // MARK: - Worker loop

    private func consumeLoop(sessionGeneration: Int) {
        while true {
            wake.wait()
            bufferLock.lock()
            let chunk = pendingAudio
            pendingAudio.removeAll(keepingCapacity: true)
            let shouldStop = stopRequested || generation != sessionGeneration
            bufferLock.unlock()

            if !chunk.isEmpty {
                if let stream {
                    feedStream(stream, chunk)
                } else {
                    feedWindow(chunk)
                }
            }

            if shouldStop || !active {
                finish()
                return
            }
        }
    }

    private func feedStream(_ stream: TranscribeCpp.Stream, _ chunk: [Float]) {
        do {
            let update = try stream.feed(chunk)
            if update.committedChanged || update.tentativeChanged {
                emit(stream.text.display, isNewWindow: false)
            }
        } catch {
            fail("Local model streaming failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Rolling-window (Whisper) path

    private func feedWindow(_ chunk: [Float]) {
        windowAudio.append(contentsOf: chunk)
        samplesSinceRun += chunk.count

        if windowAudio.count >= Self.windowLimitSamples {
            runWindow(final: true)
            let overlap = windowAudio.suffix(Self.windowOverlapSamples)
            windowAudio = Array(overlap)
            lastWindowTranscript = ""
            samplesSinceRun = 0
            windowNeedsReanchor = true
            return
        }

        guard samplesSinceRun >= Self.runIntervalSamples, windowAudio.count >= 8_000 else { return }
        samplesSinceRun = 0
        runWindow(final: false)
    }

    private func runWindow(final: Bool) {
        guard let session, !windowAudio.isEmpty else { return }

        var options = RunOptions(language: language)
        // Whisper accepts an initial prompt; attaching the extension to any
        // other architecture is rejected by the engine, so gate on arch.
        if let initialPrompt, !initialPrompt.isEmpty, info?.arch == "whisper" {
            options.family = .whisper(WhisperRunOptions(initialPrompt: initialPrompt))
        }

        do {
            let transcript = try session.run(windowAudio, options: options)
            let text = transcript.text
            let isNewWindow = windowNeedsReanchor
            windowNeedsReanchor = false
            if text != lastWindowTranscript || final {
                lastWindowTranscript = text
                emit(text, isNewWindow: isNewWindow)
            }
        } catch {
            if final {
                fail("Local model transcription failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Completion

    private func finish() {
        if let stream {
            do {
                _ = try stream.finalize()
                emit(stream.text.full, isNewWindow: false)
            } catch {
                // Keep the last live hypothesis; finalize failures are rare.
            }
            self.stream = nil
        } else if !windowAudio.isEmpty, samplesSinceRun > 0 {
            runWindow(final: true)
        }
        active = false
        bufferLock.lock()
        // A stale loop finishing must not clear the flag for a newer session.
        if workerGeneration == generation { sessionActive = false }
        bufferLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onFinished?() }
    }

    private func fail(_ message: String) {
        active = false
        bufferLock.lock()
        if workerGeneration == generation { sessionActive = false }
        bufferLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    private func emit(_ text: String, isNewWindow: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onText?(text, isNewWindow) }
    }
}
