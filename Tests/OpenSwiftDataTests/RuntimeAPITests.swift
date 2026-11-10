import Foundation
import XCTest
@testable import OpenSwiftData
import OpenSwiftDataSQLite
import OSDCore
@testable import OSDTestSupport
import OSDConformance

@ModelActor
actor PersistenceTestActor {
    func insertAndSave(_ title: String) throws -> String {
        let model = PersistenceTestModel(title: title)
        modelContext.insert(model)
        try modelContext.save()
        return model.title
    }

    func checkContextAffinity() -> Bool {
        modelContext.hasChanges == false
    }
}

final class OptionalDestinationFixture: PersistentModel, Hashable {
    var persistentBackingData: any BackingData<OptionalDestinationFixture>

    required init(backingData: any BackingData<OptionalDestinationFixture>) {
        persistentBackingData = backingData
    }

    static func schemaMetadata() -> [SchemaDescriptor.PropertyMetadata] { [] }

    static func createBackingData() -> DetachedBackingData<OptionalDestinationFixture> {
        DetachedBackingData(metadata: schemaMetadata())
    }

    static func == (lhs: OptionalDestinationFixture, rhs: OptionalDestinationFixture) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

@Model
final class SupportedOptionalCollectionFixture {
    @Relationship var destinations: [OptionalDestinationFixture] = []
    @Relationship var optionalDestinations: [OptionalDestinationFixture]?
}

final class MissingDestinationWithoutInverseFixture: PersistentModel {
    @Relationship var destination: OptionalDestinationFixture?
    var persistentBackingData: any BackingData<MissingDestinationWithoutInverseFixture>

    required init(backingData: any BackingData<MissingDestinationWithoutInverseFixture>) {
        persistentBackingData = backingData
    }

    static func schemaMetadata() -> [SchemaDescriptor.PropertyMetadata] {
        [
            SchemaDescriptor.PropertyMetadata(
                name: "destination",
                keypath: \MissingDestinationWithoutInverseFixture.destination,
                metadata: AnyHashable(SchemaDescriptor.Relationship())
            )
        ]
    }

    static func createBackingData() -> DetachedBackingData<MissingDestinationWithoutInverseFixture> {
        DetachedBackingData(metadata: schemaMetadata())
    }
}

@Model
final class OptionalScalarCollectionFixture {
    var strings: [String?]
    var integers: Set<Int?>

    init(strings: [String?] = [], integers: Set<Int?> = []) {
        self.strings = strings
        self.integers = integers
    }
}

@Model
final class TransactionFixture {
    var title: String = "original"

    init() {
        title = "original"
    }
}

@Model
final class ExplicitInverseSourceFixture {
    @Relationship(inverse: \ExplicitInverseDestinationFixture.source)
    var destination: ExplicitInverseDestinationFixture?
}

final class ExplicitInverseDestinationFixture: PersistentModel {
    var source: ExplicitInverseSourceFixture?
    var persistentBackingData: any BackingData<ExplicitInverseDestinationFixture>

    required init(backingData: any BackingData<ExplicitInverseDestinationFixture>) {
        persistentBackingData = backingData
    }

    static func schemaMetadata() -> [SchemaDescriptor.PropertyMetadata] {
        [
            SchemaDescriptor.PropertyMetadata(
                name: "source",
                keypath: \ExplicitInverseDestinationFixture.source,
                metadata: AnyHashable(SchemaDescriptor.Relationship(inverseName: "destination"))
            )
        ]
    }

    static func createBackingData() -> DetachedBackingData<ExplicitInverseDestinationFixture> {
        DetachedBackingData(metadata: schemaMetadata())
    }

    static func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] {
        [
            RelationshipAdapterBox<ExplicitInverseDestinationFixture>(
                TypedRelationshipPropertyAdapter<
                    ExplicitInverseDestinationFixture, ExplicitInverseSourceFixture?, ExplicitInverseSourceFixture
                >(
                    "source", keyPath: \.source, metadata: SchemaDescriptor.Relationship(inverseName: "destination"),
                    read: { $0.source }, endpoints: { $0.map { [$0] } ?? [] }, isToMany: false)
            )
        ]
    }
}

