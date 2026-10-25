import XCTest
import OSDCore
@testable import OSDStorage

final class SchemaBuilderTests: XCTestCase {
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
        for type in ["UUID", "Data"] {
            XCTAssertEqual(try SQLColumnType.resolve(type, property: "Item.value"), .blob)
        }
        for type in ["Decimal", "URL", "Opaque", "[String]", "Int??", "Int? ?", "Int ? ?"] {
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
        XCTAssertFalse(built.statements.contains { $0.contains("CREATE TABLE ZTRIP") && $0.contains("ZSTOPS") })
    }

    func testRejectsCollidingIdentifiers() throws {
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
                    relationships: [
                        Schema.Relationship(name: "owner", destination: "Item"),
                        Schema.Relationship(name: "OWNER", destination: "Item"),
                    ])
            ]),
            Schema([
                Schema.Entity(
                    name: "Item",
                    attributes: [Schema.Attribute(name: "id", type: "Int")],
                    relationships: [Schema.Relationship(name: "ID", destination: "Item")]
                )
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
