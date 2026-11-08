import Foundation

public struct ScenarioID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let suite: String
    public let test: String

    public init(suite: String, test: String) {
        self.suite = suite
        self.test = test
    }

    public var description: String { "\(suite)/\(test)" }
}

public enum ObservedValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case array([ObservedValue])
    case object([String: ObservedValue])

    private enum CodingKeys: String, CodingKey { case type, bool, integer, string, array, object }

    private enum ValueType: String, Codable { case null, bool, integer, string, array, object }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .null: self = .null
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .bool))
        case .integer: self = .integer(try container.decode(Int64.self, forKey: .integer))
        case .string: self = .string(try container.decode(String.self, forKey: .string))
        case .array: self = .array(try container.decode([ObservedValue].self, forKey: .array))
        case .object: self = .object(try container.decode([String: ObservedValue].self, forKey: .object))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode(ValueType.null, forKey: .type)
        case let .bool(value):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(value, forKey: .bool)
        case let .integer(value):
            try container.encode(ValueType.integer, forKey: .type)
            try container.encode(value, forKey: .integer)
        case let .string(value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .string)
        case let .array(value):
            try container.encode(ValueType.array, forKey: .type)
            try container.encode(value, forKey: .array)
        case let .object(value):
            try container.encode(ValueType.object, forKey: .type)
            try container.encode(value, forKey: .object)
        }
    }
}

public struct ParityObservation: Codable, Equatable, Sendable {
    public let step: Int
    public let field: String
    public let value: ObservedValue

    public init(step: Int, field: String, value: ObservedValue) {
        self.step = step
        self.field = field
        self.value = value
    }
}

public struct ScenarioResult: Codable, Equatable, Sendable {
    public let id: ScenarioID
    public let observations: [ParityObservation]

    public init(id: ScenarioID, observations: [ParityObservation]) {
        self.id = id
        self.observations = observations
    }
}

public struct RunnerManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let implementation: String
    public let gitSHA: String
    public let scenarios: [ScenarioID]

    public init(schemaVersion: Int = 1, implementation: String, gitSHA: String, scenarios: [ScenarioID]) {
        self.schemaVersion = schemaVersion
        self.implementation = implementation
        self.gitSHA = gitSHA
        self.scenarios = scenarios
    }
}

public struct RunnerOutput: Codable, Equatable, Sendable {
    public let manifest: RunnerManifest
    public let results: [ScenarioResult]

    public init(manifest: RunnerManifest, results: [ScenarioResult]) {
        self.manifest = manifest
        self.results = results
    }
}

public struct ObservationDifference: Codable, Equatable, Sendable {
    public let scenarioID: ScenarioID
    public let field: String
    public let osdValue: ObservedValue?
    public let appleValue: ObservedValue?
    public let isAllowed: Bool

    public init(
        scenarioID: ScenarioID,
        field: String,
        osdValue: ObservedValue?,
        appleValue: ObservedValue?,
        isAllowed: Bool
    ) {
        self.scenarioID = scenarioID
        self.field = field
        self.osdValue = osdValue
        self.appleValue = appleValue
        self.isAllowed = isAllowed
    }
}

public struct ParityComparison: Codable, Equatable, Sendable {
    public let differences: [ObservationDifference]
    public let missingOSDScenarios: [ScenarioID]
    public let missingAppleScenarios: [ScenarioID]

    public var hasUnexpectedDifferences: Bool {
        !missingOSDScenarios.isEmpty || !missingAppleScenarios.isEmpty || differences.contains { !$0.isAllowed }
    }

    public init(
        differences: [ObservationDifference],
        missingOSDScenarios: [ScenarioID],
        missingAppleScenarios: [ScenarioID]
    ) {
        self.differences = differences
        self.missingOSDScenarios = missingOSDScenarios
        self.missingAppleScenarios = missingAppleScenarios
    }
}

public struct AllowedDifference: Codable, Equatable, Sendable {
    public let scenarioID: ScenarioID
    public let field: String
    public let reason: String
    public let issueURL: URL
    public let expiration: String

