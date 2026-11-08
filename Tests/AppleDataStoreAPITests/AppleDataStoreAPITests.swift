@testable import OpenSwiftData
import Testing

@Model
final class AppleStoreFixture {
    var title: String
    init(title: String) { self.title = title }
}

@Model
private final class AppleSnapshotRelatedFixture {
    var value: Int
    var owners: [AppleSnapshotOwnerFixture] = []
    init(value: Int) { self.value = value }
}

@Model
private final class AppleSnapshotOwnerFixture {
    var title: String
    var related: AppleSnapshotRelatedFixture?
    init(title: String, related: AppleSnapshotRelatedFixture? = nil) {
        self.title = title
        self.related = related
        related?.owners.append(self)
    }
}

private struct AppleSnapshotComposite: Codable, Sendable, FlattenableComposite {
    let count: Int
    static var flattenedComponents: [FlattenedComponent<Self>] {
        [FlattenedComponent("count", keyPath: \.count, set: { count, _ in Self(count: count) })]
    }
    static func emptyFlattenedValue() throws -> Self { Self(count: 0) }
}

@Model
private final class AppleSnapshotCompositeFixture {
    @Attribute(.flattened) var composite: AppleSnapshotComposite
    init(composite: AppleSnapshotComposite) { self.composite = composite }
}

private struct FixtureSnapshot: AppleDataStoreSnapshot {
    let persistentIdentifier: PersistentIdentifier
    let title: String

    init(persistentIdentifier: PersistentIdentifier, title: String) {
        self.persistentIdentifier = persistentIdentifier
        self.title = title
    }

    init(from backingData: any BackingData, relatedBackingDatas: inout [PersistentIdentifier: any BackingData]) {
        _ = (backingData, relatedBackingDatas)
        self.init(persistentIdentifier: backingData.persistentModelID, title: "")
    }

    func copy(
        persistentIdentifier: PersistentIdentifier,
        remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]?
    ) -> Self {
        Self(persistentIdentifier: remappedIdentifiers?[self.persistentIdentifier] ?? persistentIdentifier, title: title)
    }
}

private struct FixtureAppleConfiguration: AppleDataStoreConfiguration {
    typealias Store = FixtureAppleStore
    let name: String
    var schema: SchemaDescriptor?

    func makeStore(schema: SchemaDescriptor, migrationPlan: (any SchemaMigrationPlan.Type)?) throws -> any AppleDataStore {
        FixtureAppleStore(self, schema: schema)
    }
}

private final class FixtureAppleStore: AppleDataStore, AppleDataStoreBackendProviding, @unchecked Sendable {
    let configuration: FixtureAppleConfiguration
    let identifier = "apple.fixture"
    let schema: SchemaDescriptor

    required init(_ configuration: FixtureAppleConfiguration, migrationPlan: (any SchemaMigrationPlan.Type)?) throws {
        guard let schema = configuration.schema else { throw SwiftDataError.unsupportedStore("Missing schema") }
        self.configuration = configuration
        self.schema = schema
    }

    fileprivate init(_ configuration: FixtureAppleConfiguration, schema: SchemaDescriptor) {
        self.configuration = configuration
        self.schema = schema
    }

    func fetch<Model: PersistentModel>(
        _ request: AppleDataStoreFetchRequest<Model>
    ) throws -> AppleDataStoreFetchResult<Model, FixtureSnapshot> {
        AppleDataStoreFetchResult(descriptor: request.descriptor, fetchedSnapshots: [])
    }

    func save(_ request: AppleDataStoreSaveChangesRequest<FixtureSnapshot>) throws -> AppleDataStoreSaveChangesResult {
        AppleDataStoreSaveChangesResult(for: identifier)
    }

    func makeBackend(schema: SchemaDescriptor, migrationPlan: (any SchemaMigrationPlan.Type)?) throws -> any OpenSwiftDataDataStore {
        _ = (schema, migrationPlan)
        return FixtureLegacyBackend()
    }

}

private struct FixtureLegacyBackend: OpenSwiftDataDataStore {
    let identifier = "apple.fixture"
    func fetch<Model: PersistentModel>(_ request: OpenSwiftDataDataStoreFetchRequest<Model>) throws -> OpenSwiftDataDataStoreFetchResult {
        OpenSwiftDataDataStoreFetchResult(snapshots: [])
    }
    func save(_ request: OpenSwiftDataDataStoreSaveRequest) throws -> OpenSwiftDataDataStoreSaveResult {
        OpenSwiftDataDataStoreSaveResult()
    }
    func snapshot(for identifier: PersistentIdentifier) throws -> OpenSwiftDataDataStoreSnapshot? { nil }
}

private struct CanonicalFixtureConfiguration: DataStoreConfiguration {
    typealias StoreType = CanonicalFixtureStore
    let name: String
    var schema: Schema?
    init(name: String = "canonical.fixture", schema: Schema?) {
        self.name = name
        self.schema = schema
    }

}

private struct CanonicalFixtureSnapshot: DataStoreSnapshotValueProviding, Equatable {
    let persistentIdentifier: PersistentIdentifier
    let entityName: String
    let title: String?
    let value: Int64?
    let relationships: [String: [PersistentIdentifier]]

    var persistedValues: [String: DataStoreAttributeValue] {
        var values: [String: DataStoreAttributeValue] = [:]
        if let title { values["title"] = .text(title) }
        if let value { values["value"] = .int(value) }
        return values
    }

