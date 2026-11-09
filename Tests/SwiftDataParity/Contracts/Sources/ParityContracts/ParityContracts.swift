import Foundation

public struct ScenarioID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let suite: String
    public let test: String

    public init(suite: String, test: String) {
        self.suite = suite
        self.test = test
    }

    public var description: String { "\(suite)/\(test)" }

    public init?(description: String) {
        guard let separator = description.firstIndex(of: "/") else { return nil }
        let suite = String(description[..<separator])
        let test = String(description[description.index(after: separator)...])
        guard !suite.isEmpty, !test.isEmpty else { return nil }
        self.init(suite: suite, test: test)
    }
}

public enum ObservedValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case array([ObservedValue])
    case stringSet([String])
    case object([String: ObservedValue])

    public static func unorderedStrings(_ values: [String]) -> Self {
        .stringSet(Array(Set(values)).sorted())
    }

    public var canonicalized: Self {
        switch self {
        case let .stringSet(values): .stringSet(Array(Set(values)).sorted())
        case let .array(values): .array(values.map(\.canonicalized))
        case let .object(values): .object(values.mapValues(\.canonicalized))
        default: self
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(lhs), .bool(rhs)): lhs == rhs
        case let (.integer(lhs), .integer(rhs)): lhs == rhs
        case let (.string(lhs), .string(rhs)): lhs == rhs
        case let (.array(lhs), .array(rhs)): lhs == rhs
        case let (.stringSet(lhs), .stringSet(rhs)): Set(lhs) == Set(rhs)
        case let (.object(lhs), .object(rhs)): lhs == rhs
        default: false
        }
    }

    private enum CodingKeys: String, CodingKey { case type, bool, integer, string, array, stringSet, object }

    private enum ValueType: String, Codable { case null, bool, integer, string, array, stringSet, object }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .null: self = .null
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .bool))
        case .integer: self = .integer(try container.decode(Int64.self, forKey: .integer))
        case .string: self = .string(try container.decode(String.self, forKey: .string))
        case .array: self = .array(try container.decode([ObservedValue].self, forKey: .array))
        case .stringSet: self = .unorderedStrings(try container.decode([String].self, forKey: .stringSet))
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
        case let .stringSet(value):
            try container.encode(ValueType.stringSet, forKey: .type)
            try container.encode(Array(Set(value)).sorted(), forKey: .stringSet)
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

public enum ScenarioDisposition: Codable, Equatable, Sendable {
    case observed
    case nonComparable(reasonCategory: String, rationale: String)
}

public struct ScenarioResult: Codable, Equatable, Sendable {
    public let id: ScenarioID
    public let observations: [ParityObservation]
    public let disposition: ScenarioDisposition

    public init(id: ScenarioID, observations: [ParityObservation], disposition: ScenarioDisposition = .observed) {
        self.id = id
        self.observations = observations
        self.disposition = disposition
    }
}

public struct ScenarioContract: Codable, Equatable, Sendable {
    public let id: ScenarioID
    public let expectedObservationFields: Set<String>

    public init(id: ScenarioID, expectedObservationFields: Set<String>) {
        self.id = id
        self.expectedObservationFields = expectedObservationFields
    }
}

public struct ScenarioExpectationError: Error, CustomStringConvertible {
    public let id: ScenarioID
    public let observations: [ParityObservation]

    public init(id: ScenarioID, observations: [ParityObservation]) {
        self.id = id
        self.observations = observations
    }

    public var description: String { "Scenario \(id) produced unexpected observations: \(observations)" }
}

public struct RunnerManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let implementation: String
    public let gitSHA: String
    public let scenarios: [ScenarioID]

    public init(schemaVersion: Int = 2, implementation: String, gitSHA: String, scenarios: [ScenarioID]) {
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
    public let nonComparableScenarios: [ScenarioID]

    public var hasUnexpectedDifferences: Bool {
        !missingOSDScenarios.isEmpty || !missingAppleScenarios.isEmpty || differences.contains { !$0.isAllowed }
    }

    public init(
        differences: [ObservationDifference],
        missingOSDScenarios: [ScenarioID],
        missingAppleScenarios: [ScenarioID],
        nonComparableScenarios: [ScenarioID] = []
    ) {
        self.differences = differences
        self.missingOSDScenarios = missingOSDScenarios
        self.missingAppleScenarios = missingAppleScenarios
        self.nonComparableScenarios = nonComparableScenarios
    }
}

public struct AllowedDifference: Codable, Equatable, Sendable {
    public let scenarioID: ScenarioID
    public let field: String
    public let osdExpected: ObservedValue
    public let appleExpected: ObservedValue
    public let reason: String
    public let issueURL: URL
    public let expiration: String

    public init(
        scenarioID: ScenarioID,
        field: String,
        osdExpected: ObservedValue,
        appleExpected: ObservedValue,
        reason: String,
        issueURL: URL,
        expiration: String
    ) {
        self.scenarioID = scenarioID
        self.field = field
        self.osdExpected = osdExpected
        self.appleExpected = appleExpected
        self.reason = reason
        self.issueURL = issueURL
        self.expiration = expiration
    }
}

public enum ParityComparator {
    public static func compare(
        osd: RunnerOutput,
        apple: RunnerOutput,
        expectedDispositions: [ScenarioID: ScenarioDisposition],
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
        guard osd.manifest.schemaVersion == 2 else {
            throw ComparisonError.unsupportedRunnerSchemaVersion(osd.manifest.schemaVersion)
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
        guard osdIDs == Set(expectedDispositions.keys) else {
            throw ComparisonError.dispositionScenarioMismatch("OSD")
        }
        guard appleIDs == Set(expectedDispositions.keys) else {
            throw ComparisonError.dispositionScenarioMismatch("Apple")
        }
        let sharedIDs = osdIDs.intersection(appleIDs).sorted { $0.description < $1.description }
        var differences: [ObservationDifference] = []
        var nonComparableScenarios: [ScenarioID] = []

        for id in sharedIDs {
            let osdResult = osdResults[id]!
            let appleResult = appleResults[id]!
            let expectedDisposition = expectedDispositions[id]!
            guard osdResult.disposition == expectedDisposition, appleResult.disposition == expectedDisposition else {
                throw ComparisonError.dispositionMismatch(id)
            }
            guard osdResult.disposition == appleResult.disposition else {
                throw ComparisonError.dispositionMismatch(id)
            }
            if case let .nonComparable(reasonCategory, rationale) = osdResult.disposition {
                guard !reasonCategory.isEmpty, !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    osdResult.observations.isEmpty, appleResult.observations.isEmpty
                else {
                    throw ComparisonError.invalidNonComparableResult(id)
                }
                nonComparableScenarios.append(id)
                continue
            }
            let osdObservations = try uniqueObservations(osdResults[id]!.observations, scenarioID: id)
            let appleObservations = try uniqueObservations(appleResults[id]!.observations, scenarioID: id)
            let fields = Set(osdObservations.keys).union(appleObservations.keys).sorted()

            for field in fields {
                let osdValue = osdObservations[field]?.canonicalized
                let appleValue = appleObservations[field]?.canonicalized
                guard osdValue != appleValue else { continue }
                let allowance = allowlistByKey[DifferenceKey(scenarioID: id, field: field)]
                let allowed = allowance.map {
                    $0.osdExpected.canonicalized == osdValue && $0.appleExpected.canonicalized == appleValue
                } ?? false
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
            missingAppleScenarios: osdIDs.subtracting(appleIDs).sorted { $0.description < $1.description },
            nonComparableScenarios: nonComparableScenarios)
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
            guard entry.osdExpected.canonicalized != entry.appleExpected.canonicalized else {
                throw ComparisonError.invalidAllowlist(key.description)
            }
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
    case unsupportedRunnerSchemaVersion(Int)
    case unexpectedImplementation(String, String)
    case manifestScenarioMismatch(String)
    case dispositionMismatch(ScenarioID)
    case dispositionScenarioMismatch(String)
    case invalidNonComparableResult(ScenarioID)
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
        public let nick: String?

        public init(name: String, age: Int64, nick: String? = nil) {
            self.name = name
            self.age = age
            self.nick = nick
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
        case name
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

public struct PendingFetchSpecification: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public let name: String
        public let age: Int64

        public init(name: String, age: Int64) {
            self.name = name
            self.age = age
        }
    }

    public enum PendingChange: Codable, Equatable, Sendable {
        case insert(Row)
        case updateAge(name: String, age: Int64)
        case delete(name: String)
    }

    public enum AgePredicate: Codable, Equatable, Sendable {
        case lessThan(Int64)
        case greaterThan(Int64)
    }

    public enum QueryResult: Codable, Equatable, Sendable {
        case names
        case count
        case identifierCount
    }

    public enum Sort: Codable, Equatable, Sendable {
        case none
        case ageAscending
    }

    public struct Query: Codable, Equatable, Sendable {
        public let observationField: String
        public let predicate: AgePredicate?
        public let sort: Sort
        public let limit: Int?
        public let offset: Int?
        public let includesPendingChanges: Bool
        public let result: QueryResult

        public init(
            observationField: String,
            predicate: AgePredicate? = nil,
            sort: Sort = .ageAscending,
            limit: Int? = nil,
            offset: Int? = nil,
            includesPendingChanges: Bool = true,
            result: QueryResult = .names
        ) {
            self.observationField = observationField
            self.predicate = predicate
            self.sort = sort
            self.limit = limit
            self.offset = offset
            self.includesPendingChanges = includesPendingChanges
            self.result = result
        }
    }

    public struct ExpectedObservation: Codable, Equatable, Sendable {
        public let step: Int
        public let field: String
        public let value: ObservedValue

        public init(step: Int, field: String, value: ObservedValue) {
            self.step = step
            self.field = field
            self.value = value
        }
    }

    public struct Step: Codable, Equatable, Sendable {
        public let pendingChange: PendingChange?
        public let query: Query?

        public init(pendingChange: PendingChange? = nil, query: Query? = nil) {
            self.pendingChange = pendingChange
            self.query = query
        }
    }

    public let id: ScenarioID
    public let seedRows: [Row]
    public let steps: [Step]
    public let expectedObservations: [ExpectedObservation]

    public init(
        id: ScenarioID,
        seedRows: [Row],
        steps: [Step],
        expectedObservations: [ExpectedObservation]
    ) {
        self.id = id
        self.seedRows = seedRows
        self.steps = steps
        self.expectedObservations = expectedObservations
    }

    public var contract: ScenarioContract {
        ScenarioContract(id: id, expectedObservationFields: Set(expectedObservations.map(\.field)))
    }

    public var hasValidObservationSchedule: Bool {
        let scheduledQueries = Dictionary(uniqueKeysWithValues: steps.enumerated().compactMap { index, step in
            step.query.map { ($0.observationField, index) }
        })
        let expectedFields = expectedObservations.map(\.field)
        guard expectedFields.count == Set(expectedFields).count,
              scheduledQueries.count == steps.compactMap(\.query).count,
              Set(scheduledQueries.keys) == Set(expectedFields)
        else {
            return false
        }
        return expectedObservations.allSatisfy { scheduledQueries[$0.field] == $0.step }
    }
}

public enum PendingFetchScenarioCatalog {
    private static let seedRows: [PendingFetchSpecification.Row] = [
        .init(name: "s1", age: 10), .init(name: "s2", age: 30),
        .init(name: "s3", age: 50), .init(name: "s4", age: 70),
    ]

    private static let makePendingChanges = PendingFetchSpecification.Step(pendingChange: .insert(.init(name: "p1", age: 20)))
    private static let updateFirstRow = PendingFetchSpecification.Step(
        pendingChange: .updateAge(name: "s1", age: 60))
    private static let deleteSecondRow = PendingFetchSpecification.Step(pendingChange: .delete(name: "s2"))

    public static let zeroLimit = PendingFetchSpecification(
        id: ScenarioID(suite: "PendingFetchParityTests", test: "a zero fetch limit means no limit"),
        seedRows: seedRows,
        steps: [
            .init(query: .init(observationField: "names.all", limit: 0, includesPendingChanges: false)),
            .init(query: .init(observationField: "names.offset", limit: 0, offset: 1, includesPendingChanges: false)),
            .init(query: .init(observationField: "count", limit: 0, result: .count)),
            .init(query: .init(
                observationField: "identifierCount", sort: .none, limit: 0,
                includesPendingChanges: false, result: .identifierCount)),
        ],
        expectedObservations: [
            .init(step: 0, field: "names.all", value: .array([.string("s1"), .string("s2"), .string("s3"), .string("s4")])),
            .init(step: 1, field: "names.offset", value: .array([.string("s2"), .string("s3"), .string("s4")])),
            .init(step: 2, field: "count", value: .integer(4)),
            .init(step: 3, field: "identifierCount", value: .integer(4)),
        ])

    public static let storedPaginationBeforePendingMerge = PendingFetchSpecification(
        id: ScenarioID(suite: "PendingFetchParityTests", test: "stored rows paginate before pending changes merge"),
        seedRows: seedRows,
        steps: [makePendingChanges, updateFirstRow, deleteSecondRow] + [
            .init(query: .init(observationField: "names.all")),
            .init(query: .init(observationField: "names.limit", limit: 2)),
            .init(query: .init(observationField: "names.offset", offset: 1)),
            .init(query: .init(observationField: "names.limitOffset", limit: 2, offset: 1)),
            .init(query: .init(observationField: "names.zeroLimitOffset", limit: 0, offset: 2)),
            .init(query: .init(observationField: "count.all", result: .count)),
            .init(query: .init(observationField: "count.limit", limit: 2, result: .count)),
            .init(query: .init(observationField: "count.limitOffset", limit: 2, offset: 1, result: .count)),
        ],
        expectedObservations: [
            .init(step: 3, field: "names.all", value: .array([.string("p1"), .string("s3"), .string("s1"), .string("s4")])),
            .init(step: 4, field: "names.limit", value: .array([.string("p1"), .string("s1")])),
            .init(step: 5, field: "names.offset", value: .array([.string("p1"), .string("s3"), .string("s1"), .string("s4")])),
            .init(step: 6, field: "names.limitOffset", value: .array([.string("p1"), .string("s3")])),
            .init(step: 7, field: "names.zeroLimitOffset", value: .array([.string("p1"), .string("s3"), .string("s1"), .string("s4")])),
            .init(step: 8, field: "count.all", value: .integer(4)),
            .init(step: 9, field: "count.limit", value: .integer(2)),
            .init(step: 10, field: "count.limitOffset", value: .integer(2)),
        ])

    public static let changedRowsReevaluatePredicate = PendingFetchSpecification(
        id: ScenarioID(
            suite: "PendingFetchParityTests", test: "changed models are re-evaluated against the predicate in memory"),
        seedRows: seedRows,
        steps: [makePendingChanges, updateFirstRow, deleteSecondRow] + [
            .init(query: .init(observationField: "names.lessThanForty", predicate: .lessThan(40))),
            .init(query: .init(observationField: "names.lessThanForty.limit", predicate: .lessThan(40), limit: 1)),
            .init(query: .init(observationField: "names.greaterThanFifty.offset", predicate: .greaterThan(55), offset: 1)),
        ],
        expectedObservations: [
            .init(step: 3, field: "names.lessThanForty", value: .array([.string("p1")])),
            .init(step: 4, field: "names.lessThanForty.limit", value: .array([.string("p1")])),
            .init(step: 5, field: "names.greaterThanFifty.offset", value: .array([.string("s1")])),
        ])

    public static let excludesPendingChanges = PendingFetchSpecification(
        id: ScenarioID(suite: "PendingFetchParityTests", test: "excluding pending changes returns only stored rows"),
        seedRows: seedRows,
        steps: [makePendingChanges, updateFirstRow, deleteSecondRow,
            .init(query: .init(observationField: "names.stored", includesPendingChanges: false))],
        expectedObservations: [
            .init(step: 3, field: "names.stored", value: .array([.string("s1"), .string("s2"), .string("s3"), .string("s4")])),
        ])

    public static let all = [zeroLimit, storedPaginationBeforePendingMerge, changedRowsReevaluatePredicate, excludesPendingChanges]

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }

    public static var expectedObservationFields: Set<String> {
        Set(all.flatMap { $0.expectedObservations.map(\.field) })
    }
}

public enum PendingFetchExpectationValidator {
    public static func validate(_ result: ScenarioResult, against specification: PendingFetchSpecification) -> Bool {
        guard result.id == specification.id, specification.hasValidObservationSchedule else { return false }
        var observations: [String: (Int, ObservedValue)] = [:]
        for observation in result.observations {
            guard observations.updateValue((observation.step, observation.value.canonicalized), forKey: observation.field) == nil else {
                return false
            }
        }
        let expected = Dictionary(uniqueKeysWithValues: specification.expectedObservations.map {
            ($0.field, ($0.step, $0.value.canonicalized))
        })
        return observations.count == specification.expectedObservations.count
            && observations.allSatisfy { field, actual in
                guard let expected = expected[field] else { return false }
                return actual.0 == expected.0 && actual.1 == expected.1
            }
    }
}

public struct BatchFetchSpecification: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public let name: String
        public let rank: Int64

        public init(name: String, rank: Int64) {
            self.name = name
            self.rank = rank
        }
    }

