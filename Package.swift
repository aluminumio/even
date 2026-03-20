// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "even",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "even", path: "Sources")
    ]
)
