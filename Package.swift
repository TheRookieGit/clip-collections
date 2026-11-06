// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NewsCollections",
    platforms: [.macOS(.v14)],
    targets: [
        // The capture engine: web page -> clean PDF on this Mac. Shared by the app and the probe.
        .target(name: "NewsCapture", path: "Sources/NewsCapture", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "NewsCollections", dependencies: ["NewsCapture"], path: "Sources/NewsCollections"),
        // Stage 1 command-line prototype: runs real links through the engine and reports what landed in the PDF.
        .executableTarget(name: "NewsProbe", dependencies: ["NewsCapture"], path: "Sources/NewsProbe"),
    ]
)
