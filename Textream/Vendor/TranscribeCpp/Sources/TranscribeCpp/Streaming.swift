import CTranscribe

public enum StreamState: Sendable {
    case idle, active, finished, failed
    init(_ c: transcribe_stream_state) {
        switch c {
        case TRANSCRIBE_STREAM_ACTIVE: self = .active
        case TRANSCRIBE_STREAM_FINISHED: self = .finished
        case TRANSCRIBE_STREAM_FAILED: self = .failed
        default: self = .idle
        }
    }
}

public enum CommitPolicy: Sendable {
    case auto, onFinalize, stablePrefix
    var cValue: transcribe_stream_commit_policy {
        switch self {
        case .auto: return TRANSCRIBE_STREAM_COMMIT_AUTO
        case .onFinalize: return TRANSCRIBE_STREAM_COMMIT_ON_FINALIZE
        case .stablePrefix: return TRANSCRIBE_STREAM_COMMIT_STABLE_PREFIX
        }
    }
}

public struct StreamOptions: Sendable {
    public var commitPolicy: CommitPolicy
    /// Consecutive agreeing hypotheses before a prefix commits; 0 = default (3).
    public var stablePrefixAgreementN: UInt32
    public var family: StreamExtension?

    public init(
        commitPolicy: CommitPolicy = .auto,
        stablePrefixAgreementN: UInt32 = 0,
        family: StreamExtension? = nil
    ) {
        self.commitPolicy = commitPolicy
        self.stablePrefixAgreementN = stablePrefixAgreementN
        self.family = family
    }

    func withCParams<R>(_ body: (UnsafePointer<transcribe_stream_params>) throws -> R) rethrows -> R {
        var params = transcribe_stream_params()
        transcribe_stream_params_init(&params)
        params.commit_policy = commitPolicy.cValue
        params.stable_prefix_agreement_n = stablePrefixAgreementN
        return try withStreamExtension(family) { ext in
            params.family = ext
            return try withUnsafePointer(to: &params) { try body($0) }
        }
    }
}

/// UI-stable streaming text. `committed` is append-only and flicker-free;
/// `tentative` is the volatile suffix; `full` is the authoritative raw
/// hypothesis. All copied at the FFI boundary.
public struct StreamText: Sendable, Equatable {
    public let full: String
    public let committed: String
    public let tentative: String
    /// Flicker-free display string: `committed + tentative`.
    public var display: String { committed + tentative }

    init(_ c: transcribe_stream_text) {
        full = c.full_text.map { String(cString: $0) } ?? ""
        committed = c.committed_text.map { String(cString: $0) } ?? ""
        tentative = c.tentative_text.map { String(cString: $0) } ?? ""
    }
}

/// Per-call change metadata from `feed` / `finalize`.
public struct StreamUpdate: Sendable, Equatable {
    public let resultChanged: Bool
    public let isFinal: Bool
    public let revision: Int32
    public let inputReceivedMs: Int64
    public let audioCommittedMs: Int64
    public let bufferedMs: Int64
    public let committedChanged: Bool
    public let tentativeChanged: Bool

    init(_ c: transcribe_stream_update) {
        resultChanged = c.result_changed
        isFinal = c.is_final
        revision = c.revision
        inputReceivedMs = c.input_received_ms
        audioCommittedMs = c.audio_committed_ms
        bufferedMs = c.buffered_ms
        committedChanged = c.committed_changed
        tentativeChanged = c.tentative_changed
    }
}

/// An active streaming run on a `Session`. Streaming is a mode on the session,
/// so a `Stream` holds its session (keeping it alive) and drives its state.
/// Like the session, it is single-threaded; `feed`/`finalize` serialize on the
/// model lock (the compute path).
public final class Stream {
    private let session: Session
    /// True while this stream holds the model's compute lease (set at begin,
    /// cleared at finalize/reset/deinit). Tracked per-stream so `deinit` never
    /// releases a lease a *different* session has since acquired — mirrors the
    /// Rust binding's `holds_lease`. Mutated only under `model.runLock`; the
    /// `deinit` guard reads it on the deallocating thread, where no other
    /// reference to this `Stream` can exist (so no concurrent mutation).
    var holdsLease = true

