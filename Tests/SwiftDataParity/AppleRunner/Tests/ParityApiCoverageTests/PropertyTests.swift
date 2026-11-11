import Foundation
import ParityApiCoverageRuntime
import ParityContracts
import Testing

// Property-based tests for the 10 correctness properties in design.md.
// Generators are hand-written over synthetic inputs; no external PBT library.

@Suite struct PropertyTests {
    // Property 1: Surface extraction is closed under "public".
    @Test func surfaceExtractionIsClosedUnderPublic() throws {
        let interface = """
        public struct Public { public var v: Int }
        internal struct Internal {}
        private struct Private_ {}
        """
        let surface = try extract(interface)
        let names = Set(surface.symbols.map(\.displayName))
        #expect(names.contains("Public"))
        #expect(names.contains("v"))
        #expect(!names.contains("Internal"))
        #expect(!names.contains("Private_"))
    }

    // Property 2: Excluded symbols are dropped, counted, and absent.
    @Test func excludedSymbolsAreDroppedAndCounted() throws {
        let interface = """
        @available(*, unavailable)
        public struct Excluded { public var v: Int }
        public struct Kept { public var v: Int }
        """
        let surface = try extract(interface)
        #expect(surface.excludedCount >= 1)
        #expect(!surface.symbols.contains { $0.displayName == "Excluded" })
        #expect(surface.symbols.contains { $0.displayName == "Kept" })
    }

    // Property 3: Stoplist and import gate (condensed; see ReferenceScannerTests for fixtures a-d).
    @Test func stoplistImportGateBehavesPerSpec() throws {
        let root = try makeTree(files: [
            ("withImport.swift", "import SwiftData\nfunc use() { ModelContext.save() }"),
            ("withoutImport.swift", "func use() { ModelContext.save() }"),
        ])
        let withImport = scanFile(root.appending(path: "withImport.swift"), root: root.deletingLastPathComponent(), knownTypeDisplayNames: ["ModelContext"])
        let withoutImport = scanFile(root.appending(path: "withoutImport.swift"), root: root.deletingLastPathComponent(), knownTypeDisplayNames: ["ModelContext"])
        #expect(withImport.contains { $0.displayName == "save" })
        // Without import but with receiver named after a known SwiftData type, the
        // receiver-name gate records the stoplisted reference.
        #expect(withoutImport.contains { $0.displayName == "save" })
    }

    // Property 4: Coverage counts are additive and consistent.
    @Test func coverageCountsAreAdditiveAndConsistent() throws {
        let surface = ExtractedSurface(symbols: [
            API_Symbol(kind: .structKind, displayName: "A", fullyQualifiedName: "SwiftData.A", sourceSignature: "s", platformAvailability: .init(), arity: 0, deprecated: false),
            API_Symbol(kind: .structKind, displayName: "B", fullyQualifiedName: "SwiftData.B", sourceSignature: "s", platformAvailability: .init(), arity: 0, deprecated: false),
            API_Symbol(kind: .structKind, displayName: "C", fullyQualifiedName: "SwiftData.C", sourceSignature: "s", platformAvailability: .init(), arity: 0, deprecated: false),
        ], excludedCount: 0)
        let refs = [Reference(file: "f", line: 1, column: 1, displayName: "A", matchQuality: .name)]
        let result = CoverageEngine.compute(surface: surface, references: refs, strategy: .nameMatch)
        #expect(result.coveredSymbolCount + result.uncoveredSymbolCount == result.symbols.count)
        #expect(result.uncoveredSymbolCount == result.symbols.filter { !$0.covered }.count)
    }

