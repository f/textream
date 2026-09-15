// swift-tools-version: 5.9
import PackageDescription

// transcribe.cpp Swift bindings (`TranscribeCpp`).
//
// Vendored from https://github.com/handy-computer/transcribe.cpp at v0.2.3
// (bindings/swift). The native library ships as the release xcframework
// binaryTarget, pinned by URL + checksum; Metal is embedded on the macOS arm64
// slice (CPU-only on x86_64), matching the postures documented upstream.
//
// To upgrade: bump the URL tag and the checksum (shasum -a 256 of the release
// zip), then refresh Sources/TranscribeCpp from the same tag.
let package = Package(
    name: "TranscribeCpp",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "TranscribeCpp", targets: ["TranscribeCpp"]),
    ],
    targets: [
        // The prebuilt native artifact. Module `CTranscribe` (per the bundled
        // module.modulemap) is the raw C surface.
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.2.3/TranscribeCpp.xcframework.zip",
            checksum: "944be4d5232f39c99608f676a2ddda2516e0ed3c9fb6db50685ffa8d20a8b9c9"
        ),

        // The idiomatic Swift wrapper. System libs/frameworks that the merged
        // native archive does NOT carry are linked here (the canonical set
        // comes from upstream's transcribe-link.json).
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
    ]
)
