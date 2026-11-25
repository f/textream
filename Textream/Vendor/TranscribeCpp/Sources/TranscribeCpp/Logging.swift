import CTranscribe
import Foundation

public enum LogLevel: Sendable {
    case none, info, warn, error, debug, continuation

    init(_ c: transcribe_log_level) {
        switch c {
        case TRANSCRIBE_LOG_LEVEL_INFO: self = .info
        case TRANSCRIBE_LOG_LEVEL_WARN: self = .warn
        case TRANSCRIBE_LOG_LEVEL_ERROR: self = .error
        case TRANSCRIBE_LOG_LEVEL_DEBUG: self = .debug
        case TRANSCRIBE_LOG_LEVEL_CONT: self = .continuation
        default: self = .none
        }
    }
}

/// Holds the global Swift log handler. The native sink is process-global and
/// may fire from any thread (including ggml worker threads), so access is
/// lock-guarded.
///
/// The native `transcribe_log_set` is startup-only (C contract): calling it
/// repeatedly after models/threads exist is unsupported. So the binding installs
/// ONE native trampoline (the first time a handler is set or logging disabled)
/// and thereafter only swaps the Swift handler behind it — `transcribe_log_set`
/// is called at most once per process.
private final class LogState: @unchecked Sendable {
    static let shared = LogState()
    private let lock = NSLock()
    private var handler: (@Sendable (LogLevel, String) -> Void)?
    private var trampolineInstalled = false
    /// Times `transcribe_log_set` has actually been invoked. Test hook for the
    /// "install once" invariant; must never exceed 1.
    private(set) var nativeInstallCount = 0

    /// Swap the Swift handler, installing the native trampoline exactly once.
    func set(_ h: (@Sendable (LogLevel, String) -> Void)?) {
        lock.lock()
        handler = h
        let needInstall = !trampolineInstalled
        if needInstall {
            trampolineInstalled = true
            nativeInstallCount += 1
        }
        lock.unlock()
        // Outside the lock: the C call only stores the callback (it never invokes
        // it synchronously), but keep it off the lock the trampoline also takes.
        if needInstall { transcribe_log_set(logTrampoline, nil) }
    }
    func current() -> (@Sendable (LogLevel, String) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return handler
    }
}

private func logTrampoline(
    _ level: transcribe_log_level, _ msg: UnsafePointer<CChar>?, _ userData: UnsafeMutableRawPointer?
) {
    let text = msg.map { String(cString: $0) } ?? ""
    LogState.shared.current()?(LogLevel(level), text)
}

extension Transcribe {
    /// Route native log messages (library + ggml diagnostics) to `handler`.
    /// Best called once at startup (before loading models), but safe to call
    /// later or repeatedly: the native trampoline is installed once and only the
    /// Swift handler is swapped. The handler may be invoked from any thread.
    public static func setLogHandler(_ handler: @escaping @Sendable (LogLevel, String) -> Void) {
        LogState.shared.set(handler)
    }

    /// Disable logging (library and ggml messages are dropped). Swaps the Swift
    /// handler to none behind the single installed trampoline; does not re-touch
    /// the native sink beyond the one-time install.
    public static func disableLogging() {
        LogState.shared.set(nil)
    }

    /// Times the native `transcribe_log_set` has been invoked this process.
    /// Internal test hook for the "install once" invariant.
    static var nativeLogSetCount: Int { LogState.shared.nativeInstallCount }
}
