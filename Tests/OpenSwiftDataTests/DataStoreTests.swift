import Foundation
import XCTest
@testable import OpenSwiftData

@Model
final class CustomDataStoreFixture {
    var value: Int
    init(value: Int) { self.value = value }
}

@Model
final class CustomDataStoreUInt64Fixture {
    var value: UInt64?

    init(value: UInt64?) {
        self.value = value
    }
}

@Model
final class CustomDataStorePartialFixture {
    var name: String
    var value: Int
    init(name: String, value: Int) {
        self.name = name
        self.value = value
    }
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
final class CustomDataStoreCollectionOwner {
    var name: String
    @Relationship(inverse: nil) var destinations: [CustomDataStoreCollectionDestination]

    init(name: String, destinations: [CustomDataStoreCollectionDestination] = []) {
        self.name = name
        self.destinations = destinations
    }
}

@Model
final class CustomDataStoreCollectionDestination {
    var title: String
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

@Model
final class CustomHierarchyChildOwner {
    var label: String
    @Relationship(inverse: nil) var target: CustomHierarchyChild?

    init(label: String, target: CustomHierarchyChild? = nil) {
        self.label = label
        self.target = target
    }
}

@Model
class CustomHierarchyRelationshipOwnerBase {
    var label: String
    @Relationship(inverse: nil) var target: CustomHierarchyBase?

    init(label: String, target: CustomHierarchyBase? = nil) {
        self.label = label
        self.target = target
    }
}

@Model
final class CustomHierarchyRelationshipOwnerChild: CustomHierarchyRelationshipOwnerBase {
    var code: Int

    init(label: String, code: Int, target: CustomHierarchyBase? = nil) {
        self.code = code
        super.init(label: label, target: target)
    }
}

private final class DictionaryDataStore: DataStore, @unchecked Sendable {
    let identifier = "custom.dictionary"
    let supportsInheritance = true
    private let lock = NSRecursiveLock()
    private var nextPrimaryKey: Int64 = 1
    private var snapshots: [PersistentIdentifier: DataStoreSnapshot] = [:]
    private var reservations: [PersistentIdentifier: PersistentIdentifier] = [:]
    private(set) var lastFetchedValueKeys: Set<String>?
    private var snapshotReadIdentifiers: [PersistentIdentifier] = []

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
        guard case let keyPaths = request.descriptor.propertiesToFetch, !keyPaths.isEmpty else {
            lastFetchedValueKeys = rows.first.map { Set($0.values.keys) }
            return DataStoreFetchResult(snapshots: rows)
        }
        let requestedProperties = Set(keyPaths.compactMap(Model.propertyName(forKeyPath:)))
        let requested = Set(
            request.entity.attributes.filter { requestedProperties.contains($0.name) }.flatMap { attribute in
                attribute.options.contains(.flattened) ? attribute.components.map(\.columnName) : [attribute.name]
            })
        let partialRows = rows.map { snapshot in
            DataStoreSnapshot(
                persistentIdentifier: snapshot.persistentIdentifier,
                entityName: snapshot.entityName,
                values: snapshot.values.filter { requested.contains($0.key) },
                relationships: snapshot.relationships)
        }
        lastFetchedValueKeys = partialRows.first.map { Set($0.values.keys) }
        return DataStoreFetchResult(snapshots: partialRows)
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
        snapshotReadIdentifiers.append(identifier)
        return snapshots[identifier]
    }

    var fetchedSnapshotIdentifiers: [PersistentIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        return snapshotReadIdentifiers
    }

    func clearFetchedSnapshotIdentifiers() {
        lock.lock()
        snapshotReadIdentifiers.removeAll()
        lock.unlock()
    }

    func storedSnapshots() -> [DataStoreSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return Array(snapshots.values)
    }
}

private struct ReconciledRuntimeSchemaStore: RuntimeSchemaProvidingStore {
    let runtimeSchema: SchemaDescriptor

    func read<T>(_ body: (RuntimeConnection) throws -> T) throws -> T {
        throw SwiftDataError.unsupportedStore("test-only schema provider")
    }

    func write<T>(_ body: (RuntimeConnection) throws -> T) throws -> T {
        throw SwiftDataError.unsupportedStore("test-only schema provider")
    }

