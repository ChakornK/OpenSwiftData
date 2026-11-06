// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FoundationEssentialsShim",
    platforms: [.iOS(.v17)],
    products: [.library(name: "FoundationEssentials", targets: ["FoundationEssentials"])],
    targets: [.target(name: "FoundationEssentials")]
)
