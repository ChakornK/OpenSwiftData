import Foundation
import CoreFoundation
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
}

/// A Codable and Sendable value that a data store snapshot can persist.
public typealias DataStoreSnapshotValue = Codable & Sendable

/// A coding key for the persistent identifier or a modeled property in a data store snapshot.
public enum DataStoreSnapshotCodingKey: CodingKey, Sendable {
    case persistentIdentifier
    case modeledProperty(String)

    public var stringValue: String {
        switch self {
        case .persistentIdentifier: "persistentIdentifier"
        case let .modeledProperty(name): name
        }
    }

    public init?(stringValue: String) {
        if stringValue == "persistentIdentifier" {
            self = .persistentIdentifier
        } else {
            self = .modeledProperty(stringValue)
        }
    }

    public var intValue: Int? { nil }

    public init?(intValue: Int) { return nil }
}

/// Exposes persisted property values without coupling a canonical snapshot to the legacy store snapshot type.
public protocol DataStoreSnapshotValueProviding: DataStoreSnapshot {
    var persistedValues: [String: DataStoreAttributeValue] { get }
    init(
        persistentIdentifier: PersistentIdentifier,
        entityName: String,
        persistedValues: [String: DataStoreAttributeValue],
        relationships: [String: [PersistentIdentifier]]
    )
}

/// A scalar value that a custom store can map to a model attribute.
public enum DataStoreAttributeValue: Sendable, Equatable, Codable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case data(Data)

    init(_ storedValue: StoredValue) {
        switch storedValue {
        case .null: self = .null
        case let .int(value): self = .int(value)
        case let .double(value): self = .double(value)
        case let .text(value): self = .text(value)
        case let .blob(bytes): self = .data(Data(bytes))
        }
    }

    var storedValue: StoredValue {
        switch self {
        case .null: .null
        case let .int(value): .int(value)
        case let .double(value): .double(value)
        case let .text(value): .text(value)
        case let .data(value): .blob(Array(value))
        }
    }
}

package enum SnapshotMaterializationError: Error, Equatable, CustomStringConvertible {
    case encodingFailed(String)
    case unsupportedLayout(entity: String, missingKeys: [String], extraKeys: [String])
    case typeMismatch(entity: String, key: String, expectedType: String)

    package var description: String {
        switch self {
        case let .encodingFailed(message): "Snapshot encoding failed: \(message)"
        case let .unsupportedLayout(entity, missing, extra):
            "Snapshot layout for '\(entity)' is unsupported (missing keys: \(missing), extra keys: \(extra))."
        case let .typeMismatch(entity, key, expectedType):
            "Snapshot value '\(entity).\(key)' does not match declared type '\(expectedType)'."
        }
    }
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
    let makeSnapshot: (OpenSwiftDataDataStoreSnapshot) throws -> any DataStoreSnapshot = { snapshot in
        if let snapshotType = Configuration.StoreType.Snapshot.self as? any DataStoreSnapshotValueProviding.Type {
            return makeSnapshotValue(snapshot, as: snapshotType)
        }
        let encoded: Data
        do {
            encoded = try snapshotJSON(snapshot)
        } catch {
            throw SwiftDataError.unsupportedStore(
                SnapshotMaterializationError.encodingFailed(String(describing: error)).description)
        }
        let decoded = try decodeSnapshot(
            Configuration.StoreType.Snapshot.self, from: encoded, entity: snapshot.entityName)
        return decoded.copy(persistentIdentifier: snapshot.persistentIdentifier, remappedIdentifiers: nil)
    }
    return CanonicalDataStoreAdapter(
        store: store,
        schema: schema.descriptor,
        makeSnapshot: makeSnapshot)
}

private func makeSnapshotValue(
    _ snapshot: OpenSwiftDataDataStoreSnapshot, as type: any DataStoreSnapshotValueProviding.Type
) -> any DataStoreSnapshot {
    type.init(
        persistentIdentifier: snapshot.persistentIdentifier,
        entityName: snapshot.entityName,
        persistedValues: snapshot.values.mapValues(DataStoreAttributeValue.init),
        relationships: snapshot.relationships)
}

private func decodeSnapshot<Snapshot: DataStoreSnapshot>(
    _ type: Snapshot.Type, from data: Data, entity: String
) throws -> Snapshot {
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        if var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let reservedKeys: Set<String> = ["persistentIdentifier", "entityName", "relationships", "values"]
            let valueKeys = object.keys.filter { !reservedKeys.contains($0) }
            if !object.keys.contains("values") {
                var values: [String: Any] = [:]
                for key in valueKeys { values[key] = object.removeValue(forKey: key) }
                object["values"] = values
                if let nestedData = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) {
                    if let decoded = try? JSONDecoder().decode(type, from: nestedData) { return decoded }
                }
                throw SwiftDataError.unsupportedStore(
                    SnapshotMaterializationError.unsupportedLayout(
                        entity: entity, missingKeys: [], extraKeys: valueKeys.sorted()).description)
            }
        }
        throw SwiftDataError.unsupportedStore(
            SnapshotMaterializationError.unsupportedLayout(entity: entity, missingKeys: [], extraKeys: []).description)
    }
}

