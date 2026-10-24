import XCTest
@testable import OSDCore

final class SchemaTests: XCTestCase {
    func testConstructionPreservesNamesAndMetadata() {
        let attribute = Schema.Attribute(
            name: "title",
            type: "String",
            isOptional: true,
            defaultValue: "\"untitled\"",
            options: [.unique],
            originalName: "name"
        )
        let relationship = Schema.Relationship(
            name: "stops",
            destination: "Stop",
            isToMany: true,
            inverse: "trip",
            deleteRule: .cascade,
            minimumModelCount: 1,
            maximumModelCount: 8
        )
        let entity = Schema.Entity(name: "Trip", attributes: [attribute], relationships: [relationship])
        let version = Schema.Version(version: [1, 2], identifier: "trip-v1")
        let schema = Schema([entity], version: version)

        XCTAssertEqual(schema.entities, [entity])
        XCTAssertEqual(schema.version, version)
        XCTAssertEqual(entity.name, "Trip")
        XCTAssertEqual(entity.attributes.first?.name, "title")
        XCTAssertEqual(entity.attributes.first?.type, "String")
        XCTAssertEqual(entity.attributes.first?.isOptional, true)
        XCTAssertEqual(entity.attributes.first?.defaultValue, "\"untitled\"")
        XCTAssertEqual(entity.attributes.first?.options, [.unique])
        XCTAssertEqual(entity.attributes.first?.originalName, "name")
        XCTAssertEqual(entity.relationships.first?.destination, "Stop")
        XCTAssertEqual(entity.relationships.first?.inverse, "trip")
        XCTAssertEqual(entity.relationships.first?.deleteRule, .cascade)
        XCTAssertEqual(entity.relationships.first?.minimumModelCount, 1)
        XCTAssertEqual(entity.relationships.first?.maximumModelCount, 8)
    }

    func testPropertyMetadataSupportsGeneratedMacroInitializerAndLegacyInitializer() {
        struct Model {
            let title: String
        }
        let generated = Schema.PropertyMetadata(
            name: "title",
            keypath: \Model.title,
            defaultValue: nil,
            metadata: nil
        )
        let legacy = Schema.PropertyMetadata(
            name: "legacy",
            isRelationship: true,
            defaultValue: "1",
            options: ["indexed"]
        )

        XCTAssertEqual(generated.name, "title")
        XCTAssertEqual(generated.keypath, \Model.title)
        XCTAssertNil(generated.metadata)
        XCTAssertEqual(legacy.name, "legacy")
        XCTAssertTrue(legacy.isRelationship)
        XCTAssertEqual(legacy.defaultValue, "1")
        XCTAssertEqual(legacy.options, ["indexed"])
    }

    func testTransformableOptionStoresTransformerTypeIdentifier() {
        let transformerTypeIdentifier = "Example.ArchiveTransformer"
        let option = Schema.Attribute.Option.transformable(by: transformerTypeIdentifier)
        let attribute = Schema.Attribute(name: "payload", type: "Payload", options: [option])

        XCTAssertEqual(attribute.options, [.transformable(by: transformerTypeIdentifier)])
        XCTAssertEqual(Set([option, .transformable(by: transformerTypeIdentifier)]).count, 1)
    }

    func testEntityOrderingAndLookupAreDeterministic() {
        let schema = Schema([
            Schema.Entity(name: "Trip"),
            Schema.Entity(name: "Person"),
            Schema.Entity(name: "Stop"),
        ])

        XCTAssertEqual(schema.entities.map(\.name), ["Person", "Stop", "Trip"])
        XCTAssertEqual(schema.entity(forName: "Stop")?.name, "Stop")
        XCTAssertNil(schema.entity(forName: "Unknown"))
    }

    func testEntityPreservesAttributeAndRelationshipDeclarationOrder() {
        let entity = Schema.Entity(
            name: "Trip",
            attributes: [
                Schema.Attribute(name: "zeta", type: "String"),
                Schema.Attribute(name: "alpha", type: "Int"),
            ],
            relationships: [
                Schema.Relationship(name: "zStops", destination: "Stop"),
                Schema.Relationship(name: "aOwner", destination: "Person"),
            ]
        )

        XCTAssertEqual(entity.attributes.map(\.name), ["zeta", "alpha"])
        XCTAssertEqual(entity.relationships.map(\.name), ["zStops", "aOwner"])
    }

    func testDuplicateEntityNamesArePreservedByNonthrowingInitializer() {
        let first = Schema.Entity(name: "Trip")
        let second = Schema.Entity(name: "Trip")
        let schema = Schema([first, second])

        XCTAssertEqual(schema.entities, [first, second])
        XCTAssertEqual(schema.entity(forName: "Trip"), first)
    }
}
