import Foundation

// Resolves the repository root, the SwiftData `.swiftinterface`, the SDK
// fingerprint, the scan roots, and the allowlist/report paths for a validator
// run. The interface is located by an ordered procedure: an explicit `--sdk`
// path, then `xcrun --show-sdk-path`, then the SwiftPM SDK artifact bundle.

public enum PathResolverError: Error, Equatable, Sendable, CustomStringConvertible {
    case repositoryRootNotFound
    case swiftInterfaceNotFound(searchedRoots: [String])

    public var description: String {
        switch self {
        case .repositoryRootNotFound:
            "repository root not found (no directory containing both Package.swift and Tests/OpenSwiftDataTests/Parity)"
        case let .swiftInterfaceNotFound(searchedRoots):
            "SwiftData.swiftinterface not found under any searched root:\n" + searchedRoots.map { "  - \($0)" }.joined(separator: "\n")
        }
    }
}

public enum PathResolver {
    /// Walks upward from `start` until a directory contains both `Package.swift`
    /// and `Tests/OpenSwiftDataTests/Parity`, mirroring `ParityValidate`'s logic.
    public static func locateRepositoryRoot(from start: URL) throws -> URL {
        var candidate = start.standardizedFileURL
        while candidate.path != "/" {
            let manifest = candidate.appending(path: "Package.swift")
            let parityTests = candidate.appending(path: "Tests/OpenSwiftDataTests/Parity")
            if FileManager.default.fileExists(atPath: manifest.path),
                FileManager.default.fileExists(atPath: parityTests.path)
            {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw PathResolverError.repositoryRootNotFound
    }

    /// Searches `sdkRoot` for a `SwiftData.swiftmodule/<arch>-apple-macos.swiftinterface`
    /// file. When multiple architecture variants are found, prefers `arm64e`,
    /// then `arm64`, then any other, then by lexicographic order of the arch prefix.
    public static func locateSwiftInterface(sdkRoot: URL) throws -> URL {
        let regex = try NSRegularExpression(pattern: #"/SwiftData\.swiftmodule/[^/]+-apple-macos\.swiftinterface$"#)
        var matches: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: sdkRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let path = url.path
                let range = NSRange(path.startIndex..., in: path)
                if regex.firstMatch(in: path, range: range) != nil {
                    matches.append(url)
                }
            }
        }
        guard !matches.isEmpty else {
            throw PathResolverError.swiftInterfaceNotFound(searchedRoots: [sdkRoot.path])
        }
        return matches.sorted { a, b in
            let archA = archPrefix(of: a)
            let archB = archPrefix(of: b)
            return (rank(for: archA), archA) < (rank(for: archB), archB)
        }.first!
    }

    /// Extracts the architecture prefix from a `.swiftinterface` path, i.e. the
    /// substring before `-apple-macos`.
    private static func archPrefix(of url: URL) -> String {
        let name = url.lastPathComponent
        if let range = name.range(of: "-apple-macos") {
            return String(name[..<range.lowerBound])
        }
        return name
    }

    /// Sort rank for an architecture prefix: `arm64e` → 0, `arm64` → 1, else → 2.
    private static func rank(for arch: String) -> Int {
        switch arch {
        case "arm64e": 0
        case "arm64": 1
        default: 2
        }
    }

    /// Resolves every input path for a validator run. The SDK root is derived
    /// by ordered fallback: explicit `--sdk`, then `xcrun --show-sdk-path`, then
    /// the SwiftPM SDK artifact bundle at `~/.swiftpm/swift-sdks/darwin.artifactbundle`.
    public static func resolve(
        strategy: Strategy,
        reportPath: String?,
        allowlistPath: String?,
        sdkPath: String?,
        today: String?
    ) throws -> ResolvedPaths {
        let repositoryRoot = try locateRepositoryRoot(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let paritySourceDirectory = repositoryRoot.appending(path: "Tests/OpenSwiftDataTests/Parity")

        var searchedRoots: [String] = []
        if let sdkPath {
            let candidate = URL(fileURLWithPath: sdkPath)
            do {
                let interface = try locateSwiftInterface(sdkRoot: candidate)
                return try finishResolve(
                    repositoryRoot: repositoryRoot,
                    paritySourceDirectory: paritySourceDirectory,
                    sdkRoot: candidate,
                    swiftInterfaceURL: interface,
                    strategy: strategy,
                    reportPath: reportPath,
                    allowlistPath: allowlistPath,
                    today: today
                )
            } catch PathResolverError.swiftInterfaceNotFound(let roots) {
                searchedRoots.append(contentsOf: roots)
            }
        }
        if let xcrunRoot = try? runXcrunShowSdkPath(), !xcrunRoot.path.isEmpty {
            do {
                let interface = try locateSwiftInterface(sdkRoot: xcrunRoot)
                return try finishResolve(
                    repositoryRoot: repositoryRoot,
                    paritySourceDirectory: paritySourceDirectory,
                    sdkRoot: xcrunRoot,
                    swiftInterfaceURL: interface,
                    strategy: strategy,
                    reportPath: reportPath,
                    allowlistPath: allowlistPath,
                    today: today
                )
            } catch PathResolverError.swiftInterfaceNotFound(let roots) {
                searchedRoots.append(contentsOf: roots)
            }
        }
        let bundleRoot = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".swiftpm/swift-sdks/darwin.artifactbundle")
        if FileManager.default.fileExists(atPath: bundleRoot.path) {
            do {
                let interface = try locateSwiftInterface(sdkRoot: bundleRoot)
                return try finishResolve(
                    repositoryRoot: repositoryRoot,
                    paritySourceDirectory: paritySourceDirectory,
                    sdkRoot: bundleRoot,
                    swiftInterfaceURL: interface,
                    strategy: strategy,
                    reportPath: reportPath,
                    allowlistPath: allowlistPath,
                    today: today
                )
            } catch PathResolverError.swiftInterfaceNotFound(let roots) {
                searchedRoots.append(contentsOf: roots)
            }
        }
        throw PathResolverError.swiftInterfaceNotFound(searchedRoots: searchedRoots)
    }

    /// Builds the `ResolvedPaths` once the interface file is located.
    private static func finishResolve(
        repositoryRoot: URL,
        paritySourceDirectory: URL,
        sdkRoot: URL,
        swiftInterfaceURL: URL,
        strategy: Strategy,
        reportPath: String?,
        allowlistPath: String?,
        today: String?
    ) throws -> ResolvedPaths {
        let bytes = try Data(contentsOf: swiftInterfaceURL)
        let sdkFingerprint = SDKFingerprint(
            sdkPath: sdkRoot.path,
            swiftInterfaceSHA256: Hashing.sha256Hex(bytes),
            swiftInterfaceByteCount: bytes.count
        )
        let evaluationDate: EvaluationDate
        if let today {
            evaluationDate = try EvaluationDate(gregorianDay: today)
        } else {
            evaluationDate = EvaluationDate(date: Date())
        }
        let implementationDirectories = try discoverImplementationDirectories(repositoryRoot: repositoryRoot)
        let allowlistURL = allowlistPath.map { URL(fileURLWithPath: $0) }
            ?? repositoryRoot.appending(path: "Tests/SwiftDataParity/parity-api-coverage-allowlist.json")
        let reportURL = reportPath.map { URL(fileURLWithPath: $0) }
            ?? repositoryRoot.appending(path: "parity-api-coverage-report.json")
        return ResolvedPaths(
            repositoryRoot: repositoryRoot,
            paritySourceDirectory: paritySourceDirectory,
            implementationDirectories: implementationDirectories,
            allowlistURL: allowlistURL,
            reportURL: reportURL,
            swiftInterfaceURL: swiftInterfaceURL,
            sdkRoot: sdkRoot,
            sdkFingerprint: sdkFingerprint,
            evaluationDate: evaluationDate,
            strategy: strategy
        )
    }

    /// Lists direct subdirectories of `<root>/Sources` whose name does not start
    /// with `.`, sorted lexicographically. Discovered at runtime so new modules
    /// are picked up automatically.
    private static func discoverImplementationDirectories(repositoryRoot: URL) throws -> [URL] {
        let sourcesRoot = repositoryRoot.appending(path: "Sources")
        guard FileManager.default.fileExists(atPath: sourcesRoot.path) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.path < $1.path }
    }

    /// Invokes `/usr/bin/xcrun --show-sdk-path` and returns the trimmed stdout
    /// as a URL. Returns `nil` on any failure.
    private static func runXcrunShowSdkPath() throws -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--show-sdk-path"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : URL(fileURLWithPath: output)
    }
}
