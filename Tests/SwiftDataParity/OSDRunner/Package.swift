// swift-tools-version: 6.0
import PackageDescription

#if os(macOS)
let package = Package(
    name: "OpenSwiftDataParityRunner",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "osd-parity-runner", targets: ["OSDParityRunner"])],
    dependencies: [
        .package(path: "../../../"),
        .package(path: "../Contracts"),
    ],
    targets: [
        .target(
            name: "OSDParityRuntime",
            dependencies: [
                .product(name: "OpenSwiftData", package: "OpenSwiftData"),
                .product(name: "ParityContracts", package: "contracts"),
            ],
            path: "Sources/OSDParityRuntime"),
        .executableTarget(
            name: "OSDParityRunner",
            dependencies: ["OSDParityRuntime", .product(name: "ParityContracts", package: "contracts")],
            path: "Sources/OSDParityRunner"),
        .testTarget(
            name: "OSDParityRunnerTests",
            dependencies: ["OSDParityRuntime", .product(name: "ParityContracts", package: "contracts")],
            path: "Tests/OSDParityRunnerTests"),
    ],
    swiftLanguageModes: [.v6])
#else
let package = Package(
    name: "OpenSwiftDataParityRunner",
    platforms: [.macOS(.v14)],
    targets: [],
    swiftLanguageModes: [.v6])
#endif
