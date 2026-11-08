import Foundation
import ParityContracts

public struct ComparisonInputs: Sendable {
    public let osd: RunnerOutput
    public let apple: RunnerOutput
    public let allowlist: [AllowedDifference]
    public let matrixSchemaVersion: Int
    public let matrixEntries: [CoverageMatrixEntry]
    public let coverage: CoverageValidationReport

    public init(
        osd: RunnerOutput,
        apple: RunnerOutput,
        allowlist: [AllowedDifference],
        matrixSchemaVersion: Int,
        matrixEntries: [CoverageMatrixEntry],
        coverage: CoverageValidationReport
    ) {
        self.osd = osd
        self.apple = apple
        self.allowlist = allowlist
        self.matrixSchemaVersion = matrixSchemaVersion
        self.matrixEntries = matrixEntries
        self.coverage = coverage
    }
}

public enum ComparisonInputError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingArtifact(URL)
    case unreadableArtifact(URL, String)
    case invalidCoverageMatrix

    public var description: String {
        switch self {
        case let .missingArtifact(url): "Required parity artifact is missing: \(url.path)"
        case let .unreadableArtifact(url, reason): "Unable to read parity artifact at \(url.path): \(reason)"
        case .invalidCoverageMatrix: "Coverage report is inconsistent with the parity matrix"
        }
    }
}

public enum ParityComparisonRuntime {
    public static func compare(_ inputs: ComparisonInputs) throws -> ParityComparison {
        let dispositions = try expectedDispositions(
            schemaVersion: inputs.matrixSchemaVersion,
            entries: inputs.matrixEntries,
            coverage: inputs.coverage)
        return try ParityComparator.compare(
            osd: inputs.osd,
            apple: inputs.apple,
            expectedDispositions: dispositions,
            allowedDifferences: inputs.allowlist)
    }

    private static func expectedDispositions(
        schemaVersion: Int,
        entries: [CoverageMatrixEntry],
        coverage: CoverageValidationReport
    ) throws -> [ScenarioID: ScenarioDisposition] {
        guard coverage.hasValidMatrix(
            schemaVersion: schemaVersion,
            entries: entries,
            registry: ParityScenarioCatalog.allContractsByID)
        else {
            throw ComparisonInputError.invalidCoverageMatrix
        }

        let runnerScenarioIDs = CoverageMatrixValidator.runnerScenarioIDs(in: entries)
        var dispositions: [ScenarioID: ScenarioDisposition] = [:]
        for entry in entries {
            for scenarioIDString in entry.scenarioIDs {
                guard runnerScenarioIDs.contains(scenarioIDString) else { continue }
                guard let scenarioID = ScenarioID(description: scenarioIDString),
                    let outcome = entry.outcomes[scenarioIDString]
                else {
                    throw ComparisonInputError.invalidCoverageMatrix
                }
                let disposition: ScenarioDisposition
                switch outcome {
                case "compared", "divergent": disposition = .observed
                case "non-comparable":
                    guard let reason = entry.reasonCategory, let rationale = entry.rationale else {
                        throw ComparisonInputError.invalidCoverageMatrix
                    }
                    disposition = .nonComparable(reasonCategory: reason, rationale: rationale)
                default:
                    throw ComparisonInputError.invalidCoverageMatrix
                }
                guard dispositions.updateValue(disposition, forKey: scenarioID) == nil else {
                    throw ComparisonInputError.invalidCoverageMatrix
                }
            }
        }
        return dispositions
    }
}

public enum ComparisonInputLoader {
    public static func load(
        osdURL: URL,
        appleURL: URL,
        allowlistURL: URL,
        matrixURL: URL,
        coverageURL: URL
    ) throws -> ComparisonInputs {
        let decoder = JSONDecoder()
        let osd = try decode(RunnerOutput.self, from: osdURL, using: decoder)
        let apple = try decode(RunnerOutput.self, from: appleURL, using: decoder)
        let allowlist = try decode(AllowlistFile.self, from: allowlistURL, using: decoder)
        let matrix = try decode(CoverageMatrix.self, from: matrixURL, using: decoder)
        let coverage = try decode(CoverageValidationReport.self, from: coverageURL, using: decoder)
        guard coverage.hasValidMatrix(
            schemaVersion: matrix.schemaVersion,
            entries: matrix.cases,
            registry: ParityScenarioCatalog.allContractsByID)
        else { throw ComparisonInputError.invalidCoverageMatrix }
        return ComparisonInputs(
            osd: osd,
            apple: apple,
            allowlist: allowlist.differences,
            matrixSchemaVersion: matrix.schemaVersion,
            matrixEntries: matrix.cases,
            coverage: coverage)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from url: URL,
        using decoder: JSONDecoder
    ) throws -> Value {
        do {
            return try decoder.decode(Value.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw ComparisonInputError.missingArtifact(url)
        } catch {
            throw ComparisonInputError.unreadableArtifact(url, String(describing: error))
        }
    }
}

private struct AllowlistFile: Decodable {
    let differences: [AllowedDifference]
}

private struct CoverageMatrix: Decodable {
    let schemaVersion: Int
    let cases: [CoverageMatrixEntry]
}
