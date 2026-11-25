import CTranscribe

// MARK: - Enums

/// The run mode: plain transcription or speech translation. Named
/// `TranscriptionTask` (not `Task`) so it does not shadow Swift's
/// `_Concurrency.Task` in files that `import TranscribeCpp`.
public enum TranscriptionTask: Sendable {
    case transcribe, translate
    var cValue: transcribe_task {
        self == .transcribe ? TRANSCRIBE_TASK_TRANSCRIBE : TRANSCRIBE_TASK_TRANSLATE
    }
}

public enum TimestampKind: Sendable {
    case none, auto, segment, word, token

    var cValue: transcribe_timestamp_kind {
        switch self {
        case .none: return TRANSCRIBE_TIMESTAMPS_NONE
        case .auto: return TRANSCRIBE_TIMESTAMPS_AUTO
        case .segment: return TRANSCRIBE_TIMESTAMPS_SEGMENT
        case .word: return TRANSCRIBE_TIMESTAMPS_WORD
        case .token: return TRANSCRIBE_TIMESTAMPS_TOKEN
        }
    }

    init(_ c: transcribe_timestamp_kind) {
        switch c {
        case TRANSCRIBE_TIMESTAMPS_AUTO: self = .auto
        case TRANSCRIBE_TIMESTAMPS_SEGMENT: self = .segment
        case TRANSCRIBE_TIMESTAMPS_WORD: self = .word
        case TRANSCRIBE_TIMESTAMPS_TOKEN: self = .token
        default: self = .none
        }
    }
}

public enum KvType: Sendable {
    case auto, f32, f16
    var cValue: transcribe_kv_type {
        switch self {
        case .auto: return TRANSCRIBE_KV_TYPE_AUTO
        case .f32: return TRANSCRIBE_KV_TYPE_F32
        case .f16: return TRANSCRIBE_KV_TYPE_F16
        }
    }
}

public enum Pnc: Sendable {
    case `default`, off, on
    var cValue: transcribe_pnc_mode {
        switch self {
        case .default: return TRANSCRIBE_PNC_MODE_DEFAULT
        case .off: return TRANSCRIBE_PNC_MODE_OFF
        case .on: return TRANSCRIBE_PNC_MODE_ON
        }
    }
}

public enum Itn: Sendable {
    case `default`, off, on
    var cValue: transcribe_itn_mode {
        switch self {
        case .default: return TRANSCRIBE_ITN_MODE_DEFAULT
        case .off: return TRANSCRIBE_ITN_MODE_OFF
        case .on: return TRANSCRIBE_ITN_MODE_ON
        }
    }
}

public enum Diarize: Sendable {
    case `default`, off, on
    var cValue: transcribe_diarize_mode {
        switch self {
        case .default: return TRANSCRIBE_DIARIZE_MODE_DEFAULT
        case .off: return TRANSCRIBE_DIARIZE_MODE_OFF
        case .on: return TRANSCRIBE_DIARIZE_MODE_ON
        }
    }
}

public enum Feature: Sendable {
    case initialPrompt, temperatureFallback, longForm, cancellation, pnc, itn, diarization
    var cValue: transcribe_feature {
        switch self {
        case .initialPrompt: return TRANSCRIBE_FEATURE_INITIAL_PROMPT
        case .temperatureFallback: return TRANSCRIBE_FEATURE_TEMPERATURE_FALLBACK
        case .longForm: return TRANSCRIBE_FEATURE_LONG_FORM
        case .cancellation: return TRANSCRIBE_FEATURE_CANCELLATION
        case .pnc: return TRANSCRIBE_FEATURE_PNC
        case .itn: return TRANSCRIBE_FEATURE_ITN
        case .diarization: return TRANSCRIBE_FEATURE_DIARIZATION
        }
    }
}

// MARK: - Options

public struct ModelOptions: Sendable {
    public var backend: Backend
    /// Exact process-local device. `nil` applies the backend's automatic policy.
    public var device: Device?
    public init(backend: Backend = .auto, device: Device? = nil) {
        self.backend = backend
        self.device = device
    }
}

public struct SessionOptions: Sendable {
    /// CPU threads for CPU ops; 0 = library default.
    public var nThreads: Int32
    public var kvType: KvType
    /// Optional decoder-context cap in tokens; 0 = model max.
    public var nCtx: Int32
    public init(nThreads: Int32 = 0, kvType: KvType = .auto, nCtx: Int32 = 0) {
        self.nThreads = nThreads
        self.kvType = kvType
        self.nCtx = nCtx
    }
}

public struct RunOptions: Sendable {
    public var task: TranscriptionTask
    public var timestamps: TimestampKind
    public var pnc: Pnc
    public var itn: Itn
    public var diarize: Diarize
    /// Source language hint (BCP-47-ish short code); `nil` = autodetect.
    public var language: String?
    /// Target language for translation; `nil` otherwise.
    public var targetLanguage: String?
    /// Keep special `<|...|>` tags in the returned text.
    public var keepSpecialTags: Bool
    /// Speculative-decode draft length: -1 = family default, 0 = disabled.
    public var specKDrafts: Int32
    /// Family-specific run extension (whisper run options); M3.
    public var family: RunExtension?

    public init(
        task: TranscriptionTask = .transcribe,
        // .auto ("richest the model supports", per-family) mirrors the C
        // transcribe_run_params_init default: whisper resolves it to .segment
        // (its robust path), no-timestamp families resolve to .none.
        timestamps: TimestampKind = .auto,
        pnc: Pnc = .default,
        itn: Itn = .default,
        diarize: Diarize = .default,
        language: String? = nil,
        targetLanguage: String? = nil,
        keepSpecialTags: Bool = false,
        specKDrafts: Int32 = -1,
        family: RunExtension? = nil
    ) {
        self.task = task
        self.timestamps = timestamps
        self.pnc = pnc
        self.itn = itn
        self.diarize = diarize
        self.language = language
        self.targetLanguage = targetLanguage
        self.keepSpecialTags = keepSpecialTags
        self.specKDrafts = specKDrafts
        self.family = family
    }

    /// Materialize a `transcribe_run_params` and run `body` with a pointer to
    /// it. The `language` / `target_language` C strings are kept alive for the
    /// duration of `body` (the C side copies them before returning).
    func withCParams<R>(_ body: (UnsafePointer<transcribe_run_params>) throws -> R) rethrows -> R {
        var params = transcribe_run_params()
        transcribe_run_params_init(&params)
        params.task = task.cValue
        params.timestamps = timestamps.cValue
        params.pnc = pnc.cValue
        params.itn = itn.cValue
        params.diarize = diarize.cValue
        params.keep_special_tags = keepSpecialTags
        params.spec_k_drafts = specKDrafts
        return try withOptionalCString(language) { lang in
            params.language = lang
            return try withOptionalCString(targetLanguage) { tgt in
                params.target_language = tgt
                return try withRunExtension(family) { ext in
                    params.family = ext
                    return try withUnsafePointer(to: &params) { try body($0) }
                }
            }
        }
    }
}

func withOptionalCString<R>(
    _ string: String?, _ body: (UnsafePointer<CChar>?) throws -> R
) rethrows -> R {
    if let string { return try string.withCString { try body($0) } }
    return try body(nil)
}
