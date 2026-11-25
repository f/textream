import CTranscribe

/// Native errors mapped to Swift's idiom. Every `transcribe_status` becomes a
/// distinct case so callers can pattern-match the failure class. Distinct C
/// failures stay distinct (requirements §3): "no such provider" is not
/// "provider can't satisfy this request".
///
/// `.aborted` / `.outputTruncated` carry the preserved partial `Transcript`
/// (the C side keeps partial output readable after those statuses); it is `nil`
/// when the error is built outside a run (e.g. by `check`).
///
/// `.busy` is a binding-level error (no C status maps to it): the C library
/// allows at most one in-flight run/stream across all sessions of a model (the
/// 0.x limitation in `include/transcribe.h`), and the wrapper refuses an
/// overlapping run/stream rather than racing into the documented UB.
public enum TranscribeError: Error {
    case invalidArgument(String)
    case notImplemented(String)
    case modelFileNotFound(String)
    case modelLoad(String)
    case outOfMemory(String)
    case backend(String)
    case unsupported(String)
    case badStructSize(String)
    case inputTooLong(String)
    case aborted(message: String, partial: Transcript?)
    case outputTruncated(message: String, partial: Transcript?)
    case versionMismatch(String)
    case busy(String)
    case other(status: Int32, message: String)

    /// Status description, prefixed with `context` when given.
    static func message(_ status: transcribe_status, _ context: String = "") -> String {
        let base = String(cString: transcribe_status_string(Int32(bitPattern: status.rawValue)))
        return context.isEmpty ? base : "\(context): \(base)"
    }

    /// Build the error for a non-OK status, prefixing `context` when given.
    static func make(_ status: transcribe_status, context: String = "") -> TranscribeError {
        let raw = Int32(bitPattern: status.rawValue)
        let message = message(status, context)
        switch status {
        case TRANSCRIBE_ERR_INVALID_ARG:
            return .invalidArgument(message)
        case TRANSCRIBE_ERR_NOT_IMPLEMENTED:
            return .notImplemented(message)
        case TRANSCRIBE_ERR_FILE_NOT_FOUND:
            return .modelFileNotFound(message)
        case TRANSCRIBE_ERR_GGUF, TRANSCRIBE_ERR_UNSUPPORTED_ARCH, TRANSCRIBE_ERR_UNSUPPORTED_VARIANT:
            return .modelLoad(message)
        case TRANSCRIBE_ERR_OOM:
            return .outOfMemory(message)
        case TRANSCRIBE_ERR_BACKEND:
            return .backend(message)
        case TRANSCRIBE_ERR_UNSUPPORTED_LANGUAGE, TRANSCRIBE_ERR_UNSUPPORTED_TASK,
             TRANSCRIBE_ERR_UNSUPPORTED_TIMESTAMPS, TRANSCRIBE_ERR_UNSUPPORTED_PNC,
             TRANSCRIBE_ERR_UNSUPPORTED_ITN:
            return .unsupported(message)
        case TRANSCRIBE_ERR_BAD_STRUCT_SIZE:
            return .badStructSize(message)
        case TRANSCRIBE_ERR_INPUT_TOO_LONG:
            return .inputTooLong(message)
        case TRANSCRIBE_ERR_ABORTED:
            return .aborted(message: message, partial: nil)
        case TRANSCRIBE_ERR_OUTPUT_TRUNCATED:
            return .outputTruncated(message: message, partial: nil)
        default:
            return .other(status: raw, message: message)
        }
    }

    /// Throw the mapped error unless `status` is `TRANSCRIBE_OK`.
    static func check(_ status: transcribe_status, context: String = "") throws {
        guard status != TRANSCRIBE_OK else { return }
        throw make(status, context: context)
    }
}
