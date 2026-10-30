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

@Model
class CustomHierarchyBase {
    var name: String
    init(name: String) { self.name = name }
}

@Model
class CustomHierarchyChild: CustomHierarchyBase {
    var score: Int
    init(name: String, score: Int) {
        self.score = score
        super.init(name: name)
    }
}

@Model
final class CustomHierarchyGrandchild: CustomHierarchyChild {
    var rank: Int
    init(name: String, score: Int, rank: Int) {
        self.rank = rank
        super.init(name: name, score: score)
    }
}

@Model
final class CustomHierarchyOwner {
    var label: String
    @Relationship(inverse: nil) var target: CustomHierarchyBase?

    init(label: String, target: CustomHierarchyBase? = nil) {
        self.label = label
        self.target = target
    }
}

private final class DictionaryDataStore: DataStore, @unchecked Sendable {
    let identifier = "custom.dictionary"
    let supportsInheritance = true
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
        var rows = snapshots.values.filter { request.includedEntityNames.contains($0.entityName) }
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

private struct UnsupportedHierarchyDataStore: DataStore {
    let identifier = "custom.flat-only"

    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        DataStoreFetchResult(snapshots: [])
    }

    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult { DataStoreSaveResult() }

    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? { nil }
}

private struct MismatchedHierarchySnapshotDataStore: DataStore {
    let identifier = "custom.hierarchy.mismatched"
    let supportsInheritance = true

    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        let identifier = PersistentIdentifier(
            storeIdentifier: self.identifier, entityName: "CustomHierarchyChild", primaryKey: 1)
        return DataStoreFetchResult(
            snapshots: [
                DataStoreSnapshot(
                    persistentIdentifier: identifier,
                    entityName: "CustomHierarchyGrandchild",
                    values: ["name": .text("bad"), "score": .int(1), "rank": .int(2)])
            ])
    }

    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult { DataStoreSaveResult() }

    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? { nil }
}

private struct OutsideHierarchySnapshotDataStore: DataStore {
    let identifier = "custom.hierarchy.outside"
    let supportsInheritance = true

    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        let identifier = PersistentIdentifier(
            storeIdentifier: self.identifier, entityName: "CustomDataStoreFixture", primaryKey: 1)
        return DataStoreFetchResult(
            snapshots: [
                DataStoreSnapshot(
                    persistentIdentifier: identifier,
                    entityName: "CustomDataStoreFixture",
                    values: ["value": .int(1)])
            ])
    }

    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult { DataStoreSaveResult() }

    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? { nil }
}

private struct DuplicateHierarchySnapshotDataStore: DataStore {
    let identifier = "custom.hierarchy.duplicate"
    let supportsInheritance = true

    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        let identifier = PersistentIdentifier(
            storeIdentifier: self.identifier, entityName: "CustomHierarchyChild", primaryKey: 5)
        let original = DataStoreSnapshot(
            persistentIdentifier: identifier,
            entityName: "CustomHierarchyChild",
            values: ["name": .text("first"), "score": .int(1)])
        let conflicting = DataStoreSnapshot(
            persistentIdentifier: identifier,
            entityName: "CustomHierarchyChild",
            values: ["name": .text("second"), "score": .int(2)])
        return DataStoreFetchResult(snapshots: [original, conflicting])
    }

    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult { DataStoreSaveResult() }

    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? { nil }
}

private struct InvalidHierarchyRelationshipDataStore: DataStore {
    let identifier = "custom.hierarchy.invalid-relationship"
    let supportsInheritance = true
    private let ownerIdentifier = PersistentIdentifier(
        storeIdentifier: "custom.hierarchy.invalid-relationship", entityName: "CustomHierarchyOwner", primaryKey: 1)
    private let wrongTargetIdentifier = PersistentIdentifier(
        storeIdentifier: "custom.hierarchy.invalid-relationship", entityName: "CustomDataStoreFixture", primaryKey: 2)

    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        guard request.entity.name == "CustomHierarchyOwner" else { return DataStoreFetchResult(snapshots: []) }
        return DataStoreFetchResult(
            snapshots: [
                DataStoreSnapshot(
                    persistentIdentifier: ownerIdentifier,
                    entityName: "CustomHierarchyOwner",
                    values: ["label": .text("owner")],
                    relationships: ["target": [wrongTargetIdentifier]])
            ])
    }

    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult { DataStoreSaveResult() }

    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? {
        guard identifier == wrongTargetIdentifier else { return nil }
        return DataStoreSnapshot(
            persistentIdentifier: wrongTargetIdentifier,
            entityName: "CustomDataStoreFixture",
            values: ["value": .int(1)])
    }
}