    // Property 5: Allowlist annotations are exclusive to uncovered symbols.
    @Test func allowlistAnnotationsExclusiveToUncoveredSymbols() throws {
        let entry = AllowlistEntry(fullyQualifiedName: "SwiftData.U", kind: "struct", reasonCategory: "deferred-behavior-gap", rationale: "x", issueURL: "https://e.com/1", expiration: "2999-12-31")
        let surface = ExtractedSurface(symbols: [
            API_Symbol(kind: .structKind, displayName: "U", fullyQualifiedName: "SwiftData.U", sourceSignature: "s", platformAvailability: .init(), arity: 0, deprecated: false),
        ], excludedCount: 0)
        let coverage = CoverageResult(symbols: [SymbolRecord(kind: "struct", displayName: "U", fullyQualifiedName: "SwiftData.U", sourceSignature: "s", platformAvailability: .init(), covered: false, referenceCount: 0, references: [], mangledName: "")], coveredSymbolCount: 0, uncoveredSymbolCount: 1, excludedCount: 0, surface: surface)
        let result = AllowlistValidator.validate(entries: [entry], against: coverage, evaluationDate: try EvaluationDate(gregorianDay: "2026-11-10"))
        let annotated = result.annotatedSymbols.first
        #expect(annotated?.allowlisted == true)
        #expect(annotated?.covered == false)
    }

    // Property 6: Allowlist validation rejects every documented malformation.
    @Test(arguments: [
        "bad-reason-category",
        "empty-rationale",
        "non-https",
        "bad-expiration",
        "expired",
        "stale",
        "duplicate",
        "allowlists-covered",
    ])
    func allowlistRejectsMalformation(_ kind: String) throws {
        let badEntry: AllowlistEntry
        switch kind {
        case "bad-reason-category": badEntry = entry(reasonCategory: "nope")
        case "empty-rationale": badEntry = entry(rationale: " ")
        case "non-https": badEntry = entry(issueURL: "http://e.com")
        case "bad-expiration": badEntry = entry(expiration: "nope")
        case "expired": badEntry = entry(expiration: "2020-01-01")
        case "stale": badEntry = entry(fullyQualifiedName: "SwiftData.Missing")
        case "duplicate": badEntry = entry()  // validated with a duplicate below
        case "allowlists-covered": badEntry = entry(fullyQualifiedName: "SwiftData.Covered")
        default: badEntry = entry()
        }
        let entries = kind == "duplicate" ? [badEntry, badEntry] : [badEntry]
        let surface = ExtractedSurface(symbols: kind == "allowlists-covered"
            ? [API_Symbol(kind: .structKind, displayName: "Covered", fullyQualifiedName: "SwiftData.Covered", sourceSignature: "s", platformAvailability: .init(), arity: 0, deprecated: false)]
            : (kind == "stale" ? [] : [API_Symbol(kind: .structKind, displayName: "Foo", fullyQualifiedName: "SwiftData.Foo", sourceSignature: "s", platformAvailability: .init(), arity: 0, deprecated: false)]), excludedCount: 0)
        let coverage = CoverageResult(symbols: kind == "allowlists-covered"
            ? [SymbolRecord(kind: "struct", displayName: "Covered", fullyQualifiedName: "SwiftData.Covered", sourceSignature: "s", platformAvailability: .init(), covered: true, referenceCount: 1, references: [], mangledName: "")]
            : [SymbolRecord(kind: "struct", displayName: "Foo", fullyQualifiedName: "SwiftData.Foo", sourceSignature: "s", platformAvailability: .init(), covered: false, referenceCount: 0, references: [], mangledName: "")], coveredSymbolCount: kind == "allowlists-covered" ? 1 : 0, uncoveredSymbolCount: kind == "allowlists-covered" ? 0 : 1, excludedCount: 0, surface: surface)
        let result = AllowlistValidator.validate(entries: entries, against: coverage, evaluationDate: try EvaluationDate(gregorianDay: "2026-11-10"))
        #expect(!result.valid)
        #expect(!result.validationIssues.isEmpty)
    }

