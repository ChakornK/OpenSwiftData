import XCTest
@testable import OSDCore

final class SchemaTests: XCTestCase {
    func testConstructionPreservesNamesAndMetadata() {
        let attribute = SchemaDescriptor.Attribute(
            name: "title",
            type: "String",
            isOptional: true,
            defaultValue: "\"untitled\"",
            options: [.unique],
            originalName: "name"
        )
        let relationship = SchemaDescriptor.Relationship(
            name: "stops",
            destination: "Stop",
            isToMany: true,
            inverse: "trip",
            deleteRule: .cascade,
            minimumModelCount: 1,
            maximumModelCount: 8
        )
        let entity = SchemaDescriptor.Entity(name: "Trip", attributes: [attribute], relationships: [relationship])
        let version = SchemaDescriptor.Version(1, 2, 0)
        let schema = SchemaDescriptor([entity], version: version)

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

    func testRelationshipMetadataExtractsInverseFromStoredKeyPath() {
        struct Model {
            let inverse: String?
        }

        let relationship = SchemaDescriptor.Relationship(inverse: \Model.inverse)

        XCTAssertEqual(relationship.inverse, "inverse")
    }

    func testPropertyMetadataSupportsGeneratedMacroInitializerAndLegacyInitializer() {
        struct Model {
            let title: String
        }
        let generated = SchemaDescriptor.PropertyMetadata(
            name: "title",
            keypath: \Model.title,
            defaultValue: nil,
            metadata: nil
        )
        let relationship = SchemaDescriptor.PropertyMetadata(
            name: "relationship",
            keypath: \Model.title,
            metadata: AnyHashable(SchemaDescriptor.Relationship(name: "relationship", destination: "Destination"))
        )
        let legacy = SchemaDescriptor.PropertyMetadata(
            name: "legacy",
            isRelationship: true,
            defaultValue: "1",
            options: ["indexed"]
        )

        XCTAssertEqual(generated.name, "title")
        XCTAssertEqual(generated.keypath, \Model.title)
        XCTAssertNil(generated.metadata)
        XCTAssertFalse(generated.isRelationship)
        XCTAssertTrue(relationship.isRelationship)
        XCTAssertEqual(legacy.name, "legacy")
        XCTAssertTrue(legacy.isRelationship)
        XCTAssertEqual(legacy.defaultValue, "1")
        XCTAssertEqual(legacy.options, ["indexed"])
        XCTAssertEqual(Set([legacy, legacy]).count, 1)
    }

    func testGeneratedMetadataRetainsTypedDefaultAndStringifiesLegacyValue() {
        struct Model {
            let count: Int
        }
        let generated = SchemaDescriptor.PropertyMetadata(
            name: "count",
            keypath: \Model.count,
            defaultValue: 1,
            metadata: nil
        )
        let equivalent = SchemaDescriptor.PropertyMetadata(
            name: "count",
            keypath: \Model.count,
            defaultValue: 2,
            metadata: nil
        )

        XCTAssertEqual(generated.defaultValue, "1")
        XCTAssertEqual(equivalent.defaultValue, "2")
        XCTAssertEqual(generated.keypath, \Model.count)
        XCTAssertNotEqual(generated, equivalent)
        XCTAssertEqual(Set([generated, equivalent]).count, 2)
    }

    func testGeneratedMetadataPreservesTypedMetadataEqualityAndHashing() {
        struct Model {
            let value: Int
        }
        let first = SchemaDescriptor.PropertyMetadata(
            name: "value",
            keypath: \Model.value,
            defaultValue: nil,
            metadata: AnyHashable(42)
        )
        let equal = SchemaDescriptor.PropertyMetadata(
            name: "value",
            keypath: \Model.value,
            defaultValue: nil,
            metadata: AnyHashable(42)
        )
        let different = SchemaDescriptor.PropertyMetadata(
            name: "value",
            keypath: \Model.value,
            defaultValue: nil,
            metadata: AnyHashable("42")
        )

        XCTAssertEqual(first.metadata, AnyHashable(42))
        XCTAssertEqual(first, equal)
        XCTAssertEqual(Set([first, equal]).count, 1)
        XCTAssertNotEqual(first, different)
    }

    func testPropertyMetadataRetainsStringDefaultRepresentation() {
        struct Model {
            let title: String
        }
        let metadata = SchemaDescriptor.PropertyMetadata(
            name: "title",
            keypath: \Model.title,
            defaultValue: "untitled",
            metadata: nil
        )

        XCTAssertEqual(metadata.defaultValue, "untitled")
        XCTAssertEqual(String(describing: metadata.keypath!), "\\Model.title")
    }

    func testSchemaRemainsSendableWithoutPropertyMetadataStorage() {
        func requireSendable<T: Sendable>(_ value: T) {}
        requireSendable(SchemaDescriptor([]))
    }

    func testTransformableOptionStoresTransformerTypeIdentifier() {
        let transformerTypeIdentifier = "Example.ArchiveTransformer"
        let option = SchemaDescriptor.Attribute.Option.transformable(by: transformerTypeIdentifier)
        let attribute = SchemaDescriptor.Attribute(name: "payload", type: "Payload", options: [option])

        XCTAssertEqual(attribute.options, [.transformable(by: transformerTypeIdentifier)])
        XCTAssertEqual(Set([option, .transformable(by: transformerTypeIdentifier)]).count, 1)
    }

    func testEntityOrderingAndLookupAreDeterministic() {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Trip"),
            SchemaDescriptor.Entity(name: "Person"),
            SchemaDescriptor.Entity(name: "Stop"),
        ])

