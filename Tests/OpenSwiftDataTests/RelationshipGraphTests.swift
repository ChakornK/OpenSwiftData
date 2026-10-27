@testable import OpenSwiftData
import XCTest

final class RelationshipGraphTests: XCTestCase {
    @MainActor
    func testTypedAdapterWritesOnceAndJournalsOrderedEndpoints() throws {
        let person = GraphPerson(name: "Ada")
        let first = GraphPet(name: "Milo")
        let second = GraphPet(name: "Luna")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        container.mainContext.insert(person)
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        let adapter = try XCTUnwrap(container.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pets" })
        let initialEvents = container.mainContext.state.relationshipMutations.count

        try adapter.write([first, second], to: person)

        XCTAssertEqual(person.pets.map(ObjectIdentifier.init), [ObjectIdentifier(first), ObjectIdentifier(second)])
        let events = Array(container.mainContext.state.relationshipMutations.dropFirst(initialEvents))
        XCTAssertEqual(events.count, 3)
        let event = try XCTUnwrap(events.first)
        XCTAssertTrue(event.owner === person)
        XCTAssertEqual(event.property, "pets")
        XCTAssertEqual(event.relationship.destination, "GraphPet")
        XCTAssertEqual(event.relationship.inverse, "owner")
        XCTAssertTrue(event.oldEndpoints.isEmpty)
        XCTAssertEqual(
            event.newEndpoints.map(ObjectIdentifier.init), [ObjectIdentifier(first), ObjectIdentifier(second)])
        XCTAssertEqual(event.newEndpointIDs, [first.persistentModelID, second.persistentModelID])
        XCTAssertTrue(events[1].owner === first)
        XCTAssertEqual(events[1].property, "owner")
        XCTAssertTrue(events[1].oldEndpoints.isEmpty)
        XCTAssertEqual(events[1].newEndpoints.map(ObjectIdentifier.init), [ObjectIdentifier(person)])
        XCTAssertTrue(events[2].owner === second)
        XCTAssertEqual(events[2].property, "owner")
        XCTAssertTrue(events[2].oldEndpoints.isEmpty)
        XCTAssertEqual(events[2].newEndpoints.map(ObjectIdentifier.init), [ObjectIdentifier(person)])
    }

    @MainActor
    func testGeneratedRelationshipSetterSynchronouslyPropagatesInverse() throws {
        let person = GraphPerson(name: "Ada")
        let pet = GraphPet(name: "Milo")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        XCTAssertEqual(
            container.schema.entity(forName: "GraphPerson")?.relationships.first { $0.name == "pets" }?.inverse,
            "owner")
        XCTAssertNil(container.schema.entity(forName: "GraphPerson")?.relationships.first { $0.name == "pet" }?.inverse)
        container.mainContext.insert(person)
        container.mainContext.insert(pet)

        person.pets = [pet]

        XCTAssertEqual(person.pets.map(ObjectIdentifier.init), [ObjectIdentifier(pet)])
        XCTAssertTrue(pet.owner === person)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, 2)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.map(\.property), ["pets", "owner"])
    }

    @MainActor
    func testInverseToOneReplacementRemovesFromDisplacedOwner() throws {
        let personA = GraphPerson(name: "A")
        let personB = GraphPerson(name: "B")
        let pet = GraphPet(name: "Milo")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        container.mainContext.insert(personA)
        container.mainContext.insert(personB)
        container.mainContext.insert(pet)
        let pets = try XCTUnwrap(container.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pets" })
        let owner = try XCTUnwrap(container.relationshipAdapters(for: GraphPet.self).first { $0.name == "owner" })
        try pets.write([pet], to: personA)
        let assignmentStart = container.mainContext.state.relationshipMutations.count
        try owner.write(personB, to: pet)

        XCTAssertTrue(pet.owner === personB)
        XCTAssertTrue(personA.pets.isEmpty)
        XCTAssertEqual(personB.pets.map(ObjectIdentifier.init), [ObjectIdentifier(pet)])
        let events = Array(container.mainContext.state.relationshipMutations.dropFirst(assignmentStart))
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(Set(events.map { "\(ObjectIdentifier($0.owner)):\($0.property)" }).count, 3)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, assignmentStart + 3)
    }

    @MainActor
    func testToManyReplacementClearsOldInverse() throws {
        let person = GraphPerson(name: "Ada")
        let first = GraphPet(name: "First")
        let second = GraphPet(name: "Second")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        container.mainContext.insert(person)
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        let pets = try XCTUnwrap(container.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pets" })
        try pets.write([first], to: person)
        let before = container.mainContext.state.relationshipMutations.count

        try pets.write([second], to: person)

        XCTAssertNil(first.owner)
        XCTAssertTrue(second.owner === person)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count - before, 3)
    }

    @MainActor
    func testNilRemovalBothDirections() throws {
        let person = GraphPerson(name: "Ada")
        let pet = GraphPet(name: "Milo")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        container.mainContext.insert(person)
        container.mainContext.insert(pet)
        let pets = try XCTUnwrap(container.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pets" })
        let owner = try XCTUnwrap(container.relationshipAdapters(for: GraphPet.self).first { $0.name == "owner" })

        try owner.write(person, to: pet)
        let before = container.mainContext.state.relationshipMutations.count
        try owner.write((nil as GraphPerson?) as Any, to: pet)
        XCTAssertTrue(person.pets.isEmpty)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count - before, 2)

        try pets.write([pet], to: person)
        try pets.write([GraphPet](), to: person)
        XCTAssertNil(pet.owner)
    }

    @MainActor
    func testDuplicateAndRepeatedAssignmentIsIdempotent() throws {
        let person = GraphPerson(name: "Ada")
        let first = GraphPet(name: "Milo")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        container.mainContext.insert(person)
        container.mainContext.insert(first)
        let pets = try XCTUnwrap(container.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pets" })

        try pets.write([first, first], to: person)
        XCTAssertEqual(person.pets.count, 1)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, 2)
        let changedBefore = container.mainContext.state.changedModels.map(ObjectIdentifier.init)
        let eventsBefore = container.mainContext.state.relationshipMutations.count
        try pets.write([first], to: person)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, eventsBefore)
        XCTAssertEqual(container.mainContext.state.changedModels.map(ObjectIdentifier.init), changedBefore)
    }

    @MainActor
    func testDuplicateRelationshipAssignmentRejectsCrossContextEndpoint() throws {
        let person = GraphPerson(name: "Ada")
        let pet = GraphPet(name: "Milo")
        let first = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        let second = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        let otherContextPet = GraphPet(name: "Luna")
        first.mainContext.insert(person)
        first.mainContext.insert(pet)
        second.mainContext.insert(otherContextPet)
        let pets = try XCTUnwrap(first.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pets" })
        try pets.write([pet], to: person)

        let currentEvents = first.mainContext.state.relationshipMutations.count
        XCTAssertThrowsError(try pets.write([pet, otherContextPet], to: person))
        XCTAssertEqual(person.pets.map(ObjectIdentifier.init), [ObjectIdentifier(pet)])
        XCTAssertTrue(pet.owner === person)
        XCTAssertEqual(first.mainContext.state.relationshipMutations.count, currentEvents)
    }

    @MainActor
    func testDuplicateNoOpAssignmentStillRejectsCrossContextEndpoint() throws {
        let pet = GraphPet(name: "Milo")
        let first = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        let second = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        let person = GraphPerson(name: "Ada")
        first.mainContext.insert(person)
        second.mainContext.insert(pet)
        let pets = try XCTUnwrap(first.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pets" })

        let eventsBefore = first.mainContext.state.relationshipMutations.count
        XCTAssertThrowsError(try pets.write([pet, pet], to: person))
        XCTAssertTrue(person.pets.isEmpty)
        XCTAssertNil(pet.owner)
        XCTAssertEqual(first.mainContext.state.relationshipMutations.count, eventsBefore)
    }

    @MainActor
    func testSelfReferentialCycle() throws {
        let a = GraphNode(name: "A")
        let b = GraphNode(name: "B")
        let container = try ModelContainer(for: GraphNode.self)
        container.mainContext.insert(a)
        container.mainContext.insert(b)
        let parent = try XCTUnwrap(container.relationshipAdapters(for: GraphNode.self).first { $0.name == "parent" })

        try parent.write(b, to: a)
        try parent.write(a, to: b)
        XCTAssertEqual(a.children.map(ObjectIdentifier.init), [ObjectIdentifier(b)])
        XCTAssertEqual(b.children.map(ObjectIdentifier.init), [ObjectIdentifier(a)])
        XCTAssertTrue(a.parent === b)
        XCTAssertTrue(b.parent === a)

        try parent.write(a, to: a)
        XCTAssertTrue(a.children.contains { $0 === a })
        XCTAssertTrue(b.children.isEmpty)
    }

    @MainActor
    func testNonoptionalToOneCannotBeCleared() throws {
        let holder = GraphHolder(name: "H")
        let badge = GraphBadge(holder: holder)
        let container = try ModelContainer(for: GraphHolder.self, GraphBadge.self)
        container.mainContext.insert(holder)
        container.mainContext.insert(badge)
        let badges = try XCTUnwrap(container.relationshipAdapters(for: GraphHolder.self).first { $0.name == "badges" })
        let holderAdapter = try XCTUnwrap(
            container.relationshipAdapters(for: GraphBadge.self).first { $0.name == "holder" })
        XCTAssertFalse(holderAdapter.isToMany)
        XCTAssertEqual(holderAdapter.metadata?.inverse, "badges")
        XCTAssertThrowsError(try holderAdapter.makeInverseValue([]))
        XCTAssertNotNil(
            container.mainContext.state.relationshipAdapters(for: GraphHolder.self).first { $0.name == "badges" })
        XCTAssertEqual(badges.keyPath, \GraphHolder.badges)
        try badges.write([badge], to: holder)
        let before = container.mainContext.state.relationshipMutations.count

        XCTAssertThrowsError(try badges.write([GraphBadge](), to: holder)) { error in
            guard case SwiftDataError.relationshipGraphConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(holder.badges.map(ObjectIdentifier.init), [ObjectIdentifier(badge)])
        XCTAssertTrue(badge.holder === holder)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, before)
    }

    @MainActor
    func testGeneratedSetterRejectsNonoptionalInverseConflictWithoutMutation() throws {
        let holder = GraphHolder(name: "H")
        let badge = GraphBadge(holder: holder)
        let container = try ModelContainer(for: GraphHolder.self, GraphBadge.self)
        container.mainContext.insert(holder)
        container.mainContext.insert(badge)
        let badges = try XCTUnwrap(container.relationshipAdapters(for: GraphHolder.self).first { $0.name == "badges" })
        try badges.write([badge], to: holder)
        let eventsBefore = container.mainContext.state.relationshipMutations.count

        holder.badges = []

        XCTAssertTrue(holder.badges.isEmpty)
        XCTAssertTrue(badge.holder === holder)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, eventsBefore)
    }

    @MainActor
    func testCrossContextEndpointRejectedWithoutMutation() throws {
        let person = GraphPerson(name: "Ada")
        let pet = GraphPet(name: "Milo")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        let otherContext = container.makeContext()
        container.mainContext.insert(person)
        otherContext.insert(pet)
        let pets = try XCTUnwrap(container.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pets" })
        let mainEvents = container.mainContext.state.relationshipMutations.count
        let otherEvents = otherContext.state.relationshipMutations.count

        XCTAssertThrowsError(try pets.write([pet], to: person)) { error in
            guard case SwiftDataError.relationshipContextMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(person.pets.isEmpty)
        XCTAssertNil(pet.owner)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, mainEvents)
        XCTAssertEqual(otherContext.state.relationshipMutations.count, otherEvents)
    }

    @MainActor
    func testDetachedOwnerWritesOnlyOwner() throws {
        let person = GraphPerson(name: "Ada")
        let pet = GraphPet(name: "Milo")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        let pets = try XCTUnwrap(container.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pets" })

        try pets.write([pet], to: person)

        XCTAssertEqual(person.pets.map(ObjectIdentifier.init), [ObjectIdentifier(pet)])
        XCTAssertNil(pet.owner)
        XCTAssertTrue(container.mainContext.state.relationshipMutations.isEmpty)
    }

    @MainActor
    func testRollbackRestoresAllAffectedEndpoints() throws {
        let person = GraphPerson(name: "Ada")
        let first = GraphPet(name: "First")
        let second = GraphPet(name: "Second")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        container.mainContext.insert(person)
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        let pets = try XCTUnwrap(container.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pets" })
        try pets.write([first], to: person)
        let before = container.mainContext.state.relationshipMutations

        XCTAssertThrowsError(
            try container.mainContext.transaction {
                try pets.write([second], to: person)
                throw SwiftDataError.unsupportedSchemaProperty("rollback")
            })
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, before.count)
        XCTAssertEqual(person.pets.map(ObjectIdentifier.init), [ObjectIdentifier(first)])
        XCTAssertTrue(first.owner === person)
        XCTAssertNil(second.owner)
        XCTAssertEqual(
            container.mainContext.state.relationshipMutations.map(\.newEndpointIDs), before.map(\.newEndpointIDs))
    }

    @MainActor
    func testFailedWriteRestoresStateAndJournal() throws {
        let holder = GraphHolder(name: "H")
        let badge = GraphBadge(holder: holder)
        let container = try ModelContainer(for: GraphHolder.self, GraphBadge.self)
        container.mainContext.insert(holder)
        container.mainContext.insert(badge)
        let badges = try XCTUnwrap(container.relationshipAdapters(for: GraphHolder.self).first { $0.name == "badges" })
        try badges.write([badge], to: holder)
        let insertedBefore = container.mainContext.state.insertedModels.count
        let changedBefore = container.mainContext.state.changedModels.count
        let eventsBefore = container.mainContext.state.relationshipMutations

        XCTAssertThrowsError(try badges.write([GraphBadge](), to: holder))
        XCTAssertEqual(container.mainContext.state.insertedModels.count, insertedBefore)
        XCTAssertEqual(container.mainContext.state.changedModels.count, changedBefore)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, eventsBefore.count)
        XCTAssertEqual(
            container.mainContext.state.relationshipMutations.map(\.newEndpointIDs), eventsBefore.map(\.newEndpointIDs))
    }

    @MainActor
    func testInverseConsistencyAcrossFixedSequences() throws {
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        let people = [GraphPerson(name: "P1"), GraphPerson(name: "P2")]
        let pets = [GraphPet(name: "E1"), GraphPet(name: "E2"), GraphPet(name: "E3")]
        for person in people { container.mainContext.insert(person) }
        for pet in pets { container.mainContext.insert(pet) }
        let petAdapter = try XCTUnwrap(
            container.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pets" })
        let ownerAdapter = try XCTUnwrap(
            container.relationshipAdapters(for: GraphPet.self).first { $0.name == "owner" })
        func verify() {
            for person in people {
                for pet in pets {
                    XCTAssertEqual(pet.owner === person, person.pets.contains { $0 === pet })
                }
            }
        }

        try petAdapter.write([pets[0], pets[1]], to: people[0]); verify()
        try petAdapter.write([pets[1]], to: people[1]); verify()
        try ownerAdapter.write(people[1], to: pets[0]); verify()
        try petAdapter.write([GraphPet](), to: people[0]); verify()

        try ownerAdapter.write(people[0], to: pets[0]); verify()
        try ownerAdapter.write(people[0], to: pets[1]); verify()
        try ownerAdapter.write((nil as GraphPerson?) as Any, to: pets[0]); verify()
        try petAdapter.write([pets[0], pets[1], pets[2]], to: people[1]); verify()

        try petAdapter.write([pets[0], pets[0], pets[1]], to: people[0]); verify()
        try petAdapter.write([pets[1], pets[0]], to: people[0]); verify()
        try ownerAdapter.write(people[1], to: pets[1]); verify()

        try ownerAdapter.write(people[1], to: pets[2]); verify()
        try petAdapter.write([pets[2]], to: people[1]); verify()
        try petAdapter.write([pets[2]], to: people[0]); verify()
    }

    @MainActor
    func testInverseAssignmentUpdatesToManyAndJournalsOnlyChangedProperties() throws {
        let person = GraphPerson(name: "Ada")
        let pet = GraphPet(name: "Milo")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        container.mainContext.insert(person)
        container.mainContext.insert(pet)
        let adapter = try XCTUnwrap(container.relationshipAdapters(for: GraphPet.self).first { $0.name == "owner" })
        XCTAssertEqual(
            container.schema.entity(forName: "GraphPet")?.relationships.first { $0.name == "owner" }?.inverse, "pets")
        XCTAssertEqual(adapter.metadata?.inverse, "pets")

        try adapter.write(person, to: pet)

        XCTAssertTrue(pet.owner === person)
        XCTAssertTrue(person.pets.contains { $0 === pet })
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, 2)
    }

    @MainActor
    func testToOneCardinalityRejectsMultipleEndpointsWithoutMutation() throws {
        let person = GraphPerson(name: "Ada")
        let first = GraphPet(name: "Milo")
        let second = GraphPet(name: "Luna")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        container.mainContext.insert(person)
        let adapter = try XCTUnwrap(container.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pet" })

        XCTAssertThrowsError(try adapter.write([first, second], to: person))
        XCTAssertNil(person.pet)
        XCTAssertTrue(container.mainContext.state.relationshipMutations.isEmpty)
    }

    @MainActor
    func testManualSchemaBindsExplicitRelationshipCandidate() throws {
        let schema = Schema([
            Schema.Entity(
                name: "GraphPerson",
                relationships: [
                    Schema.Relationship(name: "pets", destination: "GraphPet", isToMany: true, inverse: "owner")
                ]),
            Schema.Entity(name: "GraphPet"),
        ])

        let container = try ModelContainer(for: [GraphPerson.self, GraphPet.self], schema: schema)
        XCTAssertEqual(container.relationshipAdapters(for: GraphPerson.self).map(\.name), ["pets"])
        let person = GraphPerson(name: "Ada")
        let pet = GraphPet(name: "Milo")
        try XCTUnwrap(container.relationshipAdapters(for: GraphPerson.self).first).write([pet], to: person)
        XCTAssertEqual(person.pets.count, 1)
    }

    @MainActor
    func testManualSchemaRejectsRelationshipWithoutCompatibleCandidate() {
        let schema = Schema([
            Schema.Entity(
                name: "GraphPerson",
                relationships: [
                    Schema.Relationship(name: "pet", destination: "GraphPet", isToMany: true)
                ]),
            Schema.Entity(name: "GraphPet"),
        ])

        XCTAssertThrowsError(try ModelContainer(for: [GraphPerson.self, GraphPet.self], schema: schema)) { error in
            guard case SwiftDataError.unsupportedSchemaProperty(let message) = error else {
                return XCTFail("Expected actionable schema error, got \\(error)")
            }
            XCTAssertTrue(message.contains("GraphPerson.pet"))
            XCTAssertTrue(message.contains("GraphPet"))
            XCTAssertTrue(message.contains("to-many"))
        }
    }

    @MainActor
    func testAdapterBoxRejectsMismatchedOwnerType() throws {
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        let adapter = try XCTUnwrap(container.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pets" })
        let wrongOwner = GraphPet(name: "Milo")

        XCTAssertNil(adapter.read(wrongOwner))
        XCTAssertThrowsError(try adapter.write([GraphPet](), to: wrongOwner))
    }

    @MainActor
    func testManualModelExplicitInverseCandidateBinds() throws {
        let container = try ModelContainer(for: ManualInverseSource.self, ManualInverseDestination.self)
        XCTAssertEqual(container.relationshipAdapters(for: ManualInverseSource.self).map(\.name), ["destination"])
    }

    func testRelationshipModelRequirementsDispatchThroughExistentialMetatype() {
        let modelType: any RelationshipModel.Type = ManualInverseDestination.self

        XCTAssertEqual(modelType.relationshipAdapterCandidates().map(\.name), ["source"])
        XCTAssertTrue(modelType.inferredRelationshipAdapterCandidates().isEmpty)
    }

    @MainActor
    func testLegacyPersistentModelWithoutRefinementUsesEmptyCandidates() throws {
        let modelType: any PersistentModel.Type = LegacyPersistentOwner.self
        let container = try ModelContainer(for: modelType, InferredTarget.self)
        XCTAssertTrue(container.relationshipAdapters(for: LegacyPersistentOwner.self).isEmpty)
    }

    @MainActor
    func testManualModelRelationshipWithoutCandidateThrows() {
        XCTAssertThrowsError(try ModelContainer(for: MissingCandidateOwner.self, InferredTarget.self)) { error in
            guard case SwiftDataError.unsupportedSchemaProperty(let message) = error else {
                return XCTFail("Expected actionable schema error, got \\(error)")
            }
            XCTAssertTrue(message.contains("MissingCandidateOwner.targets"))
            XCTAssertTrue(message.contains("no compatible typed adapter exists"))
        }
    }

    @MainActor
    func testManualModelDuplicateCandidatesThrow() {
        XCTAssertThrowsError(try ModelContainer(for: DuplicateCandidateOwner.self, InferredTarget.self)) { error in
            guard case SwiftDataError.unsupportedSchemaProperty(let message) = error else {
                return XCTFail("Expected actionable schema error, got \\(error)")
            }
            XCTAssertTrue(message.contains("multiple compatible typed adapters exist"))
        }
    }

    @MainActor
    func testInferredRelationshipCollectionsBindAndScalarCollectionsDoNot() throws {
        let container = try ModelContainer(for: InferredOwner.self, InferredTarget.self, ScalarCollections.self)
        XCTAssertEqual(container.relationshipAdapters(for: InferredOwner.self).map(\.name), ["targets"])
        XCTAssertTrue(container.relationshipAdapters(for: ScalarCollections.self).isEmpty)
        let owner = InferredOwner(backingData: InferredOwner.createBackingData())
        let target = InferredTarget(backingData: InferredTarget.createBackingData())
        try XCTUnwrap(container.relationshipAdapters(for: InferredOwner.self).first).write([target], to: owner)
        XCTAssertEqual(owner.targets.count, 1)
    }

    @MainActor
    func testRelationshipEventsAndAttributeChangesContributeToHasChanges() throws {
        let person = RetentionPerson(name: "Ada")
        let pet = RetentionPet(name: "Milo")
        let container = try ModelContainer(for: RetentionPerson.self, RetentionPet.self)
        container.mainContext.insert(person)
        container.mainContext.insert(pet)
        let adapter = try XCTUnwrap(
            container.relationshipAdapters(for: RetentionPerson.self).first { $0.name == "pets" })
        try adapter.write([pet], to: person)
        let pendingCount = container.mainContext.state.relationshipMutations.count
        person.name = "Ada Lovelace"
        XCTAssertTrue(container.mainContext.hasChanges)
        container.mainContext.rollback()

        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, pendingCount)
        XCTAssertTrue(container.mainContext.hasChanges)
    }

    @MainActor
    func testNonInverseRelationshipJournalsOneEvent() throws {
        let person = GraphPerson(name: "Ada")
        let pet = GraphPet(name: "Milo")
        let friend = GraphPet(name: "Luna")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        container.mainContext.insert(person)
        container.mainContext.insert(pet)
        container.mainContext.insert(friend)
        let petAdapter = try XCTUnwrap(container.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pet" })
        let friendsAdapter = try XCTUnwrap(
            container.relationshipAdapters(for: GraphPet.self).first { $0.name == "friends" })

        try petAdapter.write(pet, to: person)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, 1)
        XCTAssertNil(pet.owner)
        XCTAssertTrue(person.pets.isEmpty)

        try friendsAdapter.write([friend], to: pet)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, 2)
        XCTAssertTrue(pet.friends.first === friend)
        XCTAssertTrue(friend.friends.isEmpty)
    }

    @MainActor
    func testRollbackRestoresRelationshipEventSnapshot() throws {
        let person = GraphPerson(name: "Ada")
        let pet = GraphPet(name: "Milo")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        container.mainContext.insert(person)
        container.mainContext.insert(pet)
        let adapter = try XCTUnwrap(container.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pets" })
        try adapter.write([pet], to: person)
        let eventsBeforeTransaction = container.mainContext.state.relationshipMutations

        XCTAssertThrowsError(
            try container.mainContext.transaction {
                try adapter.write([GraphPet](), to: person)
                throw SwiftDataError.unsupportedSchemaProperty("expected rollback")
            })

        let restoredEvents = container.mainContext.state.relationshipMutations
        XCTAssertEqual(restoredEvents.count, eventsBeforeTransaction.count)
        XCTAssertTrue(restoredEvents.last?.owner === eventsBeforeTransaction.last?.owner)
        XCTAssertEqual(restoredEvents.last?.newEndpointIDs, eventsBeforeTransaction.last?.newEndpointIDs)
    }

    @MainActor
    func testOptionalNilClearsAndInvalidValueDoesNotMutateOrJournal() throws {
        let person = GraphPerson(name: "Ada")
        let first = GraphPet(name: "Milo")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        container.mainContext.insert(person)
        container.mainContext.insert(first)
        let adapter = try XCTUnwrap(container.relationshipAdapters(for: GraphPerson.self).first { $0.name == "pets" })
        try adapter.write([first], to: person)
        let countBeforeClear = container.mainContext.state.relationshipMutations.count

        try adapter.write([GraphPet](), to: person)

        XCTAssertTrue(person.pets.isEmpty)
        let clearEvents = Array(container.mainContext.state.relationshipMutations.dropFirst(countBeforeClear))
        XCTAssertEqual(clearEvents.count, 2)
        let clear = try XCTUnwrap(clearEvents.first { $0.owner === person })
        XCTAssertEqual(clear.oldEndpoints.map(ObjectIdentifier.init), [ObjectIdentifier(first)])
        XCTAssertTrue(clear.newEndpoints.isEmpty)

        let countBeforeInvalid = container.mainContext.state.relationshipMutations.count
        let oldValue = person.pets
        XCTAssertThrowsError(try adapter.write("not pets" as Any, to: person)) { error in
            guard case SwiftDataError.relationshipValueTypeMismatch(property: "pets", expected: _, actual: _) = error
            else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(person.pets.map(ObjectIdentifier.init), oldValue.map(ObjectIdentifier.init))
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, countBeforeInvalid)
    }

    @MainActor
    func testAttachedRelationshipSetterAutoInsertsDetachedDestination() throws {
        let owner = RetentionPerson(name: "Ada")
        let pet = RetentionPet(name: "Milo")
        let container = try ModelContainer(for: RetentionPerson.self, RetentionPet.self)
        container.mainContext.insert(owner)

        owner.pets = [pet]

        XCTAssertTrue(pet.modelContext === container.mainContext)
        XCTAssertTrue(container.mainContext.insertedModelsArray.contains { $0 === pet })
        XCTAssertEqual(owner.pets.map(ObjectIdentifier.init), [ObjectIdentifier(pet)])
    }

    @MainActor
    func testDetachedOwnerAssignmentDoesNotAutoInsertDestination() throws {
        let owner = RetentionPerson(name: "Ada")
        let pet = RetentionPet(name: "Milo")
        let container = try ModelContainer(for: RetentionPerson.self, RetentionPet.self)
        let adapter = try XCTUnwrap(container.relationshipAdapters(for: RetentionPerson.self).first)

        try adapter.write([pet], to: owner)

        XCTAssertNil(owner.modelContext)
        XCTAssertNil(pet.modelContext)
        XCTAssertEqual(owner.pets.map(ObjectIdentifier.init), [ObjectIdentifier(pet)])
        XCTAssertTrue(container.mainContext.insertedModelsArray.isEmpty)
    }

    @MainActor
    func testDetachedGeneratedRelationshipAssignmentSurvivesInsertion() throws {
        let owner = RetentionPerson(name: "Ada")
        let pet = RetentionPet(name: "Milo")
        let container = try ModelContainer(for: RetentionPerson.self, RetentionPet.self)

        owner.pets = [pet]

        XCTAssertEqual(owner.pets.map(ObjectIdentifier.init), [ObjectIdentifier(pet)])
        XCTAssertNil(owner.modelContext)
        XCTAssertNil(pet.modelContext)
        XCTAssertTrue(container.mainContext.state.relationshipMutations.isEmpty)

        container.mainContext.insert(owner)
        container.mainContext.insert(pet)

        XCTAssertEqual(owner.pets.map(ObjectIdentifier.init), [ObjectIdentifier(pet)])
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, 0)
    }

    @MainActor
    func testAutoInsertedRelationshipDestinationRollsBackWithTransaction() throws {
        let owner = RetentionPerson(name: "Ada")
        let pet = RetentionPet(name: "Milo")
        let container = try ModelContainer(for: RetentionPerson.self, RetentionPet.self)
        container.mainContext.insert(owner)

        XCTAssertThrowsError(
            try container.mainContext.transaction {
                owner.pets = [pet]
                XCTAssertTrue(pet.modelContext === container.mainContext)
                throw SwiftDataError.unsupportedSchemaProperty("expected rollback")
            })

        XCTAssertNil(pet.modelContext)
        XCTAssertTrue(owner.pets.isEmpty)
        XCTAssertFalse(container.mainContext.insertedModelsArray.contains { $0 === pet })
    }

    @MainActor
    func testRelationshipAutoInsertPreflightsContextAndCardinalityBeforeMutation() throws {
        let owner = GraphPerson(name: "Ada")
        let attachedPet = GraphPet(name: "Attached")
        let foreignPet = GraphPet(name: "Foreign")
        let container = try ModelContainer(for: GraphPerson.self, GraphPet.self)
        let otherContext = container.makeContext()
        container.mainContext.insert(owner)
        container.mainContext.insert(attachedPet)
        otherContext.insert(foreignPet)
        owner.pets = [attachedPet, foreignPet]
        XCTAssertTrue(owner.pets.isEmpty)
        XCTAssertNil(attachedPet.owner)
        XCTAssertTrue(foreignPet.modelContext === otherContext)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, 0)
        XCTAssertFalse(container.mainContext.insertedModelsArray.contains { $0 === foreignPet })
    }

    @MainActor
    func testDeleteDenyIsRecoverableAndLeavesModelManaged() throws {
        let owner = DeleteRuleOwner(name: "A")
        let child = DeleteRuleChild(name: "B")
        let container = try ModelContainer(for: DeleteRuleOwner.self, DeleteRuleChild.self)
        let context = ModelContext(testSave: {}, container: container)
        context.insert(owner)
        context.insert(child)
        try context.save()
        let adapter = try XCTUnwrap(container.relationshipAdapters(for: DeleteRuleOwner.self).first)
        XCTAssertEqual(adapter.metadata?.deleteRule, .deny)
        XCTAssertTrue(owner.modelContext === context)
        XCTAssertTrue(child.modelContext === context)
        XCTAssertEqual(context.state.relationshipAdapters(for: DeleteRuleOwner.self).map(\.name), ["children"])
        try adapter.write([child], to: owner)
        XCTAssertEqual(adapter.read(owner)?.count, 1)
        XCTAssertEqual(owner.children.count, 1)
        XCTAssertTrue(child.modelContext === context)
        XCTAssertFalse(child.isDeleted)
        XCTAssertFalse(context.deletedModelsArray.contains { $0 === child })
        XCTAssertFalse(context.insertedModelsArray.contains { $0 === owner })
        XCTAssertFalse(context.insertedModelsArray.contains { $0 === child })

        context.delete(owner)
        XCTAssertFalse(owner.isDeleted)
        XCTAssertFalse(context.deletedModelsArray.contains { $0 === owner })
        try context.processPendingChanges()
        XCTAssertTrue(owner.modelContext === context)
        XCTAssertFalse(context.deletedModelsArray.contains { $0 === owner })
        XCTAssertFalse(owner.isDeleted)
        XCTAssertEqual(
            context.state.relationshipMutations.last?.newEndpoints.map(ObjectIdentifier.init), [ObjectIdentifier(child)]
        )
        XCTAssertEqual(adapter.read(owner)?.map(ObjectIdentifier.init), [ObjectIdentifier(child)])
    }

    @MainActor
    func testNonthrowingDeleteLeavesDeniedOwnerUntouched() throws {
        let owner = DeleteRuleOwner(name: "A")
        let child = DeleteRuleChild(name: "B")
        let container = try ModelContainer(for: DeleteRuleOwner.self, DeleteRuleChild.self)
        let context = ModelContext(testSave: {}, container: container)
        context.insert(owner)
        context.insert(child)
        try context.save()
        let adapter = try XCTUnwrap(container.relationshipAdapters(for: DeleteRuleOwner.self).first)
        try adapter.write([child], to: owner)

        context.delete(owner)
        XCTAssertFalse(owner.isDeleted)
        XCTAssertFalse(context.deletedModelsArray.contains { $0 === owner })
        try context.processPendingChanges()

        XCTAssertTrue(owner.modelContext === context)
        XCTAssertFalse(owner.isDeleted)
        XCTAssertEqual(adapter.read(owner)?.map(ObjectIdentifier.init), [ObjectIdentifier(child)])
    }

    @MainActor
    func testDeleteCascadeSchedulesRelatedModel() throws {
        let owner = CascadeOwner(name: "A")
        let child = DeleteRuleChild(name: "B")
        let container = try ModelContainer(for: CascadeOwner.self, DeleteRuleChild.self)
        let context = ModelContext(testSave: {}, container: container)
        context.insert(owner)
        context.insert(child)
        try context.save()
        let adapter = try XCTUnwrap(container.relationshipAdapters(for: CascadeOwner.self).first)
        XCTAssertEqual(adapter.metadata?.deleteRule, .cascade)
        try adapter.write([child], to: owner)
        XCTAssertEqual(adapter.read(owner)?.count, 1)
        XCTAssertEqual(owner.children.count, 1)

        context.delete(owner)
        XCTAssertTrue(context.deletedModelsArray.contains { $0 === owner })
        XCTAssertTrue(owner.isDeleted)
        try context.processPendingChanges()

        XCTAssertTrue(context.deletedModelsArray.contains { $0 === owner })
        XCTAssertTrue(context.deletedModelsArray.contains { $0 === child })
        XCTAssertTrue(child.isDeleted)
        XCTAssertTrue(child.modelContext === context)
    }

    @MainActor
    func testDeleteRuleProcessingIsIdempotent() throws {
        let owner = NoActionOwner(name: "A")
        let child = DeleteRuleChild(name: "B")
        let container = try ModelContainer(for: NoActionOwner.self, DeleteRuleChild.self)
        let context = ModelContext(testSave: {}, container: container)
        context.insert(owner)
        context.insert(child)
        try context.save()
        try XCTUnwrap(container.relationshipAdapters(for: NoActionOwner.self).first).write([child], to: owner)

        context.delete(owner)
        XCTAssertTrue(context.deletedModelsArray.contains { $0 === owner })
        let deletedIDs = context.deletedModelsArray.map(ObjectIdentifier.init)
        let eventsBefore = context.state.relationshipMutations.count
        try context.processPendingChanges()

        XCTAssertEqual(context.deletedModelsArray.map(ObjectIdentifier.init), deletedIDs)
        XCTAssertEqual(context.state.relationshipMutations.count, eventsBefore)
    }

    @MainActor
    func testCascadeDeleteRollsBackAllEndpointsInFailedTransaction() throws {
        let owner = CascadeOwner(name: "A")
        let child = DeleteRuleChild(name: "B")
        let container = try ModelContainer(for: CascadeOwner.self, DeleteRuleChild.self)
        let context = ModelContext(testSave: {}, container: container)
        context.insert(owner)
        context.insert(child)
        try context.save()
        try XCTUnwrap(container.relationshipAdapters(for: CascadeOwner.self).first).write([child], to: owner)

        XCTAssertThrowsError(
            try context.transaction {
                context.delete(owner)
                XCTAssertTrue(owner.isDeleted)
                XCTAssertTrue(context.deletedModelsArray.contains { $0 === owner })
                throw SwiftDataError.unsupportedSchemaProperty("expected rollback")
            })

        XCTAssertTrue(owner.modelContext === context)
        XCTAssertTrue(child.modelContext === context)
        XCTAssertFalse(owner.isDeleted)
        XCTAssertFalse(child.isDeleted)
        XCTAssertTrue(context.deletedModelsArray.isEmpty)
        XCTAssertTrue(owner.children.contains { $0 === child })
    }

    @MainActor
    func testDeleteNullifyClearsInverseBeforeReturn() throws {
        let owner = NullifyOwner(name: "A")
        let child = DeleteRuleChild(name: "B")
        let container = try ModelContainer(for: NullifyOwner.self, DeleteRuleChild.self)
        let context = ModelContext(testSave: {}, container: container)
        context.insert(owner)
        context.insert(child)
        try context.save()
        try XCTUnwrap(container.relationshipAdapters(for: NullifyOwner.self).first).write([child], to: owner)

        context.delete(owner)

        XCTAssertNil(child.owner)
    }

    @MainActor
    func testDeleteNullifyWriteFailureLeavesDeleteAndRelationshipUntouched() throws {
        let holder = GraphHolder(name: "H")
        let badge = GraphBadge(holder: holder)
        let container = try ModelContainer(for: GraphHolder.self, GraphBadge.self)
        container.mainContext.insert(holder)
        container.mainContext.insert(badge)
        let badges = try XCTUnwrap(container.relationshipAdapters(for: GraphHolder.self).first)
        try badges.write([badge], to: holder)

        XCTAssertThrowsError(try badges.write([GraphBadge](), to: holder))
        XCTAssertEqual(holder.badges.map(ObjectIdentifier.init), [ObjectIdentifier(badge)])
        XCTAssertTrue(badge.holder === holder)
        XCTAssertTrue(container.mainContext.state.relationshipMutations.contains { $0.owner === holder })
    }

    @MainActor
    func testDeleteNoActionLeavesRelationshipUntouched() throws {
        let owner = NoActionOwner(name: "A")
        let child = DeleteRuleChild(name: "B")
        let container = try ModelContainer(for: NoActionOwner.self, DeleteRuleChild.self)
        let context = ModelContext(testSave: {}, container: container)
        context.insert(owner)
        context.insert(child)
        try context.save()
        let adapter = try XCTUnwrap(container.relationshipAdapters(for: NoActionOwner.self).first)
        XCTAssertEqual(adapter.metadata?.deleteRule, .noAction)
        try adapter.write([child], to: owner)
        XCTAssertEqual(adapter.read(owner)?.count, 1)
        XCTAssertEqual(owner.children.count, 1)

        context.delete(owner)

        XCTAssertTrue(owner.children.contains { $0 === child })
        XCTAssertTrue(context.deletedModelsArray.contains { $0 === owner })
        XCTAssertFalse(context.deletedModelsArray.contains { $0 === child })
    }
}