    public init(scenarioID: ScenarioID, field: String, reason: String, issueURL: URL, expiration: String) {
        self.scenarioID = scenarioID
        self.field = field
        self.reason = reason
        self.issueURL = issueURL
        self.expiration = expiration
    }
}

public enum ParityComparator {
    public static func compare(
        osd: RunnerOutput,
        apple: RunnerOutput,
        allowedDifferences: [AllowedDifference] = []
    ) throws -> ParityComparison {
        guard osd.manifest.implementation == "openswiftdata" else {
            throw ComparisonError.unexpectedImplementation("osd", osd.manifest.implementation)
        }
        guard apple.manifest.implementation == "apple-swiftdata" else {
            throw ComparisonError.unexpectedImplementation("apple", apple.manifest.implementation)
        }
        guard osd.manifest.schemaVersion == apple.manifest.schemaVersion else {
            throw ComparisonError.schemaVersionMismatch(osd.manifest.schemaVersion, apple.manifest.schemaVersion)
        }

        let osdResults = try uniqueResults(osd.results, implementation: "OSD")
        let appleResults = try uniqueResults(apple.results, implementation: "Apple")
        let allowlistByKey = try uniqueAllowlist(allowedDifferences)
        let osdIDs = Set(osdResults.keys)
        let appleIDs = Set(appleResults.keys)
        guard osdIDs == Set(osd.manifest.scenarios) else {
            throw ComparisonError.manifestScenarioMismatch("OSD")
        }
        guard appleIDs == Set(apple.manifest.scenarios) else {
            throw ComparisonError.manifestScenarioMismatch("Apple")
        }
        let sharedIDs = osdIDs.intersection(appleIDs).sorted { $0.description < $1.description }
        var differences: [ObservationDifference] = []

        for id in sharedIDs {
            let osdObservations = try uniqueObservations(osdResults[id]!.observations, scenarioID: id)
            let appleObservations = try uniqueObservations(appleResults[id]!.observations, scenarioID: id)
            let fields = Set(osdObservations.keys).union(appleObservations.keys).sorted()

            for field in fields {
                let osdValue = osdObservations[field]
                let appleValue = appleObservations[field]
                guard osdValue != appleValue else { continue }
                let allowed = allowlistByKey[DifferenceKey(scenarioID: id, field: field)] != nil
                differences.append(
                    ObservationDifference(
                        scenarioID: id, field: field, osdValue: osdValue, appleValue: appleValue, isAllowed: allowed))
            }
        }

        let observedDifferenceKeys = Set(differences.map { DifferenceKey(scenarioID: $0.scenarioID, field: $0.field) })
        let unusedAllowlistKeys = Set(allowlistByKey.keys).subtracting(observedDifferenceKeys)
        guard unusedAllowlistKeys.isEmpty else {
            throw ComparisonError.unreferencedAllowlist(unusedAllowlistKeys.sorted().map(\.description))
        }

        return ParityComparison(
            differences: differences,
            missingOSDScenarios: appleIDs.subtracting(osdIDs).sorted { $0.description < $1.description },
            missingAppleScenarios: osdIDs.subtracting(appleIDs).sorted { $0.description < $1.description })
    }

    private static func uniqueResults(
        _ results: [ScenarioResult], implementation: String
    ) throws -> [ScenarioID: ScenarioResult] {
        var indexed: [ScenarioID: ScenarioResult] = [:]
        for result in results {
            guard indexed.updateValue(result, forKey: result.id) == nil else {
                throw ComparisonError.duplicateScenario(implementation, result.id)
            }
        }
        return indexed
    }

    private static func uniqueObservations(
        _ observations: [ParityObservation], scenarioID: ScenarioID
    ) throws -> [String: ObservedValue] {
        var indexed: [String: ObservedValue] = [:]
        for observation in observations {
            guard indexed.updateValue(observation.value, forKey: observation.field) == nil else {
                throw ComparisonError.duplicateObservation(scenarioID, observation.field)
            }
        }
        return indexed
    }

