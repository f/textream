import CTranscribe

/// A fully-materialized transcription result. All text is copied out of the
/// session at the FFI boundary (docs/bindings.md), so a `Transcript` outlives
/// the next run and the session itself.
public struct Transcript: Sendable, Equatable {
    public let text: String
    /// The model's decoded output before family post-processing (diarization
    /// markers, timestamp/special tokens, tag filtering, whitespace trims).
    /// Equal to `text` modulo whitespace for families that emit clean text.
    public let rawText: String
    /// Detected language ISO code, or `nil` when the model didn't predict one
    /// (English-only model, a caller-supplied hint, or no LID).
    public let language: String?
    /// The granularity actually returned (may be coarser than requested).
    public let timestampKind: TimestampKind
    public let segments: [Segment]
    public let speakerSegments: [SpeakerSegment]
    public let words: [Word]
    public let tokens: [Token]
    public let timings: Timings
}

/// A segment with timing and index ranges into `words` / `tokens`.
public struct Segment: Sendable, Equatable {
    public let t0Ms: Int64
    public let t1Ms: Int64
    public let firstWord: Int32
    public let nWords: Int32
    public let firstToken: Int32
    public let nTokens: Int32
    public let text: String
    /// 1-based speaker id; zero means no attribution.
    public let speakerId: Int32

    init(_ c: transcribe_segment) {
        t0Ms = c.t0_ms; t1Ms = c.t1_ms
        firstWord = c.first_word; nWords = c.n_words
        firstToken = c.first_token; nTokens = c.n_tokens
        text = c.text.map { String(cString: $0) } ?? ""
        speakerId = c.speaker_id
    }
}

/// One diarized speaker turn. Zero times mean attribution without timing;
/// `p` is NaN when the model does not expose confidence.
public struct SpeakerSegment: Sendable, Equatable {
    public let t0Ms: Int64
    public let t1Ms: Int64
    public let speakerId: Int32
    public let p: Float

    init(_ c: transcribe_speaker_segment) {
        t0Ms = c.t0_ms; t1Ms = c.t1_ms
        speakerId = c.speaker_id; p = c.p
    }
}

/// A word with timing, its parent segment index, and a token range.
public struct Word: Sendable, Equatable {
    public let t0Ms: Int64
    public let t1Ms: Int64
    public let segIndex: Int32
    public let firstToken: Int32
    public let nTokens: Int32
    public let text: String

    init(_ c: transcribe_word) {
        t0Ms = c.t0_ms; t1Ms = c.t1_ms
        segIndex = c.seg_index
        firstToken = c.first_token; nTokens = c.n_tokens
        text = c.text.map { String(cString: $0) } ?? ""
    }
}

/// A single token. `p` is a family-specific confidence hint (NaN when the
/// architecture produces none).
public struct Token: Sendable, Equatable {
    public let id: Int32
    public let p: Float
    public let t0Ms: Int64
    public let t1Ms: Int64
    public let segIndex: Int32
    public let wordIndex: Int32
    public let text: String

    init(_ c: transcribe_token) {
        id = c.id; p = c.p
        t0Ms = c.t0_ms; t1Ms = c.t1_ms
        segIndex = c.seg_index; wordIndex = c.word_index
        text = c.text.map { String(cString: $0) } ?? ""
    }
}

/// Per-call stage timings in milliseconds. Zero means "unknown / not measured".
public struct Timings: Sendable, Equatable {
    public let loadMs: Float
    public let melMs: Float
    public let encodeMs: Float
    public let decodeMs: Float

    init(_ c: transcribe_timings) {
        loadMs = c.load_ms; melMs = c.mel_ms
        encodeMs = c.encode_ms; decodeMs = c.decode_ms
    }
}

/// Immutable semantic properties read from the model at load time.
public struct Capabilities: Sendable, Equatable {
    public let nativeSampleRate: Int32
    /// Supported language codes; empty when the model is language-agnostic.
    public let languages: [String]
    /// Supported translation target language codes; empty when not advertised.
    public let translateTargetLanguages: [String]
    public let maxTimestampKind: TimestampKind
    public let supportsLanguageDetect: Bool
    public let supportsTranslate: Bool
    public let supportsStreaming: Bool
    public let supportsSpecDecode: Bool
    /// Longest single-run audio in ms; 0 = no practical limit.
    public let maxAudioMs: Int64

    init(_ c: transcribe_capabilities) {
        nativeSampleRate = c.native_sample_rate
        var langs: [String] = []
        if let arr = c.languages {
            for i in 0..<Int(c.n_languages) {
                if let s = arr[i] { langs.append(String(cString: s)) }
            }
        }
        languages = langs
        var targetLangs: [String] = []
        if let arr = c.translate_target_languages {
            for i in 0..<Int(c.n_translate_target_languages) {
                if let s = arr[i] { targetLangs.append(String(cString: s)) }
            }
        }
        translateTargetLanguages = targetLangs
        maxTimestampKind = TimestampKind(c.max_timestamp_kind)
        supportsLanguageDetect = c.supports_language_detect
        supportsTranslate = c.supports_translate
        supportsStreaming = c.supports_streaming
        supportsSpecDecode = c.supports_spec_decode
        maxAudioMs = c.max_audio_ms
    }
}

/// Effective per-session limits (see `transcribe_session_get_limits`).
public struct SessionLimits: Sendable, Equatable {
    public let effectiveNCtx: Int32
    public let effectiveMaxAudioMs: Int64
    public let maxKvBytes: Int64

    init(_ c: transcribe_session_limits) {
        effectiveNCtx = c.effective_n_ctx
        effectiveMaxAudioMs = c.effective_max_audio_ms
        maxKvBytes = c.max_kv_bytes
    }
}