    public enum Operation: Codable, Equatable, Sendable {
        case expectModelBatchError
        case expectIdentifierBatchError
        case expectSortedIdentifierError
        case saveSeed
        case savedIdentifierCount(sorted: Bool)
        case randomAccessBatch
        case pageBatch
        case filteredBatch
        case batchSizeCount(Int)
        case identifierCount
        case snapshotCounts
    }

    public struct ExpectedObservation: Codable, Equatable, Sendable {
        public let step: Int
        public let field: String
        public let value: ObservedValue

        public init(step: Int, field: String, value: ObservedValue) {
            self.step = step
            self.field = field
            self.value = value
        }
    }

    public struct Step: Codable, Equatable, Sendable {
        public let seedRows: Bool
        public let insertPendingRow: Row?
        public let save: Bool
        public let saveBeforeObservation: Bool
        public let operation: Operation
        public let observationField: String

        public init(
            seedRows: Bool = false,
            insertPendingRow: Row? = nil,
            save: Bool = false,
            saveBeforeObservation: Bool = false,
            observationField: String,
            operation: Operation
        ) {
            self.seedRows = seedRows
            self.insertPendingRow = insertPendingRow
            self.save = save
            self.saveBeforeObservation = saveBeforeObservation
            self.operation = operation
            self.observationField = observationField
        }
    }

    public let id: ScenarioID
    public let seedRows: [Row]
    public let steps: [Step]
    public let expectedObservations: [ExpectedObservation]

    public init(
        id: ScenarioID,
        seedRows: [Row],
        steps: [Step],
        expectedObservations: [ExpectedObservation]
    ) {
        self.id = id
        self.seedRows = seedRows
        self.steps = steps
        self.expectedObservations = expectedObservations
    }

    public var contract: ScenarioContract {
        ScenarioContract(id: id, expectedObservationFields: Set(expectedObservations.map(\.field)))
    }

    public var hasValidObservationSchedule: Bool {
        let fields = steps.map(\.observationField)
        let expectedFields = expectedObservations.map(\.field)
        return fields.count == Set(fields).count
            && expectedFields.count == Set(expectedFields).count
            && fields == expectedFields
            && expectedObservations.enumerated().allSatisfy { index, expected in expected.step == index }
    }
}

public enum BatchFetchScenarioCatalog {
    public static let seedRows: [BatchFetchSpecification.Row] = (0..<7).map {
        .init(name: "n\($0)", rank: Int64(7 - $0))
    }

    public static let batchedFetchesRequireExcludingPendingChanges = BatchFetchSpecification(
        id: ScenarioID(suite: "BatchFetchParityTests", test: "batched fetches require excluding pending changes"),
        seedRows: seedRows,
        steps: [
            .init(observationField: "modelBatch.throwsExpected", operation: .expectModelBatchError),
            .init(observationField: "identifierBatch.throwsExpected", operation: .expectIdentifierBatchError),
        ],
        expectedObservations: [
            .init(step: 0, field: "modelBatch.throwsExpected", value: .bool(true)),
            .init(step: 1, field: "identifierBatch.throwsExpected", value: .bool(true)),
        ])

    public static let sortedIdentifierFetchesRequireExcludingPendingChanges = BatchFetchSpecification(
        id: ScenarioID(
            suite: "BatchFetchParityTests", test: "sorted identifier fetches require excluding pending changes"),
        seedRows: seedRows,
        steps: [
            .init(observationField: "pending.sortedIdentifier.throwsExpected", operation: .expectSortedIdentifierError),
            .init(seedRows: true, saveBeforeObservation: true, observationField: "seed.saved", operation: .saveSeed),
            .init(observationField: "saved.identifierCount", operation: .savedIdentifierCount(sorted: false)),
            .init(observationField: "saved.sortedIdentifierCount", operation: .savedIdentifierCount(sorted: true)),
        ],
        expectedObservations: [
            .init(step: 0, field: "pending.sortedIdentifier.throwsExpected", value: .bool(true)),
            .init(step: 1, field: "seed.saved", value: .null),
            .init(step: 2, field: "saved.identifierCount", value: .integer(7)),
            .init(step: 3, field: "saved.sortedIdentifierCount", value: .integer(7)),
        ])

    public static let randomAccessFetchOrder = BatchFetchSpecification(
        id: ScenarioID(suite: "BatchFetchParityTests", test: "batched results are a random access collection in fetch order"),
        seedRows: seedRows,
        steps: [
            .init(seedRows: true, saveBeforeObservation: true, observationField: "collection.values", operation: .randomAccessBatch),
        ],
        expectedObservations: [
            .init(step: 0, field: "collection.values", value: .object([
                "count": .integer(7),
                "startIndex": .integer(0),
                "endIndex": .integer(7),
                "ranks": .array([.integer(1), .integer(2), .integer(3), .integer(4), .integer(5), .integer(6), .integer(7)]),
                "first": .integer(1),
                "last": .integer(7),
                "slice": .array([.integer(3), .integer(4)]),
                "reversed": .array([.integer(7), .integer(6), .integer(5), .integer(4), .integer(3), .integer(2), .integer(1)]),
                "repeatedAccessSameInstance": .bool(true),
                "sameInstanceAsOrdinaryFetch": .bool(true),
            ])),
        ])

    public static let predicatesLimitsOffsets = BatchFetchSpecification(
        id: ScenarioID(suite: "BatchFetchParityTests", test: "batched fetches honor predicates, limits, and offsets"),
        seedRows: seedRows,
        steps: [
            .init(seedRows: true, saveBeforeObservation: true, observationField: "page.ranks", operation: .pageBatch),
            .init(observationField: "filtered.ranks", operation: .filteredBatch),
        ],
        expectedObservations: [
            .init(step: 0, field: "page.ranks", value: .array([.integer(3), .integer(4), .integer(5), .integer(6)])),
            .init(step: 1, field: "filtered.ranks", value: .array([.integer(4), .integer(5), .integer(6), .integer(7)])),
        ])

    public static func anyBatchSizeReturnsEveryResult(_ batchSize: Int) -> BatchFetchSpecification {
        BatchFetchSpecification(
            id: ScenarioID(
                suite: "BatchFetchParityTests", test: "any batch size returns every result/\(batchSize)"),
            seedRows: seedRows,
            steps: [
                .init(seedRows: true, saveBeforeObservation: true, observationField: "count", operation: .batchSizeCount(batchSize)),
            ],
            expectedObservations: [
                .init(step: 0, field: "count", value: .integer(7)),
            ])
    }