@Model
private final class RetentionPerson {
    var name: String
    @Relationship var pets: [RetentionPet] = []
    init(name: String) { self.name = name }
}

@Model
private final class RetentionPet {
    var name: String
    init(name: String) { self.name = name }
}

@Model
private final class InferredOwner {
    var targets: [InferredTarget] = []
}

@Model
private final class InferredTarget {}

@Model
private final class ScalarCollections {
    var strings: [String] = []
    var stringSet: Set<String> = []
    var count = 1
}

private final class ManualInverseSource: RelationshipModel {
    @Relationship(inverse: \ManualInverseDestination.source)
    var destination: ManualInverseDestination?
    var persistentBackingData: any BackingData<ManualInverseSource>

    required init(backingData: any BackingData<ManualInverseSource>) {
        persistentBackingData = backingData
    }

    static func schemaMetadata() -> [Schema.PropertyMetadata] {
        [
            Schema.PropertyMetadata(
                name: "destination",
                keypath: \ManualInverseSource.destination,
                metadata: Schema.Relationship(inverseName: "source")
            )
        ]
    }

    static func createBackingData() -> DetachedBackingData<ManualInverseSource> {
        DetachedBackingData(metadata: schemaMetadata())
    }

    static func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] {
        [
            RelationshipAdapterBox<ManualInverseSource>(
                TypedRelationshipPropertyAdapter<
                    ManualInverseSource, ManualInverseDestination?, ManualInverseDestination
                >(
                    "destination",
                    keyPath: \.destination,
                    metadata: Schema.Relationship(inverseName: "source"),
                    read: { $0.destination },
                    endpoints: { $0.map { [$0] } ?? [] },
                    build: { $0.first },
                    isToMany: false
                )
            )
        ]
    }
}

