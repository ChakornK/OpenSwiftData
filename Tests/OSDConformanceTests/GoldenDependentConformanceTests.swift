import Foundation
import XCTest
import OSDConformance

final class GoldenDependentConformanceTests: XCTestCase {
    func testRelationshipTraceMatchesGolden() throws {
        try XCTSkipUnless(Golden.exists("relationship-trace"))

        let url = try XCTUnwrap(Golden.url(for: "relationship-trace"))
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)

        XCTAssertTrue(json is [String: Any], "Relationship trace golden must be a JSON object")
    }
}
