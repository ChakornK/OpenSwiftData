import Foundation
import ParityContracts
import SwiftData

@available(macOS 15, *)
@Model
final class IntrospectionAuthor {
    @Attribute(.unique) var handle: String
    var bio: String?
    @Relationship(deleteRule: .cascade, inverse: \IntrospectionBook.author) var books: [IntrospectionBook] = []

    init(handle: String) { self.handle = handle }
}

@available(macOS 15, *)
@Model
final class IntrospectionBook {
    #Index<IntrospectionBook>([\.title])
    var title: String
    var author: IntrospectionAuthor?

    init(title: String) { self.title = title }
}

@MainActor
@available(macOS 15, *)
enum AppleSchemaIntrospectionAdapter {
    static func runAll() throws -> [ScenarioResult] {
        try SchemaIntrospectionScenarioCatalog.all.map(run)
            .sorted { $0.id.description < $1.id.description }
    }

    private static func run(_ specification: SchemaIntrospectionSpecification) throws -> ScenarioResult {
        let schema = Schema(
            [IntrospectionAuthor.self, IntrospectionBook.self], version: Schema.Version(2, 1, 0))
        let observations: [String: ObservedValue]
        switch specification.id {
        case SchemaIntrospectionScenarioCatalog.entitiesByModelType.id:
            observations = try entityObservations(in: schema)
        case SchemaIntrospectionScenarioCatalog.propertyFlags.id:
            observations = try propertyObservations(in: schema)
        case SchemaIntrospectionScenarioCatalog.constraintsAndIndices.id:
            observations = constraintObservations(in: schema)
        case SchemaIntrospectionScenarioCatalog.schemaRoundTrip.id:
            observations = try roundTripObservations(of: schema)
        default:
            throw ScenarioExpectationError(id: specification.id, observations: [])
        }
        return ScenarioResult(
            id: specification.id,
            observations: observations.sorted { $0.key < $1.key }.enumerated().map { step, pair in
                ParityObservation(step: step, field: pair.key, value: pair.value)
            })
    }

    private static func entityObservations(in schema: Schema) throws -> [String: ObservedValue] {
        let authorName = Schema.entityName(for: IntrospectionAuthor.self)
        let bookName = Schema.entityName(for: IntrospectionBook.self)
        let author = schema.entity(for: IntrospectionAuthor.self)
        let book = schema.entity(for: IntrospectionBook.self)
        return [
            "author.entityName": .string(authorName),
            "author.entitiesLookup": .bool(author != nil),
            "author.attributes": .unorderedStrings(author?.attributesByName.keys.map { $0 } ?? []),
            "author.relationships": .unorderedStrings(author?.relationshipsByName.keys.map { $0 } ?? []),
            "author.properties": .unorderedStrings(author?.properties.map(\.name) ?? []),
            "book.entityName": .string(bookName),
            "book.entitiesLookup": .bool(book != nil),
            "entities.names": .unorderedStrings(schema.entities.map(\.name)),
        ]
    }

    private static func propertyObservations(in schema: Schema) throws -> [String: ObservedValue] {
        let author = schema.entity(for: IntrospectionAuthor.self)
        let book = schema.entity(for: IntrospectionBook.self)
        let handle = author?.attributesByName["handle"]
        let books = author?.relationshipsByName["books"]
        let authorRelationship = book?.relationshipsByName["author"]
        return [
            "author.handle.flags": .object([
                "attribute": .bool(handle?.isAttribute ?? false), "relationship": .bool(handle?.isRelationship ?? false),
                "unique": .bool(handle?.isUnique ?? false), "optional": .bool(handle?.isOptional ?? false),
                "transient": .bool(handle?.isTransient ?? false), "transformable": .bool(handle?.isTransformable ?? false),
            ]),
            "author.bio.optional": .bool(author?.attributesByName["bio"]?.isOptional ?? false),
            "author.books.flags": .object([
                "relationship": .bool(books?.isRelationship ?? false), "attribute": .bool(books?.isAttribute ?? false),
                "toOne": .bool(books?.isToOneRelationship ?? false), "inverse": .string(books?.inverseName ?? ""),
                "deleteRule": .string(books.map { deleteRuleName($0.deleteRule) } ?? "missing"),
            ]),
            "book.author.toOne": .bool(authorRelationship?.isToOneRelationship ?? false),
        ]
    }

    private static func constraintObservations(in schema: Schema) -> [String: ObservedValue] {
        let authorName = Schema.entityName(for: IntrospectionAuthor.self)
        let bookName = Schema.entityName(for: IntrospectionBook.self)
        let author = schema.entities.first { $0.name == authorName }
        let book = schema.entities.first { $0.name == bookName }
        return [
            "author.uniquenessConstraints": .array((author?.uniquenessConstraints ?? []).map {
                .array($0.map(ObservedValue.string))
            }),
            "book.indices": .array((book?.indices ?? []).map { .array($0.map(ObservedValue.string)) }),
            "entities.names": .unorderedStrings(schema.entities.map(\.name)),
        ]
    }

    private static func roundTripObservations(of schema: Schema) throws -> [String: ObservedValue] {
        let url = FileManager.default.temporaryDirectory.appending(path: "apple-parity-schema-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try schema.save(to: url)
        let loaded = try Schema.load(from: url)
        let authorName = Schema.entityName(for: IntrospectionAuthor.self)
        let bookName = Schema.entityName(for: IntrospectionBook.self)
        let author = loaded.entities.first { $0.name == authorName }
        let book = loaded.entities.first { $0.name == bookName }
        return [
            "roundTrip.version": .array([
                .integer(Int64(loaded.version.major)), .integer(Int64(loaded.version.minor)),
                .integer(Int64(loaded.version.patch)),
            ]),
            "roundTrip.entities": .unorderedStrings(loaded.entities.map(\.name)),
            "roundTrip.author.properties": .unorderedStrings(author?.properties.map(\.name) ?? []),
            "roundTrip.author.uniquenessConstraints": .array((author?.uniquenessConstraints ?? []).map {
                .array($0.map(ObservedValue.string))
            }),
            "roundTrip.book.indices": .array((book?.indices ?? []).map { .array($0.map(ObservedValue.string)) }),
            "roundTrip.entities.names": .unorderedStrings(loaded.entities.map(\.name)),
        ]
    }

    private static func deleteRuleName(_ rule: Schema.Relationship.DeleteRule) -> String {
        switch rule {
        case .noAction: "noAction"
        case .nullify: "nullify"
        case .cascade: "cascade"
        case .deny: "deny"
        @unknown default: "unknown"
        }
    }
}
