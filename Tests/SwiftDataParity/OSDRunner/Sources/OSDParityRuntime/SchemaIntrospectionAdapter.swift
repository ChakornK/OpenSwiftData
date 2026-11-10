import Foundation
import OpenSwiftData
import ParityContracts

@Model
final class IntrospectionAuthor {
    @Attribute(.unique) var handle: String
    var bio: String?
    @Relationship(deleteRule: .cascade, inverse: \IntrospectionBook.author) var books: [IntrospectionBook] = []

    init(handle: String) { self.handle = handle }
}

@Model
final class IntrospectionBook {
    #Index<IntrospectionBook>([\.title])
    var title: String
    var author: IntrospectionAuthor?

    init(title: String) { self.title = title }
}

@MainActor
public enum OSDSchemaIntrospectionAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        try SchemaIntrospectionScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    private static func runAndValidate(_ specification: SchemaIntrospectionSpecification) throws -> ScenarioResult {
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
        let result = ScenarioResult(
            id: specification.id,
            observations: observations.sorted { $0.key < $1.key }.enumerated().map { step, pair in
                ParityObservation(step: step, field: pair.key, value: pair.value)
            })
        guard validateOSDObservations(result, against: specification) else {
            throw ScenarioExpectationError(id: specification.id, observations: result.observations)
        }
        return result
    }

    private static func validateOSDObservations(
        _ result: ScenarioResult,
        against specification: SchemaIntrospectionSpecification
    ) -> Bool {
        SchemaIntrospectionExpectationValidator.validate(result, against: specification)
    }

    private static func entityObservations(in schema: Schema) throws -> [String: ObservedValue] {
        let author = try requireEntity("IntrospectionAuthor", in: schema)
        let book = try requireEntity("IntrospectionBook", in: schema)
        return [
            "author.entityName": .string(Schema.entityName(for: IntrospectionAuthor.self)),
            "author.entitiesLookup": .bool(schema.entity(for: IntrospectionAuthor.self) != nil),
            "author.attributes": .unorderedStrings(author.attributesByName.keys.map { $0 }),
            "author.relationships": .unorderedStrings(author.relationshipsByName.keys.map { $0 }),
            "author.properties": .unorderedStrings(author.properties.map(\.name)),
            "book.entityName": .string(book.name),
            "book.entitiesLookup": .bool(schema.entity(for: IntrospectionBook.self) != nil),
            "entities.names": .unorderedStrings(schema.entities.map(\.name)),
        ]
    }

    private static func propertyObservations(in schema: Schema) throws -> [String: ObservedValue] {
        let author = try requireEntity("IntrospectionAuthor", in: schema)
        let book = try requireEntity("IntrospectionBook", in: schema)
        let handle = try requireAttribute("handle", in: author)
        let books = try requireRelationship("books", in: author)
        let authorRelationship = try requireRelationship("author", in: book)
        return [
            "author.handle.flags": .object([
                "attribute": .bool(handle.isAttribute), "relationship": .bool(handle.isRelationship),
                "unique": .bool(handle.isUnique), "optional": .bool(handle.isOptional),
                "transient": .bool(handle.isTransient), "transformable": .bool(handle.isTransformable),
            ]),
            "author.bio.optional": .bool(try requireAttribute("bio", in: author).isOptional),
            "author.books.flags": .object([
                "relationship": .bool(books.isRelationship), "attribute": .bool(books.isAttribute),
                "toOne": .bool(books.isToOneRelationship), "inverse": .string(books.inverseName ?? ""),
                "deleteRule": .string(deleteRuleName(books.deleteRule)),
            ]),
            "book.author.toOne": .bool(authorRelationship.isToOneRelationship),
        ]
    }

    private static func constraintObservations(in schema: Schema) -> [String: ObservedValue] {
        let author = schema.entities.first { $0.name == "IntrospectionAuthor" }
        let book = schema.entities.first { $0.name == "IntrospectionBook" }
        return [
            "author.uniquenessConstraints": .array((author?.uniquenessConstraints ?? []).map {
                .array($0.map(ObservedValue.string))
            }),
            "book.indices": .array((book?.indices ?? []).map { .array($0.map(ObservedValue.string)) }),
            "entities.names": .unorderedStrings(schema.entities.map(\.name)),
        ]
    }

    private static func roundTripObservations(of schema: Schema) throws -> [String: ObservedValue] {
        let url = FileManager.default.temporaryDirectory.appending(path: "osd-parity-schema-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try schema.save(to: url)
        let loaded = try Schema.load(from: url)
        let author = try requireEntity("IntrospectionAuthor", in: loaded)
        let book = try requireEntity("IntrospectionBook", in: loaded)
        return [
            "roundTrip.version": .array([
                .integer(Int64(loaded.version.major)), .integer(Int64(loaded.version.minor)),
                .integer(Int64(loaded.version.patch)),
            ]),
            "roundTrip.entities": .unorderedStrings(loaded.entities.map(\.name)),
            "roundTrip.author.properties": .unorderedStrings(author.properties.map(\.name)),
            "roundTrip.author.uniquenessConstraints": .array(author.uniquenessConstraints.map {
                .array($0.map(ObservedValue.string))
            }),
            "roundTrip.book.indices": .array(book.indices.map { .array($0.map(ObservedValue.string)) }),
            "roundTrip.entities.names": .unorderedStrings(loaded.entities.map(\.name)),
        ]
    }

    private static func requireEntity(_ name: String, in schema: Schema) throws -> Schema.Entity {
        guard let entity = schema.entity(forName: name) else {
            throw ScenarioExpectationError(
                id: SchemaIntrospectionScenarioCatalog.entitiesByModelType.id,
                observations: [ParityObservation(step: 0, field: "missingEntity", value: .string(name))])
        }
        return entity
    }

    private static func requireAttribute(_ name: String, in entity: Schema.Entity) throws -> Schema.Attribute {
        guard let attribute = entity.attributesByName[name] else {
            throw ScenarioExpectationError(
                id: SchemaIntrospectionScenarioCatalog.propertyFlags.id,
                observations: [ParityObservation(step: 0, field: "missingAttribute", value: .string(name))])
        }
        return attribute
    }

    private static func requireRelationship(_ name: String, in entity: Schema.Entity) throws -> Schema.Relationship {
        guard let relationship = entity.relationshipsByName[name] else {
            throw ScenarioExpectationError(
                id: SchemaIntrospectionScenarioCatalog.propertyFlags.id,
                observations: [ParityObservation(step: 0, field: "missingRelationship", value: .string(name))])
        }
        return relationship
    }

    private static func deleteRuleName(_ rule: Schema.Relationship.DeleteRule) -> String {
        switch rule {
        case .noAction: "noAction"
        case .nullify: "nullify"
        case .cascade: "cascade"
        case .deny: "deny"
        }
    }
}
