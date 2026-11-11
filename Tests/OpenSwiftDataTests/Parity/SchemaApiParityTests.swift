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
        let _: [any SchemaProperty] = entity.inheritedProperties
        let _: [String: any SchemaProperty] = entity.inheritedPropertiesByName
        let _: [any SchemaProperty] = entity.storedProperties
        let _: [String: any SchemaProperty] = entity.storedPropertiesByName
        let _: Set<Schema.Entity> = entity.subentities
        #expect(true)
    }

    @Test func `Index CodingKeys and Types enums are referable`() throws {
        let _: Schema.Index.CodingKeys? = nil
        let _: Schema.Index.Types<SchemaApiThing>? = nil
        #expect(true)
    }

    @Test func `Index Types binary and rtree cases are referable`() throws {
        let binary: Schema.Index.Types<SchemaApiThing> = .binary([\.name])
        let rtree: Schema.Index.Types<SchemaApiThing> = .rtree([\.name])
        _ = (binary, rtree)
        #expect(true)
    }

    @Test func `Schema encodingVersion and schemaEncodingVersion are referable`() throws {
        let _: Schema.Version = schema.encodingVersion
        let _: Schema.Version = Schema.schemaEncodingVersion
        #expect(true)
    }
}
