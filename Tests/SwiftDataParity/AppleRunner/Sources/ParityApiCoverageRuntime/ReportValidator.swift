import Foundation
import ParityContracts

// Validates the internal consistency of an `APICoverageReport` (Requirement 9.1
// invariants) and surfaces coverage issues stored on the report.

public enum ReportValidator {
    /// Checks the Requirement 9.1 structural invariants (a-g). Returns one
    /// issue string per violated invariant, naming the specific mismatch.
    public static func structuralIssues(report: APICoverageReport) -> [String] {
        var issues: [String] = []
        let total = report.symbols.count
        let covered = report.symbols.filter(\.covered).count
        let uncovered = report.symbols.filter { !$0.covered }.count
        let allowlistedCovered = report.symbols.filter { $0.covered && $0.allowlisted }.count
        let coveredNotAllowlisted = report.symbols.filter { $0.allowlisted && !$0.covered }.count
        let excluded = report.excludedSymbolCount

        // (a) totalSymbolCount == coveredSymbolCount + uncoveredSymbolCount
        if report.totalSymbolCount != report.coveredSymbolCount + report.uncoveredSymbolCount {
            issues.append("totalSymbolCount (\(report.totalSymbolCount)) != coveredSymbolCount (\(report.coveredSymbolCount)) + uncoveredSymbolCount (\(report.uncoveredSymbolCount))")
        }
        // (b) uncoveredSymbolCount == symbols.filter({ $0.covered == false }).count
        if report.uncoveredSymbolCount != uncovered {
            issues.append("uncoveredSymbolCount (\(report.uncoveredSymbolCount)) != count of symbols with covered == false (\(uncovered))")
        }
        // (c) coveredSymbolCount == symbols.filter({ $0.covered == true }).count
        if report.coveredSymbolCount != covered {
            issues.append("coveredSymbolCount (\(report.coveredSymbolCount)) != count of symbols with covered == true (\(covered))")
        }
        // (d) every symbols entry with allowlisted == true also has covered == false
        if allowlistedCovered != 0 {
            issues.append("\(allowlistedCovered) symbol(s) with allowlisted == true but covered == true")
        }
        // (e) no symbols entry with covered == true has allowlisted == true
        // (same invariant as (d), checked from the opposite direction)
        if report.symbols.contains(where: { $0.covered && $0.allowlisted }) {
            // Already reported above; avoid duplicate.
        }
        // (f) excludedSymbolCount is non-negative
        if excluded < 0 {
            issues.append("excludedSymbolCount (\(excluded)) is negative")
        }
        // (g) totalSymbolCount == symbols.count
        if report.totalSymbolCount != total {
            issues.append("totalSymbolCount (\(report.totalSymbolCount)) != symbols.count (\(total))")
        }
        // Cross-check: the count of allowlisted-uncovered symbols matches.
        if report.symbols.filter({ $0.allowlisted }).count != coveredNotAllowlisted {
            issues.append("allowlisted symbol count does not match count of allowlisted-and-uncovered symbols")
        }
        return issues
    }

    /// Returns the report's stored `validationIssues` (passthrough).
    public static func coverageIssues(report: APICoverageReport) -> [String] {
        report.validationIssues
    }
}