private func storedValue(from json: Any, entity: String, key: String, type: String) throws -> StoredValue {
    let typeName = type.split(separator: ".").last.map(String.init) ?? type
    let integerTypes: Set<String> = ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64"]
    if json is NSNull { return .null }
    if let number = json as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
        guard typeName == "Bool" else {
            throw SnapshotMaterializationError.typeMismatch(entity: entity, key: key, expectedType: type)
        }
        return .int(number.boolValue ? 1 : 0)
    }
    if let string = json as? String {
        if typeName == "Data" {
            guard let bytes = Data(base64Encoded: string) else {
                throw SnapshotMaterializationError.typeMismatch(entity: entity, key: key, expectedType: type)
            }
            return .blob(Array(bytes))
        }
        guard ["String", "URL", "UUID", "Date", "Decimal"].contains(typeName) else {
            throw SnapshotMaterializationError.typeMismatch(entity: entity, key: key, expectedType: type)
        }
        if typeName == "UUID", let uuid = UUID(uuidString: string) {
            return .blob(withUnsafeBytes(of: uuid.uuid) { Array($0) })
        }
        return .text(string)
    }
    if let number = json as? NSNumber {
        if typeName == "Double" || typeName == "Float" || typeName == "Date" {
            return .double(number.doubleValue)
        }
        guard integerTypes.contains(typeName), let integer = Int64(number.stringValue) else {
            throw SnapshotMaterializationError.typeMismatch(entity: entity, key: key, expectedType: type)
        }
        return .int(integer)
    }
    if !(json is [String: Any]) && !(json is [Any]) {
        throw SnapshotMaterializationError.typeMismatch(entity: entity, key: key, expectedType: type)
    }
    let data = try JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed, .sortedKeys])
    return .blob(Array(data))
}

package func projectSnapshotValues(
    from object: [String: Any], entity: SchemaDescriptor.Entity
) throws -> [String: StoredValue] {
    let reservedKeys: Set<String> = ["persistentIdentifier", "entityName", "relationships"]
    let attributeKeys = Set(
        entity.attributes.flatMap { attribute in
            attribute.options.contains(.flattened)
                ? attribute.components.map(\.columnName)
                : [attribute.name]
        })
    let topLevelKeys = reservedKeys.union(attributeKeys)
    let valueContainerKeys = reservedKeys.union(["values"])
    let values: [String: Any]
    if Set(object.keys) == topLevelKeys {
        values = object
    } else if Set(object.keys) == valueContainerKeys, let nested = object["values"] as? [String: Any],
        Set(nested.keys) == attributeKeys
    {
        values = nested
    } else {
        throw SnapshotMaterializationError.unsupportedLayout(
            entity: entity.name,
            missingKeys: topLevelKeys.subtracting(object.keys).sorted(),
            extraKeys: Set(object.keys).subtracting(topLevelKeys).sorted())
    }
    var storedValues: [String: StoredValue] = [:]
    for attribute in entity.attributes {
        if attribute.options.contains(.flattened) {
            for component in attribute.components {
                guard let json = values[component.columnName] else {
                    throw SnapshotMaterializationError.unsupportedLayout(
                        entity: entity.name, missingKeys: [component.columnName], extraKeys: [])
                }
                storedValues[component.columnName] = try storedValue(
                    from: json, entity: entity.name, key: component.columnName, type: component.type)
            }
        } else {
            guard let json = values[attribute.name] else {
                throw SnapshotMaterializationError.unsupportedLayout(
                    entity: entity.name, missingKeys: [attribute.name], extraKeys: [])
            }
            storedValues[attribute.name] = try storedValue(
                from: json, entity: entity.name, key: attribute.name, type: attribute.type)
        }
    }
    return storedValues
}

package func materializeSnapshotValues(
    from snapshot: any DataStoreSnapshot,
    entity: SchemaDescriptor.Entity
) throws -> [String: StoredValue] {
    if let valueSnapshot = snapshot as? any DataStoreSnapshotValueProviding {
        return valueSnapshot.persistedValues.mapValues(\.storedValue)
    }
    do {
        let data = try JSONEncoder().encode(snapshot)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SnapshotMaterializationError.unsupportedLayout(
                entity: entity.name, missingKeys: [], extraKeys: [])
        }
        return try projectSnapshotValues(from: object, entity: entity)
    } catch let error as SnapshotMaterializationError {
        throw error
    } catch {
        throw SnapshotMaterializationError.encodingFailed(String(describing: error))
    }
}

