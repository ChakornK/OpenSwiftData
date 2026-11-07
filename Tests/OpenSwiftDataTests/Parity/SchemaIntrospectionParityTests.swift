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

/// SchemaDescriptor inspection APIs report entities and properties as Apple's SwiftData does.
@Suite struct SchemaIntrospectionParityTests {
    private let schema = SchemaDescriptor([IntrospectionAuthor.self, IntrospectionBook.self], version: SchemaDescriptor.Version(2, 1, 0))

    @Test func `entities are found by model type`() throws {
        #expect(SchemaDescriptor.entityName(for: IntrospectionAuthor.self) == "IntrospectionAuthor")
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
        #expect(books.isRelationship && !books.isAttribute && !books.isToOneRelationship)
        #expect(books.inverseName == "author")
        #expect(books.deleteRule == .cascade)
        let book = try #require(schema.entity(for: IntrospectionBook.self))
        #expect(book.relationshipsByName["author"]?.isToOneRelationship == true)
    }

    @Test func `constraints and indices are listed by property name`() throws {
        #expect(schema.entity(for: IntrospectionAuthor.self)?.uniquenessConstraints == [["handle"]])
        #expect(schema.entity(for: IntrospectionBook.self)?.indices == [["title"]])
    }

    @Test func `schemas round-trip through Codable and files`() throws {
        let decoded = try JSONDecoder().decode(SchemaDescriptor.self, from: JSONEncoder().encode(schema))
        #expect(decoded == schema)
        #expect(decoded.version == SchemaDescriptor.Version(2, 1, 0))

        let url = FileManager.default.temporaryDirectory.appending(path: "osd-schema-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try schema.save(to: url)
        #expect(try SchemaDescriptor.load(from: url) == schema)
    }
}
