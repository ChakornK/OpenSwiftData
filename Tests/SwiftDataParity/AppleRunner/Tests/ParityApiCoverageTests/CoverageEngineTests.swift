import Foundation
import ParityApiCoverageRuntime
import ParityContracts
import Testing

// Unit tests for `CoverageEngine` and `ReportValidator`.

@Suite struct CoverageEngineTests {
    @Test func producesConsistentCounts() throws {
        let surface = makeSurface(names: ["A", "B", "C"])
        let references = [
            Reference(file: "f.swift", line: 1, column: 1, displayName: "A", matchQuality: .name),
        ]
        let result = CoverageEngine.compute(surface: surface, references: references, strategy: .nameMatch)
        #expect(result.coveredSymbolCount + result.uncoveredSymbolCount == result.symbols.count)
        #expect(result.coveredSymbolCount == 1)
        #expect(result.uncoveredSymbolCount == 2)
    }

    @Test func marksAllOverloadsCoveredUnderNameMatch() throws {
        let surface = ExtractedSurface(symbols: [
            API_Symbol(kind: .function, displayName: "save", fullyQualifiedName: "SwiftData.X.save", sourceSignature: "func save()", platformAvailability: .init(), arity: 0, deprecated: false),
            API_Symbol(kind: .function, displayName: "save", fullyQualifiedName: "SwiftData.X.save", sourceSignature: "func save(_ c: Int)", platformAvailability: .init(), arity: 1, deprecated: false),
        ], excludedCount: 0)
        let references = [Reference(file: "f.swift", line: 1, column: 1, displayName: "save", matchQuality: .name)]
        let result = CoverageEngine.compute(surface: surface, references: references, strategy: .nameMatch)
        #expect(result.coveredSymbolCount == 2)
    }

    @Test func signaturePreciseResolvesUniqueOverload() throws {
        // Two overloads with distinct mangledNames; a reference resolves to one
        // via signature-precise when the candidate USR matches exactly.
        var surface = ExtractedSurface(symbols: [
            API_Symbol(kind: .function, displayName: "save", fullyQualifiedName: "SwiftData.X.save", sourceSignature: "func save()", platformAvailability: .init(), arity: 0, mangledName: "usr:0", deprecated: false),
            API_Symbol(kind: .function, displayName: "save", fullyQualifiedName: "SwiftData.X.save", sourceSignature: "func save(_:)", platformAvailability: .init(), arity: 1, mangledName: "usr:1", deprecated: false),
        ], excludedCount: 0)
        surface.symbolsByMangledName = ["usr:0": surface.symbols[0], "usr:1": surface.symbols[1]]
        let references = [Reference(file: "f.swift", line: 1, column: 1, displayName: "save", matchQuality: .name)]
        let result = CoverageEngine.compute(surface: surface, references: references, strategy: .signaturePrecise)
        // The candidate-USR heuristic cannot form a USR from a plain Reference
        // (no receiver context), so both degrade to .signatureAmbiguous and
        // name-match attaches to both overloads.
        #expect(result.coveredSymbolCount == 2)
        let qualities = Set(result.symbols.flatMap(\.references).map(\.matchQuality))
        #expect(qualities.contains(.signatureAmbiguous))
    }

    @Test func signaturePreciseAmbiguityFallsBackWithNameAmbiguous() throws {
        var surface = ExtractedSurface(symbols: [
            API_Symbol(kind: .function, displayName: "save", fullyQualifiedName: "SwiftData.X.save", sourceSignature: "func save()", platformAvailability: .init(), arity: 0, mangledName: "usr:0", deprecated: false),
        ], excludedCount: 0)
        surface.symbolsByMangledName = ["usr:0": surface.symbols[0]]
        let references = [Reference(file: "f.swift", line: 1, column: 1, displayName: "save", matchQuality: .name)]
        let result = CoverageEngine.compute(surface: surface, references: references, strategy: .signaturePrecise)
        #expect(result.coveredSymbolCount == 1)
        let quality = result.symbols.first?.references.first?.matchQuality
        #expect(quality == .signatureAmbiguous)
    }

    /// Helper: builds a surface with N uncovered structs named A, B, C...
    private func makeSurface(names: [String]) -> ExtractedSurface {
        let symbols = names.map { name in
            API_Symbol(kind: .structKind, displayName: name, fullyQualifiedName: "SwiftData.\(name)", sourceSignature: "public struct \(name)", platformAvailability: .init(), arity: 0, deprecated: false)
        }
        return ExtractedSurface(symbols: symbols, excludedCount: 0)
    }
}