    init(
        persistentIdentifier: PersistentIdentifier,
        entityName: String,
        title: String? = nil,
        value: Int64? = nil,
        relationships: [String: [PersistentIdentifier]] = [:]
    ) {
        self.persistentIdentifier = persistentIdentifier
        self.entityName = entityName
        self.title = title
        self.value = value
        self.relationships = relationships
    }

    init(
        persistentIdentifier: PersistentIdentifier,
        entityName: String,
        persistedValues: [String: DataStoreAttributeValue],
        relationships: [String: [PersistentIdentifier]]
    ) {
        self.init(
            persistentIdentifier: persistentIdentifier,
            entityName: entityName,
            title: persistedValues["title"].flatMap { if case let .text(value) = $0 { value } else { nil } },
            value: persistedValues["value"].flatMap { if case let .int(value) = $0 { value } else { nil } },
            relationships: relationships)
    }

    init(from backingData: any BackingData, relatedBackingDatas: inout [PersistentIdentifier: any BackingData]) {
        _ = relatedBackingDatas
        let identifier = backingData.persistentModelID
        self.init(persistentIdentifier: identifier, entityName: identifier.entityName)
    }

    func copy(
        persistentIdentifier: PersistentIdentifier,
        remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]?
    ) -> Self {
        Self(
            persistentIdentifier: remappedIdentifiers?[self.persistentIdentifier] ?? persistentIdentifier,
            entityName: entityName,
            title: title,
            value: value,
            relationships: relationships.mapValues { $0.map { remappedIdentifiers?[$0] ?? $0 } })
    }

}

private struct CanonicalSourceShapeSnapshot: DataStoreSnapshot {
    let persistentIdentifier: PersistentIdentifier
    let entityName: String
    let relationships: [String: [PersistentIdentifier]]
    init(persistentIdentifier: PersistentIdentifier, relationships: [String: [PersistentIdentifier]] = [:]) {
        self.persistentIdentifier = persistentIdentifier
        entityName = persistentIdentifier.entityName
        self.relationships = relationships
    }
    init(from backingData: any BackingData, relatedBackingDatas: inout [PersistentIdentifier: any BackingData]) {
        _ = relatedBackingDatas
        self.init(persistentIdentifier: backingData.persistentModelID)
    }
    func copy(persistentIdentifier: PersistentIdentifier, remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]?) -> Self {
        Self(
            persistentIdentifier: remappedIdentifiers?[self.persistentIdentifier] ?? persistentIdentifier,
            relationships: relationships.mapValues { $0.map { remappedIdentifiers?[$0] ?? $0 } })
    }
}

private struct ProviderPrecedenceSnapshot: DataStoreSnapshotValueProviding {
    let persistentIdentifier: PersistentIdentifier
    let entityName: String
    let relationships: [String: [PersistentIdentifier]]
    let payload: String

    private enum CodingKeys: String, CodingKey {
        case persistentIdentifier
        case entityName
        case relationships
        case payload
    }

    init(
        persistentIdentifier: PersistentIdentifier,
        entityName: String,
        relationships: [String: [PersistentIdentifier]],
        payload: String
    ) {
        self.persistentIdentifier = persistentIdentifier
        self.entityName = entityName
        self.relationships = relationships
        self.payload = payload
    }

    var persistedValues: [String: DataStoreAttributeValue] { ["title": .text("provider value")] }

    init(from backingData: any BackingData, relatedBackingDatas: inout [PersistentIdentifier: any BackingData]) {
        _ = relatedBackingDatas
        persistentIdentifier = backingData.persistentModelID
        entityName = backingData.persistentModelID.entityName
        relationships = [:]
        payload = "codable value"
    }

    init(
        persistentIdentifier: PersistentIdentifier,
        entityName: String,
        persistedValues: [String: DataStoreAttributeValue],
        relationships: [String: [PersistentIdentifier]]
    ) {
        self.persistentIdentifier = persistentIdentifier
        self.entityName = entityName
        self.relationships = relationships
        payload = persistedValues["title"].flatMap { if case let .text(value) = $0 { value } else { nil } } ?? ""
    }

    func copy(
        persistentIdentifier: PersistentIdentifier,
        remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]?
    ) -> Self {
        Self(
            persistentIdentifier: remappedIdentifiers?[self.persistentIdentifier] ?? persistentIdentifier,
            entityName: entityName,
            persistedValues: persistedValues,
            relationships: relationships.mapValues { $0.map { remappedIdentifiers?[$0] ?? $0 } })
    }
}

private struct UnbridgedCanonicalConfiguration: DataStoreConfiguration {
    typealias StoreType = UnbridgedCanonicalStore
    let name: String
    var schema: Schema?
}

private final class UnbridgedCanonicalStore: DataStore, @unchecked Sendable {
    typealias Configuration = UnbridgedCanonicalConfiguration
    typealias Snapshot = CanonicalSourceShapeSnapshot
    let configuration: UnbridgedCanonicalConfiguration
    let identifier = "unbridged.canonical"
    var schema: Schema { configuration.schema ?? Schema() }
    required init(_ configuration: UnbridgedCanonicalConfiguration, migrationPlan: (any SchemaMigrationPlan.Type)?) throws {
        self.configuration = configuration
    }
    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult<Model, Snapshot> {
        DataStoreFetchResult(descriptor: request.descriptor, fetchedSnapshots: [])
    }
    func save(_ request: DataStoreSaveChangesRequest<Snapshot>) throws -> DataStoreSaveChangesResult {
        DataStoreSaveChangesResult(for: identifier)
    }
    func snapshot(for identifier: PersistentIdentifier) throws -> Snapshot? { nil }
}

