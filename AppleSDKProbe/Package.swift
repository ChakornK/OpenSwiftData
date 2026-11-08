// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleSDKProbe",
    platforms: [.macOS(.v15)],
    targets: [
        .testTarget(name: "AppleSDKProbeTests")
    ],
    swiftLanguageModes: [.v6]
)
