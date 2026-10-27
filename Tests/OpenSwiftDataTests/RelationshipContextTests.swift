@testable import OpenSwiftData
import OSDCore
import XCTest

final class RelationshipContextTests: XCTestCase {
    @MainActor
    func testAttachedAssignmentAutoInsertsDestinationAndRollbackDetachesIt() throws {
        let owner = ContextOwner(name: "Ada")
        let pet = ContextPet(name: "Milo")
        let container = try ModelContainer(for: ContextOwner.self, ContextPet.self)
        let context = container.mainContext
        context.insert(owner)

        XCTAssertThrowsError(
            try context.transaction {
                owner.pets = [pet]
                XCTAssertTrue(pet.modelContext === context)
                throw SwiftDataError.unsupportedSchemaProperty("rollback")
            })

        XCTAssertNil(pet.modelContext)
        XCTAssertTrue(owner.pets.isEmpty)
        XCTAssertFalse(context.insertedModelsArray.contains { $0 === pet })
    }

    @MainActor
    func testDetachedOwnerAssignmentDoesNotAutoInsert() throws {
        let owner = ContextOwner(name: "Ada")
        let pet = ContextPet(name: "Milo")
        let container = try ModelContainer(for: ContextOwner.self, ContextPet.self)
        let adapter = try XCTUnwrap(container.relationshipAdapters(for: ContextOwner.self).first)

        try adapter.write([pet], to: owner)

        XCTAssertNil(owner.modelContext)
        XCTAssertNil(pet.modelContext)
        XCTAssertEqual(owner.pets.map(ObjectIdentifier.init), [ObjectIdentifier(pet)])
        XCTAssertTrue(container.mainContext.insertedModelsArray.isEmpty)
    }

    @MainActor
    func testToOneCardinalityBoundaryAcceptsSingleEndpoint() throws {
        let owner = ContextSingleOwner(name: "Ada")
        let first = ContextPet(name: "First")
        let container = try ModelContainer(for: ContextSingleOwner.self, ContextPet.self)
        container.mainContext.insert(owner)
        let adapter = try XCTUnwrap(container.relationshipAdapters(for: ContextSingleOwner.self).first)

        owner.pet = first
        XCTAssertTrue(owner.pet === first)
        XCTAssertTrue(first.modelContext === container.mainContext)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, 1)
        XCTAssertEqual(adapter.metadata?.isToMany, false)
    }

    @MainActor
    func testDeleteDenyLeavesOwnerUntouchedAndProcessingIsIdempotent() throws {
        let owner = ContextDenyOwner(name: "Ada")
        let pet = ContextPet(name: "Milo")
        let container = try ModelContainer(for: ContextDenyOwner.self, ContextPet.self)
        let context = ModelContext(testSave: {}, container: container)
        context.insert(owner)
        context.insert(pet)
        try context.save()
        let adapter = try XCTUnwrap(container.relationshipAdapters(for: ContextDenyOwner.self).first)
        try adapter.write([pet], to: owner)

        context.delete(owner)
        XCTAssertFalse(owner.isDeleted)
        XCTAssertFalse(context.deletedModelsArray.contains { $0 === owner })
        XCTAssertEqual(adapter.read(owner)?.map(ObjectIdentifier.init), [ObjectIdentifier(pet)])
        let eventCount = context.state.relationshipMutations.count
        try context.processPendingChanges()
        XCTAssertEqual(context.state.relationshipMutations.count, eventCount)
    }

    @MainActor
    func testCascadeAndNullifyDeleteRulesApplySynchronously() throws {
        let cascadeOwner = ContextCascadeOwner(name: "A")
        let cascadePet = ContextPet(name: "Cascade")
        let cascadeContainer = try ModelContainer(for: ContextCascadeOwner.self, ContextPet.self)
        let cascadeContext = ModelContext(testSave: {}, container: cascadeContainer)
        cascadeContext.insert(cascadeOwner)
        cascadeContext.insert(cascadePet)
        try cascadeContext.save()
        try XCTUnwrap(cascadeContainer.relationshipAdapters(for: ContextCascadeOwner.self).first)
            .write([cascadePet], to: cascadeOwner)
        cascadeContext.delete(cascadeOwner)
        XCTAssertTrue(cascadeContext.deletedModelsArray.contains { $0 === cascadeOwner })
        try cascadeContext.processPendingChanges()
        XCTAssertTrue(cascadeContext.deletedModelsArray.contains { $0 === cascadeOwner })
        XCTAssertTrue(cascadeContext.deletedModelsArray.contains { $0 === cascadePet })

        let nullifyOwner = ContextNullifyOwner(name: "B")
        let nullifyPet = ContextPet(name: "Nullify")
        let nullifyContainer = try ModelContainer(for: ContextNullifyOwner.self, ContextPet.self)
        let nullifyContext = ModelContext(testSave: {}, container: nullifyContainer)
        nullifyContext.insert(nullifyOwner)
        nullifyContext.insert(nullifyPet)
        try nullifyContext.save()
        try XCTUnwrap(nullifyContainer.relationshipAdapters(for: ContextNullifyOwner.self).first)
            .write([nullifyPet], to: nullifyOwner)
        nullifyContext.delete(nullifyOwner)
        XCTAssertTrue(nullifyContext.deletedModelsArray.contains { $0 === nullifyOwner })
        try nullifyContext.processPendingChanges()
        XCTAssertNil(nullifyPet.owner)
    }

}

@Model
private final class ContextOwner {
    var name: String
    @Relationship var pets: [ContextPet] = []
    init(name: String) { self.name = name }
}

@Model
private final class ContextPet {
    var name: String
    @Relationship var owner: ContextOwner?
    init(name: String) { self.name = name }
}

@Model
private final class ContextSingleOwner {
    var name: String
    @Relationship(inverse: nil) var pet: ContextPet?
    init(name: String) { self.name = name }
}

@Model
private final class ContextDenyOwner {
    var name: String
    @Relationship(deleteRule: .deny, inverse: nil) var pets: [ContextPet] = []
    init(name: String) { self.name = name }
}

@Model
private final class ContextCascadeOwner {
    var name: String
    @Relationship(deleteRule: .cascade, inverse: nil) var pets: [ContextPet] = []
    init(name: String) { self.name = name }
}

@Model
private final class ContextNullifyOwner {
    var name: String
    @Relationship(deleteRule: .nullify, inverse: nil) var pets: [ContextPet] = []
    init(name: String) { self.name = name }
}