    public static let batchedIdentifiersMatchUnbatchedIdentifiers = BatchFetchSpecification(
        id: ScenarioID(suite: "BatchFetchParityTests", test: "batched identifiers match unbatched identifiers"),
        seedRows: seedRows,
        steps: [
            .init(seedRows: true, saveBeforeObservation: true, observationField: "identifiers.count", operation: .identifierCount),
        ],
        expectedObservations: [
            .init(step: 0, field: "identifiers.count", value: .bool(true)),
        ])

    public static let batchedResultsExcludePendingInsertionsAndKeepSnapshot = BatchFetchSpecification(
        id: ScenarioID(
            suite: "BatchFetchParityTests", test: "batched results exclude pending insertions and keep their snapshot"),
        seedRows: seedRows,
        steps: [
            .init(seedRows: true, saveBeforeObservation: true, observationField: "snapshot.beforeSave.count", operation: .snapshotCounts),
            .init(insertPendingRow: .init(name: "pending", rank: 100), observationField: "snapshot.pendingCount", operation: .snapshotCounts),
            .init(save: true, observationField: "snapshot.afterSave.count", operation: .snapshotCounts),
        ],
        expectedObservations: [
            .init(step: 0, field: "snapshot.beforeSave.count", value: .integer(7)),
            .init(step: 1, field: "snapshot.pendingCount", value: .integer(7)),
            .init(step: 2, field: "snapshot.afterSave.count", value: .integer(7)),
        ])

    public static let all = [
        batchedFetchesRequireExcludingPendingChanges,
        sortedIdentifierFetchesRequireExcludingPendingChanges,
        randomAccessFetchOrder,
        predicatesLimitsOffsets,
        anyBatchSizeReturnsEveryResult(0),
        anyBatchSizeReturnsEveryResult(-1),
        anyBatchSizeReturnsEveryResult(1),
        anyBatchSizeReturnsEveryResult(100),
        batchedIdentifiersMatchUnbatchedIdentifiers,
        batchedResultsExcludePendingInsertionsAndKeepSnapshot,
    ]

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }
}

public enum BatchFetchExpectationValidator {
    public static func validate(_ result: ScenarioResult, against specification: BatchFetchSpecification) -> Bool {
        guard result.id == specification.id, specification.hasValidObservationSchedule else { return false }
        var actual: [String: (Int, ObservedValue)] = [:]
        for observation in result.observations {
            guard actual.updateValue((observation.step, observation.value.canonicalized), forKey: observation.field) == nil else {
                return false
            }
        }
        let expected = Dictionary(uniqueKeysWithValues: specification.expectedObservations.map {
            ($0.field, ($0.step, $0.value.canonicalized))
        })
        return actual.count == expected.count && actual.allSatisfy { field, value in
            expected[field]?.0 == value.0 && expected[field]?.1 == value.1
        }
    }
}

public struct BatchDeleteSpecification: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public let name: String

        public init(name: String) { self.name = name }
    }

    public enum Operation: Codable, Equatable, Sendable {
        case pendingAndRegisteredState
        case cascadePetCount
        case notificationCount
        case denyError
        case transactionRemainingCount
        case noMatchState
    }

    public struct Step: Codable, Equatable, Sendable {
        public let operation: Operation
        public let observationField: String

        public init(operation: Operation, observationField: String) {
            self.operation = operation
            self.observationField = observationField
        }
    }

    public struct ExpectedObservation: Codable, Equatable, Sendable {
        public let step: Int
        public let field: String
        public let value: ObservedValue

        public init(step: Int, field: String, value: ObservedValue) {
            self.step = step
            self.field = field
            self.value = value
        }
    }

    public let id: ScenarioID
    public let steps: [Step]
    public let expectedObservations: [ExpectedObservation]
    public let expectedOSDObservations: [ExpectedObservation]?

    public init(
        id: ScenarioID,
        steps: [Step],
        expectedObservations: [ExpectedObservation],
        expectedOSDObservations: [ExpectedObservation]? = nil
    ) {
        self.id = id
        self.steps = steps
        self.expectedObservations = expectedObservations
        self.expectedOSDObservations = expectedOSDObservations
    }

    public var contract: ScenarioContract {
        ScenarioContract(id: id, expectedObservationFields: Set(expectedObservations.map(\.field)))
    }

    public var hasValidObservationSchedule: Bool {
        let fields = steps.map(\.observationField)
        let expectedFields = expectedObservations.map(\.field)
        return fields.count == Set(fields).count
            && expectedFields.count == Set(expectedFields).count
            && fields == expectedFields
            && expectedObservations.enumerated().allSatisfy { $0.offset == $0.element.step }
    }
}

public enum BatchDeleteScenarioCatalog {
    public static let pendingAndRegisteredState = BatchDeleteSpecification(
        id: ScenarioID(suite: "BatchDeleteParityTests", test: "batch deletes leave pending changes and registered instances alone"),
        steps: [.init(operation: .pendingAndRegisteredState, observationField: "delete.state")],
        expectedObservations: [.init(step: 0, field: "delete.state", value: .object([
            "hasChanges": .bool(true), "insertedCount": .integer(1), "deletedCount": .integer(0),
            "savedADeleted": .bool(false), "savedARegistered": .bool(true), "pendingCRegistered": .bool(true),
            "otherContextNames": .array([.string("b")]), "mainContextNames": .array([.string("b"), .string("c")]),
            "afterSaveNames": .array([.string("b"), .string("c")]),
        ]))],
        expectedOSDObservations: [.init(step: 0, field: "delete.state", value: .object([
            "hasChanges": .bool(true), "insertedCount": .integer(1), "deletedCount": .integer(0),
            "savedADeleted": .bool(true), "savedARegistered": .bool(false), "pendingCRegistered": .bool(true),
            "otherContextNames": .array([.string("b")]), "mainContextNames": .array([.string("b"), .string("c")]),
            "afterSaveNames": .array([.string("b"), .string("c")]),
        ]))])

    public static let cascadeRules = BatchDeleteSpecification(
        id: ScenarioID(suite: "BatchDeleteParityTests", test: "batch deletes apply cascade rules"),
        steps: [.init(operation: .cascadePetCount, observationField: "cascade.petCount")],
        expectedObservations: [.init(step: 0, field: "cascade.petCount", value: .integer(0))])

    public static let noSaveNotifications = BatchDeleteSpecification(
        id: ScenarioID(suite: "BatchDeleteParityTests", test: "batch deletes post no save notifications"),
        steps: [.init(operation: .notificationCount, observationField: "notifications.count")],
        expectedObservations: [.init(step: 0, field: "notifications.count", value: .integer(0))])

    public static let denyRuleError = BatchDeleteSpecification(
        id: ScenarioID(suite: "BatchDeleteParityTests", test: "deny rules make batch deletes throw without deleting"),
        steps: [.init(operation: .denyError, observationField: "deny.error")],
        expectedObservations: [.init(step: 0, field: "deny.error", value: .object([
            "threw": .bool(true), "domain": .string("NSCocoaErrorDomain"), "code": .integer(134060),
            "relationship": .string("BatchParityKeeper.toys"),
            "reason": .string("Delete rule is not supported for batch deletes"),
            "remainingKeepers": .integer(1), "toyStillLinked": .bool(true),
        ]))])

    public static let failedTransactionKeepsDeletes = BatchDeleteSpecification(
        id: ScenarioID(suite: "BatchDeleteParityTests", test: "batch deletes inside a failed transaction stay applied"),
        steps: [.init(operation: .transactionRemainingCount, observationField: "transaction.remainingCount")],
        expectedObservations: [.init(step: 0, field: "transaction.remainingCount", value: .integer(0))])

    public static let noMatchesChangeNothing = BatchDeleteSpecification(
        id: ScenarioID(suite: "BatchDeleteParityTests", test: "batch deletes with no matches change nothing"),
        steps: [.init(operation: .noMatchState, observationField: "noMatch")],
        expectedObservations: [.init(step: 0, field: "noMatch", value: .object([
            "hasChanges": .bool(false), "count": .integer(1),
        ]))])

    public static let all = [
        pendingAndRegisteredState, cascadeRules, noSaveNotifications,
        denyRuleError, failedTransactionKeepsDeletes, noMatchesChangeNothing,
    ]

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }
}

public enum BatchDeleteExpectationValidator {
    public static func validate(
        _ result: ScenarioResult,
        against specification: BatchDeleteSpecification,
        implementation: String = "apple"
    ) -> Bool {
        guard result.id == specification.id, specification.hasValidObservationSchedule else { return false }
        var actual: [String: (Int, ObservedValue)] = [:]
        for observation in result.observations {
            guard actual.updateValue((observation.step, observation.value.canonicalized), forKey: observation.field) == nil else {
                return false
            }
        }
        let expectedObservations = implementation == "openswiftdata"
            ? specification.expectedOSDObservations ?? specification.expectedObservations
            : specification.expectedObservations
        let expected = Dictionary(uniqueKeysWithValues: expectedObservations.map {
            ($0.field, ($0.step, $0.value.canonicalized))
        })
        return actual.count == expected.count && actual.allSatisfy { field, value in
            expected[field]?.0 == value.0 && expected[field]?.1 == value.1
        }
    }
}

public struct CodableParitySpecification: Codable, Equatable, Sendable {
    public struct Place: Codable, Equatable, Sendable {
        public let name: String
        public let city: String
        public let zip: Int64
        public let unit: String?
        public let latitude: Double
        public let verified: Bool

        public init(name: String, city: String, zip: Int64, unit: String? = nil, latitude: Double, verified: Bool) {
            self.name = name
            self.city = city
            self.zip = zip
            self.unit = unit
            self.latitude = latitude
            self.verified = verified
        }
    }

    public enum Query: Codable, Equatable, Sendable {
        case enumRoundTrip
        case compositeRoundTrip
        case cityEqualsParis
        case zipGreaterThan(Int64)
        case nestedMemberPredicates
        case optionalUnitComparisons
        case memberAndScalarCombined
    }

    public let id: ScenarioID
    public let saveBeforeFetch: Bool
    public let places: [Place]
    public let query: Query
    public let expectedObservations: [String: ObservedValue]

    public init(
        id: ScenarioID,
        saveBeforeFetch: Bool,
        places: [Place] = [],
        query: Query,
        expectedObservations: [String: ObservedValue]
    ) {
        self.id = id
        self.saveBeforeFetch = saveBeforeFetch
        self.places = places
        self.query = query
        self.expectedObservations = expectedObservations
    }

    public var contract: ScenarioContract {
        ScenarioContract(id: id, expectedObservationFields: Set(expectedObservations.keys))
    }
}

public enum CodableParityScenarioCatalog {
    private static let places: [CodableParitySpecification.Place] = [
        .init(name: "louvre", city: "Paris", zip: 75001, latitude: 48.86, verified: true),
        .init(name: "flat", city: "Paris", zip: 75011, unit: "4B", latitude: 48.85, verified: false),
        .init(name: "bouchon", city: "Lyon", zip: 69002, latitude: 45.76, verified: false),
    ]

    private static func memberCase(
        _ test: String,
        save: Bool,
        query: CodableParitySpecification.Query,
        field: String,
        value: ObservedValue
    ) -> CodableParitySpecification {
        CodableParitySpecification(
            id: ScenarioID(suite: "CodableMemberPredicateParityTests", test: "\(test)/save=\(save)"),
            saveBeforeFetch: save,
            places: places,
            query: query,
            expectedObservations: [field: value])
    }

    public static let enumRoundTrip = CodableParitySpecification(
        id: ScenarioID(suite: "CodableAttributeParityTests", test: "codable enum attributes load in another context"),
        saveBeforeFetch: true,
        query: .enumRoundTrip,
        expectedObservations: ["enum.name": .string("a"), "enum.kind": .string("b")])