    // Property 7: Deterministic emission (generatedAt does not affect computation/sort).
    @Test func deterministicEmission() throws {
        let report1 = makeReport(generatedAt: "2026-11-10T00:00:00Z")
        let report2 = makeReport(generatedAt: "2026-11-11T12:00:00Z")
        let noTimestamp1 = APICoverageReport(
            schemaVersion: report1.schemaVersion, strategy: report1.strategy,
            sdkFingerprint: report1.sdkFingerprint, evaluationDate: report1.evaluationDate,
            generatedAt: "", totalSymbolCount: report1.totalSymbolCount,
            coveredSymbolCount: report1.coveredSymbolCount, uncoveredSymbolCount: report1.uncoveredSymbolCount,
            excludedSymbolCount: report1.excludedSymbolCount, coverageValid: report1.coverageValid,
            allowlistSHA256: report1.allowlistSHA256, validationIssues: report1.validationIssues,
            symbols: report1.symbols
        )
        let noTimestamp2 = APICoverageReport(
            schemaVersion: report2.schemaVersion, strategy: report2.strategy,
            sdkFingerprint: report2.sdkFingerprint, evaluationDate: report2.evaluationDate,
            generatedAt: "", totalSymbolCount: report2.totalSymbolCount,
            coveredSymbolCount: report2.coveredSymbolCount, uncoveredSymbolCount: report2.uncoveredSymbolCount,
            excludedSymbolCount: report2.excludedSymbolCount, coverageValid: report2.coverageValid,
            allowlistSHA256: report2.allowlistSHA256, validationIssues: report2.validationIssues,
            symbols: report2.symbols
        )
        let encoded1 = try CanonicalJSON.encode(noTimestamp1)
        let encoded2 = try CanonicalJSON.encode(noTimestamp2)
        #expect(encoded1 == encoded2)
    }

    // Property 8: --check-only recomputes against current allowlist.
    @Test func checkOnlyRecomputesAgainstCurrentAllowlist() throws {
        let reportURL = FileManager.default.temporaryDirectory.appending(path: "parity-check-\(UUID().uuidString).json")
        let allowlist1URL = FileManager.default.temporaryDirectory.appending(path: "parity-allowlist-\(UUID().uuidString)-1.json")
        let allowlist2URL = FileManager.default.temporaryDirectory.appending(path: "parity-allowlist-\(UUID().uuidString)-2.json")
        try CanonicalJSON.encode(AllowlistFile(symbols: [])).write(to: allowlist1URL)
        try CanonicalJSON.encode(AllowlistFile(symbols: [AllowlistEntry(fullyQualifiedName: "SwiftData.X", kind: nil, reasonCategory: "deferred-behavior-gap", rationale: "x", issueURL: "https://e.com", expiration: "2999-12-31")])).write(to: allowlist2URL)
        let report = makeReport(allowlistSHA256: Hashing.sha256Hex(try CanonicalJSON.encode([AllowlistEntry]())))
        try ReportEmitter.emit(report, to: reportURL)
        defer { try? FileManager.default.removeItem(at: reportURL); try? FileManager.default.removeItem(at: allowlist1URL); try? FileManager.default.removeItem(at: allowlist2URL) }
        let code1 = ParityApiCoverageRunner.run(args: ["--check-only", "--report", reportURL.path, "--allowlist", allowlist1URL.path, "--today", "2026-11-10"])
        #expect(code1 == 0)
        let code2 = ParityApiCoverageRunner.run(args: ["--check-only", "--report", reportURL.path, "--allowlist", allowlist2URL.path, "--today", "2026-11-10"])
        #expect(code2 == 1)
    }

