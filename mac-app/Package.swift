// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HandGestures",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "HandGestures", path: "Sources/HandGestures"),
        .testTarget(name: "HandGesturesTests", dependencies: ["HandGestures"], path: "Tests"),
    ]
)