    public static let compositeRoundTrip = CodableParitySpecification(
        id: ScenarioID(suite: "CodableCompositeParityTests", test: "codable composite values load in another context"),
        saveBeforeFetch: true,
        query: .compositeRoundTrip,
        expectedObservations: [
            "composite.address": .object(["city": .string("Paris"), "zip": .integer(75001)]),
            "composite.tags": .array([.object(["city": .string("Lyon"), "zip": .integer(69001)])]),
            "composite.nickname": .string("b"),
        ])

    public static let memberPredicates: [CodableParitySpecification] = [
        memberCase("string member equality", save: false, query: .cityEqualsParis, field: "names", value: .array([.string("flat"), .string("louvre")])),
        memberCase("string member equality", save: true, query: .cityEqualsParis, field: "names", value: .array([.string("flat"), .string("louvre")])),
        memberCase("integer member ordering", save: false, query: .zipGreaterThan(70000), field: "names", value: .array([.string("flat"), .string("louvre")])),
        memberCase("integer member ordering", save: true, query: .zipGreaterThan(70000), field: "names", value: .array([.string("flat"), .string("louvre")])),
        memberCase("nested members", save: false, query: .nestedMemberPredicates, field: "nested", value: .object([
            "verified": .array([.string("louvre")]), "latitudeBelow46": .array([.string("bouchon")]),
        ])),
        memberCase("nested members", save: true, query: .nestedMemberPredicates, field: "nested", value: .object([
            "verified": .array([.string("louvre")]), "latitudeBelow46": .array([.string("bouchon")]),
        ])),
        memberCase("optional member comparisons", save: false, query: .optionalUnitComparisons, field: "optionalUnit", value: .object([
            "nil": .array([.string("bouchon"), .string("louvre")]), "fourB": .array([.string("flat")]),
        ])),
        memberCase("optional member comparisons", save: true, query: .optionalUnitComparisons, field: "optionalUnit", value: .object([
            "nil": .array([.string("bouchon"), .string("louvre")]), "fourB": .array([.string("flat")]),
        ])),
        memberCase("members combine with scalar attributes", save: false, query: .memberAndScalarCombined, field: "names", value: .array([.string("louvre")])),
        memberCase("members combine with scalar attributes", save: true, query: .memberAndScalarCombined, field: "names", value: .array([.string("louvre")])),
    ]

    public static let all = [enumRoundTrip, compositeRoundTrip] + memberPredicates

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }
}

public enum CodableParityExpectationValidator {
    public static func validate(_ result: ScenarioResult, against specification: CodableParitySpecification) -> Bool {
        guard result.id == specification.id else { return false }
        var actual: [String: ObservedValue] = [:]
        for observation in result.observations {
            guard actual.updateValue(observation.value.canonicalized, forKey: observation.field) == nil else { return false }
        }
        return actual == specification.expectedObservations.mapValues(\.canonicalized)
    }
}

public struct ContextNotificationSpecification: Codable, Equatable, Sendable {
    public enum Query: String, Codable, Sendable {
        case rawValues
        case saveNotifications
        case editingState
    }

    public let id: ScenarioID
    public let query: Query
    public let expectedObservations: [String: ObservedValue]
    public let expectedOSDObservations: [String: ObservedValue]?

    public init(
        id: ScenarioID,
        query: Query,
        expectedObservations: [String: ObservedValue],
        expectedOSDObservations: [String: ObservedValue]? = nil
    ) {
        self.id = id
        self.query = query
        self.expectedObservations = expectedObservations
        self.expectedOSDObservations = expectedOSDObservations
    }

    public var contract: ScenarioContract {
        ScenarioContract(id: id, expectedObservationFields: Set(expectedObservations.keys))
    }
}

public enum ContextNotificationScenarioCatalog {
    public static let rawValues = ContextNotificationSpecification(
        id: ScenarioID(suite: "ContextNotificationsParityTests", test: "notification names and keys use SwiftData's raw values"),
        query: .rawValues,
        expectedObservations: [
            "names": .array([.string("ModelContextWillSave"), .string("ModelContextDidSave")]),
            "keys": .array([.string("newQueryGeneration"), .string("invalidatedAll"), .string("inserted"), .string("updated"), .string("deleted")]),
            "insertedKeyRoundTrip": .bool(true),
        ])

    public static let saveNotifications = ContextNotificationSpecification(
        id: ScenarioID(suite: "ContextNotificationsParityTests", test: "saves post willSave without info and didSave only when changes commit"),
        query: .saveNotifications,
        expectedObservations: [
            "names": .array([
                .string("ModelContextWillSave"), .string("ModelContextDidSave"),
                .string("ModelContextWillSave"), .string("ModelContextDidSave"), .string("ModelContextWillSave"),
            ]),
            "willSaveInfoEmpty": .bool(true),
            "firstInsertedCount": .integer(2),
            "firstUpdatedCount": .integer(0),
            "firstDeletedCount": .integer(0),
            "secondInsertedCount": .integer(0),
            "secondUpdatedCount": .integer(1),
            "secondDeletedCount": .integer(1),
        ])

    public static let editingState = ContextNotificationSpecification(
        id: ScenarioID(suite: "ContextNotificationsParityTests", test: "contexts expose author and a stable editing state"),
        query: .editingState,
        expectedObservations: [
            "initialAuthorsNil": .bool(true),
            "sameContextEditingIDStable": .bool(true),
            "differentContextsHaveDifferentEditingIDs": .bool(true),
            "updatedAuthor": .string("me"),
            "contextsCompareByIdentity": .bool(true),
        ])

    public static let all = [rawValues, saveNotifications, editingState]

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }
}

public enum ContextNotificationExpectationValidator {
    public static func validate(_ result: ScenarioResult, against specification: ContextNotificationSpecification) -> Bool {
        guard result.id == specification.id else { return false }
        var actual: [String: ObservedValue] = [:]
        for observation in result.observations {
            guard actual.updateValue(observation.value.canonicalized, forKey: observation.field) == nil else { return false }
        }
        return actual == specification.expectedObservations.mapValues(\.canonicalized)
    }
}

public struct RollbackParitySpecification: Codable, Equatable, Sendable {
    public enum Query: String, Codable, Sendable {
        case committedValues
        case committedRelationship
        case relatedInsertion
        case repeatedEdits
        case editedDeletion
        case insertionAndDeletion
        case relationshipNotSaved
    }

    public let id: ScenarioID
    public let query: Query
    public let expectedObservations: [String: ObservedValue]
    public let expectedOSDObservations: [String: ObservedValue]?

    public init(
        id: ScenarioID,
        query: Query,
        expectedObservations: [String: ObservedValue],
        expectedOSDObservations: [String: ObservedValue]? = nil
    ) {
        self.id = id
        self.query = query
        self.expectedObservations = expectedObservations
        self.expectedOSDObservations = expectedOSDObservations
    }

    public var contract: ScenarioContract {
        ScenarioContract(id: id, expectedObservationFields: Set(expectedObservations.keys))
    }
}

public enum RollbackParityScenarioCatalog {
    private static func scenario(
        _ test: String,
        _ query: RollbackParitySpecification.Query,
        _ expectedObservations: [String: ObservedValue],
        expectedOSDObservations: [String: ObservedValue]? = nil,
        suite: String = "RollbackParityTests"
    ) -> RollbackParitySpecification {
        RollbackParitySpecification(
            id: ScenarioID(suite: suite, test: test), query: query,
            expectedObservations: expectedObservations, expectedOSDObservations: expectedOSDObservations)
    }

    public static let committedValues = scenario(
        "rollback restores committed values immediately and clears change tracking", .committedValues, [
            "age": .integer(1), "name": .string("a"), "tag": .null, "tags": .array([]),
            "modelHasChanges": .bool(false), "contextHasChanges": .bool(false),
            "modelRemainsAttached": .bool(true), "storedAges": .array([.integer(1)]),
            "sameRegisteredInstance": .bool(true),
        ])

    public static let committedRelationship = scenario(
        "rollback restores committed relationship edits", .committedRelationship, [
            "ownerItemCount": .integer(1), "itemOwnerAbsent": .bool(false), "contextHasChanges": .bool(false),
        ], expectedOSDObservations: [
            "ownerItemCount": .integer(0), "itemOwnerAbsent": .bool(true), "contextHasChanges": .bool(false),
        ])

    public static let relatedInsertion = scenario(
        "rollback detaches related insertions and restores saved graph", .relatedInsertion, [
            "ownerItemCount": .integer(1), "itemDetached": .bool(true), "itemOwnerAbsent": .bool(false),
            "ownerHasChanges": .bool(false), "contextHasChanges": .bool(false), "storedItemCount": .integer(0),
        ], expectedOSDObservations: [
            "ownerItemCount": .integer(0), "itemDetached": .bool(true), "itemOwnerAbsent": .bool(true),
            "ownerHasChanges": .bool(false), "contextHasChanges": .bool(false), "storedItemCount": .integer(0),
        ])

    public static let repeatedEdits = scenario(
        "rollback restores first committed values after repeated edits", .repeatedEdits, [
            "ageAfterFirstRollback": .integer(3), "unchangedAfterFirstRollback": .bool(true),
            "hasChangesAfterSecondEdit": .bool(true), "ageAfterSecondRollback": .integer(4),
            "unchangedAfterSecondRollback": .bool(true),
        ], expectedOSDObservations: [
            "ageAfterFirstRollback": .integer(1), "unchangedAfterFirstRollback": .bool(true),
            "hasChangesAfterSecondEdit": .bool(true), "ageAfterSecondRollback": .integer(1),
            "unchangedAfterSecondRollback": .bool(true),
        ])

    public static let editedDeletion = scenario(
        "rollback restores values when an edited model is deleted", .editedDeletion, [
            "age": .integer(2), "notDeleted": .bool(true), "modelRemainsAttached": .bool(true),
            "contextHasChanges": .bool(false),
        ], expectedOSDObservations: [
            "age": .integer(1), "notDeleted": .bool(true), "modelRemainsAttached": .bool(true),
            "contextHasChanges": .bool(false),
        ])

    public static let insertionAndDeletion = scenario(
        "rollback detaches insertions and restores deletions", .insertionAndDeletion, [
            "rolledBackInsertionDetached": .bool(true), "rolledBackInsertionNotDeleted": .bool(true),
            "insertedModelsEmpty": .bool(true), "insertionValueRetained": .string("b"),
            "deletionWasApplied": .bool(true), "restoredDeletionNotDeleted": .bool(true),
            "restoredDeletionAttached": .bool(true), "storedOwnerCount": .integer(1),
        ])

    public static let relationshipNotSaved = scenario(
        "rolled back relationship edits are not saved", .relationshipNotSaved, [
            "changedModelsEmpty": .bool(true), "storedRelationshipCount": .integer(0),
        ], suite: "RollbackRelationshipParityTests")

    public static let all = [
        committedValues, committedRelationship, relatedInsertion, repeatedEdits, editedDeletion,
        insertionAndDeletion, relationshipNotSaved,
    ]

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }
}

public enum RollbackParityExpectationValidator {
    public static func validate(
        _ result: ScenarioResult,
        against specification: RollbackParitySpecification,
        implementation: String = "apple"
    ) -> Bool {
        guard result.id == specification.id else { return false }
        var actual: [String: ObservedValue] = [:]
        for observation in result.observations {
            guard actual.updateValue(observation.value.canonicalized, forKey: observation.field) == nil else { return false }
        }
        let expectedObservations = implementation == "openswiftdata"
            ? specification.expectedOSDObservations ?? specification.expectedObservations
            : specification.expectedObservations
        return actual == expectedObservations.mapValues(\.canonicalized)
    }
}

public struct ModelContextParitySpecification: Codable, Equatable, Sendable {
    public enum Query: String, Codable, Sendable {
        case temporaryModelLookup
        case crossContextModelLookup
        case processPendingChanges
        case transactionSavesChanges
        case deletedInsertionState
        case reinsertDeletedInsertion
        case rollbackDeletedInsertion
        case fetchDescriptorDefaults
        case fetchDescriptorProperties
        case fetchDescriptorEquality
    }

