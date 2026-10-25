// swift-tools-version: 6.0
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "OpenSwiftData",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "OpenSwiftData", targets: ["OpenSwiftData"]),
        .library(name: "OpenSwiftDataSQLite", targets: ["OpenSwiftDataSQLite"]),
        .library(name: "OSDStorage", targets: ["OSDStorage"]),
        .library(name: "OSDQuery", targets: ["OSDQuery"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "604.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.2"),
    ],
    targets: [
        .target(
            name: "OSDCore",
            dependencies: [.product(name: "Logging", package: "swift-log")]
        ),
        .target(
            name: "OpenSwiftData",
            dependencies: ["OSDCore", "OpenSwiftDataMacros"]
        ),
        .target(
            name: "OSDStorage",
            dependencies: ["OSDCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "OpenSwiftDataSQLite",
            dependencies: ["OpenSwiftData", "OSDStorage"]
        ),
        .target(
            name: "OSDQuery",
            dependencies: ["OpenSwiftData"]
        ),
        .target(
            name: "OSDTestSupport",
            dependencies: ["OpenSwiftData"],
            path: "Tests/OSDTestSupport"
        ),
        .target(
            name: "OSDConformance",
            dependencies: [],
            path: "Tests/OSDConformance",
            resources: [.process("Goldens")]
        ),
        .macro(
            name: "OpenSwiftDataMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ],
            path: "Sources/OpenSwiftDataMacros"
        ),
        .testTarget(
            name: "OSDCoreTests",
            dependencies: ["OSDCore"]
        ),
        .testTarget(
            name: "OSDStorageTests",
            dependencies: ["OSDStorage"]
        ),
        .testTarget(
            name: "OpenSwiftDataSQLiteTests",
            dependencies: ["OpenSwiftData", "OpenSwiftDataSQLite", "OSDStorage"]
        ),
        .testTarget(
            name: "OpenSwiftDataTests",
            dependencies: ["OpenSwiftData", "OpenSwiftDataSQLite", "OSDTestSupport", "OSDConformance"]
        ),
        .testTarget(
            name: "OSDConformanceTests",
            dependencies: ["OSDConformance"]
        ),
        .testTarget(
            name: "OpenSwiftDataMacrosTests",
            dependencies: [
                "OpenSwiftData",
                "OpenSwiftDataMacros",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
