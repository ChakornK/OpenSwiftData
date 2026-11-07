import Foundation
import Testing
@testable import OSDCore

/// `Schema.Version` matches Apple's semantic version type.
@Suite struct SchemaVersionParityTests {
    @Test func `components and description`() {
        let version = Schema.Version(1, 2, 3)
        #expect(version.major == 1)
        #expect(version.minor == 2)
        #expect(version.patch == 3)
        #expect(version.description == "1.2.3")
        #expect(String(describing: version) == "1.2.3")
    }

    @Test func `orders numerically by component`() {
        #expect(Schema.Version(1, 2, 3) < Schema.Version(1, 10, 0))
        #expect(Schema.Version(2, 0, 0) > Schema.Version(1, 99, 99))
        #expect(Schema.Version(1, 0, 1) > Schema.Version(1, 0, 0))
        #expect(Schema.Version(1, 0, 0) == Schema.Version(1, 0, 0))
    }

    @Test func `encodes as major minor patch`() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(Schema.Version(1, 2, 3)), as: UTF8.self)
        #expect(json == #"{"major":1,"minor":2,"patch":3}"#)
        let decoded = try JSONDecoder().decode(Schema.Version.self, from: Data(json.utf8))
        #expect(decoded == Schema.Version(1, 2, 3))
    }

    @Test func `decodes stored versions in both formats`() throws {
        #expect(try Schema.Version.decode(#"{"major":2,"minor":1,"patch":0}"#) == Schema.Version(2, 1, 0))
        #expect(try Schema.Version.decode(#"{"identifier":"v2","version":[2,1]}"#) == Schema.Version(2, 1, 0))
        #expect(throws: SwiftDataError.migrationUnsupported) { try Schema.Version.decode("not json") }
    }
}
