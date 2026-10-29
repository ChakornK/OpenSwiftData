import Foundation
import XCTest
@testable import OpenSwiftData

@Model
final class CustomDataStoreFixture {
    var value: Int
    init(value: Int) { self.value = value }
}

@Model
final class CustomDataStoreOwner {
    var name: String
    @Relationship(inverse: nil) var destination: CustomDataStoreDestination?

    init(name: String, destination: CustomDataStoreDestination? = nil) {
        self.name = name
        self.destination = destination
    }
}

@Model
final class CustomDataStoreDestination {
    var title: String
    @Relationship(inverse: nil) var owner: CustomDataStoreOwner?
    init(title: String) { self.title = title }
}

private final class DictionaryDataStore: DataStore, @unchecked Sendable {
    let identifier = "custom.dictionary"
    private let lock = NSRecursiveLock()
    private var nextPrimaryKey: Int64 = 1
    private var snapshots: [PersistentIdentifier: DataStoreSnapshot] = [:]
    private var reservations: [PersistentIdentifier: PersistentIdentifier] = [:]

    func reserveIdentifiers(for snapshots: [DataStoreSnapshot]) throws -> [PersistentIdentifier: PersistentIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        var remappings: [PersistentIdentifier: PersistentIdentifier] = [:]
        for snapshot in snapshots {
            let identifier = PersistentIdentifier(
                storeIdentifier: self.identifier, entityName: snapshot.entityName, primaryKey: nextPrimaryKey)
            nextPrimaryKey += 1
            remappings[snapshot.persistentIdentifier] = identifier
        }
        reservations.merge(remappings) { _, new in new }
        return remappings
    }

    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        lock.lock()
        defer { lock.unlock() }
        var rows = snapshots.values.filter { $0.entityName == request.entity.name }
        rows.sort { ($0.persistentIdentifier.primaryKey ?? 0) < ($1.persistentIdentifier.primaryKey ?? 0) }
        let offset = request.descriptor.fetchOffset ?? 0
        rows = Array(rows.dropFirst(offset))
        if let limit = request.descriptor.fetchLimit { rows = Array(rows.prefix(limit)) }
        return DataStoreFetchResult(snapshots: rows)
    }

    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult {
        lock.lock()
        defer { lock.unlock() }
        for snapshot in request.inserted {
            let identifier = snapshot.persistentIdentifier
            snapshots[identifier] = DataStoreSnapshot(
                persistentIdentifier: identifier, entityName: snapshot.entityName,
                values: snapshot.values,
                relationships: snapshot.relationships)
        }
        for snapshot in request.updated {
            snapshots[snapshot.persistentIdentifier] = DataStoreSnapshot(
                persistentIdentifier: snapshot.persistentIdentifier, entityName: snapshot.entityName,
                values: snapshot.values,
                relationships: snapshot.relationships)
        }
        for identifier in request.deleted { snapshots.removeValue(forKey: identifier) }
        return DataStoreSaveResult(
            identifierRemappings: [:],
            updatedIdentifiers: Set(request.updated.map(\.persistentIdentifier)),
            deletedIdentifiers: Set(request.deleted))
    }

    private func remapRelationships(
        _ relationships: [String: [PersistentIdentifier]],
        using remappings: [PersistentIdentifier: PersistentIdentifier]
    ) -> [String: [PersistentIdentifier]] {
        relationships.mapValues { $0.map { remappings[$0] ?? $0 } }
    }

    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[identifier]
    }
}

