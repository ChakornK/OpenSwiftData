import Foundation
import OSDCore

/// Stores model snapshots without requiring a SQL backend.
public protocol DataStore: Sendable {
    /// A stable identifier for this store instance.
    var identifier: String { get }
    /// Whether fetch requests can return every requested hierarchy entity using its concrete entity name.
    var supportsInheritance: Bool { get }
    /// Fetches snapshots matching the request's entity subtree, predicate, ordering, offset, and limit.
    /// When `propertiesToFetch` is non-nil, snapshots may omit unrequested scalar values; relationship identifiers
    /// remain complete. The context faults omitted scalar properties on demand through `snapshot(for:)`.
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
    func makeStore(schema: SchemaDescriptor) throws -> any DataStore
}

/// A value snapshot of one model row.
public struct DataStoreSnapshot: Sendable, Equatable {
    /// The model row identifier.
    public let persistentIdentifier: PersistentIdentifier
    /// The stable schema entity name.
    public let entityName: String
    /// Encoded scalar properties keyed by schema property name, or component column name when flattened.
    /// Partial fetches may omit unrequested values; flattened properties are atomic and include all components.
    public let values: [String: StoredValue]
    /// Related model identifiers keyed by relationship property name.
    public let relationships: [String: [PersistentIdentifier]]

    /// Creates a snapshot with scalar values and related persistent identifiers.
    /// ModelContext resolves related snapshots recursively during fetch and faults omitted partial-fetch values on demand.
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
    public let entity: SchemaDescriptor.Entity
    /// The concrete entity names included by the requested entity's inheritance subtree.
    public let includedEntityNames: Set<String>

    /// Creates a fetch request. Omitting `includedEntityNames` requests only `entity.name`.
    public init(
        descriptor: FetchDescriptor<Model>, entity: SchemaDescriptor.Entity,
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
    public func makeStore(schema: SchemaDescriptor) throws -> any DataStore {
        _ = schema
        return store
    }
}

/// A custom store configuration aligned with Apple's associated-store configuration shape.
///
/// This prefixed API uses OpenSwiftData's current `SchemaDescriptor` type and remains separate from `DataStoreConfiguration`.
public protocol AppleDataStoreConfiguration: Sendable {
    /// The custom store type created from this configuration.
    associatedtype Store: AppleDataStore
    /// The configuration's stable name.
    var name: String { get }
    /// The schema assigned by the model container, when available.
    var schema: SchemaDescriptor? { get set }
    /// Creates the configured store with the resolved schema and migration plan.
    func makeStore(schema: SchemaDescriptor, migrationPlan: (any SchemaMigrationPlan.Type)?) throws -> any AppleDataStore
    /// Validates configuration values before opening the store.
    func validate() throws
}

public extension AppleDataStoreConfiguration {
    func validate() throws {}
}

/// A snapshot exchanged between a model context and an Apple-shaped custom store.
public protocol AppleDataStoreSnapshot: Codable, Sendable {
    /// The snapshot's persistent identity.
    var persistentIdentifier: PersistentIdentifier { get }
    /// Creates a snapshot from model backing data and collects directly related backing data.
    init(
        from backingData: any BackingData,
        relatedBackingDatas: inout [PersistentIdentifier: any BackingData]
    )
    /// Returns a snapshot with remapped identifiers.
    func copy(
        persistentIdentifier: PersistentIdentifier,
        remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]?
    ) -> Self
}

/// A value-oriented snapshot whose model values and relationships are supplied explicitly.
public struct AppleDefaultSnapshot: AppleDataStoreSnapshot, Equatable {
    public let persistentIdentifier: PersistentIdentifier
    public let entityName: String
    public let values: [String: StoredValue]
    public let relationships: [String: [PersistentIdentifier]]

    /// Creates a snapshot with explicitly supplied identity, values, and relationships.
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

    /// Creates an identity-only snapshot because backing data does not expose model values.
    @available(*, deprecated, message: "Captures identity only; provide values explicitly until Schema API parity is implemented.")
    public init(
        from backingData: any BackingData,
        relatedBackingDatas: inout [PersistentIdentifier: any BackingData]
    ) {
        _ = (backingData, relatedBackingDatas)
        let identifier = backingData.persistentModelID
        persistentIdentifier = identifier
        entityName = identifier.entityName
        values = [:]
        relationships = [:]
    }

    public func copy(
        persistentIdentifier: PersistentIdentifier,
        remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]? = nil
    ) -> Self {
        Self(
            persistentIdentifier: remappedIdentifiers?[self.persistentIdentifier] ?? persistentIdentifier,
            entityName: entityName,
            values: values,
            relationships: relationships.mapValues { $0.map { remappedIdentifiers?[$0] ?? $0 } })
    }

}

extension AppleDefaultSnapshot {
    /// Converts this snapshot to the current OpenSwiftData context representation.
    /// Converts this snapshot to the context's stored representation after validating its entity.
    public func makeBackendSnapshot(in schema: SchemaDescriptor) throws -> DataStoreSnapshot {
        guard schema.entity(forName: entityName) != nil else {
            throw SwiftDataError.unsupportedStore("Snapshot entity '\(entityName)' is not in the schema.")
        }
        return DataStoreSnapshot(
            persistentIdentifier: persistentIdentifier, entityName: entityName,
            values: values, relationships: relationships)
    }

