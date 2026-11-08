import Foundation
import OSDCore

/// Stores model snapshots without requiring a SQL backend.
public protocol OpenSwiftDataDataStore: Sendable {
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
    func fetch<Model: PersistentModel>(_ request: OpenSwiftDataDataStoreFetchRequest<Model>) throws -> OpenSwiftDataDataStoreFetchResult
    /// Reserves permanent identifiers for a batch before its atomic save. Reservations must be reusable if the
    /// subsequent `save` throws. Reserved identifiers are placed directly in inserted snapshots and may be used by
    /// relationship snapshots in the same request.
    func reserveIdentifiers(for snapshots: [OpenSwiftDataDataStoreSnapshot]) throws -> [PersistentIdentifier: PersistentIdentifier]
    /// Applies the request atomically. A thrown error must leave the store unchanged; a returned result must
    /// acknowledge every requested update and deletion. Inserted snapshots already carrying reserved identifiers
    /// need no result mapping; unreserved temporary identifiers must be mapped to permanent identifiers.
    func save(_ request: OpenSwiftDataDataStoreSaveRequest) throws -> OpenSwiftDataDataStoreSaveResult
    /// Returns one snapshot by its persistent identifier.
    func snapshot(for identifier: PersistentIdentifier) throws -> OpenSwiftDataDataStoreSnapshot?
}

public extension OpenSwiftDataDataStore {
    var supportsInheritance: Bool { false }

    func reserveIdentifiers(for snapshots: [OpenSwiftDataDataStoreSnapshot]) throws -> [PersistentIdentifier: PersistentIdentifier] {
        [:]
    }
}

@available(*, deprecated, renamed: "OpenSwiftDataDataStore")
public typealias LegacyDataStore = OpenSwiftDataDataStore

@available(*, deprecated, renamed: "OpenSwiftDataDataStoreConfiguration")
public typealias LegacyDataStoreConfiguration = OpenSwiftDataDataStoreConfiguration

@available(*, deprecated, renamed: "OpenSwiftDataDataStoreSnapshot")
public typealias LegacyDataStoreSnapshot = OpenSwiftDataDataStoreSnapshot

@available(*, deprecated, renamed: "OpenSwiftDataDataStoreFetchRequest")
public typealias LegacyDataStoreFetchRequest<Model: PersistentModel> = OpenSwiftDataDataStoreFetchRequest<Model>

@available(*, deprecated, renamed: "OpenSwiftDataDataStoreFetchResult")
public typealias LegacyDataStoreFetchResult = OpenSwiftDataDataStoreFetchResult

@available(*, deprecated, renamed: "OpenSwiftDataDataStoreSaveRequest")
public typealias LegacyDataStoreSaveRequest = OpenSwiftDataDataStoreSaveRequest

@available(*, deprecated, renamed: "OpenSwiftDataDataStoreSaveResult")
public typealias LegacyDataStoreSaveResult = OpenSwiftDataDataStoreSaveResult

/// Creates a configured custom data store for a schema.
public protocol OpenSwiftDataDataStoreConfiguration: Sendable {
    /// Creates the store that will back a model container.
    func makeStore(schema: SchemaDescriptor) throws -> any OpenSwiftDataDataStore
}

/// A value snapshot of one model row.
public struct OpenSwiftDataDataStoreSnapshot: Sendable, Equatable {
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
public struct OpenSwiftDataDataStoreFetchRequest<Model: PersistentModel> {
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
public struct OpenSwiftDataDataStoreFetchResult: Sendable, Equatable {
    /// The snapshots matching the request, in requested sort order.
    public let snapshots: [OpenSwiftDataDataStoreSnapshot]
    public let relatedSnapshots: [PersistentIdentifier: OpenSwiftDataDataStoreSnapshot]

    /// Creates a fetch result from ordered snapshots.
    public init(
        snapshots: [OpenSwiftDataDataStoreSnapshot],
        relatedSnapshots: [PersistentIdentifier: OpenSwiftDataDataStoreSnapshot] = [:]
    ) {
        self.snapshots = snapshots
        self.relatedSnapshots = relatedSnapshots
    }
}

/// A batch of model snapshots to persist atomically.
public struct OpenSwiftDataDataStoreSaveRequest: Sendable, Equatable {
    /// Newly inserted model snapshots.
    public let inserted: [OpenSwiftDataDataStoreSnapshot]
    /// Existing model snapshots whose values changed.
    public let updated: [OpenSwiftDataDataStoreSnapshot]
    /// Persistent identifiers to delete.
    public let deleted: [PersistentIdentifier]