    func close() throws {}
}

private struct PlainRuntimeSchemaStore: RuntimeStore {
    func read<T>(_ body: (RuntimeConnection) throws -> T) throws -> T {
        throw SwiftDataError.unsupportedStore("test-only runtime store")
    }

    func write<T>(_ body: (RuntimeConnection) throws -> T) throws -> T {
        throw SwiftDataError.unsupportedStore("test-only runtime store")
    }

    func close() throws {}
}

private final class ClosingRuntimeSchemaStore: RuntimeSchemaProvidingStore, @unchecked Sendable {
    let runtimeSchema: SchemaDescriptor
    private let lock = NSLock()
    private var wasClosed = false

    init(runtimeSchema: SchemaDescriptor) {
        self.runtimeSchema = runtimeSchema
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasClosed
    }

    func read<T>(_ body: (RuntimeConnection) throws -> T) throws -> T {
        throw SwiftDataError.unsupportedStore("test-only schema provider")
    }

    func write<T>(_ body: (RuntimeConnection) throws -> T) throws -> T {
        throw SwiftDataError.unsupportedStore("test-only schema provider")
    }

    func close() throws {
        lock.lock()
        wasClosed = true
        lock.unlock()
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

private struct HierarchyDestinationRelationshipDataStore: DataStore {
    let identifier = "custom.hierarchy.destination-relationship"
    let supportsInheritance = true
    let targetEntityName: String

    private var ownerIdentifier: PersistentIdentifier {
        PersistentIdentifier(storeIdentifier: identifier, entityName: "CustomHierarchyChildOwner", primaryKey: 1)
    }

    private var targetIdentifier: PersistentIdentifier {
        PersistentIdentifier(storeIdentifier: identifier, entityName: targetEntityName, primaryKey: 2)
    }

    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        guard request.entity.name == "CustomHierarchyChildOwner" else { return DataStoreFetchResult(snapshots: []) }
        return DataStoreFetchResult(
            snapshots: [
                DataStoreSnapshot(
                    persistentIdentifier: ownerIdentifier,
                    entityName: "CustomHierarchyChildOwner",
                    values: ["label": .text("owner")],
                    relationships: ["target": [targetIdentifier]])
            ])
    }

    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult { DataStoreSaveResult() }

    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? {
        guard identifier == targetIdentifier else { return nil }
        let values: [String: StoredValue]
        switch targetEntityName {
        case "CustomHierarchyChild":
            values = ["name": .text("child"), "score": .int(4)]
        case "CustomHierarchyGrandchild":
            values = ["name": .text("grandchild"), "score": .int(5), "rank": .int(11)]
        default:
            values = ["name": .text("base")]
        }
        return DataStoreSnapshot(
            persistentIdentifier: targetIdentifier, entityName: targetEntityName, values: values)
    }
}

private struct MultipleTargetsForToOneDataStore: DataStore {
    let identifier = "custom.store.multiple-to-one-targets"
    private let ownerIdentifier = PersistentIdentifier(
        storeIdentifier: "custom.store.multiple-to-one-targets", entityName: "CustomDataStoreOwner", primaryKey: 1)
    private let firstTargetIdentifier = PersistentIdentifier(
        storeIdentifier: "custom.store.multiple-to-one-targets", entityName: "CustomDataStoreDestination", primaryKey: 2
    )
    private let secondTargetIdentifier = PersistentIdentifier(
        storeIdentifier: "custom.store.multiple-to-one-targets", entityName: "CustomDataStoreDestination", primaryKey: 3
    )

    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        guard request.entity.name == "CustomDataStoreOwner" else { return DataStoreFetchResult(snapshots: []) }
        return DataStoreFetchResult(
            snapshots: [
                DataStoreSnapshot(
                    persistentIdentifier: ownerIdentifier,
                    entityName: "CustomDataStoreOwner",
                    values: ["name": .text("owner")],
                    relationships: ["destination": [firstTargetIdentifier, secondTargetIdentifier]])
            ])
    }

    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult { DataStoreSaveResult() }

    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? {
        guard identifier == firstTargetIdentifier || identifier == secondTargetIdentifier else { return nil }
        return DataStoreSnapshot(
            persistentIdentifier: identifier,
            entityName: "CustomDataStoreDestination",
            values: ["title": .text("target")],
            relationships: ["owner": []])
    }
}

private struct EmptyToOneRelationshipDataStore: DataStore {
    let identifier = "custom.store.empty-to-one-target"
    private let ownerIdentifier = PersistentIdentifier(
        storeIdentifier: "custom.store.empty-to-one-target", entityName: "CustomDataStoreOwner", primaryKey: 1)

    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        guard request.entity.name == "CustomDataStoreOwner" else { return DataStoreFetchResult(snapshots: []) }
        return DataStoreFetchResult(
            snapshots: [
                DataStoreSnapshot(
                    persistentIdentifier: ownerIdentifier,
                    entityName: "CustomDataStoreOwner",
                    values: ["name": .text("owner")],
                    relationships: ["destination": []])
            ])
    }

    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult { DataStoreSaveResult() }

    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? { nil }
}

