import OpenSwiftData
import XCTest

@Model()
final class ExampleModel {
    var title: String
    var count: Int = 0

    init(title: String) {
        self.title = title
    }
}

@ModelActor
actor ExampleModelActor {
    func uses(_ container: ModelContainer) -> Bool {
        modelContext.container === container
    }
}

final class MacroDeclarationTests: XCTestCase {
    func testModelMacroCanBeAppliedInCompiledSource() {
        func requiresPersistentModel<T: PersistentModel>(_ model: T) {}
        requiresPersistentModel(ExampleModel(title: "compiled"))
    }

    func testModelGeneratesStableDescriptorsAndKeyPathSlots() {
        XCTAssertEqual(ExampleModel.propertyDescriptors.map(\.slot), [0, 1])
        XCTAssertEqual(ExampleModel.propertyDescriptors.map(\.name), ["title", "count"])
        XCTAssertEqual(ExampleModel.propertyDescriptors.map(\.keyPath), [\ExampleModel.title, \ExampleModel.count])
        XCTAssertEqual(ExampleModel.propertySlot(forKeyPath: \ExampleModel.title), 0)
        XCTAssertEqual(ExampleModel.propertySlot(forKeyPath: \ExampleModel.count), 1)
        XCTAssertNil(ExampleModel.propertySlot(forKeyPath: \OtherModel.value))
    }

    func testQualifiedPropertyMacrosGenerateMatchingMetadata() {
        XCTAssertEqual(QualifiedPropertyMacroFixture.propertyDescriptors.map(\.name), ["key"])
        XCTAssertEqual(QualifiedPropertyMacroFixture.propertyDescriptors.map(\.options), [["unique"]])
        XCTAssertEqual(QualifiedPropertyMacroFixture.schemaMetadata().map(\.name), ["key"])
    }

    @MainActor
    func testQualifiedRelationshipMacroGeneratesRelationshipMetadata() throws {
        let container = try ModelContainer(for: QualifiedRelationshipMacroFixture.self, OtherModel.self)
        let relationship = try XCTUnwrap(
            container.schema.entity(forName: "QualifiedRelationshipMacroFixture")?.relationships.first)
        XCTAssertEqual(relationship.name, "target")
        XCTAssertEqual(relationship.destination, "OtherModel")
        XCTAssertEqual(relationship.deleteRule, .cascade)
        XCTAssertNil(relationship.inverse)
        XCTAssertTrue(
            QualifiedRelationshipMacroFixture.relationshipAdapterCandidates().contains { $0.name == "target" })
    }

    func testModuleSelectedPropertyMacroGeneratesUniqueMetadata() {
        XCTAssertEqual(ModuleSelectedPropertyMacroFixture.propertyDescriptors.map(\.name), ["key"])
        XCTAssertEqual(ModuleSelectedPropertyMacroFixture.propertyDescriptors.map(\.options), [["unique"]])
        XCTAssertEqual(ModuleSelectedPropertyMacroFixture.schemaMetadata().map(\.name), ["key"])
    }

    func testGeneratedSlotAccessWorksWithDetachedBackingSnapshots() {
        let model = ExampleModel(title: "before")
        model.count = 7
        let snapshot = model.snapshotLifecycle()
        model.title = "after"
        model.count = 9
        XCTAssertEqual(model.title, "after")
        XCTAssertEqual(model.count, 9)
        model.restoreLifecycle(snapshot)
        XCTAssertEqual(model.title, "before")
        XCTAssertEqual(model.count, 7)
    }

    @MainActor
    func testModelActorMacroCreatesExecutorAndContext() async throws {
        let container = try ModelContainer(for: ExampleModel.self)
        let actor = ExampleModelActor(modelContainer: container)
        let usesContainer = await actor.uses(container)
        XCTAssertTrue(usesContainer)
    }
}

@Model
final class OtherModel {
    var value: Int
}

@Model
final class QualifiedRelationshipMacroFixture {
    @OpenSwiftData.Relationship(deleteRule: .cascade, inverse: nil) var target: OtherModel?

    init(target: OtherModel?) {
        self.target = target
    }
}

@Model
final class ModuleSelectedPropertyMacroFixture {
    @OpenSwiftData::Attribute(.unique) var key: String

    init(key: String) {
        self.key = key
    }
}

@Model
final class QualifiedPropertyMacroFixture {
    @OpenSwiftData.Attribute(.unique) var key: String
    @OpenSwiftData.Transient var cache: String = "cached"

    init(key: String) {
        self.key = key
    }
}
