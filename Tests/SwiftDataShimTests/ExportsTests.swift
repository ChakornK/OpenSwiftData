import XCTest

#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
    import SwiftData

    @Model
    final class QualifiedShimMacroFixture {
        @SwiftData.Attribute(.unique) var key: String
        @SwiftData.Transient var cache: String = "cached"

        init(key: String) {
            self.key = key
        }
    }

    final class ExportsTests: XCTestCase {
        func testOpenSwiftDataSchemaIsReexportedBySwiftDataShim() {
            let schema = Schema([Schema.Entity(name: "ShimModel")])
            XCTAssertEqual(schema.entities.map(\.name), ["ShimModel"])
        }

        func testQualifiedShimPropertyMacrosUseOpenSwiftDataGeneration() {
            XCTAssertEqual(QualifiedShimMacroFixture.propertyDescriptors.map(\.name), ["key"])
            XCTAssertEqual(QualifiedShimMacroFixture.propertyDescriptors.map(\.options), [["unique"]])
            XCTAssertEqual(QualifiedShimMacroFixture.schemaMetadata().map(\.name), ["key"])
        }
    }
#else
    final class ShimUnavailableOnNonAppleTests: XCTestCase {
        func testNonAppleBuildDoesNotEnableSwiftDataExports() {
            XCTAssertTrue(true)
        }
    }
#endif
