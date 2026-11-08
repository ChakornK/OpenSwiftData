import Foundation
import ParityContracts
import SwiftParser
import SwiftSyntax

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
        let discovered = try SourceCaseDiscovery.discover(in: sourceDirectory)
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
        let coverageProblems = structuralProblems + pendingCases.map { "\($0): expected exactly one matrix record" }
        for problem in coverageProblems.prefix(20) { FileHandle.standardError.write(Data("\(problem)\n".utf8)) }
        if coverageProblems.count > 20 {
            FileHandle.standardError.write(Data("... and \(coverageProblems.count - 20) additional coverage issue(s); see \(reportURL.path)\n".utf8))
        }
        guard coverageProblems.isEmpty else { Foundation.exit(EXIT_FAILURE) }
        print("Validated \(discovered.count) source test case(s).")
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

private enum SourceCaseDiscovery {
    static func discover(in directory: URL) throws -> Set<String> {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var result = Set<String>()
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let visitor = SuiteTestVisitor(viewMode: .sourceAccurate)
            visitor.walk(Parser.parse(source: source))
            for identity in visitor.identities {
                guard result.insert(identity).inserted else {
                    throw DiscoveryFailure.duplicateIdentity(identity, file.lastPathComponent)
                }
            }
        }
        return result
    }
}

private final class SuiteTestVisitor: SyntaxVisitor {
    private var suiteStack: [String] = []
    private(set) var identities = Set<String>()

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        suiteStack.append(hasAttribute("Suite", in: node.attributes) ? node.name.text : "")
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) { _ = suiteStack.popLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        suiteStack.append(hasAttribute("Suite", in: node.attributes) ? node.name.text : "")
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) { _ = suiteStack.popLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        suiteStack.append(hasAttribute("Suite", in: node.attributes) ? node.name.text : "")
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) { _ = suiteStack.popLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let suite = suiteStack.last, !suite.isEmpty, hasAttribute("Test", in: node.attributes) else {
            return .visitChildren
        }
        let name = node.name.description.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        identities.insert("\(suite)/\(name)")
        return .visitChildren
    }

    private func hasAttribute(_ expected: String, in attributes: AttributeListSyntax) -> Bool {
        for element in attributes {
            guard case let .attribute(attribute) = element else { continue }
            if attribute.attributeName.trimmedDescription == expected { return true }
        }
        return false
    }
}

private enum DiscoveryFailure: Error, CustomStringConvertible {
    case duplicateIdentity(String, String)
    var description: String {
        switch self {
        case let .duplicateIdentity(identity, file): "Duplicate parity identity \(identity) in \(file)"
        }
    }
}

private enum ValidationError: Error {
    case repositoryRootNotFound
    case inconsistentCoverageReport
}
