import Foundation
import OSDCore

/// A GRDB-free persistence store used by a model container.
public protocol RuntimeStore: Sendable {
    /// Executes a read operation against the configured store.
    func read<T>(_ body: (RuntimeConnection) throws -> T) throws -> T
    /// Executes an atomic write operation against the configured store.
    func write<T>(_ body: (RuntimeConnection) throws -> T) throws -> T
    /// Closes the underlying store.
    func close() throws
    /// Returns a backend change token when external-commit monitoring is supported.
    func dataVersion() throws -> Int64?
    /// Encodes Data during one atomic store write.
    func writeWithExternalData<T>(
        _ body: (RuntimeConnection, ExternalDataWriteSession) throws -> T
    ) throws -> T
    /// A stable identifier for the store's contents, used as the persistent identifiers' store identifier.
    ///
    /// Return `nil` to use the configuration name instead.
    var persistentStoreIdentifier: String? { get }
}

package protocol RuntimeSchemaProvidingStore: RuntimeStore {
    var runtimeSchema: Schema { get }
}

public extension RuntimeStore {
    var persistentStoreIdentifier: String? { nil }
    func dataVersion() throws -> Int64? { nil }
    func writeWithExternalData<T>(
        _ body: (RuntimeConnection, ExternalDataWriteSession) throws -> T
    ) throws -> T {
        try write { connection in
            try body(connection, ExternalDataWriteSession(externalize: { .blob($0) }))
        }
    }
}

/// A backend that can compile a reflected model predicate into a SQL fragment.
public protocol RuntimePredicateCompiler: Sendable {
    /// Compiles a query tree and returns SQL with bound positional values.
    func compile(_ request: RuntimePredicateRequest) throws -> RuntimeCompiledPredicate
}

/// A model-property reference that does not carry a Swift key path across the runtime boundary.
public struct RuntimePropertyReference: Sendable, Equatable {
    /// The schema property name.
    public let name: String

    /// Creates a reference to a schema property.
    public init(name: String) {
        self.name = name
    }
}

/// A backend-neutral predicate node tree.
public indirect enum RuntimePredicateNode: Sendable, Equatable {
    case expression(name: String, children: [(String, RuntimePredicateNode)])
    case property(RuntimePropertyReference)
    case capture(typeName: String, description: String)

    /// Compares expression trees by ordered child labels and recursively equal nodes.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.expression(lhsName, lhsChildren), .expression(rhsName, rhsChildren)):
            lhsName == rhsName && lhsChildren.elementsEqual(rhsChildren, by: ==)
        case let (.property(lhsProperty), .property(rhsProperty)):
            lhsProperty == rhsProperty
        case let (.capture(lhsType, lhsDescription), .capture(rhsType, rhsDescription)):
            lhsType == rhsType && lhsDescription == rhsDescription
        default:
            false
        }
    }

}

/// An opaque path to one reflected predicate value node.
public struct RuntimePredicatePath: Sendable, Hashable {
    /// The ordered Mirror child labels from the predicate root to the value node.
    public let labels: [String]

    /// Creates a path from reflected child labels.
    public init(labels: [String]) {
        self.labels = labels
    }
}

/// Identifies the encoding used for predicate captures in a compilation request.
public struct RuntimePredicateCaptureEncoding: Sendable, Hashable, Codable {
    /// The encoding version.
    public let rawValue: Int

    /// Creates an encoding version.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Captures use the legacy reflected type name and description representation.
    public static let legacyDescription = Self(rawValue: 0)
    /// Captures use the typed path-keyed scalar representation.
    public static let typed = Self(rawValue: 1)
}

/// A predicate compilation request resolved against one model schema.
public struct RuntimePredicateRequest: Sendable {
    /// The target entity name.
    public let entityName: String
    /// The predicate tree with typed model key paths resolved to schema names.
    public let root: RuntimePredicateNode
    /// The ordering columns included in the structural query plan.
    public let ordering: [String]
    /// Typed scalar captures keyed by their reflected value-node paths.
    public let typedCaptures: [RuntimePredicatePath: StoredValue]
    /// Persistent identifier captures keyed by their reflected value-node paths.
    public let identifierCaptures: [RuntimePredicatePath: PersistentIdentifier]
    /// The capture encoding used by this request.
    public let captureEncoding: RuntimePredicateCaptureEncoding
    /// Persisted attribute names accepted as direct property references.
    public let attributeNames: Set<String>
    /// Swift type names for persisted attributes, used to validate typed predicate nodes.
    public let attributeTypes: [String: String]
    /// Optional persisted attribute paths, used to preserve optional comparison semantics.
    public let optionalAttributeNames: Set<String>
    /// The identifier of the store that owns this query context.
    public let storeIdentifier: String?
    /// Resolved to-one and direct to-many relationships referenced by predicate expressions.
    public let relationships: [RuntimePredicateRelationship]

