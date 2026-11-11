import Testing
import Foundation
import ParityApiCoverageRuntime
import ParityContracts

@Suite struct AllowlistValidatorEnforcementTests {
    private func makeSurfaceAndResult(coveredFqn: String? = nil) -> (surface: ExtractedSurface, result: CoverageResult) {
        let covered = API_Symbol(
            kind: .structKind, displayName: "Covered", fullyQualifiedName: coveredFqn ?? "SwiftData.Covered",
            sourceSignature: "public struct Covered", platformAvailability: PlatformAvailability(
                macOS: nil, iOS: nil, tvOS: nil, watchOS: nil, visionOS: nil, unavailable: false, deprecated: false),
            arity: 0, mangledName: "", deprecated: false)
        let uncovered = API_Symbol(
            kind: .enumKind, displayName: "Uncovered", fullyQualifiedName: "SwiftData.Uncovered",
            sourceSignature: "public enum Uncovered", platformAvailability: PlatformAvailability(
                macOS: nil, iOS: nil, tvOS: nil, watchOS: nil, visionOS: nil, unavailable: false, deprecated: false),
            arity: 0, mangledName: "", deprecated: false)
        let symbols = [covered, uncovered]
        let surface = ExtractedSurface(symbols: symbols, excludedCount: 0)
        let records = symbols.map { symbol in
            let isCovered = symbol.fullyQualifiedName == (coveredFqn ?? "SwiftData.Covered")
            return SymbolRecord(
                kind: symbol.kind.rawValue, displayName: symbol.displayName,
                fullyQualifiedName: symbol.fullyQualifiedName, sourceSignature: symbol.sourceSignature,
                platformAvailability: symbol.platformAvailability, covered: isCovered,
                referenceCount: isCovered ? 1 : 0, references: [],
                allowlisted: false, allowlistReasonCategory: nil, allowlistRationale: nil,
                allowlistIssueURL: nil, mangledName: "")
        }
        let result = CoverageResult(
            symbols: records, coveredSymbolCount: 1, uncoveredSymbolCount: 1,
            excludedCount: 0, surface: surface)
        return (surface, result)
    }

    @Test func emptyAllowlistWithUncoveredSymbolIsInvalid() throws {
        let (_, result) = makeSurfaceAndResult()
        let evaluationDate = try EvaluationDate(gregorianDay: "2026-11-10")
        let validation = AllowlistValidator.validate(entries: [], against: result, evaluationDate: evaluationDate)
        #expect(!validation.valid)
        let hasUncoveredIssue = validation.validationIssues.contains {
            $0 == "SwiftData.Uncovered: uncovered symbol has no allowlist entry"
        }
        #expect(hasUncoveredIssue)
    }

    @Test func matchingAllowlistWithUncoveredSymbolIsValid() throws {
        let (_, result) = makeSurfaceAndResult()
        let evaluationDate = try EvaluationDate(gregorianDay: "2026-11-10")
        let entry = AllowlistEntry(
            fullyQualifiedName: "SwiftData.Uncovered", kind: "enum",
            reasonCategory: "deferred-behavior-gap",
            rationale: "OpenSwiftData does not implement this symbol.",
            issueURL: "https://github.com/ChakornK/OpenSwiftData/issues/15",
            expiration: "2999-12-31")
        let validation = AllowlistValidator.validate(entries: [entry], against: result, evaluationDate: evaluationDate)
        #expect(validation.valid)
        let uncoveredIssue = validation.validationIssues.first {
            $0.contains("uncovered symbol has no allowlist entry")
        }
        #expect(uncoveredIssue == nil)
    }
}
