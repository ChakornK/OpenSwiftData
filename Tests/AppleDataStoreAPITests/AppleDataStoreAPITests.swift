import OpenSwiftData
import Testing

@Model
final class AppleStoreFixture {
    var title: String
    init(title: String) { self.title = title }
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

private final class FixtureAppleStore: AppleDataStoreBackendProviding, @unchecked Sendable {
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

    func makeBackend(schema: SchemaDescriptor, migrationPlan: (any SchemaMigrationPlan.Type)?) throws -> any DataStore {
        _ = (schema, migrationPlan)
        return FixtureLegacyBackend()
    }
}

private struct FixtureLegacyBackend: DataStore {
    let identifier = "apple.fixture"
    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        DataStoreFetchResult(snapshots: [])
    }
    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult { DataStoreSaveResult() }
    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? { nil }
}

@Suite
struct AppleDataStoreAPITests {
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
