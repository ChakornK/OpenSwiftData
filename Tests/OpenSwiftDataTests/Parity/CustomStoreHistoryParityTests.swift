import Foundation
import OpenSwiftData
import Testing

@Model
final class HistoryParityFixture {
    var title: String
    init(title: String) { self.title = title }
}

/// A custom store that reports a history token from every save, backed by an in-memory snapshot table.
private final class HistoryReportingStoreState: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [PersistentIdentifier: OpenSwiftDataDataStoreSnapshot] = [:]
    private var nextKey: Int64 = 1

    func save(_ request: OpenSwiftDataDataStoreSaveRequest) throws -> OpenSwiftDataDataStoreSaveResult {
        lock.lock(); defer { lock.unlock() }
        var remappings: [PersistentIdentifier: PersistentIdentifier] = [:]
        for snapshot in request.inserted where snapshot.persistentIdentifier.isTemporary {
            let permanent = PersistentIdentifier(
                storeIdentifier: "history.fixture", entityName: snapshot.entityName, primaryKey: nextKey)
            nextKey += 1
            remappings[snapshot.persistentIdentifier] = permanent
        }
        for snapshot in request.inserted + request.updated {
            let permanent = remappings[snapshot.persistentIdentifier] ?? snapshot.persistentIdentifier
            rows[permanent] = OpenSwiftDataDataStoreSnapshot(
                persistentIdentifier: permanent, entityName: snapshot.entityName,
                values: snapshot.values, relationships: snapshot.relationships)
        }
        for identifier in request.deleted { rows.removeValue(forKey: identifier) }
        return OpenSwiftDataDataStoreSaveResult(
            identifierRemappings: remappings,
            updatedIdentifiers: Set(request.updated.map(\.persistentIdentifier)),
            deletedIdentifiers: Set(request.deleted),
            historyToken: DefaultHistoryToken(storeTokens: ["history.fixture": nextKey - 1]))
    }
}

private final class HistoryReportingDataStore: OpenSwiftDataDataStore, @unchecked Sendable {
    let identifier = "history.fixture"
    let state = HistoryReportingStoreState()

    func fetch<Model: PersistentModel>(_ request: OpenSwiftDataDataStoreFetchRequest<Model>) throws -> OpenSwiftDataDataStoreFetchResult {
        OpenSwiftDataDataStoreFetchResult(snapshots: [])
    }

    func save(_ request: OpenSwiftDataDataStoreSaveRequest) throws -> OpenSwiftDataDataStoreSaveResult {
        try state.save(request)
    }

    func snapshot(for identifier: PersistentIdentifier) throws -> OpenSwiftDataDataStoreSnapshot? { nil }
}

/// A custom store's history token must be recorded on save and retrievable through `fetchHistory`.
@MainActor @Suite struct CustomStoreHistoryPropagationTests {
    @Test func customStoreSaveRecordsAFetchableHistoryTransaction() throws {
        let store = HistoryReportingDataStore()
        let configuration = ModelConfiguration(
            "history-custom-store", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(for: HistoryParityFixture.self, configurations: configuration)
        let context = container.mainContext

        let model = HistoryParityFixture(title: "recorded")
        context.insert(model)
        try context.save()

        let transactions = try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
        #expect(!transactions.isEmpty)
        #expect(transactions.contains { ($0.token.tokenValue?["history.fixture"]) != nil })
        let storedIdentifiers = transactions.flatMap { transaction in
            transaction.changes.map(\.changedPersistentIdentifier)
        }
        #expect(storedIdentifiers.contains(model.persistentModelID))
    }
}
