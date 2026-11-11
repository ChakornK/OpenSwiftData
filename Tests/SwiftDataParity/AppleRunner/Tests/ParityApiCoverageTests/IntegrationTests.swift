import Foundation
import ParityApiCoverageRuntime
import ParityContracts
import Testing

// Integration test against the real macOS SDK. Gated to macOS 15+; runs the
// full `ParityApiCoverage.run` against the repository and asserts the
// infrastructure invariants, NOT `coverageValid` (uncovered-but-un-allowlisted
// symbols are an expected transient state).

#if os(macOS)
@Suite struct IntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15))
    func fullRunAgainstRealSDK() throws {
        let reportPath = FileManager.default.temporaryDirectory
            .appending(path: "parity-api-coverage-integration-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: reportPath) }

        let exitCode = ParityApiCoverageRunner.run(args: ["--report", reportPath, "--today", "2026-11-10"])

        // (1) exit code in {0, 1}, never {2, 3, 4, 5, 6}.
        #expect(exitCode == 0 || exitCode == 1, "exit code was \(exitCode)")

        // (2) report file exists.
        #expect(FileManager.default.fileExists(atPath: reportPath), "report not written")

        let report = try ReportEmitter.load(from: URL(fileURLWithPath: reportPath))

        // (3) structural issues empty.
        let structural = ReportValidator.structuralIssues(report: report)
        #expect(structural.isEmpty, "structural issues: \(structural)")

        // (4) SDK fingerprint SHA is 64 hex chars.
        let shaRegex = try NSRegularExpression(pattern: "^[0-9a-f]{64}$")
        let sha = report.sdkFingerprint.swiftInterfaceSHA256
        #expect(shaRegex.firstMatch(in: sha, range: NSRange(sha.startIndex..., in: sha)) != nil, "sha was \(sha)")

        // (5) total symbol count > 0.
        #expect(report.totalSymbolCount > 0, "totalSymbolCount was \(report.totalSymbolCount)")
    }
}
#endif