    /// Creates a query request for a backend compiler.
    public init(
        entityName: String,
        root: RuntimePredicateNode,
        ordering: [String],
        typedCaptures: [RuntimePredicatePath: StoredValue] = [:],
        captureEncoding: RuntimePredicateCaptureEncoding = .legacyDescription,
        attributeNames: Set<String> = [],
        attributeTypes: [String: String] = [:],
        optionalAttributeNames: Set<String> = [],
        identifierCaptures: [RuntimePredicatePath: PersistentIdentifier] = [:],
        storeIdentifier: String? = nil,
        relationships: [RuntimePredicateRelationship] = []
    ) {
        self.entityName = entityName
        self.root = root
        self.ordering = ordering
        self.typedCaptures = typedCaptures
        self.identifierCaptures = identifierCaptures
        self.captureEncoding = captureEncoding
        self.attributeNames = attributeNames
        self.attributeTypes = attributeTypes
        self.optionalAttributeNames = optionalAttributeNames
        self.storeIdentifier = storeIdentifier
        self.relationships = relationships
    }
}

/// A compiled SQL predicate and its ordered positional arguments.
public struct RuntimeCompiledPredicate: Sendable, Equatable {
    /// The SQL expression used after `WHERE`.
    public let sql: String
    /// Bound values in SQL placeholder order.
    public let arguments: [RuntimeValue]
    /// A runtime-neutral plan for evaluating pending model values.
    public let evaluatorPlan: PredicatePlan?

    /// Creates a compiled SQL predicate.
    public init(sql: String, arguments: [RuntimeValue], evaluatorPlan: PredicatePlan? = nil) {
        self.sql = sql
        self.arguments = arguments
        self.evaluatorPlan = evaluatorPlan
    }
}

/// A typed predicate representation shared by SQL and pending-model evaluation.
/// Provides a typed model query compiler to the runtime without exposing storage implementation modules.
public protocol RuntimeQueryStore: RuntimeStore, RuntimePredicateCompiler {}

/// A GRDB-free SQL connection exposed to runtime persistence operations.
public protocol RuntimeConnection {
    /// Executes SQL with positional values.
    func execute(_ sql: String, arguments: [RuntimeValue]) throws
    /// Returns rows of positional values.
    func rows(_ sql: String, arguments: [RuntimeValue]) throws -> [[RuntimeValue]]
    /// The most recently inserted row identifier.
    func lastInsertRowID() -> Int64
    /// The number of rows affected by the last statement.
    func changesCount() -> Int
    /// Records model changes inside the current atomic write, when history is supported.
    func recordHistory(_ changes: [RuntimeHistoryChange], timestamp: Date, author: String?) throws
}

public extension RuntimeConnection {
    func recordHistory(_ changes: [RuntimeHistoryChange], timestamp: Date, author: String?) throws {}
}

/// A store-neutral model row change written with its transaction.
public struct RuntimeHistoryChange: Sendable, Hashable {
    /// The history change kind.
    public let type: HistoryChangeType
    /// The stable schema entity name.
    public let entityName: String
    /// The changed row's primary key.
    public let primaryKey: Int64
    /// For updates, the names of the properties whose values changed.
    public let updatedAttributes: [String]
    /// For deletions, the stored values of properties marked `.preserveValueOnDeletion`, keyed by name.
    public let tombstone: [String: StoredValue]

    /// Creates a store-neutral row change.
    public init(
        type: HistoryChangeType, entityName: String, primaryKey: Int64, updatedAttributes: [String] = [],
        tombstone: [String: StoredValue] = [:]
    ) {
        self.type = type
        self.entityName = entityName
        self.primaryKey = primaryKey
        self.updatedAttributes = updatedAttributes
        self.tombstone = tombstone
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.type == rhs.type && lhs.entityName == rhs.entityName && lhs.primaryKey == rhs.primaryKey
            && lhs.updatedAttributes == rhs.updatedAttributes && lhs.tombstone == rhs.tombstone
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(entityName)
        hasher.combine(primaryKey)
        hasher.combine(updatedAttributes)
    }
}

/// A runtime store that supports durable history queries and pruning.
package protocol RuntimeHistoryStore: RuntimeStore {
    /// Fetches every stored history transaction in commit order.
    func fetchHistory() throws -> [StoredHistoryTransaction]
    /// Deletes the history transactions with the given identifiers.
    func deleteHistory(transactionIDs: [Int64]) throws
    /// The largest transaction identifier the store has ever issued, or zero when none.
    func latestIssuedHistoryTransactionID() throws -> Int64
}

/// SQL values exchanged across the runtime-store boundary.
public enum RuntimeValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob([UInt8])
}

extension RuntimeValue {
    package init(storedValue: StoredValue) {
        switch storedValue {
        case .null: self = .null
        case let .int(value): self = .int(value)
        case let .double(value): self = .double(value)
        case let .text(value): self = .text(value)
        case let .blob(value): self = .blob(value)
        }
    }

    package var storedValue: StoredValue {
        switch self {
        case .null: .null
        case let .int(value): .int(value)
        case let .double(value): .double(value)
        case let .text(value): .text(value)
        case let .blob(value): .blob(value)
        }
    }
}

/// The non-SQLite store location selected by a model configuration.
public enum RuntimeStoreLocation: Sendable {
    case file(URL)
    case memory(name: String)
}

/// Creates a runtime store for a location.
public typealias RuntimeStoreFactory = @Sendable (RuntimeStoreLocation, Schema) throws -> any RuntimeStore

/// Reads schema version metadata at a runtime store location without migrating it.
public typealias RuntimeSchemaVersionReader = @Sendable (RuntimeStoreLocation) throws -> RuntimeSchemaVersionState

package typealias RuntimeSchemaCompatibilityReader = @Sendable (RuntimeStoreLocation, Schema) throws -> Bool
