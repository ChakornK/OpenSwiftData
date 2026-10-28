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

    @MainActor
    func testModelActorMacroCreatesExecutorAndContext() async throws {
        let container = try ModelContainer(for: ExampleModel.self)
        let actor = ExampleModelActor(modelContainer: container)
        let usesContainer = await actor.uses(container)
        XCTAssertTrue(usesContainer)
    }
}
