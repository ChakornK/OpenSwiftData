import Foundation
import ParityContracts
import SwiftParser
import SwiftSyntax

private struct CoverageMatrix: Decodable {
    struct Entry: Decodable {
        let sourceCase: String
        let scenarioIDs: [String]
        let status: String
        let observations: [String]
        let argumentSets: [String]
        let reasonCategory: String?
        let rationale: String?
    }

    let schemaVersion: Int
    let cases: [Entry]
}

@main
struct ParityValidate {
    static func main() throws {
        let repositoryRoot = try locateRepositoryRoot(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let sourceDirectory = repositoryRoot.appending(path: "Tests/OpenSwiftDataTests/Parity")
        let matrixURL = repositoryRoot.appending(path: "Tests/SwiftDataParity/parity-matrix.json")
        let discovered = try SourceCaseDiscovery.discover(in: sourceDirectory)
        let matrix = try JSONDecoder().decode(CoverageMatrix.self, from: Data(contentsOf: matrixURL))
        let registry = ParityScenarioCatalog.specificationsByID
        let problems = CoverageMatrixValidator.validate(discovered: discovered, matrix: matrix, registry: registry)
        let reportURL = repositoryRoot.appending(path: "parity-coverage-report.json")
        let mappedIdentities = Set(matrix.cases.map(\.sourceCase))
        let pendingCases = discovered.subtracting(mappedIdentities).sorted()
        let report = CoverageValidationReport(
            discoveredCaseCount: discovered.count,
            comparedCaseCount: matrix.cases.filter { $0.status == "compared" }.count,
            divergentCaseCount: matrix.cases.filter { $0.status == "divergent" }.count,
            nonComparableCaseCount: matrix.cases.filter { $0.status == "non-comparable" }.count,
            pendingCases: pendingCases,
            validationIssues: problems)
        try CanonicalJSON.encode(report).write(to: reportURL, options: .atomic)
        for problem in problems.prefix(20) { FileHandle.standardError.write(Data("\(problem)\n".utf8)) }
        if problems.count > 20 {
            FileHandle.standardError.write(Data("... and \(problems.count - 20) additional coverage issue(s); see \(reportURL.path)\n".utf8))
        }
        guard problems.isEmpty else { Foundation.exit(EXIT_FAILURE) }
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

private struct CoverageValidationReport: Codable {
    let discoveredCaseCount: Int
    let comparedCaseCount: Int
    let divergentCaseCount: Int
    let nonComparableCaseCount: Int
    let pendingCases: [String]
    let validationIssues: [String]
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

private enum CoverageMatrixValidator {
    private static let permittedStatuses: Set<String> = ["compared", "divergent", "non-comparable"]
    private static let permittedReasons: Set<String> = [
        "private-api", "unsupported-platform-or-version", "nondeterministic-apple-behavior", "shim-only-api",
    ]

    static func validate(
        discovered: Set<String>, matrix: CoverageMatrix, registry: [String: PredicateMembershipSpecification]
    ) -> [String] {
        var errors: [String] = []
        let grouped = Dictionary(grouping: matrix.cases, by: \.sourceCase)
        for identity in discovered.sorted() where grouped[identity]?.count != 1 {
            errors.append("\(identity): expected exactly one matrix record")
        }
        for entry in matrix.cases where !discovered.contains(entry.sourceCase) {
            errors.append("\(entry.sourceCase): matrix record is stale")
        }
        for entry in matrix.cases {
            guard permittedStatuses.contains(entry.status) else {
                errors.append("\(entry.sourceCase): invalid status '\(entry.status)'")
                continue
            }
            if entry.status == "non-comparable" {
                if let reason = entry.reasonCategory, permittedReasons.contains(reason),
                    let rationale = entry.rationale, !rationale.isEmpty
                {} else {
                    errors.append("\(entry.sourceCase): non-comparable entry needs a valid reason and rationale")
                }
            } else if entry.scenarioIDs.isEmpty || entry.scenarioIDs.contains(where: { registry[$0] == nil }) {
                errors.append("\(entry.sourceCase): references missing scenario registry entry")
            } else if entry.status == "compared",
                entry.scenarioIDs.contains(where: { id in
                    guard let specification = registry[id] else { return true }
                    return Set(entry.observations) != Set(specification.expectedObservations.keys)
                })
            {
                errors.append("\(entry.sourceCase): matrix observation fields do not match shared scenario contract")
            }
            if entry.argumentSets.isEmpty {
                errors.append("\(entry.sourceCase): argumentSets must not be empty")
            }
        }
        return errors
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
}