private struct CodableConventionConfiguration: DataStoreConfiguration {
    typealias StoreType = CodableConventionStore
    let name: String
    var schema: Schema?
}

private struct CodableConventionSnapshot: DataStoreSnapshot {
    let persistentIdentifier: PersistentIdentifier
    let entityName: String
    let relationships: [String: [PersistentIdentifier]]
    let title: String?
    let value: Int64?

    private enum CodingKeys: String, CodingKey {
        case persistentIdentifier, entityName, relationships, values
    }

    private enum ValueKeys: String, CodingKey {
        case title, value
    }

    init(
        persistentIdentifier: PersistentIdentifier,
        entityName: String,
        relationships: [String: [PersistentIdentifier]],
        title: String?,
        value: Int64?
    ) {
        self.persistentIdentifier = persistentIdentifier
        self.entityName = entityName
        self.relationships = relationships
        self.title = title
        self.value = value
    }

    init(from backingData: any BackingData, relatedBackingDatas: inout [PersistentIdentifier: any BackingData]) {
        _ = relatedBackingDatas
        persistentIdentifier = backingData.persistentModelID
        entityName = backingData.persistentModelID.entityName
        relationships = [:]
        title = nil
        value = nil
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        persistentIdentifier = try container.decode(PersistentIdentifier.self, forKey: .persistentIdentifier)
        entityName = try container.decode(String.self, forKey: .entityName)
        relationships = try container.decode([String: [PersistentIdentifier]].self, forKey: .relationships)
        let values = try container.nestedContainer(keyedBy: ValueKeys.self, forKey: .values)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        value = try values.decodeIfPresent(Int64.self, forKey: .value)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(persistentIdentifier, forKey: .persistentIdentifier)
        try container.encode(entityName, forKey: .entityName)
        try container.encode(relationships, forKey: .relationships)
        var values = container.nestedContainer(keyedBy: ValueKeys.self, forKey: .values)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(value, forKey: .value)
    }

    func copy(
        persistentIdentifier: PersistentIdentifier,
        remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]?
    ) -> Self {
        Self(
            persistentIdentifier: remappedIdentifiers?[self.persistentIdentifier] ?? persistentIdentifier,
            entityName: entityName,
            relationships: relationships.mapValues { $0.map { remappedIdentifiers?[$0] ?? $0 } },
            title: title,
            value: value)
    }
}

private struct RenamedCodableSnapshot: DataStoreSnapshot {
    let persistentIdentifier: PersistentIdentifier
    let entityName: String
    let relationships: [String: [PersistentIdentifier]]
    let payload: String

    private enum CodingKeys: String, CodingKey {
        case persistentIdentifier
        case entityName
        case relationships
        case payload
    }

    init(
        persistentIdentifier: PersistentIdentifier,
        entityName: String,
        relationships: [String: [PersistentIdentifier]],
        payload: String
    ) {
        self.persistentIdentifier = persistentIdentifier
        self.entityName = entityName
        self.relationships = relationships
        self.payload = payload
    }

    init(from backingData: any BackingData, relatedBackingDatas: inout [PersistentIdentifier: any BackingData]) {
        _ = relatedBackingDatas
        persistentIdentifier = backingData.persistentModelID
        entityName = backingData.persistentModelID.entityName
        relationships = [:]
        payload = ""
    }

    func copy(
        persistentIdentifier: PersistentIdentifier,
        remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]?
    ) -> Self {
        Self(
            persistentIdentifier: remappedIdentifiers?[self.persistentIdentifier] ?? persistentIdentifier,
            entityName: entityName,
            relationships: relationships.mapValues { $0.map { remappedIdentifiers?[$0] ?? $0 } },
            payload: payload)
    }
}

private final class CodableConventionStore: DataStore, @unchecked Sendable {
    typealias Configuration = CodableConventionConfiguration
    typealias Snapshot = CodableConventionSnapshot
    let configuration: Configuration
    let identifier: String
    var schema: Schema { configuration.schema ?? Schema() }
    private let state: CodableConventionStoreState

    required init(_ configuration: Configuration, migrationPlan: (any SchemaMigrationPlan.Type)?) throws {
        self.configuration = configuration
        identifier = configuration.name
        state = CodableConventionRegistry.shared.state(for: configuration.name)
    }

    func fetch<Model: PersistentModel>(
        _ request: DataStoreFetchRequest<Model>
    ) throws -> DataStoreFetchResult<Model, Snapshot> {
        state.fetch(descriptor: request.descriptor, entityName: Schema.entityName(for: Model.self))
    }

    func save(_ request: DataStoreSaveChangesRequest<Snapshot>) throws -> DataStoreSaveChangesResult {
        try state.save(request, storeIdentifier: identifier)
    }

    func snapshot(for identifier: PersistentIdentifier) throws -> Snapshot? { state.snapshot(for: identifier) }
    static func failNextSave(for name: String) { CodableConventionRegistry.shared.state(for: name).failNextSave() }
}

