// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClipCollections",
    platforms: [.macOS(.v14)],
    targets: [
        // The capture engine: web page -> clean PDF on this Mac. Shared by the app and the probe.
        .target(name: "ClipCapture", path: "Sources/ClipCapture", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ClipCollections", dependencies: ["ClipCapture"], path: "Sources/ClipCollections"),
        // Stage 1 command-line prototype: runs real links through the engine and reports what landed in the PDF.
        .executableTarget(name: "ClipProbe", dependencies: ["ClipCapture"], path: "Sources/ClipProbe"),
    ]
)