private final class FailsOnceDataStore: DataStore, @unchecked Sendable {
    let identifier = "custom.dictionary.fails-once"
    private let lock = NSLock()
    private var didFail = false
    private var rows: [PersistentIdentifier: DataStoreSnapshot] = [:]
    private var nextID: Int64 = 1
    private var reservations: [PersistentIdentifier: PersistentIdentifier] = [:]

    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        lock.lock()
        defer { lock.unlock() }
        return DataStoreFetchResult(snapshots: rows.values.filter { $0.entityName == request.entity.name })
    }

    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult {
        lock.lock()
        defer { lock.unlock() }
        if !didFail {
            didFail = true
            throw SwiftDataError.unsupportedStore("first save fails")
        }
        for snapshot in request.inserted {
            let identifier = snapshot.persistentIdentifier
            rows[identifier] = DataStoreSnapshot(
                persistentIdentifier: identifier, entityName: snapshot.entityName,
                values: snapshot.values, relationships: snapshot.relationships)
        }
        return DataStoreSaveResult()
    }

    func reserveIdentifiers(for snapshots: [DataStoreSnapshot]) throws -> [PersistentIdentifier: PersistentIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        var result: [PersistentIdentifier: PersistentIdentifier] = [:]
        for snapshot in snapshots {
            if let existing = reservations[snapshot.persistentIdentifier] {
                result[snapshot.persistentIdentifier] = existing
            } else {
                let destination = PersistentIdentifier(
                    storeIdentifier: identifier, entityName: snapshot.entityName, primaryKey: nextID)
                nextID += 1
                result[snapshot.persistentIdentifier] = destination
            }
        }
        reservations.merge(result) { old, _ in old }
        return result
    }

    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return rows[identifier]
    }

}