    public let id: ScenarioID
    public let query: Query
    public let expectedObservations: [String: ObservedValue]
    public let expectedOSDObservations: [String: ObservedValue]?

    public init(
        id: ScenarioID,
        query: Query,
        expectedObservations: [String: ObservedValue],
        expectedOSDObservations: [String: ObservedValue]? = nil
    ) {
        self.id = id
        self.query = query
        self.expectedObservations = expectedObservations
        self.expectedOSDObservations = expectedOSDObservations
    }

    public var contract: ScenarioContract {
        ScenarioContract(id: id, expectedObservationFields: Set(expectedObservations.keys))
    }
}

public enum ModelContextParityScenarioCatalog {
    private static func scenario(
        _ suite: String,
        _ test: String,
        _ query: ModelContextParitySpecification.Query,
        _ expected: [String: ObservedValue],
        expectedOSDObservations: [String: ObservedValue]? = nil
    ) -> ModelContextParitySpecification {
        ModelContextParitySpecification(
            id: ScenarioID(suite: suite, test: test), query: query,
            expectedObservations: expected, expectedOSDObservations: expectedOSDObservations)
    }

    public static let temporaryModelLookup = scenario(
        "ModelContextParityTests", "model(for:) returns the registered instance, including for temporary identifiers",
        .temporaryModelLookup, ["sameInstanceBeforeSave": .bool(true), "sameInstanceAfterSave": .bool(true)])

    public static let crossContextModelLookup = scenario(
        "ModelContextParityTests", "model(for:) loads and registers saved models in another context",
        .crossContextModelLookup, [
            "name": .string("a"), "attachedToOtherContext": .bool(true), "unchanged": .bool(true),
            "notDeleted": .bool(true), "lookupStable": .bool(true), "registeredLookupStable": .bool(true),
        ])

    public static let processPendingChanges = scenario(
        "ModelContextParityTests", "processing pending changes keeps them pending", .processPendingChanges, [
            "hasChanges": .bool(true), "insertedCount": .integer(1),
        ])

    public static let transactionSavesChanges = scenario(
        "ModelContextParityTests", "a transaction saves changes made before and inside it", .transactionSavesChanges, [
            "hasChangesAfterTransaction": .bool(false), "savedCount": .integer(2),
        ])

    public static let deletedInsertionState = scenario(
        "DeletedInsertionParityTests", "a deleted insertion is reported as inserted and deleted until saved",
        .deletedInsertionState, [
            "deletedBeforeSave": .bool(true), "attachedBeforeSave": .bool(true), "hasChangesBeforeSave": .bool(true),
            "insertedCountBeforeSave": .integer(1), "deletedCountBeforeSave": .integer(1),
            "fetchCountBeforeSave": .integer(0), "detachedAfterSave": .bool(true),
            "notDeletedAfterSave": .bool(true), "hasChangesAfterSave": .bool(false),
            "insertedCountAfterSave": .integer(0), "deletedCountAfterSave": .integer(0),
            "storedCountAfterSave": .integer(0),
        ])

    public static let reinsertDeletedInsertion = scenario(
        "DeletedInsertionParityTests", "inserting a deleted insertion again does nothing", .reinsertDeletedInsertion, [
            "stillDeleted": .bool(true), "insertedCount": .integer(1), "deletedCount": .integer(1),
        ])

    public static let rollbackDeletedInsertion = scenario(
        "DeletedInsertionParityTests", "rolling back detaches a deleted insertion", .rollbackDeletedInsertion, [
            "detached": .bool(true), "notDeleted": .bool(true), "hasChanges": .bool(true),
        ], expectedOSDObservations: [
            "detached": .bool(true), "notDeleted": .bool(true), "hasChanges": .bool(false),
        ])

    public static let fetchDescriptorDefaults = scenario(
        "FetchDescriptorParityTests", "defaults match SwiftData", .fetchDescriptorDefaults, [
            "predicateAbsent": .bool(true), "sortEmpty": .bool(true), "fetchLimitAbsent": .bool(true),
            "fetchOffsetAbsent": .bool(false), "includePendingChanges": .bool(true),
            "propertiesToFetchEmpty": .bool(true), "prefetchRelationshipsEmpty": .bool(true),
        ], expectedOSDObservations: [
            "predicateAbsent": .bool(true), "sortEmpty": .bool(true), "fetchLimitAbsent": .bool(true),
            "fetchOffsetAbsent": .bool(true), "includePendingChanges": .bool(true),
            "propertiesToFetchEmpty": .bool(true), "prefetchRelationshipsEmpty": .bool(true),
        ])

    public static let fetchDescriptorProperties = scenario(
        "FetchDescriptorParityTests", "properties to fetch is a mutable array", .fetchDescriptorProperties,
        ["propertyCount": .integer(1), "containsName": .bool(true)])

    public static let fetchDescriptorEquality = scenario(
        "FetchDescriptorParityTests", "descriptors compare every option", .fetchDescriptorEquality, [
            "samePredicateAndSortEqual": .bool(false), "differentPredicateUnequal": .bool(true),
            "differentLimitUnequal": .bool(true), "differentPendingOptionUnequal": .bool(true),
        ], expectedOSDObservations: [
            "samePredicateAndSortEqual": .bool(true), "differentPredicateUnequal": .bool(true),
            "differentLimitUnequal": .bool(true), "differentPendingOptionUnequal": .bool(true),
        ])

    public static let all = [
        temporaryModelLookup, crossContextModelLookup, processPendingChanges, transactionSavesChanges,
        deletedInsertionState, reinsertDeletedInsertion, rollbackDeletedInsertion,
        fetchDescriptorDefaults, fetchDescriptorProperties, fetchDescriptorEquality,
    ]

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }
}

public enum ModelContextParityExpectationValidator {
    public static func validate(
        _ result: ScenarioResult,
        against specification: ModelContextParitySpecification,
        implementation: String = "apple"
    ) -> Bool {
        guard result.id == specification.id else { return false }
        var actual: [String: ObservedValue] = [:]
        for observation in result.observations {
            guard actual.updateValue(observation.value.canonicalized, forKey: observation.field) == nil else { return false }
        }
        let expectedObservations = implementation == "openswiftdata"
            ? specification.expectedOSDObservations ?? specification.expectedObservations
            : specification.expectedObservations
        return actual == expectedObservations.mapValues(\.canonicalized)
    }
}

public struct HistoryParitySpecification: Codable, Equatable, Sendable {
    public enum Query: String, Codable, Sendable {
        case recordsChangedTransactions
        case descriptors
        case tokenRoundTrip
        case deletingHistoryExpiresTokens
    }

    public let id: ScenarioID
    public let query: Query
    public let expectedObservations: [String: ObservedValue]

    public init(id: ScenarioID, query: Query, expectedObservations: [String: ObservedValue]) {
        self.id = id
        self.query = query
        self.expectedObservations = expectedObservations
    }

    public var contract: ScenarioContract {
        ScenarioContract(id: id, expectedObservationFields: Set(expectedObservations.keys))
    }
}

public enum HistoryParityScenarioCatalog {
    private static func scenario(
        _ test: String,
        _ query: HistoryParitySpecification.Query,
        _ expectedObservations: [String: ObservedValue]
    ) -> HistoryParitySpecification {
        HistoryParitySpecification(
            id: ScenarioID(suite: "HistoryParityTests", test: test), query: query,
            expectedObservations: expectedObservations)
    }

    public static let recordsChangedTransactions = scenario(
        "each save with changes records one transaction", .recordsChangedTransactions, [
            "initialCount": .integer(0), "transactionCount": .integer(4),
            "authors": .array([.string("alice"), .string("alice"), .null, .null]),
            "idsMatchTransactions": .bool(true), "transactionIDsIncrease": .bool(true),
            "tokensIncrease": .bool(true), "tokenValuesPresent": .bool(true),
            "bundleIdentifierPresent": .bool(true), "processIdentifierPresent": .bool(true),
            "firstTransactionChangeCount": .integer(2), "firstChangeIsInsert": .bool(true),
            "secondChangeIsUpdate": .bool(true), "updatedAttributes": .stringSet(["count", "name"]),
            "thirdChangeIsDelete": .bool(true), "deletedCode": .string("B"),
            "deletedNameAbsent": .bool(true), "tombstoneCount": .integer(1),
        ])

    public static let descriptors = scenario(
        "descriptors filter, sort, and limit transactions", .descriptors, [
            "tokenFilterCount": .integer(2), "authorFilterCount": .integer(2),
            "limitCount": .integer(2), "reverseOrderMatches": .bool(true), "defaultLimit": .integer(0),
        ])

    public static let tokenRoundTrip = scenario(
        "tokens encode their store and transaction", .tokenRoundTrip, [
            "storeTokenCount": .integer(1), "tokenRoundTripEqual": .bool(true),
            "tokenValueEntryCount": .integer(1),
        ])

    public static let deletingHistoryExpiresTokens = scenario(
        "deleting history expires tokens that refer to deleted transactions", .deletingHistoryExpiresTokens, [
            "remainingAfterPrefixDelete": .integer(2), "laterTokenExpired": .bool(true),
            "deletedTokenExpired": .bool(true), "emptyAfterDeleteAll": .bool(true),
        ])

    public static let all = [recordsChangedTransactions, descriptors, tokenRoundTrip, deletingHistoryExpiresTokens]

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }
}

public enum HistoryParityExpectationValidator {
    public static func validate(_ result: ScenarioResult, against specification: HistoryParitySpecification) -> Bool {
        guard result.id == specification.id else { return false }
        var actual: [String: ObservedValue] = [:]
        for observation in result.observations {
            guard actual.updateValue(observation.value.canonicalized, forKey: observation.field) == nil else { return false }
        }
        return actual == specification.expectedObservations.mapValues(\.canonicalized)
    }
}

public struct SchemaIntrospectionSpecification: Codable, Equatable, Sendable {
    public let id: ScenarioID
    public let expectedObservations: [String: ObservedValue]

    public init(id: ScenarioID, expectedObservations: [String: ObservedValue]) {
        self.id = id
        self.expectedObservations = expectedObservations
    }

    public var contract: ScenarioContract {
        ScenarioContract(id: id, expectedObservationFields: Set(expectedObservations.keys))
    }
}

public enum SchemaIntrospectionScenarioCatalog {
    public static let entitiesByModelType = SchemaIntrospectionSpecification(
        id: ScenarioID(suite: "SchemaIntrospectionParityTests", test: "entities are found by model type"),
        expectedObservations: [
            "author.entityName": .string("IntrospectionAuthor"),
            "author.attributes": .stringSet(["bio", "handle"]),
            "author.relationships": .stringSet(["books"]),
            "author.properties": .stringSet(["bio", "books", "handle"]),
            "book.entityName": .string("IntrospectionBook"),
            "author.entitiesLookup": .bool(true),
            "book.entitiesLookup": .bool(true),
            "entities.names": .stringSet(["IntrospectionAuthor", "IntrospectionBook"]),
        ])

    public static let propertyFlags = SchemaIntrospectionSpecification(
        id: ScenarioID(suite: "SchemaIntrospectionParityTests", test: "property flags describe attributes and relationships"),
        expectedObservations: [
            "author.handle.flags": .object([
                "attribute": .bool(true), "relationship": .bool(false), "unique": .bool(true),
                "optional": .bool(false), "transient": .bool(false), "transformable": .bool(false),
            ]),
            "author.bio.optional": .bool(true),
            "author.books.flags": .object([
                "relationship": .bool(false), "attribute": .bool(false), "toOne": .bool(false),
                "inverse": .string("author"), "deleteRule": .string("cascade"),
            ]),
            "book.author.toOne": .bool(true),
        ])

