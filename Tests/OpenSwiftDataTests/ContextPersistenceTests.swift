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

@Model
final class ConflictingUniqueKeysFixture {
    @Attribute(.unique) var email: String
    @Attribute(.unique) var username: String

    init(email: String, username: String) {
        self.email = email
        self.username = username
    }
}

@Model
final class UpsertRelationshipOwnerFixture {
    @Attribute(.unique) var key: String
    @Relationship(inverse: nil) var destination: UpsertRelationshipDestinationFixture?

    init(key: String) { self.key = key }
}

@Model
final class UpsertRelationshipDestinationFixture {
    var name: String

    init(name: String) { self.name = name }
}

@Model
final class PersistentRelationshipOwner {
    var title: String
    @Relationship(deleteRule: .nullify, inverse: \PersistentRelationshipChild.owner)
    var children: [PersistentRelationshipChild] = []
    @Relationship(inverse: nil) var favorite: PersistentRelationshipChild?

    init(title: String) { self.title = title }
}

@Model
final class PersistentRelationshipChild {
    var title: String
    @Relationship var owner: PersistentRelationshipOwner?

    init(title: String) { self.title = title }
}

@Model
final class PersistentTagGroup {
    var name: String
    @Relationship var tags: [PersistentTag] = []

    init(name: String) { self.name = name }
}

@Model
final class PersistentTag {
    var name: String
    @Relationship(inverse: \PersistentTagGroup.tags) var groups: [PersistentTagGroup] = []

