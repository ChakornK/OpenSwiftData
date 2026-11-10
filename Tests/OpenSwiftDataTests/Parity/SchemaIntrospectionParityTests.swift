import Foundation
import OpenSwiftData
import Testing

@Model final class IntrospectionAuthor {
    @Attribute(.unique) var handle: String
    var bio: String?
    @Relationship(deleteRule: .cascade, inverse: \IntrospectionBook.author) var books: [IntrospectionBook] = []
    init(handle: String) { self.handle = handle }
}

@Model final class IntrospectionBook {
    #Index<IntrospectionBook>([\.title])
    var title: String
    var author: IntrospectionAuthor?
    init(title: String) { self.title = title }
}

/// Schema inspection APIs report entities and properties in the SwiftData shape.
@Suite struct SchemaIntrospectionParityTests {
    private let schema = Schema([IntrospectionAuthor.self, IntrospectionBook.self], version: Schema.Version(2, 1, 0))

    @Test func `entities are found by model type`() throws {
        #expect(Schema.entityName(for: IntrospectionAuthor.self) == "IntrospectionAuthor")
        let author = try #require(schema.entity(for: IntrospectionAuthor.self))
        #expect(author.name == "IntrospectionAuthor")
        #expect(Set(author.attributesByName.keys) == ["handle", "bio"])
        #expect(Set(author.relationshipsByName.keys) == ["books"])
        #expect(Set(author.properties.map(\.name)) == ["handle", "bio", "books"])
    }

    @Test func `property flags describe attributes and relationships`() throws {
        let author = try #require(schema.entity(for: IntrospectionAuthor.self))
        let handle = try #require(author.attributesByName["handle"])
        #expect(handle.isAttribute && !handle.isRelationship && handle.isUnique && !handle.isOptional)
        #expect(!handle.isTransient && !handle.isTransformable)
        #expect(author.attributesByName["bio"]?.isOptional == true)
        let books = try #require(author.relationshipsByName["books"])
        #expect(!books.isAttribute && !books.isRelationship && !books.isToOneRelationship)
        #expect(books.inverseName == "author")
        #expect(books.deleteRule == .cascade)
        let book = try #require(schema.entity(for: IntrospectionBook.self))
        #expect(book.relationshipsByName["author"]?.isToOneRelationship == true)
    }

    @Test func `constraints and indices are listed by property name`() throws {
        #expect(schema.entity(for: IntrospectionAuthor.self)?.uniquenessConstraints == [["handle"]])
        // Apple's schema introspection reports a synthetic `binary` column alongside each index's
        // declared properties.
        #expect(schema.entity(for: IntrospectionBook.self)?.indices == [["binary", "title"]])
    }

    @Test func `schemas round-trip through Codable and files`() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "osd-schema-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try schema.save(to: url)
        let loaded = try Schema.load(from: url)
        // Apple's Codable schema round-trip drops index metadata entirely.
        #expect(loaded.entity(for: IntrospectionBook.self)?.indices == [])
        #expect(loaded.entity(for: IntrospectionAuthor.self)?.uniquenessConstraints == [["handle"]])
        #expect(loaded.entities.map(\.name) == schema.entities.map(\.name))
    }

}
