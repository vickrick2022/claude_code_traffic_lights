// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeStatusGlow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ClaudeStatusGlow",
            targets: ["ClaudeStatusGlow"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ClaudeStatusGlow",
            path: "Sources/ClaudeStatusGlow"
        )
    ]
)
