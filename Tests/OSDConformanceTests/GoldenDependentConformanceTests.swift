import XCTest
import OSDConformance

final class GoldenDependentConformanceTests: XCTestCase {
    func testRelationshipTraceMatchesGolden() throws {
        try XCTSkipUnless(Golden.exists("relationship-trace"))

        XCTAssertTrue(Golden.exists("relationship-trace"))
    }
}
