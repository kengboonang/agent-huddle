// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentHuddle",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HuddleCore"),
        .executableTarget(name: "AgentHuddle", dependencies: ["HuddleCore"]),
        .testTarget(name: "HuddleCoreTests", dependencies: ["HuddleCore"]),
    ],
    swiftLanguageModes: [.v5]
)