        XCTAssertEqual(schema.entities.map(\.name), ["Person", "Stop", "Trip"])
        XCTAssertEqual(schema.entity(forName: "Stop")?.name, "Stop")
        XCTAssertNil(schema.entity(forName: "Unknown"))
    }

    func testReconciledEntityIDsPreserveStoredIDsAndAppendNewHierarchyEntities() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Animal"),
            SchemaDescriptor.Entity(name: "Dog", superentityName: "Animal"),
            SchemaDescriptor.Entity(name: "Zebra", superentityName: "Animal"),
            SchemaDescriptor.Entity(name: "Cat", superentityName: "Animal"),
            SchemaDescriptor.Entity(name: "Kitten", superentityName: "Cat"),
        ])

        let reconciled = try schema.reconciled(with: ["Animal": 1, "Dog": 2, "Zebra": 3])

        XCTAssertEqual(
            reconciled.entityIDsByName,
            ["Animal": 1, "Dog": 2, "Zebra": 3, "Cat": 4, "Kitten": 5])
        XCTAssertEqual(reconciled.entity(forID: 2)?.name, "Dog")
        XCTAssertEqual(reconciled.entity(forID: 20), nil)
        XCTAssertEqual(SchemaDescriptor(schema.entities).entityIDsByName["Cat"], 2)
        XCTAssertEqual(try schema.reconciled(with: [:]).entityIDsByName, schema.entityIDsByName)
    }

    func testReconciledEntityIDsRejectInvalidStoredMaps() {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base"),
            SchemaDescriptor.Entity(name: "Child", superentityName: "Base"),
        ])

        XCTAssertThrowsError(try schema.reconciled(with: ["Base": 1, "Unknown": 2]))
        XCTAssertThrowsError(try schema.reconciled(with: ["Base": 1, "Child": 1]))
        XCTAssertThrowsError(try schema.reconciled(with: ["Base": 0, "Child": 2]))

        let orphanSchema = SchemaDescriptor([SchemaDescriptor.Entity(name: "Orphan", superentityName: "MissingParent")])
        XCTAssertThrowsError(try orphanSchema.reconciled(with: ["Base": 1]))

        let cyclicSchema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "First", superentityName: "Second"),
            SchemaDescriptor.Entity(name: "Second", superentityName: "First"),
        ])
        XCTAssertThrowsError(try cyclicSchema.reconciled(with: ["First": 1, "Second": 2]))

        let duplicateSchema = SchemaDescriptor([SchemaDescriptor.Entity(name: "Base"), SchemaDescriptor.Entity(name: "Base")])
        XCTAssertThrowsError(try duplicateSchema.reconciled(with: ["Base": 1]))
    }

    func testEntityPreservesAttributeAndRelationshipDeclarationOrder() {
        let entity = SchemaDescriptor.Entity(
            name: "Trip",
            attributes: [
                SchemaDescriptor.Attribute(name: "zeta", type: "String"),
                SchemaDescriptor.Attribute(name: "alpha", type: "Int"),
            ],
            relationships: [
                SchemaDescriptor.Relationship(name: "zStops", destination: "Stop"),
                SchemaDescriptor.Relationship(name: "aOwner", destination: "Person"),
            ]
        )

        XCTAssertEqual(entity.attributes.map(\.name), ["zeta", "alpha"])
        XCTAssertEqual(entity.relationships.map(\.name), ["zStops", "aOwner"])
    }

    func testDuplicateEntityNamesArePreservedByNonthrowingInitializer() {
        let first = SchemaDescriptor.Entity(name: "Trip")
        let second = SchemaDescriptor.Entity(name: "Trip")
        let schema = SchemaDescriptor([first, second])

        XCTAssertEqual(schema.entities, [first, second])
        XCTAssertEqual(schema.entity(forName: "Trip"), first)
    }
}