final class DataStoreTests: XCTestCase {
    @MainActor
    func testConfiguredDataStoreSupportsSnapshotSaveFetchAndDelete() throws {
        let dataStore = DictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store", dataStoreConfiguration: ExistingDataStoreConfiguration(store: dataStore))
        let container = try ModelContainer(for: CustomDataStoreFixture.self, configurations: configuration)
        let context = container.mainContext

        let inserted = CustomDataStoreFixture(value: 1)
        context.insert(inserted)
        try context.save()
        XCTAssertEqual(inserted.persistentModelID.storeIdentifier, dataStore.identifier)
        XCTAssertFalse(inserted.persistentModelID.isTemporary)
        XCTAssertTrue(try context.model(for: inserted.persistentModelID) as CustomDataStoreFixture? === inserted)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CustomDataStoreFixture>()).map(\.value), [1])

        inserted.value = 2
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<CustomDataStoreFixture>()).map(\.value), [2])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CustomDataStoreFixture>()), 1)
        XCTAssertEqual(
            try context.fetchIdentifiers(FetchDescriptor<CustomDataStoreFixture>()), [inserted.persistentModelID])

        context.delete(inserted)
        try context.save()
        XCTAssertTrue(try context.fetch(FetchDescriptor<CustomDataStoreFixture>()).isEmpty)
    }

    @MainActor
    func testFailedDataStoreSaveRetainsPendingInsertion() throws {
        let store = FailingDictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store-failure", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(for: CustomDataStoreFixture.self, configurations: configuration)
        let context = container.mainContext
        let model = CustomDataStoreFixture(value: 42)
        context.insert(model)
        XCTAssertThrowsError(try context.save())
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(model.persistentModelID.isTemporary)
    }

    @MainActor
    func testDataStoreRejectsPartialFetchesAndIncompleteSnapshots() throws {
        let dataStore = DictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store-partial", dataStoreConfiguration: ExistingDataStoreConfiguration(store: dataStore))
        let container = try ModelContainer(for: CustomDataStoreFixture.self, configurations: configuration)
        let context = container.mainContext
        XCTAssertThrowsError(
            try context.fetch(FetchDescriptor<CustomDataStoreFixture>(propertiesToFetch: [\.value])))

        let malformedStore = MalformedSnapshotDataStore()
        let malformedConfiguration = ModelConfiguration(
            "custom-store-malformed", dataStoreConfiguration: ExistingDataStoreConfiguration(store: malformedStore))
        let malformedContainer = try ModelContainer(
            for: CustomDataStoreFixture.self, configurations: malformedConfiguration)
        XCTAssertThrowsError(
            try malformedContainer.mainContext.fetch(FetchDescriptor<CustomDataStoreFixture>()))
    }

    @MainActor
    func testDataStoreSnapshotsRoundTripFlattenedComponentValues() throws {
        let store = DictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store-flattened", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(for: FlattenedCompositeFixture.self, configurations: configuration)
        let context = container.mainContext
        let value = FlattenedDimensions(width: 12, label: "custom")
        context.insert(FlattenedCompositeFixture(dimensions: value))
        try context.save()
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FlattenedCompositeFixture>()).first?.dimensions,
            value)
    }

    @MainActor
    func testDataStoreSnapshotsRoundTripRelationshipsByIdentifier() throws {
        let store = DictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store-relationships", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(
            for: CustomDataStoreOwner.self, CustomDataStoreDestination.self, configurations: configuration)
        let context = container.mainContext
        let destination = CustomDataStoreDestination(title: "destination")
        let owner = CustomDataStoreOwner(name: "owner", destination: destination)
        context.insert(owner)
        try context.save()

        let reader = container.makeContext()
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<CustomDataStoreOwner>()).first)
        XCTAssertFalse(fetched.destination === destination)
        XCTAssertEqual(fetched.destination?.title, "destination")

        let replacement = CustomDataStoreDestination(title: "replacement")
        context.insert(replacement)
        owner.destination = replacement
        try context.save()
        XCTAssertEqual(
            try container.makeContext().fetch(FetchDescriptor<CustomDataStoreOwner>()).first?.destination?.title,
            "replacement")
    }

    @MainActor
    func testDataStoreSnapshotsRoundTripCyclicRelationshipGraph() throws {
        let store = DictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store-cycle", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(
            for: CustomDataStoreOwner.self, CustomDataStoreDestination.self, configurations: configuration)
        let context = container.mainContext
        let owner = CustomDataStoreOwner(name: "cycle")
        let destination = CustomDataStoreDestination(title: "cycle destination")
        owner.destination = destination
        destination.owner = owner
        context.insert(owner)
        try context.save()

        let fetchedOwner = try XCTUnwrap(context.fetch(FetchDescriptor<CustomDataStoreOwner>()).first)
        let fetchedDestination = try XCTUnwrap(fetchedOwner.destination)
        XCTAssertTrue(fetchedDestination.owner === fetchedOwner)
    }

    @MainActor
    func testFailedDataStoreBatchCanRetryWithReservedIdentifiers() throws {
        let store = FailsOnceDataStore()
        let configuration = ModelConfiguration(
            "custom-store-retry", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(for: CustomDataStoreFixture.self, configurations: configuration)
        let context = container.mainContext
        let model = CustomDataStoreFixture(value: 99)
        context.insert(model)
        XCTAssertThrowsError(try context.save())
        XCTAssertTrue(context.hasChanges)
        try context.save()
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CustomDataStoreFixture>()).first?.value, 99)
    }

    @MainActor
    func testInvalidDataStoreSaveResultDoesNotFinalizeContextModels() throws {
        let store = InvalidSaveResultDataStore()
        let configuration = ModelConfiguration(
            "custom-store-invalid-result", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(for: CustomDataStoreFixture.self, configurations: configuration)
        let context = container.mainContext
        let model = CustomDataStoreFixture(value: 7)
        context.insert(model)
        XCTAssertThrowsError(try context.save())
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(model.persistentModelID.isTemporary)
    }
}

private struct FailingDictionaryDataStore: DataStore {
    let identifier = "custom.dictionary.failure"
    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        DataStoreFetchResult(snapshots: [])
    }
    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult {
        throw SwiftDataError.unsupportedStore("injected custom DataStore failure")
    }
    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? { nil }
}

private struct InvalidSaveResultDataStore: DataStore {
    let identifier = "custom.dictionary.invalid-result"
    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        DataStoreFetchResult(snapshots: [])
    }
    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult {
        DataStoreSaveResult()
    }
    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? { nil }
}

private struct MalformedSnapshotDataStore: DataStore {
    let identifier = "custom.dictionary.malformed"
    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        let identifier = PersistentIdentifier(
            storeIdentifier: self.identifier, entityName: request.entity.name, primaryKey: 1)
        return DataStoreFetchResult(
            snapshots: [DataStoreSnapshot(persistentIdentifier: identifier, entityName: request.entity.name)])
    }
    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult { DataStoreSaveResult() }
    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? { nil }
}
