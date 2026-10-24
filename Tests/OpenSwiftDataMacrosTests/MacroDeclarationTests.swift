import OpenSwiftData
import XCTest

@Model
final class ExampleModel {
    @Attribute(.unique) var value: Int = 0
    @Relationship(deleteRule: .cascade, inverse: \OtherModel.value) var otherModel: OtherModel?
}

@Model
final class OtherModel {
    var value: ExampleModel?
}

#Unique<ExampleModel>(\.value)
#Index<ExampleModel>(\.value)

final class MacroDeclarationTests: XCTestCase {
    func testModelMacroCanBeAppliedInCompiledSource() {
        XCTAssertTrue(ExampleModel.self == ExampleModel.self)
    }
}