private final class ManualInverseDestination: RelationshipModel {
    var source: ManualInverseSource?
    var persistentBackingData: any BackingData<ManualInverseDestination>

    required init(backingData: any BackingData<ManualInverseDestination>) {
        persistentBackingData = backingData
    }

    static func schemaMetadata() -> [Schema.PropertyMetadata] {
        [
            Schema.PropertyMetadata(
                name: "source",
                keypath: \ManualInverseDestination.source,
                metadata: Schema.Relationship(inverseName: "destination")
            )
        ]
    }

    static func createBackingData() -> DetachedBackingData<ManualInverseDestination> {
        DetachedBackingData(metadata: schemaMetadata())
    }

    static func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] {
        [
            RelationshipAdapterBox<ManualInverseDestination>(
                TypedRelationshipPropertyAdapter<ManualInverseDestination, ManualInverseSource?, ManualInverseSource>(
                    "source",
                    keyPath: \.source,
                    metadata: Schema.Relationship(inverseName: "destination"),
                    read: { $0.source },
                    endpoints: { $0.map { [$0] } ?? [] },
                    build: { $0.first },
                    isToMany: false
                )
            )
        ]
    }
}

private final class MissingCandidateOwner: RelationshipModel {
    @Relationship var targets: [InferredTarget] = []
    var persistentBackingData: any BackingData<MissingCandidateOwner>