private struct MultipleTargetsForToManyDataStore: DataStore {
    let identifier = "custom.store.multiple-to-many-targets"
    private let ownerIdentifier = PersistentIdentifier(
        storeIdentifier: "custom.store.multiple-to-many-targets", entityName: "CustomDataStoreCollectionOwner",
        primaryKey: 1)
    private let firstTargetIdentifier = PersistentIdentifier(
        storeIdentifier: "custom.store.multiple-to-many-targets", entityName: "CustomDataStoreCollectionDestination",
        primaryKey: 2)
    private let secondTargetIdentifier = PersistentIdentifier(
        storeIdentifier: "custom.store.multiple-to-many-targets", entityName: "CustomDataStoreCollectionDestination",
        primaryKey: 3)

    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult {
        guard request.entity.name == "CustomDataStoreCollectionOwner" else {
            return DataStoreFetchResult(snapshots: [])
        }
        return DataStoreFetchResult(
            snapshots: [
                DataStoreSnapshot(
                    persistentIdentifier: ownerIdentifier,
                    entityName: "CustomDataStoreCollectionOwner",
                    values: ["name": .text("owner")],
                    relationships: [
                        "destinations": [
                            firstTargetIdentifier, firstTargetIdentifier, secondTargetIdentifier,
                        ]
                    ])
            ])
    }

    func save(_ request: DataStoreSaveRequest) throws -> DataStoreSaveResult { DataStoreSaveResult() }

