// swift-tools-version: 6.0
import PackageDescription

#if os(macOS)
let package = Package(
    name: "AppleSwiftDataParityRunner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "apple-parity-runner", targets: ["AppleParityRunner"]),
        .executable(name: "parity-validate", targets: ["ParityValidate"]),
        .executable(name: "parity-compare", targets: ["ParityCompare"]),
    ],
    dependencies: [
        .package(path: "../Contracts"),
        .package(url: "https://github.com/apple/swift-syntax.git", from: "604.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AppleParityRunner",
            dependencies: [.product(name: "ParityContracts", package: "contracts")],
            path: "Sources/AppleParityRunner"),
        .executableTarget(
            name: "ParityValidate",
            dependencies: [
                .product(name: "ParityContracts", package: "contracts"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]),
        .executableTarget(
            name: "ParityCompare",
            dependencies: [.product(name: "ParityContracts", package: "contracts")],
            path: "Sources/ParityCompare"),
        .testTarget(
            name: "ParityToolTests",
            dependencies: [.product(name: "ParityContracts", package: "contracts")],
            path: "Tests/ParityToolTests"),
    ],
    swiftLanguageModes: [.v6])
#else
let package = Package(
    name: "AppleSwiftDataParityRunner",
    platforms: [.macOS(.v14)],
    targets: [],
    swiftLanguageModes: [.v6])
#endif