private final class CodableConventionStoreState: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [PersistentIdentifier: CodableConventionSnapshot] = [:]
    private var failsNextSave = false

    func failNextSave() {
        lock.lock(); defer { lock.unlock() }
        failsNextSave = true
    }

    func fetch<Model: PersistentModel>(
        descriptor: FetchDescriptor<Model>, entityName: String
    ) -> DataStoreFetchResult<Model, CodableConventionSnapshot> {
        lock.lock(); defer { lock.unlock() }
        return DataStoreFetchResult(
            descriptor: descriptor,
            fetchedSnapshots: rows.values.filter { $0.entityName == entityName },
            relatedSnapshots: rows)
    }

    func snapshot(for identifier: PersistentIdentifier) -> CodableConventionSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return rows[identifier]
    }

    func save(
        _ request: DataStoreSaveChangesRequest<CodableConventionSnapshot>, storeIdentifier: String
    ) throws -> DataStoreSaveChangesResult {
        lock.lock(); defer { lock.unlock() }
        if failsNextSave {
            failsNextSave = false
            throw SwiftDataError.unsupportedStore("injected Codable convention save failure")
        }
        var candidate = rows
        for identifier in request.deleted { candidate.removeValue(forKey: identifier) }
        var remappings: [PersistentIdentifier: PersistentIdentifier] = [:]
        var nextPrimaryKey = (candidate.values.compactMap(\.persistentIdentifier.primaryKey).max() ?? 0) + 1
        for snapshot in request.inserted where snapshot.persistentIdentifier.isTemporary {
            remappings[snapshot.persistentIdentifier] = PersistentIdentifier(
                storeIdentifier: storeIdentifier, entityName: snapshot.entityName, primaryKey: nextPrimaryKey)
            nextPrimaryKey += 1
        }
        for snapshot in request.inserted + request.updated {
            let permanentID = remappings[snapshot.persistentIdentifier] ?? snapshot.persistentIdentifier
            let remapped = snapshot.copy(persistentIdentifier: permanentID, remappedIdentifiers: remappings)
            candidate[remapped.persistentIdentifier] = remapped
        }
        rows = candidate
        return DataStoreSaveChangesResult(for: storeIdentifier, remappedIdentifiers: remappings)
    }
}

private final class CodableConventionRegistry: @unchecked Sendable {
    static let shared = CodableConventionRegistry()
    private let lock = NSLock()
    private var storage: [String: CodableConventionStoreState] = [:]

    func state(for name: String) -> CodableConventionStoreState {
        lock.lock(); defer { lock.unlock() }
        if let state = storage[name] { return state }
        let state = CodableConventionStoreState()
        storage[name] = state
        return state
    }
}

private final class CanonicalStoreState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PersistentIdentifier: CanonicalFixtureSnapshot] = [:]
    private var failsNextSave = false

    func failNextSave() {
        lock.lock(); defer { lock.unlock() }
        failsNextSave = true
    }

    func snapshots() -> [CanonicalFixtureSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return Array(values.values)
    }

    func snapshot(for identifier: PersistentIdentifier) -> CanonicalFixtureSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return values[identifier]
    }

    func save(_ request: DataStoreSaveChangesRequest<CanonicalFixtureSnapshot>, storeIdentifier: String) throws -> DataStoreSaveChangesResult {
        lock.lock(); defer { lock.unlock() }
        if failsNextSave {
            failsNextSave = false
            throw SwiftDataError.unsupportedStore("injected canonical store save failure")
        }
        var candidate = values
        for identifier in request.deleted { candidate.removeValue(forKey: identifier) }
        var remappings: [PersistentIdentifier: PersistentIdentifier] = [:]
        var nextKey = (candidate.values.compactMap(\.persistentIdentifier.primaryKey).max() ?? 0) + 1
        var insertedMappings: [(CanonicalFixtureSnapshot, PersistentIdentifier)] = []
        for snapshot in request.inserted {
            let identifier = snapshot.persistentIdentifier
            let permanent = identifier.isTemporary
                ? PersistentIdentifier(storeIdentifier: storeIdentifier, entityName: identifier.entityName, primaryKey: nextKey)
                : identifier
            if identifier.isTemporary { nextKey += 1; remappings[identifier] = permanent }
            insertedMappings.append((snapshot, permanent))
        }
        for (source, permanent) in insertedMappings {
            let remapped = source.copy(persistentIdentifier: permanent, remappedIdentifiers: remappings)
            candidate[remapped.persistentIdentifier] = remapped
        }
        for snapshot in request.updated { candidate[snapshot.persistentIdentifier] = snapshot }
        values = candidate
        return DataStoreSaveChangesResult(for: storeIdentifier, remappedIdentifiers: remappings)
    }
}

private final class CanonicalFixtureStore: DataStore, @unchecked Sendable {
    typealias Configuration = CanonicalFixtureConfiguration
    typealias Snapshot = CanonicalFixtureSnapshot
    let configuration: CanonicalFixtureConfiguration
    let identifier = "canonical.fixture"
    var schema: Schema { configuration.schema ?? Schema() }
    var supportsInheritance: Bool { true }
    let state: CanonicalStoreState

