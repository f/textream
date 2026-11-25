import CTranscribe
import Foundation

/// A single-threaded transcription context bound to a `Model`. Not `Sendable`:
/// use one `Session` from one thread at a time (it may move between threads if
/// never used concurrently). The strong `model` reference keeps the model alive
/// for the session's lifetime, so freeing happens in a safe order under ARC.
public final class Session {
    // Internal (not private) so `Stream` and the cancellation extension in
    // this module can reach the handle, the model (for its run lock), and the
    // retained cancel token.
    let model: Model
    let ptr: OpaquePointer
    /// Strong ref to the installed cancellation token (the C side holds an
    /// unretained pointer to it via the abort callback userdata).
    var cancelToken: CancellationToken?

    init(model: Model, ptr: OpaquePointer) {
        self.model = model
        self.ptr = ptr
    }

    deinit { transcribe_session_free(ptr) }

    /// Effective per-session limits.
    public var limits: SessionLimits {
        var lim = transcribe_session_limits()
        transcribe_session_limits_init(&lim)
        _ = transcribe_session_get_limits(ptr, &lim)
        return SessionLimits(lim)
    }

    /// Whether the most recent run was aborted by an installed cancellation.
    public var wasAborted: Bool { transcribe_was_aborted(ptr) }
    /// Whether the most recent run stopped at the context cap before EOS.
    public var wasTruncated: Bool { transcribe_was_truncated(ptr) }

    /// Per-call timings from the most recent run.
    public var timings: Timings {
        var t = transcribe_timings(); transcribe_timings_init(&t)
        _ = transcribe_get_timings(ptr, &t)
        return Timings(t)
    }

    /// Pretty-print the current timings to the log sink at INFO (or stderr when
    /// no log handler is installed).
    public func printTimings() { transcribe_print_timings(ptr) }

    // MARK: - Offline run (blocking)

    /// Transcribe one utterance. `pcm` is mono float32 at 16 kHz in [-1, 1].
    public func run(_ pcm: [Float], options: RunOptions = .init()) throws -> Transcript {
        model.runLock.lock()
        defer { model.runLock.unlock() }
        if model.streamActive {
            throw TranscribeError.busy(
                "a stream is active on this model; finish or drop it before run()")
        }
        return try options.withCParams { params in
            let status = pcm.withUnsafeBufferPointer {
                transcribe_run(ptr, $0.baseAddress, Int32($0.count), params)
            }
            return try makeTranscript(status, context: "run")
        }
    }

    /// Transcribe several utterances in one dispatch. Returns one result per
    /// input; a malformed or per-utterance-failed input is a `.failure` in its
    /// slot (whole-batch faults throw).
    public func runBatch(
        _ inputs: [[Float]], options: RunOptions = .init()
    ) throws -> [Result<Transcript, Error>] {
        model.runLock.lock()
        defer { model.runLock.unlock() }
        if model.streamActive {
            throw TranscribeError.busy(
                "a stream is active on this model; finish or drop it before runBatch()")
        }
        return try options.withCParams { params in
            let counts = inputs.map { Int32($0.count) }
            let status = withPCMPointers(inputs[...], []) { pointers in
                pointers.withUnsafeBufferPointer { pp in
                    counts.withUnsafeBufferPointer { cc in
                        transcribe_run_batch(
                            ptr, pp.baseAddress, cc.baseAddress, Int32(inputs.count), params)
                    }
                }
            }
            if status != TRANSCRIBE_OK && status != TRANSCRIBE_ERR_ABORTED {
                throw TranscribeError.make(status, context: "run_batch")
            }
            let n = Int(transcribe_batch_n_results(ptr))
            return (0..<n).map { i in
                let s = transcribe_batch_status(ptr, Int32(i))
                let context = "utterance \(i)"
                switch s {
                case TRANSCRIBE_OK:
                    return .success(batchTranscript(i))
                // Per-utterance abort/truncation preserves a readable partial
                // (C contract) — attach it, mirroring `run` and the Rust/Python
                // batch paths, instead of dropping it on the floor.
                case TRANSCRIBE_ERR_ABORTED:
                    return .failure(TranscribeError.aborted(
                        message: TranscribeError.message(s, context), partial: batchTranscript(i)))
                case TRANSCRIBE_ERR_OUTPUT_TRUNCATED:
                    return .failure(TranscribeError.outputTruncated(
                        message: TranscribeError.message(s, context), partial: batchTranscript(i)))
                default:
                    return .failure(TranscribeError.make(s, context: context))
                }
            }
        }
    }

