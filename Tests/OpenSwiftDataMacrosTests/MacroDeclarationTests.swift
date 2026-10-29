import OpenSwiftData
import XCTest

@Model
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