    /// Creates a batch save request.
    public init(inserted: [OpenSwiftDataDataStoreSnapshot], updated: [OpenSwiftDataDataStoreSnapshot], deleted: [PersistentIdentifier]) {
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
    }
}

/// The permanent identifiers assigned to newly inserted snapshots.
public struct OpenSwiftDataDataStoreSaveResult: Sendable, Equatable {
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

/// A snapshot exchanged with a custom data store.
public protocol DataStoreSnapshot: Codable, Sendable {
    var persistentIdentifier: PersistentIdentifier { get }
    var entityName: String { get }
    var relationships: [String: [PersistentIdentifier]] { get }
    init(from backingData: any BackingData, relatedBackingDatas: inout [PersistentIdentifier: any BackingData])
    func copy(
        persistentIdentifier: PersistentIdentifier,
        remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]?
    ) -> Self
    func makeOpenSwiftDataSnapshot(in schema: Schema) throws -> OpenSwiftDataDataStoreSnapshot
    static func makeDataStoreSnapshot(from snapshot: OpenSwiftDataDataStoreSnapshot, in schema: Schema) throws -> Self
}

/// A typed fetch request for a custom store.
public struct DataStoreFetchRequest<Model: PersistentModel> {
    public let descriptor: FetchDescriptor<Model>
    public init(_ descriptor: FetchDescriptor<Model>) { self.descriptor = descriptor }
}

/// A custom-store fetch result.
public struct DataStoreFetchResult<Model: PersistentModel, Snapshot: DataStoreSnapshot> {
    public let descriptor: FetchDescriptor<Model>
    public let fetchedSnapshots: [Snapshot]
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

/// A batch of snapshots to insert, update, or delete atomically.
public struct DataStoreSaveChangesRequest<Snapshot: DataStoreSnapshot> {
    public let inserted: [Snapshot]
    public let updated: [Snapshot]
    public let deleted: [PersistentIdentifier]
    public init(inserted: [Snapshot], updated: [Snapshot], deleted: [PersistentIdentifier]) {
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
    }
}

/// The permanent identifiers and snapshots produced by a custom-store save.
public struct DataStoreSaveChangesResult: Sendable {
    public let storeIdentifier: String
    public let remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]
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

/// Creates a custom store for a model container.
public protocol DataStoreConfiguration: Sendable {
    associatedtype StoreType: DataStore where StoreType.Configuration == Self
    var name: String { get }
    var schema: Schema? { get set }
    func validate() throws
}

public extension DataStoreConfiguration {
    func validate() throws {}
}

/// A custom model store using typed snapshots and atomic save changes.
public protocol DataStore: AnyObject {
    associatedtype Configuration: DataStoreConfiguration where Configuration.StoreType == Self
    associatedtype Snapshot: DataStoreSnapshot
    init(_ configuration: Configuration, migrationPlan: (any SchemaMigrationPlan.Type)?) throws
    var configuration: Configuration { get }
    var name: String { get }
    var identifier: String { get }
    var schema: Schema { get }
    var supportsInheritance: Bool { get }
    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult<Model, Snapshot>
    func save(_ request: DataStoreSaveChangesRequest<Snapshot>) throws -> DataStoreSaveChangesResult
    func snapshot(for identifier: PersistentIdentifier) throws -> Snapshot?
}

public extension DataStore {
    var supportsInheritance: Bool { false }
    var name: String { configuration.name }
}

package func makeCanonicalStore<Configuration: DataStoreConfiguration>(
    _ configuration: Configuration,
    schema: Schema,
    migrationPlan: (any SchemaMigrationPlan.Type)?
) throws -> any OpenSwiftDataDataStore {
    try configuration.validate()
    let store = try Configuration.StoreType(configuration, migrationPlan: migrationPlan)
    return CanonicalDataStoreAdapter(store: store, schema: schema.descriptor)
}

private final class CanonicalDataStoreAdapter<Store: DataStore>: OpenSwiftDataDataStore, @unchecked Sendable {
    private let store: Store
    private let descriptor: SchemaDescriptor
    let identifier: String
    let supportsInheritance: Bool

