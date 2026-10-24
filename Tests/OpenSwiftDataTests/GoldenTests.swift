import OSDConformance
import XCTest

final class GoldenTests: XCTestCase {
    func testExistsAcceptsNamesWithAndWithoutJSONExtension() {
        let name = "nonexistent-golden-resource-9B2A61"

        XCTAssertFalse(Golden.exists(name))
        XCTAssertFalse(Golden.exists("\(name).json"))
    }
}