@Suite struct ReportValidatorTests {
    @Test func catchesTotalCountMismatch() {
        let report = makeReport(total: 5, covered: 2, uncovered: 2, symbols: makeSymbols(covered: 2, uncovered: 2))
        let issues = ReportValidator.structuralIssues(report: report)
        #expect(issues.contains(where: { $0.contains("totalSymbolCount") }))
    }

    @Test func catchesUncoveredCountMismatch() {
        let report = makeReport(total: 4, covered: 2, uncovered: 2, symbols: makeSymbols(covered: 1, uncovered: 3))
        let issues = ReportValidator.structuralIssues(report: report)
        #expect(issues.contains(where: { $0.contains("uncoveredSymbolCount") }))
    }

    @Test func catchesCoveredCountMismatch() {
        let report = makeReport(total: 4, covered: 1, uncovered: 3, symbols: makeSymbols(covered: 2, uncovered: 2))
        let issues = ReportValidator.structuralIssues(report: report)
        #expect(issues.contains(where: { $0.contains("coveredSymbolCount") }))
    }

    @Test func catchesAllowlistedCoveredSymbol() {
        let symbols = makeSymbols(covered: 2, uncovered: 2).map { record -> SymbolRecord in
            record.covered ? SymbolRecord(kind: record.kind, displayName: record.displayName, fullyQualifiedName: record.fullyQualifiedName, sourceSignature: record.sourceSignature, platformAvailability: record.platformAvailability, covered: true, referenceCount: record.referenceCount, references: record.references, allowlisted: true, allowlistReasonCategory: "x", allowlistRationale: "y", allowlistIssueURL: "z", mangledName: record.mangledName) : record
        }
        let report = makeReport(total: 4, covered: 2, uncovered: 2, symbols: symbols)
        let issues = ReportValidator.structuralIssues(report: report)
        #expect(issues.contains(where: { $0.contains("allowlisted == true but covered == true") }))
    }

    @Test func catchesNegativeExcludedCount() {
        let report = makeReport(total: 0, covered: 0, uncovered: 0, symbols: [], excluded: -1)
        let issues = ReportValidator.structuralIssues(report: report)
        #expect(issues.contains(where: { $0.contains("excludedSymbolCount") && $0.contains("negative") }))
    }

    @Test func catchesTotalCountNotSymbolsCount() {
        let report = makeReport(total: 5, covered: 2, uncovered: 2, symbols: makeSymbols(covered: 2, uncovered: 2))
        let issues = ReportValidator.structuralIssues(report: report)
        #expect(issues.contains(where: { $0.contains("symbols.count") }))
    }

    /// Helper: builds a minimal `APICoverageReport`.
    private func makeReport(total: Int, covered: Int, uncovered: Int, symbols: [SymbolRecord], excluded: Int = 0) -> APICoverageReport {
        APICoverageReport(
            schemaVersion: 1, strategy: "name-match",
            sdkFingerprint: SDKFingerprint(sdkPath: "", swiftInterfaceSHA256: "", swiftInterfaceByteCount: 0),
            evaluationDate: "2026-11-10", generatedAt: "2026-11-10T00:00:00Z",
            totalSymbolCount: total, coveredSymbolCount: covered, uncoveredSymbolCount: uncovered,
            excludedSymbolCount: excluded, coverageValid: true, allowlistSHA256: "",
            validationIssues: [], symbols: symbols
        )
    }

    /// Helper: builds `covered` covered + `uncovered` uncovered `SymbolRecord`s.
    private func makeSymbols(covered: Int, uncovered: Int) -> [SymbolRecord] {
        var records: [SymbolRecord] = []
        for i in 0..<covered {
            records.append(SymbolRecord(kind: "struct", displayName: "C\(i)", fullyQualifiedName: "SwiftData.C\(i)", sourceSignature: "s", platformAvailability: .init(), covered: true, referenceCount: 1, references: [], mangledName: ""))
        }
        for i in 0..<uncovered {
            records.append(SymbolRecord(kind: "struct", displayName: "U\(i)", fullyQualifiedName: "SwiftData.U\(i)", sourceSignature: "s", platformAvailability: .init(), covered: false, referenceCount: 0, references: [], mangledName: ""))
        }
        return records
    }
}