    // MARK: - Offline run (async convenience)

    /// `run` hopped off the caller's thread/actor onto a background queue, with
    /// Swift task cancellation bridged to the native abort (see
    /// `withTaskCancellationBridge`).
    ///
    /// The `nonisolated(unsafe)` capture is sound: the continuation resumes
    /// exactly once, the work runs serialized under the model lock, and the
    /// caller is suspended on `await` (so the session is not used concurrently)
    /// — exactly the "may move between threads if never used concurrently"
    /// contract this type documents.
    public func run(_ pcm: [Float], options: RunOptions = .init()) async throws -> Transcript {
        nonisolated(unsafe) let this = self
        return try await withTaskCancellationBridge { try this.run(pcm, options: options) }
    }

    /// `runBatch` hopped off the caller's thread/actor onto a background queue,
    /// with Swift task cancellation bridged to the native abort.
    public func runBatch(
        _ inputs: [[Float]], options: RunOptions = .init()
    ) async throws -> [Result<Transcript, Error>] {
        nonisolated(unsafe) let this = self
        return try await withTaskCancellationBridge { try this.runBatch(inputs, options: options) }
    }

    /// Hop a blocking call to a background queue and bridge Swift structured-
    /// concurrency cancellation to the native abort: if the surrounding `Task`
    /// is cancelled, the run aborts and throws `.aborted` (with the partial
    /// transcript preserved), matching the synchronous `CancellationToken` path.
    ///
    /// The bridge installs its own token ONLY when the caller has not installed
    /// one — it never clobbers a caller's `CancellationToken` (there is a single
    /// native abort slot, so a caller-installed token takes precedence and
    /// `Task.cancel()` is then not observed). The bridged token is removed when
    /// the call returns, restoring the session's prior (no-token) state.
    private func withTaskCancellationBridge<T>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let bridged = (cancelToken == nil) ? CancellationToken() : nil
        if let bridged { setCancellationToken(bridged) }
        defer { if bridged != nil { clearCancellationToken() } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                DispatchQueue.global().async {
                    cont.resume(with: Result { try body() })
                }
            }
        } onCancel: {
            bridged?.cancel()
        }
    }

    // MARK: - Result extraction

    private func makeTranscript(_ status: transcribe_status, context: String) throws -> Transcript {
        switch status {
        case TRANSCRIBE_OK:
            return readTranscript()
        case TRANSCRIBE_ERR_ABORTED:
            throw TranscribeError.aborted(
                message: TranscribeError.message(status, context), partial: readTranscript())
        case TRANSCRIBE_ERR_OUTPUT_TRUNCATED:
            throw TranscribeError.outputTruncated(
                message: TranscribeError.message(status, context), partial: readTranscript())
        default:
            throw TranscribeError.make(status, context: context)
        }
    }

    func readTranscript() -> Transcript {
        var segments: [Segment] = []
        for i in 0..<Int(transcribe_n_segments(ptr)) {
            var s = transcribe_segment(); transcribe_segment_init(&s)
            _ = transcribe_get_segment(ptr, Int32(i), &s)
            segments.append(Segment(s))
        }
        var words: [Word] = []
        for i in 0..<Int(transcribe_n_words(ptr)) {
            var w = transcribe_word(); transcribe_word_init(&w)
            _ = transcribe_get_word(ptr, Int32(i), &w)
            words.append(Word(w))
        }
        var tokens: [Token] = []
        for i in 0..<Int(transcribe_n_tokens(ptr)) {
            var t = transcribe_token(); transcribe_token_init(&t)
            _ = transcribe_get_token(ptr, Int32(i), &t)
            tokens.append(Token(t))
        }
        var speakerSegments: [SpeakerSegment] = []
        for i in 0..<Int(transcribe_n_speaker_segments(ptr)) {
            var s = transcribe_speaker_segment(); transcribe_speaker_segment_init(&s)
            _ = transcribe_get_speaker_segment(ptr, Int32(i), &s)
            speakerSegments.append(SpeakerSegment(s))
        }
        var timings = transcribe_timings(); transcribe_timings_init(&timings)
        _ = transcribe_get_timings(ptr, &timings)
        let language = String(cString: transcribe_detected_language(ptr))
        return Transcript(
            text: String(cString: transcribe_full_text(ptr)),
            rawText: String(cString: transcribe_raw_text(ptr)),
            language: language.isEmpty ? nil : language,
            timestampKind: TimestampKind(transcribe_returned_timestamp_kind(ptr)),
            segments: segments, speakerSegments: speakerSegments,
            words: words, tokens: tokens, timings: Timings(timings))
    }

    private func batchTranscript(_ i: Int) -> Transcript {
        let idx = Int32(i)
        var segments: [Segment] = []
        for j in 0..<Int(transcribe_batch_n_segments(ptr, idx)) {
            var s = transcribe_segment(); transcribe_segment_init(&s)
            _ = transcribe_batch_get_segment(ptr, idx, Int32(j), &s)
            segments.append(Segment(s))
        }
        var words: [Word] = []
        for j in 0..<Int(transcribe_batch_n_words(ptr, idx)) {
            var w = transcribe_word(); transcribe_word_init(&w)
            _ = transcribe_batch_get_word(ptr, idx, Int32(j), &w)
            words.append(Word(w))
        }
        var tokens: [Token] = []
        for j in 0..<Int(transcribe_batch_n_tokens(ptr, idx)) {
            var t = transcribe_token(); transcribe_token_init(&t)
            _ = transcribe_batch_get_token(ptr, idx, Int32(j), &t)
            tokens.append(Token(t))
        }
        var speakerSegments: [SpeakerSegment] = []
        for j in 0..<Int(transcribe_batch_n_speaker_segments(ptr, idx)) {
            var s = transcribe_speaker_segment(); transcribe_speaker_segment_init(&s)
            _ = transcribe_batch_get_speaker_segment(ptr, idx, Int32(j), &s)
            speakerSegments.append(SpeakerSegment(s))
        }
        var timings = transcribe_timings(); transcribe_timings_init(&timings)
        _ = transcribe_batch_get_timings(ptr, idx, &timings)
        let language = String(cString: transcribe_batch_detected_language(ptr, idx))
        return Transcript(
            text: String(cString: transcribe_batch_full_text(ptr, idx)),
            rawText: String(cString: transcribe_batch_raw_text(ptr, idx)),
            language: language.isEmpty ? nil : language,
            timestampKind: TimestampKind(transcribe_batch_returned_timestamp_kind(ptr, idx)),
            segments: segments, speakerSegments: speakerSegments,
            words: words, tokens: tokens, timings: Timings(timings))
    }
}

/// Open every input's buffer pointer at once (nested closures) so all base
/// addresses are valid simultaneously for the duration of `body`.
private func withPCMPointers<R>(
    _ inputs: ArraySlice<[Float]>, _ acc: [UnsafePointer<Float>?],
    _ body: ([UnsafePointer<Float>?]) -> R
) -> R {
    guard let first = inputs.first else { return body(acc) }
    return first.withUnsafeBufferPointer { buffer in
        withPCMPointers(inputs.dropFirst(), acc + [buffer.baseAddress], body)
    }
}
