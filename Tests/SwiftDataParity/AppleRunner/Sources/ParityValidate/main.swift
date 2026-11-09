import Foundation
import ParityContracts
import ParitySourceDiscovery

private struct CoverageMatrix: Decodable {
    let schemaVersion: Int
    let cases: [CoverageMatrixEntry]
}

@main
struct ParityValidate {
    static func main() throws {
        let repositoryRoot = try locateRepositoryRoot(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let sourceDirectory = repositoryRoot.appending(path: "Tests/OpenSwiftDataTests/Parity")
        let matrixURL = repositoryRoot.appending(path: "Tests/SwiftDataParity/parity-matrix.json")
        let discovered = try ParitySourceDiscovery.discover(in: sourceDirectory)
        let matrix = try JSONDecoder().decode(CoverageMatrix.self, from: Data(contentsOf: matrixURL))
        let registry = ParityScenarioCatalog.allContractsByID
        let structuralProblems = CoverageMatrixValidator.validate(
            schemaVersion: matrix.schemaVersion,
            discovered: Set(matrix.cases.map(\.sourceCase)),
            entries: matrix.cases,
            registry: registry)
        let reportURL = repositoryRoot.appending(path: "parity-coverage-report.json")
        let mappedIdentities = Set(matrix.cases.map(\.sourceCase))
        let mappedSourceCaseCount = discovered.intersection(mappedIdentities).count
        let pendingCases = discovered.subtracting(mappedIdentities).sorted()
        let sourceCaseCounts = CoverageMatrixValidator.sourceCaseCounts(in: matrix.cases)
        let scenarioOutcomeCounts = CoverageMatrixValidator.outcomeCounts(in: matrix.cases)
        let report = CoverageValidationReport(
            discoveredCaseCount: discovered.count,
            coverageValid: structuralProblems.isEmpty,
            mappedSourceCaseCount: mappedSourceCaseCount,
            declaredComparedSourceCaseCount: sourceCaseCounts["compared", default: 0],
            declaredDivergentSourceCaseCount: sourceCaseCounts["divergent", default: 0],
            declaredNonComparableSourceCaseCount: sourceCaseCounts["non-comparable", default: 0],
            declaredComparedScenarioCount: scenarioOutcomeCounts["compared", default: 0],
            declaredDivergentScenarioCount: scenarioOutcomeCounts["divergent", default: 0],
            declaredNonComparableScenarioCount: scenarioOutcomeCounts["non-comparable", default: 0],
            discoveredCases: discovered.sorted(),
            pendingCases: pendingCases,
            validationIssues: structuralProblems)
        guard report.isConsistent(with: matrix.cases) else {
            throw ValidationError.inconsistentCoverageReport
        }
        try CanonicalJSON.encode(report).write(to: reportURL, options: .atomic)
        for problem in structuralProblems.prefix(20) { FileHandle.standardError.write(Data("\(problem)\n".utf8)) }
        if structuralProblems.count > 20 {
            FileHandle.standardError.write(Data("... and \(structuralProblems.count - 20) additional structural issue(s); see \(reportURL.path)\n".utf8))
        }
        guard structuralProblems.isEmpty else { Foundation.exit(EXIT_FAILURE) }
        let coverageSummary = pendingCases.isEmpty
            ? "coverage complete"
            : "\(pendingCases.count) source case(s) remain pending"
        print("Validated matrix structure for \(discovered.count) discovered source test case(s); \(coverageSummary).")
    }

    private static func locateRepositoryRoot(from start: URL) throws -> URL {
        var candidate = start.standardizedFileURL
        while candidate.path != "/" {
            let manifest = candidate.appending(path: "Package.swift")
            let parityTests = candidate.appending(path: "Tests/OpenSwiftDataTests/Parity")
            if FileManager.default.fileExists(atPath: manifest.path),
                FileManager.default.fileExists(atPath: parityTests.path)
            {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw ValidationError.repositoryRootNotFound
    }
}

private enum ValidationError: Error {
    case repositoryRootNotFound
    case inconsistentCoverageReport
}
