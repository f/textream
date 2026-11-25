import CTranscribe

// Typed family extensions. Each option struct uses Optionals so unset fields
// keep the C `_init` defaults — the library is told only what the caller set
// (the same "init then override" pattern the Rust binding uses). The C structs
// are materialized in a nested closure so their address is stable while the
// `transcribe_ext` pointer is handed to the run/begin call; the library copies
// what it needs before returning.

// MARK: - Run-slot extensions (whisper, sortformer)

public struct WhisperRunOptions: Sendable {
    public var initialPrompt: String?
    public var conditionOnPrevTokens: Bool?
    public var maxPrevContextTokens: Int32?
    public var temperature: Float?
    public var temperatureInc: Float?
    public var compressionRatioThold: Float?
    public var logprobThold: Float?
    public var noSpeechThold: Float?
    public var seed: UInt32?
    public var maxInitialTimestamp: Float?

    public init(
        initialPrompt: String? = nil,
        conditionOnPrevTokens: Bool? = nil,
        maxPrevContextTokens: Int32? = nil,
        temperature: Float? = nil,
        temperatureInc: Float? = nil,
        compressionRatioThold: Float? = nil,
        logprobThold: Float? = nil,
        noSpeechThold: Float? = nil,
        seed: UInt32? = nil,
        maxInitialTimestamp: Float? = nil
    ) {
        self.initialPrompt = initialPrompt
        self.conditionOnPrevTokens = conditionOnPrevTokens
        self.maxPrevContextTokens = maxPrevContextTokens
        self.temperature = temperature
        self.temperatureInc = temperatureInc
        self.compressionRatioThold = compressionRatioThold
        self.logprobThold = logprobThold
        self.noSpeechThold = noSpeechThold
        self.seed = seed
        self.maxInitialTimestamp = maxInitialTimestamp
    }
}

/// Sortformer streaming operating point (latency / accuracy trade-off).
/// The menu is discrete (jointly-tuned bundles), not a latency dial;
/// `.default` keeps the GGUF-shipped checkpoint configuration.
/// `.veryHighLatency` (~30 s lookahead) is the offline-file operating
/// point; `.lowLatency` (~1 s) is the real-time point.
public enum SortformerPreset: Sendable {
    case `default`
    case veryHighLatency
    case highLatency
    case lowLatency

    var cValue: transcribe_sortformer_preset {
        switch self {
        case .default: return TRANSCRIBE_SORTFORMER_PRESET_DEFAULT
        case .veryHighLatency: return TRANSCRIBE_SORTFORMER_PRESET_VERY_HIGH_LATENCY
        case .highLatency: return TRANSCRIBE_SORTFORMER_PRESET_HIGH_LATENCY
        case .lowLatency: return TRANSCRIBE_SORTFORMER_PRESET_LOW_LATENCY
        }
    }
}

/// Sortformer diarizer options (run slot). Sortformer produces speaker
/// segments, no text; read results via the speaker-segment accessors.
public struct SortformerStreamOptions: Sendable {
    public var preset: SortformerPreset?
    public init(preset: SortformerPreset? = nil) { self.preset = preset }
}

public enum RunExtension: Sendable {
    case whisper(WhisperRunOptions)
    case sortformer(SortformerStreamOptions)

    var kind: UInt32 {
        switch self {
        case .whisper: return TRANSCRIBE_EXT_KIND_WHISPER_RUN
        case .sortformer: return TRANSCRIBE_EXT_KIND_SORTFORMER_STREAM
        }
    }
}

/// Materialize the run extension (or pass NULL) and call `body` with a pointer
/// to its embedded `transcribe_ext`, kept alive for the call's duration.
func withRunExtension<R>(
    _ ext: RunExtension?, _ body: (UnsafePointer<transcribe_ext>?) throws -> R
) rethrows -> R {
    guard let ext else { return try body(nil) }
    switch ext {
    case .whisper(let o):
        var c = transcribe_whisper_run_ext()
        transcribe_whisper_run_ext_init(&c)
        if let v = o.conditionOnPrevTokens { c.condition_on_prev_tokens = v }
        if let v = o.maxPrevContextTokens { c.max_prev_context_tokens = v }
        if let v = o.temperature { c.temperature = v }
        if let v = o.temperatureInc { c.temperature_inc = v }
        if let v = o.compressionRatioThold { c.compression_ratio_thold = v }
        if let v = o.logprobThold { c.logprob_thold = v }
        if let v = o.noSpeechThold { c.no_speech_thold = v }
        if let v = o.seed { c.seed = v }
        if let v = o.maxInitialTimestamp { c.max_initial_timestamp = v }
        return try withOptionalCString(o.initialPrompt) { prompt in
            c.initial_prompt = prompt
            return try withUnsafePointer(to: &c.ext) { try body($0) }
        }
    case .sortformer(let o):
        var c = transcribe_sortformer_stream_ext()
        transcribe_sortformer_stream_ext_init(&c)
        if let v = o.preset { c.preset = v.cValue }
        return try withUnsafePointer(to: &c.ext) { try body($0) }
    }
}

