import Foundation
import ParityApiCoverageRuntime
import ParityContracts
import Testing

// Unit tests for `ReportEmitter` (canonical JSON, round-trip, generatedAt
// format, allowlistSHA256 shape, Reference custom Codable) and `EvaluationDate`
// (parsing, rejection, GMT start-of-day).

@Suite struct ReportEmitterTests {
    @Test func producesCanonicalSortedSlashUnescapedJSON() throws {
        let report = makeReport()
        let url = FileManager.default.temporaryDirectory.appending(path: "parity-report-\(UUID().uuidString).json")
        try ReportEmitter.emit(report, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        // Re-encode after decode; canonical JSON is byte-stable.
        let decoded = try JSONDecoder().decode(APICoverageReport.self, from: data)
        let reencoded = try CanonicalJSON.encode(decoded)
        #expect(data == reencoded)
    }

    @Test func generatedAtMatchesISO8601Pattern() throws {
        let report = makeReport(generatedAt: "2026-11-10T12:34:56Z")
        let url = FileManager.default.temporaryDirectory.appending(path: "parity-report-\(UUID().uuidString).json")
        try ReportEmitter.emit(report, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(APICoverageReport.self, from: data)
        let regex = try NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#)
        #expect(regex.firstMatch(in: decoded.generatedAt, range: NSRange(decoded.generatedAt.startIndex..., in: decoded.generatedAt)) != nil)
    }

    @Test func referenceCustomCodableOmitsDisplayNameFromReportJSON() throws {
        let reference = Reference(file: "f.swift", line: 1, column: 2, displayName: "ModelContext", matchQuality: .name)
        let record = SymbolRecord(kind: "struct", displayName: "X", fullyQualifiedName: "SwiftData.X", sourceSignature: "s", platformAvailability: .init(), covered: true, referenceCount: 1, references: [reference], mangledName: "")
        let report = makeReport(symbols: [record])
        let data = try CanonicalJSON.encode(report)
        let string = String(decoding: data, as: UTF8.self)
        // The references array must not contain "displayName".
        #expect(!string.contains("\"displayName\""))
        // It must contain the four report fields.
        #expect(string.contains("\"matchQuality\""))
        #expect(string.contains("\"file\""))
        #expect(string.contains("\"line\""))
        #expect(string.contains("\"column\""))
    }

    @Test func allowlistSHA256IsEitherEmptyOr64HexChars() throws {
        let report1 = makeReport(allowlistSHA256: "")
        let report2 = makeReport(allowlistSHA256: String(repeating: "a", count: 64))
        let regex = try NSRegularExpression(pattern: #"^[0-9a-f]{64}$"#)
        #expect(report1.allowlistSHA256 == "")
        #expect(regex.firstMatch(in: report2.allowlistSHA256, range: NSRange(report2.allowlistSHA256.startIndex..., in: report2.allowlistSHA256)) != nil)
    }

    /// Helper: builds a minimal `APICoverageReport`.
    private func makeReport(generatedAt: String = "2026-11-10T00:00:00Z", allowlistSHA256: String = "", symbols: [SymbolRecord] = []) -> APICoverageReport {
        APICoverageReport(
            schemaVersion: 1, strategy: "name-match",
            sdkFingerprint: SDKFingerprint(sdkPath: "", swiftInterfaceSHA256: "", swiftInterfaceByteCount: 0),
            evaluationDate: "2026-11-10", generatedAt: generatedAt,
            totalSymbolCount: symbols.count, coveredSymbolCount: 0, uncoveredSymbolCount: symbols.count,
            excludedSymbolCount: 0, coverageValid: true, allowlistSHA256: allowlistSHA256,
            validationIssues: [], symbols: symbols
        )
    }
}

@Suite struct EvaluationDateTests {
    @Test func acceptsValidDate() throws {
        let date = try EvaluationDate(gregorianDay: "2026-11-10")
        #expect(date.gregorianDay == "2026-11-10")
    }

    @Test func rejectsMissingLeadingZero() {
        #expect(throws: EvaluationDateError.self) { try EvaluationDate(gregorianDay: "2026-11-1") }
    }

    @Test func rejectsSlashes() {
        #expect(throws: EvaluationDateError.self) { try EvaluationDate(gregorianDay: "2026/11/10") }
    }

    @Test func rejectsInvalidCalendarDate() {
        // 2026-02-31 matches the regex but is not a real calendar date.
        #expect(throws: EvaluationDateError.self) { try EvaluationDate(gregorianDay: "2026-02-31") }
    }

    @Test func initDateProducesGMTStartOfDay() {
        // A fixed UTC instant: 2026-11-10T15:30:00Z → start of 2026-11-10 GMT.
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 10
        components.hour = 15; components.minute = 30
        components.timeZone = TimeZone(identifier: "UTC")
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components)!
        let evaluationDate = EvaluationDate(date: date)
        #expect(evaluationDate.gregorianDay == "2026-11-10")
        let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: evaluationDate.foundationDate)
        #expect(startComponents.hour == 0)
        #expect(startComponents.minute == 0)
    }
}
