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

final class MacroDeclarationTests: XCTestCase {
    func testModelMacroCanBeAppliedInCompiledSource() {
        func requiresPersistentModel<T: PersistentModel>(_ model: T) {}
        requiresPersistentModel(ExampleModel(title: "compiled"))
    }
}