    required init(_ configuration: CanonicalFixtureConfiguration, migrationPlan: (any SchemaMigrationPlan.Type)?) throws {
        self.configuration = configuration
        state = Self.stateForConfiguration(configuration)
    }

    func fetch<Model: PersistentModel>(
        _ request: DataStoreFetchRequest<Model>
    ) throws -> DataStoreFetchResult<Model, CanonicalFixtureSnapshot> {
        let rows = state.snapshots().filter { $0.entityName == Schema.entityName(for: Model.self) }
        return DataStoreFetchResult(descriptor: request.descriptor, fetchedSnapshots: Array(rows))
    }

    func save(_ request: DataStoreSaveChangesRequest<CanonicalFixtureSnapshot>) throws -> DataStoreSaveChangesResult {
        try state.save(request, storeIdentifier: identifier)
    }

    func snapshot(for identifier: PersistentIdentifier) throws -> CanonicalFixtureSnapshot? { state.snapshot(for: identifier) }

    private static let states = CanonicalStoreStates()
    static func failNextSave(for name: String) { states.state(for: name).failNextSave() }
    private static func stateForConfiguration(_ configuration: CanonicalFixtureConfiguration) -> CanonicalStoreState {
        states.state(for: configuration.name)
    }
}

private final class CanonicalStoreStates: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: CanonicalStoreState] = [:]
    func state(for name: String) -> CanonicalStoreState {
        lock.lock(); defer { lock.unlock() }
        if let existing = storage[name] { return existing }
        let state = CanonicalStoreState()
        storage[name] = state
        return state
    }
}

private struct DefaultSnapshotConfiguration: DataStoreConfiguration {
    typealias StoreType = DefaultSnapshotStore
    let name: String
    var schema: Schema?
}

private final class DefaultSnapshotStore: DataStore, @unchecked Sendable {
    typealias Configuration = DefaultSnapshotConfiguration
    typealias Snapshot = AppleDefaultSnapshot
    let configuration: Configuration
    let identifier: String
    var schema: Schema { configuration.schema ?? Schema() }
    private let state: CanonicalDefaultStoreState

    required init(_ configuration: Configuration, migrationPlan: (any SchemaMigrationPlan.Type)?) throws {
        self.configuration = configuration
        identifier = configuration.name
        state = CanonicalDefaultStoreStates.shared.state(for: configuration.name)
    }

    func fetch<Model: PersistentModel>(
        _ request: DataStoreFetchRequest<Model>
    ) throws -> DataStoreFetchResult<Model, Snapshot> {
        state.fetch(entityName: Schema.entityName(for: Model.self), descriptor: request.descriptor)
    }

    func save(_ request: DataStoreSaveChangesRequest<Snapshot>) throws -> DataStoreSaveChangesResult {
        try state.save(request, storeIdentifier: identifier)
    }

    func snapshot(for identifier: PersistentIdentifier) throws -> Snapshot? { state.snapshot(for: identifier) }

    static func failNextSave(for name: String) { CanonicalDefaultStoreStates.shared.state(for: name).failNextSave() }
}

private final class CanonicalDefaultStoreState: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [PersistentIdentifier: AppleDefaultSnapshot] = [:]
    private var failsNextSave = false

    func failNextSave() {
        lock.lock(); defer { lock.unlock() }
        failsNextSave = true
    }

    func fetch<Model: PersistentModel>(
        entityName: String, descriptor: FetchDescriptor<Model>
    ) -> DataStoreFetchResult<Model, AppleDefaultSnapshot> {
        lock.lock(); defer { lock.unlock() }
        return DataStoreFetchResult(
            descriptor: descriptor,
            fetchedSnapshots: snapshots.values.filter { $0.entityName == entityName },
            relatedSnapshots: snapshots)
    }

    func snapshot(for identifier: PersistentIdentifier) -> AppleDefaultSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshots[identifier]
    }

    func save(_ request: DataStoreSaveChangesRequest<AppleDefaultSnapshot>, storeIdentifier: String) throws -> DataStoreSaveChangesResult {
        lock.lock(); defer { lock.unlock() }
        if failsNextSave {
            failsNextSave = false
            throw SwiftDataError.unsupportedStore("injected canonical default snapshot save failure")
        }
        var candidate = snapshots
        for identifier in request.deleted { candidate.removeValue(forKey: identifier) }
        var remappings: [PersistentIdentifier: PersistentIdentifier] = [:]
        var nextKey = (candidate.values.compactMap(\.persistentIdentifier.primaryKey).max() ?? 0) + 1
        for snapshot in request.inserted {
            if snapshot.persistentIdentifier.isTemporary {
                remappings[snapshot.persistentIdentifier] = PersistentIdentifier(
                    storeIdentifier: storeIdentifier, entityName: snapshot.entityName, primaryKey: nextKey)
                nextKey += 1
            }
        }
        for snapshot in request.inserted {
            let permanent = remappings[snapshot.persistentIdentifier] ?? snapshot.persistentIdentifier
            let copied = snapshot.copy(persistentIdentifier: permanent, remappedIdentifiers: remappings)
            candidate[copied.persistentIdentifier] = copied
        }
        for snapshot in request.updated { candidate[snapshot.persistentIdentifier] = snapshot }
        snapshots = candidate
        return DataStoreSaveChangesResult(for: storeIdentifier, remappedIdentifiers: remappings)
    }
}

