import CTranscribe

// Public-ABI drift gate (requirements §2). Swift's Clang importer reads the C
// headers directly, so there is no generated FFI layer to regenerate — the gate
// is this PINNED hash, compared in CI against include/transcribe.abihash by
// scripts/ci/swift_abihash_check.py. When the header's ABI changes the neutral
// hash moves, the check goes red, and a maintainer bumps this constant after a
// CONSCIOUS review of what changed (then audits the wrapper for new/changed
// structs, enums, or entry points). The per-field struct-layout check is WAIVED
// because the Clang importer gets layout from a real compiler — same waiver as
// Rust/bindgen; the load-time base-version gate (Transcribe.ensureCompatible)
// remains.
extension Transcribe {
    /// sha256/16 of the normalized public FFI surface, pinned to the value in
    /// include/transcribe.abihash at the time this binding was last reviewed.
    public static let pinnedHeaderHash = "7df72bf9e667b8c2"

    /// The public-ABI digest this binding was reviewed against (16 hex chars).
    public static func headerHash() -> String { pinnedHeaderHash }
}
