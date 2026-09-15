import CTranscribe
import Foundation

/// A loaded model. Safe to share across threads (`@unchecked Sendable`): the C
/// API allows concurrent queries and session creation, and the compute path is
/// serialized by an internal lock (the C "one in-flight run per model"
/// contract — the same per-model mutex + stream lease the Rust binding uses). A
/// `Model` outlives every `Session` derived from it; the session holds a strong
/// reference, so close ordering is automatic under ARC.
public final class Model: @unchecked Sendable {
    let ptr: OpaquePointer
    /// Serializes the run/feed/finalize compute path across all sessions, and
    /// guards `streamActive`.
    let runLock = NSLock()
    /// The compute lease: `true` while some session holds an ACTIVE stream.
    /// The C contract allows at most one in-flight run/stream across ALL
    /// sessions of a model, and an active stream spans begin..finalize/reset/
    /// drop — so `run`/`runBatch`/another `stream` are refused with `.busy`
    /// while it is held, rather than racing into the documented UB (corrupted
    /// decodes on CPU, command-buffer failures on Metal). Always accessed under
    /// `runLock`.
    var streamActive = false

    /// Load a model from a GGUF file. Runs the pre-1.0 version gate first.
    public init(path: String, options: ModelOptions = .init()) throws {
        try Transcribe.ensureCompatible()
        var params = transcribe_model_load_params()
        transcribe_model_load_params_init(&params)
        params.backend = options.backend.cValue
        params.device = options.device?.handle
        var out: OpaquePointer?
        let status = transcribe_model_load_file(path, &params, &out)
        try TranscribeError.check(status, context: "loading \(path)")
        guard let out else {
            throw TranscribeError.modelLoad("loading \(path): null model handle")
        }
        ptr = out
    }

    deinit { transcribe_model_free(ptr) }

    /// Create a transcription session bound to this model.
    public func session(_ options: SessionOptions = .init()) throws -> Session {
        var params = transcribe_session_params()
        transcribe_session_params_init(&params)
        params.n_threads = options.nThreads
        params.kv_type = options.kvType.cValue
        params.n_ctx = options.nCtx
        var out: OpaquePointer?
        let status = transcribe_session_init(ptr, &params, &out)
        try TranscribeError.check(status, context: "creating session")
        guard let out else {
            throw TranscribeError.other(status: 0, message: "null session handle")
        }
        return Session(model: self, ptr: out)
    }

    public var capabilities: Capabilities {
        var caps = transcribe_capabilities()
        transcribe_capabilities_init(&caps)
        _ = transcribe_model_get_capabilities(ptr, &caps)
        return Capabilities(caps)
    }

    public func supports(_ feature: Feature) -> Bool {
        transcribe_model_supports(ptr, feature.cValue)
    }

    /// `general.architecture`, e.g. "parakeet".
    public var arch: String { String(cString: transcribe_model_arch_string(ptr)) }
    /// `stt.variant`, e.g. "tdt-0.6b-v2" (may be empty).
    public var variant: String { String(cString: transcribe_model_variant_string(ptr)) }
    /// The runtime backend bound to this model, e.g. "metal" / "cpu".
    public var backend: String { String(cString: transcribe_model_backend(ptr)) }

    /// The compute `Device` this model is running on — the one that owns its
    /// weights. `memoryFree` is a live snapshot, so read this again to poll how
    /// much device memory is left after the model loaded. Throws if the model
    /// has no resolved compute device.
    public var device: Device {
        get throws {
            guard let handle = transcribe_model_device(ptr) else {
                throw TranscribeError.backend("model has no resolved compute device")
            }
            var raw = transcribe_device_info()
            transcribe_device_info_init(&raw)
            try TranscribeError.check(
                transcribe_device_get_info(handle, &raw), context: "device_get_info")
            return Device(raw, handle: handle)
        }
    }

    /// Tokenize plain UTF-8 text into the model's vocabulary (no special
    /// tokens). Throws `.notImplemented` for vocabularies without an encoder.
    public func tokenize(_ text: String) throws -> [Int32] {
        var capacity = 256
        while true {
            var buffer = [Int32](repeating: 0, count: capacity)
            let n = transcribe_tokenize(ptr, text, &buffer, capacity)
            if n == Int32.min {
                throw TranscribeError.notImplemented("tokenize is unsupported for this model")
            }
            if n < 0 { capacity = Int(-n); continue }  // buffer too small: retry
            return Array(buffer[0..<Int(n)])
        }
    }
}
