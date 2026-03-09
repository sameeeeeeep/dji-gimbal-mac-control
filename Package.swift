// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GimbalController",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GimbalController",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ProtocolTests",
            dependencies: ["GimbalController"],
            path: "Tests/ProtocolTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
