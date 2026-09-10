/// Swift bindings for transcribe.cpp.
///
/// `TranscribeCpp` is the idiomatic Swift wrapper over the C API exposed by the
/// `CTranscribe` module (the prebuilt `.xcframework` binaryTarget). Objective-C
/// and C++ consumers can `#import` the bundled `transcribe/extensions.h`
/// directly; this wrapper is the Swift-native surface.
///
/// The full surface is implemented: `Model` / `Session` / `Stream`, offline and
/// streaming transcription, batch, cancellation, logging, and family
/// extensions, plus the no-model surface (version, ABI, device discovery,
/// errors). See `notes/swift-bindings-plan.md` for the capability matrix.
import CTranscribe

/// Top-level, model-free entry points: identity, ABI introspection, the
/// load-time version gate, and backend discovery.
public enum Transcribe {
    /// Version this binding was built against. Pinned here for the pre-1.0
    /// base-version load gate; the version-sync milestone will generate it from
    /// `include/transcribe.h` (the single source of truth) rather than hardcode.
    public static let compiledVersion = "0.2.3"

    /// `MAJOR.MINOR.PATCH` of the linked native library.
    public static func version() -> String { String(cString: transcribe_version()) }

    /// Short git commit the native library was built from, or "unknown".
    public static func versionCommit() -> String {
        String(cString: transcribe_version_commit())
    }

    /// Human-readable description of a native status code.
    public static func statusString(_ status: Int32) -> String {
        String(cString: transcribe_status_string(status))
    }

    /// `sizeof` the native library reports for a public ABI struct. Used by the
    /// no-model ABI liveness check; a real layout is non-zero.
    public static func abiStructSize(_ which: AbiStruct) -> Int {
        Int(transcribe_abi_struct_size(which.cValue))
    }

    /// Pre-1.0 load gate: the linked library and this binding must agree on the
    /// base `MAJOR.MINOR.PATCH` (a packaging-only post-release suffix still
    /// loads). Mirrors the Python/Rust load-time gate.
    public static func ensureCompatible() throws {
        let have = baseVersion(version())
        let want = baseVersion(compiledVersion)
        guard have == want else {
            throw TranscribeError.versionMismatch(
                "native library \(version()) is incompatible with binding \(compiledVersion)")
        }
    }

    /// Whether a backend request can be satisfied by some registered device.
    /// Never throws: an unavailable or unknown backend answers `false`.
    public static func backendAvailable(_ backend: Backend) -> Bool {
        transcribe_backend_available(backend.cValue)
    }

    /// (Re)scan and register the available compute backends. A no-op for a
    /// statically-linked build with backends compiled in (the xcframework
    /// posture); emits a one-line device summary through the log sink. Throws
    /// if the scan reports an error.
    public static func initBackends() throws {
        try TranscribeError.check(transcribe_init_backends_default(), context: "init_backends")
    }

    /// The compute devices the native library has registered.
    public static func devices() -> [Device] {
        let count = transcribe_device_count()
        var devices: [Device] = []
        devices.reserveCapacity(Int(count))
        for index in 0..<count {
            guard let handle = transcribe_device_get(index) else { continue }
            var raw = transcribe_device_info()
            transcribe_device_info_init(&raw)
            guard transcribe_device_get_info(handle, &raw) == TRANSCRIBE_OK else { continue }
            devices.append(Device(raw, handle: handle, index: Int(index)))
        }
        return devices
    }
}

/// Leading dotted-numeric release segment, suffix stripped (PEP 440 style):
/// `"0.0.1.post3"` → `"0.0.1"`. Internal; the base-version gate uses it.
func baseVersion(_ version: String) -> String {
    var out = ""
    for scalar in version.unicodeScalars {
        if scalar == "." || ("0"..."9").contains(scalar) {
            out.unicodeScalars.append(scalar)
        } else {
            break
        }
    }
    return out
}
