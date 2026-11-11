import Foundation
import ParityApiCoverageRuntime
import ParityContracts
import Testing

// Unit tests for `AllowlistValidator`. Each test builds a synthetic
// `CoverageResult` and a set of `AllowlistEntry` values and asserts on the
// validation issues and annotations.

@Suite struct AllowlistValidatorTests {
    @Test func rejectsBadReasonCategory() throws {
        let entry = entry(reasonCategory: "not-a-real-category")
        let result = validate(entries: [entry])
        #expect(result.validationIssues.contains(where: { $0.contains("invalid reasonCategory") }))
        #expect(!result.valid)
    }

    @Test func rejectsEmptyRationale() throws {
        let entry = entry(rationale: "   ")
        let result = validate(entries: [entry])
        #expect(result.validationIssues.contains(where: { $0.contains("rationale must not be empty") }))
        #expect(!result.valid)
    }

    @Test func rejectsNonHTTPSIssueURL() throws {
        let entry = entry(issueURL: "http://example.com/issue")
        let result = validate(entries: [entry])
        #expect(result.validationIssues.contains(where: { $0.contains("issueURL must be HTTPS") }))
        #expect(!result.valid)
    }

    @Test func rejectsUnparseableExpiration() throws {
        let entry = entry(expiration: "not-a-date")
        let result = validate(entries: [entry])
        #expect(result.validationIssues.contains(where: { $0.contains("invalid or expired expiration") }))
        #expect(!result.valid)
    }

    @Test func rejectsExpiredExpiration() throws {
        let entry = entry(expiration: "2020-01-01")
        let result = validate(entries: [entry], evaluationDate: try EvaluationDate(gregorianDay: "2026-11-10"))
        #expect(result.validationIssues.contains(where: { $0.contains("invalid or expired expiration") }))
        #expect(!result.valid)
    }

    @Test func acceptsEntryOnItsExpirationDay() throws {
        let entry = entry(expiration: "2026-11-10")
        let result = validate(entries: [entry], evaluationDate: try EvaluationDate(gregorianDay: "2026-11-10"))
        #expect(!result.validationIssues.contains(where: { $0.contains("expired") }))
    }

    @Test func rejectsInvalidCalendarDate() throws {
        // 2026-02-31 matches the regex but is not a real calendar date.
        let entry = entry(expiration: "2026-02-31")
        let result = validate(entries: [entry])
        #expect(result.validationIssues.contains(where: { $0.contains("invalid or expired expiration") }))
        #expect(!result.valid)
    }

    @Test func rejectsStaleFullyQualifiedName() throws {
        let entry = entry(fullyQualifiedName: "SwiftData.DoesNotExist")
        let result = validate(entries: [entry])
        #expect(result.validationIssues.contains(where: { $0.contains("stale entry") }))
        #expect(!result.valid)
    }

    @Test func rejectsDuplicate() throws {
        let entry1 = entry()
        let entry2 = entry()
        let result = validate(entries: [entry1, entry2])
        #expect(result.validationIssues.contains(where: { $0.contains("duplicate allowlist entry") }))
        #expect(!result.valid)
    }

    @Test func rejectsAllowlistingCoveredSymbol() throws {
        let entry = entry(fullyQualifiedName: "SwiftData.Covered")
        let surface = ExtractedSurface(symbols: [
            API_Symbol(kind: .structKind, displayName: "Covered", fullyQualifiedName: "SwiftData.Covered", sourceSignature: "public struct Covered", platformAvailability: .init(), arity: 0, deprecated: false),
        ], excludedCount: 0)
        let coverage = CoverageResult(symbols: [SymbolRecord(kind: "struct", displayName: "Covered", fullyQualifiedName: "SwiftData.Covered", sourceSignature: "public struct Covered", platformAvailability: .init(), covered: true, referenceCount: 1, references: [], mangledName: "")], coveredSymbolCount: 1, uncoveredSymbolCount: 0, excludedCount: 0, surface: surface)
        let result = AllowlistValidator.validate(entries: [entry], against: coverage, evaluationDate: try EvaluationDate(gregorianDay: "2026-11-10"))
        #expect(result.validationIssues.contains(where: { $0.contains("entry allowlists a covered symbol") }))
        #expect(!result.valid)
    }