private func snapshotJSON(_ snapshot: OpenSwiftDataDataStoreSnapshot) throws -> Data {
    var object: [String: Any] = [
        "persistentIdentifier": try jsonObject(snapshot.persistentIdentifier),
        "entityName": snapshot.entityName,
        "relationships": try jsonObject(snapshot.relationships),
    ]
    for (key, value) in snapshot.values {
        switch value {
        case .null:
            object[key] = NSNull()
        case let .int(integer):
            object[key] = NSNumber(value: integer)
        case let .double(number):
            object[key] = NSNumber(value: number)
        case let .text(text):
            object[key] = text
        case let .blob(bytes):
            let data = Data(bytes)
            if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                object[key] = json
            } else {
                object[key] = data.base64EncodedString()
            }
        }
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
}

private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

private final class CanonicalDataStoreAdapter<Store: DataStore>: OpenSwiftDataDataStore, @unchecked Sendable {
    private let store: Store
    private let descriptor: SchemaDescriptor
    private let makeSnapshot: (OpenSwiftDataDataStoreSnapshot) throws -> any DataStoreSnapshot
    let identifier: String
    let supportsInheritance: Bool

    init(
        store: Store,
        schema: SchemaDescriptor,
        makeSnapshot: @escaping (OpenSwiftDataDataStoreSnapshot) throws -> any DataStoreSnapshot
    ) {
        self.store = store
        descriptor = schema
        self.makeSnapshot = makeSnapshot
        identifier = store.identifier
        supportsInheritance = store.supportsInheritance
    }

    func fetch<Model: PersistentModel>(
        _ request: OpenSwiftDataDataStoreFetchRequest<Model>
    ) throws -> OpenSwiftDataDataStoreFetchResult {
        let result = try store.fetch(DataStoreFetchRequest(request.descriptor))
        var roots: [OpenSwiftDataDataStoreSnapshot] = []
        var related: [PersistentIdentifier: OpenSwiftDataDataStoreSnapshot] = [:]
        var pending: [any DataStoreSnapshot] = result.fetchedSnapshots
        for snapshot in result.relatedSnapshots.values { pending.append(snapshot) }
        let rootIdentifiers = Set(result.fetchedSnapshots.map(\.persistentIdentifier))
        var visited: Set<PersistentIdentifier> = []
        while let snapshot = pending.popLast() {
            guard visited.insert(snapshot.persistentIdentifier).inserted else { continue }
            let converted = try backendSnapshot(snapshot)
            if rootIdentifiers.contains(snapshot.persistentIdentifier) {
                roots.append(converted)
            } else {
                related[converted.persistentIdentifier] = converted
            }
            for identifier in snapshot.relationships.values.flatMap({ $0 }) {
                let relatedSnapshot: (any DataStoreSnapshot)?
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
        let inserts = try request.inserted.map { snapshot -> Store.Snapshot in
            guard let typed = try makeCanonicalSnapshot(snapshot) as? Store.Snapshot else {
                throw SwiftDataError.unsupportedStore("Canonical snapshot factory returned an incompatible type.")
            }
            return typed
        }
        let updates = try request.updated.map { snapshot -> Store.Snapshot in
            guard let typed = try makeCanonicalSnapshot(snapshot) as? Store.Snapshot else {
                throw SwiftDataError.unsupportedStore("Canonical snapshot factory returned an incompatible type.")
            }
            return typed
        }
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
        return try backendSnapshot(snapshot)
    }

    private func makeCanonicalSnapshot(_ snapshot: OpenSwiftDataDataStoreSnapshot) throws -> any DataStoreSnapshot {
        try makeSnapshot(snapshot)
    }

    private func backendSnapshot(_ snapshot: any DataStoreSnapshot) throws -> OpenSwiftDataDataStoreSnapshot {
        guard let identity = snapshot as? Store.Snapshot else {
            throw SwiftDataError.unsupportedStore("Canonical snapshot type mismatch.")
        }
        guard let entity = descriptor.entity(forName: identity.entityName) else {
            throw SwiftDataError.unsupportedStore("Canonical snapshot refers to unknown entity '\(identity.entityName)'.")
        }
        let values: [String: StoredValue]
        do {
            values = try materializeSnapshotValues(from: identity, entity: entity)
        } catch let error as SnapshotMaterializationError {
            throw SwiftDataError.unsupportedStore(error.description)
        }
        return OpenSwiftDataDataStoreSnapshot(
            persistentIdentifier: identity.persistentIdentifier,
            entityName: identity.entityName,
            values: values,
            relationships: identity.relationships)
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
public struct AppleDefaultSnapshot: DataStoreSnapshotValueProviding, Equatable {
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

    public var persistedValues: [String: DataStoreAttributeValue] { values.mapValues(DataStoreAttributeValue.init) }

    public init(
        persistentIdentifier: PersistentIdentifier,
        entityName: String,
        persistedValues: [String: DataStoreAttributeValue],
        relationships: [String: [PersistentIdentifier]]
    ) {
        self.init(
            persistentIdentifier: persistentIdentifier,
            entityName: entityName,
            values: persistedValues.mapValues(\.storedValue),
            relationships: relationships)
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