    func snapshot(for identifier: PersistentIdentifier) throws -> DataStoreSnapshot? {
        guard identifier == firstTargetIdentifier || identifier == secondTargetIdentifier else { return nil }
        return DataStoreSnapshot(
            persistentIdentifier: identifier,
            entityName: "CustomDataStoreCollectionDestination",
            values: ["title": .text("target")])
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
    func testConfiguredDataStoreSupportsSnapshotSaveFetchAndDelete() async throws {
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
    func testDataStoreHierarchyFetchIdentityAndPendingPagination() async throws {
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
    func testDataStoreHierarchyPartialFetchFaultsSubtypeProperties() async throws {
        let store = DictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store-hierarchy-partial",
            dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(
            for: CustomHierarchyBase.self, CustomHierarchyChild.self, CustomHierarchyGrandchild.self,
            configurations: configuration)
        let writer = container.mainContext
        writer.insert(CustomHierarchyChild(name: "child", score: 2))
        writer.insert(CustomHierarchyGrandchild(name: "grandchild", score: 3, rank: 9))
        try writer.save()

        let reader = container.makeContext()
        let descriptor = FetchDescriptor<CustomHierarchyChild>(propertiesToFetch: [\.name])
        let projected = try reader.fetch(descriptor)
        XCTAssertEqual(projected.map(\.name), ["child", "grandchild"])
        XCTAssertTrue(projected[1] is CustomHierarchyGrandchild)
        XCTAssertEqual(store.lastFetchedValueKeys, ["name"])

        let readsBeforeFaults = store.fetchedSnapshotIdentifiers.count
        XCTAssertEqual(projected[0].score, 2)
        XCTAssertEqual(projected[1].score, 3)
        let faultedIdentifiers = Array(store.fetchedSnapshotIdentifiers.dropFirst(readsBeforeFaults))
        XCTAssertEqual(faultedIdentifiers, projected.map(\.persistentModelID))

        let grandchild = try XCTUnwrap(projected[1] as? CustomHierarchyGrandchild)
        XCTAssertEqual(grandchild.rank, 9)
        XCTAssertEqual(store.fetchedSnapshotIdentifiers.count, readsBeforeFaults + 2)
    }

    @MainActor
    func testDataStoreEnumerationHonorsCommittedOnlyDescriptorWithPendingDeletion() async throws {
        let store = DictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store-enumeration-delete",
            dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(
            for: CustomHierarchyBase.self, CustomHierarchyChild.self, CustomHierarchyGrandchild.self,
            configurations: configuration)
        let writer = container.mainContext
        writer.insert(CustomHierarchyChild(name: "child", score: 2))
        writer.insert(CustomHierarchyGrandchild(name: "grandchild", score: 3, rank: 9))
        try writer.save()

        let reader = container.makeContext()
        let child = try XCTUnwrap(
            reader.fetch(FetchDescriptor<CustomHierarchyChild>()).first { $0.name == "child" })
        reader.delete(child)
        let committedDescriptor = FetchDescriptor<CustomHierarchyBase>(includePendingChanges: false)
        let committedFetch = try reader.fetch(committedDescriptor)
        var committedEnumeration: [CustomHierarchyBase] = []
        try reader.enumerate(committedDescriptor, batchSize: 1) { committedEnumeration.append($0) }

        XCTAssertEqual(committedEnumeration.map(\.persistentModelID), committedFetch.map(\.persistentModelID))
        XCTAssertTrue(committedEnumeration.first === child)
        XCTAssertTrue(child.isDeleted)
        XCTAssertEqual(committedEnumeration.map(\.name), ["child", "grandchild"])

        let pendingDescriptor = FetchDescriptor<CustomHierarchyBase>()
        let pendingFetch = try reader.fetch(pendingDescriptor)
        var pendingEnumeration: [CustomHierarchyBase] = []
        try reader.enumerate(pendingDescriptor, batchSize: 1) { pendingEnumeration.append($0) }
        XCTAssertEqual(pendingEnumeration.map(\.persistentModelID), pendingFetch.map(\.persistentModelID))
        XCTAssertEqual(pendingEnumeration.map(\.name), ["grandchild"])

        try reader.save()
        XCTAssertEqual(try reader.fetch(committedDescriptor).map(\.name), ["grandchild"])
    }

    @MainActor
    func testFlatDataStoreRejectsHierarchySchemaWithoutCapability() async throws {
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
    func testContainerAdoptsRuntimeStoreReconciledSchema() async throws {
        let requestedSchema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "CustomHierarchyBase"),
            SchemaDescriptor.Entity(name: "CustomHierarchyChild", superentityName: "CustomHierarchyBase"),
        ])
        let runtimeSchema = try SchemaDescriptor(
            requestedSchema.entities,
            entityIDs: ["CustomHierarchyBase": 10, "CustomHierarchyChild": 20])
        let provider = ReconciledRuntimeSchemaStore(runtimeSchema: runtimeSchema)
        let configuration = ModelConfiguration(
            "runtime-schema-provider", storeFactory: { _, _ in provider })
        let container = try ModelContainer(
            for: [CustomHierarchyBase.self, CustomHierarchyChild.self],
            schema: requestedSchema,
            configurations: [configuration])

        XCTAssertEqual(container.schemaDescriptor.entityIDsByName, runtimeSchema.entityIDsByName)
        XCTAssertEqual(container.schemaDescriptor.entity(forID: 20)?.name, "CustomHierarchyChild")
        XCTAssertEqual(
            ObjectIdentifier(try XCTUnwrap(container.modelRegistration(forEntityID: 20)).type),
            ObjectIdentifier(CustomHierarchyChild.self))
    }

    @MainActor
    func testContainerKeepsRequestedSchemaForRuntimeStoresWithoutSchemaCapability() async throws {
        let requestedSchema = SchemaDescriptor([SchemaDescriptor.Entity(name: "CustomDataStoreFixture")])
        let configuration = ModelConfiguration(
            "runtime-schema-legacy-store", storeFactory: { _, _ in PlainRuntimeSchemaStore() })
        let container = try ModelContainer(
            for: [CustomDataStoreFixture.self], schema: requestedSchema, configurations: [configuration])

        XCTAssertEqual(container.schema.entityIDsByName, requestedSchema.entityIDsByName)
    }

    @MainActor
    func testContainerRejectsIncompatibleRuntimeSchemaAndClosesStore() async throws {
        let requestedSchema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "CustomDataStoreFixture", attributes: [SchemaDescriptor.Attribute(name: "value", type: "Int")])
        ])
        let incompatibleSchema = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "CustomDataStoreFixture",
                attributes: [
                    SchemaDescriptor.Attribute(name: "value", type: "Int"),
                    SchemaDescriptor.Attribute(name: "extra", type: "Int"),
                ])
        ])
        let store = ClosingRuntimeSchemaStore(runtimeSchema: incompatibleSchema)
        let configuration = ModelConfiguration(
            "runtime-schema-incompatible", storeFactory: { _, _ in store })

        XCTAssertThrowsError(
            try ModelContainer(
                for: [CustomDataStoreFixture.self], schema: requestedSchema, configurations: [configuration]))
        XCTAssertTrue(store.isClosed)
    }

    @MainActor
    func testFlatDataStoreRemainsCompatibleWithoutInheritanceCapability() async throws {
        let configuration = ModelConfiguration(
            "custom-flat-compatible",
            dataStoreConfiguration: ExistingDataStoreConfiguration(store: UnsupportedHierarchyDataStore()))
        let container = try ModelContainer(for: CustomDataStoreFixture.self, configurations: configuration)
        XCTAssertEqual(container.schema.entities.map(\.name), ["CustomDataStoreFixture"])
    }

    @MainActor
    func testDataStoreRejectsSnapshotWhoseIdentifierDisagreesWithConcreteEntity() async throws {
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
    func testDataStoreRejectsSnapshotOutsideRequestedHierarchySubtree() async throws {
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
    func testDataStoreRejectsDuplicateSnapshotIdentifiers() async throws {
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
    func testDataStoreRejectsRelationshipTargetOutsideDestinationSubtree() async throws {
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
    func testDataStoreChildDestinationAcceptsGrandchildAndRejectsBaseTarget() async throws {
        let acceptedConfiguration = ModelConfiguration(
            "custom-hierarchy-child-destination-accepted",
            dataStoreConfiguration: ExistingDataStoreConfiguration(
                store: HierarchyDestinationRelationshipDataStore(targetEntityName: "CustomHierarchyGrandchild")))
        let acceptedContainer = try ModelContainer(
            for: CustomHierarchyChildOwner.self, CustomHierarchyBase.self, CustomHierarchyChild.self,
            CustomHierarchyGrandchild.self, configurations: acceptedConfiguration)
        let acceptedOwner = try XCTUnwrap(
            acceptedContainer.mainContext.fetch(FetchDescriptor<CustomHierarchyChildOwner>()).first)
        XCTAssertEqual(acceptedOwner.label, "owner")
        XCTAssertTrue(acceptedOwner.target is CustomHierarchyGrandchild)
        XCTAssertEqual((acceptedOwner.target as? CustomHierarchyGrandchild)?.rank, 11)

        let rejectedConfiguration = ModelConfiguration(
            "custom-hierarchy-child-destination-rejected",
            dataStoreConfiguration: ExistingDataStoreConfiguration(
                store: HierarchyDestinationRelationshipDataStore(targetEntityName: "CustomHierarchyBase")))
        let rejectedContainer = try ModelContainer(
            for: CustomHierarchyChildOwner.self, CustomHierarchyBase.self, CustomHierarchyChild.self,
            CustomHierarchyGrandchild.self, configurations: rejectedConfiguration)
        XCTAssertThrowsError(
            try rejectedContainer.mainContext.fetch(FetchDescriptor<CustomHierarchyChildOwner>())
        ) { error in
            guard case SwiftDataError.unsupportedStore = error else {
                return XCTFail("Expected unsupportedStore, received \(error)")
            }
        }
    }

    @MainActor
    func testDataStoreHierarchyRelationshipRoundTripsConcreteDestination() async throws {
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
    func testDataStoreInheritedHierarchyRelationshipRoundTrips() async throws {
        let store = DictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store-inherited-hierarchy-relationship",
            dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(
            for: CustomHierarchyBase.self, CustomHierarchyChild.self, CustomHierarchyGrandchild.self,
            CustomHierarchyRelationshipOwnerBase.self, CustomHierarchyRelationshipOwnerChild.self,
            configurations: configuration)
        let writer = container.mainContext
        let firstTarget = CustomHierarchyGrandchild(name: "first", score: 4, rank: 11)
        let secondTarget = CustomHierarchyGrandchild(name: "second", score: 5, rank: 12)
        let owner = CustomHierarchyRelationshipOwnerChild(label: "owner", code: 7, target: firstTarget)
        writer.insert(firstTarget)
        writer.insert(secondTarget)
        writer.insert(owner)
        try writer.save()

        let initialSnapshots = store.storedSnapshots()
        let initialOwnerSnapshot = try XCTUnwrap(
            initialSnapshots.first { $0.entityName == "CustomHierarchyRelationshipOwnerChild" })
        let initialTargetSnapshot = try XCTUnwrap(
            initialSnapshots.first { $0.persistentIdentifier == firstTarget.persistentModelID })
        XCTAssertEqual(initialOwnerSnapshot.persistentIdentifier.entityName, "CustomHierarchyRelationshipOwnerChild")
        XCTAssertEqual(initialTargetSnapshot.persistentIdentifier.entityName, "CustomHierarchyGrandchild")
        XCTAssertEqual(
            initialOwnerSnapshot.relationships["target"], [initialTargetSnapshot.persistentIdentifier])

        let reader = container.makeContext()
        let partialOwners = try reader.fetch(
            FetchDescriptor<CustomHierarchyRelationshipOwnerBase>(propertiesToFetch: [\.label]))
        XCTAssertEqual(store.lastFetchedValueKeys, ["label"])
        let fetchedOwner = try XCTUnwrap(partialOwners.first)
        XCTAssertTrue(fetchedOwner is CustomHierarchyRelationshipOwnerChild)
        store.clearFetchedSnapshotIdentifiers()
        XCTAssertEqual((fetchedOwner as? CustomHierarchyRelationshipOwnerChild)?.code, 7)
        XCTAssertEqual(store.fetchedSnapshotIdentifiers, [fetchedOwner.persistentModelID])
        XCTAssertTrue(fetchedOwner.target is CustomHierarchyGrandchild)
        let grandchild = try XCTUnwrap(fetchedOwner.target as? CustomHierarchyGrandchild)
        XCTAssertEqual(grandchild.score, 4)
        XCTAssertEqual(grandchild.rank, 11)

        let replacement = try XCTUnwrap(
            reader.fetch(FetchDescriptor<CustomHierarchyGrandchild>()).first { $0.name == "second" })
        fetchedOwner.target = replacement
        try reader.save()

        let updatedSnapshots = store.storedSnapshots()
        let updatedOwnerSnapshot = try XCTUnwrap(
            updatedSnapshots.first { $0.entityName == "CustomHierarchyRelationshipOwnerChild" })
        let updatedTargetSnapshot = try XCTUnwrap(
            updatedSnapshots.first { $0.persistentIdentifier == replacement.persistentModelID })
        XCTAssertEqual(
            updatedOwnerSnapshot.relationships["target"], [updatedTargetSnapshot.persistentIdentifier])

        let verifier = container.makeContext()
        let updatedOwner = try XCTUnwrap(
            verifier.fetch(FetchDescriptor<CustomHierarchyRelationshipOwnerBase>()).first)
        XCTAssertEqual(updatedOwner.target?.name, "second")
        XCTAssertTrue(updatedOwner.target is CustomHierarchyGrandchild)
    }

    @MainActor
    func testFailedDataStoreSaveRetainsPendingInsertion() async throws {
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
    func testDataStoreUInt64OverflowDoesNotCommitAndCanRetry() async throws {
        let store = DictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store-uint64-overflow", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(for: CustomDataStoreUInt64Fixture.self, configurations: configuration)
        let context = container.mainContext
        let valid = CustomDataStoreUInt64Fixture(value: UInt64(Int64.max))
        let overflowing = CustomDataStoreUInt64Fixture(value: UInt64(Int64.max) + 1)
        context.insert(valid)
        context.insert(overflowing)

        XCTAssertThrowsError(try context.save())
        XCTAssertTrue(store.storedSnapshots().isEmpty)
        XCTAssertTrue(context.insertedModels.contains(where: { $0 === valid }))
        XCTAssertTrue(context.insertedModels.contains(where: { $0 === overflowing }))
        XCTAssertTrue(valid.persistentModelID.isTemporary)
        XCTAssertTrue(overflowing.persistentModelID.isTemporary)

        overflowing.value = UInt64(Int64.max)
        try context.save()
        XCTAssertEqual(store.storedSnapshots().count, 2)
        XCTAssertFalse(valid.persistentModelID.isTemporary)
        XCTAssertFalse(overflowing.persistentModelID.isTemporary)
        XCTAssertEqual(
            Set(try container.makeContext().fetch(FetchDescriptor<CustomDataStoreUInt64Fixture>()).compactMap(\.value)),
            Set([UInt64(Int64.max)]))
    }

    @MainActor
    func testDataStorePartialFetchFaultsUnrequestedProperties() async throws {
        let dataStore = DictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store-partial", dataStoreConfiguration: ExistingDataStoreConfiguration(store: dataStore))
        let container = try ModelContainer(for: CustomDataStorePartialFixture.self, configurations: configuration)
        let context = container.mainContext
        context.insert(CustomDataStorePartialFixture(name: "partial", value: 42))
        try context.save()
        let descriptor = FetchDescriptor<CustomDataStorePartialFixture>(propertiesToFetch: [\.name])
        let fetched = try XCTUnwrap(context.fetch(descriptor).first)
        XCTAssertEqual(fetched.name, "partial")
        XCTAssertEqual(dataStore.lastFetchedValueKeys, ["name"])
        XCTAssertEqual(fetched.value, 42)
        XCTAssertEqual(dataStore.lastFetchedValueKeys, ["name"])

        let valueDescriptor = FetchDescriptor<CustomDataStorePartialFixture>(propertiesToFetch: [\.value])
        let fetchedByValue = try XCTUnwrap(context.fetch(valueDescriptor).first)
        XCTAssertTrue(fetchedByValue === fetched)
        XCTAssertEqual(dataStore.lastFetchedValueKeys, ["value"])
        XCTAssertEqual(fetchedByValue.name, "partial")
        XCTAssertEqual(fetchedByValue.value, 42)

        let malformedStore = MalformedSnapshotDataStore()
        let malformedConfiguration = ModelConfiguration(
            "custom-store-malformed", dataStoreConfiguration: ExistingDataStoreConfiguration(store: malformedStore))
        let malformedContainer = try ModelContainer(
            for: CustomDataStoreFixture.self, configurations: malformedConfiguration)
        XCTAssertThrowsError(
            try malformedContainer.mainContext.fetch(FetchDescriptor<CustomDataStoreFixture>()))
    }

    @MainActor
    func testDataStoreSnapshotsRoundTripFlattenedComponentValues() async throws {
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

        let partial = try XCTUnwrap(
            context.fetch(FetchDescriptor<FlattenedCompositeFixture>(propertiesToFetch: [\.dimensions])).first)
        XCTAssertEqual(store.lastFetchedValueKeys, ["dimensions_width", "dimensions_label"])
        XCTAssertEqual(partial.dimensions, value)
    }

    @MainActor
    func testDataStoreSnapshotsRoundTripRelationshipsByIdentifier() async throws {
        let store = DictionaryDataStore()
        let configuration = ModelConfiguration(
            "custom-store-relationships", dataStoreConfiguration: ExistingDataStoreConfiguration(store: store))
        let container = try ModelContainer(
            for: CustomDataStoreOwner.self, CustomDataStoreDestination.self, configurations: configuration)
        let context = container.mainContext
        let destination = CustomDataStoreDestination(title: "destination")
        let owner = CustomDataStoreOwner(name: "owner", destination: destination)
        let secondOwner = CustomDataStoreOwner(name: "second owner", destination: destination)
        context.insert(owner)
        context.insert(secondOwner)
        try context.save()

        let reader = container.makeContext()
        let partialOwners = try reader.fetch(
            FetchDescriptor<CustomDataStoreOwner>(propertiesToFetch: [\.name]))
        XCTAssertEqual(store.lastFetchedValueKeys, ["name"])
        let partialOwner = try XCTUnwrap(partialOwners.first(where: { $0.name == "owner" }))
        let partialSecondOwner = try XCTUnwrap(partialOwners.first(where: { $0.name == "second owner" }))
        XCTAssertEqual(partialOwner.destination?.title, "destination")
        XCTAssertTrue(partialOwner.destination === partialSecondOwner.destination)

        let fetchedOwners = try reader.fetch(FetchDescriptor<CustomDataStoreOwner>())
        let fetched = try XCTUnwrap(fetchedOwners.first(where: { $0.name == "owner" }))
        let fetchedSecondOwner = try XCTUnwrap(fetchedOwners.first(where: { $0.name == "second owner" }))
        XCTAssertFalse(fetched.destination === destination)
        XCTAssertEqual(fetched.destination?.title, "destination")
        XCTAssertTrue(fetched.destination === fetchedSecondOwner.destination)

        let replacement = CustomDataStoreDestination(title: "replacement")
        context.insert(replacement)
        owner.destination = replacement
        try context.save()
        XCTAssertEqual(
            try container.makeContext().fetch(FetchDescriptor<CustomDataStoreOwner>()).first?.destination?.title,
            "replacement")
    }

    @MainActor
    func testDataStoreRejectsMultipleTargetsForToOneRelationship() async throws {
        let configuration = ModelConfiguration(
            "custom-store-multiple-to-one-targets",
            dataStoreConfiguration: ExistingDataStoreConfiguration(store: MultipleTargetsForToOneDataStore()))
        let container = try ModelContainer(
            for: CustomDataStoreOwner.self, CustomDataStoreDestination.self, configurations: configuration)

        XCTAssertThrowsError(try container.mainContext.fetch(FetchDescriptor<CustomDataStoreOwner>())) { error in
            guard case SwiftDataError.unsupportedStore = error else {
                return XCTFail("Expected unsupportedStore, received \(error)")
            }
        }
    }

    @MainActor
    func testDataStoreAcceptsEmptyOptionalToOneRelationship() async throws {
        let configuration = ModelConfiguration(
            "custom-store-empty-to-one-target",
            dataStoreConfiguration: ExistingDataStoreConfiguration(store: EmptyToOneRelationshipDataStore()))
        let container = try ModelContainer(
            for: CustomDataStoreOwner.self, CustomDataStoreDestination.self, configurations: configuration)

        XCTAssertNil(try container.mainContext.fetch(FetchDescriptor<CustomDataStoreOwner>()).first?.destination)
    }

    @MainActor
    func testDataStoreAllowsMultipleTargetsForToManyRelationship() async throws {
        let configuration = ModelConfiguration(
            "custom-store-multiple-to-many-targets",
            dataStoreConfiguration: ExistingDataStoreConfiguration(store: MultipleTargetsForToManyDataStore()))
        let container = try ModelContainer(
            for: CustomDataStoreCollectionOwner.self,
            CustomDataStoreCollectionDestination.self,
            configurations: configuration)

        let owner = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<CustomDataStoreCollectionOwner>()).first)
        XCTAssertEqual(
            owner.destinations.map(\.persistentModelID),
            [
                PersistentIdentifier(
                    storeIdentifier: "custom.store.multiple-to-many-targets",
                    entityName: "CustomDataStoreCollectionDestination", primaryKey: 2),
                PersistentIdentifier(
                    storeIdentifier: "custom.store.multiple-to-many-targets",
                    entityName: "CustomDataStoreCollectionDestination", primaryKey: 3),
            ])
    }

    @MainActor
    func testDataStoreSnapshotsRoundTripCyclicRelationshipGraph() async throws {
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
    func testFailedDataStoreBatchCanRetryWithReservedIdentifiers() async throws {
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
    func testDataStoreCancelAndReplacePendingSubtypeClearsRetryIdentity() async throws {
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
    func testDataStoreOriginalTemporaryIdentifierResolvesAfterHierarchySave() async throws {
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
    func testFailedHierarchyDataStoreRetryPreservesSameSaveRelationships() async throws {
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
    func testFailedHierarchyDataStoreRollbackClearsTemporaryIdentityState() async throws {
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
    func testFailedDataStoreUpdateRemapsNewHierarchyRelationshipTarget() async throws {
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
    func testInvalidDataStoreSaveResultDoesNotFinalizeContextModels() async throws {
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