    init(store: Store, schema: SchemaDescriptor) {
        self.store = store
        descriptor = schema
        identifier = store.identifier
        supportsInheritance = store.supportsInheritance
    }

    func fetch<Model: PersistentModel>(
        _ request: OpenSwiftDataDataStoreFetchRequest<Model>
    ) throws -> OpenSwiftDataDataStoreFetchResult {
        let result = try store.fetch(DataStoreFetchRequest(request.descriptor))
        let publicSchema = Schema(descriptor: descriptor)
        var roots: [OpenSwiftDataDataStoreSnapshot] = []
        var related: [PersistentIdentifier: OpenSwiftDataDataStoreSnapshot] = [:]
        var pending = result.fetchedSnapshots
        pending.append(contentsOf: result.relatedSnapshots.values)
        let rootIdentifiers = Set(result.fetchedSnapshots.map(\.persistentIdentifier))
        var visited: Set<PersistentIdentifier> = []
        while let snapshot = pending.popLast() {
            guard visited.insert(snapshot.persistentIdentifier).inserted else { continue }
            let converted = try snapshot.makeOpenSwiftDataSnapshot(in: publicSchema)
            if rootIdentifiers.contains(snapshot.persistentIdentifier) {
                roots.append(converted)
            } else {
                related[converted.persistentIdentifier] = converted
            }
            for identifier in snapshot.relationships.values.flatMap({ $0 }) {
                let relatedSnapshot: Store.Snapshot?
                if let explicitSnapshot = result.relatedSnapshots[identifier] {
                    relatedSnapshot = explicitSnapshot
                } else {
                    relatedSnapshot = try store.snapshot(for: identifier)
                }
                if let relatedSnapshot {
                    pending.append(relatedSnapshot)
                }
            }
        }
        return OpenSwiftDataDataStoreFetchResult(snapshots: roots, relatedSnapshots: related)
    }

    func reserveIdentifiers(for snapshots: [OpenSwiftDataDataStoreSnapshot]) throws -> [PersistentIdentifier: PersistentIdentifier] {
        [:]
    }

    func save(_ request: OpenSwiftDataDataStoreSaveRequest) throws -> OpenSwiftDataDataStoreSaveResult {
        let publicSchema = Schema(descriptor: descriptor)
        let inserts = try request.inserted.map { try Store.Snapshot.makeDataStoreSnapshot(from: $0, in: publicSchema) }
        let updates = try request.updated.map { try Store.Snapshot.makeDataStoreSnapshot(from: $0, in: publicSchema) }
        let deletions = request.deleted
        let result = try store.save(
            DataStoreSaveChangesRequest(inserted: inserts, updated: updates, deleted: deletions))
        return OpenSwiftDataDataStoreSaveResult(
            identifierRemappings: result.remappedIdentifiers,
            updatedIdentifiers: Set(request.updated.map(\.persistentIdentifier)),
            deletedIdentifiers: Set(request.deleted))
    }

    func snapshot(for identifier: PersistentIdentifier) throws -> OpenSwiftDataDataStoreSnapshot? {
        guard let snapshot = try store.snapshot(for: identifier) else { return nil }
        return try snapshot.makeOpenSwiftDataSnapshot(in: Schema(descriptor: descriptor))
    }
}

/// A type-erased configuration for an already-created custom store.
public struct ExistingDataStoreConfiguration: OpenSwiftDataDataStoreConfiguration {
    private let store: any OpenSwiftDataDataStore

    /// Creates a configuration that returns an existing store instance.
    public init(store: any OpenSwiftDataDataStore) {
        self.store = store
    }

    /// Returns the configured store; the store is responsible for validating the supplied schema.
    public func makeStore(schema: SchemaDescriptor) throws -> any OpenSwiftDataDataStore {
        _ = schema
        return store
    }
}

/// A custom store configuration aligned with Apple's associated-store configuration shape.
///
/// This prefixed API uses OpenSwiftData's current `SchemaDescriptor` type and remains separate from `OpenSwiftDataDataStoreConfiguration`.
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
public struct AppleDefaultSnapshot: DataStoreSnapshot, Equatable {
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