    @Test func acceptsValidEntryAndAnnotatesSymbol() throws {
        let entry = entry(fullyQualifiedName: "SwiftData.Uncovered")
        let surface = ExtractedSurface(symbols: [
            API_Symbol(kind: .structKind, displayName: "Uncovered", fullyQualifiedName: "SwiftData.Uncovered", sourceSignature: "public struct Uncovered", platformAvailability: .init(), arity: 0, deprecated: false),
        ], excludedCount: 0)
        let coverage = CoverageResult(symbols: [SymbolRecord(kind: "struct", displayName: "Uncovered", fullyQualifiedName: "SwiftData.Uncovered", sourceSignature: "public struct Uncovered", platformAvailability: .init(), covered: false, referenceCount: 0, references: [], mangledName: "")], coveredSymbolCount: 0, uncoveredSymbolCount: 1, excludedCount: 0, surface: surface)
        let result = AllowlistValidator.validate(entries: [entry], against: coverage, evaluationDate: try EvaluationDate(gregorianDay: "2026-11-10"))
        #expect(result.valid)
        let annotated = result.annotatedSymbols.first
        #expect(annotated?.allowlisted == true)
        #expect(annotated?.allowlistReasonCategory == "deferred-behavior-gap")
    }

    @Test func treatsMissingFileAsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "parity-allowlist-missing-\(UUID().uuidString).json")
        let (entries, loadIssues) = AllowlistValidator.loadEntries(from: url)
        #expect(entries.isEmpty)
        #expect(loadIssues.isEmpty)
    }

    @Test func treatsMalformedJSONAsEmptyWithLoadIssues() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "parity-allowlist-bad-\(UUID().uuidString).json")
        try "{not json".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let (entries, loadIssues) = AllowlistValidator.loadEntries(from: url)
        #expect(entries.isEmpty)
        #expect(!loadIssues.isEmpty)
        #expect(loadIssues.first?.contains("allowlist:") == true)
    }

    /// Helper: a valid entry with overridable fields, matching `SwiftData.Foo`.
    private func entry(
        fullyQualifiedName: String = "SwiftData.Foo",
        kind: String? = "struct",
        reasonCategory: String = "deferred-behavior-gap",
        rationale: String = "Intentionally omitted.",
        issueURL: String = "https://example.com/issue",
        expiration: String = "2999-12-31"
    ) -> AllowlistEntry {
        AllowlistEntry(fullyQualifiedName: fullyQualifiedName, kind: kind, reasonCategory: reasonCategory, rationale: rationale, issueURL: issueURL, expiration: expiration)
    }

    /// Helper: validates `entries` against a synthetic surface containing
    /// `SwiftData.Foo` (struct) as an uncovered symbol.
    private func validate(entries: [AllowlistEntry], evaluationDate: EvaluationDate? = nil) -> AllowlistValidation {
        let surface = ExtractedSurface(symbols: [
            API_Symbol(kind: .structKind, displayName: "Foo", fullyQualifiedName: "SwiftData.Foo", sourceSignature: "public struct Foo", platformAvailability: .init(), arity: 0, deprecated: false),
        ], excludedCount: 0)
        let coverage = CoverageResult(symbols: [SymbolRecord(kind: "struct", displayName: "Foo", fullyQualifiedName: "SwiftData.Foo", sourceSignature: "public struct Foo", platformAvailability: .init(), covered: false, referenceCount: 0, references: [], mangledName: "")], coveredSymbolCount: 0, uncoveredSymbolCount: 1, excludedCount: 0, surface: surface)
        return AllowlistValidator.validate(entries: entries, against: coverage, evaluationDate: evaluationDate ?? (try? EvaluationDate(gregorianDay: "2026-11-10")) ?? EvaluationDate(date: Date()))
    }
}