private final class CanonicalDefaultStoreStates: @unchecked Sendable {
    static let shared = CanonicalDefaultStoreStates()
    private let lock = NSLock()
    private var states: [String: CanonicalDefaultStoreState] = [:]

    func state(for name: String) -> CanonicalDefaultStoreState {
        lock.lock(); defer { lock.unlock() }
        if let state = states[name] { return state }
        let state = CanonicalDefaultStoreState()
        states[name] = state
        return state
    }
}

@Suite
struct AppleDataStoreAPITests {
    @Test
    func dataStoreSnapshotCodingKeysRoundTrip() throws {
        let identifier = DataStoreSnapshotCodingKey(stringValue: "persistentIdentifier")
        if case .persistentIdentifier = identifier {} else { Issue.record("Expected persistent identifier key") }
        #expect(identifier?.stringValue == "persistentIdentifier")

        let property = DataStoreSnapshotCodingKey(stringValue: "profile.displayName")
        if case .modeledProperty("profile.displayName") = property {} else { Issue.record("Expected modeled property key") }
        #expect(property?.stringValue == "profile.displayName")
        #expect(DataStoreSnapshotCodingKey(intValue: 0) == nil)
    }

    @Test
    func canonicalDataStoreContractCompiles() throws {
        let schema = Schema([AppleStoreFixture.self])
        let configuration = CanonicalFixtureConfiguration(schema: schema)
        let store = try CanonicalFixtureStore(configuration, migrationPlan: nil)
        #expect(store.schema.entities.count == 1)
        #expect(store.name == "canonical.fixture")
        let identifier = PersistentIdentifier(storeIdentifier: "canonical.fixture", entityName: "AppleStoreFixture", primaryKey: 1)
        let sourceShapeSnapshot = CanonicalSourceShapeSnapshot(persistentIdentifier: identifier)
        #expect(sourceShapeSnapshot.entityName == "AppleStoreFixture")
    }

    @Test
    func canonicalSnapshotConformanceDoesNotRequireEngineConversions() throws {
        let schema = Schema([AppleStoreFixture.self])
        let configuration = UnbridgedCanonicalConfiguration(name: "unbridged", schema: schema)
        let store = try UnbridgedCanonicalStore(configuration, migrationPlan: nil)
        let result = try store.fetch(DataStoreFetchRequest(FetchDescriptor<AppleStoreFixture>()))
        #expect(result.fetchedSnapshots.isEmpty)
    }

    @MainActor
    @Test
    func baseOnlySnapshotStoreCanOpenEmptyContainer() throws {
        let schema = Schema([AppleStoreFixture.self])
        let configuration = ModelConfiguration(
            canonicalStore: "unbridged", schema: schema,
            canonicalDataStoreConfiguration: UnbridgedCanonicalConfiguration(name: "unbridged", schema: schema))
        let container = try ModelContainer(for: [AppleStoreFixture.self], configurations: [configuration])
        #expect(container.dataStore?.identifier == "unbridged.canonical")
    }

    @MainActor
    @Test
    func canonicalDataStoreConfigurationRoutesContainerOperations() throws {
        let schema = Schema([AppleStoreFixture.self])
        let configuration = ModelConfiguration(
            canonicalStore: "canonical.fixture", schema: schema,
            canonicalDataStoreConfiguration: CanonicalFixtureConfiguration(schema: schema))
        let container = try ModelContainer(for: [AppleStoreFixture.self], configurations: [configuration])
        let model = AppleStoreFixture(title: "canonical")
        container.mainContext.insert(model)
        try container.mainContext.save()
        #expect(container.dataStore?.identifier == "canonical.fixture")
        let fetched = try container.makeContext().fetch(FetchDescriptor<AppleStoreFixture>())
        #expect(fetched.map(\.title) == ["canonical"])
    }

    @MainActor
    @Test
    func baseDataStoreSnapshotCodableConventionRoundTripsRelationshipsAndRollback() throws {
        let schema = Schema([AppleSnapshotOwnerFixture.self, AppleSnapshotRelatedFixture.self])
        let name = "codable-convention-\(UUID().uuidString)"
        let configuration = ModelConfiguration(
            canonicalStore: name, schema: schema,
            canonicalDataStoreConfiguration: CodableConventionConfiguration(name: name, schema: schema))
        let container = try ModelContainer(
            for: [AppleSnapshotOwnerFixture.self, AppleSnapshotRelatedFixture.self], configurations: [configuration])
        let related = AppleSnapshotRelatedFixture(value: 88)
        let owner = AppleSnapshotOwnerFixture(title: "base protocol only", related: related)
        container.mainContext.insert(owner)
        CodableConventionStore.failNextSave(for: name)

        #expect(throws: (any Error).self) { try container.mainContext.save() }
        #expect(owner.modelContext === container.mainContext)
        try container.mainContext.save()

        let fetched = try #require(container.makeContext().fetch(FetchDescriptor<AppleSnapshotOwnerFixture>()).first)
        #expect(fetched.title == "base protocol only")
        #expect(fetched.related?.value == 88)
    }

    @Test
    func codableConventionRejectsRenamedKeysAndWrongTypes() throws {
        let schema = Schema([AppleStoreFixture.self]).descriptor
        let entity = try #require(schema.entity(forName: "AppleStoreFixture"))

        #expect(throws: SnapshotMaterializationError.self) {
            try projectSnapshotValues(
                from: ["persistentIdentifier": NSNull(), "entityName": "AppleStoreFixture", "relationships": [:], "payload": "renamed"],
                entity: entity)
        }

