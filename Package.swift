// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GimbalController",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "GimbalController",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ],
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