// MARK: - Stream-slot extensions

public struct MoonshineStreamingOptions: Sendable {
    public var minDecodeIntervalMs: Int32?
    public init(minDecodeIntervalMs: Int32? = nil) { self.minDecodeIntervalMs = minDecodeIntervalMs }
}

public struct ParakeetStreamOptions: Sendable {
    public var attContextRight: Int32?
    public init(attContextRight: Int32? = nil) { self.attContextRight = attContextRight }
}

public struct ParakeetBufferedStreamOptions: Sendable {
    public var leftMs: Int32?
    public var chunkMs: Int32?
    public var rightMs: Int32?
    public init(leftMs: Int32? = nil, chunkMs: Int32? = nil, rightMs: Int32? = nil) {
        self.leftMs = leftMs; self.chunkMs = chunkMs; self.rightMs = rightMs
    }
}

public struct VoxtralRealtimeStreamOptions: Sendable {
    public var numDelayTokens: Int32?
    public var minDecodeIntervalMs: Int32?
    public init(numDelayTokens: Int32? = nil, minDecodeIntervalMs: Int32? = nil) {
        self.numDelayTokens = numDelayTokens; self.minDecodeIntervalMs = minDecodeIntervalMs
    }
}

public enum StreamExtension: Sendable {
    case parakeetStream(ParakeetStreamOptions)
    case parakeetBuffered(ParakeetBufferedStreamOptions)
    case moonshineStreaming(MoonshineStreamingOptions)
    case voxtralRealtime(VoxtralRealtimeStreamOptions)

    var kind: UInt32 {
        switch self {
        case .parakeetStream: return TRANSCRIBE_EXT_KIND_PARAKEET_STREAM
        case .parakeetBuffered: return TRANSCRIBE_EXT_KIND_PARAKEET_BUFFERED_STREAM
        case .moonshineStreaming: return TRANSCRIBE_EXT_KIND_MOONSHINE_STREAMING_STREAM
        case .voxtralRealtime: return TRANSCRIBE_EXT_KIND_VOXTRAL_REALTIME_STREAM
        }
    }
}

func withStreamExtension<R>(
    _ ext: StreamExtension?, _ body: (UnsafePointer<transcribe_ext>?) throws -> R
) rethrows -> R {
    guard let ext else { return try body(nil) }
    switch ext {
    case .parakeetStream(let o):
        var c = transcribe_parakeet_stream_ext()
        transcribe_parakeet_stream_ext_init(&c)
        if let v = o.attContextRight { c.att_context_right = v }
        return try withUnsafePointer(to: &c.ext) { try body($0) }
    case .parakeetBuffered(let o):
        var c = transcribe_parakeet_buffered_stream_ext()
        transcribe_parakeet_buffered_stream_ext_init(&c)
        if let v = o.leftMs { c.left_ms = v }
        if let v = o.chunkMs { c.chunk_ms = v }
        if let v = o.rightMs { c.right_ms = v }
        return try withUnsafePointer(to: &c.ext) { try body($0) }
    case .moonshineStreaming(let o):
        var c = transcribe_moonshine_streaming_stream_ext()
        transcribe_moonshine_streaming_stream_ext_init(&c)
        if let v = o.minDecodeIntervalMs { c.min_decode_interval_ms = v }
        return try withUnsafePointer(to: &c.ext) { try body($0) }
    case .voxtralRealtime(let o):
        var c = transcribe_voxtral_realtime_stream_ext()
        transcribe_voxtral_realtime_stream_ext_init(&c)
        if let v = o.numDelayTokens { c.num_delay_tokens = v }
        if let v = o.minDecodeIntervalMs { c.min_decode_interval_ms = v }
        return try withUnsafePointer(to: &c.ext) { try body($0) }
    }
}

// MARK: - Acceptance probe

extension Model {
    /// Whether this model accepts the given run extension on the RUN slot.
    public func accepts(_ family: RunExtension) -> Bool {
        transcribe_model_accepts_ext_kind(ptr, TRANSCRIBE_EXT_SLOT_RUN, family.kind)
    }
    /// Whether this model accepts the given stream extension on the STREAM slot.
    public func accepts(_ family: StreamExtension) -> Bool {
        transcribe_model_accepts_ext_kind(ptr, TRANSCRIBE_EXT_SLOT_STREAM, family.kind)
    }
}
