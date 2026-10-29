import XCTest
import OSDCore
@testable import OSDStorage

final class SchemaBuilderTests: XCTestCase {
    func testFlattenedAttributeEmitsScalarLeafColumns() throws {
        let schema = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(
                        name: "size", type: "Size", options: [.flattened],
                        components: [
                            Schema.Attribute.Component(name: "width", columnName: "size_width", type: "Int"),
                            Schema.Attribute.Component(name: "label", columnName: "size_label", type: "String"),
                        ])
                ])
        ])
        let built = try SchemaBuilder.build(schema)
        XCTAssertTrue(
            built.statements.contains(
                "CREATE TABLE ZRECORD (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, "
                    + "ZSIZE_LABEL VARCHAR, ZSIZE_WIDTH INTEGER);"))
    }

    func testFlattenedComponentColumnCollisionFailsSchemaValidation() {
        let schema = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "size_width", type: "Int"),
                    Schema.Attribute(
                        name: "size", type: "Size", options: [.flattened],
                        components: [Schema.Attribute.Component(name: "width", columnName: "size_width", type: "Int")]),
                ])
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(schema))
    }

    func testFlattenedCompositeCannotBeIndexedAsWholeAttribute() {
        let schema = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(
                        name: "size", type: "Size", options: [.flattened],
                        components: [Schema.Attribute.Component(name: "width", columnName: "size_width", type: "Int")])
                ],
                indexes: [Schema.Index(properties: ["size"])])
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(schema))
    }

    func testCompoundUniqueAndIndexDDLPreserveDeclaredColumnOrder() throws {
        let schema = Schema([
            Schema.Entity(
                name: "Pair",
                attributes: [
                    Schema.Attribute(name: "left", type: "String"),
                    Schema.Attribute(name: "right", type: "String"),
                ],
                indexes: [
                    Schema.Index(properties: ["right", "left"], isUnique: true),
                    Schema.Index(properties: ["left", "right"]),
                ])
        ])
        let statements = try SchemaBuilder.build(schema).statements
        XCTAssertEqual(
            statements.suffix(2),
            [
                "CREATE UNIQUE INDEX ZPAIR_ZRIGHT_ZLEFT_UNIQUE_INDEX ON ZPAIR (ZRIGHT, ZLEFT);",
                "CREATE INDEX ZPAIR_ZLEFT_ZRIGHT_INDEX ON ZPAIR (ZLEFT, ZRIGHT);",
            ])
    }

    func testExactDDLForSingleAndCompoundGeneratedIndexShapes() throws {
        let schema = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "rank", type: "Int"),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                indexes: [
                    Schema.Index(properties: ["rank"]),
                    Schema.Index(properties: ["label"], isUnique: true),
                    Schema.Index(properties: ["rank", "label"]),
                ])
        ])
        let indexes = try SchemaBuilder.build(schema).statements.filter {
            $0.hasPrefix("CREATE ") && $0.contains("INDEX")
        }
        XCTAssertEqual(
            indexes,
            [
                "CREATE INDEX ZRECORD_ZRANK_INDEX ON ZRECORD (ZRANK);",
                "CREATE UNIQUE INDEX ZRECORD_ZLABEL_UNIQUE_INDEX ON ZRECORD (ZLABEL);",
                "CREATE INDEX ZRECORD_ZRANK_ZLABEL_INDEX ON ZRECORD (ZRANK, ZLABEL);",
            ])
    }

    func testIndexRejectsMissingPropertiesAndCollidingGeneratedNames() {
        let missing = Schema([
            Schema.Entity(
                name: "Item", attributes: [Schema.Attribute(name: "value", type: "Int")],
                indexes: [Schema.Index(properties: ["absent"])])
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(missing))

        let collision = Schema([
            Schema.Entity(
                name: "A",
                attributes: [
                    Schema.Attribute(name: "value", type: "Int")
                ],
                relationships: [Schema.Relationship(name: "child", destination: "B")],
                indexes: [
                    Schema.Index(properties: ["child"])
                ]),
            Schema.Entity(name: "B"),
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(collision))

        let ambiguousEncoding = Schema([
            Schema.Entity(
                name: "Pair",
                attributes: [
                    Schema.Attribute(name: "a_Zb", type: "Int"),
                    Schema.Attribute(name: "a", type: "Int"),
                    Schema.Attribute(name: "b", type: "Int"),
                ],
                indexes: [
                    Schema.Index(properties: ["a_Zb"]),
                    Schema.Index(properties: ["a", "b"]),
                ])
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(ambiguousEncoding))
    }

    func testExactDDLForDocumentedSupportedShapeAndRows() throws {
        let schema = Schema([
            Schema.Entity(
                name: "Trip",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "days", type: "Int"),
                    Schema.Attribute(name: "notes", type: "String", isOptional: true),
                ]),
            Schema.Entity(
                name: "Person",
                attributes: [
                    Schema.Attribute(name: "email", type: "String", options: [.unique]),
                    Schema.Attribute(name: "age", type: "Int"),
                ]),
            Schema.Entity(
                name: "Stop",
                attributes: [
                    Schema.Attribute(name: "title", type: "String"),
                    Schema.Attribute(name: "order", type: "Int"),
                ], relationships: [Schema.Relationship(name: "trip", destination: "Trip")]),
        ])
        let built = try SchemaBuilder.build(schema)
        XCTAssertEqual(
            built.statements,
            [
                "CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);",
                "CREATE TABLE _osd_meta (key TEXT PRIMARY KEY, value BLOB);",
                "CREATE TABLE ZPERSON (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAGE INTEGER, ZEMAIL VARCHAR);",
                "CREATE UNIQUE INDEX ZPERSON_ZEMAIL_UNIQUE_INDEX ON ZPERSON (ZEMAIL);",
                "CREATE TABLE ZSTOP (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZORDER INTEGER, ZTITLE VARCHAR, ZTRIP INTEGER);",
                "CREATE INDEX ZSTOP_ZTRIP_INDEX ON ZSTOP (ZTRIP);",
                "CREATE TABLE ZTRIP (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDAYS INTEGER, ZNAME VARCHAR, ZNOTES VARCHAR);",
            ])
        XCTAssertEqual(
            built.bootstrapRows,
            [
                SchemaBootstrapRow(entityID: 1, name: "Person"),
                SchemaBootstrapRow(entityID: 2, name: "Stop"),
                SchemaBootstrapRow(entityID: 3, name: "Trip"),
            ])
        XCTAssertFalse(built.statements.contains { $0.contains("Z_METADATA") })
    }

    func testTransformableAttributesUseBlobColumns() throws {
        let schema = Schema([
            Schema.Entity(
                name: "Item",
                attributes: [
                    Schema.Attribute(
                        name: "payload", type: "CodablePayload", options: [.transformable(by: "Codec")])
                ])
        ])
        let built = try SchemaBuilder.build(schema)
        XCTAssertTrue(
            built.statements.contains(
                "CREATE TABLE ZITEM (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZPAYLOAD BLOB);"))
    }

    func testDecimalAndURLUseVarcharColumns() throws {
        let schema = Schema([
            Schema.Entity(
                name: "Item",
                attributes: [
                    Schema.Attribute(name: "amount", type: "Decimal"),
                    Schema.Attribute(name: "url", type: "URL"),
                ])
        ])

        let built = try SchemaBuilder.build(schema)

        XCTAssertTrue(
            built.statements.contains(
                "CREATE TABLE ZITEM (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAMOUNT VARCHAR, ZURL VARCHAR);"
            ))
    }

    func testSupportedTypesAndUnsupportedTypeError() throws {
        let types = ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Bool"]
        for type in types {
            XCTAssertEqual(try SQLColumnType.resolve(type, property: "Item.value"), .integer)
        }
        for type in ["Float", "Double"] {
            XCTAssertEqual(try SQLColumnType.resolve(type, property: "Item.value"), .float)
        }
        XCTAssertEqual(try SQLColumnType.resolve("Date", property: "Item.value"), .timestamp)
        XCTAssertEqual(try SQLColumnType.resolve("String?", property: "Item.value"), .varchar)
        XCTAssertEqual(try SQLColumnType.resolve("Decimal", property: "Item.value"), .varchar)
        XCTAssertEqual(try SQLColumnType.resolve("URL", property: "Item.value"), .varchar)
        for type in ["UUID", "Data"] {
            XCTAssertEqual(try SQLColumnType.resolve(type, property: "Item.value"), .blob)
        }
        XCTAssertEqual(
            try SQLColumnType.resolve(
                "CodablePayload", property: "Item.payload", options: [.transformable(by: "Codec")]),
            .blob)
        for type in ["Opaque", "[String]", "Int??", "Int? ?", "Int ? ?"] {
            XCTAssertThrowsError(try SQLColumnType.resolve(type, property: "Item.value")) { error in
                guard case SwiftDataError.unsupportedSchemaProperty = error else {
                    return XCTFail("Unexpected error: \\(error)")
                }
            }
        }
    }

    func testOptionalTypeWhitespaceAndMalformedMarkers() throws {
        XCTAssertEqual(try SQLColumnType.resolve(" Int ? ", property: "Item.value"), .integer)
        for type in ["Int??", "Int? ?", "Int ? ?", "?Int", "Int ?garbage"] {
            XCTAssertThrowsError(try SQLColumnType.resolve(type, property: "Item.value"))
        }
    }

    func testOneToOneHasOneCanonicalOwnerAcrossInputOrders() throws {
        let alpha = Schema.Entity(
            name: "Alpha",
            relationships: [Schema.Relationship(name: "beta", destination: "Beta", inverse: "alpha")]
        )
        let beta = Schema.Entity(
            name: "Beta",
            relationships: [Schema.Relationship(name: "alpha", destination: "Alpha", inverse: "beta")]
        )
        for entities in [[alpha, beta], [beta, alpha]] {
            let built = try SchemaBuilder.build(Schema(entities))
            XCTAssertTrue(
                built.statements.contains(
                    "CREATE TABLE ZALPHA (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZBETA INTEGER);"))
            XCTAssertTrue(built.statements.contains("CREATE INDEX ZALPHA_ZBETA_INDEX ON ZALPHA (ZBETA);"))
            XCTAssertFalse(built.statements.contains { $0.contains("ZBETA (Z_PK") && $0.contains("ZALPHA INTEGER") })
        }
    }

    func testTripStopsInverseToOneUsesOnlyStopForeignKey() throws {
        let trip = Schema.Entity(
            name: "Trip",
            relationships: [Schema.Relationship(name: "stops", destination: "Stop", isToMany: true, inverse: "trip")]
        )
        let stop = Schema.Entity(
            name: "Stop",
            relationships: [Schema.Relationship(name: "trip", destination: "Trip", inverse: "stops")]
        )
        let built = try SchemaBuilder.build(Schema([trip, stop]))
        XCTAssertTrue(
            built.statements.contains(
                "CREATE TABLE ZSTOP (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZTRIP INTEGER);"))
        XCTAssertTrue(
            built.statements.contains("CREATE INDEX ZSTOP_ZTRIP_INDEX ON ZSTOP (ZTRIP);"))
        XCTAssertFalse(
            built.statements.contains { $0.contains("CREATE TABLE ZTRIP") && $0.contains("ZSTOPS") })
    }

    func testAcceptsAllSupportedInverseCardinalityPairs() throws {
        let schemas: [Schema] = [
            Schema([
                Schema.Entity(
                    name: "A",
                    relationships: [Schema.Relationship(name: "b", destination: "B", inverse: "a")]
                ),
                Schema.Entity(
                    name: "B",
                    relationships: [Schema.Relationship(name: "a", destination: "A", inverse: "b")]
                ),
            ]),
            Schema([
                Schema.Entity(
                    name: "A",
                    relationships: [Schema.Relationship(name: "bs", destination: "B", isToMany: true, inverse: "a")]
                ),
                Schema.Entity(
                    name: "B",
                    relationships: [Schema.Relationship(name: "a", destination: "A", inverse: "bs")]
                ),
            ]),
            Schema([
                Schema.Entity(
                    name: "A",
                    relationships: [Schema.Relationship(name: "b", destination: "B", inverse: "as")]
                ),
                Schema.Entity(
                    name: "B",
                    relationships: [Schema.Relationship(name: "as", destination: "A", isToMany: true, inverse: "b")]
                ),
            ]),
            Schema([
                Schema.Entity(
                    name: "A",
                    relationships: [Schema.Relationship(name: "bs", destination: "B", isToMany: true, inverse: "as")]
                ),
                Schema.Entity(
                    name: "B",
                    relationships: [Schema.Relationship(name: "as", destination: "A", isToMany: true, inverse: "bs")]
                ),
            ]),
            Schema([
                Schema.Entity(
                    name: "ZParent",
                    relationships: [
                        Schema.Relationship(name: "children", destination: "AChild", isToMany: true, inverse: "parent")
                    ]
                ),
                Schema.Entity(
                    name: "AChild",
                    relationships: [Schema.Relationship(name: "parent", destination: "ZParent", inverse: "children")]
                ),
            ]),
        ]

        for schema in schemas {
            let built = try SchemaBuilder.build(schema)
            if schema.entities.contains(where: { $0.relationships.contains(where: \.isToMany) }) {
                XCTAssertTrue(built.statements.contains { $0.contains("CREATE TABLE Z_") })
            }
        }
    }

    func testRejectsMismatchedReciprocalMetadata() {
        let schema = Schema([
            Schema.Entity(
                name: "Parent",
                relationships: [
                    Schema.Relationship(name: "children", destination: "Child", isToMany: true, inverse: "parent")
                ]
            ),
            Schema.Entity(
                name: "Child",
                relationships: [
                    Schema.Relationship(name: "parent", destination: "Parent", isToMany: true, inverse: "wrongName")
                ]
            ),
        ])

        XCTAssertThrowsError(try SchemaBuilder.build(schema)) { error in
            guard case SwiftDataError.unsupportedSchemaProperty = error else {
                return XCTFail("Unexpected error: \\(error)")
            }
        }
    }

    func testToManyWithoutInverseUsesOwnerJoinTable() throws {
        let entity = Schema.Entity(
            name: "Owner",
            relationships: [Schema.Relationship(name: "items", destination: "Item", isToMany: true)]
        )
        let item = Schema.Entity(name: "Item")

        let built = try SchemaBuilder.build(Schema([item, entity]))
        XCTAssertEqual(
            built.statements.suffix(3),
            [
                "CREATE TABLE Z_OWNER_ITEMS_ITEM (Z_A INTEGER, Z_B INTEGER);",
                "CREATE UNIQUE INDEX Z_OWNER_ITEMS_ITEM_UNIQUE_INDEX ON Z_OWNER_ITEMS_ITEM (Z_A, Z_B);",
                "CREATE INDEX Z_OWNER_ITEMS_ITEM_Z_B_INDEX ON Z_OWNER_ITEMS_ITEM (Z_B);",
            ]
        )
    }

    func testRejectsMalformedRelationshipMetadata() throws {
        var invalidSchemas: [Schema] = [
            Schema([
                Schema.Entity(
                    name: "Item",
                    relationships: [Schema.Relationship(name: "owner", destination: "Missing")])
            ]),
            Schema([
                Schema.Entity(
                    name: "Item",
                    relationships: [Schema.Relationship(name: "owner", destination: "Owner", inverse: "items")]),
                Schema.Entity(name: "Owner"),
            ]),
            Schema([
                Schema.Entity(
                    name: "Item",
                    relationships: [Schema.Relationship(name: "owner", destination: "Owner", inverse: "items")]),
                Schema.Entity(
                    name: "Owner",
                    relationships: [
                        Schema.Relationship(
                            name: "items", destination: "Other", isToMany: true, inverse: "owner")
                    ]
                ),
                Schema.Entity(name: "Other"),
            ]),
            Schema([
                Schema.Entity(
                    name: "Item",
                    relationships: [
                        Schema.Relationship(
                            name: "items", destination: "ItemDestination", isToMany: true, inverse: "other")
                    ]
                ),
                Schema.Entity(
                    name: "ItemDestination",
                    relationships: [
                        Schema.Relationship(
                            name: "other", destination: "Item", isToMany: true, inverse: "missing")
                    ]
                ),
            ]),
            Schema([
                Schema.Entity(
                    name: "Item",
                    relationships: [
                        Schema.Relationship(
                            name: "items", destination: "Item", minimumModelCount: 2, maximumModelCount: 1)
                    ]
                )
            ]),
        ]

        invalidSchemas.append(
            Schema([
                Schema.Entity(
                    name: "Item",
                    relationships: [
                        Schema.Relationship(name: "self", destination: "Item", inverse: "self")
                    ]
                )
            ])
        )

        for (index, schema) in invalidSchemas.enumerated() {
            XCTAssertThrowsError(try SchemaBuilder.build(schema), "invalid relationship case \(index)") { error in
                guard case SwiftDataError.unsupportedSchemaProperty = error else {
                    return XCTFail("Unexpected error: \\(error)")
                }
            }
        }
    }

    func testManyToManyEmitsCanonicalJoinAfterSideAEntity() throws {
        let owner = Schema.Entity(
            name: "Owner",
            relationships: [Schema.Relationship(name: "items", destination: "Item", isToMany: true, inverse: "owners")]
        )
        let item = Schema.Entity(
            name: "Item",
            relationships: [Schema.Relationship(name: "owners", destination: "Owner", isToMany: true, inverse: "items")]
        )

        let built = try SchemaBuilder.build(Schema([item, owner]))
        XCTAssertEqual(
            built.statements,
            [
                "CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);",
                "CREATE TABLE _osd_meta (key TEXT PRIMARY KEY, value BLOB);",
                "CREATE TABLE ZITEM (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER);",
                "CREATE TABLE ZOWNER (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER);",
                "CREATE TABLE Z_ITEM_OWNERS_OWNER_ITEMS (Z_A INTEGER, Z_B INTEGER);",
                "CREATE UNIQUE INDEX Z_ITEM_OWNERS_OWNER_ITEMS_UNIQUE_INDEX ON Z_ITEM_OWNERS_OWNER_ITEMS (Z_A, Z_B);",
                "CREATE INDEX Z_ITEM_OWNERS_OWNER_ITEMS_Z_B_INDEX ON Z_ITEM_OWNERS_OWNER_ITEMS (Z_B);",
            ]
        )
    }

    func testIndexNamesAreUniqueAcrossEntityAndJoinIndexes() {
        let entities = [
            Schema.Entity(
                name: "A",
                attributes: [Schema.Attribute(name: "B_C", type: "Int", options: [.unique])],
                relationships: [Schema.Relationship(name: "b_c", destination: "A")]
            ),
            Schema.Entity(
                name: "A_B",
                relationships: [Schema.Relationship(name: "C_D", destination: "D", isToMany: true)]
            ),
            Schema.Entity(name: "C", relationships: [Schema.Relationship(name: "D", destination: "A_B")]),
            Schema.Entity(name: "D"),
        ]

        XCTAssertThrowsError(try SchemaBuilder.build(Schema(entities))) { error in
            guard case SwiftDataError.unsupportedSchemaProperty = error else {
                return XCTFail("Unexpected error: \\(error)")
            }
        }
    }

    func testRejectsCollidingIdentifiers() {
        let collisions: [Schema] = [
            Schema([Schema.Entity(name: "Thing"), Schema.Entity(name: "thing")]),
            Schema([Schema.Entity(name: "_osd_meta", attributes: [Schema.Attribute(name: "value", type: "Int")])]),
            Schema([
                Schema.Entity(
                    name: "Item",
                    attributes: [
                        Schema.Attribute(name: "name", type: "String"),
                        Schema.Attribute(name: "NAME", type: "Int"),
                    ])
            ]),
            Schema([Schema.Entity(name: "Item", attributes: [Schema.Attribute(name: "primarykey", type: "Int")])]),
            Schema([
                Schema.Entity(
                    name: "Item",
                    attributes: [Schema.Attribute(name: "id", type: "Int")],
                    relationships: [Schema.Relationship(name: "ID", destination: "Item")]
                )
            ]),
            Schema([
                Schema.Entity(
                    name: "A",
                    attributes: [Schema.Attribute(name: "index", type: "Int", options: [.unique])],
                    relationships: [Schema.Relationship(name: "index", destination: "B")]
                ),
                Schema.Entity(name: "B"),
            ]),
            Schema([
                Schema.Entity(
                    name: "A",
                    relationships: [Schema.Relationship(name: "items", destination: "B", isToMany: true)]
                ),
                Schema.Entity(name: "_A_ITEMS_B"),
                Schema.Entity(name: "B"),
            ]),
        ]
        for (index, schema) in collisions.enumerated() {
            XCTAssertThrowsError(try SchemaBuilder.build(schema), "collision case \(index)") { error in
                guard case SwiftDataError.unsupportedSchemaProperty = error else {
                    return XCTFail("Unexpected error: \\(error)")
                }
            }
        }
    }

    func testSortingUsesUTF8ByteOrder() throws {
        let schema = Schema([
            Schema.Entity(name: "é", attributes: [Schema.Attribute(name: "é", type: "String")]),
            Schema.Entity(
                name: "Z",
                attributes: [Schema.Attribute(name: "a", type: "Int"), Schema.Attribute(name: "é", type: "String")]),
        ])
        let built = try SchemaBuilder.build(schema)
        XCTAssertEqual(built.bootstrapRows.map(\.name), ["Z", "é"])
        XCTAssertTrue(
            built.statements.contains(
                "CREATE TABLE ZZ (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZA INTEGER, ZÉ VARCHAR);"
            )
        )
    }
}
