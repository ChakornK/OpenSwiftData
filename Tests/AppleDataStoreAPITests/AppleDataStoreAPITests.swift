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

private final class CanonicalFixtureStore: DataStore, @unchecked Sendable {
    typealias Configuration = CanonicalFixtureConfiguration
    typealias Snapshot = AppleDefaultSnapshot
    let configuration: CanonicalFixtureConfiguration
    let identifier = "canonical.fixture"
    var schema: Schema { configuration.schema ?? Schema() }
    var supportsInheritance: Bool { true }
    private var snapshots: [PersistentIdentifier: AppleDefaultSnapshot] = [:]

    required init(_ configuration: CanonicalFixtureConfiguration, migrationPlan: (any SchemaMigrationPlan.Type)?) throws {
        self.configuration = configuration
    }

    func fetch<Model: PersistentModel>(
        _ request: DataStoreFetchRequest<Model>
    ) throws -> DataStoreFetchResult<Model, AppleDefaultSnapshot> {
        let rows = snapshots.values.filter { $0.entityName == Schema.entityName(for: Model.self) }
        return DataStoreFetchResult(descriptor: request.descriptor, fetchedSnapshots: Array(rows))
    }

    func save(_ request: DataStoreSaveChangesRequest<AppleDefaultSnapshot>) throws -> DataStoreSaveChangesResult {
        for identifier in request.deleted { snapshots.removeValue(forKey: identifier) }
        var remappings: [PersistentIdentifier: PersistentIdentifier] = [:]
        for snapshot in request.inserted {
            let permanent = PersistentIdentifier(
                storeIdentifier: identifier,
                entityName: snapshot.persistentIdentifier.entityName,
                primaryKey: Int64(snapshots.count + 1))
            remappings[snapshot.persistentIdentifier] = permanent
            snapshots[permanent] = snapshot.copy(persistentIdentifier: permanent, remappedIdentifiers: remappings)
        }
        for snapshot in request.updated { snapshots[snapshot.persistentIdentifier] = snapshot }
        return DataStoreSaveChangesResult(for: identifier, remappedIdentifiers: remappings)
    }

    func snapshot(for identifier: PersistentIdentifier) throws -> AppleDefaultSnapshot? { snapshots[identifier] }
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
