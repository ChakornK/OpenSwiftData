import Foundation
import ParityContracts
import ParityCompareRuntime

@main
struct ParityCompare {
    static func main() {
        do {
            try run(CommandLine.arguments)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run(_ arguments: [String]) throws {
        let values = try Arguments.parse(arguments)
        let inputs = try ComparisonInputLoader.load(
            osdURL: values.osd,
            appleURL: values.apple,
            allowlistURL: values.allowlist,
            matrixURL: values.matrix,
            coverageURL: values.coverageReport)
        let comparison = try ParityComparisonRuntime.compare(inputs)
        try CanonicalJSON.encode(comparison).write(to: values.report, options: .atomic)
        if comparison.hasUnexpectedDifferences {
            FileHandle.standardError.write(Data("Parity comparison failed. See \(values.report.path)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
        let coverageSummary = inputs.coverage.pendingCases.isEmpty
            ? "source coverage is complete"
            : "\(inputs.coverage.pendingCases.count) source case(s) remain unmapped"
        print("Scenario comparison passed for \(inputs.osd.results.count - comparison.nonComparableScenarios.count) comparable scenario(s); \(comparison.nonComparableScenarios.count) non-comparable scenario(s); \(coverageSummary).")
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

private enum ArgumentError: Error { case invalidArguments }
