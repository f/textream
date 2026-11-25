import CTranscribe

/// A backend request. `auto` always succeeds (CPU is the final fallback);
/// Explicit GPU choices require that backend to be present in the build.
public enum Backend: Sendable, Equatable {
    case auto
    case cpu
    case cpuAccel
    case metal
    case vulkan
    case cuda
    case rocm

    var cValue: transcribe_backend_request {
        switch self {
        case .auto: return TRANSCRIBE_BACKEND_AUTO
        case .cpu: return TRANSCRIBE_BACKEND_CPU
        case .cpuAccel: return TRANSCRIBE_BACKEND_CPU_ACCEL
        case .metal: return TRANSCRIBE_BACKEND_METAL
        case .vulkan: return TRANSCRIBE_BACKEND_VULKAN
        case .cuda: return TRANSCRIBE_BACKEND_CUDA
        case .rocm: return TRANSCRIBE_BACKEND_ROCM
        }
    }
}

/// ggml's vendor-agnostic class for a compute device, orthogonal to
/// `Device.kind` (which carries the vendor). Backends report this classification
/// themselves, so use it as a runtime hint rather than a portable
/// hardware-memory taxonomy.
public enum DeviceType: Sendable, Equatable {
    case cpu
    case gpu
    case igpu
    case accel
    /// A device-type value this binding does not recognize — reported by a
    /// runtime newer than the header this binding was built against.
    /// Distinguish such devices by `Device.deviceId` / `Device.name`, not by
    /// this axis.
    case unknown

    init(_ c: transcribe_device_type) {
        switch c.rawValue {
        case TRANSCRIBE_DEVICE_TYPE_CPU.rawValue: self = .cpu
        case TRANSCRIBE_DEVICE_TYPE_GPU.rawValue: self = .gpu
        case TRANSCRIBE_DEVICE_TYPE_IGPU.rawValue: self = .igpu
        case TRANSCRIBE_DEVICE_TYPE_ACCEL.rawValue: self = .accel
        default: self = .unknown
        }
    }
}

/// A registered compute device.
public struct Device: @unchecked Sendable, Equatable {
    /// ggml device name, e.g. "Metal".
    public let name: String
    /// Human-readable description, e.g. "Apple M4 Max".
    public let description: String
    /// Classified vendor kind string, e.g. "cpu", "metal", "vulkan", "cuda", "rocm".
    public let kind: String
    /// The CPU/GPU/IGPU/ACCEL axis, orthogonal to `kind`.
    public let deviceType: DeviceType
    /// Stable hardware id (PCI bus id) when the backend reports one, else nil
    /// (e.g. Metal).
    public let deviceId: String?
    /// Reported device memory capacity in bytes, or 0 if unreported.
    public let memoryTotal: UInt64
    /// Available device memory in bytes — a snapshot at query time, or 0 if
    /// unreported. Re-query (`TranscribeCpp.devices()` or `Model.device`) to
    /// refresh; backend-defined and not comparable across device kinds.
    public let memoryFree: UInt64
    /// Process-local registry index for display. Pass this `Device` through
    /// `ModelOptions(device:)` for exact selection; persist `deviceId` instead.
    public let index: Int?
    let handle: transcribe_device_t

    /// Build from the raw C struct the library filled. `index` is the registry
    /// index when the device came from enumeration, else nil.
    init(_ raw: transcribe_device_info, handle: transcribe_device_t, index: Int? = nil) {
        name = raw.name.map { String(cString: $0) } ?? ""
        description = raw.description.map { String(cString: $0) } ?? ""
        kind = raw.kind.map { String(cString: $0) } ?? ""
        deviceType = DeviceType(raw.device_type)
        deviceId = raw.device_id.map { String(cString: $0) }
        memoryTotal = raw.memory_total
        memoryFree = raw.memory_free
        self.index = index
        self.handle = handle
    }

    public static func == (lhs: Device, rhs: Device) -> Bool {
        lhs.handle == rhs.handle
    }
}

/// A public ABI struct, for the no-model layout-liveness check. Mirrors the
/// `transcribe_abi_struct` enum (only the members the bindings introspect).
public enum AbiStruct: Sendable {
    case modelLoadParams
    case sessionParams
    case runParams
    case streamParams
    case capabilities
    case timings
    case segment
    case word
    case token
    case streamUpdate
    case streamText
    case sessionLimits
    case ext
    case deviceInfo

    var cValue: transcribe_abi_struct {
        switch self {
        case .modelLoadParams: return TRANSCRIBE_ABI_MODEL_LOAD_PARAMS
        case .sessionParams: return TRANSCRIBE_ABI_SESSION_PARAMS
        case .runParams: return TRANSCRIBE_ABI_RUN_PARAMS
        case .streamParams: return TRANSCRIBE_ABI_STREAM_PARAMS
        case .capabilities: return TRANSCRIBE_ABI_CAPABILITIES
        case .timings: return TRANSCRIBE_ABI_TIMINGS
        case .segment: return TRANSCRIBE_ABI_SEGMENT
        case .word: return TRANSCRIBE_ABI_WORD
        case .token: return TRANSCRIBE_ABI_TOKEN
        case .streamUpdate: return TRANSCRIBE_ABI_STREAM_UPDATE
        case .streamText: return TRANSCRIBE_ABI_STREAM_TEXT
        case .sessionLimits: return TRANSCRIBE_ABI_SESSION_LIMITS
        case .ext: return TRANSCRIBE_ABI_EXT
        case .deviceInfo: return TRANSCRIBE_ABI_DEVICE_INFO
        }
    }
}
