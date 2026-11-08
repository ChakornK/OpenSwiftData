import OpenSwiftData
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

private struct CanonicalFixtureSnapshot: DataStoreSnapshot, Equatable {
    let persistentIdentifier: PersistentIdentifier
    let entityName: String
    let values: [String: StoredValue]
    let relationships: [String: [PersistentIdentifier]]

    init(
        persistentIdentifier: PersistentIdentifier,
        entityName: String,
        values: [String: StoredValue],
        relationships: [String: [PersistentIdentifier]] = [:]
    ) {
        self.persistentIdentifier = persistentIdentifier
        self.entityName = entityName
        self.values = values
        self.relationships = relationships
    }

    init(from backingData: any BackingData, relatedBackingDatas: inout [PersistentIdentifier: any BackingData]) {
        _ = relatedBackingDatas
        let identifier = backingData.persistentModelID
        self.init(persistentIdentifier: identifier, entityName: identifier.entityName, values: [:])
    }

    func copy(
        persistentIdentifier: PersistentIdentifier,
        remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]?
    ) -> Self {
        Self(
            persistentIdentifier: remappedIdentifiers?[self.persistentIdentifier] ?? persistentIdentifier,
            entityName: entityName,
            values: values,
            relationships: relationships.mapValues { $0.map { remappedIdentifiers?[$0] ?? $0 } })
    }

    func makeOpenSwiftDataSnapshot(in schema: Schema) throws -> OpenSwiftDataDataStoreSnapshot {
        OpenSwiftDataDataStoreSnapshot(
            persistentIdentifier: persistentIdentifier, entityName: entityName, values: values,
            relationships: relationships)
    }

    static func makeDataStoreSnapshot(from snapshot: OpenSwiftDataDataStoreSnapshot, in schema: Schema) throws -> Self {
        Self(
            persistentIdentifier: snapshot.persistentIdentifier, entityName: snapshot.entityName,
            values: snapshot.values, relationships: snapshot.relationships)
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

@Suite
struct AppleDataStoreAPITests {
    @Test
    func canonicalDataStoreContractCompiles() throws {
        let schema = Schema([AppleStoreFixture.self])
        let configuration = CanonicalFixtureConfiguration(schema: schema)
        let store = try CanonicalFixtureStore(configuration, migrationPlan: nil)
        #expect(store.schema.entities.count == 1)
        #expect(store.name == "canonical.fixture")
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
