// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParityContracts",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ParityContracts", targets: ["ParityContracts"])],
    targets: [
        .target(name: "ParityContracts"),
        .testTarget(name: "ParityContractsTests", dependencies: ["ParityContracts"]),
    ],
    swiftLanguageModes: [.v6])