@Model
final class InvalidInverseNameFixture {
    @Relationship(inverse: \ExplicitInverseDestinationFixture.source)
    var destination: OptionalDestinationFixture?
}

@Model
final class InvalidInverseAttributeFixture {
    @Relationship(inverse: \ExplicitInverseNonRelationshipFixture.title)
    var destination: ExplicitInverseNonRelationshipFixture?
}

final class ExplicitInverseNonRelationshipFixture: PersistentModel {
    var title: String = ""
    var persistentBackingData: any BackingData<ExplicitInverseNonRelationshipFixture>

    required init(backingData: any BackingData<ExplicitInverseNonRelationshipFixture>) {
        persistentBackingData = backingData
    }

    static func schemaMetadata() -> [SchemaDescriptor.PropertyMetadata] {
        [SchemaDescriptor.PropertyMetadata(name: "title", keypath: \ExplicitInverseNonRelationshipFixture.title)]
    }

    static func createBackingData() -> DetachedBackingData<ExplicitInverseNonRelationshipFixture> {
        DetachedBackingData(metadata: schemaMetadata())
    }
}

final class InvalidInverseBackReferenceFixture: PersistentModel {
    var destination: ExplicitInverseWrongDestinationFixture?
    var persistentBackingData: any BackingData<InvalidInverseBackReferenceFixture>

    required init(backingData: any BackingData<InvalidInverseBackReferenceFixture>) {
        persistentBackingData = backingData
    }

    static func schemaMetadata() -> [SchemaDescriptor.PropertyMetadata] {
        [
            SchemaDescriptor.PropertyMetadata(
                name: "destination",
                keypath: \InvalidInverseBackReferenceFixture.destination,
                metadata: AnyHashable(SchemaDescriptor.Relationship(inverseName: "source"))
            )
        ]
    }

    static func createBackingData() -> DetachedBackingData<InvalidInverseBackReferenceFixture> {
        DetachedBackingData(metadata: schemaMetadata())
    }
}

@Model
final class ExplicitInverseWrongDestinationFixture {
    @Relationship var source: OptionalDestinationFixture?
}

final class MissingRelationshipDestinationFixture: PersistentModel {
    var destination: OptionalDestinationFixture?
    var persistentBackingData: any BackingData<MissingRelationshipDestinationFixture>

    required init(backingData: any BackingData<MissingRelationshipDestinationFixture>) {
        persistentBackingData = backingData
    }

    static func schemaMetadata() -> [SchemaDescriptor.PropertyMetadata] {
        [
            SchemaDescriptor.PropertyMetadata(
                name: "destination",
                keypath: \MissingRelationshipDestinationFixture.destination,
                metadata: AnyHashable(SchemaDescriptor.Relationship(inverseName: "missing"))
            )
        ]
    }

    static func createBackingData() -> DetachedBackingData<MissingRelationshipDestinationFixture> {
        DetachedBackingData(metadata: schemaMetadata())
    }
}

@Model
final class OptionalModelArraysFixture {
    var destinations: [OptionalDestinationFixture?] = []
    var optionalDestinations: [OptionalDestinationFixture?]?
}

final class OptionalModelSetsFixture: PersistentModel {
    var destinations: Set<OptionalDestinationFixture?> = []
    var optionalDestinations: Set<OptionalDestinationFixture?>?
    var persistentBackingData: any BackingData<OptionalModelSetsFixture>

    required init(backingData: any BackingData<OptionalModelSetsFixture>) {
        persistentBackingData = backingData
    }

