import XCTest
import OpenSwiftData

final class ExportsTests: XCTestCase {
    func testSchemaTypesAreAvailableThroughOpenSwiftData() {
        let schema = Schema([Schema.Entity(name: "Trip")])

        XCTAssertEqual(schema.entities.map(\.name), ["Trip"])
        XCTAssertEqual(schema.entity(forName: "Trip")?.name, "Trip")
    }

    func testFoundationExpressionMacroIsAvailableThroughOpenSwiftData() throws {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, *) else {
            throw XCTSkip("Foundation #Expression requires Apple OS 18-era APIs")
        }
        let expression = #Expression<Int, Int> { value in value * 2 }
        XCTAssertEqual(try expression.evaluate(21), 42)
    }
}