        #expect(throws: SnapshotMaterializationError.self) {
            try projectSnapshotValues(
                from: ["persistentIdentifier": NSNull(), "entityName": "AppleStoreFixture", "relationships": [:], "title": 42],
                entity: entity)
        }
    }

    @Test
    func snapshotCodingKeyMaterializesModeledProperty() throws {
        let entity = try #require(Schema([AppleStoreFixture.self]).descriptor.entity(forName: "AppleStoreFixture"))
        let values = try projectSnapshotValues(
            from: [
                "persistentIdentifier": NSNull(),
                "entityName": entity.name,
                "relationships": [:],
                DataStoreSnapshotCodingKey.modeledProperty("title").stringValue: "coded through Apple key",
            ],
            entity: entity)
        #expect(values["title"] == .text("coded through Apple key"))
    }

    @Test
    func opaqueSnapshotLayoutFailsBeforeModelMaterialization() throws {
        let schema = Schema([AppleStoreFixture.self]).descriptor
        let entity = try #require(schema.entity(forName: "AppleStoreFixture"))
        let snapshot = RenamedCodableSnapshot(
            persistentIdentifier: PersistentIdentifier(
                storeIdentifier: "opaque", entityName: entity.name, primaryKey: 1),
            entityName: entity.name,
            relationships: [:],
            payload: "not a schema field")

        #expect(throws: SnapshotMaterializationError.self) {
            try materializeSnapshotValues(from: snapshot, entity: entity)
        }
    }

    @Test
    func snapshotProviderTakesPrecedenceOverCodableLayout() throws {
        let identifier = PersistentIdentifier(
            storeIdentifier: "provider.precedence", entityName: "AppleStoreFixture", primaryKey: 1)
        let snapshot = ProviderPrecedenceSnapshot(
            persistentIdentifier: identifier,
            entityName: "AppleStoreFixture",
            persistedValues: ["title": .text("provider value")],
            relationships: [:])
        let schema = Schema([AppleStoreFixture.self]).descriptor
        let entity = try #require(schema.entity(forName: "AppleStoreFixture"))

        #expect(throws: SnapshotMaterializationError.self) {
            try projectSnapshotValues(
                from: [
                    "persistentIdentifier": NSNull(), "entityName": "AppleStoreFixture",
                    "relationships": [:], "payload": "codable value",
                ], entity: entity)
        }
        #expect(try materializeSnapshotValues(from: snapshot, entity: entity)["title"] == .text("provider value"))
    }

    @MainActor
    @Test
    func customStoreWithDefaultSnapshotRunsWithoutOpenSwiftDataBridge() throws {
        let schema = Schema([AppleSnapshotOwnerFixture.self, AppleSnapshotRelatedFixture.self])
        let name = "canonical-default-snapshot-\(UUID().uuidString)"
        let configuration = ModelConfiguration(
            canonicalStore: name, schema: schema,
            canonicalDataStoreConfiguration: DefaultSnapshotConfiguration(name: name, schema: schema))
        let container = try ModelContainer(
            for: [AppleSnapshotOwnerFixture.self, AppleSnapshotRelatedFixture.self], configurations: [configuration])
        let related = AppleSnapshotRelatedFixture(value: 73)
        let owner = AppleSnapshotOwnerFixture(title: "native canonical snapshot", related: related)
        container.mainContext.insert(owner)
        DefaultSnapshotStore.failNextSave(for: name)

        #expect(throws: (any Error).self) { try container.mainContext.save() }
        #expect(owner.modelContext === container.mainContext)
        try container.mainContext.save()

        let fresh = container.makeContext()
        let fetched = try #require(fresh.fetch(FetchDescriptor<AppleSnapshotOwnerFixture>()).first)
        #expect(fetched.title == "native canonical snapshot")
        #expect(fetched.related?.value == 73)
    }

    @MainActor
    @Test
    func customCanonicalSnapshotRoutesRelationshipsAndFetch() throws {
        let schema = Schema([AppleSnapshotOwnerFixture.self, AppleSnapshotRelatedFixture.self])
        let name = "canonical-graph-\(UUID().uuidString)"
        let configuration = ModelConfiguration(
            canonicalStore: name, schema: schema,
            canonicalDataStoreConfiguration: CanonicalFixtureConfiguration(name: name, schema: schema))
        let container = try ModelContainer(
            for: [AppleSnapshotOwnerFixture.self, AppleSnapshotRelatedFixture.self], configurations: [configuration])
        let context = container.mainContext
        let related = AppleSnapshotRelatedFixture(value: 41)
        let owner = AppleSnapshotOwnerFixture(title: "custom snapshot", related: related)
        context.insert(owner)
        try context.save()

        let fresh = container.makeContext()
        let fetched = try #require(fresh.fetch(FetchDescriptor<AppleSnapshotOwnerFixture>()).first)
        #expect(fetched.title == "custom snapshot")
        #expect(fetched.related?.value == 41)
    }

    @MainActor
    @Test
    func customCanonicalSnapshotSaveFailurePreservesPendingModel() throws {
        let schema = Schema([AppleStoreFixture.self])
        let name = "canonical-rollback-\(UUID().uuidString)"
        let configuration = ModelConfiguration(
            canonicalStore: name, schema: schema,
            canonicalDataStoreConfiguration: CanonicalFixtureConfiguration(name: name, schema: schema))
        let container = try ModelContainer(for: [AppleStoreFixture.self], configurations: [configuration])
        let model = AppleStoreFixture(title: "retry")
        container.mainContext.insert(model)
        CanonicalFixtureStore.failNextSave(for: name)

        #expect(throws: (any Error).self) { try container.mainContext.save() }
        #expect(model.modelContext === container.mainContext)
        #expect(model.title == "retry")
        try container.mainContext.save()
        #expect(try container.makeContext().fetch(FetchDescriptor<AppleStoreFixture>()).map(\.title) == ["retry"])
    }

    @MainActor
    @Test
    func testDefaultSnapshotCaptureIncludesScalarAndRelatedValues() throws {
        let related = AppleSnapshotRelatedFixture(value: 7)
        let owner = AppleSnapshotOwnerFixture(title: "snapshot", related: related)
        let schema = try ModelContainer.inferredSchema(
            for: [AppleSnapshotOwnerFixture.self, AppleSnapshotRelatedFixture.self])
        let snapshots = try AppleDefaultSnapshot.capture(from: owner, in: schema)
        let ownerSnapshot = try #require(snapshots.first { $0.entityName == "AppleSnapshotOwnerFixture" })
        let relatedSnapshot = try #require(snapshots.first { $0.entityName == "AppleSnapshotRelatedFixture" })

        #expect(ownerSnapshot.values["title"] == .text("snapshot"))
        #expect(ownerSnapshot.relationships["related"] == [related.persistentModelID])
        #expect(relatedSnapshot.values["value"] == .int(7))
        #expect(relatedSnapshot.relationships["owners"] == [owner.persistentModelID])
        #expect(snapshots.count == 2)

        let remappedOwner = PersistentIdentifier(
            storeIdentifier: "snapshot.store", entityName: owner.persistentModelID.entityName, primaryKey: 30)
        let remappedRelated = PersistentIdentifier(
            storeIdentifier: "snapshot.store", entityName: related.persistentModelID.entityName, primaryKey: 31)
        let remappings = [owner.persistentModelID: remappedOwner, related.persistentModelID: remappedRelated]
        let copied = ownerSnapshot.copy(persistentIdentifier: remappedOwner, remappedIdentifiers: remappings)
        #expect(copied.relationships["related"] == [remappedRelated])

        let compositeModel = AppleSnapshotCompositeFixture(composite: AppleSnapshotComposite(count: 42))
        let compositeSchema = try ModelContainer.inferredSchema(for: [AppleSnapshotCompositeFixture.self])
        let compositeSnapshots = try AppleDefaultSnapshot.capture(from: compositeModel, in: compositeSchema)
        let compositeSnapshot = try #require(compositeSnapshots.first)
        #expect(compositeSnapshot.values["composite_count"] == .int(42))
    }

    @Test
    func testAppleStoreConformanceCompiles() throws {
        let schema = try ModelContainer.inferredSchema(for: [AppleStoreFixture.self])
        let config = FixtureAppleConfiguration(name: "fixture", schema: schema)
        let store = try FixtureAppleStore(config, migrationPlan: nil)
        #expect(store.schema == schema)
        #expect(store.identifier == "apple.fixture")
    }

    @Test
    func testSnapshotCopyRemapsIdentifiers() throws {
        let original = PersistentIdentifier(
            storeIdentifier: "apple.fixture", entityName: "AppleStoreFixture", temporaryIdentifier: UUID())
        let permanent = PersistentIdentifier(storeIdentifier: "apple.fixture", entityName: "AppleStoreFixture", primaryKey: 7)
        let snapshot = FixtureSnapshot(persistentIdentifier: original, title: "test")
        let copy = snapshot.copy(persistentIdentifier: permanent, remappedIdentifiers: [original: permanent])
        #expect(copy.persistentIdentifier == permanent)
        #expect(copy.title == "test")
    }

    @Test
    @available(*, deprecated, message: "Exercises the intentionally deprecated identity-only initializer.")
    func testDefaultSnapshotBackingInitializerCapturesIdentityOnly() throws {
        let backing = DetachedBackingData<AppleStoreFixture>(metadata: AppleStoreFixture.schemaMetadata())
        var related: [PersistentIdentifier: any BackingData] = [:]
        let snapshot = AppleDefaultSnapshot(from: backing, relatedBackingDatas: &related)
        #expect(snapshot.persistentIdentifier == backing.persistentModelID)
        #expect(snapshot.entityName == backing.persistentModelID.entityName)
        #expect(snapshot.values.isEmpty)
    }

    @Test @MainActor
    func testContainerRoutesAppleStoreConfigurationToBackend() throws {
        let schema = try ModelContainer.inferredSchema(for: [AppleStoreFixture.self])
        let configuration = FixtureAppleConfiguration(name: "fixture", schema: schema)
        let container = try ModelContainer(
            for: [AppleStoreFixture.self],
            configurations: [ModelConfiguration(
                appleStore: "apple-fixture", schema: Schema(descriptor: schema),
                appleDataStoreConfiguration: configuration)])
        #expect(container.dataStore?.identifier == "apple.fixture")
    }
}