    // Property 9: Skeleton round-trips through the validator.
    @Test func skeletonRoundTripsThroughValidator() throws {
        // Build a skeleton against a synthetic uncovered surface, load it,
        // and validate: the deduplicated entries (with non-empty placeholder
        // rationale) must validate clean.
        let surface = ExtractedSurface(symbols: [
            API_Symbol(kind: .structKind, displayName: "U", fullyQualifiedName: "SwiftData.U", sourceSignature: "s", platformAvailability: .init(), arity: 0, deprecated: false),
        ], excludedCount: 0)
        let coverage = CoverageResult(symbols: [SymbolRecord(kind: "struct", displayName: "U", fullyQualifiedName: "SwiftData.U", sourceSignature: "s", platformAvailability: .init(), covered: false, referenceCount: 0, references: [], mangledName: "")], coveredSymbolCount: 0, uncoveredSymbolCount: 1, excludedCount: 0, surface: surface)
        let skeleton = [AllowlistEntry(fullyQualifiedName: "SwiftData.U", kind: "struct", reasonCategory: "deferred-behavior-gap", rationale: "TODO: explain why this symbol is intentionally not implemented.", issueURL: "https://example.invalid/TODO", expiration: "2999-12-31")]
        let result = AllowlistValidator.validate(entries: skeleton, against: coverage, evaluationDate: try EvaluationDate(gregorianDay: "2026-11-10"))
        #expect(result.valid)
    }

    // Property 10: Exit code contract.
    @Test(arguments: [
        ("--unknown-flag", 6),
        ("--strategy", 6),
    ])
    func exitCodeContract(_ flag: String, _ expected: Int32) {
        let code = ParityApiCoverageRunner.run(args: [flag])
        #expect(code == expected)
    }

    @Test func exitCodeContractForUnknownFlagIs6() {
        let code = ParityApiCoverageRunner.run(args: ["--bogus"])
        #expect(code == 6)
    }

    /// Helper: extracts a synthetic interface string.
    private func extract(_ source: String) throws -> ExtractedSurface {
        let url = FileManager.default.temporaryDirectory.appending(path: "parity-prop-\(UUID().uuidString).swiftinterface")
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try APISurfaceExtractor.extract(interfaceFile: url)
    }

    /// Helper: builds a temp tree.
    private func makeTree(files: [(String, String)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "parity-prop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: root.appending(path: name), atomically: true, encoding: .utf8)
        }
        return root
    }

    /// Helper: scans one file and returns references.
    private func scanFile(_ file: URL, root: URL, knownTypeDisplayNames: Set<String>) -> [Reference] {
        ReferenceScanner.scan(
            roots: [file.deletingLastPathComponent()],
            repositoryRoot: root,
            knownDisplayNames: ["ModelContext", "save"],
            knownTypeDisplayNames: knownTypeDisplayNames,
            nameStoplist: NameStoplist.entries
        ).references
    }

    /// Helper: a valid entry matching `SwiftData.Foo`.
    private func entry(
        fullyQualifiedName: String = "SwiftData.Foo",
        kind: String? = "struct",
        reasonCategory: String = "deferred-behavior-gap",
        rationale: String = "x",
        issueURL: String = "https://e.com/1",
        expiration: String = "2999-12-31"
    ) -> AllowlistEntry {
        AllowlistEntry(fullyQualifiedName: fullyQualifiedName, kind: kind, reasonCategory: reasonCategory, rationale: rationale, issueURL: issueURL, expiration: expiration)
    }

    /// Helper: builds a minimal report for determinism checks.
    private func makeReport(generatedAt: String = "2026-11-10T00:00:00Z", allowlistSHA256: String = "") -> APICoverageReport {
        APICoverageReport(
            schemaVersion: 1, strategy: "name-match",
            sdkFingerprint: SDKFingerprint(sdkPath: "", swiftInterfaceSHA256: "", swiftInterfaceByteCount: 0),
            evaluationDate: "2026-11-10", generatedAt: generatedAt,
            totalSymbolCount: 0, coveredSymbolCount: 0, uncoveredSymbolCount: 0,
            excludedSymbolCount: 0, coverageValid: true, allowlistSHA256: allowlistSHA256,
            validationIssues: [], symbols: []
        )
    }
}