    init(_ session: Session) { self.session = session }

    /// Abandon any unfinalized stream when the handle is dropped: without this,
    /// a `Stream` that goes out of scope without `finalize()`/`reset()` would
    /// leave the session stuck ACTIVE and the model's compute lease held
    /// forever. Reset is idempotent and safe from any state.
    deinit {
        guard holdsLease else { return }
        session.model.runLock.lock()
        transcribe_stream_reset(session.ptr)
        session.model.streamActive = false
        session.model.runLock.unlock()
    }

    /// Feed a PCM frame (16 kHz mono float32). Returns per-call change metadata.
    public func feed(_ frame: [Float]) throws -> StreamUpdate {
        session.model.runLock.lock()
        defer { session.model.runLock.unlock() }
        var update = transcribe_stream_update()
        transcribe_stream_update_init(&update)
        let status = frame.withUnsafeBufferPointer {
            transcribe_stream_feed(session.ptr, $0.baseAddress, Int32($0.count), &update)
        }
        try TranscribeError.check(status, context: "stream_feed")
        return StreamUpdate(update)
    }

    /// Signal end of input; flushes buffered audio and emits remaining text.
    /// Either way the stream is no longer active, so the model's compute lease
    /// is released here (not deferred to `deinit`) — another session may
    /// proceed without waiting for this `Stream` to drop.
    @discardableResult
    public func finalize() throws -> StreamUpdate {
        session.model.runLock.lock()
        defer { session.model.runLock.unlock() }
        var update = transcribe_stream_update()
        transcribe_stream_update_init(&update)
        let status = transcribe_stream_finalize(session.ptr, &update)
        if holdsLease { session.model.streamActive = false; holdsLease = false }
        try TranscribeError.check(status, context: "stream_finalize")
        return StreamUpdate(update)
    }

    /// Abandon the stream and return the session to idle. Releases the model's
    /// compute lease (the stream is no longer active).
    @discardableResult
    public func reset() -> StreamState {
        session.model.runLock.lock()
        transcribe_stream_reset(session.ptr)
        if holdsLease { session.model.streamActive = false; holdsLease = false }
        session.model.runLock.unlock()
        return state
    }

    public var state: StreamState { StreamState(transcribe_stream_get_state(session.ptr)) }
    public var revision: Int32 { transcribe_stream_revision(session.ptr) }

    /// The stream's recorded terminal failure, or `nil` while it is healthy.
    /// Set after a `feed`/`finalize` transitioned the stream to `.failed`; reset
    /// by a new stream. Inspect it when `state == .failed` to learn why.
    public var lastStatus: TranscribeError? {
        let status = transcribe_stream_last_status(session.ptr)
        return status == TRANSCRIBE_OK ? nil : TranscribeError.make(status, context: "stream")
    }

    /// The UI-stable text snapshot (committed / tentative / full).
    public var text: StreamText {
        var t = transcribe_stream_text()
        transcribe_stream_text_init(&t)
        _ = transcribe_stream_get_text(session.ptr, &t)
        return StreamText(t)
    }

    /// Full structured snapshot of the current hypothesis (owned copies).
    public var snapshot: Transcript { session.readTranscript() }
}

extension Session {
    /// Begin a streaming run. The session must support streaming (else
    /// `.notImplemented`) and be idle/finished/failed (not already streaming).
    /// Claims the model's compute lease for the whole stream lifetime: a second
    /// stream — or an offline run — on ANY session of the same model is refused
    /// with `.busy` until this stream finalizes, resets, or is dropped.
    public func stream(
        _ runOptions: RunOptions = .init(), _ streamOptions: StreamOptions = .init()
    ) throws -> Stream {
        model.runLock.lock()
        defer { model.runLock.unlock() }
        if model.streamActive {
            throw TranscribeError.busy("a stream is already active on this model")
        }
        let status = runOptions.withCParams { runParams in
            streamOptions.withCParams { streamParams in
                transcribe_stream_begin(ptr, runParams, streamParams)
            }
        }
        try TranscribeError.check(status, context: "stream_begin")
        model.streamActive = true
        return Stream(self)
    }
}
