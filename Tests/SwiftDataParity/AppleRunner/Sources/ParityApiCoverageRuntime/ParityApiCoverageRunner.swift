import Foundation
import ParityContracts

// The testable orchestration core for `parity-api-coverage`. All non-`main`
// logic lives here so the test target (which depends on the runtime, not the
// executable) can invoke `ParityApiCoverageRunner.run(args:)` directly.

public enum ParityApiCoverageRunner {
    /// The testable entry. Parses flags and runs the appropriate flow, returning
    /// the exit code without calling `exit`.
    public static func run(args: [String]) -> Int32 {
        var strategy = Strategy.nameMatch
        var reportPath: String?
        var allowlistPath: String?
        var sdkPath: String?
        var today: String?
        var checkOnly = false
        var skeletonPath: String?

        let valueFlags: Set<String> = [
            "--strategy", "--report", "--allowlist", "--sdk", "--today", "--emit-allowlist-skeleton",
        ]

        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--check-only" {
                checkOnly = true
                index += 1
                continue
            }
            guard valueFlags.contains(arg) else {
                FileHandle.standardError.write(Data("Unknown flag: \(arg)\n".utf8))
                return 6
            }
            guard index + 1 < args.count else {
                FileHandle.standardError.write(Data("Missing value for \(arg)\n".utf8))
                return 6
            }
            let value = args[index + 1]
            switch arg {
            case "--strategy":
                guard let parsed = Strategy(rawValue: value) else {
                    FileHandle.standardError.write(Data("Invalid --strategy: \(value)\n".utf8))
                    return 6
                }
                strategy = parsed
            case "--report": reportPath = value
            case "--allowlist": allowlistPath = value
            case "--sdk": sdkPath = value
            case "--today":
                do {
                    _ = try EvaluationDate(gregorianDay: value)
                } catch {
                    FileHandle.standardError.write(Data("Invalid --today: \(value)\n".utf8))
                    return 6
                }
                today = value
            case "--emit-allowlist-skeleton": skeletonPath = value
            default:
                FileHandle.standardError.write(Data("Unknown flag: \(arg)\n".utf8))
                return 6
            }
            index += 2
        }

        do {
            let resolved = try PathResolver.resolve(
                strategy: strategy,
                reportPath: reportPath,
                allowlistPath: allowlistPath,
                sdkPath: sdkPath,
                today: today
            )
            if checkOnly {
                return runCheckOnly(resolved: resolved)
            }
            if let skeletonPath {
                return runSkeleton(resolved: resolved, skeletonPath: skeletonPath)
            }
            return runNormal(resolved: resolved, strategy: strategy)
        } catch let caught {
            return reportError(caught)
        }
    }

    /// Maps a thrown error to an exit code and prints it to standard error.
    private static func reportError(_ error: Error) -> Int32 {
        let message = String(describing: error)
        switch error {
        case PathResolverError.swiftInterfaceNotFound:
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
            return 2
        case APISurfaceExtractorError.unparseableInterface:
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
            return 3
        case PathResolverError.repositoryRootNotFound:
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
            return 4
        default:
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
            return 1
        }
    }

    /// The normal coverage run: extract, scan, compute, allowlist, emit report.
    private static func runNormal(resolved: ResolvedPaths, strategy: Strategy) -> Int32 {
        var surface: ExtractedSurface
        do {
            surface = try APISurfaceExtractor.extract(interfaceFile: resolved.swiftInterfaceURL)
        } catch let caught {
            return reportError(caught)
        }

        var validationIssues: [String] = []
        if strategy == .signaturePrecise {
            runSymbolGraph(surface: &surface, sdkRoot: resolved.sdkRoot, validationIssues: &validationIssues)
        }

        let scanResult = ReferenceScanner.scan(
            roots: [resolved.paritySourceDirectory] + resolved.implementationDirectories,
            repositoryRoot: resolved.repositoryRoot,
            knownDisplayNames: surface.displayNames,
            knownTypeDisplayNames: Set(surface.symbols.filter { isTypeKind($0.kind) }.map { $0.displayName }),
            nameStoplist: NameStoplist.entries
        )
        validationIssues.append(contentsOf: scanResult.issues)

        let coverage = CoverageEngine.compute(surface: surface, references: scanResult.references, strategy: strategy)
        let (entries, loadIssues) = AllowlistValidator.loadEntries(from: resolved.allowlistURL)
        validationIssues.append(contentsOf: loadIssues)
        let allowlistValidation = AllowlistValidator.validate(entries: entries, against: coverage, evaluationDate: resolved.evaluationDate)
        validationIssues.append(contentsOf: allowlistValidation.validationIssues)

        let allowlistSHA256: String
        if FileManager.default.fileExists(atPath: resolved.allowlistURL.path) {
            allowlistSHA256 = Hashing.sha256Hex((try? CanonicalJSON.encode(entries)) ?? Data())
        } else {
            allowlistSHA256 = ""
        }

        let generatedAt = currentTimestamp()
        let coveredCount = allowlistValidation.annotatedSymbols.filter(\.covered).count
        let uncoveredCount = allowlistValidation.annotatedSymbols.filter { !$0.covered }.count
        let structural = ReportValidator.structuralIssues(report: APICoverageReport(
            schemaVersion: 1,
            strategy: strategy.rawValue,
            sdkFingerprint: resolved.sdkFingerprint,
            evaluationDate: resolved.evaluationDate.gregorianDay,
            generatedAt: generatedAt,
            totalSymbolCount: allowlistValidation.annotatedSymbols.count,
            coveredSymbolCount: coveredCount,
            uncoveredSymbolCount: uncoveredCount,
            excludedSymbolCount: coverage.excludedCount,
            coverageValid: allowlistValidation.valid,
            allowlistSHA256: allowlistSHA256,
            validationIssues: validationIssues,
            symbols: allowlistValidation.annotatedSymbols
        ))
        validationIssues.append(contentsOf: structural)
        let coverageValid = allowlistValidation.valid && structural.isEmpty

        let report = APICoverageReport(
            schemaVersion: 1,
            strategy: strategy.rawValue,
            sdkFingerprint: resolved.sdkFingerprint,
            evaluationDate: resolved.evaluationDate.gregorianDay,
            generatedAt: generatedAt,
            totalSymbolCount: allowlistValidation.annotatedSymbols.count,
            coveredSymbolCount: coveredCount,
            uncoveredSymbolCount: uncoveredCount,
            excludedSymbolCount: coverage.excludedCount,
            coverageValid: coverageValid,
            allowlistSHA256: allowlistSHA256,
            validationIssues: validationIssues.sorted(),
            symbols: allowlistValidation.annotatedSymbols
        )
        do {
            try ReportEmitter.emit(report, to: resolved.reportURL)
        } catch let caught {
            FileHandle.standardError.write(Data("Error writing report: \(String(describing: caught))\n".utf8))
            return 1
        }
        if coverageValid {
            let allowlistedCount = report.symbols.filter(\.allowlisted).count
            print("API coverage complete: \(coveredCount)/\(report.totalSymbolCount) symbols covered (\(allowlistedCount) allowlisted, \(coverage.excludedCount) excluded).")
            return 0
        } else {
            let sortedIssues = report.validationIssues
            FileHandle.standardError.write(Data("API coverage invalid: \(sortedIssues.count) issue(s) found.\n".utf8))
            for issue in sortedIssues.prefix(20) {
                FileHandle.standardError.write(Data("\(issue)\n".utf8))
            }
            if sortedIssues.count > 20 {
                FileHandle.standardError.write(Data("... and \(sortedIssues.count - 20) more\n".utf8))
            }
            return 1
        }
    }

    /// Runs `swift symbolgraph-extract` for the `signature-precise` strategy and
    /// joins the resulting USRs into `surface`. On failure or an empty join,
    /// appends a `signature-strategy-fallback` issue.
    private static func runSymbolGraph(surface: inout ExtractedSurface, sdkRoot: URL, validationIssues: inout [String]) {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "parity-sg-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            validationIssues.append("signature-strategy-fallback")
            return
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "arm64"
        #endif
        let triple = "\(arch)-apple-macos15.0"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [
            "symbolgraph-extract", "-module-name", "SwiftData", "-sdk", sdkRoot.path,
            "-output-dir", tempDir.path, "-target", triple, "-minimum-access-level", "public",
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            validationIssues.append("signature-strategy-fallback")
            return
        }
        guard process.terminationStatus == 0 else {
            validationIssues.append("signature-strategy-fallback")
            return
        }
        APISurfaceExtractor.joinSymbolGraph(&surface, symbolGraphDirectory: tempDir)
        if surface.symbolsByMangledName.isEmpty {
            validationIssues.append("signature-strategy-fallback")
        }
    }

    /// The `--check-only` flow: loads an existing report and recomputes
    /// `coverageValid` against the current allowlist and evaluation date.
    private static func runCheckOnly(resolved: ResolvedPaths) -> Int32 {
        guard FileManager.default.fileExists(atPath: resolved.reportURL.path) else {
            FileHandle.standardError.write(Data("Report not found: \(resolved.reportURL.path)\n".utf8))
            return 5
        }
        let report: APICoverageReport
        do {
            report = try ReportEmitter.load(from: resolved.reportURL)
        } catch let caught {
            FileHandle.standardError.write(Data("Error loading report: \(String(describing: caught))\n".utf8))
            return 1
        }
        let (entries, loadIssues) = AllowlistValidator.loadEntries(from: resolved.allowlistURL)
        let currentSHA: String
        if FileManager.default.fileExists(atPath: resolved.allowlistURL.path) {
            currentSHA = Hashing.sha256Hex((try? CanonicalJSON.encode(entries)) ?? Data())
        } else {
            currentSHA = ""
        }
        let recomputed = AllowlistValidator.recomputeValid(
            symbols: report.symbols,
            entries: entries,
            evaluationDate: resolved.evaluationDate
        )
        let structural = ReportValidator.structuralIssues(report: report)
        var mismatches: [String] = []
        if recomputed != report.coverageValid {
            mismatches.append("coverageValid drift")
        }
        mismatches.append(contentsOf: structural)
        if currentSHA != report.allowlistSHA256 {
            mismatches.append("allowlist drift")
        }
        for entry in entries where !report.symbols.contains(where: { $0.fullyQualifiedName == entry.fullyQualifiedName }) {
            mismatches.append("stale allowlist entry: \(entry.fullyQualifiedName)")
        }
        mismatches.append(contentsOf: loadIssues)
        if mismatches.isEmpty {
            print("Report valid.")
            return 0
        } else {
            FileHandle.standardError.write(Data("Check failed:\n".utf8))
            for mismatch in mismatches.prefix(20) {
                FileHandle.standardError.write(Data("- \(mismatch)\n".utf8))
            }
            if mismatches.count > 20 {
                FileHandle.standardError.write(Data("... and \(mismatches.count - 20) more\n".utf8))
            }
            return 1
        }
    }

    /// The `--emit-allowlist-skeleton` flow: extracts, scans, computes, then
    /// writes one stub entry per uncovered symbol (deduplicated by
    /// `(fullyQualifiedName, kind)`). Does not write a report.
    private static func runSkeleton(resolved: ResolvedPaths, skeletonPath: String) -> Int32 {
        var surface: ExtractedSurface
        do {
            surface = try APISurfaceExtractor.extract(interfaceFile: resolved.swiftInterfaceURL)
        } catch let caught {
            return reportError(caught)
        }
        let scanResult = ReferenceScanner.scan(
            roots: [resolved.paritySourceDirectory] + resolved.implementationDirectories,
            repositoryRoot: resolved.repositoryRoot,
            knownDisplayNames: surface.displayNames,
            knownTypeDisplayNames: Set(surface.symbols.filter { isTypeKind($0.kind) }.map { $0.displayName }),
            nameStoplist: NameStoplist.entries
        )
        _ = scanResult.issues
        let coverage = CoverageEngine.compute(surface: surface, references: scanResult.references, strategy: .nameMatch)
        let uncovered = coverage.symbols.filter { !$0.covered }
        var seen = Set<String>()
        var skeleton: [AllowlistEntry] = []
        for record in uncovered {
            let key = "\(record.fullyQualifiedName)#\(record.kind)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            skeleton.append(AllowlistEntry(
                fullyQualifiedName: record.fullyQualifiedName,
                kind: record.kind,
                reasonCategory: "deferred-behavior-gap",
                rationale: "TODO: explain why this symbol is intentionally not implemented.",
                issueURL: "https://example.invalid/TODO",
                expiration: "2999-12-31"
            ))
        }
        do {
            let data = try CanonicalJSON.encode(AllowlistFile(symbols: skeleton))
            try data.write(to: URL(fileURLWithPath: skeletonPath), options: .atomic)
        } catch let caught {
            FileHandle.standardError.write(Data("Error writing skeleton: \(String(describing: caught))\n".utf8))
            return 1
        }
        return 0
    }

    /// The current UTC timestamp as `YYYY-MM-DDTHH:MM:SSZ`.
    private static func currentTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }

    /// Returns `true` for `SymbolKind`s that declare a type.
    private static func isTypeKind(_ kind: SymbolKind) -> Bool {
        switch kind {
        case .structKind, .classKind, .enumKind, .protocolKind, .actorKind: true
        default: false
        }
    }
}
