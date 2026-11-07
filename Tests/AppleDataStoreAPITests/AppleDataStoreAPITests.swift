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

    init(
        from backingData: any BackingData,
        relatedBackingDatas: inout [PersistentIdentifier: any BackingData]
    ) throws {
        _ = (backingData, relatedBackingDatas)
        throw SwiftDataError.unsupportedStore("fixture requires explicit snapshot values")
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
    var schema: Schema?

    func makeStore(schema: Schema, migrationPlan: (any SchemaMigrationPlan.Type)?) throws -> any AppleDataStore {
        FixtureAppleStore(self, schema: schema)
    }
}

private final class FixtureAppleStore: AppleDataStoreBackendProviding, @unchecked Sendable {
    let configuration: FixtureAppleConfiguration
    let identifier = "apple.fixture"
    let schema: Schema

    required init(_ configuration: FixtureAppleConfiguration, migrationPlan: (any SchemaMigrationPlan.Type)?) throws {
        guard let schema = configuration.schema else { throw SwiftDataError.unsupportedStore("Missing schema") }
        self.configuration = configuration
        self.schema = schema
    }

    fileprivate init(_ configuration: FixtureAppleConfiguration, schema: Schema) {
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

    func makeBackend(schema: Schema, migrationPlan: (any SchemaMigrationPlan.Type)?) throws -> any DataStore {
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

private final class FixtureTransactionState: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var snapshots: [PersistentIdentifier: DataStoreSnapshot] = [:]
    private var failAfterFirstInsert = false
    private var inserts = 0

    func enableFailure() { lock.lock(); failAfterFirstInsert = true; lock.unlock() }
    func resetFailure() { lock.lock(); failAfterFirstInsert = false; inserts = 0; lock.unlock() }

    func apply(_ request: DataStoreSaveRequest) throws {
        lock.lock(); defer { lock.unlock() }
        for snapshot in request.inserted {
            snapshots[snapshot.persistentIdentifier] = snapshot
            inserts += 1
            if failAfterFirstInsert, inserts == 1 {
                throw SwiftDataError.unsupportedStore("injected atomic write failure")
            }
        }
        for snapshot in request.updated { snapshots[snapshot.persistentIdentifier] = snapshot }
        for identifier in request.deleted { snapshots.removeValue(forKey: identifier) }
    }

    func all() -> [DataStoreSnapshot] { lock.lock(); defer { lock.unlock() }; return Array(snapshots.values) }
    func restore(_ values: [DataStoreSnapshot]) {
        lock.lock(); defer { lock.unlock() }
        snapshots = Dictionary(uniqueKeysWithValues: values.map { ($0.persistentIdentifier, $0) })
    }
}

private struct AtomicFixtureBackend: DataStore {
    let identifier = "apple.fixture"
    let state: FixtureTransactionState

    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        DataStoreFetchResult(snapshots: state.all())
    }

    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult {
        let before = state.all()
        do {
            try state.apply(request)
            return DataStoreSaveResult(
                updatedIdentifiers: Set(request.updated.map(\.persistentIdentifier)),
                deletedIdentifiers: Set(request.deleted))
        } catch {
            state.restore(before)
            state.resetFailure()
            throw error
        }
    }

    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? {
        state.all().first { $0.persistentIdentifier == identifier }
    }
}

@Suite
struct AppleDataStoreAPITests {
    @Test
    func testAppleStoreConformanceCompiles() throws {
        let schema = Schema([AppleStoreFixture.self])
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
    func testDefaultSnapshotBackingInitializerCapturesIdentityOnly() throws {
        let backing = DetachedBackingData<AppleStoreFixture>(metadata: AppleStoreFixture.schemaMetadata())
        var related: [PersistentIdentifier: any BackingData] = [:]
        let snapshot = try AppleDefaultSnapshot(from: backing, relatedBackingDatas: &related)
        #expect(snapshot.persistentIdentifier == backing.persistentModelID)
        #expect(snapshot.entityName == backing.persistentModelID.entityName)
        #expect(snapshot.values.isEmpty)
    }

    @Test @MainActor
    func testContainerRoutesAppleStoreConfigurationToBackend() throws {
        let schema = Schema([AppleStoreFixture.self])
        let configuration = FixtureAppleConfiguration(name: "fixture", schema: schema)
        let container = try ModelContainer(
            for: [AppleStoreFixture.self],
            configurations: [ModelConfiguration(
                appleStore: "apple-fixture", schema: schema,
                appleDataStoreConfiguration: configuration)])
        #expect(container.dataStore?.identifier == "apple.fixture")
    }

}
