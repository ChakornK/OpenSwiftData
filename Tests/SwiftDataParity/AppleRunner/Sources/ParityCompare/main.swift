import Foundation
import ParityContracts

private struct AllowlistFile: Decodable {
    let differences: [AllowedDifference]
}

private struct CoverageMatrix: Decodable {
    let schemaVersion: Int
    let cases: [CoverageMatrixEntry]
}

@main
struct ParityCompare {
    static func main() throws {
        let values = try Arguments.parse(CommandLine.arguments)
        let decoder = JSONDecoder()
        let osd = try decoder.decode(RunnerOutput.self, from: Data(contentsOf: values.osd))
        let apple = try decoder.decode(RunnerOutput.self, from: Data(contentsOf: values.apple))
        let allowlist = try decoder.decode(AllowlistFile.self, from: Data(contentsOf: values.allowlist))
        let matrix = try decoder.decode(CoverageMatrix.self, from: Data(contentsOf: values.matrix))
        let coverage = try decoder.decode(CoverageValidationReport.self, from: Data(contentsOf: values.coverageReport))
        let dispositions = try expectedDispositions(from: matrix, coverage: coverage)
        let comparison = try ParityComparator.compare(
            osd: osd, apple: apple, expectedDispositions: dispositions, allowedDifferences: allowlist.differences)
        try CanonicalJSON.encode(comparison).write(to: values.report, options: .atomic)
        if comparison.hasUnexpectedDifferences {
            FileHandle.standardError.write(Data("Parity comparison failed. See \(values.report.path)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
        let coverageSummary = coverage.pendingCases.isEmpty
            ? "source coverage is complete"
            : "\(coverage.pendingCases.count) source case(s) remain unmapped"
        print("Scenario comparison passed for \(osd.results.count - comparison.nonComparableScenarios.count) comparable scenario(s); \(comparison.nonComparableScenarios.count) non-comparable scenario(s); \(coverageSummary).")
    }

    private static func expectedDispositions(
        from matrix: CoverageMatrix,
        coverage: CoverageValidationReport
    ) throws -> [ScenarioID: ScenarioDisposition] {
        guard coverage.hasValidMatrix(
            schemaVersion: matrix.schemaVersion,
            entries: matrix.cases,
            registry: ParityScenarioCatalog.allContractsByID)
        else { throw ArgumentError.invalidCoverageMatrix }

        var dispositions: [ScenarioID: ScenarioDisposition] = [:]
        for entry in matrix.cases {
            for scenarioIDString in entry.scenarioIDs {
                let scenarioID = try parseScenarioID(scenarioIDString)
                guard let outcome = entry.outcomes[scenarioIDString] else { throw ArgumentError.invalidCoverageMatrix }
                let disposition: ScenarioDisposition
                switch outcome {
                case "compared", "divergent": disposition = .observed
                case "non-comparable":
                    guard let reason = entry.reasonCategory, let rationale = entry.rationale else {
                        throw ArgumentError.invalidCoverageMatrix
                    }
                    disposition = .nonComparable(reasonCategory: reason, rationale: rationale)
                default: throw ArgumentError.invalidCoverageMatrix
                }
                guard dispositions.updateValue(disposition, forKey: scenarioID) == nil else {
                    throw ArgumentError.invalidCoverageMatrix
                }
            }
        }
        return dispositions
    }

    private static func parseScenarioID(_ value: String) throws -> ScenarioID {
        guard let scenarioID = ScenarioID(description: value) else { throw ArgumentError.invalidCoverageMatrix }
        return scenarioID
    }
}

private struct Arguments {
    let osd: URL
    let apple: URL
    let allowlist: URL
    let report: URL
    let matrix: URL
    let coverageReport: URL

    static func parse(_ arguments: [String]) throws -> Self {
        var options: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), arguments.indices.contains(index + 1) else {
                throw ArgumentError.invalidArguments
            }
            options[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let osd = options["--osd"], let apple = options["--apple"],
            let allowlist = options["--allowlist"], let report = options["--report"],
            let matrix = options["--matrix"], let coverageReport = options["--coverage-report"]
        else { throw ArgumentError.invalidArguments }
        return Self(
            osd: URL(fileURLWithPath: osd), apple: URL(fileURLWithPath: apple),
            allowlist: URL(fileURLWithPath: allowlist), report: URL(fileURLWithPath: report),
            matrix: URL(fileURLWithPath: matrix), coverageReport: URL(fileURLWithPath: coverageReport))
    }
}

private enum ArgumentError: Error { case invalidArguments, invalidCoverageMatrix }
