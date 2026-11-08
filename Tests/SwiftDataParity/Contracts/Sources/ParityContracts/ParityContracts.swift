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

public struct ScenarioResult: Codable, Equatable, Sendable {
    public let id: ScenarioID
    public let observations: [ParityObservation]

    public init(id: ScenarioID, observations: [ParityObservation]) {
        self.id = id
        self.observations = observations
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

public enum CoverageMatrixValidator {
    public static let supportedSchemaVersion = 1
    public static let permittedStatuses: Set<String> = ["compared", "divergent", "non-comparable"]
    private static let permittedReasons: Set<String> = [
        "private-api", "unsupported-platform-or-version", "nondeterministic-apple-behavior", "shim-only-api",
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
            + Array(ModelIdentityScenarioCatalog.contractsByID.values))
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
