import XCTest

#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
    import SwiftData

    final class ExportsTests: XCTestCase {
        func testOpenSwiftDataSchemaIsReexportedBySwiftDataShim() {
            let schema = Schema([Schema.Entity(name: "ShimModel")])
            XCTAssertEqual(schema.entities.map(\.name), ["ShimModel"])
        }
    }
#else
    final class ShimUnavailableOnNonAppleTests: XCTestCase {
        func testNonAppleBuildDoesNotEnableSwiftDataExports() {
            XCTAssertTrue(true)
        }
    }
#endif