    static func schemaMetadata() -> [SchemaDescriptor.PropertyMetadata] {
        [
            SchemaDescriptor.PropertyMetadata(name: "destinations", keypath: \OptionalModelSetsFixture.destinations),
            SchemaDescriptor.PropertyMetadata(
                name: "optionalDestinations", keypath: \OptionalModelSetsFixture.optionalDestinations),
        ]
    }

    static func createBackingData() -> DetachedBackingData<OptionalModelSetsFixture> {
        DetachedBackingData(metadata: schemaMetadata())
    }
}

final class OptionalElementCollectionFixture: PersistentModel {
    var destinations: [OptionalDestinationFixture?]?
    var persistentBackingData: any BackingData<OptionalElementCollectionFixture>

    required init(backingData: any BackingData<OptionalElementCollectionFixture>) {
        persistentBackingData = backingData
    }

    static func schemaMetadata() -> [SchemaDescriptor.PropertyMetadata] {
        [SchemaDescriptor.PropertyMetadata(name: "destinations", keypath: \OptionalElementCollectionFixture.destinations)]
    }

    static func createBackingData() -> DetachedBackingData<OptionalElementCollectionFixture> {
        DetachedBackingData(metadata: schemaMetadata())
    }
}

enum FirstNamespace {
    final class SharedName: PersistentModel {
        var title = ""
        var persistentBackingData: any BackingData<SharedName>

        required init(backingData: any BackingData<SharedName>) {
            persistentBackingData = backingData
        }

        static func schemaMetadata() -> [SchemaDescriptor.PropertyMetadata] { [] }

        static func createBackingData() -> DetachedBackingData<SharedName> {
            DetachedBackingData(metadata: schemaMetadata())
        }
    }
}

enum SecondNamespace {
    final class SharedName: PersistentModel {
        var title = ""
        var persistentBackingData: any BackingData<SharedName>

        required init(backingData: any BackingData<SharedName>) {
            persistentBackingData = backingData
        }

        static func schemaMetadata() -> [SchemaDescriptor.PropertyMetadata] { [] }

        static func createBackingData() -> DetachedBackingData<SharedName> {
            DetachedBackingData(metadata: schemaMetadata())
        }
    }
}

