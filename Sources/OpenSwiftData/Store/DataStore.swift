import Foundation
import OSDCore

/// Stores model snapshots without requiring a SQL backend.
public protocol DataStore: Sendable {
    /// A stable identifier for this store instance.
    var identifier: String { get }
    /// Whether fetch requests can return every requested hierarchy entity using its concrete entity name.
    var supportsInheritance: Bool { get }
    /// Fetches snapshots matching the request's entity subtree, predicate, ordering, offset, and limit.
    /// The store applies the predicate and ordering before offset and limit. When `includePendingChanges` is true,
    /// ModelContext requests all matching stored snapshots and applies pagination after merging pending models.
    /// Hierarchy-capable stores include every matching `includedEntityNames` entry and return each snapshot with its
    /// concrete entity name in both `entityName` and `persistentIdentifier.entityName`.
    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult
    /// Reserves permanent identifiers for a batch before its atomic save. Reservations must be reusable if the
    /// subsequent `save` throws. Reserved identifiers are placed directly in inserted snapshots and may be used by
    /// relationship snapshots in the same request.
    func reserveIdentifiers(for snapshots: [DataStoreSnapshot]) throws -> [PersistentIdentifier: PersistentIdentifier]
    /// Applies the request atomically. A thrown error must leave the store unchanged; a returned result must
    /// acknowledge every requested update and deletion. Inserted snapshots already carrying reserved identifiers
    /// need no result mapping; unreserved temporary identifiers must be mapped to permanent identifiers.
    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult
    /// Returns one snapshot by its persistent identifier.
    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot?
}

public extension DataStore {
    var supportsInheritance: Bool { false }

    func reserveIdentifiers(for snapshots: [DataStoreSnapshot]) throws -> [PersistentIdentifier: PersistentIdentifier] {
        [:]
    }
}

/// Creates a configured custom data store for a schema.
public protocol DataStoreConfiguration: Sendable {
    /// Creates the store that will back a model container.
    func makeStore(schema: Schema) throws -> any DataStore
}

/// A value snapshot of one model row.
public struct DataStoreSnapshot: Sendable, Equatable {
    /// The model row identifier.
    public let persistentIdentifier: PersistentIdentifier
    /// The stable schema entity name.
    public let entityName: String
    /// Encoded scalar properties keyed by schema property name, or component column name when flattened.
    public let values: [String: StoredValue]
    /// Related model identifiers keyed by relationship property name.
    public let relationships: [String: [PersistentIdentifier]]

    /// Creates a snapshot. The current ModelContext fetch adapter supports scalar attributes and flattened values;
    /// relationship snapshots are encoded and saved, but fetching relationship-bearing entities is not yet supported.
    public init(
        persistentIdentifier: PersistentIdentifier,
        entityName: String,
        values: [String: StoredValue] = [:],
        relationships: [String: [PersistentIdentifier]] = [:]
    ) {
        self.persistentIdentifier = persistentIdentifier
        self.entityName = entityName
        self.values = values
        self.relationships = relationships
    }
}

/// A typed fetch request passed to a custom data store.
public struct DataStoreFetchRequest<Model: PersistentModel> {
    /// The typed fetch descriptor, including predicate, ordering, and bounds.
    public let descriptor: FetchDescriptor<Model>
    /// The schema entity selected by the model container.
    public let entity: Schema.Entity
    /// The concrete entity names included by the requested entity's inheritance subtree.
    public let includedEntityNames: Set<String>

    /// Creates a fetch request. Omitting `includedEntityNames` requests only `entity.name`.
    public init(
        descriptor: FetchDescriptor<Model>, entity: Schema.Entity,
        includedEntityNames: Set<String>? = nil
    ) {
        self.descriptor = descriptor
        self.entity = entity
        self.includedEntityNames = includedEntityNames ?? [entity.name]
    }
}

/// The snapshots returned by a custom data store fetch.
public struct DataStoreFetchResult: Sendable, Equatable {
    /// The snapshots matching the request, in requested sort order.
    public let snapshots: [DataStoreSnapshot]

    /// Creates a fetch result from ordered snapshots.
    public init(snapshots: [DataStoreSnapshot]) {
        self.snapshots = snapshots
    }
}

/// A batch of model snapshots to persist atomically.
public struct DataStoreSaveRequest: Sendable, Equatable {
    /// Newly inserted model snapshots.
    public let inserted: [DataStoreSnapshot]
    /// Existing model snapshots whose values changed.
    public let updated: [DataStoreSnapshot]
    /// Persistent identifiers to delete.
    public let deleted: [PersistentIdentifier]

    /// Creates a batch save request.
    public init(inserted: [DataStoreSnapshot], updated: [DataStoreSnapshot], deleted: [PersistentIdentifier]) {
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
    }
}

/// The permanent identifiers assigned to newly inserted snapshots.
public struct DataStoreSaveResult: Sendable, Equatable {
    /// Maps only unreserved inserted temporary identifiers to their permanent store identifiers.
    public let identifierRemappings: [PersistentIdentifier: PersistentIdentifier]
    /// The existing identifiers whose updates were committed.
    public let updatedIdentifiers: Set<PersistentIdentifier>
    /// The identifiers whose deletions were committed.
    public let deletedIdentifiers: Set<PersistentIdentifier>

    /// Creates a result acknowledging the committed save operations.
    public init(
        identifierRemappings: [PersistentIdentifier: PersistentIdentifier] = [:],
        updatedIdentifiers: Set<PersistentIdentifier> = [],
        deletedIdentifiers: Set<PersistentIdentifier> = []
    ) {
        self.identifierRemappings = identifierRemappings
        self.updatedIdentifiers = updatedIdentifiers
        self.deletedIdentifiers = deletedIdentifiers
    }
}

/// A type-erased configuration for an already-created custom store.
public struct ExistingDataStoreConfiguration: DataStoreConfiguration {
    private let store: any DataStore

    /// Creates a configuration that returns an existing store instance.
    public init(store: any DataStore) {
        self.store = store
    }

    /// Returns the configured store; the store is responsible for validating the supplied schema.
    public func makeStore(schema: Schema) throws -> any DataStore {
        _ = schema
        return store
    }
}
