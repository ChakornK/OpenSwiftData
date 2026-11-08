// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleSwiftDataBehaviorValidation",
    platforms: [.macOS(.v15)],
    targets: [
        .testTarget(name: "AppleSwiftDataBehaviorValidationTests")
    ],
    swiftLanguageModes: [.v6]
)