    private static func uniqueAllowlist(_ entries: [AllowedDifference]) throws -> [DifferenceKey: AllowedDifference] {
        var indexed: [DifferenceKey: AllowedDifference] = [:]
        let today = Calendar(identifier: .gregorian).startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        for entry in entries {
            let key = DifferenceKey(scenarioID: entry.scenarioID, field: entry.field)
            guard indexed[key] == nil else { throw ComparisonError.duplicateAllowlist(key.description) }
            guard !entry.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                entry.issueURL.scheme == "https",
                let expiration = formatter.date(from: entry.expiration)
            else { throw ComparisonError.invalidAllowlist(key.description) }
            guard expiration >= today else { throw ComparisonError.expiredAllowlist(key.description, entry.expiration) }
            indexed[key] = entry
        }
        return indexed
    }
}

private struct DifferenceKey: Hashable, Comparable, CustomStringConvertible {
    let scenarioID: ScenarioID
    let field: String

    var description: String { "\(scenarioID)#\(field)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.scenarioID.description, lhs.field) < (rhs.scenarioID.description, rhs.field)
    }
}

public enum ComparisonError: Error, Equatable {
    case schemaVersionMismatch(Int, Int)
    case unexpectedImplementation(String, String)
    case manifestScenarioMismatch(String)
    case duplicateScenario(String, ScenarioID)
    case duplicateObservation(ScenarioID, String)
    case duplicateAllowlist(String)
    case invalidAllowlist(String)
    case expiredAllowlist(String, String)
    case unreferencedAllowlist([String])
}

public struct PredicateMembershipSpecification: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public let name: String
        public let age: Int64

        public init(name: String, age: Int64) {
            self.name = name
            self.age = age
        }
    }

    public let id: ScenarioID
    public let rows: [Row]
    public let capturedNames: [String]
    public let sortField: SortField
    public let expectedObservations: [String: ObservedValue]
    public let operations: [ScenarioOperation]

    public enum SortField: String, Codable, Sendable {
        case age
    }

    public init(
        id: ScenarioID,
        rows: [Row],
        capturedNames: [String],
        sortField: SortField,
        expectedObservations: [String: ObservedValue],
        operations: [ScenarioOperation]
    ) {
        self.id = id
        self.rows = rows
        self.capturedNames = capturedNames
        self.sortField = sortField
        self.expectedObservations = expectedObservations
        self.operations = operations
    }
}

public enum ScenarioOperation: Codable, Equatable, Sendable {
    case insertRows
    case fetchNamesMatchingCapturedNames(observationField: String, includePendingChanges: Bool)
    case fetchNamesMatchingArrayLiteralBD(observationField: String, includePendingChanges: Bool)
    case fetchNamesNotMatchingCapturedNames(observationField: String, names: [String], includePendingChanges: Bool)
    case fetchNamesMatchingAges(observationField: String, ages: [Int], includePendingChanges: Bool)
    case fetchNamesMatchingNamesOrAge(observationField: String, names: [String], minimumAge: Int, includePendingChanges: Bool)
    case countNamesMatchingCapturedNames(observationField: String)
    case save
}

public enum ParityScenarioCatalog {
    public static let predicateMembership = PredicateMembershipSpecification(
        id: ScenarioID(suite: "PredicateParityTests", test: "membership in a captured array"),
        rows: [
            .init(name: "a", age: 1),
            .init(name: "b", age: 2),
            .init(name: "c", age: 3),
            .init(name: "d", age: 4),
        ],
        capturedNames: ["a", "c"],
        sortField: .age,
        expectedObservations: [
            "pending.names": .array([.string("a"), .string("c")]),
            "saved.names": .array([.string("a"), .string("c")]),
        ],
        operations: [
            .insertRows,
            .fetchNamesMatchingCapturedNames(observationField: "pending.names", includePendingChanges: true),
            .save,
            .fetchNamesMatchingCapturedNames(observationField: "saved.names", includePendingChanges: false),
        ])

