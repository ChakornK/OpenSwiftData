import XCTest
@testable import OSDCore

final class PropertyDescriptorTests: XCTestCase {
    func testDescriptorPreservesProvidedMetadata() {
        let descriptor = PropertyDescriptor(
            slot: 3,
            name: "email",
            keyPath: \Fixture.email,
            kind: .attribute,
            codec: FixtureCodec.self,
            options: ["unique"]
        )

        XCTAssertEqual(descriptor.slot, 3)
        XCTAssertEqual(descriptor.name, "email")
        XCTAssertEqual(descriptor.keyPath, \Fixture.email)
        XCTAssertEqual(descriptor.options, ["unique"])
        XCTAssertTrue(descriptor.kind.isAttribute)
    }

    func testRelationshipKindIsDistinctFromAttribute() {
        let descriptor = PropertyDescriptor(
            slot: 0,
            name: "owner",
            keyPath: \Fixture.owner,
            kind: .relationship,
            codec: FixtureCodec.self,
            options: []
        )

        XCTAssertTrue(descriptor.kind.isRelationship)
        XCTAssertFalse(descriptor.kind.isAttribute)
    }

    private struct Fixture {
        let email: String
        let owner: String?
    }

    private struct FixtureCodec {}
}

private extension PropertyDescriptor.Kind {
    var isAttribute: Bool {
        if case .attribute = self { return true }
        return false
    }

    var isRelationship: Bool {
        if case .relationship = self { return true }
        return false
    }
}