    public static let constraintsAndIndices = SchemaIntrospectionSpecification(
        id: ScenarioID(suite: "SchemaIntrospectionParityTests", test: "constraints and indices are listed by property name"),
        expectedObservations: [
            "author.uniquenessConstraints": .array([.array([.string("handle")])]),
            "book.indices": .array([.array([.string("binary"), .string("title")])]),
            "entities.names": .stringSet(["IntrospectionAuthor", "IntrospectionBook"]),
        ])

    public static let schemaRoundTrip = SchemaIntrospectionSpecification(
        id: ScenarioID(suite: "SchemaIntrospectionParityTests", test: "schemas round-trip through Codable and files"),
        expectedObservations: [
            "roundTrip.version": .array([.integer(2), .integer(1), .integer(0)]),
            "roundTrip.entities": .stringSet(["IntrospectionAuthor", "IntrospectionBook"]),
            "roundTrip.author.properties": .stringSet(["bio", "books", "handle"]),
            "roundTrip.author.uniquenessConstraints": .array([.array([.string("handle")])]),
            "roundTrip.book.indices": .array([]),
            "roundTrip.entities.names": .stringSet(["IntrospectionAuthor", "IntrospectionBook"]),
        ])

    public static let all: [SchemaIntrospectionSpecification] = [
        entitiesByModelType, propertyFlags, constraintsAndIndices, schemaRoundTrip,
    ]

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }
}

public enum SchemaIntrospectionExpectationValidator {
    public static func validate(_ result: ScenarioResult, against specification: SchemaIntrospectionSpecification) -> Bool {
        guard result.id == specification.id else { return false }
        var observations: [String: ObservedValue] = [:]
        for observation in result.observations {
            guard observations.updateValue(observation.value.canonicalized, forKey: observation.field) == nil else {
                return false
            }
        }
        return observations == specification.expectedObservations.mapValues(\.canonicalized)
    }
}

public struct SchemaModelTypesSpecification: Codable, Equatable, Sendable {
    public let id: ScenarioID
    public let expectedObservations: [String: ObservedValue]

    public init(id: ScenarioID, expectedObservations: [String: ObservedValue]) {
        self.id = id
        self.expectedObservations = expectedObservations
    }

    public var contract: ScenarioContract {
        ScenarioContract(id: id, expectedObservationFields: Set(expectedObservations.keys))
    }
}

public enum SchemaModelTypesScenarioCatalog {
    public static let entitiesInNameOrder = SchemaModelTypesSpecification(
        id: ScenarioID(suite: "SchemaModelTypesParityTests", test: "a schema built from types lists entities in name order"),
        expectedObservations: [
            "entities.names": .array([.string("SchemaParityStop"), .string("SchemaParityTrip")]),
            "schema.version": .array([.integer(1), .integer(0), .integer(0)]),
            "schema.variadicEntityCount": .integer(2),
        ])

    public static let relationshipDestinations = SchemaModelTypesSpecification(
        id: ScenarioID(
            suite: "SchemaModelTypesParityTests",
            test: "a schema includes models reachable only as relationship destinations"),
        expectedObservations: [
            "stop.lookup": .bool(true),
            "trip.entityName": .string("SchemaParityTrip"),
        ])

    public static let emptySchema = SchemaModelTypesSpecification(
        id: ScenarioID(suite: "SchemaModelTypesParityTests", test: "an empty schema has no entities and version 1.0.0"),
        expectedObservations: [
            "entities.names": .stringSet([]),
            "schema.version": .array([.integer(1), .integer(0), .integer(0)]),
        ])

    public static let versionedSchema = SchemaModelTypesSpecification(
        id: ScenarioID(suite: "SchemaModelTypesParityTests", test: "a versioned schema carries its version"),
        expectedObservations: [
            "schema.version": .array([.integer(2), .integer(0), .integer(0)]),
            "entities.count": .integer(2),
        ])

    public static let containerRoundTrip = SchemaModelTypesSpecification(
        id: ScenarioID(
            suite: "SchemaModelTypesParityTests",
            test: "a container opened from a type-built schema saves and fetches models"),
        expectedObservations: [
            "fetched.tripNames": .array([.string("Coast")]),
            "fetched.stopLabels": .array([.string("A")]),
        ])

    public static let all: [SchemaModelTypesSpecification] = [
        entitiesInNameOrder, relationshipDestinations, emptySchema, versionedSchema, containerRoundTrip,
    ]

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }
}

public enum SchemaModelTypesExpectationValidator {
    public static func validate(_ result: ScenarioResult, against specification: SchemaModelTypesSpecification) -> Bool {
        guard result.id == specification.id else { return false }
        var observations: [String: ObservedValue] = [:]
        for observation in result.observations {
            guard observations.updateValue(observation.value.canonicalized, forKey: observation.field) == nil else {
                return false
            }
        }
        return observations == specification.expectedObservations.mapValues(\.canonicalized)
    }
}

public struct StoreIdentifierSpecification: Codable, Equatable, Sendable {
    public let id: ScenarioID
    public let expectedObservationFields: Set<String>

    public init(id: ScenarioID, expectedObservationFields: Set<String>) {
        self.id = id
        self.expectedObservationFields = expectedObservationFields
    }

    public var contract: ScenarioContract {
        ScenarioContract(id: id, expectedObservationFields: expectedObservationFields)
    }
}

public enum StoreIdentifierScenarioCatalog {
    public static let savedIdentifierIsUUID = StoreIdentifierSpecification(
        id: ScenarioID(suite: "StoreIdentifierParityTests", test: "saved identifiers use a UUID store identifier"),
        expectedObservationFields: ["temporary.storeIdentifierAbsent", "saved.storeIdentifierPresent", "saved.storeIdentifierIsUUID"])

    public static let identifierSurvivesReopen = StoreIdentifierSpecification(
        id: ScenarioID(suite: "StoreIdentifierParityTests", test: "the store identifier survives reopening the store"),
        expectedObservationFields: [
            "reopened.identifierEqual", "reopened.storeIdentifierEqual", "reopened.fetchName", "reopened.registeredName",
        ])

    public static let separateStoresDiffer = StoreIdentifierSpecification(
        id: ScenarioID(suite: "StoreIdentifierParityTests", test: "separate stores have different identifiers"),
        expectedObservationFields: ["stores.identifiersDiffer"])

    public static let all: [StoreIdentifierSpecification] = [
        savedIdentifierIsUUID, identifierSurvivesReopen, separateStoresDiffer,
    ]

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }
}

public struct ModelIdentitySpecification: Codable, Equatable, Sendable {
    public let id: ScenarioID
    public let expectedObservationFields: Set<String>

    public init(id: ScenarioID, expectedObservationFields: Set<String>) {
        self.id = id
        self.expectedObservationFields = expectedObservationFields
    }

    public var contract: ScenarioContract {
        ScenarioContract(id: id, expectedObservationFields: expectedObservationFields)
    }
}

public enum ModelIdentityScenarioCatalog {
    public static let instancesCompareByIdentity = ModelIdentitySpecification(
        id: ScenarioID(suite: "ModelIdentityParityTests", test: "models compare by instance identity"),
        expectedObservationFields: [
            "instances.sameReferenceEqual", "instances.distinctEqual", "instances.distinctHashesDiffer",
            "instances.remainUnequalAfterSave",
        ])

    public static let idIsPersistentIdentifier = ModelIdentitySpecification(
        id: ScenarioID(suite: "ModelIdentityParityTests", test: "the id is the persistent identifier"),
        expectedObservationFields: ["id.matchesPersistentIDBeforeSave", "id.matchesPersistentIDAfterSave"])

    public static let savingReplacesTemporaryID = ModelIdentitySpecification(
        id: ScenarioID(suite: "ModelIdentityParityTests", test: "saving replaces the temporary identifier"),
        expectedObservationFields: ["id.changedAfterSave", "id.temporaryStoreAbsent", "id.savedStorePresent"])

    public static let contextsUseDistinctInstances = ModelIdentitySpecification(
        id: ScenarioID(
            suite: "ModelIdentityParityTests",
            test: "instances of one row in two contexts hash equally but compare unequal"),
        expectedObservationFields: [
            "contexts.distinctReferences", "contexts.modelsUnequal", "contexts.hashesEqual", "contexts.setCount",
        ])

    public static let declaredIDReplacesIdentifierID = ModelIdentitySpecification(
        id: ScenarioID(suite: "ModelIdentityParityTests", test: "a declared id property replaces the identifier id"),
        expectedObservationFields: ["customID.matchesDeclaredUUID"])

    public static let modelsConformToProtocols = ModelIdentitySpecification(
        id: ScenarioID(suite: "ModelIdentityParityTests", test: "models are Identifiable and Observable"),
        expectedObservationFields: ["conformance.identifiable", "conformance.observable"])

    public static let all: [ModelIdentitySpecification] = [
        instancesCompareByIdentity, idIsPersistentIdentifier, savingReplacesTemporaryID,
        contextsUseDistinctInstances, declaredIDReplacesIdentifierID, modelsConformToProtocols,
    ]

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }
}

public struct UniqueConstraintSpecification: Codable, Equatable, Sendable {
    public enum Query: String, Codable, Sendable {
        case insertingDuplicateOverwrites
        case mergedDuplicateEditsDoNotPersist
        case mergedDuplicateIdentifier
        case deletingMergedDuplicate
        case duplicatesInOneSave
        case updatingIntoConflict
        case compositeConstraints
    }

    public let id: ScenarioID
    public let query: Query
    public let expectedObservationFields: Set<String>

    public init(
        id: ScenarioID,
        query: Query,
        expectedObservationFields: Set<String>
    ) {
        self.id = id
        self.query = query
        self.expectedObservationFields = expectedObservationFields
    }

    public var contract: ScenarioContract {
        ScenarioContract(id: id, expectedObservationFields: expectedObservationFields)
    }
}

public enum UniqueConstraintScenarioCatalog {
    private static func scenario(
        _ test: String,
        _ query: UniqueConstraintSpecification.Query,
        _ fields: Set<String>
    ) -> UniqueConstraintSpecification {
        UniqueConstraintSpecification(
            id: ScenarioID(suite: "UniqueConstraintParityTests", test: test),
            query: query,
            expectedObservationFields: fields)
    }

    public static let insertingDuplicateOverwrites = scenario(
        "inserting a duplicate overwrites the stored row and refreshes the existing instance",
        .insertingDuplicateOverwrites,
        [
            "preSaveCount", "storedRows", "originalValue", "originalAttached", "originalDeleted",
            "duplicateAttached", "duplicateIDChangedOnSave", "contextClean", "fetchedOriginalInstance",
        ])

    public static let mergedDuplicateEditsDoNotPersist = scenario(
        "edits to a merged duplicate do not reach the store", .mergedDuplicateEditsDoNotPersist,
        ["hasChangesAfterEdit", "storedRowsAfterSecondSave"])

    public static let mergedDuplicateIdentifier = scenario(
        "a merged duplicate gets a permanent identifier", .mergedDuplicateIdentifier,
        ["duplicateIDChangedOnSave", "duplicateRegistered", "duplicateIDDiffersFromSurvivor"])

    public static let deletingMergedDuplicate = scenario(
        "deleting a merged duplicate leaves the merged row", .deletingMergedDuplicate,
        ["storedRowsAfterDelete"])

    public static let duplicatesInOneSave = scenario(
        "duplicates inserted in one save collapse into one row", .duplicatesInOneSave,
        ["storedCount", "storedRows"])

    public static let updatingIntoConflict = scenario(
        "updating into a conflict merges the changed values and removes the updated row",
        .updatingIntoConflict,
        ["storedRows", "updatedIDUnchanged", "updatedAttached", "updatedDeleted", "updatedValue"])

    public static let compositeConstraints = scenario(
        "composite and multiple constraints each merge conflicting inserts", .compositeConstraints,
        ["storedRows"])

    public static let all = [
        insertingDuplicateOverwrites, mergedDuplicateEditsDoNotPersist, mergedDuplicateIdentifier,
        deletingMergedDuplicate, duplicatesInOneSave, updatingIntoConflict, compositeConstraints,
    ]

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }
}

