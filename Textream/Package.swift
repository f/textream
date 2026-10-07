// swift-tools-version:5.9
import PackageDescription

// Test harness only: compiles the two Foundation-only source files from the app
// so they can be unit-tested with `swift test` (the Xcode project has no macOS test target).
let package = Package(
    name: "MarkdownScript",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "MarkdownScript",
            path: "Textream",
            sources: ["MarkdownScriptParser.swift", "LinkedScriptStore.swift"]
        ),
        .testTarget(
            name: "MarkdownScriptTests",
            dependencies: ["MarkdownScript"],
            path: "MarkdownScriptTests"
        ),
    ]
)