    init(name: String) { self.name = name }
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
        XCTAssertEqual(model.persistentModelID.storeIdentifier, "context-test")
        let fetched = try context.fetch(FetchDescriptor<PersistenceTestModel>())
        XCTAssertTrue(fetched.first === model)
        XCTAssertTrue(try context.model(for: model.persistentModelID) as PersistenceTestModel? === model)
    }

    @MainActor
    func testFetchDescriptorLimitOffsetSortAndConvenienceQueries() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("fetch-descriptor"))
        let context = container.mainContext
        for title in ["c", "a", "b"] {
            context.insert(PersistenceTestModel(title: title))
        }
        try context.save()

        let descriptor = FetchDescriptor<PersistenceTestModel>(
            sortBy: [SortDescriptor(\.title)], fetchLimit: 1, fetchOffset: 1)
        let fetched = try context.fetch(descriptor)

        XCTAssertEqual(fetched.map(\.title), ["b"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), fetched.map(\.persistentModelID))
        let countDescriptor = FetchDescriptor<PersistenceTestModel>(includePendingChanges: false)
        XCTAssertEqual(try context.fetchCount(countDescriptor), 3)
        XCTAssertEqual(try context.fetchIdentifiers(countDescriptor).count, 3)
        var enumerated: [String] = []
        try context.enumerate(descriptor, batchSize: 1) { enumerated.append($0.title) }
        XCTAssertEqual(enumerated, ["b"])
    }

    @MainActor
    func testPredicateFetchFailsExplicitlyUntilStorageCompositionSupportsQueries() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("unsupported-fetch-predicate"))
        let predicate = #Predicate<PersistenceTestModel> { $0.count > 0 }
        let descriptor = FetchDescriptor<PersistenceTestModel>(predicate: predicate)

        XCTAssertThrowsError(try container.mainContext.fetch(descriptor)) { error in
            guard case SwiftDataError.unsupportedPredicate = error else {
                XCTFail("Expected unsupportedPredicate, got \(error)")
                return
            }
        }
    }

    @MainActor
    func testUniqueInsertUpsertsAndRebindsIdentityMap() throws {
        let container = try ModelContainer(
            for: FailedWritePersistenceFixture.self, configurations: .sqliteMemory("unique-upsert"))
        let context = container.mainContext
        let original = FailedWritePersistenceFixture(key: "same-key")
        context.insert(original)
        try context.save()
        let originalID = original.persistentModelID
        XCTAssertTrue(try context.model(for: originalID) as FailedWritePersistenceFixture? === original)

        let replacement = FailedWritePersistenceFixture(key: "same-key")
        context.insert(replacement)
        try context.save()

        XCTAssertEqual(replacement.persistentModelID, originalID)
        XCTAssertNil(original.modelContext)
        XCTAssertTrue(try context.model(for: originalID) as FailedWritePersistenceFixture? === replacement)
        let reader = container.makeContext()
        let fetched = try reader.fetch(FetchDescriptor<FailedWritePersistenceFixture>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].key, "same-key")
    }

    @MainActor
    func testUniqueUpsertPersistsRelationshipToDestinationInsertedInSameSave() throws {
        let container = try ModelContainer(
            for: UpsertRelationshipOwnerFixture.self, UpsertRelationshipDestinationFixture.self,
            configurations: .sqliteMemory("unique-upsert-relationship"))
        let context = container.mainContext
        let original = UpsertRelationshipOwnerFixture(key: "same-owner")
        context.insert(original)
        try context.save()

        let replacement = UpsertRelationshipOwnerFixture(key: "same-owner")
        let destination = UpsertRelationshipDestinationFixture(name: "new destination")
        context.insert(replacement)
        replacement.destination = destination
        try context.save()

        let ownerPK = try XCTUnwrap(replacement.persistentModelID.primaryKey)
        let destinationPK = try XCTUnwrap(destination.persistentModelID.primaryKey)
        try container.store?.read { connection in
            let rows = try connection.rows(
                "SELECT Z_OPT, ZDESTINATION FROM ZUPSERTRELATIONSHIPOWNERFIXTURE WHERE Z_PK = ?",
                arguments: [.int(ownerPK)])
            XCTAssertEqual(rows.first, [.int(2), .int(destinationPK)])
        }
    }

    @MainActor
    func testConflictingUniqueMatchesFailAtomicallyAndRetainPendingInsert() throws {
        let container = try ModelContainer(
            for: ConflictingUniqueKeysFixture.self, configurations: .sqliteMemory("conflicting-unique-upsert"))
        let context = container.mainContext
        let first = ConflictingUniqueKeysFixture(email: "first@example.com", username: "first")
        let second = ConflictingUniqueKeysFixture(email: "second@example.com", username: "second")
        context.insert(first)
        context.insert(second)
        try context.save()

        let incoming = ConflictingUniqueKeysFixture(email: first.email, username: second.username)
        context.insert(incoming)
        XCTAssertThrowsError(try context.save()) { error in
            guard case SwiftDataError.unsupportedStore = error else {
                return XCTFail("Expected conflicting unique matches, got \(error)")
            }
        }
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(incoming.hasChanges)
        XCTAssertTrue(incoming.persistentModelID.isTemporary)
        let reader = container.makeContext()
        let rows = try reader.fetch(FetchDescriptor<ConflictingUniqueKeysFixture>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.email)), ["first@example.com", "second@example.com"])
        XCTAssertEqual(Set(rows.map(\.username)), ["first", "second"])
    }

    @MainActor
    func testDirtyUpdatePreservesExternalChangeToUntouchedColumn() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("dirty-column-update"))
        let context = container.mainContext
        let model = PersistenceTestModel(title: "original")
        context.insert(model)
        try context.save()
        let pk = try XCTUnwrap(model.persistentModelID.primaryKey)

        try container.store?.write { connection in
            try connection.execute(
                "UPDATE ZPERSISTENCETESTMODEL SET ZCOUNT = ?, Z_OPT = Z_OPT + 1 WHERE Z_PK = ?",
                arguments: [.int(41), .int(pk)])
        }
        let reader = container.makeContext()
        let externallyRefreshed = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistenceTestModel>()).first)
        XCTAssertEqual(externallyRefreshed.count, 41)
        externallyRefreshed.title = "local edit"
        try reader.save()

        let stored = try container.store?.read { connection in
            try connection.rows(
                "SELECT ZTITLE, ZCOUNT, Z_OPT FROM ZPERSISTENCETESTMODEL WHERE Z_PK = ?",
                arguments: [.int(pk)])
        }
        XCTAssertEqual(stored?.first, [.text("local edit"), .int(41), .int(3)])
    }

    @MainActor
    func testOptimisticLockConflictRollsBackAllRowsAndRetainsPendingChanges() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("optimistic-conflict"))
        let writer = container.mainContext
        let original = PersistenceTestModel(title: "initial")
        writer.insert(original)
        try writer.save()

        let firstContext = container.makeContext()
        let secondContext = container.makeContext()
        let first = try XCTUnwrap(firstContext.fetch(FetchDescriptor<PersistenceTestModel>()).first)
        let second = try XCTUnwrap(secondContext.fetch(FetchDescriptor<PersistenceTestModel>()).first)
        first.title = "first writer"
        try firstContext.save()
        second.title = "stale writer"
        let earlierInsert = PersistenceTestModel(title: "must roll back")
        secondContext.insert(earlierInsert)

        XCTAssertThrowsError(try secondContext.save()) { error in
            XCTAssertEqual(error as? SwiftDataError, .optimisticLockConflict)
        }
        XCTAssertTrue(secondContext.hasChanges)
        XCTAssertTrue(second.hasChanges)
        XCTAssertTrue(earlierInsert.persistentModelID.isTemporary)

        let reader = container.makeContext()
        let rows = try reader.fetch(FetchDescriptor<PersistenceTestModel>())
        XCTAssertEqual(rows.map(\.title), ["first writer"])
    }

    @MainActor
    func testOptimisticLockConflictRejectsStaleRelationshipOnlyWrite() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("stale-relationship-write"))
        let setup = container.mainContext
        let owner = PersistentRelationshipOwner(title: "owner")
        let child = PersistentRelationshipChild(title: "child")
        setup.insert(owner)
        setup.insert(child)
        try setup.save()

        let firstContext = container.makeContext()
        let staleContext = container.makeContext()
        let firstOwner = try XCTUnwrap(firstContext.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        let firstChild = try XCTUnwrap(firstContext.fetch(FetchDescriptor<PersistentRelationshipChild>()).first)
        let staleOwner = try XCTUnwrap(staleContext.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        let staleChild = try XCTUnwrap(staleContext.fetch(FetchDescriptor<PersistentRelationshipChild>()).first)

        firstOwner.children = [firstChild]
        try firstContext.save()
        staleOwner.favorite = staleChild

        XCTAssertThrowsError(try staleContext.save()) { error in
            XCTAssertEqual(error as? SwiftDataError, .optimisticLockConflict)
        }
        XCTAssertTrue(staleContext.hasChanges)
        XCTAssertTrue(staleOwner.hasChanges)
        XCTAssertTrue(staleOwner.favorite === staleChild)

        let reader = container.makeContext()
        let persisted = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        XCTAssertEqual(persisted.children.map(\.title), ["child"])
        XCTAssertNil(persisted.favorite)
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
        context.insert(valid)
        let identifier = valid.persistentModelID
        try container.store?.write { connection in
            try connection.execute(
                "CREATE TRIGGER fail_atomic_insert BEFORE INSERT ON ZPERSISTENCETESTMODEL "
                    + "BEGIN SELECT RAISE(ABORT, 'atomic failure'); END;", arguments: [])
        }

        XCTAssertThrowsError(try context.save())
        XCTAssertEqual(valid.persistentModelID, identifier)
        XCTAssertTrue(valid.persistentModelID.isTemporary)
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(valid.hasChanges)

        let reader = container.makeContext()
        XCTAssertTrue(try reader.fetch(FetchDescriptor<PersistenceTestModel>()).isEmpty)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<FailedWritePersistenceFixture>()).count, 1)
        try container.store?.write { connection in
            try connection.execute("DROP TRIGGER fail_atomic_insert", arguments: [])
        }
    }

    @MainActor
    func testToOneAndToManyRelationshipsRoundTripWithInverseReconstruction() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("relationship-round-trip"))
        let ownerRelationship = try XCTUnwrap(
            container.schema.entity(forName: "PersistentRelationshipOwner")?.relationships.first {
                $0.name == "children"
            })
        let childRelationship = try XCTUnwrap(
            container.schema.entity(forName: "PersistentRelationshipChild")?.relationships.first { $0.name == "owner" })
        XCTAssertTrue(ownerRelationship.isToMany)
        XCTAssertFalse(childRelationship.isToMany)
        XCTAssertEqual(ownerRelationship.inverse, "owner")
        XCTAssertEqual(childRelationship.inverse, "children")
        let owner = PersistentRelationshipOwner(title: "owner")
        let first = PersistentRelationshipChild(title: "first")
        let second = PersistentRelationshipChild(title: "second")
        container.mainContext.insert(owner)
        owner.children = [second, first]
        owner.favorite = first
        try container.mainContext.save()
        let reader = container.makeContext()
        let fetchedOwner = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        XCTAssertEqual(fetchedOwner.children.map(\.title), ["first", "second"])
        XCTAssertTrue(fetchedOwner.children.allSatisfy { $0.owner?.title == fetchedOwner.title })
        XCTAssertEqual(fetchedOwner.favorite?.title, "first")
        XCTAssertEqual(
            fetchedOwner.children.first { $0.title == "first" }?.persistentModelID,
            fetchedOwner.favorite?.persistentModelID)
        XCTAssertFalse(
            reader.hasChanges,
            "Reader pending: inserted=\(reader.insertedModelsArray.count), changed=\(reader.changedModelsArray.count), "
                + "relationshipMutations=\(reader.state.relationshipMutations.count), changedModels="
                + "\(reader.changedModelsArray.map { (String(describing: type(of: $0)), $0.persistentModelID) })")
        XCTAssertFalse(fetchedOwner.hasChanges)
        XCTAssertTrue(
            fetchedOwner.children.allSatisfy { !$0.hasChanges },
            "Fetched children: \(fetchedOwner.children.map { ($0.title, $0.persistentModelID, $0.hasChanges, $0.owner?.title as Any) })"
        )
    }

    @MainActor
    func testManyToManyRoundTripUsesStablePrimaryKeyOrdering() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-round-trip"))
        let group = PersistentTagGroup(name: "group")
        let third = PersistentTag(name: "third")
        let first = PersistentTag(name: "first")
        let second = PersistentTag(name: "second")
        container.mainContext.insert(third)
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        container.mainContext.insert(group)
        group.tags = [third, first, second]
        try container.mainContext.save()
        let storedTagIDs = [third, first, second].compactMap { $0.persistentModelID.primaryKey }
        let storedGroupID = try XCTUnwrap(group.persistentModelID.primaryKey)
        XCTAssertEqual(storedTagIDs.count, 3)
        XCTAssertEqual(Set(storedTagIDs).count, 3)
        try container.store?.read { connection in
            let rows = try connection.rows(
                "SELECT Z_A, Z_B FROM Z_PERSISTENTTAG_GROUPS_PERSISTENTTAGGROUP_TAGS ORDER BY Z_A, Z_B",
                arguments: [])
            XCTAssertEqual(rows.count, 3)
            XCTAssertEqual(rows.map(\.first), storedTagIDs.sorted().map { Optional(RuntimeValue.int($0)) })
            XCTAssertTrue(rows.allSatisfy { $0.last == .int(storedGroupID) })
        }
        let reader = container.makeContext()
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentTagGroup>()).first)
        XCTAssertEqual(fetched.tags.count, 3)
        XCTAssertEqual(Set(fetched.tags.map(\.name)), Set(["first", "second", "third"]))
        XCTAssertEqual(fetched.tags.compactMap(\.persistentModelID.primaryKey), storedTagIDs.sorted())
        let primaryKeys = try fetched.tags.map { tag in
            try XCTUnwrap(tag.persistentModelID.primaryKey)
        }
        XCTAssertEqual(primaryKeys, primaryKeys.sorted())
        for tag in fetched.tags {
            XCTAssertEqual(tag.groups.map(\.name), ["group"])
            XCTAssertEqual(tag.groups.first?.persistentModelID, fetched.persistentModelID)
        }
        XCTAssertFalse(
            reader.hasChanges,
            "Tag fetch pending: \(reader.changedModelsArray.map { (String(describing: type(of: $0)), $0.persistentModelID) })"
        )
        XCTAssertFalse(fetched.hasChanges)
        XCTAssertTrue(fetched.tags.allSatisfy { !$0.hasChanges })
    }

    @MainActor
    func testManyToManyIndependentFetchFromEitherEndpoint() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-either-endpoint"))
        let group = PersistentTagGroup(name: "group")
        let tag = PersistentTag(name: "tag")
        group.tags = [tag]
        XCTAssertEqual(group.tags.map(\.name), ["tag"])
        container.mainContext.insert(group)
        container.mainContext.insert(tag)
        XCTAssertEqual(group.tags.map(\.name), ["tag"])
        try container.mainContext.save()
        try container.store?.read { connection in
            let rows = try connection.rows(
                "SELECT Z_A, Z_B FROM Z_PERSISTENTTAG_GROUPS_PERSISTENTTAGGROUP_TAGS", arguments: [])
            XCTAssertEqual(rows.count, 1)
        }
        let tagReader = container.makeContext()
        let fetchedTag = try XCTUnwrap(tagReader.fetch(FetchDescriptor<PersistentTag>()).first)
        XCTAssertEqual(fetchedTag.groups.map(\.name), ["group"])
        XCTAssertFalse(fetchedTag.hasChanges)
        XCTAssertTrue(fetchedTag.groups.allSatisfy { !$0.hasChanges })
        XCTAssertFalse(tagReader.hasChanges)

        let groupReader = container.makeContext()
        let fetchedGroup = try XCTUnwrap(groupReader.fetch(FetchDescriptor<PersistentTagGroup>()).first)
        XCTAssertEqual(fetchedGroup.tags.map(\.name), ["tag"])
        XCTAssertFalse(groupReader.hasChanges)
    }

    @MainActor
    func testManyToManyInitialAssignmentBeforeBothInsertionsPersistsOnce() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-initial-assignment"))
        let group = PersistentTagGroup(name: "group")
        let tag = PersistentTag(name: "tag")
        group.tags = [tag]
        container.mainContext.insert(group)
        container.mainContext.insert(tag)
        try container.mainContext.save()

        try container.store?.read { connection in
            let rows = try connection.rows(
                "SELECT Z_A, Z_B FROM Z_PERSISTENTTAG_GROUPS_PERSISTENTTAGGROUP_TAGS", arguments: [])
            XCTAssertEqual(rows.count, 1)
        }
        let reader = container.makeContext()
        let fetchedGroup = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentTagGroup>()).first)
        XCTAssertEqual(fetchedGroup.tags.map(\.name), ["tag"])
    }

    @MainActor
    func testDirtyRegisteredRelationshipOwnerKeepsEditedValueDuringFetch() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("dirty-owner-fetch"))
        let writer = container.mainContext
        let owner = PersistentRelationshipOwner(title: "owner")
        let savedChild = PersistentRelationshipChild(title: "saved")
        writer.insert(owner)
        writer.insert(savedChild)
        owner.children = [savedChild]
        try writer.save()

        let context = container.makeContext()
        let fetchedOwner = try XCTUnwrap(context.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        let editedChild = PersistentRelationshipChild(title: "edited")
        context.insert(editedChild)
        fetchedOwner.children = [editedChild]

        let fetchedAgain = try XCTUnwrap(context.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        XCTAssertTrue(fetchedAgain === fetchedOwner)
        XCTAssertEqual(fetchedAgain.children.map(\.title), ["edited"])
        XCTAssertTrue(fetchedAgain.hasChanges)
        XCTAssertTrue(context.hasChanges)
    }

    @MainActor
    func testInsertedRelationshipsUseSinglePersistencePlanWithAssignedIDs() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("inserted-relationship-values"))
        let context = container.mainContext
        let child = PersistentRelationshipChild(title: "initial child")
        context.insert(child)
        let owner = PersistentRelationshipOwner(title: "initial owner")
        owner.favorite = child
        context.insert(owner)

        try context.save()

        XCTAssertFalse(owner.persistentModelID.isTemporary)
        XCTAssertFalse(child.persistentModelID.isTemporary)
        try container.store?.read { connection in
            let ownerPK = try XCTUnwrap(owner.persistentModelID.primaryKey)
            let childPK = try XCTUnwrap(child.persistentModelID.primaryKey)
            let favoriteRows = try connection.rows(
                "SELECT ZFAVORITE FROM ZPERSISTENTRELATIONSHIPOWNER WHERE Z_PK = ?",
                arguments: [.int(ownerPK)])
            XCTAssertEqual(favoriteRows.first?.first, .int(childPK))
        }
    }

    @MainActor
    func testInsertedRelationshipSetterChangesPersistLatestValueInSameTransaction() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("inserted-relationship-mutation"))
        let context = container.mainContext
        let initial = PersistentRelationshipChild(title: "initial")
        let replacement = PersistentRelationshipChild(title: "replacement")
        let owner = PersistentRelationshipOwner(title: "owner")
        owner.favorite = initial
        owner.children = [initial]
        context.insert(owner)
        context.insert(initial)
        owner.favorite = replacement
        owner.children = [replacement]

        try context.save()

        let reader = container.makeContext()
        let fetchedOwner = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        XCTAssertEqual(fetchedOwner.favorite?.title, "replacement")
        XCTAssertEqual(fetchedOwner.children.map(\.title), ["replacement"])
        XCTAssertFalse(initial.persistentModelID.isTemporary)
        XCTAssertFalse(replacement.persistentModelID.isTemporary)
    }

    @MainActor
    func testRelationshipAndAttributeWriteRollbackIsAtomicAndRetainsPendingState() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("relationship-atomicity"))
        let context = container.mainContext
        let owner = PersistentRelationshipOwner(title: "before")
        let child = PersistentRelationshipChild(title: "child")
        context.insert(child)
        context.insert(owner)
        try context.save()

        owner.title = "pending"
        owner.children = [child]
        try container.store?.write { connection in
            try connection.execute(
                "CREATE TRIGGER reject_relationship_update "
                    + "BEFORE UPDATE OF ZOWNER ON ZPERSISTENTRELATIONSHIPCHILD "
                    + "BEGIN SELECT RAISE(ABORT, 'relationship failure'); END;", arguments: [])
        }

        XCTAssertThrowsError(try context.save())
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(owner.hasChanges)
        XCTAssertEqual(owner.title, "pending")
        XCTAssertTrue(owner.children.first === child)
        XCTAssertTrue(child.modelContext === context)

        try container.store?.write { connection in
            try connection.execute("DROP TRIGGER reject_relationship_update", arguments: [])
        }
        let reader = container.makeContext()
        let persisted = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        XCTAssertEqual(persisted.title, "before")
        XCTAssertTrue(persisted.children.isEmpty)

        try context.save()
        let savedReader = container.makeContext()
        let saved = try XCTUnwrap(savedReader.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        XCTAssertEqual(saved.title, "pending")
        XCTAssertEqual(saved.children.map(\.title), ["child"])
    }

    @MainActor
    func testManyToManyMutationThroughInversePersistsFromStorageOwner() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-inverse-mutation"))
        let context = container.mainContext
        let group = PersistentTagGroup(name: "group")
        let tag = PersistentTag(name: "tag")
        context.insert(group)
        context.insert(tag)

        tag.groups = [group]
        try context.save()

        try container.store?.read { connection in
            let rows = try connection.rows(
                "SELECT Z_A, Z_B FROM Z_PERSISTENTTAG_GROUPS_PERSISTENTTAGGROUP_TAGS", arguments: [])
            XCTAssertEqual(rows.count, 1)
        }
        let reader = container.makeContext()
        let fetchedGroup = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentTagGroup>()).first)
        XCTAssertEqual(fetchedGroup.tags.map(\.name), ["tag"])
    }

    @MainActor
    func testManyToManyInverseMutationPreservesUnchangedPairs() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-inverse-preserve"))
        let context = container.mainContext
        let firstGroup = PersistentTagGroup(name: "first")
        let secondGroup = PersistentTagGroup(name: "second")
        let firstTag = PersistentTag(name: "first")
        let secondTag = PersistentTag(name: "second")
        context.insert(firstGroup)
        context.insert(secondGroup)
        context.insert(firstTag)
        context.insert(secondTag)
        firstGroup.tags = [firstTag, secondTag]
        try context.save()

        firstTag.groups = [secondGroup]
        XCTAssertEqual(firstTag.groups.map(\.name), ["second"])
        XCTAssertEqual(secondTag.groups.map(\.name), ["first"])
        XCTAssertEqual(firstGroup.tags.map(\.name), ["second"])
        XCTAssertEqual(secondGroup.tags.map(\.name), ["first"])
        try context.save()

        try container.store?.read { connection in
            let rows = try connection.rows(
                "SELECT Z_A, Z_B FROM Z_PERSISTENTTAG_GROUPS_PERSISTENTTAGGROUP_TAGS ORDER BY Z_A, Z_B",
                arguments: [])
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(
                rows.map {
                    $0.compactMap { value -> Int64? in
                        if case let .int(number) = value { return number }
                        return nil
                    }
                },
                [
                    [
                        try XCTUnwrap(firstTag.persistentModelID.primaryKey),
                        try XCTUnwrap(secondGroup.persistentModelID.primaryKey),
                    ],
                    [
                        try XCTUnwrap(secondTag.persistentModelID.primaryKey),
                        try XCTUnwrap(firstGroup.persistentModelID.primaryKey),
                    ],
                ])
        }
    }

    @MainActor
    func testManyToManyMutationsFromBothOrientationsPersistOneConsistentGraph() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-mixed-orientations"))
        let context = container.mainContext
        let firstGroup = PersistentTagGroup(name: "first")
        let secondGroup = PersistentTagGroup(name: "second")
        let firstTag = PersistentTag(name: "first")
        let secondTag = PersistentTag(name: "second")
        context.insert(firstGroup)
        context.insert(secondGroup)
        context.insert(firstTag)
        context.insert(secondTag)
        firstGroup.tags = [firstTag]
        secondGroup.tags = [secondTag]
        try context.save()

        firstGroup.tags = [secondTag]
        firstTag.groups = [secondGroup]
        try context.save()

        try container.store?.read { connection in
            let rows = try connection.rows(
                "SELECT Z_A, Z_B FROM Z_PERSISTENTTAG_GROUPS_PERSISTENTTAGGROUP_TAGS ORDER BY Z_A, Z_B",
                arguments: [])
            XCTAssertEqual(rows.count, 3)
            XCTAssertEqual(
                rows.map {
                    $0.compactMap { value -> Int64? in
                        if case let .int(number) = value { return number }
                        return nil
                    }
                },
                [
                    [
                        try XCTUnwrap(firstTag.persistentModelID.primaryKey),
                        try XCTUnwrap(secondGroup.persistentModelID.primaryKey),
                    ],
                    [
                        try XCTUnwrap(secondTag.persistentModelID.primaryKey),
                        try XCTUnwrap(firstGroup.persistentModelID.primaryKey),
                    ],
                    [
                        try XCTUnwrap(secondTag.persistentModelID.primaryKey),
                        try XCTUnwrap(secondGroup.persistentModelID.primaryKey),
                    ],
                ])
        }

        let reader = container.makeContext()
        let groups = try reader.fetch(FetchDescriptor<PersistentTagGroup>())
        XCTAssertEqual(groups.first { $0.name == "first" }?.tags.map(\.name), ["second"])
        XCTAssertEqual(groups.first { $0.name == "second" }?.tags.map(\.name), ["first", "second"])
        XCTAssertFalse(
            reader.hasChanges,
            "Mixed M2M fetch pending: \(reader.changedModelsArray.map { (String(describing: type(of: $0)), $0.persistentModelID) })"
        )
        let tags = try reader.fetch(FetchDescriptor<PersistentTag>())
        XCTAssertEqual(tags.first { $0.name == "first" }?.groups.map(\.name), ["second"])
        XCTAssertEqual(tags.first { $0.name == "second" }?.groups.map(\.name), ["first", "second"])
        XCTAssertFalse(
            reader.hasChanges,
            "Mixed M2M fetch pending: \(reader.changedModelsArray.map { (String(describing: type(of: $0)), $0.persistentModelID) })"
        )
    }

    @MainActor
    func testManyToManyRemovalThroughInversePersistsEmptyStorageOwnerCollection() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-inverse-removal"))
        let context = container.mainContext
        let group = PersistentTagGroup(name: "group")
        let tag = PersistentTag(name: "tag")
        context.insert(group)
        context.insert(tag)
        group.tags = [tag]
        try context.save()

        tag.groups.removeAll()
        try context.save()

        let reader = container.makeContext()
        let fetchedGroup = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentTagGroup>()).first)
        XCTAssertTrue(fetchedGroup.tags.isEmpty)
    }

    @MainActor
    func testDeletingManyToManyEndpointCleansUpJoinRelationship() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-delete-endpoint"))
        let context = container.mainContext
        let group = PersistentTagGroup(name: "group")
        let tag = PersistentTag(name: "tag")
        context.insert(group)
        context.insert(tag)
        group.tags = [tag]
        try context.save()

        context.delete(tag)
        try context.save()

        let reader = container.makeContext()
        let fetchedGroup = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentTagGroup>()).first)
        XCTAssertTrue(fetchedGroup.tags.isEmpty)
        XCTAssertTrue(try reader.fetch(FetchDescriptor<PersistentTag>()).isEmpty)
    }

    @MainActor
    func testDeletingOneToManyDestinationNullifiesPersistedForeignKey() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("one-to-many-delete-nullify"))
        let context = container.mainContext
        let owner = PersistentRelationshipOwner(title: "owner")
        let child = PersistentRelationshipChild(title: "child")
        context.insert(owner)
        context.insert(child)
        child.owner = owner
        try context.save()
        XCTAssertEqual(owner.children.map(\.title), ["child"])
        XCTAssertTrue(child.owner === owner)

        context.delete(owner)
        try context.save()

        try container.store?.read { connection in
            let childPK = try XCTUnwrap(child.persistentModelID.primaryKey)
            let rows = try connection.rows(
                "SELECT ZOWNER FROM ZPERSISTENTRELATIONSHIPCHILD WHERE Z_PK = ?", arguments: [.int(childPK)])
            XCTAssertEqual(rows.first?.first, .null)
        }
        let reader = container.makeContext()
        let fetchedChild = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipChild>()).first)
        XCTAssertNil(fetchedChild.owner)
        XCTAssertFalse(reader.hasChanges)
    }
}