public enum UniqueConstraintExpectationValidator {
    public static func validate(_ result: ScenarioResult, against specification: UniqueConstraintSpecification) -> Bool {
        guard result.id == specification.id else { return false }
        let fields = result.observations.map(\.field)
        return fields.count == Set(fields).count && Set(fields) == specification.expectedObservationFields
    }
}

public struct ModelConfigurationSpecification: Codable, Equatable, Sendable {
    public let id: ScenarioID
    public let expectedObservations: [String: ObservedValue]

    public init(id: ScenarioID, expectedObservations: [String: ObservedValue]) {
        self.id = id
        self.expectedObservations = expectedObservations
    }

    public var contract: ScenarioContract {
        ScenarioContract(id: id, expectedObservationFields: Set(expectedObservations.keys))
    }
}

public enum ModelConfigurationScenarioCatalog {
    public static let nonComparableSelectionReason =
        "Apple's SwiftData selection wrappers expose no public selection discriminator."

    public static let defaultConfiguration = ModelConfigurationSpecification(
        id: ScenarioID(
            suite: "ModelConfigurationParityTests",
            test: "the default configuration stores default.store in Application Support"),
        expectedObservations: [
            "name": .string("default"), "url.fileName": .string("default.store"),
            "url.parent": .string("Application Support"),
            "idMatchesURL": .bool(true), "inMemory": .bool(false), "allowsSave": .bool(true),
            "hasSchema": .bool(false), "hasGroupIdentifier": .bool(false), "hasCloudIdentifier": .bool(false),
        ])

    public static let inMemoryConfiguration = ModelConfigurationSpecification(
        id: ScenarioID(suite: "ModelConfigurationParityTests", test: "in-memory configurations use dev null"),
        expectedObservations: [
            "default.inMemory": .bool(true), "default.url": .string("/dev/null"),
            "named.inMemory": .bool(true), "named.url": .string("/dev/null"), "named.name": .string("Named"),
        ])

    public static let namedConfiguration = ModelConfigurationSpecification(
        id: ScenarioID(suite: "ModelConfigurationParityTests", test: "named configurations use the name as the file stem"),
        expectedObservations: [
            "named.url.fileName": .string("Named.store"), "nilName.defaults": .string("default"),
            "named.url.parent": .string("Application Support"),
            "slashName.fileName": .string("b.store"),
        ])

    public static let explicitURLConfiguration = ModelConfigurationSpecification(
        id: ScenarioID(suite: "ModelConfigurationParityTests", test: "explicit URLs are kept and the name defaults"),
        expectedObservations: [
            "url.kept": .bool(true), "defaultName": .string("default"), "explicitName": .string("X"),
        ])

    public static let typeScopedSchema = ModelConfigurationSpecification(
        id: ScenarioID(suite: "ModelConfigurationParityTests", test: "type-scoped configurations carry a schema"),
        expectedObservations: [
            "typed.entities": .stringSet(["ConfigurationParityThing"]), "typed.name": .string("default"),
            "typed.inMemory": .bool(true), "mutable.schemaEntityCount": .integer(1),
        ])

    public static let cloudAndGroupSelections = ModelConfigurationSpecification(
        id: ScenarioID(suite: "ModelConfigurationParityTests", test: "cloud and group selections are reported"),
        expectedObservations: ["selected.cloudIdentifierMatches": .bool(true)])

    public static let groupSelectionKind = ScenarioID(
        suite: "ModelConfigurationParityTests", test: "cloud and group selections are reported/group selection kind")

    public static let equalityIncludesCoreFields = ModelConfigurationSpecification(
        id: ScenarioID(suite: "ModelConfigurationParityTests", test: "equality compares name, url, schema, save permission, and storage"),
        expectedObservations: [
            "equality.defaults": .bool(true), "equality.memoryDefaults": .bool(true),
            "equality.nameDifference": .bool(false), "equality.saveDifference": .bool(false),
            "equality.memoryNameDifference": .bool(false), "equality.sameURLDifferentName": .bool(false),
            "equality.differentSchemas": .bool(false), "equality.schemaPresence": .bool(false),
        ])

    public static let cloudAndGroupExcludedFromEquality = ModelConfigurationSpecification(
        id: ScenarioID(suite: "ModelConfigurationParityTests", test: "cloud and group selections do not affect equality"),
        expectedObservations: ["equality.cloudSelection": .bool(true), "equality.groupSelection": .bool(true)])

    public static let hashIgnoresSchema = ModelConfigurationSpecification(
        id: ScenarioID(suite: "ModelConfigurationParityTests", test: "hashing ignores the schema"),
        expectedObservations: ["hash.sameConfiguration": .bool(true), "hash.differentSchema": .bool(true)])

    public static let debugDescription = ModelConfigurationSpecification(
        id: ScenarioID(suite: "ModelConfigurationParityTests", test: "debug description lists every setting"),
        expectedObservations: [
            "debug.defaultFieldsPresent": .bool(true), "debug.customFieldsPresent": .bool(true),
        ])

    public static let all: [ModelConfigurationSpecification] = [
        defaultConfiguration, inMemoryConfiguration, namedConfiguration, explicitURLConfiguration, typeScopedSchema,
        cloudAndGroupSelections, equalityIncludesCoreFields, cloudAndGroupExcludedFromEquality, hashIgnoresSchema,
        debugDescription,
    ]

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }

    public static var nonComparableSelectionIDs: [ScenarioID] {
        [groupSelectionKind]
    }

    public static var nonComparableSelectionIDStrings: [String] {
        nonComparableSelectionIDs.map(\.description)
    }
}

public enum ModelConfigurationContainerScenarioCatalog {
    public static let invalidName = ModelConfigurationSpecification(
        id: ScenarioID(
            suite: "ModelConfigurationContainerParityTests", test: "containers reject configurations with invalid names"),
        expectedObservations: ["invalidName.containerRejected": .bool(true)])

    public static let independentInMemoryStores = ModelConfigurationSpecification(
        id: ScenarioID(
            suite: "ModelConfigurationContainerParityTests", test: "in-memory stores with the same name are independent"),
        expectedObservations: ["secondStore.fetchCount": .integer(0)])

    public static let nestedFileStore = ModelConfigurationSpecification(
        id: ScenarioID(
            suite: "ModelConfigurationContainerParityTests", test: "file stores create missing parent directories"),
        expectedObservations: ["saved.fileExists": .bool(true), "saved.fetchNames": .array([.string("x")])])

    public static let all = [invalidName, independentInMemoryStores, nestedFileStore]

    public static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id.description, $0.contract) })
    }
}

public enum ScenarioExpectationValidator {
    public static func validate(_ result: ScenarioResult, against specification: PredicateMembershipSpecification) -> Bool {
        guard result.id == specification.id else { return false }
        var observed: [String: ObservedValue] = [:]
        for observation in result.observations {
            guard observed.updateValue(observation.value.canonicalized, forKey: observation.field) == nil else {
                return false
            }
        }
        let expected = specification.expectedObservations.mapValues(\.canonicalized)
        return observed == expected
    }
}

public struct CoverageMatrixEntry: Codable, Equatable, Sendable {
    public let sourceCase: String
    public let scenarioIDs: [String]
    public let outcomes: [String: String]
    public let observations: [String: [String]]
    public let reasonCategory: String?
    public let rationale: String?

    public init(
        sourceCase: String,
        scenarioIDs: [String],
        outcomes: [String: String],
        observations: [String: [String]],
        reasonCategory: String? = nil,
        rationale: String? = nil
    ) {
        self.sourceCase = sourceCase
        self.scenarioIDs = scenarioIDs
        self.outcomes = outcomes
        self.observations = observations
        self.reasonCategory = reasonCategory
        self.rationale = rationale
    }

    public var sourceStatus: String {
        let values = Set(outcomes.values)
        if values == ["non-comparable"] { return "non-comparable" }
        if values.contains("divergent") { return "divergent" }
        if values.contains("compared") { return "compared" }
        return "invalid"
    }
}

public struct CoverageValidationReport: Codable, Equatable, Sendable {
    public let discoveredCaseCount: Int
    public let coverageValid: Bool
    public let mappedSourceCaseCount: Int
    public let declaredComparedSourceCaseCount: Int
    public let declaredDivergentSourceCaseCount: Int
    public let declaredNonComparableSourceCaseCount: Int
    public let declaredComparedScenarioCount: Int
    public let declaredDivergentScenarioCount: Int
    public let declaredNonComparableScenarioCount: Int
    public let discoveredCases: [String]
    public let pendingCases: [String]
    public let validationIssues: [String]

    public init(
        discoveredCaseCount: Int,
        coverageValid: Bool,
        mappedSourceCaseCount: Int,
        declaredComparedSourceCaseCount: Int,
        declaredDivergentSourceCaseCount: Int,
        declaredNonComparableSourceCaseCount: Int,
        declaredComparedScenarioCount: Int,
        declaredDivergentScenarioCount: Int,
        declaredNonComparableScenarioCount: Int,
        discoveredCases: [String],
        pendingCases: [String],
        validationIssues: [String]
    ) {
        self.discoveredCaseCount = discoveredCaseCount
        self.coverageValid = coverageValid
        self.mappedSourceCaseCount = mappedSourceCaseCount
        self.declaredComparedSourceCaseCount = declaredComparedSourceCaseCount
        self.declaredDivergentSourceCaseCount = declaredDivergentSourceCaseCount
        self.declaredNonComparableSourceCaseCount = declaredNonComparableSourceCaseCount
        self.declaredComparedScenarioCount = declaredComparedScenarioCount
        self.declaredDivergentScenarioCount = declaredDivergentScenarioCount
        self.declaredNonComparableScenarioCount = declaredNonComparableScenarioCount
        self.discoveredCases = discoveredCases
        self.pendingCases = pendingCases
        self.validationIssues = validationIssues
    }

    public var hasCompleteCoverage: Bool {
        coverageValid && validationIssues.isEmpty && pendingCases.isEmpty
    }

    public func isConsistent(with entries: [CoverageMatrixEntry]) -> Bool {
        let discovered = Set(discoveredCases)
        let mapped = Set(entries.map(\.sourceCase))
        let pending = discovered.subtracting(mapped).sorted()
        let sourceCounts = CoverageMatrixValidator.sourceCaseCounts(in: entries)
        let outcomeCounts = CoverageMatrixValidator.outcomeCounts(in: entries)
        return discovered.count == discoveredCases.count
            && discoveredCaseCount == discoveredCases.count
            && pendingCases == pending
            && mappedSourceCaseCount == discovered.intersection(mapped).count
            && declaredComparedSourceCaseCount == sourceCounts["compared", default: 0]
            && declaredDivergentSourceCaseCount == sourceCounts["divergent", default: 0]
            && declaredNonComparableSourceCaseCount == sourceCounts["non-comparable", default: 0]
            && declaredComparedScenarioCount == outcomeCounts["compared", default: 0]
            && declaredDivergentScenarioCount == outcomeCounts["divergent", default: 0]
            && declaredNonComparableScenarioCount == outcomeCounts["non-comparable", default: 0]
    }

    public func hasValidMatrix(
        schemaVersion: Int = CoverageMatrixValidator.supportedSchemaVersion,
        entries: [CoverageMatrixEntry],
        registry: [String: ScenarioContract]
    ) -> Bool {
        guard isConsistent(with: entries) else { return false }
        let structuralIssues = CoverageMatrixValidator.validate(
            schemaVersion: schemaVersion,
            discovered: Set(entries.map(\.sourceCase)),
            entries: entries,
            registry: registry)
        return structuralIssues.isEmpty
            && coverageValid
            && validationIssues == structuralIssues
    }
}

public enum CoverageMatrixValidator {
    public static let supportedSchemaVersion = 1
    public static let permittedStatuses: Set<String> = ["compared", "divergent", "non-comparable"]
    public static let permittedReasons: Set<String> = [
        "deferred-behavior-gap", "private-api", "unsupported-platform-or-version",
        "nondeterministic-apple-behavior", "shim-only-api",
    ]

