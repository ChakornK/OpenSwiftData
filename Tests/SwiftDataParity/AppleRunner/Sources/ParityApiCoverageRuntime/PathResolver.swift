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
        // Resolve the SDK root symlink (e.g. `MacOSX26.5.sdk` → `MacOSX.sdk`)
        // so `FileManager.enumerator` traverses the real directory tree.
        let resolvedRoot: URL
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: sdkRoot.path) {
            let targetURL = URL(fileURLWithPath: target, isDirectory: true)
            resolvedRoot = targetURL.path.hasPrefix("/") ? targetURL : sdkRoot.deletingLastPathComponent().appending(path: target)
        } else {
            resolvedRoot = sdkRoot
        }
        let regex = try NSRegularExpression(pattern: #"/SwiftData\.swiftmodule/[^/]+-apple-macos\.swiftinterface$"#)
        var matches: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
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
            throw PathResolverError.swiftInterfaceNotFound(searchedRoots: [resolvedRoot.path])
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

    /// Resolves only the paths needed for `--check-only`: repository root,
    /// allowlist, report, and evaluation date. Does NOT locate the
    /// SwiftInterface or compute the SDK fingerprint. Used by `--check-only`
    /// which re-evaluates an existing report without re-extracting the surface.
    public static func resolveForCheckOnly(
        reportPath: String?,
        allowlistPath: String?,
        today: String?
    ) throws -> ResolvedPaths {
        let repositoryRoot = try locateRepositoryRoot(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let paritySourceDirectory = repositoryRoot.appending(path: "Tests/OpenSwiftDataTests/Parity")
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
        // The interface and SDK fingerprint are not used by `--check-only`; fill
        // with placeholders so `ResolvedPaths` is complete.
        let placeholder = SDKFingerprint(sdkPath: "", swiftInterfaceSHA256: "", swiftInterfaceByteCount: 0)
        return ResolvedPaths(
            repositoryRoot: repositoryRoot,
            paritySourceDirectory: paritySourceDirectory,
            implementationDirectories: implementationDirectories,
            allowlistURL: allowlistURL,
            reportURL: reportURL,
            swiftInterfaceURL: repositoryRoot,
            sdkRoot: repositoryRoot,
            sdkFingerprint: placeholder,
            evaluationDate: evaluationDate,
            strategy: .nameMatch
        )
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
    /// as a URL. Returns `nil` on any failure. Also checks the `SDKROOT`
    /// environment variable (resolved against `DEVELOPER_DIR` when relative)
    /// and `xcode-select -p` derived paths as fallbacks.
    private static func runXcrunShowSdkPath() throws -> URL? {
        // Fast path: `SDKROOT` is set by `xcrun` and the shell environment.
        // Only use it directly when it points to an existing absolute path;
        // resolve a relative SDKROOT against `DEVELOPER_DIR`.
        if let sdkroot = ProcessInfo.processInfo.environment["SDKROOT"], !sdkroot.isEmpty {
            if sdkroot.hasPrefix("/") && FileManager.default.fileExists(atPath: sdkroot) {
                return URL(fileURLWithPath: sdkroot)
            }
            if let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !developerDir.isEmpty {
                let resolved = "\(developerDir)/Platforms/MacOSX.platform/Developer/SDKs/\(sdkroot)"
                if FileManager.default.fileExists(atPath: resolved) {
                    return URL(fileURLWithPath: resolved)
                }
            }
        }
        // Try `xcrun --show-sdk-path` via Process. `SDKROOT` is cleared in the
        // subprocess environment so xcrun resolves the real SDK.
        if let path = runProcess(executable: "/usr/bin/xcrun", arguments: ["--show-sdk-path"]),
            path.hasPrefix("/"),
            FileManager.default.fileExists(atPath: path)
        {
            return URL(fileURLWithPath: path)
        }
        // Fallback: derive the SDK path from `DEVELOPER_DIR` or `xcode-select -p`.
        let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? runProcess(executable: "/usr/bin/xcode-select", arguments: ["-p"]) ?? ""
        if !developerDir.isEmpty {
            let sdkPath = "\(developerDir)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
            if FileManager.default.fileExists(atPath: sdkPath) {
                return URL(fileURLWithPath: sdkPath)
            }
        }
        return nil
    }

    /// Runs a process and returns its trimmed stdout, or nil on failure.
    /// Clears `SDKROOT` from the environment so `xcrun` resolves the default
    /// SDK rather than echoing back a relative `SDKROOT` set by SwiftPM.
    private static func runProcess(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Remove `SDKROOT` so `xcrun --show-sdk-path` resolves the real SDK.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SDKROOT")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
    }
}