    required init(backingData: any BackingData<MissingCandidateOwner>) {
        persistentBackingData = backingData
    }

    static func schemaMetadata() -> [Schema.PropertyMetadata] {
        [Schema.PropertyMetadata(name: "targets", keypath: \MissingCandidateOwner.targets)]
    }

    static func createBackingData() -> DetachedBackingData<MissingCandidateOwner> {
        DetachedBackingData(metadata: schemaMetadata())
    }

    static func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] {
        [
            RelationshipAdapterBox<MissingCandidateOwner>(
                TypedRelationshipPropertyAdapter<MissingCandidateOwner, [InferredTarget], InferredTarget>(
                    "different", keyPath: \.targets, read: { $0.targets }, endpoints: { $0 }, build: { $0 },
                    isToMany: true))
        ]
    }
}

private final class LegacyPersistentOwner: PersistentModel {
    @Relationship var targets: [InferredTarget] = []
    var persistentBackingData: any BackingData<LegacyPersistentOwner>

    required init(backingData: any BackingData<LegacyPersistentOwner>) {
        persistentBackingData = backingData
    }

    static func schemaMetadata() -> [Schema.PropertyMetadata] {
        [Schema.PropertyMetadata(name: "targets", keypath: \LegacyPersistentOwner.targets)]
    }