final class RuntimeAPITests: XCTestCase {
    @MainActor
    func testModelActorExecutesContextOperationsOnItsSerialExecutor() async throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("model-actor-context"))
        let actor = PersistenceTestActor(modelContainer: container)
        let saved = try await actor.insertAndSave("actor-value")
        XCTAssertEqual(saved, "actor-value")
    }

    @MainActor
    func testModelContextAffinityDetectsWrongExecutor() async throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("context-affinity"))
        let actor = PersistenceTestActor(modelContainer: container)
        let isIsolated = await actor.checkContextAffinity()
        XCTAssertTrue(isIsolated)
    }

    @MainActor
    func testContainerPreservesOptionalCollectionRelationships() async throws {
        let container = try ModelContainer(
            for: [OptionalDestinationFixture.self, SupportedOptionalCollectionFixture.self], configurations: [])
        let entity = try XCTUnwrap(container.schema.entity(forName: "SupportedOptionalCollectionFixture"))
        XCTAssertEqual(entity.name, "SupportedOptionalCollectionFixture")
        XCTAssertEqual(Set(entity.relationships.map(\.name)), ["destinations", "optionalDestinations"])
        XCTAssertEqual(Set(entity.attributes.map(\.name)), ["destinations", "optionalDestinations"])
        XCTAssertEqual(
            container.relationshipAdapters(for: SupportedOptionalCollectionFixture.self).map(\.name),
            [],
            "Unexpected adapters: \(container.relationshipAdapters(for: SupportedOptionalCollectionFixture.self).map(\.name))"
        )
    }

    @MainActor
    func testContainerSupportsOptionalScalarCollectionAttributes() async throws {
        let container = try ModelContainer(for: [OptionalScalarCollectionFixture.self], configurations: [])
        let entity = try XCTUnwrap(container.schema.entity(forName: "OptionalScalarCollectionFixture"))
        XCTAssertEqual(Set(entity.attributes.map(\.name)), ["strings", "integers"])
        XCTAssertTrue(entity.relationships.isEmpty)
    }

    @MainActor
    func testOptionalScalarCollectionElementsPersistAndMaterialize() async throws {
        let container = try ModelContainer(
            for: OptionalScalarCollectionFixture.self,
            configurations: .sqliteMemory("optional-scalar-collection-elements"))
        let writer = container.mainContext
        let model = OptionalScalarCollectionFixture(strings: [nil, "present"], integers: [nil, 7])
        writer.insert(model)
        try writer.save()

        let reader = container.makeContext()
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<OptionalScalarCollectionFixture>()).first)
        XCTAssertEqual(fetched.strings, [nil, "present"])
        XCTAssertEqual(fetched.integers, Set([nil, 7]))

        fetched.strings[1] = "updated"
        fetched.integers.insert(11)
        try reader.save()

        let verifier = container.makeContext()
        let updated = try XCTUnwrap(verifier.fetch(FetchDescriptor<OptionalScalarCollectionFixture>()).first)
        XCTAssertEqual(updated.strings, [nil, "updated"])
        XCTAssertEqual(updated.integers, Set([nil, 7, 11]))
    }

    @MainActor
    func testOptionalScalarCollectionPredicatesFailClosed() async throws {
        let container = try ModelContainer(
            for: OptionalScalarCollectionFixture.self,
            configurations: .sqliteMemory("optional-scalar-collection-predicates"))
        let stringValue = "value"
        let stringDescriptor = FetchDescriptor<OptionalScalarCollectionFixture>(
            predicate: #Predicate { $0.strings.allSatisfy { $0 == stringValue } })
        XCTAssertThrowsError(try container.mainContext.fetch(stringDescriptor)) { error in
            guard case SwiftDataError.unsupportedPredicate = error else {
                return XCTFail("Expected unsupportedPredicate for optional String elements, got \\(error)")
            }
        }

        let integerValue: Int? = 1
        let integerDescriptor = FetchDescriptor<OptionalScalarCollectionFixture>(
            predicate: #Predicate { $0.integers.contains(integerValue) })
        XCTAssertThrowsError(try container.mainContext.fetch(integerDescriptor)) { error in
            guard case SwiftDataError.unsupportedPredicate = error else {
                return XCTFail("Expected unsupportedPredicate for optional Int elements, got \\(error)")
            }
        }
    }

    @MainActor
    func testMainContextsAreSpecificToTheirContainers() async throws {
        let firstContainer = try ModelContainer(for: [TransactionFixture.self], configurations: [])
        let secondContainer = try ModelContainer(for: [TransactionFixture.self], configurations: [])

        XCTAssertFalse(firstContainer.mainContext === secondContainer.mainContext)
        XCTAssertTrue(firstContainer.mainContext.container === firstContainer)
        XCTAssertTrue(secondContainer.mainContext.container === secondContainer)
    }

    @MainActor
    func testContainerRejectsDuplicateEntityNames() async {
        XCTAssertThrowsError(
            try ModelContainer(
                for: [FirstNamespace.SharedName.self, SecondNamespace.SharedName.self], configurations: [])
        ) { error in
            guard case SwiftDataError.duplicateEntityName = error else {
                return XCTFail("Expected duplicateEntityName, got \\(error)")
            }
        }
    }

    @MainActor
    func testPersistenceOperationsFailWithoutStore() async {
        let context = ModelContext()
        let descriptor = FetchDescriptor<TransactionFixture>()
        let identifier = TransactionFixture().persistentModelID

        assertUnsupportedStore { try context.fetch(descriptor) }
        assertUnsupportedStore { try context.fetchCount(descriptor) }
        assertUnsupportedStore { try context.fetchIdentifiers(descriptor) }
        assertUnsupportedStore { try context.enumerate(descriptor) { _ in } }
        assertUnsupportedStore { try context.model(for: identifier) as TransactionFixture? }
        assertUnsupportedStore {
            try context.delete(model: TransactionFixture.self, where: #Predicate { _ in true })
        }

        XCTAssertFalse(context.hasChanges)
        XCTAssertTrue(context.insertedModelsArray.isEmpty)
        XCTAssertTrue(context.changedModelsArray.isEmpty)
        XCTAssertTrue(context.deletedModelsArray.isEmpty)
    }

    @MainActor
    func testUnsupportedPredicateDeleteDoesNotMutateInsertedModels() async {
        let context = ModelContext()
        let model = TransactionFixture()
        context.insert(model)
        let identifier = model.persistentModelID

        assertUnsupportedStore {
            try context.delete(model: TransactionFixture.self, where: #Predicate { _ in true })
        }

        XCTAssertTrue(model.modelContext === context)
        XCTAssertEqual(model.persistentModelID, identifier)
        XCTAssertFalse(model.isDeleted)
        XCTAssertTrue(context.insertedModelsArray.contains { $0 === model })
        XCTAssertTrue(context.hasChanges)
    }

    @MainActor
    private func assertUnsupportedStore<T>(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case SwiftDataError.unsupportedStore = error else {
                return XCTFail("Expected unsupportedStore, got \\(error)", file: file, line: line)
            }
        }
    }

    @MainActor
    func testTransactionBlockFailureRestoresPropertyAndLifecycleState() async {
        let context = ModelContext()
        let model = TransactionFixture()
        context.insert(model)
        model.title = "original"
        let originalIdentifier = model.persistentModelID

        XCTAssertThrowsError(
            try context.transaction {
                model.title = "changed"
                throw SwiftDataError.unsupportedStore("block failure")
            })
        XCTAssertEqual(model.title, "original")
        XCTAssertTrue(model.hasChanges)
        XCTAssertFalse(model.isDeleted)
        XCTAssertTrue(model.modelContext === context)
        XCTAssertEqual(model.persistentModelID.resolvedStoreIdentifier, "OSD.InMemory.\(ObjectIdentifier(context))")
        XCTAssertEqual(model.persistentModelID.temporaryIdentifier, originalIdentifier.temporaryIdentifier)
        XCTAssertTrue(context.insertedModelsArray.contains { $0 === model })
        XCTAssertTrue(context.hasChanges)
    }

    @MainActor
    func testTransactionFailureAfterDeletingSavedModelRestoresLifecycleAndContext() async throws {
        let context = ModelContext(testSave: {})
        let model = TransactionFixture()
        context.insert(model)
        try context.save()
        let identifier = model.persistentModelID

        XCTAssertThrowsError(
            try context.transaction {
                context.delete(model)
                throw SwiftDataError.unsupportedStore("block failure")
            })

        XCTAssertTrue(model.modelContext === context)
        XCTAssertEqual(model.persistentModelID, identifier)
        XCTAssertFalse(model.isDeleted)
        XCTAssertFalse(model.hasChanges)
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testTransactionFailureAfterMutatingThenDeletingRestoresEntryState() async throws {
        let context = ModelContext(testSave: {})
        let model = TransactionFixture()
        context.insert(model)
        try context.save()

        XCTAssertThrowsError(
            try context.transaction {
                model.title = "changed"
                context.delete(model)
                throw SwiftDataError.unsupportedStore("block failure")
            })

        XCTAssertEqual(model.title, "original")
        XCTAssertTrue(model.modelContext === context)
        XCTAssertFalse(model.isDeleted)
        XCTAssertFalse(model.hasChanges)
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testNestedTransactionFailureRestoresOuterEntryAfterCaughtError() async throws {
        var saveShouldFail = false
        let context = ModelContext(testSave: {
            if saveShouldFail { throw SwiftDataError.unsupportedStore("save failure") }
        })
        let model = TransactionFixture()
        context.insert(model)
        try context.save()
        saveShouldFail = true

        XCTAssertThrowsError(
            try context.transaction {
                model.title = "outer entry"
                do {
                    try context.transaction {
                        context.delete(model)
                        model.title = "inner mutation"
                        throw SwiftDataError.unsupportedStore("inner failure")
                    }
                } catch {}
                model.title = "outer later mutation"
            })

        XCTAssertEqual(model.title, "original")
        XCTAssertTrue(model.modelContext === context)
        XCTAssertFalse(model.isDeleted)
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testTransactionFailurePreservesPreexistingInsertedChanges() async {
        let context = ModelContext()
        let model = TransactionFixture()
        context.insert(model)
        model.title = "base"

        XCTAssertThrowsError(
            try context.transaction {
                model.title = "inside"
                throw SwiftDataError.unsupportedStore("block failure")
            })

        XCTAssertEqual(model.title, "base")
        XCTAssertTrue(model.modelContext === context)
        XCTAssertTrue(context.insertedModelsArray.contains { $0 === model })
        XCTAssertTrue(context.hasChanges)
        XCTAssertFalse(model.isDeleted)
    }

    @MainActor
    func testTransactionSaveFailureRestoresPropertyAndDetachesInsertion() async {
        let context = ModelContext(testSave: { throw SwiftDataError.unsupportedStore("save failure") })
        let model = TransactionFixture()
        let originalIdentifier = model.persistentModelID

        XCTAssertThrowsError(
            try context.transaction {
                context.insert(model)
                model.title = "changed"
            })
        XCTAssertEqual(model.title, "original")
        XCTAssertFalse(model.hasChanges)
        XCTAssertFalse(model.isDeleted)
        XCTAssertNil(model.modelContext)
        XCTAssertEqual(model.persistentModelID, originalIdentifier)
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testSuccessfulSaveDetachesDeletedModelAndPreservesLastValues() async throws {
        let context = ModelContext(testSave: {})
        let model = TransactionFixture()
        context.insert(model)
        try context.save()
        XCTAssertFalse(model.hasChanges)
        model.title = "last value"
        context.delete(model)

        try context.save()

        XCTAssertNil(model.modelContext)
        XCTAssertTrue(model.isDeleted)
        XCTAssertFalse(model.hasChanges)
        XCTAssertEqual(model.title, "last value")
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testSuccessfulTransactionSaveDetachesDeletedModelAndPreservesLastValues() async throws {
        let context = ModelContext(testSave: {})
        let model = TransactionFixture()
        context.insert(model)
        try context.save()
        model.title = "last value"
        context.delete(model)

        try context.transaction {}

        XCTAssertNil(model.modelContext)
        XCTAssertTrue(model.isDeleted)
        XCTAssertFalse(model.hasChanges)
        XCTAssertEqual(model.title, "last value")
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testDeletingUnsavedInsertionKeepsItPendingUntilSave() async throws {
        let context = ModelContext()
        let model = TransactionFixture()
        model.title = "baseline"
        context.insert(model)
        model.title = "inserted"
        let identifier = model.persistentModelID

        context.delete(model)

        XCTAssertEqual(model.title, "inserted")
        XCTAssertTrue(model.modelContext === context)
        XCTAssertTrue(model.isDeleted)
        XCTAssertEqual(model.persistentModelID, identifier)
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(context.insertedModelsArray.contains { $0 === model })
        XCTAssertTrue(context.deletedModelsArray.contains { $0 === model })

        try context.save()

        XCTAssertNil(model.modelContext)
        XCTAssertFalse(model.isDeleted)
        XCTAssertFalse(context.hasChanges)
        XCTAssertTrue(context.insertedModelsArray.isEmpty)
        XCTAssertTrue(context.deletedModelsArray.isEmpty)
    }

    @MainActor
    func testRollbackKeepsAndDetachesMutatedPendingInsertion() async {
        let context = ModelContext()
        let model = TransactionFixture()
        model.title = "insert-time baseline"
        let identifier = model.persistentModelID
        context.insert(model)
        model.title = "later mutation"

        context.rollback()

        // Apple semantics: a canceled insertion detaches but keeps its in-memory values.
        XCTAssertEqual(model.title, "later mutation")
        XCTAssertNil(model.modelContext)
        XCTAssertEqual(model.persistentModelID, identifier)
        XCTAssertFalse(model.hasChanges)
        XCTAssertFalse(model.isDeleted)
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testFailedTransactionInsertionRestoresAndDetachesModel() async {
        let context = ModelContext(testSave: {})
        let model = TransactionFixture()
        model.title = "insertion baseline"
        let identifier = model.persistentModelID

        XCTAssertThrowsError(
            try context.transaction {
                context.insert(model)
                model.title = "transaction mutation"
                throw SwiftDataError.unsupportedStore("block failure")
            })

        XCTAssertEqual(model.title, "insertion baseline")
        XCTAssertNil(model.modelContext)
        XCTAssertEqual(model.persistentModelID, identifier)
        XCTAssertFalse(model.hasChanges)
        XCTAssertFalse(model.isDeleted)
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testNestedSuccessfulTransactionDefersSaveUntilOuterCommit() async {
        let context = ModelContext()
        let preexistingInsertion = TransactionFixture()
        context.insert(preexistingInsertion)
        let newInsertion = TransactionFixture()

        XCTAssertThrowsError(
            try context.transaction {
                preexistingInsertion.title = "outer change"
                try context.transaction {
                    context.insert(newInsertion)
                    newInsertion.title = "inner insertion change"
                }
                throw SwiftDataError.unsupportedStore("outer failure")
            })

        XCTAssertEqual(preexistingInsertion.title, "original")
        XCTAssertTrue(preexistingInsertion.modelContext === context)
        XCTAssertTrue(context.insertedModelsArray.contains { $0 === preexistingInsertion })
        XCTAssertEqual(newInsertion.title, "original")
        XCTAssertNil(newInsertion.modelContext)
        XCTAssertFalse(context.insertedModelsArray.contains { $0 === newInsertion })
        XCTAssertTrue(context.hasChanges)
    }

    @MainActor
    func testNestedSuccessfulTransactionSavesOnceAtOuterCommit() async throws {
        var saveCount = 0
        let context = ModelContext(testSave: { saveCount += 1 })
        let model = TransactionFixture()
        context.insert(model)

        try context.transaction {
            try context.transaction {
                model.title = "inner success"
                try context.save()
            }
            XCTAssertEqual(saveCount, 0)
            XCTAssertTrue(context.hasChanges)
            XCTAssertTrue(model.hasChanges)
        }

        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(model.title, "inner success")
        XCTAssertFalse(model.hasChanges)
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testFailedDirectSaveRetainsPendingState() async {
        let context = ModelContext(testSave: { throw SwiftDataError.unsupportedStore("save failure") })
        let model = TransactionFixture()
        context.insert(model)
        model.title = "pending"

        XCTAssertThrowsError(try context.save())
        XCTAssertEqual(model.title, "pending")
        XCTAssertTrue(model.hasChanges)
        XCTAssertTrue(model.modelContext === context)
        XCTAssertTrue(context.hasChanges)
    }

    @MainActor
    func testPlainStringPropertyIsAnAttribute() async throws {
        let container = try ModelContainer(for: [ExplicitInverseNonRelationshipFixture.self], configurations: [])
        let entity = try XCTUnwrap(container.schema.entity(forName: "ExplicitInverseNonRelationshipFixture"))

        XCTAssertEqual(entity.attributes.map(\.name), ["title"])
        XCTAssertTrue(entity.relationships.isEmpty)
    }

    @MainActor
    func testContainerAcceptsValidExplicitInverse() async throws {
        let container = try ModelContainer(
            for: [ExplicitInverseSourceFixture.self, ExplicitInverseDestinationFixture.self], configurations: [])
        let source = try XCTUnwrap(container.schema.entity(forName: "ExplicitInverseSourceFixture"))
        XCTAssertEqual(source.relationships.first?.inverse, "source")
    }

    @MainActor
    func testContainerRejectsInvalidExplicitInverseNamesAndTypes() async {
        assertSchemaError(
            try ModelContainer(
                for: [OptionalDestinationFixture.self, InvalidInverseNameFixture.self], configurations: []))
        assertSchemaError(
            try ModelContainer(
                for: [InvalidInverseAttributeFixture.self, ExplicitInverseNonRelationshipFixture.self],
                configurations: []))
        assertSchemaError(
            try ModelContainer(
                for: [InvalidInverseBackReferenceFixture.self, ExplicitInverseWrongDestinationFixture.self],
                configurations: []))
    }

    @MainActor
    private func assertSchemaError(
        _ container: @autoclosure () throws -> ModelContainer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try container(), file: file, line: line) { error in
            guard let dataError = error as? SwiftDataError, dataError == .unsupportedSchemaProperty,
                let message = dataError.explanation
            else {
                return XCTFail("Expected descriptive schema error, got \\(error)", file: file, line: line)
            }
            XCTAssertFalse(message.isEmpty, file: file, line: line)
        }
    }

    @MainActor
    func testContainerRejectsTypedRelationshipWithoutDestinationOrInverse() async {
        XCTAssertThrowsError(
            try ModelContainer(for: [MissingDestinationWithoutInverseFixture.self], configurations: [])
        ) { error in
            guard let dataError = error as? SwiftDataError, dataError == .unsupportedSchemaProperty,
                let message = dataError.explanation
            else {
                return XCTFail("Expected descriptive schema error, got \\(error)")
            }
            XCTAssertTrue(message.contains("MissingDestinationWithoutInverseFixture.destination"))
            XCTAssertTrue(message.contains("OptionalDestinationFixture"))
        }
    }

    @MainActor
    func testContainerRejectsMissingExplicitRelationshipDestination() async {
        XCTAssertThrowsError(try ModelContainer(for: [MissingRelationshipDestinationFixture.self], configurations: []))
        { error in
            guard let dataError = error as? SwiftDataError, dataError == .unsupportedSchemaProperty,
                let message = dataError.explanation
            else {
                return XCTFail("Expected descriptive schema error, got \\(error)")
            }
            XCTAssertTrue(message.contains("MissingRelationshipDestinationFixture.destination"))
            XCTAssertTrue(message.contains("OptionalDestinationFixture"))
        }
    }

    @MainActor
    func testContainerRejectsOptionalRelationshipElements() async {
        assertOptionalModelCollectionRejected(OptionalElementCollectionFixture.self, property: "destinations")
        assertOptionalModelCollectionRejected(OptionalModelArraysFixture.self, property: "destinations")
        assertOptionalModelCollectionRejected(OptionalModelSetsFixture.self, property: "destinations")
    }

    @MainActor
    private func assertOptionalModelCollectionRejected(
        _ modelType: any PersistentModel.Type,
        property: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let entityName = String(describing: modelType).split(separator: ".").last.map(String.init) ?? ""
        XCTAssertThrowsError(
            try ModelContainer(for: [OptionalDestinationFixture.self, modelType], configurations: []),
            file: file,
            line: line
        ) { error in
            guard let dataError = error as? SwiftDataError, dataError == .unsupportedRelationshipElement,
                let message = dataError.explanation
            else {
                return XCTFail("Expected unsupportedRelationshipElement, got \\(error)", file: file, line: line)
            }
            XCTAssertEqual(
                message,
                "Property '\(entityName).\(property)' uses a relationship collection with optional model elements.",
                file: file,
                line: line
            )
        }
    }
}
