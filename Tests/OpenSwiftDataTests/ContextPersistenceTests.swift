import XCTest
import OpenSwiftData
import OpenSwiftDataSQLite

@Model
final class PersistenceTestModel {
    var title: String
    var count: Int = 0
    init(title: String) { self.title = title }
}

@Model
final class ReverseOrderPersistenceFixture {
    var zebra: String
    var alpha: Int
    var middle: String
    var optionalValue: String?

    init(zebra: String, alpha: Int, middle: String, optionalValue: String?) {
        self.zebra = zebra
        self.alpha = alpha
        self.middle = middle
        self.optionalValue = optionalValue
    }
}

struct CodablePayload: Codable, Equatable {
    let label: String
    let count: Int
}

@Model
final class ExplicitCodableAttributeFixture {
    @Attribute(.transformable(by: "Codec")) var payload: CodablePayload

    init(payload: CodablePayload) { self.payload = payload }
}

@Model
final class FailedWritePersistenceFixture {
    @Attribute(.unique) var key: String
    init(key: String) { self.key = key }
}

final class ContextPersistenceTests: XCTestCase {
    @MainActor
    func testExplicitCodableAttributeSQLiteRoundTrip() throws {
        let container = try ModelContainer(
            for: ExplicitCodableAttributeFixture.self, configurations: .sqliteMemory("codable-attribute"))
        let payload = CodablePayload(label: "round-trip", count: 37)
        let model = ExplicitCodableAttributeFixture(payload: payload)
        container.mainContext.insert(model)
        try container.mainContext.save()

        let reader = container.makeContext()
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<ExplicitCodableAttributeFixture>()).first)
        XCTAssertEqual(fetched.payload, payload)
    }

    @MainActor
    func testInsertedModelSavesFetchesAndReusesIdentity() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("context-test"))
        let context = container.mainContext
        let model = PersistenceTestModel(title: "persisted")
        let temporaryID = model.persistentModelID
        context.insert(model)
        try context.save()

        XCTAssertFalse(model.persistentModelID.isTemporary)
        XCTAssertNotEqual(model.persistentModelID, temporaryID)
        let fetched = try context.fetch(FetchDescriptor<PersistenceTestModel>())
        XCTAssertTrue(fetched.first === model)
        XCTAssertTrue(try context.model(for: model.persistentModelID) as PersistenceTestModel? === model)
    }

    @MainActor
    func testFreshContextFetchDecodesCanonicalAttributeOrderAndOptionalValues() throws {
        let container = try ModelContainer(
            for: ReverseOrderPersistenceFixture.self, configurations: .sqliteMemory("ordered-fetch"))
        let writer = container.mainContext
        let model = ReverseOrderPersistenceFixture(
            zebra: "z-value", alpha: 42, middle: "middle-value", optionalValue: "optional-value")
        writer.insert(model)
        try writer.save()
        XCTAssertEqual(model.optionalValue, "optional-value")

        let reader = container.makeContext()
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<ReverseOrderPersistenceFixture>()).first)
        XCTAssertEqual(
            ReverseOrderPersistenceFixture.persistenceAdapters().map(\.name).sorted(),
            ["alpha", "middle", "optionalValue", "zebra"])
        XCTAssertEqual(fetched.zebra, "z-value")
        XCTAssertEqual(fetched.alpha, 42)
        XCTAssertEqual(fetched.middle, "middle-value")
        XCTAssertEqual(fetched.optionalValue, "optional-value")

        let nilModel = ReverseOrderPersistenceFixture(
            zebra: "nil-z", alpha: 7, middle: "nil-middle", optionalValue: nil)
        writer.insert(nilModel)
        try writer.save()

        let nilReader = container.makeContext()
        let fetchedNil = try XCTUnwrap(
            nilReader.fetch(FetchDescriptor<ReverseOrderPersistenceFixture>()).first {
                $0.alpha == 7
            })
        XCTAssertNil(fetchedNil.optionalValue)
    }

    @MainActor
    func testFreshContextUpdateAndRollbackRestoreStoreValue() throws {
        let container = try ModelContainer(for: PersistenceTestModel.self, configurations: .sqliteMemory("update-test"))
        let first = container.mainContext
        let model = PersistenceTestModel(title: "before")
        first.insert(model)
        try first.save()

        let second = container.makeContext()
        let fetched = try XCTUnwrap(second.fetch(FetchDescriptor<PersistenceTestModel>()).first)
        fetched.title = "after"
        try second.save()
        fetched.title = "discarded"
        second.rollback()
        XCTAssertEqual(fetched.title, "after")
        XCTAssertFalse(second.hasChanges)
    }

    @MainActor
    func testRollbackKeepsSavedBaselineAcrossMultipleMutations() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("rollback-saved-baseline"))
        let context = container.mainContext
        let model = PersistenceTestModel(title: "A")
        context.insert(model)
        try context.save()

        model.title = "B"
        context.rollback()
        XCTAssertEqual(model.title, "A")

        model.title = "C"
        context.rollback()
        XCTAssertEqual(model.title, "A")
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testUpdateOfExternallyDeletedRowFailsAndRetainsPendingState() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("missing-update-row"))
        let model = PersistenceTestModel(title: "initial")
        container.mainContext.insert(model)
        try container.mainContext.save()
        let identifier = model.persistentModelID
        let wasChanged = model.hasChanges

        try container.store?.write { connection in
            guard let pk = identifier.primaryKey else { throw SwiftDataError.unsupportedStore("Missing key") }
            try connection.execute(
                "DELETE FROM ZPERSISTENCETESTMODEL WHERE Z_PK = ?", arguments: [.int(pk)])
        }
        model.title = "pending update"

        XCTAssertThrowsError(try container.mainContext.save())
        XCTAssertEqual(model.title, "pending update")
        XCTAssertTrue(container.mainContext.hasChanges)
        XCTAssertTrue(model.hasChanges)
        XCTAssertEqual(model.persistentModelID, identifier)
        XCTAssertFalse(model.persistentModelID.isTemporary)
        XCTAssertFalse(wasChanged)
    }

    @MainActor
    func testSavedDeleteRemovesIdentityMapEntry() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("delete-identity"))
        let context = container.mainContext
        let model = PersistenceTestModel(title: "deleted")
        context.insert(model)
        try context.save()
        let identifier = model.persistentModelID

        context.delete(model)
        try context.save()

        XCTAssertNil(try context.model(for: identifier) as PersistenceTestModel?)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PersistenceTestModel>()).isEmpty)
    }

    @MainActor
    func testModelLookupRejectsForeignStoreAndMismatchedEntity() throws {
        let first = try ModelContainer(for: PersistenceTestModel.self, configurations: .sqliteMemory("lookup-one"))
        let second = try ModelContainer(for: PersistenceTestModel.self, configurations: .sqliteMemory("lookup-two"))
        let model = PersistenceTestModel(title: "saved")
        first.mainContext.insert(model)
        try first.mainContext.save()

        XCTAssertThrowsError(try second.mainContext.model(for: model.persistentModelID) as PersistenceTestModel?)
        XCTAssertThrowsError(
            try first.mainContext.model(for: model.persistentModelID) as ReverseOrderPersistenceFixture?)
    }

    @MainActor
    func testRollbackRestoresDetachedIdentityAndClearsManagedMetadata() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("detach-rollback"))
        let context = container.mainContext
        let model = PersistenceTestModel(title: "pending")
        let detachedID = model.persistentModelID
        context.insert(model)
        model.title = "changed"

        context.rollback()

        XCTAssertNil(model.modelContext)
        XCTAssertEqual(model.persistentModelID, detachedID)
        XCTAssertEqual(model.persistentModelID.storeIdentifier, "OSD.Detached")
        XCTAssertTrue(model.persistentModelID.isTemporary)
        XCTAssertEqual(model.title, "pending")
        XCTAssertFalse(model.hasChanges)
    }

    @MainActor
    func testFailedAtomicWriteRollsBackEarlierInsertAndRetainsPendingChanges() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, FailedWritePersistenceFixture.self,
            configurations: .sqliteMemory("atomic-failure"))
        let context = container.mainContext
        let duplicate = FailedWritePersistenceFixture(key: "duplicate")
        context.insert(duplicate)
        try context.save()

        let valid = PersistenceTestModel(title: "partial")
        let conflicting = FailedWritePersistenceFixture(key: "duplicate")
        context.insert(valid)
        context.insert(conflicting)
        let identifier = valid.persistentModelID

        XCTAssertThrowsError(try context.save())
        XCTAssertEqual(valid.persistentModelID, identifier)
        XCTAssertTrue(valid.persistentModelID.isTemporary)
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(valid.hasChanges)

        let reader = container.makeContext()
        XCTAssertTrue(try reader.fetch(FetchDescriptor<PersistenceTestModel>()).isEmpty)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<FailedWritePersistenceFixture>()).count, 1)
    }
}