    static func createBackingData() -> DetachedBackingData<LegacyPersistentOwner> {
        DetachedBackingData(metadata: schemaMetadata())
    }
}

private final class DuplicateCandidateOwner: RelationshipModel {
    @Relationship(inverse: nil) var targets: [InferredTarget] = []
    var persistentBackingData: any BackingData<DuplicateCandidateOwner>

    required init(backingData: any BackingData<DuplicateCandidateOwner>) {
        persistentBackingData = backingData
    }

    static func schemaMetadata() -> [Schema.PropertyMetadata] {
        [Schema.PropertyMetadata(name: "targets", keypath: \DuplicateCandidateOwner.targets)]
    }

    static func createBackingData() -> DetachedBackingData<DuplicateCandidateOwner> {
        DetachedBackingData(metadata: schemaMetadata())
    }

    static func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] {
        [false, true].map { _ in
            RelationshipAdapterBox<DuplicateCandidateOwner>(
                TypedRelationshipPropertyAdapter<DuplicateCandidateOwner, [InferredTarget], InferredTarget>(
                    "targets",
                    keyPath: \.targets,
                    read: { $0.targets },
                    endpoints: { $0 },
                    build: { $0 },
                    isToMany: true
                )
            )
        }
    }
}

@Model
private final class GraphPerson {
    var name: String
    @Relationship var pet: GraphPet?
    @Relationship var pets: [GraphPet] = []
    init(name: String) { self.name = name }
}