private final class FailsOnceDataStore: DataStore, @unchecked Sendable {
    let identifier = "custom.dictionary.fails-once"
    let supportsInheritance = true
    private let lock = NSLock()
    private let failOnSaveNumber: Int
    private var saveCount = 0
    private var rows: [PersistentIdentifier: DataStoreSnapshot] = [:]
    private var nextID: Int64 = 1
    private var reservations: [PersistentIdentifier: PersistentIdentifier] = [:]

    init(failOnSaveNumber: Int = 1) {
        self.failOnSaveNumber = failOnSaveNumber
    }

    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        lock.lock()
        defer { lock.unlock() }
        return DataStoreFetchResult(
            snapshots: rows.values.filter { request.includedEntityNames.contains($0.entityName) })
    }

    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult {
        lock.lock()
        defer { lock.unlock() }
        saveCount += 1
        if saveCount == failOnSaveNumber {
            throw SwiftDataError.unsupportedStore("injected save failure")
        }
        for snapshot in request.inserted {
            let identifier = snapshot.persistentIdentifier
            rows[identifier] = DataStoreSnapshot(
                persistentIdentifier: identifier, entityName: snapshot.entityName,
                values: snapshot.values, relationships: snapshot.relationships)
        }
        for snapshot in request.updated {
            rows[snapshot.persistentIdentifier] = DataStoreSnapshot(
                persistentIdentifier: snapshot.persistentIdentifier,
                entityName: snapshot.entityName,
                values: snapshot.values,
                relationships: snapshot.relationships)
        }
        for identifier in request.deleted { rows.removeValue(forKey: identifier) }
        return DataStoreSaveResult(
            identifierRemappings: [:],
            updatedIdentifiers: Set(request.updated.map(\.persistentIdentifier)),
            deletedIdentifiers: Set(request.deleted))
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

    func storedSnapshots() -> [DataStoreSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return Array(rows.values)
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
    func testDataStoreHierarchyFetchIdentityAndPendingPagination() throws {
        let store = DictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store-hierarchy", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(
            for: CustomHierarchyBase.self, CustomHierarchyChild.self, CustomHierarchyGrandchild.self,
            configurations: configuration)
        let context = container.mainContext
        let base = CustomHierarchyBase(name: "base")
        let child = CustomHierarchyChild(name: "child", score: 2)
        let grandchild = CustomHierarchyGrandchild(name: "grandchild", score: 3, rank: 9)
        context.insert(base)
        context.insert(child)
        context.insert(grandchild)
        try context.save()

        let reader = container.makeContext()
        let baseRows = try reader.fetch(FetchDescriptor<CustomHierarchyBase>())
        XCTAssertEqual(baseRows.map(\.name), ["base", "child", "grandchild"])
        XCTAssertTrue(baseRows[1] is CustomHierarchyChild)
        XCTAssertTrue(baseRows[2] is CustomHierarchyGrandchild)
        let childRows = try reader.fetch(FetchDescriptor<CustomHierarchyChild>())
        XCTAssertEqual(childRows.map(\.name), ["child", "grandchild"])
        XCTAssertTrue(baseRows[1] === childRows[0])
        XCTAssertTrue(baseRows[2] === childRows[1])
        XCTAssertTrue(
            try reader.model(for: try XCTUnwrap(childRows[1].persistentModelID)) as CustomHierarchyBase?
                === childRows[1])
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<CustomHierarchyChild>()), 2)
        XCTAssertEqual(
            try reader.fetchIdentifiers(FetchDescriptor<CustomHierarchyChild>()).map(\.entityName),
            ["CustomHierarchyChild", "CustomHierarchyGrandchild"])
        let sortedGrandchildren = try reader.fetch(
            FetchDescriptor<CustomHierarchyChild>(sortBy: [SortDescriptor(\CustomHierarchyChild.name)]))
        XCTAssertEqual(sortedGrandchildren.map(\.name), ["child", "grandchild"])
        XCTAssertEqual(
            try reader.fetch(
                FetchDescriptor<CustomHierarchyChild>(fetchLimit: 1, fetchOffset: 1, includePendingChanges: false)
            )
            .map(\.name),
            ["grandchild"])

        let fetchedGrandchild = try XCTUnwrap(childRows[1] as? CustomHierarchyGrandchild)
        fetchedGrandchild.rank = 12
        try reader.save()
        let refreshedGrandchild = try XCTUnwrap(
            container.makeContext().fetch(FetchDescriptor<CustomHierarchyGrandchild>()).first)
        XCTAssertEqual(refreshedGrandchild.rank, 12)

        let pending = CustomHierarchyGrandchild(name: "pending", score: 4, rank: 10)
        reader.insert(pending)
        let page = try reader.fetch(
            FetchDescriptor<CustomHierarchyChild>(fetchLimit: 1, fetchOffset: 2, includePendingChanges: true))
        XCTAssertEqual(page.count, 1)
        XCTAssertTrue(page[0] === pending)
        XCTAssertEqual(
            try reader.fetchCount(
                FetchDescriptor<CustomHierarchyChild>(fetchLimit: 1, fetchOffset: 2, includePendingChanges: true)),
            1)
    }

    @MainActor
    func testFlatDataStoreRejectsHierarchySchemaWithoutCapability() throws {
        let configuration = ModelConfiguration(
            "custom-flat-only",
            dataStoreConfiguration: ExistingDataStoreConfiguration(store: UnsupportedHierarchyDataStore()))
        XCTAssertThrowsError(
            try ModelContainer(
                for: CustomHierarchyBase.self, CustomHierarchyChild.self, configurations: configuration)
        ) { error in
            guard case SwiftDataError.unsupportedStore = error else {
                return XCTFail("Expected unsupportedStore, received \(error)")
            }
        }
    }

    @MainActor
    func testFlatDataStoreRemainsCompatibleWithoutInheritanceCapability() throws {
        let configuration = ModelConfiguration(
            "custom-flat-compatible",
            dataStoreConfiguration: ExistingDataStoreConfiguration(store: UnsupportedHierarchyDataStore()))
        let container = try ModelContainer(for: CustomDataStoreFixture.self, configurations: configuration)
        XCTAssertEqual(container.schema.entities.map(\.name), ["CustomDataStoreFixture"])
    }

    @MainActor
    func testDataStoreRejectsSnapshotWhoseIdentifierDisagreesWithConcreteEntity() throws {
        let configuration = ModelConfiguration(
            "custom-hierarchy-mismatched",
            dataStoreConfiguration: ExistingDataStoreConfiguration(store: MismatchedHierarchySnapshotDataStore()))
        let container = try ModelContainer(
            for: CustomHierarchyBase.self, CustomHierarchyChild.self, CustomHierarchyGrandchild.self,
            configurations: configuration)

        XCTAssertThrowsError(try container.mainContext.fetch(FetchDescriptor<CustomHierarchyBase>())) { error in
            guard case SwiftDataError.unsupportedStore = error else {
                return XCTFail("Expected unsupportedStore, received \(error)")
            }
        }
    }

    @MainActor
    func testDataStoreRejectsSnapshotOutsideRequestedHierarchySubtree() throws {
        let configuration = ModelConfiguration(
            "custom-hierarchy-outside",
            dataStoreConfiguration: ExistingDataStoreConfiguration(store: OutsideHierarchySnapshotDataStore()))
        let container = try ModelContainer(
            for: CustomHierarchyBase.self, CustomHierarchyChild.self, CustomHierarchyGrandchild.self,
            configurations: configuration)

        XCTAssertThrowsError(try container.mainContext.fetch(FetchDescriptor<CustomHierarchyBase>())) { error in
            guard case SwiftDataError.unsupportedStore = error else {
                return XCTFail("Expected unsupportedStore, received \(error)")
            }
        }
    }

    @MainActor
    func testDataStoreRejectsDuplicateSnapshotIdentifiers() throws {
        let configuration = ModelConfiguration(
            "custom-hierarchy-duplicate",
            dataStoreConfiguration: ExistingDataStoreConfiguration(store: DuplicateHierarchySnapshotDataStore()))
        let container = try ModelContainer(
            for: CustomHierarchyBase.self, CustomHierarchyChild.self, CustomHierarchyGrandchild.self,
            configurations: configuration)

        XCTAssertThrowsError(try container.mainContext.fetch(FetchDescriptor<CustomHierarchyBase>())) { error in
            guard case SwiftDataError.unsupportedStore = error else {
                return XCTFail("Expected unsupportedStore, received \(error)")
            }
        }
    }

    @MainActor
    func testDataStoreRejectsRelationshipTargetOutsideDestinationSubtree() throws {
        let configuration = ModelConfiguration(
            "custom-hierarchy-invalid-relationship",
            dataStoreConfiguration: ExistingDataStoreConfiguration(store: InvalidHierarchyRelationshipDataStore()))
        let container = try ModelContainer(
            for: CustomHierarchyOwner.self,
            CustomHierarchyBase.self,
            CustomHierarchyChild.self,
            CustomHierarchyGrandchild.self,
            CustomDataStoreFixture.self,
            configurations: configuration)

        XCTAssertThrowsError(try container.mainContext.fetch(FetchDescriptor<CustomHierarchyOwner>())) { error in
            guard case SwiftDataError.unsupportedStore = error else {
                return XCTFail("Expected unsupportedStore, received \(error)")
            }
        }
    }

    @MainActor
    func testDataStoreHierarchyRelationshipRoundTripsConcreteDestination() throws {
        let store = DictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store-hierarchy-relationship", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(
            for: CustomHierarchyOwner.self,
            CustomHierarchyBase.self,
            CustomHierarchyChild.self,
            CustomHierarchyGrandchild.self,
            configurations: configuration)
        let context = container.mainContext
        let target = CustomHierarchyGrandchild(name: "target", score: 4, rank: 11)
        context.insert(target)
        context.insert(CustomHierarchyOwner(label: "owner", target: target))
        try context.save()

        let reader = container.makeContext()
        let owner = try XCTUnwrap(reader.fetch(FetchDescriptor<CustomHierarchyOwner>()).first)
        XCTAssertTrue(owner.target is CustomHierarchyGrandchild)
        XCTAssertEqual((owner.target as? CustomHierarchyGrandchild)?.rank, 11)
        XCTAssertTrue(
            try reader.model(for: try XCTUnwrap(owner.target?.persistentModelID)) as CustomHierarchyBase?
                === owner.target)
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
    func testDataStoreCancelAndReplacePendingSubtypeClearsRetryIdentity() throws {
        let store = FailsOnceDataStore()
        let configuration = ModelConfiguration(
            "custom-store-cancel-replace", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(
            for: CustomHierarchyBase.self, CustomHierarchyChild.self, CustomHierarchyGrandchild.self,
            configurations: configuration)
        let context = container.mainContext
        let discarded = CustomHierarchyChild(name: "discarded", score: 1)
        context.insert(discarded)
        context.delete(discarded)

        let replacement = CustomHierarchyGrandchild(name: "replacement", score: 2, rank: 4)
        context.insert(replacement)
        XCTAssertThrowsError(try context.save())
        try context.save()

        let fetched = try XCTUnwrap(container.makeContext().fetch(FetchDescriptor<CustomHierarchyBase>()).first)
        XCTAssertTrue(fetched is CustomHierarchyGrandchild)
        XCTAssertEqual((fetched as? CustomHierarchyGrandchild)?.rank, 4)
    }

    @MainActor
    func testDataStoreOriginalTemporaryIdentifierResolvesAfterHierarchySave() throws {
        let store = DictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store-temp-lookup", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(
            for: CustomHierarchyBase.self, CustomHierarchyChild.self, CustomHierarchyGrandchild.self,
            configurations: configuration)
        let context = container.mainContext
        let model = CustomHierarchyGrandchild(name: "temporary", score: 5, rank: 7)
        let temporaryIdentifier = model.persistentModelID
        context.insert(model)
        try context.save()

        XCTAssertTrue(try context.model(for: temporaryIdentifier) as CustomHierarchyGrandchild? === model)
    }

    @MainActor
    func testFailedHierarchyDataStoreRetryPreservesSameSaveRelationships() throws {
        let store = FailsOnceDataStore()
        let configuration = ModelConfiguration(
            "custom-store-hierarchy-retry", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(
            for: CustomHierarchyOwner.self,
            CustomHierarchyBase.self,
            CustomHierarchyChild.self,
            CustomHierarchyGrandchild.self,
            configurations: configuration)
        let context = container.mainContext
        let target = CustomHierarchyGrandchild(name: "target", score: 8, rank: 13)
        let owner = CustomHierarchyOwner(label: "owner")
        context.insert(owner)
        owner.target = target
        context.insert(target)

        XCTAssertThrowsError(try context.save())
        XCTAssertTrue(context.hasChanges)
        try context.save()

        let reader = container.makeContext()
        let fetchedOwner = try XCTUnwrap(reader.fetch(FetchDescriptor<CustomHierarchyOwner>()).first)
        let fetchedTarget = try XCTUnwrap(fetchedOwner.target as? CustomHierarchyGrandchild)
        XCTAssertEqual(fetchedTarget.rank, 13)
        XCTAssertTrue(fetchedTarget.persistentModelID.entityName == "CustomHierarchyGrandchild")
    }

    @MainActor
    func testFailedHierarchyDataStoreRollbackClearsTemporaryIdentityState() throws {
        let store = FailsOnceDataStore()
        let configuration = ModelConfiguration(
            "custom-store-hierarchy-rollback", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(
            for: CustomHierarchyBase.self, CustomHierarchyChild.self, CustomHierarchyGrandchild.self,
            configurations: configuration)
        let context = container.mainContext
        let discarded = CustomHierarchyChild(name: "discarded", score: 1)
        context.insert(discarded)
        XCTAssertThrowsError(try context.save())
        context.rollback()
        XCTAssertNil(discarded.modelContext)

        let replacement = CustomHierarchyGrandchild(name: "replacement", score: 2, rank: 3)
        context.insert(replacement)
        try context.save()
        let fetched = try XCTUnwrap(container.makeContext().fetch(FetchDescriptor<CustomHierarchyBase>()).first)
        XCTAssertTrue(fetched is CustomHierarchyGrandchild)
        XCTAssertEqual((fetched as? CustomHierarchyGrandchild)?.rank, 3)
    }

    @MainActor
    func testFailedDataStoreUpdateRemapsNewHierarchyRelationshipTarget() throws {
        let store = FailsOnceDataStore(failOnSaveNumber: 2)
        let configuration = ModelConfiguration(
            "custom-store-update-new-target", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(
            for: CustomHierarchyOwner.self,
            CustomHierarchyBase.self,
            CustomHierarchyChild.self,
            CustomHierarchyGrandchild.self,
            configurations: configuration)
        let context = container.mainContext
        let owner = CustomHierarchyOwner(label: "owner")
        context.insert(owner)
        try context.save()

        let target = CustomHierarchyGrandchild(name: "new", score: 6, rank: 15)
        owner.target = target
        XCTAssertThrowsError(try context.save())
        try context.save()

        let snapshots = store.storedSnapshots()
        let ownerSnapshot = try XCTUnwrap(snapshots.first { $0.entityName == "CustomHierarchyOwner" })
        let targetSnapshot = try XCTUnwrap(snapshots.first { $0.entityName == "CustomHierarchyGrandchild" })
        XCTAssertEqual(ownerSnapshot.relationships["target"], [targetSnapshot.persistentIdentifier])
        XCTAssertFalse(ownerSnapshot.relationships["target", default: []].contains { $0.isTemporary })
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