    public static func validate(
        schemaVersion: Int = supportedSchemaVersion,
        discovered: Set<String>,
        entries: [CoverageMatrixEntry],
        registry: [String: ScenarioContract]
    ) -> [String] {
        var errors: [String] = []
        guard schemaVersion == supportedSchemaVersion else {
            return ["unsupported coverage matrix schema version \(schemaVersion)"]
        }
        let grouped = Dictionary(grouping: entries, by: \.sourceCase)
        for identity in discovered.sorted() where grouped[identity]?.count != 1 {
            errors.append("\(identity): expected exactly one matrix record")
        }
        for entry in entries where !discovered.contains(entry.sourceCase) {
            errors.append("\(entry.sourceCase): matrix record is stale")
        }
        for entry in entries {
            guard !entry.sourceCase.isEmpty else {
                errors.append("matrix sourceCase must not be empty")
                continue
            }
            guard !entry.scenarioIDs.isEmpty else {
                errors.append("\(entry.sourceCase): scenarioIDs must not be empty")
                continue
            }
            guard entry.scenarioIDs.count == Set(entry.scenarioIDs).count else {
                errors.append("\(entry.sourceCase): scenarioIDs must be unique")
                continue
            }
            let malformedScenarioIDs = entry.scenarioIDs.filter { ScenarioID(description: $0) == nil }
            if !malformedScenarioIDs.isEmpty {
                errors.append("\(entry.sourceCase): contains a malformed scenario ID")
                continue
            }
            guard Set(entry.outcomes.keys) == Set(entry.scenarioIDs) else {
                errors.append("\(entry.sourceCase): outcome mappings must cover each scenario exactly once")
                continue
            }
            guard entry.scenarioIDs.allSatisfy({ permittedStatuses.contains(entry.outcomes[$0] ?? "") }) else {
                errors.append("\(entry.sourceCase): contains an invalid scenario outcome")
                continue
            }
            let comparableIDs = Set(entry.scenarioIDs.filter { entry.outcomes[$0] != "non-comparable" })
            guard comparableIDs.allSatisfy({ registry[$0] != nil }) else {
                errors.append("\(entry.sourceCase): references missing scenario registry entry")
                continue
            }
            guard Set(entry.observations.keys) == comparableIDs else {
                errors.append("\(entry.sourceCase): observation mappings must cover comparable scenarios exactly once")
                continue
            }
            let fieldsDoNotMatch = comparableIDs.contains { id in
                guard let specification = registry[id], let fields = entry.observations[id] else { return true }
                return fields.count != Set(fields).count || Set(fields) != specification.expectedObservationFields
            }
            if fieldsDoNotMatch {
                errors.append("\(entry.sourceCase): matrix observation fields do not match shared scenario contract")
            }
            if comparableIDs.isEmpty && !entry.observations.isEmpty {
                errors.append("\(entry.sourceCase): non-comparable scenarios must not declare observations")
            }
            if entry.outcomes.values.contains("non-comparable") {
                if let reason = entry.reasonCategory, permittedReasons.contains(reason),
                    let rationale = entry.rationale, !rationale.isEmpty
                {} else {
                    errors.append("\(entry.sourceCase): non-comparable outcome needs a valid reason and rationale")
                }
            }
        }
        return errors
    }

    public static func outcomeCounts(in entries: [CoverageMatrixEntry]) -> [String: Int] {
        entries.reduce(into: [String: Int]()) { counts, entry in
            for outcome in entry.outcomes.values where permittedStatuses.contains(outcome) {
                counts[outcome, default: 0] += 1
            }
        }
    }

    public static func runnerScenarioIDs(in entries: [CoverageMatrixEntry]) -> Set<String> {
        Set(entries.lazy
            .filter { $0.outcomes.values.contains { $0 != "non-comparable" } }
            .flatMap(\.scenarioIDs))
    }

    public static func sourceCaseCounts(in entries: [CoverageMatrixEntry]) -> [String: Int] {
        let groupedEntries = Dictionary(grouping: entries, by: \.sourceCase)
        return groupedEntries.reduce(into: [String: Int]()) { counts, group in
            let statuses = Set(group.value.map(\.sourceStatus))
            guard statuses.count == 1, let status = statuses.first, permittedStatuses.contains(status) else { return }
            counts[status, default: 0] += 1
        }
    }

    public static var supportedStatuses: Set<String> { permittedStatuses }
}

public extension ParityScenarioCatalog {
    static var contractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: all.map {
            ($0.id.description, ScenarioContract(id: $0.id, expectedObservationFields: Set($0.expectedObservations.keys)))
        })
    }

    static var allContractsByID: [String: ScenarioContract] {
        Dictionary(uniqueKeysWithValues: (Array(contractsByID.values)
            + Array(SchemaIntrospectionScenarioCatalog.contractsByID.values)
            + Array(SchemaModelTypesScenarioCatalog.contractsByID.values)
            + Array(StoreIdentifierScenarioCatalog.contractsByID.values)
            + Array(ModelIdentityScenarioCatalog.contractsByID.values)
            + Array(ModelConfigurationScenarioCatalog.contractsByID.values)
            + Array(ModelConfigurationContainerScenarioCatalog.contractsByID.values)
            + Array(PendingFetchScenarioCatalog.contractsByID.values)
            + Array(BatchFetchScenarioCatalog.contractsByID.values)
             + Array(BatchDeleteScenarioCatalog.contractsByID.values)
             + Array(CodableParityScenarioCatalog.contractsByID.values)
             + Array(ContextNotificationScenarioCatalog.contractsByID.values)
             + Array(RollbackParityScenarioCatalog.contractsByID.values)
             + Array(ModelContextParityScenarioCatalog.contractsByID.values)
             + Array(HistoryParityScenarioCatalog.contractsByID.values)
             + Array(UniqueConstraintScenarioCatalog.contractsByID.values))
            .map { ($0.id.description, $0) })
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
    case countNamesMatchingNonEmptyNames(observationField: String)
    case fetchNameSetMatchingNameCharacterCount(observationField: String, count: Int)
    case fetchNameSetMatchingOptionalNickCount(observationField: String, minimumCount: Int, defaultValue: Bool)
    case fetchNamesMatchingNameIsEmpty(observationField: String, negated: Bool, includePendingChanges: Bool)
    case fetchNamesMatchingNameCharacterCount(observationField: String, count: Int, usesGreaterThan: Bool)
    case fetchNamesMatchingOptionalNickIsEmpty(observationField: String, defaultValue: Bool)
    case fetchNamesMatchingOptionalNickCount(observationField: String, minimumCount: Int, defaultValue: Bool)
    case fetchNamesMatchingOptionalNickIsEmptyDirectly(observationField: String)
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

    public static let stringIsEmptyPending = PredicateMembershipSpecification(
        id: ScenarioID(suite: "StringPredicateParityTests", test: "string isEmpty/pending"),
        rows: [
            .init(name: "Alpha", age: 1, nick: "al"),
            .init(name: "beta", age: 2),
            .init(name: "Gamma", age: 3, nick: "GA"),
            .init(name: "délta", age: 4, nick: ""),
            .init(name: "Épsilon", age: 5),
        ],
        capturedNames: [],
        sortField: .name,
        expectedObservations: [
            "empty.names": .array([]),
            "nonempty.count": .integer(5),
        ],
        operations: [
            .insertRows,
            .fetchNamesMatchingNameIsEmpty(observationField: "empty.names", negated: false, includePendingChanges: true),
            .countNamesMatchingNonEmptyNames(observationField: "nonempty.count"),
        ])

    public static let stringIsEmptySaved = PredicateMembershipSpecification(
        id: ScenarioID(suite: "StringPredicateParityTests", test: "string isEmpty/saved"),
        rows: stringIsEmptyPending.rows,
        capturedNames: [],
        sortField: .name,
        expectedObservations: [
            "empty.names": .array([]),
            "nonempty.count": .integer(5),
        ],
        operations: [
            .insertRows,
            .save,
            .fetchNamesMatchingNameIsEmpty(observationField: "empty.names", negated: false, includePendingChanges: true),
            .countNamesMatchingNonEmptyNames(observationField: "nonempty.count"),
        ])

    public static let stringCountPending = PredicateMembershipSpecification(
        id: ScenarioID(suite: "StringPredicateParityTests", test: "string count counts characters/pending"),
        rows: stringIsEmptyPending.rows,
        capturedNames: [],
        sortField: .name,
        expectedObservations: [
            "length.4": .array([.string("beta")]),
            "length.5": .stringSet(["Alpha", "Gamma", "délta"]),
            "length.gt5": .array([.string("Épsilon")]),
        ],
        operations: [
            .insertRows,
            .fetchNamesMatchingNameCharacterCount(observationField: "length.4", count: 4, usesGreaterThan: false),
            .fetchNameSetMatchingNameCharacterCount(observationField: "length.5", count: 5),
            .fetchNamesMatchingNameCharacterCount(observationField: "length.gt5", count: 5, usesGreaterThan: true),
        ])

    public static let stringCountSaved = PredicateMembershipSpecification(
        id: ScenarioID(suite: "StringPredicateParityTests", test: "string count counts characters/saved"),
        rows: stringIsEmptyPending.rows,
        capturedNames: [],
        sortField: .name,
        expectedObservations: stringCountPending.expectedObservations,
        operations: [
            .insertRows,
            .save,
            .fetchNamesMatchingNameCharacterCount(observationField: "length.4", count: 4, usesGreaterThan: false),
            .fetchNameSetMatchingNameCharacterCount(observationField: "length.5", count: 5),
            .fetchNamesMatchingNameCharacterCount(observationField: "length.gt5", count: 5, usesGreaterThan: true),
        ])

    public static let optionalFlatMapPending = PredicateMembershipSpecification(
        id: ScenarioID(suite: "StringPredicateParityTests", test: "optional flatMap over a string/pending"),
        rows: stringIsEmptyPending.rows,
        capturedNames: [],
        sortField: .name,
        expectedObservations: optionalFlatMapExpected,
        operations: optionalFlatMapOperations)

    public static let optionalFlatMapSaved = PredicateMembershipSpecification(
        id: ScenarioID(suite: "StringPredicateParityTests", test: "optional flatMap over a string/saved"),
        rows: stringIsEmptyPending.rows,
        capturedNames: [],
        sortField: .name,
        expectedObservations: optionalFlatMapExpected,
        operations: [.insertRows, .save] + optionalFlatMapOperations.dropFirst())

    private static let optionalFlatMapExpected: [String: ObservedValue] = [
        "nick.empty.false": .array([.string("délta")]),
        "nick.count.gt1.false": .array([.string("Alpha"), .string("Gamma")]),
        "nick.count.gt1.true": .stringSet(["Alpha", "Gamma", "beta", "Épsilon"]),
        "nick.isEmpty.direct": .array([.string("délta")]),
    ]

    private static let optionalFlatMapOperations: [ScenarioOperation] = [
        .insertRows,
        .fetchNamesMatchingOptionalNickIsEmpty(observationField: "nick.empty.false", defaultValue: false),
        .fetchNamesMatchingOptionalNickCount(observationField: "nick.count.gt1.false", minimumCount: 1, defaultValue: false),
        .fetchNameSetMatchingOptionalNickCount(observationField: "nick.count.gt1.true", minimumCount: 1, defaultValue: true),
        .fetchNamesMatchingOptionalNickIsEmptyDirectly(observationField: "nick.isEmpty.direct"),
    ]

    public static let all: [PredicateMembershipSpecification] = [
        predicateMembership,
        predicateArrayLiteralMembership,
        emptyArrayMembership,
        negatedIntegerAndCombinedMembership,
        stringIsEmptyPending,
        stringIsEmptySaved,
        stringCountPending,
        stringCountSaved,
        optionalFlatMapPending,
        optionalFlatMapSaved,
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