    /// Creates a snapshot from an OpenSwiftData context snapshot.
    /// Recreates a snapshot after validating its entity against the schema.
    public static func makeAppleSnapshot(from snapshot: DataStoreSnapshot, in schema: SchemaDescriptor) throws -> Self {
        guard schema.entity(forName: snapshot.entityName) != nil else {
            throw SwiftDataError.unsupportedStore("Snapshot entity '\(snapshot.entityName)' is not in the schema.")
        }
        return Self(
            persistentIdentifier: snapshot.persistentIdentifier, entityName: snapshot.entityName,
            values: snapshot.values, relationships: snapshot.relationships)
    }
}

/// A typed fetch request passed to an Apple-shaped custom store.
public struct AppleDataStoreFetchRequest<Model: PersistentModel> {
    /// The fetch descriptor supplied by the caller.
    public let descriptor: FetchDescriptor<Model>

    public init(descriptor: FetchDescriptor<Model>) {
        self.descriptor = descriptor
    }
}

/// The snapshots returned by an Apple-shaped custom store fetch.
public struct AppleDataStoreFetchResult<Model: PersistentModel, Snapshot: AppleDataStoreSnapshot> {
    /// The descriptor associated with the fetched snapshots.
    public let descriptor: FetchDescriptor<Model>
    /// The snapshots matching the descriptor.
    public let fetchedSnapshots: [Snapshot]
    /// Related snapshots keyed by persistent identifier.
    public let relatedSnapshots: [PersistentIdentifier: Snapshot]

    public init(
        descriptor: FetchDescriptor<Model>,
        fetchedSnapshots: [Snapshot],
        relatedSnapshots: [PersistentIdentifier: Snapshot] = [:]
    ) {
        self.descriptor = descriptor
        self.fetchedSnapshots = fetchedSnapshots
        self.relatedSnapshots = relatedSnapshots
    }
}

/// A batch of model changes passed to an Apple-shaped custom store.
public struct AppleDataStoreSaveChangesRequest<Snapshot: AppleDataStoreSnapshot> {
    public let inserted: [Snapshot]
    public let updated: [Snapshot]
    public let deleted: [Snapshot]

    public init(inserted: [Snapshot], updated: [Snapshot], deleted: [Snapshot]) {
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
    }
}

/// A batch of changes passed to an Apple-shaped custom store.
public struct AppleDataStoreBatchRequest<Snapshot: AppleDataStoreSnapshot> {
    public let saves: [AppleDataStoreSaveChangesRequest<Snapshot>]

    public init(saves: [AppleDataStoreSaveChangesRequest<Snapshot>]) {
        self.saves = saves
    }
}

/// The result of committing changes to an Apple-shaped custom store.
public struct AppleDataStoreSaveChangesResult: Sendable {
    /// The identifier of the store that committed the changes.
    public let storeIdentifier: String
    /// Temporary-to-permanent identifier mappings for inserted snapshots.
    public let remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]
    /// Snapshots that the context should register after the save.
    public let snapshotsToReregister: [PersistentIdentifier: PersistentIdentifier]

    public init(
        for storeIdentifier: String,
        remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier] = [:],
        snapshotsToReregister: [PersistentIdentifier: PersistentIdentifier] = [:]
    ) {
        self.storeIdentifier = storeIdentifier
        self.remappedIdentifiers = remappedIdentifiers
        self.snapshotsToReregister = snapshotsToReregister
    }
}

/// A store that can provide its own adapter for the current OpenSwiftData context engine.
public protocol AppleDataStoreBackendProviding: AppleDataStore {
    func makeBackend(schema: SchemaDescriptor, migrationPlan: (any SchemaMigrationPlan.Type)?) throws -> any DataStore
}

/// A custom store using the Apple-shaped API under nonconflicting prefixed names.
public protocol AppleDataStore: AnyObject, Sendable {
    associatedtype Configuration: AppleDataStoreConfiguration where Configuration.Store == Self
    associatedtype Snapshot: AppleDataStoreSnapshot

    init(_ configuration: Configuration, migrationPlan: (any SchemaMigrationPlan.Type)?) throws
    var configuration: Configuration { get }
    var identifier: String { get }
    var schema: SchemaDescriptor { get }
    var supportsInheritance: Bool { get }

    func fetch<Model: PersistentModel>(
        _ request: AppleDataStoreFetchRequest<Model>
    ) throws -> AppleDataStoreFetchResult<Model, Snapshot>
    func save(_ request: AppleDataStoreSaveChangesRequest<Snapshot>) throws -> AppleDataStoreSaveChangesResult
}

public extension AppleDataStore {
    var supportsInheritance: Bool { false }

}

/// An optional custom-store capability for batching model fetches and saves.
public protocol AppleDataStoreBatching: AppleDataStore {
    func fetch<Model: PersistentModel>(
        _ requests: [AppleDataStoreFetchRequest<Model>]
    ) throws -> [AppleDataStoreFetchResult<Model, Snapshot>]
    func save(_ request: AppleDataStoreBatchRequest<Snapshot>) throws -> [AppleDataStoreSaveChangesResult]
}