@Model
private final class GraphPet {
    var name: String
    @Relationship(inverse: \GraphPerson.pets) var owner: GraphPerson?
    @Relationship var friends: [GraphPet] = []
    init(name: String) { self.name = name }
}

@Model
private final class GraphNode {
    var name: String
    @Relationship(inverse: \GraphNode.children) var parent: GraphNode?
    var children: [GraphNode] = []
    init(name: String) { self.name = name }
}

@Model
private final class GraphHolder {
    var name: String
    @Relationship var badges: [GraphBadge] = []
    init(name: String) { self.name = name }
}

@Model
private final class GraphBadge {
    @Relationship(inverse: \GraphHolder.badges) var holder: GraphHolder
    init(holder: GraphHolder) { self.holder = holder }
}

@Model
private final class DeleteRuleOwner {
    var name: String
    @Relationship(deleteRule: .deny, inverse: nil) var children: [DeleteRuleChild] = []
    init(name: String) { self.name = name }
}

@Model
private final class DeleteRuleChild {
    var name: String
    @Relationship var owner: DeleteRuleOwner?
    init(name: String) { self.name = name }
}

@Model
private final class NoActionOwner {
    var name: String
    @Relationship(deleteRule: .noAction, inverse: nil) var children: [DeleteRuleChild] = []
    init(name: String) { self.name = name }
}

@Model
private final class CascadeOwner {
    var name: String
    @Relationship(deleteRule: .cascade, inverse: nil) var children: [DeleteRuleChild] = []
    init(name: String) { self.name = name }
}

@Model
private final class NullifyOwner {
    var name: String
    @Relationship(deleteRule: .nullify, inverse: nil) var children: [DeleteRuleChild] = []
    init(name: String) { self.name = name }
}