    /// Creates an identity-only snapshot because an untyped backing interface cannot expose registered model adapters.
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

public extension AppleDefaultSnapshot {
    /// Creates snapshots for a model and every reachable related model.
    ///
    /// Scalars use generated persistence adapters. Unsupported encodings throw instead of producing partial snapshots.
    static func capture(from model: any PersistentModel, in schema: SchemaDescriptor) throws -> [Self] {
        var snapshots: [PersistentIdentifier: Self] = [:]
        var pending: [any PersistentModel] = [model]
        while let current = pending.popLast() {
            let identifier = current.persistentModelID
            guard snapshots[identifier] == nil else { continue }
            let entityName = identifier.entityName
            guard let entity = schema.entity(forName: entityName) else {
                throw SwiftDataError.unsupportedStore("Snapshot entity '\(entityName)' is not in the schema.")
            }
            var values: [String: StoredValue] = [:]
            let propertyAdapters = type(of: current).erasedPersistenceAdapters()
            for attribute in entity.attributes where !attribute.options.contains(.flattened) {
                guard let adapter = propertyAdapters.first(where: { $0.name == attribute.name }) else { continue }
                values[attribute.name] = try adapter.encoded(current)
            }
            for adapter in type(of: current).flattenedPropertyAdapters() {
                values[adapter.columnName] = try adapter.encoded(current)
            }
            var relationships: [String: [PersistentIdentifier]] = [:]
            if let modelType = type(of: current) as? any RelationshipModel.Type {
                for adapter in modelType.relationshipAdapterCandidatesForMutation() {
                    guard entity.relationships.contains(where: { $0.name == adapter.name }),
                        let endpoints = adapter.read(current)
                    else { continue }
                    relationships[adapter.name] = endpoints.map(\.persistentModelID)
                    pending.append(contentsOf: endpoints)
                }
            }
            snapshots[identifier] = Self(
                persistentIdentifier: identifier,
                entityName: entityName,
                values: values,
                relationships: relationships)
        }
        return snapshots.values.sorted { $0.persistentIdentifier < $1.persistentIdentifier }
    }
}

extension AppleDefaultSnapshot {
    /// Converts this snapshot to the current OpenSwiftData context representation.
    /// Converts this snapshot to the context's stored representation after validating its entity.
    public func makeBackendSnapshot(in schema: SchemaDescriptor) throws -> OpenSwiftDataDataStoreSnapshot {
        guard schema.entity(forName: entityName) != nil else {
            throw SwiftDataError.unsupportedStore("Snapshot entity '\(entityName)' is not in the schema.")
        }
        return OpenSwiftDataDataStoreSnapshot(
            persistentIdentifier: persistentIdentifier, entityName: entityName,
            values: values, relationships: relationships)
    }

    /// Creates a snapshot from an OpenSwiftData context snapshot.
    /// Recreates a snapshot after validating its entity against the schema.
    public static func makeAppleSnapshot(from snapshot: OpenSwiftDataDataStoreSnapshot, in schema: SchemaDescriptor) throws -> Self {
        guard schema.entity(forName: snapshot.entityName) != nil else {
            throw SwiftDataError.unsupportedStore("Snapshot entity '\(snapshot.entityName)' is not in the schema.")
        }
        return Self(
            persistentIdentifier: snapshot.persistentIdentifier, entityName: snapshot.entityName,
            values: snapshot.values, relationships: snapshot.relationships)
    }
}

extension AppleDefaultSnapshot {
    public func makeOpenSwiftDataSnapshot(in schema: Schema) throws -> OpenSwiftDataDataStoreSnapshot {
        let value = try makeBackendSnapshot(in: schema.descriptor)
        return OpenSwiftDataDataStoreSnapshot(
            persistentIdentifier: value.persistentIdentifier, entityName: value.entityName,
            values: value.values, relationships: value.relationships)
    }

    public static func makeDataStoreSnapshot(
        from snapshot: OpenSwiftDataDataStoreSnapshot, in schema: Schema
    ) throws -> Self {
        try makeAppleSnapshot(
            from: OpenSwiftDataDataStoreSnapshot(
                persistentIdentifier: snapshot.persistentIdentifier, entityName: snapshot.entityName,
                values: snapshot.values, relationships: snapshot.relationships),
            in: schema.descriptor)
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
public protocol AppleDataStoreBackendProviding: AnyObject, Sendable {
    func makeBackend(schema: SchemaDescriptor, migrationPlan: (any SchemaMigrationPlan.Type)?) throws -> any OpenSwiftDataDataStore
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
