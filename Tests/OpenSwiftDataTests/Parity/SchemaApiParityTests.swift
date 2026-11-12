import Foundation
import OpenSwiftData
import Testing

@Model final class SchemaApiThing {
    var name: String
    var rank: Int
    init(name: String, rank: Int) { self.name = name; self.rank = rank }
}

/// Schema-introspection API surface that OpenSwiftData does not fully
/// reimplement, referenced for parity API coverage.
struct SchemaApiParityTests {
    private let schema = Schema([Schema.Entity(name: "SchemaApiThing")], version: Schema.Version(1, 0, 0))

    @Test func `Entity computed properties are referable`() throws {
        let entity = try #require(schema.entity(forName: "SchemaApiThing"))
        #expect(entity.inheritedProperties.isEmpty)
        #expect(entity.inheritedPropertiesByName.isEmpty)
        #expect(entity.storedProperties.isEmpty)
        #expect(entity.storedPropertiesByName.isEmpty)
        #expect(entity.subentities.isEmpty)
    }

    @Test func `Index CodingKeys and Types enums are referable`() throws {
        let codingKeys: Schema.Index.CodingKeys? = nil
        let types: Schema.Index.Types<SchemaApiThing>? = nil
        #expect(codingKeys == nil)
        #expect(types == nil)
    }

    @Test func `Index Types binary and rtree cases are referable`() throws {
        let binary: Schema.Index.Types<SchemaApiThing> = .binary([\.name])
        let rtree: Schema.Index.Types<SchemaApiThing> = .rtree([\.name])
        if case .binary = binary {} else { Issue.record("expected .binary") }
        if case .rtree = rtree {} else { Issue.record("expected .rtree") }
    }

    @Test func `Schema encodingVersion and schemaEncodingVersion are referable`() throws {
        let version: Schema.Version = schema.encodingVersion
        let staticVersion: Schema.Version = Schema.schemaEncodingVersion
        #expect(version == Schema.Version(1, 0, 0))
        #expect(staticVersion == Schema.Version(1, 0, 0))
    }
}