    public static let predicateArrayLiteralMembership = PredicateMembershipSpecification(
        id: ScenarioID(suite: "PredicateParityTests", test: "membership in an array literal"),
        rows: [
            .init(name: "a", age: 1),
            .init(name: "b", age: 2),
            .init(name: "c", age: 3),
            .init(name: "d", age: 4),
        ],
        capturedNames: [],
        sortField: .age,
        expectedObservations: [
            "pending.names": .array([.string("b"), .string("d")]),
            "saved.names": .array([.string("b"), .string("d")]),
        ],
        operations: [
            .insertRows,
            .fetchNamesMatchingArrayLiteralBD(observationField: "pending.names", includePendingChanges: true),
            .save,
            .fetchNamesMatchingArrayLiteralBD(observationField: "saved.names", includePendingChanges: false),
        ])

    public static let emptyArrayMembership = PredicateMembershipSpecification(
        id: ScenarioID(suite: "PredicateParityTests", test: "membership in an empty array matches nothing"),
        rows: [
            .init(name: "a", age: 1),
            .init(name: "b", age: 2),
            .init(name: "c", age: 3),
            .init(name: "d", age: 4),
        ],
        capturedNames: [],
        sortField: .age,
        expectedObservations: [
            "pending.names": .array([]),
            "saved.names": .array([]),
            "saved.count": .integer(0),
        ],
        operations: [
            .insertRows,
            .fetchNamesMatchingCapturedNames(observationField: "pending.names", includePendingChanges: true),
            .save,
            .fetchNamesMatchingCapturedNames(observationField: "saved.names", includePendingChanges: false),
            .countNamesMatchingCapturedNames(observationField: "saved.count"),
        ])

    public static let negatedIntegerAndCombinedMembership = PredicateMembershipSpecification(
        id: ScenarioID(suite: "PredicateParityTests", test: "negated, integer, and combined membership"),
        rows: [
            .init(name: "a", age: 1),
            .init(name: "b", age: 2),
            .init(name: "c", age: 3),
            .init(name: "d", age: 4),
        ],
        capturedNames: [],
        sortField: .age,
        expectedObservations: [
            "negated.pending": .array([.string("b"), .string("d")]),
            "negated.saved": .array([.string("b"), .string("d")]),
            "integer.pending": .array([.string("b"), .string("d")]),
            "integer.saved": .array([.string("b"), .string("d")]),
            "combined.pending": .array([.string("a"), .string("c"), .string("d")]),
            "combined.saved": .array([.string("a"), .string("c"), .string("d")]),
        ],
        operations: [
            .insertRows,
            .fetchNamesNotMatchingCapturedNames(
                observationField: "negated.pending", names: ["a", "c"], includePendingChanges: true),
            .save,
            .fetchNamesNotMatchingCapturedNames(
                observationField: "negated.saved", names: ["a", "c"], includePendingChanges: false),
            .fetchNamesMatchingAges(observationField: "integer.pending", ages: [2, 4, 9], includePendingChanges: true),
            .save,
            .fetchNamesMatchingAges(observationField: "integer.saved", ages: [2, 4, 9], includePendingChanges: false),
            .fetchNamesMatchingNamesOrAge(
                observationField: "combined.pending", names: ["a", "c"], minimumAge: 3, includePendingChanges: true),
            .save,
            .fetchNamesMatchingNamesOrAge(
                observationField: "combined.saved", names: ["a", "c"], minimumAge: 3, includePendingChanges: false),
        ])

    public static let all: [PredicateMembershipSpecification] = [
        predicateMembership,
        predicateArrayLiteralMembership,
        emptyArrayMembership,
        negatedIntegerAndCombinedMembership,
    ]

    public static var specificationsByID: [String: PredicateMembershipSpecification] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0) })
    }
}

public enum CanonicalJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

public protocol ParityScenario {
    static var id: ScenarioID { get }
    @MainActor static func run() throws -> ScenarioResult
}
