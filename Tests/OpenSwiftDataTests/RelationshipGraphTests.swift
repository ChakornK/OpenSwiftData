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
        let events = container.mainContext.state.relationshipMutations.dropFirst(initialEvents)
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertTrue(event.owner === person)
        XCTAssertEqual(event.property, "pets")
        XCTAssertEqual(event.relationship.destination, "GraphPet")
        XCTAssertEqual(event.relationship.inverse, "owner")
        XCTAssertTrue(event.oldEndpoints.isEmpty)
        XCTAssertEqual(
            event.newEndpoints.map(ObjectIdentifier.init), [ObjectIdentifier(first), ObjectIdentifier(second)])
        XCTAssertEqual(event.newEndpointIDs, [first.persistentModelID, second.persistentModelID])
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
        let clear = try XCTUnwrap(container.mainContext.state.relationshipMutations.last)
        XCTAssertEqual(container.mainContext.state.relationshipMutations.count, countBeforeClear + 1)
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
                    "different", keyPath: \.targets, read: { $0.targets }, endpoints: { $0 }, isToMany: true))
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
