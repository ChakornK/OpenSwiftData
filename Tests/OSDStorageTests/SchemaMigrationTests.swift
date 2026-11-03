import XCTest
import OSDCore
@testable import OSDStorage

final class SchemaMigrationTests: XCTestCase {
    func testSHA256MatchesKnownDigest() {
        let digest = SchemaHash.digest(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testCanonicalSchemaHashIgnoresDeclarationOrder() {
        let first = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "zeta", type: "String"),
                    Schema.Attribute(name: "alpha", type: "Int"),
                ])
        ])
        let second = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "alpha", type: "Int"),
                    Schema.Attribute(name: "zeta", type: "String"),
                ])
        ])

        XCTAssertEqual(SchemaHash.digest(first), SchemaHash.digest(second))
    }

    func testFlattenedComponentLayoutChangesSchemaHash() {
        let blob = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "size", type: "Size")])
        ])
        let flattened = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(
                        name: "size", type: "Size", options: [.flattened],
                        components: [Schema.Attribute.Component(name: "width", columnName: "size_width", type: "Int")])
                ])
        ])
        XCTAssertNotEqual(SchemaHash.digest(blob), SchemaHash.digest(flattened))
    }

    func testFlattenedComponentDeclarationOrderIsCanonicalizedByName() {
        let first = Schema([
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
        let second = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(
                        name: "size", type: "Size", options: [.flattened],
                        components: [
                            Schema.Attribute.Component(name: "label", columnName: "size_label", type: "String"),
                            Schema.Attribute.Component(name: "width", columnName: "size_width", type: "Int"),
                        ])
                ])
        ])
        XCTAssertEqual(SchemaHash.digest(first), SchemaHash.digest(second))
        XCTAssertEqual(first.entities.first?.attributes.first?.components.map(\.name), ["label", "width"])
    }

    func testExternalStorageOptionChangeRequiresExplicitMigration() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "external-storage-migration"))
        let inline = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "payload", type: "Data")])
        ])
        let external = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "payload", type: "Data", options: [.externalStorage])])
        ])
        try bootstrap(inline, driver: driver)
        XCTAssertThrowsError(
            try driver.write { connection in
                try LightweightMigration.openOrMigrate(to: external, connection: connection)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
        let columnNames = columns.compactMap { row -> String? in
            guard row.count > 1, case let .text(name) = row[1] else { return nil }
            return name
        }
        XCTAssertEqual(columnNames, ["Z_PK", "Z_ENT", "Z_OPT", "ZPAYLOAD"])
        try driver.close()
    }

    func testBlobToFlattenedAttributeMigrationFailsClosedWithoutChangingStore() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "blob-to-flattened-migration"))
        let blob = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "size", type: "Size", options: [.codable])])
        ])
        let flattened = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(
                        name: "size", type: "Size", options: [.flattened],
                        components: [Schema.Attribute.Component(name: "width", columnName: "size_width", type: "Int")])
                ])
        ])
        try bootstrap(blob, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZSIZE) VALUES (1, 1, ?)", [.blob([1, 2, 3])])
        }

        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.openOrMigrate(to: flattened, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT ZSIZE FROM ZRECORD", []) }, [[.blob([1, 2, 3])]])
        try driver.close()
    }

    func testFlattenedComponentMetadataRoundTrips() throws {
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
        let encoded = SchemaHash.canonicalDescription(of: schema)
        let decoded = try SchemaHash.decodeCanonicalDescription(encoded)
        XCTAssertEqual(schema.entities, decoded.entities)
    }

    func testSchemaParentMetadataRoundTripsAndNilRemainsCanonical() throws {
        let legacy = Schema([Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int")])])
        let explicitlyUninherited = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int")], superentityName: nil)
        ])
        XCTAssertEqual(
            SchemaHash.canonicalDescription(of: legacy), SchemaHash.canonicalDescription(of: explicitlyUninherited))
        XCTAssertEqual(SchemaHash.digest(legacy), SchemaHash.digest(explicitlyUninherited))
        XCTAssertFalse(SchemaHash.canonicalDescription(of: legacy).contains("superentityName"))
        XCTAssertEqual(
            try SchemaBuilder.build(legacy).statements,
            try SchemaBuilder.build(explicitlyUninherited).statements)

        let inherited = Schema([
            Schema.Entity(name: "Base", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "Child", attributes: [Schema.Attribute(name: "age", type: "Int")], superentityName: "Base"),
        ])
        let decoded = try SchemaHash.decodeCanonicalDescription(SchemaHash.canonicalDescription(of: inherited))
        XCTAssertEqual(decoded.entity(forName: "Child")?.superentityName, "Base")
        XCTAssertNotEqual(SchemaHash.digest(inherited), SchemaHash.digest(legacy))
    }

    func testRelationshipDeclarationOwnerChangesHashAndRoundTrips() throws {
        let baseWithoutRelationship = Schema.Entity(name: "Base")
        let baseWithRelationship = Schema.Entity(
            name: "Base",
            relationships: [Schema.Relationship(name: "target", destination: "Target")])
        let childOwns = Schema.Entity(
            name: "Child",
            relationships: [
                Schema.Relationship(
                    name: "target", destination: "Target", declaringEntityName: "Child")
            ],
            superentityName: "Base")
        let baseOwns = Schema.Entity(
            name: "Child",
            relationships: [
                Schema.Relationship(
                    name: "target", destination: "Target", declaringEntityName: "Base")
            ],
            superentityName: "Base")
        let target = Schema.Entity(name: "Target")
        let childOwnedSchema = Schema([baseWithoutRelationship, childOwns, target])
        let baseOwnedSchema = Schema([baseWithRelationship, baseOwns, target])

        XCTAssertNotEqual(SchemaHash.digest(childOwnedSchema), SchemaHash.digest(baseOwnedSchema))
        let decoded = try SchemaHash.decodeCanonicalDescription(
            SchemaHash.canonicalDescription(of: baseOwnedSchema))
        XCTAssertEqual(decoded.entities, baseOwnedSchema.entities)
        XCTAssertEqual(
            decoded.relationshipStorageMapping(modelEntityName: "Child", relationshipName: "target")?
                .declaringEntityName,
            "Base")
    }

    func testHierarchyRootIndexesChangeHashAndRoundTrip() throws {
        let withoutIndex = Schema([
            Schema.Entity(name: "Base", attributes: [Schema.Attribute(name: "code", type: "String")]),
            Schema.Entity(
                name: "Child",
                attributes: [Schema.Attribute(name: "code", type: "String")],
                superentityName: "Base"),
        ])
        let withIndex = Schema([
            Schema.Entity(
                name: "Base",
                attributes: [Schema.Attribute(name: "code", type: "String")],
                indexes: [Schema.Index(properties: ["code"], isUnique: true)]),
            Schema.Entity(
                name: "Child",
                attributes: [
                    Schema.Attribute(name: "code", type: "String"),
                    Schema.Attribute(name: "score", type: "Int", options: [.unique]),
                ],
                indexes: [
                    Schema.Index(properties: ["code"], isUnique: true),
                    Schema.Index(properties: ["score"]),
                ],
                superentityName: "Base"),
        ])

        XCTAssertNotEqual(SchemaHash.digest(withoutIndex), SchemaHash.digest(withIndex))
        let decoded = try SchemaHash.decodeCanonicalDescription(SchemaHash.canonicalDescription(of: withIndex))
        XCTAssertEqual(decoded.entities, withIndex.entities)
    }

    func testSubtypeIndexesAndUniqueAttributesChangeHierarchyHash() throws {
        let unconstrained = Schema([
            Schema.Entity(name: "Base", attributes: [Schema.Attribute(name: "token", type: "String")]),
            Schema.Entity(
                name: "Child",
                attributes: [
                    Schema.Attribute(name: "token", type: "String"), Schema.Attribute(name: "score", type: "Int"),
                ],
                superentityName: "Base"),
        ])
        let constrained = Schema([
            Schema.Entity(name: "Base", attributes: [Schema.Attribute(name: "token", type: "String")]),
            Schema.Entity(
                name: "Child",
                attributes: [
                    Schema.Attribute(name: "token", type: "String"),
                    Schema.Attribute(name: "score", type: "Int", options: [.unique]),
                ],
                indexes: [Schema.Index(properties: ["token"], isUnique: true)],
                superentityName: "Base"),
        ])

        XCTAssertNotEqual(SchemaHash.digest(unconstrained), SchemaHash.digest(constrained))
        let decoded = try SchemaHash.decodeCanonicalDescription(SchemaHash.canonicalDescription(of: constrained))
        XCTAssertEqual(SchemaHash.digest(decoded), SchemaHash.digest(constrained))
        XCTAssertEqual(decoded.entity(forName: "Child")?.indexes, constrained.entity(forName: "Child")?.indexes)
        XCTAssertTrue(
            decoded.entity(forName: "Child")?.attributes
                .first(where: { $0.name == "score" })?.options.contains(.unique) == true)
    }

    func testCanonicalHashChangesWhenEachPersistedFieldChanges() {
        let base = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Int")],
                relationships: [Schema.Relationship(name: "parent", destination: "Parent")],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let variants = [
            Schema([
                Schema.Entity(
                    name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int", isOptional: true)],
                    relationships: [Schema.Relationship(name: "parent", destination: "Parent")],
                    indexes: [Schema.Index(properties: ["value"])])
            ]),
            Schema([
                Schema.Entity(
                    name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int", defaultValue: "0")],
                    relationships: [Schema.Relationship(name: "parent", destination: "Parent")],
                    indexes: [Schema.Index(properties: ["value"])])
            ]),
            Schema([
                Schema.Entity(
                    name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int", options: [.unique])],
                    relationships: [Schema.Relationship(name: "parent", destination: "Parent")],
                    indexes: [Schema.Index(properties: ["value"])])
            ]),
            Schema([
                Schema.Entity(
                    name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int")],
                    relationships: [Schema.Relationship(name: "parent", destination: "Parent", isToMany: true)],
                    indexes: [Schema.Index(properties: ["value"])])
            ]),
            Schema([
                Schema.Entity(
                    name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int")],
                    relationships: [Schema.Relationship(name: "parent", destination: "Parent", deleteRule: .cascade)],
                    indexes: [Schema.Index(properties: ["value"])])
            ]),
            Schema([
                Schema.Entity(
                    name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int")],
                    relationships: [Schema.Relationship(name: "parent", destination: "Parent")],
                    indexes: [Schema.Index(properties: ["value"], isUnique: true)])
            ]),
        ]

        for variant in variants {
            XCTAssertNotEqual(SchemaHash.digest(base), SchemaHash.digest(variant))
        }
    }

    func testLightweightMigrationAddsOptionalAttributeAtomically() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-add-optional"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String"),
                    Schema.Attribute(name: "notes", type: "String", isOptional: true),
                ])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZTITLE) VALUES (1, 1, ?)", [.text("hello")])
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        let rows = try driver.read { try $0.rows("SELECT ZTITLE, ZNOTES FROM ZRECORD") }
        XCTAssertEqual(rows, [[.text("hello"), .null]])
        try driver.close()
    }

    func testAddingLiteralDefaultedAttributesBackfillsExistingRows() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-required-default"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String"),
                    Schema.Attribute(name: "priority", type: "Int", defaultValue: "7"),
                    Schema.Attribute(name: "label", type: "String", isOptional: true, defaultValue: "\"O'Neil\""),
                    Schema.Attribute(name: "enabled", type: "Bool", defaultValue: "true"),
                    Schema.Attribute(name: "ratio", type: "Double", defaultValue: "1.25"),
                    Schema.Attribute(name: "amount", type: "Decimal", defaultValue: "12.5"),
                ])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZTITLE) VALUES (1, 1, ?)", [.text("saved")])
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        let columns = "ZTITLE, ZPRIORITY, ZLABEL, ZENABLED, ZRATIO, ZAMOUNT"
        let rows = try driver.read { try $0.rows("SELECT \(columns) FROM ZRECORD") }
        XCTAssertEqual(rows, [[.text("saved"), .int(7), .text("O'Neil"), .int(1), .double(1.25), .text("12.5")]])
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZTITLE) VALUES (1, 1, ?)", [.text("new")])
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT \(columns) FROM ZRECORD ORDER BY Z_PK") },
            [
                [.text("saved"), .int(7), .text("O'Neil"), .int(1), .double(1.25), .text("12.5")],
                [.text("new"), .int(7), .text("O'Neil"), .int(1), .double(1.25), .text("12.5")],
            ])
        try driver.close()
    }

    func testOptionalToRequiredAttributeBackfillsNullsAndPreservesIndexedRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String"),
                    Schema.Attribute(name: "priority", type: "Int", isOptional: true, options: [.unique]),
                ],
                indexes: [Schema.Index(properties: ["title"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String"),
                    Schema.Attribute(name: "priority", type: "Int", defaultValue: "7", options: [.unique]),
                ],
                indexes: [Schema.Index(properties: ["title"])])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZTITLE, ZPRIORITY) VALUES (?, ?, ?, ?)",
                [.int(1), .int(4), .text("kept"), .int(3)])
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZTITLE, ZPRIORITY) VALUES (?, ?, ?, NULL)",
                [.int(1), .int(9), .text("backfilled")])
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let rows = try migrated.read {
            try $0.rows("SELECT Z_PK, Z_OPT, ZTITLE, ZPRIORITY FROM ZRECORD ORDER BY Z_PK")
        }
        XCTAssertEqual(
            rows,
            [
                [.int(1), .int(4), .text("kept"), .int(3)],
                [.int(2), .int(9), .text("backfilled"), .int(7)],
            ])
        let indexNames = try migrated.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'ZRECORD%'")
        }
        let storedIndexNames = indexNames.compactMap { row -> String? in
            guard case let .text(name)? = row.first else { return nil }
            return name
        }
        XCTAssertEqual(Set(storedIndexNames), ["ZRECORD_ZPRIORITY_UNIQUE_INDEX", "ZRECORD_ZTITLE_INDEX"])
        let hash = try migrated.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
            ).first?.first
        }
        XCTAssertEqual(hash, .blob(Array(SchemaHash.hexDigest(destination).utf8)))
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZPRIORITY FROM ZRECORD ORDER BY Z_PK") },
            [[.int(1), .int(4), .int(3)], [.int(2), .int(9), .int(7)]])
        try reopened.close()
    }

    func testRequiredToOptionalMetadataMigrationPreservesRowsAndAllowsNullWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("required-to-optional.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "label", type: "String"),
                    Schema.Attribute(name: "rank", type: "Int32", options: [.unique]),
                ],
                indexes: [Schema.Index(properties: ["label"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "label", type: "String"),
                    Schema.Attribute(name: "rank", type: "Int32", isOptional: true, options: [.unique]),
                ],
                indexes: [Schema.Index(properties: ["label"])])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZLABEL, ZRANK) VALUES (1, 4, 'first', 10)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZLABEL, ZRANK) VALUES (1, 9, 'second', 20)")
        }
        let allocator = try initial.read {
            try $0.rows("SELECT Z_ENT, Z_NAME, Z_SUPER, Z_MAX FROM Z_PRIMARYKEY ORDER BY Z_ENT")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT, ZLABEL, ZRANK FROM ZRECORD ORDER BY Z_PK") },
            [
                [.int(1), .int(1), .int(4), .text("first"), .int(10)],
                [.int(2), .int(1), .int(9), .text("second"), .int(20)],
            ])
        XCTAssertEqual(
            try migrated.read {
                try $0.rows("SELECT Z_ENT, Z_NAME, Z_SUPER, Z_MAX FROM Z_PRIMARYKEY ORDER BY Z_ENT")
            },
            allocator)
        let rankColumn = try migrated.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
            .first(where: { $0.count > 3 && $0[1] == .text("ZRANK") })
        XCTAssertEqual(rankColumn?[3], .int(0))
        XCTAssertEqual(
            try migrated.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD' ORDER BY name")
            },
            [[.text("ZRECORD_ZLABEL_INDEX")], [.text("ZRECORD_ZRANK_UNIQUE_INDEX")]])
        let expectedTableDDL = try XCTUnwrap(
            SchemaBuilder.build(destination).statements.first(where: { $0.hasPrefix("CREATE TABLE ZRECORD ") })
        )
        .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        XCTAssertEqual(
            try migrated.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            .text(expectedTableDDL))
        try migrated.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZLABEL, ZRANK) VALUES (1, 1, 'optional', NULL)")
        }
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, ZRANK FROM ZRECORD WHERE ZLABEL = 'optional'") },
            [[.int(3), .null]])
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(try reopened.read { try $0.rows("SELECT COUNT(*) FROM ZRECORD") }, [[.int(3)]])
        try reopened.close()
    }

    func testRequiredToOptionalMetadataMigrationRejectsCombinedEditsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "String")]),
            Schema.Entity(name: "Other"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "String", isOptional: true)]),
            Schema.Entity(
                name: "Other", attributes: [Schema.Attribute(name: "note", type: "String", isOptional: true)]),
        ])
        let location = StoreLocation.file(directory.appendingPathComponent("combined.sqlite"))
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 3, 'kept')")
        }
        let originalHash = try initial.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]).first?
                .first
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected combined schema edit to fail closed, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZVALUE FROM ZRECORD") },
            [[.int(1), .int(3), .text("kept")]])
        XCTAssertEqual(
            try reopened.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                    .first?.first
            },
            originalHash)
        try reopened.close()
    }

    func testRequiredToOptionalMetadataMigrationPreservesCustomIndexesAndTriggers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "String")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "value", type: "String", isOptional: true)])
        ])
        for (name, statement) in [
            ("index", "CREATE INDEX USER_VALUE_INDEX ON ZRECORD (ZVALUE)"),
            (
                "trigger",
                "CREATE TRIGGER USER_RECORD_TRIGGER AFTER INSERT ON ZRECORD BEGIN UPDATE ZRECORD SET Z_OPT = Z_OPT WHERE Z_PK = NEW.Z_PK; END"
            ),
        ] {
            let location = StoreLocation.file(directory.appendingPathComponent("\(name).sqlite"))
            let initial = try LightweightMigration.openStore(location: location, schema: source)
            try initial.write { connection in
                try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 5, 'kept')")
                try connection.execute(statement)
            }
            try initial.close()

            let migrated = try LightweightMigration.openStore(location: location, schema: destination)
            XCTAssertEqual(
                try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZVALUE FROM ZRECORD") },
                [[.int(1), .int(5), .text("kept")]])
            let objects = try migrated.read {
                try $0.rows("SELECT type, name FROM sqlite_master WHERE name LIKE 'USER_%' ORDER BY name")
            }
            let expectedName = name == "index" ? "USER_VALUE_INDEX" : "USER_RECORD_TRIGGER"
            let expectedType = name == "index" ? "index" : "trigger"
            XCTAssertEqual(objects, [[.text(expectedType), .text(expectedName)]])
            try migrated.write { connection in
                try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 6, NULL)")
            }
            try migrated.close()
        }
    }

    func testOptionalToRequiredBackfillUsesTypedScalarDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(String, String, String, StoredValue)] = [
            ("name", "String", "\"O'Neil\"", .text("O'Neil")),
            ("enabled", "Bool", "true", .int(1)),
            ("ratio", "Double", "1.25", .double(1.25)),
            ("amount", "Decimal", "12.5", .text("12.5")),
        ]
        for (name, type, defaultValue, expected) in cases {
            let source = Schema([
                Schema.Entity(
                    name: "Record",
                    attributes: [Schema.Attribute(name: name, type: type, isOptional: true)])
            ])
            let destination = Schema([
                Schema.Entity(
                    name: "Record",
                    attributes: [Schema.Attribute(name: name, type: type, defaultValue: defaultValue)])
            ])
            let location = StoreLocation.file(directory.appendingPathComponent("\(name).sqlite"))
            let initial = try LightweightMigration.openStore(location: location, schema: source)
            try initial.write { connection in
                let column = "Z\(name.uppercased())"
                try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, \(column)) VALUES (1, 2, NULL)")
            }
            try initial.close()

            let migrated = try LightweightMigration.openStore(location: location, schema: destination)
            let column = "Z\(name.uppercased())"
            XCTAssertEqual(try migrated.read { try $0.rows("SELECT \(column) FROM ZRECORD") }, [[expected]])
            try migrated.close()
        }

        let emptySource = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "String", isOptional: true)])
        ])
        let emptyDestination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "String", defaultValue: "\"value\"")])
        ])
        let emptyLocation = StoreLocation.file(directory.appendingPathComponent("empty.sqlite"))
        let emptyInitial = try LightweightMigration.openStore(location: emptyLocation, schema: emptySource)
        try emptyInitial.close()
        let emptyMigrated = try LightweightMigration.openStore(location: emptyLocation, schema: emptyDestination)
        XCTAssertEqual(try emptyMigrated.read { try $0.rows("SELECT COUNT(*) FROM ZRECORD") }, [[.int(0)]])
        try emptyMigrated.close()
    }

    func testMultipleOptionalAttributesBackfillTypedDefaultsTogether() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "count", type: "Int32", isOptional: true, defaultValue: "9"),
                    Schema.Attribute(name: "enabled", type: "Bool", isOptional: true, defaultValue: "true"),
                    Schema.Attribute(name: "retained", type: "String", isOptional: true),
                ],
                indexes: [Schema.Index(properties: ["retained"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "count", type: "Int32", defaultValue: "9"),
                    Schema.Attribute(name: "enabled", type: "Bool", defaultValue: "true"),
                    Schema.Attribute(name: "retained", type: "String", isOptional: true),
                ],
                indexes: [Schema.Index(properties: ["retained"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-optional-to-required-defaults"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZCOUNT, ZENABLED, ZRETAINED) VALUES (1, 3, NULL, NULL, NULL)")
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZCOUNT, ZENABLED, ZRETAINED) VALUES (1, 7, 4, 0, 'kept')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT Z_PK, Z_OPT, ZCOUNT, ZENABLED, ZRETAINED FROM ZRECORD ORDER BY Z_PK")
            },
            [
                [.int(1), .int(3), .int(9), .int(1), .null],
                [.int(2), .int(7), .int(4), .int(0), .text("kept")],
            ])
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA index_list(ZRECORD)") }.count, 1)
        try driver.close()
    }

    func testMultipleOptionalBackfillsRollbackWhenLaterUniqueValueCollides() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int32", isOptional: true, defaultValue: "5"),
                    Schema.Attribute(name: "second", type: "Int32", isOptional: true, defaultValue: "7"),
                ],
                indexes: [Schema.Index(properties: ["second"], isUnique: true)])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int32", defaultValue: "5"),
                    Schema.Attribute(name: "second", type: "Int32", defaultValue: "7"),
                ],
                indexes: [Schema.Index(properties: ["second"], isUnique: true)])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-optional-backfill-unique-rollback"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 2, NULL, NULL)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 4, 9, 7)")
        }
        let originalHash = try driver.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                .first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected later unique backfill collision to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZFIRST, ZSECOND FROM ZRECORD ORDER BY Z_PK") },
            [[.int(1), .int(2), .null, .null], [.int(2), .int(4), .int(9), .int(7)]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                    .first?.first
            },
            originalHash)
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZFIRST") && $0[3] == .int(0)
                })
            })
        try driver.close()
    }

    func testMultipleOptionalBackfillsRollbackOnCompositeUniqueCollision() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int32", isOptional: true, defaultValue: "3"),
                    Schema.Attribute(name: "second", type: "Int32", isOptional: true, defaultValue: "7"),
                ],
                indexes: [Schema.Index(properties: ["first", "second"], isUnique: true)])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int32", defaultValue: "3"),
                    Schema.Attribute(name: "second", type: "Int32", defaultValue: "7"),
                ],
                indexes: [Schema.Index(properties: ["first", "second"], isUnique: true)])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-backfill-composite-unique-rollback"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 2, NULL, NULL)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 3, 3, NULL)")
        }
        let originalDDL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        let originalHash = try driver.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                .first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected composite unique backfill collision, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZFIRST, ZSECOND FROM ZRECORD ORDER BY Z_PK") },
            [[.int(1), .int(2), .null, .null], [.int(2), .int(3), .int(3), .null]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalDDL)
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                    .first?.first
            },
            originalHash)
        try driver.close()
    }

    func testOpeningStoreRollsBackCompositeBackfillCollisionAndMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(
            directory.appendingPathComponent("optional-backfill-composite-rollback.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int32", isOptional: true, defaultValue: "3"),
                    Schema.Attribute(name: "second", type: "Int32", isOptional: true, defaultValue: "7"),
                ],
                indexes: [Schema.Index(properties: ["first", "second"], isUnique: true)])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int32", defaultValue: "3"),
                    Schema.Attribute(name: "second", type: "Int32", defaultValue: "7"),
                ],
                indexes: [Schema.Index(properties: ["first", "second"], isUnique: true)])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 2, NULL, NULL)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 3, 3, NULL)")
        }
        let originalHash = try initial.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                .first?.first
        }
        let originalDDL = try initial.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected composite backfill collision to fail opening, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZFIRST, ZSECOND FROM ZRECORD ORDER BY Z_PK") },
            [[.int(1), .int(2), .null, .null], [.int(2), .int(3), .int(3), .null]])
        XCTAssertEqual(
            try reopened.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                    .first?.first
            },
            originalHash)
        XCTAssertEqual(
            try reopened.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalDDL)
        XCTAssertEqual(try reopened.read { try $0.rows("PRAGMA integrity_check") }, [[.text("ok")]])
        try reopened.close()
    }

    func testSignedIntegerWideningPreservesRowsAndIndexes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Int32", isOptional: true, options: [.unique])
                ],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Int64", isOptional: true, options: [.unique])
                ],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (?, ?, ?)",
                [.int(1), .int(2), .int(Int64(Int32.min))])
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (?, ?, ?)",
                [.int(1), .int(3), .int(Int64(Int32.max))])
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 4, NULL)")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZVALUE FROM ZRECORD ORDER BY Z_PK") },
            [
                [.int(1), .int(2), .int(Int64(Int32.min))],
                [.int(2), .int(3), .int(Int64(Int32.max))],
                [.int(3), .int(4), .null],
            ])
        let indexRows = try migrated.read {
            try $0.rows(
                "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD' ORDER BY name")
        }
        XCTAssertEqual(
            indexRows.compactMap { row -> String? in
                guard case let .text(name)? = row.first else { return nil }
                return name
            },
            ["ZRECORD_ZVALUE_INDEX", "ZRECORD_ZVALUE_UNIQUE_INDEX"])
        try migrated.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (?, ?, ?)",
                [.int(1), .int(5), .int(Int64(Int32.max) + 1)])
        }
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT ZVALUE FROM ZRECORD WHERE Z_PK = 4") },
            [[.int(Int64(Int32.max) + 1)]])
        XCTAssertThrowsError(
            try migrated.write { connection in
                try connection.execute(
                    "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (?, ?, ?)",
                    [.int(1), .int(5), .int(Int64(Int32.max) + 1)])
            })
        try migrated.close()
    }

    func testMultipleSignedIntegerAttributesWidenTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("multiple-integer-widening.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "code", type: "Int8", options: [.unique]),
                    Schema.Attribute(name: "rank", type: "Int16"),
                    Schema.Attribute(name: "untouched", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["code", "rank"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "code", type: "Int32", options: [.unique]),
                    Schema.Attribute(name: "rank", type: "Int64"),
                    Schema.Attribute(name: "untouched", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["code", "rank"])])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZCODE, ZRANK, ZUNTOUCHED) VALUES (1, 9, -128, 32767, 'kept')")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT, ZCODE, ZRANK, ZUNTOUCHED FROM ZRECORD") },
            [[.int(1), .int(1), .int(9), .int(-128), .int(32767), .text("kept")]])
        let indexes = try migrated.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD' ORDER BY name")
        }
        XCTAssertEqual(
            indexes,
            [[.text("ZRECORD_ZCODE_UNIQUE_INDEX")], [.text("ZRECORD_ZCODE_ZRANK_INDEX")]])
        try migrated.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZCODE, ZRANK, ZUNTOUCHED) VALUES (1, 2, 128, 32768, 'wide')")
        }
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT ZCODE, ZRANK FROM ZRECORD WHERE Z_PK = 2") },
            [[.int(128), .int(32768)]])
        XCTAssertThrowsError(
            try migrated.write {
                try $0.execute(
                    "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZCODE, ZRANK, ZUNTOUCHED) VALUES (1, 3, 128, 32769, 'duplicate')"
                )
            })
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(try reopened.read { try $0.rows("SELECT COUNT(*) FROM ZRECORD") }, [[.int(2)]])
        try reopened.close()
    }

    func testMultipleSignedIntegerWideningsCanReplaceOrdinaryIndexes() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "small", type: "Int8"),
                    Schema.Attribute(name: "medium", type: "Int16"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["retained"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "small", type: "Int32"),
                    Schema.Attribute(name: "medium", type: "Int64"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["small"]), Schema.Index(properties: ["medium"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-widening-index-replace"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZSMALL, ZMEDIUM, ZRETAINED) VALUES (1, 4, -128, 32767, 'keep')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD' ORDER BY name")
            },
            [[.text("ZRECORD_ZMEDIUM_INDEX")], [.text("ZRECORD_ZSMALL_INDEX")]])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT ZSMALL, ZMEDIUM, ZRETAINED FROM ZRECORD") },
            [[.int(-128), .int(32767), .text("keep")]])
        try driver.close()
    }

    func testMultipleSignedIntegerWideningsRejectUniqueIndexTransitions() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "small", type: "Int8"),
                    Schema.Attribute(name: "medium", type: "Int16"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "small", type: "Int32"),
                    Schema.Attribute(name: "medium", type: "Int64"),
                ],
                indexes: [Schema.Index(properties: ["small"], isUnique: true)])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-widening-unique-reject"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZSMALL, ZMEDIUM) VALUES (1, 3, 7, 9)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected unique-index addition to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(try driver.read { try $0.rows("PRAGMA index_list(ZRECORD)").isEmpty })
        try driver.close()
    }

    func testOptionalSuffixIntegerTypesWidenTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("optional-integer-widening.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "small", type: "Int8?", isOptional: true),
                    Schema.Attribute(name: "medium", type: "Int16?", isOptional: true),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "small", type: "Int32?", isOptional: true),
                    Schema.Attribute(name: "medium", type: "Int64?", isOptional: true),
                ])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZSMALL, ZMEDIUM) VALUES (1, 4, -128, NULL)")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZSMALL, ZMEDIUM FROM ZRECORD") },
            [[.int(1), .int(4), .int(-128), .null]])
        try migrated.close()
    }

    func testMixedIntegerWideningAndNarrowingFailsWithoutChangingStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("mixed-integer-widening.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "wide", type: "Int8"),
                    Schema.Attribute(name: "narrow", type: "Int64"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "wide", type: "Int16"),
                    Schema.Attribute(name: "narrow", type: "Int32"),
                ])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZWIDE, ZNARROW) VALUES (1, 6, 12, 2147483648)")
        }
        let originalHash = try initial.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
            ).first?.first
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected mixed widening/narrowing to fail closed, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZWIDE, ZNARROW FROM ZRECORD") },
            [[.int(1), .int(6), .int(12), .int(2_147_483_648)]])
        XCTAssertEqual(
            try reopened.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
                ).first?.first
            },
            originalHash)
        try reopened.close()
    }

    func testMixedIntegerNarrowingAndWideningFailsWithoutChangingStore() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "narrow", type: "Int64"),
                    Schema.Attribute(name: "wide", type: "Int8"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "narrow", type: "Int32"),
                    Schema.Attribute(name: "wide", type: "Int16"),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "mixed-integer-narrowing-widening"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZNARROW, ZWIDE) VALUES (1, 6, 2147483648, 12)")
        }
        let originalDDL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected mixed narrowing/widening to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNARROW, ZWIDE FROM ZRECORD") },
            [[.int(1), .int(6), .int(2_147_483_648), .int(12)]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalDDL)
        try driver.close()
    }

    func testMixedIntegerWideningAndFloatConversionFailsWithoutChangingStore() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "wide", type: "Int8"),
                    Schema.Attribute(name: "fraction", type: "Int64"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "wide", type: "Int16"),
                    Schema.Attribute(name: "fraction", type: "Double"),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "mixed-integer-float-widening"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZWIDE, ZFRACTION) VALUES (1, 7, 12, 24)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected mixed integer and floating conversion to fail, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZWIDE, ZFRACTION FROM ZRECORD") },
            [[.int(1), .int(7), .int(12), .int(24)]])
        try driver.close()
    }

    func testIntegerWideningCombinedWithRenameFailsWithoutChangingStore() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "wide", type: "Int8"),
                    Schema.Attribute(name: "label", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "wide", type: "Int16"),
                    Schema.Attribute(name: "title", type: "String", originalName: "label"),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "integer-widening-plus-rename"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZWIDE, ZLABEL) VALUES (1, 8, 13, 'kept')")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected widening combined with rename to fail, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZWIDE, ZLABEL FROM ZRECORD") },
            [[.int(1), .int(8), .int(13), .text("kept")]])
        try driver.close()
    }

    func testSignedIntegerNarrowingRejectsOutOfRangeValuesWithoutChangingStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int64")])
        ])
        let narrower = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int32")])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 6, 2147483648)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 9, -2147483649)")
        }
        let sourceHash = try initial.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
            ).first?.first
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: narrower)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT ZVALUE FROM ZRECORD") },
            [[.int(2_147_483_648)], [.int(-2_147_483_649)]])
        XCTAssertEqual(
            try reopened.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
                ).first?
                .first
            },
            sourceHash)
        try reopened.close()
    }

    func testSignedIntegerNarrowingPreservesBoundaryValuesIndexesAndMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("integer-narrowing.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Int64", isOptional: true)],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Int32", isOptional: true)],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 2, -2147483648)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 7, 2147483647)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 5, NULL)")
        }
        let sourceHash = try initial.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
            ).first?.first
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT, ZVALUE FROM ZRECORD ORDER BY Z_PK") },
            [
                [.int(1), .int(1), .int(2), .int(-2_147_483_648)],
                [.int(2), .int(1), .int(7), .int(2_147_483_647)],
                [.int(3), .int(1), .int(5), .null],
            ])
        XCTAssertEqual(
            try migrated.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [[.text("ZRECORD_ZVALUE_INDEX")]])
        let destinationHash = try migrated.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
            ).first?.first
        }
        XCTAssertNotEqual(destinationHash, sourceHash)
        try migrated.close()
        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(try reopened.read { try $0.rows("PRAGMA integrity_check") }, [[.text("ok")]])
        try reopened.close()
    }

    func testMultipleSignedIntegerNarrowingsPreserveBoundariesAndNulls() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "small", type: "Int32", isOptional: true),
                    Schema.Attribute(name: "medium", type: "Int64"),
                    Schema.Attribute(name: "wide", type: "Int64", isOptional: true),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                indexes: [
                    Schema.Index(properties: ["small"]),
                    Schema.Index(properties: ["wide"]),
                    Schema.Index(properties: ["retained"]),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "small", type: "Int8", isOptional: true),
                    Schema.Attribute(name: "medium", type: "Int16"),
                    Schema.Attribute(name: "wide", type: "Int32", isOptional: true),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                indexes: [
                    Schema.Index(properties: ["small"]),
                    Schema.Index(properties: ["wide"]),
                    Schema.Index(properties: ["retained"]),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-signed-narrowing-boundaries"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZSMALL, ZMEDIUM, ZWIDE, ZRETAINED) "
                    + "VALUES (1, 2, -128, -32768, -2147483648, 'low')")
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZSMALL, ZMEDIUM, ZWIDE, ZRETAINED) "
                    + "VALUES (1, 5, 127, 32767, 2147483647, 'high')")
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZSMALL, ZMEDIUM, ZWIDE, ZRETAINED) "
                    + "VALUES (1, 8, NULL, 0, NULL, 'null')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT Z_PK, Z_OPT, typeof(ZSMALL), ZSMALL, ZMEDIUM, ZWIDE, ZRETAINED FROM ZRECORD ORDER BY Z_PK")
            },
            [
                [.int(1), .int(2), .text("integer"), .int(-128), .int(-32768), .int(-2_147_483_648), .text("low")],
                [.int(2), .int(5), .text("integer"), .int(127), .int(32767), .int(2_147_483_647), .text("high")],
                [.int(3), .int(8), .text("null"), .null, .int(0), .null, .text("null")],
            ])
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA index_list(ZRECORD)") }.count, 3)
        try driver.close()
    }

    func testMultipleSignedIntegerNarrowingsCanReplaceOrdinaryIndexes() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int64"),
                    Schema.Attribute(name: "second", type: "Int64"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["retained"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int32"),
                    Schema.Attribute(name: "second", type: "Int16"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                indexes: [
                    Schema.Index(properties: ["first"]),
                    Schema.Index(properties: ["second"]),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-narrowing-ordinary-index-replace"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND, ZRETAINED) VALUES (1, 4, 12, 34, 'keep')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD' ORDER BY name")
            },
            [[.text("ZRECORD_ZFIRST_INDEX")], [.text("ZRECORD_ZSECOND_INDEX")]])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT ZFIRST, ZSECOND, ZRETAINED FROM ZRECORD") },
            [[.int(12), .int(34), .text("keep")]])
        try driver.close()
    }

    func testMultipleSignedIntegerNarrowingsRejectUniqueIndexTransitions() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int64"),
                    Schema.Attribute(name: "second", type: "Int64"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int32"),
                    Schema.Attribute(name: "second", type: "Int16"),
                ],
                indexes: [Schema.Index(properties: ["first"], isUnique: true)])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-narrowing-unique-reject"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 2, 12, 34)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected unique-index transition to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(try driver.read { try $0.rows("PRAGMA index_list(ZRECORD)").isEmpty })
        try driver.close()
    }

    func testMultipleSignedIntegerNarrowingsRejectUniqueIndexRemoval() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int64"),
                    Schema.Attribute(name: "second", type: "Int64"),
                ],
                indexes: [Schema.Index(properties: ["first"], isUnique: true)])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int32"),
                    Schema.Attribute(name: "second", type: "Int16"),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-narrowing-unique-remove-reject"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected unique-index removal to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA index_list(ZRECORD)") }.count, 1)
        try driver.close()
    }

    func testMultipleSignedIntegerNarrowingsValidateAllColumnsBeforeMetadataChanges() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int64"),
                    Schema.Attribute(name: "second", type: "Int64"),
                ],
                indexes: [Schema.Index(properties: ["first"]), Schema.Index(properties: ["second"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int32"),
                    Schema.Attribute(name: "second", type: "Int16"),
                ],
                indexes: [Schema.Index(properties: ["first"]), Schema.Index(properties: ["second"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-signed-narrowing-overflow"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 7, 2147483647, 32768)")
        }
        let originalDDL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        let originalHash = try driver.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                .first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected second narrowing overflow to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZFIRST, ZSECOND FROM ZRECORD") },
            [[.int(1), .int(7), .int(2_147_483_647), .int(32_768)]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalDDL)
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                    .first?.first
            },
            originalHash)
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA index_list(ZRECORD)") }.count, 2)
        try driver.close()
    }

    func testInt64ToInt32BatchNarrowingRejectsBothExtremesAndAdjacentValues() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "retained", type: "String"),
                    Schema.Attribute(name: "narrowed", type: "Int64"),
                ],
                indexes: [Schema.Index(properties: ["narrowed"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "retained", type: "String"),
                    Schema.Attribute(name: "narrowed", type: "Int32"),
                ],
                indexes: [Schema.Index(properties: ["narrowed"])])
        ])
        for (caseIndex, value) in [Int64.min, Int64.max, Int64(Int32.min) - 1, Int64(Int32.max) + 1].enumerated() {
            let driver = try GRDBSQLiteDriver(location: .memory(name: "int64-int32-edge-\(caseIndex)"))
            try bootstrap(source, driver: driver)
            try driver.write { connection in
                try connection.execute(
                    "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZRETAINED, ZNARROWED) VALUES (1, 4, 'unchanged', ?)",
                    [.int(value)])
            }
            let originalDDL = try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            }
            let originalHash = try driver.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                    .first?.first
            }
            let originalIndexes = try driver.read { try $0.rows("PRAGMA index_list(ZRECORD)") }
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }, "Unexpectedly accepted narrowing source value \(value)."
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected Int64→Int32 narrowing to reject \(value), got \(error)")
                }
            }
            XCTAssertEqual(
                try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZRETAINED, ZNARROWED FROM ZRECORD") },
                [[.int(1), .int(4), .text("unchanged"), .int(value)]])
            XCTAssertEqual(
                try driver.read {
                    try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
                },
                originalDDL)
            XCTAssertEqual(
                try driver.read {
                    try $0.rows(
                        "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
                    )
                    .first?.first
                },
                originalHash)
            XCTAssertEqual(try driver.read { try $0.rows("PRAGMA index_list(ZRECORD)") }, originalIndexes)
            try driver.close()
        }
    }

    func testMultipleIntegerNarrowingsRejectFloatRebuildCombination() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "narrowed", type: "Int64"),
                    Schema.Attribute(name: "converted", type: "Int64"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "narrowed", type: "Int32"),
                    Schema.Attribute(name: "converted", type: "Double"),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "narrowing-float-rebuild-reject"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZNARROWED, ZCONVERTED) VALUES (1, 2, 4, 5)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected mixed narrowing and floating conversion to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT typeof(ZNARROWED), ZNARROWED, typeof(ZCONVERTED), ZCONVERTED FROM ZRECORD")
            },
            [[.text("integer"), .int(4), .text("integer"), .int(5)]])
        try driver.close()
    }

    func testSignedIntegerNarrowingRejectsMalformedStorageTypeAtomically() throws {
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int64")])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int16")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "integer-narrowing-malformed"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 11, 'twelve')")
        }
        let originalSchemaHash = try driver.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
            ).first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected malformed integer storage to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, typeof(ZVALUE), ZVALUE FROM ZRECORD") },
            [[.int(1), .int(11), .text("text"), .text("twelve")]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
                ).first?.first
            },
            originalSchemaHash)
        try driver.close()
    }

    func testNarrowIntegerWidthsAcceptExactSignedBoundaries() throws {
        let cases: [(sourceType: String, destinationType: String, minimum: Int64, maximum: Int64)] = [
            ("Int32", "Int16", -32_768, 32_767),
            ("Int16", "Int8", -128, 127),
        ]
        for (sourceType, destinationType, minimum, maximum) in cases {
            let driver = try GRDBSQLiteDriver(location: .memory(name: "narrow-\(sourceType)-\(destinationType)"))
            let source = Schema([
                Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: sourceType)])
            ])
            let destination = Schema([
                Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: destinationType)])
            ])
            try bootstrap(source, driver: driver)
            try driver.write { connection in
                try connection.execute(
                    "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 1, ?)", [.int(minimum)])
                try connection.execute(
                    "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 2, ?)", [.int(maximum)])
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            }
            XCTAssertEqual(
                try driver.read { try $0.rows("SELECT ZVALUE FROM ZRECORD ORDER BY Z_PK") },
                [[.int(minimum)], [.int(maximum)]])
            try driver.close()
        }
    }

    func testIntegerToDoubleRebuildPreservesExactValuesAndSystemColumns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("integer-double-rebuild.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Int64", isOptional: true)])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Double", isOptional: true)])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_PK, Z_ENT, Z_OPT, ZVALUE) VALUES (7, 1, 2, -9007199254740992)")
            try connection.execute(
                "INSERT INTO ZRECORD (Z_PK, Z_ENT, Z_OPT, ZVALUE) VALUES (11, 1, 8, 9007199254740992)")
            try connection.execute("INSERT INTO ZRECORD (Z_PK, Z_ENT, Z_OPT, ZVALUE) VALUES (19, 1, 4, NULL)")
        }
        let sourceEntityHighWatermark = try initial.read {
            try $0.rows("SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME = 'Record'").first?.first
        }
        let sourceHash = try initial.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
            ).first?.first
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read {
                try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT, typeof(ZVALUE), ZVALUE FROM ZRECORD ORDER BY Z_PK")
            },
            [
                [.int(7), .int(1), .int(2), .text("real"), .double(-9_007_199_254_740_992)],
                [.int(11), .int(1), .int(8), .text("real"), .double(9_007_199_254_740_992)],
                [.int(19), .int(1), .int(4), .text("null"), .null],
            ])
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME = 'Record'") },
            [sourceEntityHighWatermark].compactMap { $0 }.map { [$0] })
        let destinationHash = try migrated.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
            ).first?.first
        }
        XCTAssertNotEqual(destinationHash, sourceHash)
        XCTAssertEqual(try migrated.read { try $0.rows("PRAGMA integrity_check") }, [[.text("ok")]])
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(try reopened.read { try $0.rows("SELECT COUNT(*) FROM ZRECORD") }, [[.int(3)]])
        try reopened.close()
    }

    func testIntegerToDoubleRebuildRejectsInexactValuesAndRollsBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("integer-double-rollback.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int64")])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double")])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 9, 9007199254740993)")
        }
        let originalTableSQL = try initial.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        let originalHash = try initial.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
            ).first?.first
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected inexact integer conversion to fail closed, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, typeof(ZVALUE), ZVALUE FROM ZRECORD") },
            [[.int(1), .int(9), .text("integer"), .int(9_007_199_254_740_993)]])
        XCTAssertEqual(
            try reopened.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalTableSQL)
        XCTAssertEqual(
            try reopened.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
                ).first?.first
            },
            originalHash)
        try reopened.close()
    }

    func testIntegerToFloatingRebuildAcceptsExactValuesBeyondContiguousPrecisionRange() throws {
        let cases: [(String, String, [Int64], [Double])] = [
            (
                "float",
                "Float",
                [16_777_218, 33_554_436, Int64.min],
                [16_777_218.0, 33_554_436.0, -9_223_372_036_854_775_808.0]
            ),
            (
                "double",
                "Double",
                [9_007_199_254_740_994, 18_014_398_509_481_988, Int64.min],
                [9_007_199_254_740_994.0, 18_014_398_509_481_988.0, -9_223_372_036_854_775_808.0]
            ),
        ]
        for (name, destinationType, values, expectedValues) in cases {
            let source = Schema([
                Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int64")])
            ])
            let destination = Schema([
                Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: destinationType)])
            ])
            let driver = try GRDBSQLiteDriver(
                location: .memory(name: "integer-float-exact-outside-dense-range-\(name)"))
            try bootstrap(source, driver: driver)
            try driver.write { connection in
                for (offset, value) in values.enumerated() {
                    try connection.execute(
                        "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, ?, ?)",
                        [.int(Int64(offset + 1)), .int(value)])
                }
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            }
            XCTAssertEqual(
                try driver.read { try $0.rows("SELECT Z_PK, ZVALUE FROM ZRECORD ORDER BY Z_PK") },
                values.enumerated().map { [.int(Int64($0.offset + 1)), .double(expectedValues[$0.offset])] })
            try driver.close()
        }
    }

    func testIntegerToFloatingRebuildRejectsInexactValuesWithoutTrapping() throws {
        let cases: [(String, String, Int64)] = [
            ("float-adjacent", "Float", 16_777_217),
            ("float-max", "Float", Int64.max),
            ("double-adjacent", "Double", 9_007_199_254_740_993),
            ("double-max", "Double", Int64.max),
        ]
        for (name, destinationType, value) in cases {
            let source = Schema([
                Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int64")])
            ])
            let destination = Schema([
                Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: destinationType)])
            ])
            let driver = try GRDBSQLiteDriver(location: .memory(name: "integer-float-inexact-no-trap-\(name)"))
            try bootstrap(source, driver: driver)
            try driver.write { connection in
                try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 9, ?)", [.int(value)])
            }
            let sourceRows = try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZVALUE FROM ZRECORD") }
            let sourceDDL = try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'")
            }
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected inexact \(destinationType) conversion to reject, got \(error)")
                }
            }
            XCTAssertEqual(
                try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZVALUE FROM ZRECORD") }, sourceRows)
            XCTAssertEqual(
                try driver.read {
                    try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'")
                },
                sourceDDL)
            try driver.close()
        }
    }

    func testIntegerToDoubleRebuildPreservesOrdinaryIndexes() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Int64"),
                    Schema.Attribute(name: "other", type: "String"),
                ],
                indexes: [
                    Schema.Index(properties: ["value"]),
                    Schema.Index(properties: ["value", "other"]),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"),
                    Schema.Attribute(name: "other", type: "String"),
                ],
                indexes: [
                    Schema.Index(properties: ["value"]),
                    Schema.Index(properties: ["value", "other"]),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "integer-double-preserved-indexes"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZOTHER) VALUES (1, 3, 17, 'a')")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZOTHER) VALUES (1, 5, 23, 'b')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, typeof(ZVALUE), ZVALUE, ZOTHER FROM ZRECORD ORDER BY Z_PK") },
            [[.int(1), .text("real"), .double(17), .text("a")], [.int(2), .text("real"), .double(23), .text("b")]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD' ORDER BY name")
            },
            [[.text("ZRECORD_ZVALUE_INDEX")], [.text("ZRECORD_ZVALUE_ZOTHER_INDEX")]])
        let queryPlan = try driver.read {
            try $0.rows("EXPLAIN QUERY PLAN SELECT Z_PK FROM ZRECORD WHERE ZVALUE = 17")
        }
        XCTAssertTrue(
            queryPlan.contains(where: {
                $0.contains(where: {
                    if case let .text(text) = $0 { text.contains("ZRECORD_ZVALUE_INDEX") } else { false }
                })
            }))
        try driver.close()
    }

    func testIntegerToDoubleRebuildCanChangeOrdinaryIndexSet() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Int64"),
                    Schema.Attribute(name: "other", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"),
                    Schema.Attribute(name: "other", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["other"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "integer-double-index-set-change"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZOTHER) VALUES (1, 5, 29, 'kept')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [[.text("ZRECORD_ZOTHER_INDEX"), .text("CREATE INDEX ZRECORD_ZOTHER_INDEX ON ZRECORD (ZOTHER)")]])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZVALUE, ZOTHER FROM ZRECORD") },
            [[.int(1), .int(5), .double(29), .text("kept")]])
        try driver.close()
    }

    func testIntegerToDoubleRebuildCanReplaceOrdinaryIndexSet() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Int64"),
                    Schema.Attribute(name: "other", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"),
                    Schema.Attribute(name: "other", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["other"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "integer-double-replace-index-set"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZOTHER) VALUES (1, 6, 31, 'kept')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [[.text("ZRECORD_ZOTHER_INDEX"), .text("CREATE INDEX ZRECORD_ZOTHER_INDEX ON ZRECORD (ZOTHER)")]])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, ZVALUE, ZOTHER FROM ZRECORD") },
            [[.int(1), .double(31), .text("kept")]])
        try driver.close()
    }

    func testIntegerToDoubleRebuildPreservesUniqueSourceConstraint() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int64", options: [.unique])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double", options: [.unique])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "integer-double-unique-source"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 3, 17)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 4, 23)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [
                [
                    .text("ZRECORD_ZVALUE_UNIQUE_INDEX"),
                    .text("CREATE UNIQUE INDEX ZRECORD_ZVALUE_UNIQUE_INDEX ON ZRECORD (ZVALUE)"),
                ]
            ])
        XCTAssertThrowsError(
            try driver.write {
                try $0.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 5, 17.0)")
            })
        XCTAssertEqual(try driver.read { try $0.rows("SELECT COUNT(*) FROM ZRECORD") }, [[.int(2)]])
        try driver.close()
    }

    func testIntegerToDoubleRebuildPreservesCompositeUniqueIndex() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Int64"),
                    Schema.Attribute(name: "tag", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["value", "tag"], isUnique: true)])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"),
                    Schema.Attribute(name: "tag", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["value", "tag"], isUnique: true)])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "integer-double-composite-unique"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZTAG) VALUES (1, 3, 17, 'a')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [
                [
                    .text("ZRECORD_ZVALUE_ZTAG_UNIQUE_INDEX"),
                    .text("CREATE UNIQUE INDEX ZRECORD_ZVALUE_ZTAG_UNIQUE_INDEX ON ZRECORD (ZVALUE, ZTAG)"),
                ]
            ])
        XCTAssertThrowsError(
            try driver.write {
                try $0.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZTAG) VALUES (1, 4, 17.0, 'a')")
            })
        try driver.close()
    }

    func testIntegerToDoubleRebuildRejectsUnrelatedDestinationIndexNameCollision() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Int64"), Schema.Attribute(name: "other", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"), Schema.Attribute(name: "other", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["other"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "integer-double-unrelated-index-collision"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZOTHER) VALUES (1, 3, 17, 'a')")
            try connection.execute("CREATE TABLE ZRECORD_ZOTHER_INDEX (value INTEGER)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected destination index collision to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT typeof(ZVALUE), ZVALUE FROM ZRECORD") },
            [[.text("integer"), .int(17)]])
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD_ZOTHER_INDEX'")
                    .count == 1
            })
        try driver.close()
    }

    func testIntegerToDoubleRebuildRejectsPhysicalDependenciesBeforeChanges() throws {
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int64")])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double")])
        ])
        let cases: [(String, String)] = [
            ("trigger", "CREATE TRIGGER USER_RECORD_TRIGGER AFTER INSERT ON ZRECORD BEGIN SELECT 1; END"),
            ("foreign-key", "CREATE TABLE USER_REFERENCE (value INTEGER REFERENCES ZRECORD(Z_PK))"),
        ]
        for (name, statement) in cases {
            let driver = try GRDBSQLiteDriver(location: .memory(name: "integer-double-dependency-\(name)"))
            try bootstrap(source, driver: driver)
            try driver.write { connection in
                try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 4, 12)")
                try connection.execute(statement)
            }
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected \(name) dependency to fail closed, got \(error)")
                }
            }
            XCTAssertEqual(
                try driver.read { try $0.rows("SELECT typeof(ZVALUE), ZVALUE FROM ZRECORD") },
                [[.text("integer"), .int(12)]])
            XCTAssertTrue(
                try driver.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD_OSD_REBUILD'")
                        .isEmpty
                })
            try driver.close()
        }
    }

    func testIntegerToDoubleRebuildRejectsGeneratedSourceColumns() throws {
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int64")])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "integer-double-generated-column"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("DROP TABLE ZRECORD")
            try connection.execute(
                "CREATE TABLE ZRECORD (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, "
                    + "ZVALUE INTEGER, ZDERIVED INTEGER GENERATED ALWAYS AS (ZVALUE + 1) VIRTUAL)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 13, 4)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected generated source column to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_xinfo(ZRECORD)").contains(where: {
                    $0.count > 6 && $0[1] == .text("ZDERIVED") && $0[6] != .int(0)
                })
            })
        XCTAssertEqual(try driver.read { try $0.rows("SELECT ZVALUE, ZDERIVED FROM ZRECORD") }, [[.int(4), .int(5)]])
        try driver.close()
    }

    func testIntegerToFloatRebuildPreservesExactBoundariesAndNull() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int32", isOptional: true)])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "value", type: "Float", isOptional: true)])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "integer-float-rebuild-boundaries"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 2, -16777216)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 7, 16777216)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 4, NULL)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT Z_PK, Z_OPT, typeof(ZVALUE), ZVALUE FROM ZRECORD ORDER BY Z_PK")
            },
            [
                [.int(1), .int(2), .text("real"), .double(-16_777_216)],
                [.int(2), .int(7), .text("real"), .double(16_777_216)],
                [.int(3), .int(4), .text("null"), .null],
            ])
        try driver.close()
    }

    func testIntegerToFloatRebuildRejectsInexactValueAndRollsBack() throws {
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int64")])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Float")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "integer-float-rebuild-inexact"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 10, 16777217)")
        }
        let originalTableSQL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected inexact Int-to-Float conversion to fail, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT typeof(ZVALUE), ZVALUE FROM ZRECORD") },
            [[.text("integer"), .int(16_777_217)]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalTableSQL)
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE name LIKE '%OSD_REBUILD%'").isEmpty
            })
        try driver.close()
    }

    func testMultipleExactNumericRebuildsPreserveMixedBoundariesAndNulls() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "singlePrecision", type: "Int32", isOptional: true),
                    Schema.Attribute(name: "doublePrecision", type: "Int64", isOptional: true),
                ],
                indexes: [Schema.Index(properties: ["singlePrecision"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "singlePrecision", type: "Float", isOptional: true),
                    Schema.Attribute(name: "doublePrecision", type: "Double", isOptional: true),
                ],
                indexes: [Schema.Index(properties: ["singlePrecision"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-exact-numeric-rebuilds"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZSINGLEPRECISION, ZDOUBLEPRECISION) VALUES (1, 3, -16777216, 9007199254740992)"
            )
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZSINGLEPRECISION, ZDOUBLEPRECISION) VALUES (1, 8, 16777216, -9007199254740992)"
            )
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZSINGLEPRECISION, ZDOUBLEPRECISION) VALUES (1, 6, NULL, NULL)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT Z_PK, Z_OPT, typeof(ZSINGLEPRECISION), ZSINGLEPRECISION, "
                        + "typeof(ZDOUBLEPRECISION), ZDOUBLEPRECISION FROM ZRECORD ORDER BY Z_PK")
            },
            [
                [.int(1), .int(3), .text("real"), .double(-16_777_216), .text("real"), .double(9_007_199_254_740_992)],
                [.int(2), .int(8), .text("real"), .double(16_777_216), .text("real"), .double(-9_007_199_254_740_992)],
                [.int(3), .int(6), .text("null"), .null, .text("null"), .null],
            ])
        XCTAssertEqual(
            try driver.read { try $0.rows("PRAGMA index_list(ZRECORD)") }.count,
            1)
        try driver.close()
    }

    func testMultipleExactNumericRebuildsCanMixDirections() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "integral", type: "Double", isOptional: true),
                    Schema.Attribute(name: "exactInteger", type: "Int64"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "integral", type: "Int16", isOptional: true),
                    Schema.Attribute(name: "exactInteger", type: "Double"),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-exact-numeric-mixed-directions"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZINTEGRAL, ZEXACTINTEGER) VALUES (1, 4, -0.0, 9007199254740992)")
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZINTEGRAL, ZEXACTINTEGER) VALUES (1, 7, 32767.0, -9007199254740992)"
            )
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT Z_PK, Z_OPT, typeof(ZINTEGRAL), ZINTEGRAL, typeof(ZEXACTINTEGER), ZEXACTINTEGER "
                        + "FROM ZRECORD ORDER BY Z_PK")
            },
            [
                [.int(1), .int(4), .text("integer"), .int(0), .text("real"), .double(9_007_199_254_740_992)],
                [.int(2), .int(7), .text("integer"), .int(32_767), .text("real"), .double(-9_007_199_254_740_992)],
            ])
        try driver.close()
    }

    func testMultipleExactNumericRebuildsCanReplaceOrdinaryIndexes() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int32"),
                    Schema.Attribute(name: "second", type: "Int64"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["retained"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Float"),
                    Schema.Attribute(name: "second", type: "Double"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["first"]), Schema.Index(properties: ["second"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-exact-numeric-index-replacement"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND, ZRETAINED) VALUES (1, 3, 5, 9, 'keep')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD' ORDER BY name")
            },
            [[.text("ZRECORD_ZFIRST_INDEX")], [.text("ZRECORD_ZSECOND_INDEX")]])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT ZFIRST, ZSECOND, ZRETAINED FROM ZRECORD") },
            [[.double(5), .double(9), .text("keep")]])
        try driver.close()
    }

    func testMultipleExactNumericRebuildsSupportEmptyTablesAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("multiple-exact-empty.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int32"),
                    Schema.Attribute(name: "second", type: "Double", isOptional: true),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Float"),
                    Schema.Attribute(name: "second", type: "Int16", isOptional: true),
                ])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.close()
        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertTrue(try migrated.read { try $0.rows("SELECT Z_PK FROM ZRECORD").isEmpty })
        let destinationHash = try migrated.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                .first?.first
        }
        try migrated.close()
        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try reopened.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                    .first?.first
            },
            destinationHash)
        XCTAssertTrue(try reopened.read { try $0.rows("PRAGMA integrity_check") == [[.text("ok")]] })
        try reopened.close()
    }

    func testMultipleExactNumericRebuildsValidateEveryColumnBeforeSwap() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "valid", type: "Int32"),
                    Schema.Attribute(name: "fractional", type: "Double"),
                ],
                indexes: [Schema.Index(properties: ["valid"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "valid", type: "Float"),
                    Schema.Attribute(name: "fractional", type: "Int64"),
                ],
                indexes: [Schema.Index(properties: ["valid"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-exact-numeric-preflight"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALID, ZFRACTIONAL) VALUES (1, 9, 42, 1.5)")
        }
        let originalDDL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        let originalHash = try driver.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                .first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected inexact second conversion to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, typeof(ZVALID), ZVALID, ZFRACTIONAL FROM ZRECORD") },
            [[.int(1), .int(9), .text("integer"), .int(42), .double(1.5)]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalDDL)
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                    .first?.first
            },
            originalHash)
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA index_list(ZRECORD)") }.count, 1)
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE name LIKE '%OSD_REBUILD%'").isEmpty
            })
        try driver.close()
    }

    func testMultipleExactNumericRebuildsPreflightCombinedUniqueIndex() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "integerValue", type: "Int64"),
                    Schema.Attribute(name: "floatingValue", type: "Double"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "integerValue", type: "Double"),
                    Schema.Attribute(name: "floatingValue", type: "Int16"),
                ],
                indexes: [Schema.Index(properties: ["integerValue", "floatingValue"], isUnique: true)])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-exact-numeric-unique-preflight"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZINTEGERVALUE, ZFLOATINGVALUE) VALUES (1, 2, 7, 7.0)")
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZINTEGERVALUE, ZFLOATINGVALUE) VALUES (1, 3, 7, 7.0)")
        }
        let originalDDL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected combined unique index to reject duplicates, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT Z_PK, typeof(ZINTEGERVALUE), ZINTEGERVALUE, ZFLOATINGVALUE FROM ZRECORD ORDER BY Z_PK")
            },
            [
                [.int(1), .text("integer"), .int(7), .double(7)],
                [.int(2), .text("integer"), .int(7), .double(7)],
            ])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalDDL)
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE name LIKE '%OSD_REBUILD%'").isEmpty
            })
        try driver.close()
    }

    func testMultipleExactNumericRebuildsRejectUniqueNegativeZeroCollision() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Double"),
                    Schema.Attribute(name: "second", type: "Int64"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int16"),
                    Schema.Attribute(name: "second", type: "Double"),
                ],
                indexes: [Schema.Index(properties: ["first"], isUnique: true)])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-exact-numeric-negative-zero-unique"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 2, -0.0, 7)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 3, 0.0, 8)")
        }
        let originalDDL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected unique converted negative zero collision, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, typeof(ZFIRST), ZFIRST FROM ZRECORD ORDER BY Z_PK") },
            [[.int(1), .text("real"), .double(-0.0)], [.int(2), .text("real"), .double(0.0)]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalDDL)
        try driver.close()
    }

    func testMultipleExactNumericRebuildsRejectCombinedNarrowing() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "converted", type: "Int64"),
                    Schema.Attribute(name: "narrowed", type: "Int64"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "converted", type: "Double"),
                    Schema.Attribute(name: "narrowed", type: "Int32"),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-exact-numeric-reject-narrowing"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZCONVERTED, ZNARROWED) VALUES (1, 2, 4, 5)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected mixed narrowing to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT typeof(ZCONVERTED), ZCONVERTED, typeof(ZNARROWED), ZNARROWED FROM ZRECORD")
            },
            [[.text("integer"), .int(4), .text("integer"), .int(5)]])
        try driver.close()
    }

    func testMultipleExactNumericRebuildsAllowOptionalityRelaxation() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int32"),
                    Schema.Attribute(name: "second", type: "Int64"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Float"),
                    Schema.Attribute(name: "second", type: "Double", isOptional: true),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-exact-numeric-reject-optionality"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 2, 4, 5)")
        }
        try driver.write { connection in
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT typeof(ZFIRST), ZFIRST, typeof(ZSECOND), ZSECOND FROM ZRECORD")
            },
            [[.text("real"), .double(4), .text("real"), .double(5)]])
        try driver.write { connection in
            try connection.execute("UPDATE ZRECORD SET ZSECOND = NULL WHERE Z_PK = 1")
        }
        XCTAssertEqual(try driver.read { try $0.rows("SELECT ZSECOND FROM ZRECORD") }, [[.null]])
        try driver.close()
    }

    func testMultipleExactNumericRebuildsRejectUniqueOptionChange() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "integerValue", type: "Int64"),
                    Schema.Attribute(name: "floatingValue", type: "Double"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "integerValue", type: "Double"),
                    Schema.Attribute(name: "floatingValue", type: "Int16", options: [.unique]),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-exact-numeric-reject-unique-change"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZINTEGERVALUE, ZFLOATINGVALUE) VALUES (1, 2, 4, 5.0)")
        }
        let originalDDL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected attribute unique change to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT Z_PK, typeof(ZINTEGERVALUE), ZINTEGERVALUE, ZFLOATINGVALUE FROM ZRECORD")
            },
            [[.int(1), .text("integer"), .int(4), .double(5)]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalDDL)
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE name LIKE '%OSD_REBUILD%'").isEmpty
            })
        try driver.close()
    }

    func testMultipleExactNumericRebuildsAllowRequiredToOptionalRelaxation() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "singlePrecision", type: "Int32"),
                    Schema.Attribute(name: "integer", type: "Double"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "singlePrecision", type: "Float", isOptional: true),
                    Schema.Attribute(name: "integer", type: "Int16", isOptional: true),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-exact-required-to-optional"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZSINGLEPRECISION, ZINTEGER) VALUES (1, 3, 16777216, 42.0)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT Z_PK, Z_OPT, typeof(ZSINGLEPRECISION), ZSINGLEPRECISION, typeof(ZINTEGER), ZINTEGER FROM ZRECORD"
                )
            },
            [[.int(1), .int(3), .text("real"), .double(16_777_216), .text("integer"), .int(42)]])
        try driver.write { connection in
            try connection.execute("UPDATE ZRECORD SET ZSINGLEPRECISION = NULL, ZINTEGER = NULL WHERE Z_PK = 1")
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT ZSINGLEPRECISION, ZINTEGER FROM ZRECORD") },
            [[.null, .null]])
        try driver.close()
    }

    func testMultipleExactNumericRebuildsRejectOptionalToRequiredConversion() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Int32", isOptional: true),
                    Schema.Attribute(name: "second", type: "Int64"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Float"),
                    Schema.Attribute(name: "second", type: "Double"),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-exact-reject-optional-to-required"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 4, 5, 6)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected optional-to-required conversion to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT ZFIRST, ZSECOND FROM ZRECORD") },
            [[.int(5), .int(6)]])
        try driver.close()
    }

    func testDoubleToSignedIntegerRebuildPreservesExactValuesAndUniqueIndex() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double", isOptional: true),
                    Schema.Attribute(name: "label", type: "String", options: [.unique]),
                ],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Int16", isOptional: true),
                    Schema.Attribute(name: "label", type: "String", options: [.unique]),
                ],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "double-to-int16-rebuild"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 2, -0.0, 'zero')")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 5, -32768.0, 'min')")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 9, 32767.0, 'max')")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 3, NULL, 'nil')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT Z_PK, Z_OPT, typeof(ZVALUE), ZVALUE, ZLABEL FROM ZRECORD ORDER BY Z_PK")
            },
            [
                [.int(1), .int(2), .text("integer"), .int(0), .text("zero")],
                [.int(2), .int(5), .text("integer"), .int(-32768), .text("min")],
                [.int(3), .int(9), .text("integer"), .int(32767), .text("max")],
                [.int(4), .int(3), .text("null"), .null, .text("nil")],
            ])
        let indexes = try driver.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD' ORDER BY name")
        }
        XCTAssertEqual(indexes, [[.text("ZRECORD_ZLABEL_UNIQUE_INDEX")], [.text("ZRECORD_ZVALUE_INDEX")]])
        XCTAssertThrowsError(
            try driver.write {
                try $0.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 10, 1, 'zero')")
            })
        try driver.close()
    }

    func testDoubleToSignedIntegerRebuildRejectsFractionAndRollsBack() throws {
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double")])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int8")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "double-to-int8-fraction"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 7, 1.5)")
        }
        let originalDDL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected fractional conversion to fail, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, typeof(ZVALUE), ZVALUE FROM ZRECORD") },
            [[.int(1), .int(7), .text("real"), .double(1.5)]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalDDL)
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE name LIKE '%OSD_REBUILD%'").isEmpty
            })
        try driver.close()
    }

    func testFloatToSignedIntegerRebuildAndInt64UpperBoundary() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Float", isOptional: true)])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Int64", isOptional: true)])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "float-to-int64-boundary"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 2, -9223372036854775808.0)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 3, 9223372036854774784.0)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 4, -0.0)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 5, NULL)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, typeof(ZVALUE), ZVALUE FROM ZRECORD ORDER BY Z_PK") },
            [
                [.int(1), .text("integer"), .int(Int64.min)],
                [.int(2), .text("integer"), .int(9_223_372_036_854_774_784)],
                [.int(3), .text("integer"), .int(0)],
                [.int(4), .text("null"), .null],
            ])
        try driver.close()
    }

    func testFloatingToSignedIntegerRejectsUnsafeStorageAndRangeCasesAtomically() throws {
        let failures: [(name: String, value: String, destinationType: String)] = [
            ("fraction-positive", "1.5", "Int64"),
            ("fraction-negative", "-0.5", "Int64"),
            ("int8-overflow", "128.0", "Int8"),
            ("positive-overflow", "9223372036854775808.0", "Int64"),
            ("negative-overflow", "-9223372036854777856.0", "Int64"),
            ("infinity", "1.0e999", "Int64"),
            ("text", "'12x'", "Int64"),
            ("blob", "X'0102'", "Int64"),
        ]
        for (name, value, destinationType) in failures {
            let source = Schema([
                Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double")])
            ])
            let destination = Schema([
                Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: destinationType)])
            ])
            let driver = try GRDBSQLiteDriver(location: .memory(name: "float-to-int-invalid-\(name)"))
            try bootstrap(source, driver: driver)
            try driver.write { connection in
                try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 8, \(value))")
            }
            let original = try driver.read {
                try $0.rows("SELECT typeof(ZVALUE), ZVALUE FROM ZRECORD").first
            }
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }, "Expected \(name) to fail closed"
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected unsupported migration for \(name), got \(error)")
                }
            }
            XCTAssertEqual(
                try driver.read { try $0.rows("SELECT typeof(ZVALUE), ZVALUE FROM ZRECORD") },
                [try XCTUnwrap(original)])
            try driver.close()
        }
    }

    func testFloatingToInt64RejectsPositiveTwoToThe63() throws {
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double")])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int64")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "double-to-int64-positive-two63"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 6, 9223372036854775808.0)")
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT typeof(ZVALUE), ZVALUE FROM ZRECORD") },
            [[.text("real"), .double(9_223_372_036_854_775_808)]])
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected +2^63 to fail signed Int64 conversion, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT typeof(ZVALUE), ZVALUE FROM ZRECORD") },
            [[.text("real"), .double(9_223_372_036_854_775_808)]])
        try driver.close()
    }

    func testFloatingToIntegerPreservesAttributeUniqueConstraint() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Double", options: [.unique])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Int16", options: [.unique])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "float-to-int-unique-attribute"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 2, 8.0)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [
                [
                    .text("ZRECORD_ZVALUE_UNIQUE_INDEX"),
                    .text("CREATE UNIQUE INDEX ZRECORD_ZVALUE_UNIQUE_INDEX ON ZRECORD (ZVALUE)"),
                ]
            ])
        XCTAssertThrowsError(
            try driver.write {
                try $0.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 3, 8)")
            })
        try driver.close()
    }

    func testFloatingToIntegerUniqueAdditionRejectsDuplicatesBeforeSwap() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"),
                    Schema.Attribute(name: "label", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Int16"),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["value", "label"], isUnique: true)])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "float-to-int-unique-add-duplicate"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 2, 7.0, 'same')")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 3, 7.0, 'same')")
        }
        let sourceDDL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected unique preflight to reject duplicates, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, ZVALUE, ZLABEL FROM ZRECORD ORDER BY Z_PK") },
            [[.int(1), .double(7), .text("same")], [.int(2), .double(7), .text("same")]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            sourceDDL)
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE name LIKE '%OSD_REBUILD%'").isEmpty
            })
        try driver.close()
    }

    func testFloatingToIntegerUniqueAdditionAndNullSemantics() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double", isOptional: true),
                    Schema.Attribute(name: "label", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Int16", isOptional: true),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["value", "label"], isUnique: true)])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "float-to-int-unique-add-null"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 2, 7.0, 'a')")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 3, 7.0, 'b')")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 4, NULL, 'same')")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 5, NULL, 'same')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [
                [
                    .text("ZRECORD_ZVALUE_ZLABEL_UNIQUE_INDEX"),
                    .text("CREATE UNIQUE INDEX ZRECORD_ZVALUE_ZLABEL_UNIQUE_INDEX ON ZRECORD (ZVALUE, ZLABEL)"),
                ]
            ])
        try driver.close()
    }

    func testFloatingToIntegerUniqueRemovalAllowsDuplicatesAfterRebuild() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Double", options: [.unique])])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int16")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "float-to-int-unique-remove"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 5, 8.0)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 6, 8)")
        }
        XCTAssertEqual(try driver.read { try $0.rows("SELECT COUNT(*) FROM ZRECORD") }, [[.int(2)]])
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'").isEmpty
            })
        try driver.close()
    }

    func testIntegerToFloatUniqueAdditionRejectsInexactValuesAtomically() throws {
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int64")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "value", type: "Float", options: [.unique])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "int-to-float-unique-add-inexact"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 1, 16777217)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected inexact unique conversion to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT typeof(ZVALUE), ZVALUE FROM ZRECORD") },
            [[.text("integer"), .int(16_777_217)]])
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE name LIKE '%OSD_REBUILD%'").isEmpty
            })
        try driver.close()
    }

    func testIntegerToDoubleUniqueAdditionRejectsDuplicatesBeforeSwap() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Int64"),
                    Schema.Attribute(name: "label", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["value", "label"], isUnique: true)])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "int-to-double-unique-add-duplicate"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 2, 12, 'same')")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 3, 12, 'same')")
        }
        let originalDDL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected unique preflight to reject duplicates, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT typeof(ZVALUE), ZVALUE, ZLABEL FROM ZRECORD ORDER BY Z_PK") },
            [[.text("integer"), .int(12), .text("same")], [.text("integer"), .int(12), .text("same")]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalDDL)
        try driver.close()
    }

    func testNumericRebuildRejectsHierarchyPartialUniqueIndexesBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double")]),
            Schema.Entity(
                name: "SpecialRecord",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"),
                    Schema.Attribute(name: "specialValue", type: "String", options: [.unique]),
                ],
                superentityName: "Record",
            ),
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int16")]),
            Schema.Entity(
                name: "SpecialRecord",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"),
                    Schema.Attribute(name: "specialValue", type: "String", options: [.unique]),
                ],
                superentityName: "Record",
            ),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "numeric-rebuild-hierarchy-partial-index"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 3, 5.0)")
        }
        let originalDDL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        let originalIndexes = try driver.read {
            try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected hierarchy rebuild to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT typeof(ZVALUE), ZVALUE FROM ZRECORD") },
            [[.text("real"), .double(5)]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalDDL)
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            originalIndexes)
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE name LIKE '%OSD_REBUILD%'").isEmpty
            })
        try driver.close()
    }

    func testFloatingToRequiredIntegerRejectsNull() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double", isOptional: true)])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int16", isOptional: false)])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "float-to-required-int-null"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 3, NULL)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            })
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT typeof(ZVALUE), ZVALUE FROM ZRECORD") },
            [[.text("null"), .null]])
        try driver.close()
    }

    func testFloatingToSignedIntegerRejectsCombinedTypeChanges() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"),
                    Schema.Attribute(name: "other", type: "Int64"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Int16"),
                    Schema.Attribute(name: "other", type: "Int32"),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "float-to-int-combined-types"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZOTHER) VALUES (1, 3, 12.0, 4)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected combined type changes to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT typeof(ZVALUE), ZVALUE, ZOTHER FROM ZRECORD") },
            [[.text("real"), .double(12), .int(4)]])
        try driver.close()
    }

    func testFloatingToSignedIntegerRejectsDefaultChangesAtomically() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double", defaultValue: "1.0")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int16", defaultValue: "1")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "float-to-integer-default"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 2, 5.0)")
        }
        let originalDDL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected default-changing conversion to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT typeof(ZVALUE), ZVALUE FROM ZRECORD") },
            [[.text("real"), .double(5)]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalDDL)
        try driver.close()
    }

    func testFloatingToUnsignedIntegerRemainsUnsupported() throws {
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double")])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "UInt16")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "float-to-uint-unsupported"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 2, 5.0)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            })
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT typeof(ZVALUE), ZVALUE FROM ZRECORD") },
            [[.text("real"), .double(5)]])
        try driver.close()
    }

    func testFloatingToIntegerAddsUniqueIndexWhenDataIsDistinct() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Int16", options: [.unique])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "float-to-int-unique-change"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 4, 5.0)")
        }
        try driver.write { connection in
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [[.text("ZRECORD_ZVALUE_UNIQUE_INDEX")]])
        XCTAssertThrowsError(
            try driver.write {
                try $0.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 5, 5)")
            })
        try driver.close()
    }

    func testFloatingToIntegerAllowsUniqueIndexDeclarationReordering() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                indexes: [
                    Schema.Index(properties: ["value", "label"], isUnique: true),
                    Schema.Index(properties: ["label"]),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "label", type: "String"),
                    Schema.Attribute(name: "value", type: "Int16"),
                ],
                indexes: [
                    Schema.Index(properties: ["label"]),
                    Schema.Index(properties: ["value", "label"], isUnique: true),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "float-to-int-index-declaration-order"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 8, 7.0, 'x')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT ZVALUE, ZLABEL FROM ZRECORD") },
            [[.int(7), .text("x")]])
        try driver.close()
    }

    func testFloatingToIntegerWithRelationshipsRemainsUnsupported() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Double")],
                relationships: [
                    Schema.Relationship(
                        name: "target", destination: "Target", isToMany: false, isOptional: true)
                ]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Int16")],
                relationships: [
                    Schema.Relationship(
                        name: "target", destination: "Target", isToMany: false, isOptional: true)
                ]),
            Schema.Entity(name: "Target"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "float-to-int-relationship"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            })
        try driver.close()
    }

    func testIntegerToDoubleRebuildRejectsCombinedNumericChangesAtomically() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "narrow", type: "Int64"),
                    Schema.Attribute(name: "real", type: "Int64"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "narrow", type: "Int32"),
                    Schema.Attribute(name: "real", type: "Double"),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "integer-double-combined-types"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZNARROW, ZREAL) VALUES (1, 12, 2147483647, 9007199254740992)")
        }
        let originalTableSQL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        let originalHash = try driver.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
            ).first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected combined numeric changes to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNARROW, ZREAL FROM ZRECORD") },
            [[.int(1), .int(12), .int(2_147_483_647), .int(9_007_199_254_740_992)]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalTableSQL)
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
                ).first?.first
            },
            originalHash)
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE name LIKE '%OSD_REBUILD%'").isEmpty
            })
        try driver.close()
    }

    func testFloatToDoubleWideningValidatesStoredValuesAndPreservesRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("float-widening.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Float", isOptional: true)],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Double", isOptional: true)],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            for (version, literal) in [
                (Int64(1), "0.125"),
                (Int64(2), "-0.0"),
                (Int64(3), "1.401298464324817e-45"),
                (Int64(4), "1.0e999"),
                (Int64(5), "-1.0e999"),
            ] {
                try connection.execute(
                    "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, ?, \(literal))", [.int(version)])
            }
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 6, 16777216)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 7, NULL)")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, typeof(ZVALUE), ZVALUE FROM ZRECORD ORDER BY Z_PK") },
            [
                [.int(1), .int(1), .text("real"), .double(0.125)],
                [.int(2), .int(2), .text("real"), .double(0.0)],
                [.int(3), .int(3), .text("real"), .double(1.401298464324817e-45)],
                [.int(4), .int(4), .text("real"), .double(Double.infinity)],
                [.int(5), .int(5), .text("real"), .double(-Double.infinity)],
                [.int(6), .int(6), .text("real"), .double(16_777_216.0)],
                [.int(7), .int(7), .text("null"), .null],
            ])
        let retainedIndexes = try migrated.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
        }
        XCTAssertEqual(retainedIndexes, [[.text("ZRECORD_ZVALUE_INDEX")]])
        try migrated.close()
    }

    func testFloatToDoubleWideningRejectsInexactAndMalformedValuesAtomically() throws {
        let failures: [(String, String)] = [
            ("inexact", "0.1"),
            ("underflow", "1.0e-46"),
            ("overflow", "1.0e39"),
        ]
        for (name, literal) in failures {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let location = StoreLocation.file(directory.appendingPathComponent("\(name).sqlite"))
            let source = Schema([
                Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Float")])
            ])
            let destination = Schema([
                Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double")])
            ])
            let initial = try LightweightMigration.openStore(location: location, schema: source)
            try initial.write { connection in
                try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 2, \(literal))")
            }
            let originalValue = try initial.read { try $0.rows("SELECT ZVALUE FROM ZRECORD").first?.first }
            let sourceHash = try initial.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
                ).first?
                .first
            }
            try initial.close()

            XCTAssertThrowsError(
                try LightweightMigration.openStore(location: location, schema: destination),
                "Expected \(name) value to fail widening validation"
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected \(name) value to fail widening validation, got \(error)")
                }
            }
            let reopened = try LightweightMigration.openStore(location: location, schema: source)
            XCTAssertEqual(
                try reopened.read { try $0.rows("SELECT ZVALUE FROM ZRECORD") },
                [[try XCTUnwrap(originalValue)]])
            XCTAssertEqual(
                try reopened.read {
                    try $0.rows(
                        "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
                    ).first?
                    .first
                },
                sourceHash)
            XCTAssertEqual(
                try reopened.read { try $0.rows("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY") },
                [[.int(1), .text("Record")]])
            try reopened.close()
        }
    }

    func testDoubleToFloatNarrowingAcceptsOnlyExactlyRepresentableValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("double-narrowing.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Double", isOptional: true)],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Float", isOptional: true)],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            for (version, literal) in [
                (Int64(1), "0.125"),
                (Int64(2), "1.401298464324817e-45"),
                (Int64(3), "1.0e999"),
                (Int64(4), "-1.0e999"),
            ] {
                try connection.execute(
                    "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, ?, \(literal))", [.int(version)])
            }
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 5, NULL)")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read {
                try $0.rows("SELECT Z_PK, Z_OPT, ZVALUE FROM ZRECORD ORDER BY Z_PK")
            },
            [
                [.int(1), .int(1), .double(0.125)],
                [.int(2), .int(2), .double(1.401298464324817e-45)],
                [.int(3), .int(3), .double(Double.infinity)],
                [.int(4), .int(4), .double(-Double.infinity)],
                [.int(5), .int(5), .null],
            ])
        try migrated.close()
    }

    func testFloatToDoubleMigrationPreservesExactSubnormalValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("float-double-bit-patterns.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Float")])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double")])
        ])
        let values: [Float] = [
            .leastNonzeroMagnitude,
            Float(bitPattern: Float.leastNonzeroMagnitude.bitPattern - 1),
            Float.leastNormalMagnitude,
            Float(bitPattern: Float.leastNormalMagnitude.bitPattern - 1),
        ]
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            for (offset, value) in values.enumerated() {
                try connection.execute(
                    "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, ?, ?)",
                    [.int(Int64(offset + 1)), .double(Double(value))])
            }
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let storedValues = try migrated.read { try $0.rows("SELECT ZVALUE FROM ZRECORD ORDER BY Z_PK") }
        XCTAssertEqual(storedValues.count, values.count)
        for (row, sourceValue) in zip(storedValues, values) {
            guard case let .double(storedValue)? = row.first else {
                return XCTFail("Expected a REAL value for each migrated Float.")
            }
            XCTAssertEqual(Float(storedValue).bitPattern, sourceValue.bitPattern)
        }
        try migrated.close()
    }

    func testDoubleToFloatMigrationPreservesExactSubnormalValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("double-float-bit-patterns.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double")])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Float")])
        ])
        let values: [Float] = [
            .leastNonzeroMagnitude,
            Float(bitPattern: Float.leastNonzeroMagnitude.bitPattern - 1),
            Float.leastNormalMagnitude,
            Float(bitPattern: Float.leastNormalMagnitude.bitPattern - 1),
        ]
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            for (offset, value) in values.enumerated() {
                try connection.execute(
                    "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, ?, ?)",
                    [.int(Int64(offset + 1)), .double(Double(value))])
            }
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let storedValues = try migrated.read { try $0.rows("SELECT ZVALUE FROM ZRECORD ORDER BY Z_PK") }
        XCTAssertEqual(storedValues.count, values.count)
        for (row, sourceValue) in zip(storedValues, values) {
            guard case let .double(storedValue)? = row.first else {
                return XCTFail("Expected a REAL value for each migrated Double.")
            }
            XCTAssertEqual(Float(storedValue).bitPattern, sourceValue.bitPattern)
        }
        try migrated.close()
    }

    func testDoubleToFloatNarrowingRejectsLossyValuesAndRollsBack() throws {
        let cases: [(String, String)] = [
            ("precision", "0.1"),
            ("underflow", "1.0e-46"),
            ("overflow", "3.5e38"),
        ]
        for (name, literal) in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let location = StoreLocation.file(directory.appendingPathComponent("\(name).sqlite"))
            let source = Schema([
                Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Double")])
            ])
            let destination = Schema([
                Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Float")])
            ])
            let initial = try LightweightMigration.openStore(location: location, schema: source)
            try initial.write { connection in
                try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 7, \(literal))")
            }
            let originalValue = try initial.read { try $0.rows("SELECT ZVALUE FROM ZRECORD").first?.first }
            let originalHash = try initial.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
                ).first?.first
            }
            try initial.close()

            XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected lossy \(name) conversion to fail, got \(error)")
                }
            }
            let reopened = try LightweightMigration.openStore(location: location, schema: source)
            XCTAssertEqual(
                try reopened.read { try $0.rows("SELECT ZVALUE FROM ZRECORD") },
                [[try XCTUnwrap(originalValue)]])
            XCTAssertEqual(
                try reopened.read {
                    try $0.rows(
                        "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
                    ).first?.first
                },
                originalHash)
            try reopened.close()
        }
    }

    func testFloatToDoubleMigrationReconcilesOrdinaryIndexChanges() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Float"),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["value"]), Schema.Index(properties: ["label"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["value", "label"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "float-double-index-reconcile"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 3, 0.125, 'keep')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZVALUE, ZLABEL FROM ZRECORD") },
            [[.int(1), .int(3), .double(0.125), .text("keep")]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [[.text("ZRECORD_ZVALUE_ZLABEL_INDEX")]])
        try driver.close()
    }

    func testFloatTypeMigrationRejectsUniqueIndexTransitions() throws {
        let indexTransitions: [(String, [Schema.Index], [Schema.Index])] = [
            ("add", [], [Schema.Index(properties: ["value"], isUnique: true)]),
            ("remove", [Schema.Index(properties: ["value"], isUnique: true)], []),
        ]
        for (name, sourceIndexes, destinationIndexes) in indexTransitions {
            let source = Schema([
                Schema.Entity(
                    name: "Record",
                    attributes: [Schema.Attribute(name: "value", type: "Float")],
                    indexes: sourceIndexes)
            ])
            let destination = Schema([
                Schema.Entity(
                    name: "Record",
                    attributes: [Schema.Attribute(name: "value", type: "Double")],
                    indexes: destinationIndexes)
            ])
            let driver = try GRDBSQLiteDriver(location: .memory(name: "float-unique-index-\(name)"))
            try bootstrap(source, driver: driver)
            let sourceIndexesBefore = try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name")
            }
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected unique index \(name) to be rejected, got \(error)")
                }
            }
            XCTAssertEqual(
                try driver.read {
                    try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name")
                },
                sourceIndexesBefore)
            try driver.close()
        }
    }

    func testDoubleToFloatMigrationReconcilesOrdinaryIndexChanges() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["value"]), Schema.Index(properties: ["label"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Float"),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["value", "label"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "double-float-index-reconcile"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 5, 0.125, 'keep')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZVALUE, ZLABEL FROM ZRECORD") },
            [[.int(1), .int(5), .double(0.125), .text("keep")]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [[.text("ZRECORD_ZVALUE_ZLABEL_INDEX")]])
        try driver.close()
    }

    func testDoubleToFloatIndexChangeRejectsInexactValueWithoutIndexChanges() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Float"),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["label"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "double-float-inexact-index"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 7, 0.1, 'keep')")
        }
        let sourceIndexes = try driver.read {
            try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected inexact Double-to-Float conversion to reject index changes, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZVALUE, ZLABEL FROM ZRECORD") },
            [[.int(1), .int(7), .double(0.1), .text("keep")]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name")
            },
            sourceIndexes)
        try driver.close()
    }

    func testFloatToDoubleIndexMigrationPersistsMetadataAndReopens() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("float-double-index-migration.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Float"),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "Double"),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["label"])])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE, ZLABEL) VALUES (1, 11, 0.125, 'persist')")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZVALUE, ZLABEL FROM ZRECORD") },
            [[.int(1), .int(11), .double(0.125), .text("persist")]])
        XCTAssertEqual(
            try migrated.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [[.text("ZRECORD_ZLABEL_INDEX")]])
        XCTAssertEqual(
            try migrated.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
            },
            [[.blob(Array(SchemaHash.hexDigest(destination).utf8))]])
        XCTAssertEqual(try migrated.read { try $0.rows("PRAGMA integrity_check") }, [[.text("ok")]])
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZVALUE, ZLABEL FROM ZRECORD") },
            [[.int(1), .int(11), .double(0.125), .text("persist")]])
        XCTAssertEqual(try reopened.read { try $0.rows("PRAGMA integrity_check") }, [[.text("ok")]])
        try reopened.close()
    }

    func testMultipleFloatDoubleTypeChangesMigrateTogether() throws {
        let cases: [(String, [String], [String])] = [
            ("widen", ["Float", "Float"], ["Double", "Double"]),
            ("narrow", ["Double", "Double"], ["Float", "Float"]),
            ("mixed", ["Float", "Double"], ["Double", "Float"]),
        ]
        for (caseName, sourceTypes, destinationTypes) in cases {
            let sourceAttributes = ["first", "second"].enumerated().map { offset, name in
                Schema.Attribute(name: name, type: sourceTypes[offset])
            }
            let destinationAttributes = ["first", "second"].enumerated().map { offset, name in
                Schema.Attribute(name: name, type: destinationTypes[offset])
            }
            let source = Schema([
                Schema.Entity(name: "Record", attributes: sourceAttributes)
            ])
            let destination = Schema([
                Schema.Entity(name: "Record", attributes: destinationAttributes)
            ])
            let driver = try GRDBSQLiteDriver(location: .memory(name: "multi-float-double-\(caseName)"))
            try bootstrap(source, driver: driver)
            try driver.write { connection in
                try connection.execute(
                    "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 13, 0.125, 0.375)")
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            }
            XCTAssertEqual(
                try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZFIRST, ZSECOND FROM ZRECORD") },
                [[.int(1), .int(13), .double(0.125), .double(0.375)]],
                "Unexpected row after \(caseName) migration")
            try driver.close()
        }
    }

    func testMultipleFloatDoubleChangesRejectOtherMetadataEdits() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Float"),
                    Schema.Attribute(name: "second", type: "Float"),
                ])
        ])
        let invalidDestinations = [
            Schema([
                Schema.Entity(
                    name: "Record",
                    attributes: [
                        Schema.Attribute(name: "first", type: "Double"),
                        Schema.Attribute(name: "second", type: "Double"),
                        Schema.Attribute(name: "extra", type: "Int16", isOptional: true),
                    ])
            ]),
            Schema([
                Schema.Entity(
                    name: "Record",
                    attributes: [
                        Schema.Attribute(name: "first", type: "Double"),
                        Schema.Attribute(name: "second", type: "Double", isOptional: true),
                    ])
            ]),
            Schema([
                Schema.Entity(
                    name: "Record",
                    attributes: [
                        Schema.Attribute(name: "first", type: "Double", defaultValue: "1"),
                        Schema.Attribute(name: "second", type: "Double"),
                    ])
            ]),
        ]
        for (offset, destination) in invalidDestinations.enumerated() {
            let driver = try GRDBSQLiteDriver(location: .memory(name: "multi-float-double-invalid-\(offset)"))
            try bootstrap(source, driver: driver)
            let sourceRows = try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZFIRST, ZSECOND FROM ZRECORD") }
            let sourceIndexes = try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name")
            }
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected unrelated metadata change to reject the batch, got \(error)")
                }
            }
            XCTAssertEqual(
                try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZFIRST, ZSECOND FROM ZRECORD") }, sourceRows)
            XCTAssertEqual(
                try driver.read {
                    try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name")
                },
                sourceIndexes)
            try driver.close()
        }
    }

    func testMultipleFloatDoubleChangesValidateEveryColumnBeforeIndexReconciliation() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Float"),
                    Schema.Attribute(name: "second", type: "Float"),
                ],
                indexes: [Schema.Index(properties: ["first"]), Schema.Index(properties: ["second"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "Double"),
                    Schema.Attribute(name: "second", type: "Double"),
                ],
                indexes: [Schema.Index(properties: ["first", "second"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multi-float-double-index-failure"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 17, 0.125, 0.1)")
        }
        let originalRows = try driver.read {
            try $0.rows("SELECT Z_PK, Z_OPT, ZFIRST, ZSECOND FROM ZRECORD")
        }
        let originalIndexes = try driver.read {
            try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected inexact later Float column to reject the batch, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZFIRST, ZSECOND FROM ZRECORD") }, originalRows)
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name")
            },
            originalIndexes)
        try driver.close()
    }

    func testUnindexedScalarAttributeRemovalPreservesRowsAndReopens() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String"),
                    Schema.Attribute(name: "obsolete", type: "Int16"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZTITLE, ZOBSOLETE) VALUES (?, ?, ?, ?)",
                [.int(1), .int(8), .text("preserved"), .int(42)])
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZTITLE FROM ZRECORD") },
            [[.int(1), .int(8), .text("preserved")]])
        XCTAssertFalse(
            try migrated.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
                .contains(where: { $0.count > 1 && $0[1] == .text("ZOBSOLETE") }))
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, ZTITLE FROM ZRECORD") },
            [[.int(1), .text("preserved")]])
        try reopened.close()
    }

    func testIndexedAttributeRemovalDropsOrdinaryIndexAndPreservesRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Int")],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let destination = Schema([Schema.Entity(name: "Record")])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 2, 5)")
        }
        try initial.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertFalse(
            try reopened.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
                .contains(where: { $0.count > 1 && $0[1] == .text("ZVALUE") }))
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT FROM ZRECORD") },
            [[.int(1), .int(2)]])
        XCTAssertTrue(
            try reopened.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZRECORD_ZVALUE_INDEX'")
                    .isEmpty
            })
        try reopened.close()
    }

    func testUnindexedScalarRemovalDropsDependentOrdinaryIndexes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String"),
                    Schema.Attribute(name: "obsolete", type: "Int"),
                    Schema.Attribute(name: "category", type: "String"),
                ],
                indexes: [
                    Schema.Index(properties: ["obsolete"]),
                    Schema.Index(properties: ["category", "obsolete"]),
                    Schema.Index(properties: ["title"]),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String"),
                    Schema.Attribute(name: "category", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["title"])])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZTITLE, ZOBSOLETE, ZCATEGORY) VALUES (1, 6, 'kept', 9, 'group')")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let columns = try migrated.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
        XCTAssertFalse(columns.contains(where: { $0.count > 1 && $0[1] == .text("ZOBSOLETE") }))
        let indexNames = try migrated.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
        }.compactMap { row -> String? in
            guard case let .text(name)? = row.first else { return nil }
            return name
        }
        XCTAssertEqual(indexNames, ["ZRECORD_ZTITLE_INDEX"])
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZTITLE, ZCATEGORY FROM ZRECORD") },
            [[.int(1), .int(6), .text("kept"), .text("group")]])
        try migrated.close()
    }

    func testMultipleScalarAttributesCanBeRemovedWithDependentOrdinaryIndexes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("multiple-removals.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "kept", type: "String"),
                    Schema.Attribute(name: "first", type: "Int32", isOptional: true),
                    Schema.Attribute(name: "second", type: "Double", isOptional: true),
                ],
                indexes: [
                    Schema.Index(properties: ["first"]),
                    Schema.Index(properties: ["second", "first"]),
                    Schema.Index(properties: ["kept"]),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "kept", type: "String")],
                indexes: [Schema.Index(properties: ["kept"])])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZKEPT, ZFIRST, ZSECOND) VALUES (1, 4, 'one', 12, 2.5)")
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZKEPT, ZFIRST, ZSECOND) VALUES (1, 9, 'two', NULL, NULL)")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT, ZKEPT FROM ZRECORD ORDER BY Z_PK") },
            [[.int(1), .int(1), .int(4), .text("one")], [.int(2), .int(1), .int(9), .text("two")]])
        XCTAssertEqual(
            try migrated.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [[.text("ZRECORD_ZKEPT_INDEX")]])
        XCTAssertEqual(try migrated.read { try $0.rows("PRAGMA integrity_check") }, [[.text("ok")]])
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(try reopened.read { try $0.rows("SELECT COUNT(*) FROM ZRECORD") }, [[.int(2)]])
        try reopened.close()
    }

    func testScalarRenameComposesWithIndependentScalarRemoval() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "legacyTitle", type: "String"),
                    Schema.Attribute(name: "obsolete", type: "String"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["retained"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String", originalName: "legacyTitle"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["retained"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "rename-plus-independent-removal"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZLEGACYTITLE, ZOBSOLETE, ZRETAINED) "
                    + "VALUES (1, 8, 'title-data', 'drop', 'retained-data')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZTITLE, ZRETAINED FROM ZRECORD") },
            [[.int(1), .int(8), .text("title-data"), .text("retained-data")]])
        XCTAssertFalse(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZOBSOLETE")
                })
            })
        XCTAssertEqual(
            try driver.read { try $0.rows("PRAGMA index_list(ZRECORD)") }.count,
            1)
        try driver.close()
    }

    func testScalarRenameComposesWithDefaultedScalarAddition() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "legacyTitle", type: "String"),
                    Schema.Attribute(name: "retained", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String", originalName: "legacyTitle"),
                    Schema.Attribute(name: "retained", type: "String"),
                    Schema.Attribute(name: "priority", type: "Int16", defaultValue: "4"),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "rename-plus-defaulted-add"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZLEGACYTITLE, ZRETAINED) VALUES (1, 5, 'title', 'keep')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZTITLE, ZRETAINED, ZPRIORITY FROM ZRECORD") },
            [[.int(1), .int(5), .text("title"), .text("keep"), .int(4)]])
        try driver.close()
    }

    func testScalarRenameWithDynamicDefaultRejectsBeforeChangingRows() throws {
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "legacyTitle", type: "String")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String", originalName: "legacyTitle"),
                    Schema.Attribute(name: "createdAt", type: "Date", defaultValue: "CURRENT_TIMESTAMP"),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "rename-plus-dynamic-default-reject"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZLEGACYTITLE) VALUES (1, 3, 'keep')")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected dynamic default to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZLEGACYTITLE FROM ZRECORD") },
            [[.int(1), .int(3), .text("keep")]])
        XCTAssertFalse(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: { $0.count > 1 && $0[1] == .text("ZTITLE") })
            })
        try driver.close()
    }

    func testScalarRenameAndAdditionRejectsExistingPhysicalColumnCollisionBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "legacyTitle", type: "String")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String", originalName: "legacyTitle"),
                    Schema.Attribute(name: "note", type: "String", isOptional: true),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "rename-add-existing-column-collision"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZLEGACYTITLE) VALUES (1, 6, 'keep')")
            try connection.execute("ALTER TABLE ZRECORD ADD COLUMN ZNOTE VARCHAR")
        }
        let originalDDL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected physical column collision to fail before rename, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZLEGACYTITLE FROM ZRECORD") },
            [[.int(1), .int(6), .text("keep")]])
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZLEGACYTITLE")
                })
            })
        XCTAssertFalse(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: { $0.count > 1 && $0[1] == .text("ZTITLE") })
            })
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZRECORD'").first?.first
            },
            originalDDL)
        try driver.close()
    }

    func testScalarRenameComposesWithRemovalButRejectsDestinationNameReuse() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "legacyTitle", type: "String"),
                    Schema.Attribute(name: "obsolete", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "obsolete", type: "String", originalName: "legacyTitle")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "rename-removal-column-reuse"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZLEGACYTITLE, ZOBSOLETE) VALUES (1, 3, 'keep', 'drop')")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected rename/removal name reuse to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT ZLEGACYTITLE, ZOBSOLETE FROM ZRECORD") },
            [[.text("keep"), .text("drop")]])
        try driver.close()
    }

    func testScalarRenameWithIndexAndRemovalRemainsUnsupported() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "legacyTitle", type: "String"),
                    Schema.Attribute(name: "obsolete", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["legacyTitle"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "title", type: "String", originalName: "legacyTitle")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "rename-index-removal-reject"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            })
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZLEGACYTITLE")
                })
            })
        try driver.close()
    }

    func testScalarRenameWithGeneratedOrdinaryIndexComposesWithRemoval() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "legacyTitle", type: "String"),
                    Schema.Attribute(name: "obsolete", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["legacyTitle"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String", originalName: "legacyTitle")
                ],
                indexes: [Schema.Index(properties: ["title"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "rename-index-remove-scalar"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZLEGACYTITLE, ZOBSOLETE) VALUES (1, 4, 'kept', 'drop')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZTITLE FROM ZRECORD") },
            [[.int(1), .int(4), .text("kept")]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [[.text("ZRECORD_ZTITLE_INDEX"), .text("CREATE INDEX ZRECORD_ZTITLE_INDEX ON ZRECORD (ZTITLE)")]])
        try driver.close()
    }

    func testScalarRenameRemovalCanReplaceUnrelatedOrdinaryIndex() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "legacyTitle", type: "String"),
                    Schema.Attribute(name: "obsolete", type: "String"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["retained"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String", originalName: "legacyTitle"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["title"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "rename-removal-replace-unrelated-index"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZLEGACYTITLE, ZOBSOLETE, ZRETAINED) "
                    + "VALUES (1, 5, 'title-data', 'drop', 'retained-data')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [[.text("ZRECORD_ZTITLE_INDEX"), .text("CREATE INDEX ZRECORD_ZTITLE_INDEX ON ZRECORD (ZTITLE)")]])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT ZTITLE, ZRETAINED FROM ZRECORD") },
            [[.text("title-data"), .text("retained-data")]])
        try driver.close()
    }

    func testScalarRemovalComposesWithOptionalAndDefaultedAdditions() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "obsolete", type: "String"),
                    Schema.Attribute(name: "identity", type: "String", options: [.unique]),
                ],
                indexes: [Schema.Index(properties: ["obsolete", "identity"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "identity", type: "String", options: [.unique]),
                    Schema.Attribute(name: "optionalNote", type: "String", isOptional: true),
                    Schema.Attribute(name: "priority", type: "Int16", defaultValue: "7"),
                ],
                indexes: [Schema.Index(properties: ["identity"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-add-scalar-columns"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZOBSOLETE, ZIDENTITY) VALUES (1, 6, 'drop', 'kept')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }.compactMap { row -> String? in
                guard row.count > 1, case let .text(name) = row[1] else { return nil }
                return name
            },
            ["Z_PK", "Z_ENT", "Z_OPT", "ZIDENTITY", "ZOPTIONALNOTE", "ZPRIORITY"])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT Z_PK, Z_OPT, ZIDENTITY, ZOPTIONALNOTE, ZPRIORITY FROM ZRECORD")
            },
            [[.int(1), .int(6), .text("kept"), .null, .int(7)]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD' ORDER BY name")
            },
            [[.text("ZRECORD_ZIDENTITY_INDEX")], [.text("ZRECORD_ZIDENTITY_UNIQUE_INDEX")]])
        try driver.close()
    }

    func testScalarRemovalAndAdditionRejectsNewUniqueAttributeAtomically() throws {
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "obsolete", type: "String")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "added", type: "String", isOptional: true, options: [.unique])
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-add-unique-reject"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZOBSOLETE) VALUES (1, 2, 'kept')")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            })
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZOBSOLETE")
                })
            })
        XCTAssertFalse(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: { $0.count > 1 && $0[1] == .text("ZADDED") })
            })
        try driver.close()
    }

    func testScalarRemovalAndAdditionRejectsNonliteralRequiredDefaultBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "obsolete", type: "String")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "createdAt", type: "Date", defaultValue: "CURRENT_TIMESTAMP")
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-add-dynamic-default"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZOBSOLETE) VALUES (1, 3, 'retained-before-failure')")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected dynamic default to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZOBSOLETE")
                })
            })
        XCTAssertFalse(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZCREATEDAT")
                })
            })
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT ZOBSOLETE FROM ZRECORD") },
            [[.text("retained-before-failure")]])
        try driver.close()
    }

    func testCodableBlobAttributeCanBeRemovedWithOrdinaryScalarRemoval() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "payload", type: "Payload", options: [.codable]),
                    Schema.Attribute(name: "obsolete", type: "String"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["payload"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "retained", type: "String")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-codable-blob-attribute"))
        try bootstrap(source, driver: driver)
        let markerLikeBytes = Array("OSD_EXTERNAL_DATA_V1\u{0}data-not-a-sidecar.blob".utf8)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZPAYLOAD, ZOBSOLETE, ZRETAINED) VALUES (1, 6, ?, 'drop', 'keep')",
                [.blob(markerLikeBytes)])
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }.compactMap { row -> String? in
                guard row.count > 1, case let .text(name) = row[1] else { return nil }
                return name
            },
            ["Z_PK", "Z_ENT", "Z_OPT", "ZRETAINED"])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZRETAINED FROM ZRECORD") },
            [[.int(1), .int(6), .text("keep")]])
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'").isEmpty
            })
        try driver.close()
    }

    func testMultipleInlineCodableBlobsCanBeRemovedWithFlattenedAttributesAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("multiple-codable-removal.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "firstPayload", type: "Payload", options: [.codable]),
                    Schema.Attribute(
                        name: "address", type: "Address", options: [.flattened],
                        components: [
                            .init(name: "city", columnName: "address_city", type: "String"),
                            .init(name: "postalCode", columnName: "address_postalCode", type: "Int32"),
                        ]),
                    Schema.Attribute(name: "secondPayload", type: "Payload", options: [.codable]),
                    Schema.Attribute(name: "retained", type: "String"),
                    Schema.Attribute(name: "retainedCount", type: "Int64", isOptional: true),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "retained", type: "String"),
                    Schema.Attribute(name: "retainedCount", type: "Int64", isOptional: true),
                ])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let firstMarker = Array("OSD_EXTERNAL_DATA_V1\u{0}inline-first.blob".utf8)
        let secondMarker = Array("OSD_EXTERNAL_DATA_V1\u{0}inline-second.blob".utf8)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRSTPAYLOAD, ZADDRESS_CITY, ZADDRESS_POSTALCODE, "
                    + "ZSECONDPAYLOAD, ZRETAINED, ZRETAINEDCOUNT) VALUES (1, 11, ?, 'Oslo', 1234, ?, 'preserve', 9223372036854775807)",
                [.blob(firstMarker), .blob(secondMarker)])
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read {
                try $0.rows("SELECT Z_PK, Z_OPT, ZRETAINED, ZRETAINEDCOUNT FROM ZRECORD")
            },
            [[.int(1), .int(11), .text("preserve"), .int(Int64.max)]])
        let migratedHash = try migrated.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                .first?.first
        }
        XCTAssertEqual(
            try migrated.read { try $0.rows("PRAGMA table_info(ZRECORD)") }.compactMap { row -> String? in
                guard row.count > 1, case let .text(name) = row[1] else { return nil }
                return name
            },
            ["Z_PK", "Z_ENT", "Z_OPT", "ZRETAINED", "ZRETAINEDCOUNT"])
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try reopened.read {
                try $0.rows("SELECT Z_PK, Z_OPT, ZRETAINED, ZRETAINEDCOUNT FROM ZRECORD")
            },
            [[.int(1), .int(11), .text("preserve"), .int(Int64.max)]])
        XCTAssertEqual(
            try reopened.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                    .first?.first
            },
            migratedHash)
        XCTAssertEqual(try reopened.read { try $0.rows("PRAGMA integrity_check") }, [[.text("ok")]])
        try reopened.close()
    }

    func testCodableRemovalRejectsPhysicalIndexDependencyBeforeAnyDrop() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "firstPayload", type: "Payload", options: [.codable]),
                    Schema.Attribute(name: "secondPayload", type: "Payload", options: [.codable]),
                    Schema.Attribute(name: "retained", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "retained", type: "String")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "codable-removal-index-dependency-reject"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRSTPAYLOAD, ZSECONDPAYLOAD, ZRETAINED) VALUES (1, 5, ?, ?, 'keep')",
                [.blob([0x01, 0x02]), .blob([0x03, 0x04])])
            try connection.execute("CREATE INDEX ZCUSTOM_PAYLOAD_INDEX ON ZRECORD (ZSECONDPAYLOAD)")
        }
        let originalColumns = try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
        let originalRow = try driver.read {
            try $0.rows("SELECT Z_PK, Z_OPT, ZFIRSTPAYLOAD, ZSECONDPAYLOAD, ZRETAINED FROM ZRECORD")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected a physical dependency on a removed Codable BLOB to fail, got \(error)")
            }
        }
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }, originalColumns)
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT Z_PK, Z_OPT, ZFIRSTPAYLOAD, ZSECONDPAYLOAD, ZRETAINED FROM ZRECORD")
            },
            originalRow)
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZCUSTOM_PAYLOAD_INDEX'")
            },
            [[.text("ZCUSTOM_PAYLOAD_INDEX")]])
        try driver.close()
    }

    func testExternalCodableAttributeRemovalRemainsUnsupported() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(
                        name: "payload", type: "Payload", options: [.codable, .externalStorage])
                ])
        ])
        let destination = Schema([Schema.Entity(name: "Record")])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-external-codable-reject"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected external Codable removal to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: { $0.count > 1 && $0[1] == .text("ZPAYLOAD") }
                )
            })
        try driver.close()
    }

    func testFlattenedAttributeCanBeRemovedAsAWhole() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(
                        name: "address",
                        type: "Address",
                        options: [.flattened],
                        components: [
                            .init(name: "city", columnName: "address_city", type: "String"),
                            .init(name: "zip", columnName: "address_zip", type: "Int32"),
                        ]),
                    Schema.Attribute(name: "retained", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "retained", type: "String")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-whole-flattened-attribute"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZADDRESS_CITY, ZADDRESS_ZIP, ZRETAINED) "
                    + "VALUES (1, 5, 'Paris', 75000, 'keep')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }.compactMap { row -> String? in
                guard row.count > 1, case let .text(name) = row[1] else { return nil }
                return name
            },
            ["Z_PK", "Z_ENT", "Z_OPT", "ZRETAINED"])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZRETAINED FROM ZRECORD") },
            [[.int(1), .int(5), .text("keep")]])
        try driver.close()
    }

    func testMultipleFlattenedAttributesCanBeRemovedTogether() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(
                        name: "address",
                        type: "Address",
                        options: [.flattened],
                        components: [
                            .init(name: "city", columnName: "address_city", type: "String"),
                            .init(name: "zip", columnName: "address_zip", type: "Int32"),
                        ]),
                    Schema.Attribute(
                        name: "dimensions",
                        type: "Dimensions",
                        options: [.flattened],
                        components: [
                            .init(name: "width", columnName: "dimensions_width", type: "Double"),
                            .init(name: "height", columnName: "dimensions_height", type: "Double"),
                        ]),
                    Schema.Attribute(name: "retained", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "retained", type: "String"),
                    Schema.Attribute(name: "note", type: "String", isOptional: true),
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-multiple-flattened-attributes"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZADDRESS_CITY, ZADDRESS_ZIP, "
                    + "ZDIMENSIONS_WIDTH, ZDIMENSIONS_HEIGHT, ZRETAINED) "
                    + "VALUES (1, 7, 'Rome', 12345, 1.5, 2.5, 'keep')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }.compactMap { row -> String? in
                guard row.count > 1, case let .text(name) = row[1] else { return nil }
                return name
            },
            ["Z_PK", "Z_ENT", "Z_OPT", "ZRETAINED", "ZNOTE"])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZRETAINED, ZNOTE FROM ZRECORD") },
            [[.int(1), .int(7), .text("keep"), .null]])
        try driver.close()
    }

    func testFlattenedAttributeRemovalRejectsMissingLeafBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(
                        name: "address",
                        type: "Address",
                        options: [.flattened],
                        components: [
                            .init(name: "city", columnName: "address_city", type: "String"),
                            .init(name: "zip", columnName: "address_zip", type: "Int32"),
                        ])
                ])
        ])
        let destination = Schema([Schema.Entity(name: "Record")])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-flattened-missing-leaf"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("DROP TABLE ZRECORD")
            try connection.execute(
                "CREATE TABLE ZRECORD (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZADDRESS_CITY VARCHAR)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected missing flattened leaf to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZADDRESS_CITY")
                })
            })
        try driver.close()
    }

    func testFlattenedAttributeRemovalRejectsPartiallyMissingPhysicalComponents() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(
                        name: "address",
                        type: "Address",
                        options: [.flattened],
                        components: [
                            .init(name: "city", columnName: "address_city", type: "String"),
                            .init(name: "zip", columnName: "address_zip", type: "Int32"),
                        ])
                ])
        ])
        let destination = Schema([Schema.Entity(name: "Record")])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-flattened-partial-component"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("ALTER TABLE ZRECORD DROP COLUMN ZADDRESS_ZIP")
        }
        let originalColumns = try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            })
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }, originalColumns)
        try driver.close()
    }

    func testFlattenedAttributeRemovalRejectsCaseVariantPhysicalLeafIndex() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(
                        name: "address",
                        type: "Address",
                        options: [.flattened],
                        components: [
                            .init(name: "city", columnName: "address_city", type: "String"),
                            .init(name: "zip", columnName: "address_zip", type: "Int32"),
                        ])
                ])
        ])
        let destination = Schema([Schema.Entity(name: "Record")])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-flattened-case-variant-index"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("CREATE INDEX USER_ADDRESS_CITY_CASE_VARIANT ON ZRECORD (zaddress_city)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected case-variant leaf index to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZADDRESS_CITY")
                })
            })
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE name = 'USER_ADDRESS_CITY_CASE_VARIANT'").count == 1
            })
        try driver.close()
    }

    func testScalarOptionalAdditionComposesWithOptionalToOneRemoval() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "obsolete", type: "String")],
                relationships: [Schema.Relationship(name: "target", destination: "Target")]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner", attributes: [Schema.Attribute(name: "note", type: "String", isOptional: true)]),
            Schema.Entity(name: "Target"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "scalar-optional-add-to-one-remove"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZTARGET (Z_ENT, Z_OPT) VALUES (2, 6)")
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZOBSOLETE, ZTARGET) VALUES (1, 8, 'drop', 1)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT, ZNOTE FROM ZOWNER") },
            [[.int(1), .int(1), .int(8), .null]])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT FROM ZTARGET") },
            [[.int(1), .int(2), .int(6)]])
        try driver.close()
    }

    func testScalarDefaultedAdditionComposesWithOptionalToOneRemoval() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "obsolete", type: "String")],
                relationships: [Schema.Relationship(name: "target", destination: "Target")]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner", attributes: [Schema.Attribute(name: "rank", type: "Int16", defaultValue: "11")]),
            Schema.Entity(name: "Target"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "scalar-default-add-to-one-remove"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZOBSOLETE, ZTARGET) VALUES (1, 9, 'drop', NULL)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZRANK FROM ZOWNER") },
            [[.int(1), .int(9), .int(11)]])
        try driver.close()
    }

    func testScalarAdditionIndexComposesWithOptionalToOneRemoval() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "obsolete", type: "String")],
                relationships: [Schema.Relationship(name: "target", destination: "Target")]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "note", type: "String", isOptional: true)],
                indexes: [Schema.Index(properties: ["note"])]),
            Schema.Entity(name: "Target"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "scalar-index-add-to-one-remove"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZTARGET (Z_ENT, Z_OPT) VALUES (2, 4)")
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZOBSOLETE, ZTARGET) VALUES (1, 6, 'drop', 1)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZOWNER'")
            },
            [[.text("ZOWNER_ZNOTE_INDEX"), .text("CREATE INDEX ZOWNER_ZNOTE_INDEX ON ZOWNER (ZNOTE)")]])
        XCTAssertEqual(try driver.read { try $0.rows("SELECT Z_PK, ZNOTE FROM ZOWNER") }, [[.int(1), .null]])
        try driver.close()
    }

    func testUniqueScalarAdditionWithRelationshipRemovalFailsAtomically() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "obsolete", type: "String")],
                relationships: [Schema.Relationship(name: "target", destination: "Target")]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "identity", type: "String", isOptional: true, options: [.unique])]),
            Schema.Entity(name: "Target"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "unique-add-to-one-remove-reject"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZOBSOLETE, ZTARGET) VALUES (1, 2, 'keep', NULL)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            })
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZOWNER)").contains(where: { $0.count > 1 && $0[1] == .text("ZTARGET") })
            })
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZOWNER)").contains(where: { $0.count > 1 && $0[1] == .text("ZOBSOLETE") }
                )
            })
        try driver.close()
    }

    func testScalarRemovalCanAddIndexOnRetainedAttribute() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "kept", type: "String"),
                    Schema.Attribute(name: "obsolete", type: "Int32"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "kept", type: "String")],
                indexes: [Schema.Index(properties: ["kept"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-scalar-add-retained-index"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZKEPT, ZOBSOLETE) VALUES (1, 3, 'kept', 5)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZKEPT FROM ZRECORD") },
            [[.int(1), .int(3), .text("kept")]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [[.text("ZRECORD_ZKEPT_INDEX")]])
        try driver.close()
    }

    func testScalarRemovalAndIndexNameCollisionRollBackColumnDrop() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "kept", type: "String"),
                    Schema.Attribute(name: "obsolete", type: "Int32"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "kept", type: "String")],
                indexes: [Schema.Index(properties: ["kept"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-scalar-index-collision-rollback"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZKEPT, ZOBSOLETE) VALUES (1, 3, 'kept', 5)")
            try connection.execute("CREATE TABLE ZRECORD_ZKEPT_INDEX (value INTEGER)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected destination index collision to fail, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZOBSOLETE")
                })
            })
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT ZKEPT, ZOBSOLETE FROM ZRECORD") }, [[.text("kept"), .int(5)]])
        try driver.close()
    }

    func testScalarRemovalRejectsDestinationIndexReferencingRemovedAttribute() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "kept", type: "String"),
                    Schema.Attribute(name: "obsolete", type: "Int32"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "kept", type: "String")],
                indexes: [Schema.Index(properties: ["obsolete"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-scalar-index-removed-column"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected index on removed column to fail, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZOBSOLETE")
                })
            })
        try driver.close()
    }

    func testScalarRemovalCanReplaceIndexOnRetainedAttributes() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "String"),
                    Schema.Attribute(name: "second", type: "String"),
                    Schema.Attribute(name: "obsolete", type: "Int32"),
                ],
                indexes: [Schema.Index(properties: ["first", "second"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "String"),
                    Schema.Attribute(name: "second", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["second", "first"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-scalar-replace-retained-index"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND, ZOBSOLETE) VALUES (1, 8, 'a', 'b', 3)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
            },
            [
                [
                    .text("ZRECORD_ZSECOND_ZFIRST_INDEX"),
                    .text("CREATE INDEX ZRECORD_ZSECOND_ZFIRST_INDEX ON ZRECORD (ZSECOND, ZFIRST)"),
                ]
            ])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZFIRST, ZSECOND FROM ZRECORD") },
            [[.int(1), .int(8), .text("a"), .text("b")]])
        try driver.close()
    }

    func testScalarRemovalCanRemoveIndexOnRetainedAttributes() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "kept", type: "String"),
                    Schema.Attribute(name: "obsolete", type: "Int32"),
                ],
                indexes: [Schema.Index(properties: ["kept"])])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "kept", type: "String")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "remove-scalar-remove-retained-index"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZKEPT, ZOBSOLETE) VALUES (1, 6, 'kept', 4)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'").isEmpty
            })
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZKEPT FROM ZRECORD") },
            [[.int(1), .int(6), .text("kept")]])
        try driver.close()
    }

    func testMultipleScalarRemovalAllowsCompositeIndexWhollyOnRemovedColumns() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-removals-composite-index"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "kept", type: "String"),
                    Schema.Attribute(name: "left", type: "Int32"),
                    Schema.Attribute(name: "right", type: "Int32"),
                ],
                indexes: [Schema.Index(properties: ["left", "right"])])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "kept", type: "String")])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZKEPT, ZLEFT, ZRIGHT) VALUES (1, 5, 'kept', 1, 2)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(try driver.read { try $0.rows("SELECT ZKEPT FROM ZRECORD") }, [[.text("kept")]])
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'").isEmpty
            })
        try driver.close()
    }

    func testMultipleScalarRemovalRejectsUniqueIndexesSharedWithRetainedAttributes() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "kept", type: "String"),
                    Schema.Attribute(name: "removed", type: "Int32"),
                ],
                indexes: [Schema.Index(properties: ["kept", "removed"], isUnique: true)])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "kept", type: "String")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-removals-mixed-unique"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected mixed unique index removal to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }.count, 5)
        try driver.close()
    }

    func testMultipleScalarRemovalRejectsTamperedGeneratedUniqueIndex() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "kept", type: "String"),
                    Schema.Attribute(name: "removed", type: "Int32", options: [.unique]),
                ])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "kept", type: "String")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-removals-tampered-unique"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("DROP INDEX ZRECORD_ZREMOVED_UNIQUE_INDEX")
            try connection.execute("CREATE INDEX ZRECORD_ZREMOVED_UNIQUE_INDEX ON ZRECORD (ZREMOVED)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected tampered generated unique index to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: { $0.count > 1 && $0[1] == .text("ZREMOVED") }
                )
            })
        try driver.close()
    }

    func testMultipleScalarRemovalPreservesSameNamedIndexOnOtherTable() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "kept", type: "String"), Schema.Attribute(name: "removed", type: "Int32"),
                ]),
            Schema.Entity(name: "ZRecord", attributes: [Schema.Attribute(name: "value", type: "Int32")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "kept", type: "String")]),
            Schema.Entity(name: "ZRecord", attributes: [Schema.Attribute(name: "value", type: "Int32")]),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-removals-index-other-table"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("CREATE TABLE ZUNRELATED (Z_PK INTEGER PRIMARY KEY, ZREMOVED INTEGER)")
            try connection.execute("CREATE INDEX ZRECORD_ZREMOVED_INDEX ON ZUNRELATED (ZREMOVED)")
        }
        try driver.write {
            try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT tbl_name FROM sqlite_master WHERE type = 'index' AND name = 'ZRECORD_ZREMOVED_INDEX'")
            },
            [[.text("ZUNRELATED")]])
        try driver.close()
    }

    func testMultipleScalarRemovalRejectsCheckDependenciesBeforeDdl() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("multiple-drop-rollback.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "kept", type: "String"),
                    Schema.Attribute(name: "first", type: "Int32"),
                    Schema.Attribute(name: "second", type: "Int32"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "kept", type: "String")])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZKEPT, ZFIRST, ZSECOND) VALUES (1, 2, 'kept', 3, 4)")
        }
        let originalHash = try initial.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                .first?.first
        }
        try initial.close()

        let tampered = try GRDBSQLiteDriver(location: location)
        try tampered.write { connection in
            try connection.execute(
                "CREATE TABLE ZRECORD_TMP (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, "
                    + "ZKEPT VARCHAR, ZFIRST INTEGER, ZSECOND INTEGER, CHECK (ZSECOND >= 0))")
            try connection.execute(
                "INSERT INTO ZRECORD_TMP (Z_PK, Z_ENT, Z_OPT, ZKEPT, ZFIRST, ZSECOND) "
                    + "SELECT Z_PK, Z_ENT, Z_OPT, ZKEPT, ZFIRST, ZSECOND FROM ZRECORD")
            try connection.execute("DROP TABLE ZRECORD")
            try connection.execute("ALTER TABLE ZRECORD_TMP RENAME TO ZRECORD")
        }
        try tampered.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination))
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZKEPT, ZFIRST, ZSECOND FROM ZRECORD") },
            [[.int(1), .int(2), .text("kept"), .int(3), .int(4)]])
        XCTAssertEqual(
            try reopened.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                    .first?.first
            },
            originalHash)
        XCTAssertTrue(
            try reopened.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: { $0.count > 1 && $0[1] == .text("ZFIRST") })
            })
        try reopened.close()
    }

    func testMultipleScalarRemovalRejectsUnexpectedPhysicalColumns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("unexpected-column.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "kept", type: "String"),
                    Schema.Attribute(name: "first", type: "Int32"),
                    Schema.Attribute(name: "second", type: "Int32"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "kept", type: "String")])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZKEPT, ZFIRST, ZSECOND) VALUES (1, 7, 'kept', 1, 2)")
            try connection.execute("ALTER TABLE ZRECORD ADD COLUMN ZUNTRACKED BLOB")
        }
        let originalHash = try initial.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                .first?.first
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected unexpected physical column to fail closed, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZKEPT, ZFIRST, ZSECOND, ZUNTRACKED FROM ZRECORD") },
            [[.int(1), .int(7), .text("kept"), .int(1), .int(2), .null]])
        XCTAssertEqual(
            try reopened.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                    .first?.first
            },
            originalHash)
        try reopened.close()
    }

    func testMultipleScalarRemovalAllowsUnrelatedForeignKeys() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-removals-unrelated-fk"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "kept", type: "String"),
                    Schema.Attribute(name: "removed", type: "Int32"),
                ]),
            Schema.Entity(name: "Other"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "kept", type: "String")]),
            Schema.Entity(name: "Other"),
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("CREATE TABLE USER_REFERENCE (Z_TARGET INTEGER REFERENCES ZOTHER(Z_PK))")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZKEPT, ZREMOVED) VALUES (1, 3, 'kept', 7)")
        }
        try driver.write {
            try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
        }
        XCTAssertEqual(try driver.read { try $0.rows("SELECT ZKEPT FROM ZRECORD") }, [[.text("kept")]])
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA foreign_key_list(USER_REFERENCE)") }.count, 1)
        try driver.close()
    }

    func testUniqueIndexOnRemovedAttributeStillFailsClosed() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "unique-indexed-attribute-removal"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "obsolete", type: "Int")],
                indexes: [Schema.Index(properties: ["obsolete"], isUnique: true)])
        ])
        let destination = Schema([Schema.Entity(name: "Record")])
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected unique index removal to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
                .contains(where: { $0.count > 1 && $0[1] == .text("ZOBSOLETE") }))
        try driver.close()
    }

    func testAttributeUniqueConstraintRemovalPreservesRowsAndAllowsDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "email", type: "String", options: [.unique]),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["email"], isUnique: true)])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "label", type: "String")])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZEMAIL, ZLABEL) VALUES (1, 4, 'one', 'a')")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZEMAIL, ZLABEL) VALUES (1, 5, 'two', 'b')")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertFalse(
            try migrated.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
                .contains(where: { $0.count > 1 && $0[1] == .text("ZEMAIL") }))
        XCTAssertTrue(
            try migrated.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZRECORD_ZEMAIL_UNIQUE_INDEX'"
                )
                .isEmpty
            })
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZLABEL FROM ZRECORD ORDER BY Z_PK") },
            [[.int(1), .int(4), .text("a")], [.int(2), .int(5), .text("b")]])
        try migrated.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZLABEL) VALUES (1, 6, 'duplicate email no longer constrained')")
        }
        XCTAssertEqual(try migrated.read { try $0.rows("SELECT COUNT(*) FROM ZRECORD") }, [[.int(3)]])
        try migrated.close()
    }

    func testCompositeUniqueIndexOnRemovedAttributeStillFailsClosed() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "composite-unique-attribute-removal"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "obsolete", type: "Int"),
                    Schema.Attribute(name: "scope", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["obsolete", "scope"], isUnique: true)])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "scope", type: "String")])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZOBSOLETE, ZSCOPE) VALUES (1, 1, 5, 'a')")
            XCTAssertThrowsError(
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected composite unique constraint removal to fail closed, got \(error)")
                }
            }
            XCTAssertEqual(try connection.rows("SELECT ZOBSOLETE, ZSCOPE FROM ZRECORD"), [[.int(5), .text("a")]])
            XCTAssertTrue(
                try connection.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZRECORD_ZOBSOLETE_ZSCOPE_UNIQUE_INDEX'"
                )
                .count == 1)
        }
        try driver.close()
    }

    func testIndexedAttributeRemovalPreflightsSideEffectsBeforeDroppingIndexes() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "indexed-removal-preflight"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "obsolete", type: "Int"),
                    Schema.Attribute(name: "title", type: "String"),
                ],
                indexes: [
                    Schema.Index(properties: ["obsolete"]),
                    Schema.Index(properties: ["title"]),
                ])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "CREATE TRIGGER BLOCK_REMOVAL AFTER UPDATE ON ZRECORD BEGIN SELECT 1; END")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected removal side-effect preflight to reject, got \(error)")
            }
        }
        let indexNames = try driver.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
        }.compactMap { row -> String? in
            guard case let .text(name)? = row.first else { return nil }
            return name
        }
        XCTAssertTrue(indexNames.contains("ZRECORD_ZOBSOLETE_INDEX"))
        XCTAssertTrue(indexNames.contains("ZRECORD_ZTITLE_INDEX"))
        XCTAssertTrue(
            try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
                .contains(where: { $0.count > 1 && $0[1] == .text("ZOBSOLETE") }))
        try driver.close()
    }

    func testIndexedAttributeRemovalRejectsPartialAndExpressionIndexes() throws {
        let rawIndexes = [
            ("partial", "CREATE INDEX USER_PARTIAL_INDEX ON ZRECORD (ZTITLE) WHERE ZOBSOLETE > 0"),
            ("expression", "CREATE INDEX USER_EXPRESSION_INDEX ON ZRECORD (ZOBSOLETE + 1)"),
        ]
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "obsolete", type: "Int"),
                    Schema.Attribute(name: "title", type: "String"),
                ],
                indexes: [Schema.Index(properties: ["obsolete"])])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")])
        ])
        for (kind, statement) in rawIndexes {
            let driver = try GRDBSQLiteDriver(location: .memory(name: "attribute-removal-raw-index-\(kind)"))
            try bootstrap(source, driver: driver)
            try driver.write { try $0.execute(statement) }
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected \(kind) index to reject removal, got \(error)")
                }
            }
            XCTAssertTrue(
                try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
                    .contains(where: { $0.count > 1 && $0[1] == .text("ZOBSOLETE") }))
            let indexName = kind == "partial" ? "USER_PARTIAL_INDEX" : "USER_EXPRESSION_INDEX"
            XCTAssertEqual(
                try driver.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?", [.text(indexName)])
                        .count
                },
                1)
            try driver.close()
        }
    }

    func testRelationshipBearingEntityRemovalFailsWithoutChangingStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [Schema.Relationship(name: "favorite", destination: "Target")]),
            Schema.Entity(name: "Target", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "Owner", attributes: [Schema.Attribute(name: "name", type: "String")])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZNAME, ZFAVORITE) VALUES (1, 1, 'owner', 1)")
            try connection.execute("INSERT INTO ZTARGET (Z_ENT, Z_OPT, ZNAME) VALUES (2, 1, 'target')")
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT ZNAME, ZFAVORITE FROM ZOWNER") },
            [[.text("owner"), .int(1)]])
        XCTAssertEqual(try reopened.read { try $0.rows("SELECT ZNAME FROM ZTARGET") }, [[.text("target")]])
        try reopened.close()
    }

    func testEntityRemovalRejectsExternalStorageAndOrphanTables() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceWithExternalStorage = Schema([
            Schema.Entity(
                name: "Removed",
                attributes: [Schema.Attribute(name: "payload", type: "Data", options: [.externalStorage])]),
            Schema.Entity(name: "Retained"),
        ])
        let destination = Schema([Schema.Entity(name: "Retained")])
        let externalLocation = StoreLocation.file(directory.appendingPathComponent("external.sqlite"))
        let externalStore = try LightweightMigration.openStore(
            location: externalLocation, schema: sourceWithExternalStorage)
        try externalStore.close()
        XCTAssertThrowsError(try LightweightMigration.openStore(location: externalLocation, schema: destination)) {
            error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let externalReopened = try LightweightMigration.openStore(
            location: externalLocation, schema: sourceWithExternalStorage)
        XCTAssertTrue(
            try externalReopened.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZREMOVED'").count == 1
            })
        try externalReopened.close()

        let plainSource = Schema([Schema.Entity(name: "Removed"), Schema.Entity(name: "Retained")])
        let orphanLocation = StoreLocation.file(directory.appendingPathComponent("orphan.sqlite"))
        let orphanStore = try LightweightMigration.openStore(location: orphanLocation, schema: plainSource)
        try orphanStore.write { connection in
            try connection.execute("CREATE TABLE ZORPHAN_JOIN (Z_A INTEGER, Z_B INTEGER)")
        }
        try orphanStore.close()
        XCTAssertThrowsError(try LightweightMigration.openStore(location: orphanLocation, schema: destination)) {
            error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let orphanReopened = try LightweightMigration.openStore(location: orphanLocation, schema: plainSource)
        XCTAssertTrue(
            try orphanReopened.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZORPHAN_JOIN'").count == 1
            })
        try orphanReopened.close()
    }

    func testEntityRemovalRejectsUntrackedIndexes() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "entity-removal-untracked-index"))
        let source = Schema([Schema.Entity(name: "Removed"), Schema.Entity(name: "Retained")])
        let destination = try Schema(
            [Schema.Entity(name: "Retained")],
            entityIDs: ["Retained": try XCTUnwrap(source.entityIDsByName["Retained"])])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("CREATE INDEX USER_REMOVAL_INDEX ON ZREMOVED (Z_PK)")
            XCTAssertThrowsError(
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected migrationUnsupported, got \(error)")
                }
            }
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?", [.text("USER_REMOVAL_INDEX")])
            },
            [[.text("USER_REMOVAL_INDEX")]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZREMOVED'")
            },
            [[.text("ZREMOVED")]])
        try driver.close()
    }

    func testEntityRemovalRejectsUntrackedIndexOnRetainedTable() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "entity-removal-retained-untracked-index"))
        let source = Schema([
            Schema.Entity(name: "Removed"),
            Schema.Entity(name: "Retained", attributes: [Schema.Attribute(name: "value", type: "Int")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "Retained", attributes: [Schema.Attribute(name: "value", type: "Int")])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("CREATE INDEX USER_RETAINED_INDEX ON ZRETAINED (Z_PK)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected retained custom index to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZREMOVED'").count == 1
            })
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'USER_RETAINED_INDEX'")
                    .count == 1
            })
        try driver.close()
    }

    func testEntityRemovalRejectsSQLiteAutoindexOnRetainedTable() throws {
        let source = Schema([
            Schema.Entity(name: "Removed"),
            Schema.Entity(name: "Retained", attributes: [Schema.Attribute(name: "value", type: "Int")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "Retained", attributes: [Schema.Attribute(name: "value", type: "Int")])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "entity-removal-retained-autoindex"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("DROP TABLE ZRETAINED")
            try connection.execute(
                "CREATE TABLE ZRETAINED (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZVALUE INTEGER UNIQUE)"
            )
            try connection.execute("INSERT INTO ZRETAINED (Z_PK, Z_ENT, Z_OPT, ZVALUE) VALUES (1, 2, 1, 7)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected retained SQLite autoindex to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZREMOVED'").count == 1
            })
        XCTAssertEqual(try driver.read { try $0.rows("SELECT ZVALUE FROM ZRETAINED") }, [[.int(7)]])
        try driver.close()
    }

    func testEntityRemovalRejectsSQLiteAutoindexOnRemovedTable() throws {
        let source = Schema([
            Schema.Entity(name: "Removed", attributes: [Schema.Attribute(name: "value", type: "Int")]),
            Schema.Entity(name: "Retained"),
        ])
        let destination = Schema([Schema.Entity(name: "Retained")])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "entity-removal-removed-autoindex"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("DROP TABLE ZREMOVED")
            try connection.execute(
                "CREATE TABLE ZREMOVED (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZVALUE INTEGER UNIQUE)")
            try connection.execute("INSERT INTO ZREMOVED (Z_PK, Z_ENT, Z_OPT, ZVALUE) VALUES (1, 1, 1, 7)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected removed-table SQLite autoindex to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZREMOVED'").count == 1
            })
        try driver.close()
    }

    func testEntityRemovalPreservesRetainedRelationshipJoinTables() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "tags", destination: "Tag", isToMany: true, inverse: "owners")
                ]),
            Schema.Entity(name: "RetainedRoot", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "Tag",
                relationships: [
                    Schema.Relationship(name: "owners", destination: "Owner", isToMany: true, inverse: "tags")
                ]),
            Schema.Entity(name: "ZRemovedRoot"),
        ])
        let destination = Schema(source.entities.filter { $0.name != "ZRemovedRoot" })
        let built = try SchemaBuilder.build(source)
        let joinStatement = try XCTUnwrap(
            built.statements.first { statement in
                let components = statement.split(separator: " ")
                return components.count > 2 && components[0] == "CREATE" && components[1] == "TABLE"
                    && components[2].hasPrefix("Z_") && components[2] != "Z_PRIMARYKEY"
            })
        let joinTable = try XCTUnwrap(joinStatement.split(separator: " ").dropFirst(2).first).description
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZOWNER (Z_ENT, Z_OPT) VALUES (?, ?)",
                [
                    .int(Int64(try XCTUnwrap(source.entityIDsByName["Owner"]))), .int(1),
                ])
            try connection.execute(
                "INSERT INTO ZTAG (Z_ENT, Z_OPT) VALUES (?, ?)",
                [
                    .int(Int64(try XCTUnwrap(source.entityIDsByName["Tag"]))), .int(1),
                ])
            try connection.execute("INSERT INTO \(joinTable) (Z_A, Z_B) VALUES (1, 1)")
            try connection.execute(
                "INSERT INTO ZZREMOVEDROOT (Z_ENT, Z_OPT) VALUES (?, ?)",
                [
                    .int(Int64(try XCTUnwrap(source.entityIDsByName["ZRemovedRoot"]))), .int(1),
                ])
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(try migrated.read { try $0.rows("SELECT Z_A, Z_B FROM \(joinTable)") }, [[.int(1), .int(1)]])
        try migrated.close()
    }

    func testEntityRemovalRejectsJoinTableOwnedByRemovedInverseDeclaration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(
                name: "Tag",
                relationships: [
                    Schema.Relationship(name: "owners", destination: "Owner", isToMany: true, inverse: "tags")
                ]),
            Schema.Entity(name: "ZRemovedRoot"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag"),
        ])
        let joinStatement = try XCTUnwrap(
            SchemaBuilder.build(source).statements.first(where: { statement in
                let components = statement.split(separator: " ")
                return components.count > 2 && components[0] == "CREATE" && components[1] == "TABLE"
                    && components[2].hasPrefix("Z_") && components[2] != "Z_PRIMARYKEY"
            }))
        let joinTable = try XCTUnwrap(joinStatement.split(separator: " ").dropFirst(2).first).description
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZOWNER (Z_ENT, Z_OPT) VALUES (?, ?)",
                [
                    .int(Int64(try XCTUnwrap(source.entityIDsByName["Owner"]))), .int(1),
                ])
            try connection.execute(
                "INSERT INTO ZTAG (Z_ENT, Z_OPT) VALUES (?, ?)",
                [
                    .int(Int64(try XCTUnwrap(source.entityIDsByName["Tag"]))), .int(1),
                ])
            try connection.execute("INSERT INTO \(joinTable) (Z_A, Z_B) VALUES (1, 1)")
            try connection.execute(
                "INSERT INTO ZZREMOVEDROOT (Z_ENT, Z_OPT) VALUES (?, ?)",
                [
                    .int(Int64(try XCTUnwrap(source.entityIDsByName["ZRemovedRoot"]))), .int(1),
                ])
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(try reopened.read { try $0.rows("SELECT Z_A, Z_B FROM \(joinTable)") }, [[.int(1), .int(1)]])
        try reopened.close()
    }

    func testEntityRemovalRejectsMissingRetainedJoinTable() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "missing-retained-join-table"))
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "tags", destination: "Tag", isToMany: true, inverse: "owners")
                ]),
            Schema.Entity(name: "RetainedRoot"),
            Schema.Entity(
                name: "Tag",
                relationships: [
                    Schema.Relationship(name: "owners", destination: "Owner", isToMany: true, inverse: "tags")
                ]),
            Schema.Entity(name: "ZRemovedRoot"),
        ])
        let destinationNames = Set(source.entities.map(\.name).filter { $0 != "ZRemovedRoot" })
        let destinationEntities = source.entities.filter { destinationNames.contains($0.name) }
        let destinationIDs = source.entityIDsByName.filter { destinationNames.contains($0.key) }
        let destination = try Schema(destinationEntities, entityIDs: destinationIDs)
        let joinStatement = try XCTUnwrap(
            SchemaBuilder.build(source).statements.first(where: { statement in
                let components = statement.split(separator: " ")
                return components.count > 2 && components[0] == "CREATE" && components[1] == "TABLE"
                    && components[2].hasPrefix("Z_") && components[2] != "Z_PRIMARYKEY"
            }))
        let joinTable = try XCTUnwrap(joinStatement.split(separator: " ").dropFirst(2).first).description
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write { connection in
                try connection.execute(
                    "INSERT INTO ZOWNER (Z_ENT, Z_OPT) VALUES (?, 1)",
                    [
                        .int(Int64(try XCTUnwrap(source.entityIDsByName["Owner"])))
                    ])
                try connection.execute(
                    "INSERT INTO ZTAG (Z_ENT, Z_OPT) VALUES (?, 1)",
                    [
                        .int(Int64(try XCTUnwrap(source.entityIDsByName["Tag"])))
                    ])
                try connection.execute(
                    "INSERT INTO ZZREMOVEDROOT (Z_ENT, Z_OPT) VALUES (?, 1)",
                    [
                        .int(Int64(try XCTUnwrap(source.entityIDsByName["ZRemovedRoot"])))
                    ])
                try connection.execute("DROP TABLE \(joinTable)")
                try LightweightMigration.migrate(
                    source: source, destination: destination, connection: connection)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZZREMOVEDROOT'").count == 1
            })
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY WHERE Z_NAME = 'ZRemovedRoot'") },
            [[.int(4), .text("ZRemovedRoot")]])
        try driver.close()
    }

    func testEntityIDMetadataBackfillRollsBackAsOneUnit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let schema = Schema([Schema.Entity(name: "Record")])
        let initial = try LightweightMigration.openStore(location: location, schema: schema)
        let originalHash = try initial.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
            ).first?.first
        }
        try initial.write { connection in
            try connection.execute("DELETE FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.entityIDsKey)])
            try connection.execute(
                "CREATE TRIGGER fail_entity_id_allocator BEFORE INSERT ON _osd_meta "
                    + "WHEN NEW.key = '\(LightweightMigration.entityIDHighWatermarkKey)' "
                    + "BEGIN SELECT RAISE(ABORT, 'allocator backfill failure'); END")
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: schema))
        let inspected = try GRDBSQLiteDriver(location: location)
        XCTAssertNil(
            try inspected.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.entityIDsKey)]
                ).first
            })
        XCTAssertEqual(
            try inspected.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
                ).first?
                .first
            },
            originalHash)
        try inspected.write { connection in
            try connection.execute("DROP TRIGGER fail_entity_id_allocator")
        }
        try inspected.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: schema)
        XCTAssertNotNil(
            try reopened.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.entityIDsKey)]
                ).first
            })
        XCTAssertEqual(try reopened.read { try LightweightMigration.storedNextEntityIdentifier(connection: $0) }, 2)
        try reopened.close()
    }

    func testEntityIDHighWatermarkRejectsMalformedValuesAndRepairsLowValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([Schema.Entity(name: "Alpha"), Schema.Entity(name: "Beta")])
        let location = StoreLocation.file(directory.appendingPathComponent("allocator.sqlite"))
        let initial = try LightweightMigration.openStore(location: location, schema: schema)
        try initial.write { connection in
            try connection.execute(
                "UPDATE _osd_meta SET value = ? WHERE key = ?",
                [.blob(Array("invalid".utf8)), .text(LightweightMigration.entityIDHighWatermarkKey)])
            XCTAssertEqual(
                try connection.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.entityIDHighWatermarkKey)]
                ).first?.first,
                .blob(Array("invalid".utf8)))
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: schema)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected invalid allocator metadata to fail closed, got \(error)")
            }
        }
        let repair = try GRDBSQLiteDriver(location: location)
        try repair.write { connection in
            try connection.execute(
                "UPDATE _osd_meta SET value = ? WHERE key = ?",
                [.blob(Array("1".utf8)), .text(LightweightMigration.entityIDHighWatermarkKey)])
            XCTAssertEqual(
                try connection.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.entityIDHighWatermarkKey)]
                ).first?.first,
                .blob(Array("1".utf8)))
        }
        try repair.close()

        let addedSchema = Schema([
            Schema.Entity(name: "Alpha"),
            Schema.Entity(name: "Beta"),
            Schema.Entity(name: "Gamma"),
        ])
        let added = try LightweightMigration.openStore(location: location, schema: addedSchema)
        XCTAssertEqual(
            try added.read { try $0.rows("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY ORDER BY Z_ENT") },
            [[.int(1), .text("Alpha")], [.int(2), .text("Beta")], [.int(3), .text("Gamma")]])
        XCTAssertEqual(try added.read { try LightweightMigration.storedNextEntityIdentifier(connection: $0) }, 4)
        try added.close()

        let emptyLocation = StoreLocation.file(directory.appendingPathComponent("empty.sqlite"))
        let empty = try LightweightMigration.openStore(location: emptyLocation, schema: Schema([]))
        XCTAssertEqual(try empty.read { try LightweightMigration.storedNextEntityIdentifier(connection: $0) }, 1)
        XCTAssertEqual(
            try empty.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.entityIDHighWatermarkKey)]
                ).first?.first
            },
            .blob(Array("1".utf8)))
        try empty.close()
        let firstEntity = try LightweightMigration.openStore(
            location: emptyLocation, schema: Schema([Schema.Entity(name: "First")]))
        XCTAssertEqual(
            try firstEntity.read { try $0.rows("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY") },
            [[.int(1), .text("First")]])
        try firstEntity.close()
    }

    func testOptionalToRequiredUniqueDefaultCollisionRollsBackAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String"),
                    Schema.Attribute(name: "priority", type: "Int", isOptional: true, options: [.unique]),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String"),
                    Schema.Attribute(name: "priority", type: "Int", defaultValue: "7", options: [.unique]),
                ])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZTITLE, ZPRIORITY) VALUES (?, ?, ?, ?)",
                [.int(1), .int(1), .text("existing-seven"), .int(7)])
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZTITLE, ZPRIORITY) VALUES (?, ?, ?, NULL)",
                [.int(1), .int(1), .text("null-one")])
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZTITLE, ZPRIORITY) VALUES (?, ?, ?, NULL)",
                [.int(1), .int(1), .text("null-two")])
        }
        let sourceHash = try initial.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
            ).first?.first
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT ZTITLE, ZPRIORITY FROM ZRECORD ORDER BY Z_PK") },
            [[.text("existing-seven"), .int(7)], [.text("null-one"), .null], [.text("null-two"), .null]])
        XCTAssertEqual(
            try reopened.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
                ).first?
                .first
            },
            sourceHash)
        try reopened.close()
    }

    func testOptionalToRequiredWithoutDefaultAndCombinedEntityChangesFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Int", isOptional: true)])
        ])
        let missingDefault = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Int")])
        ])
        let combinedChange = Schema([
            Schema.Entity(name: "Extra"),
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "value", type: "Int", defaultValue: "0")]),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZVALUE) VALUES (?, ?, NULL)", [.int(1), .int(1)])
        }
        try initial.close()

        for destination in [missingDefault, combinedChange] {
            XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected migrationUnsupported, got \(error)")
                }
            }
            let unchanged = try LightweightMigration.openStore(location: location, schema: source)
            XCTAssertEqual(
                try unchanged.read { try $0.rows("SELECT ZVALUE FROM ZRECORD") },
                [[.null]])
            try unchanged.close()
        }
    }

    func testAddingRequiredAttributeWithNonliteralDefaultFailsAtomically() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-dynamic-default"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String"),
                    Schema.Attribute(name: "identifier", type: "UUID", defaultValue: "UUID()"),
                ])
        ])
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
        XCTAssertFalse(columns.contains { $0.count > 1 && $0[1] == .text("ZIDENTIFIER") })
        try driver.close()
    }

    func testHierarchyRelationshipMigrationFailsBeforeCreatingPhysicalSchema() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-inherited-relationship"))
        let source = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(name: "Child", superentityName: "Base"),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(
                name: "Child",
                relationships: [
                    Schema.Relationship(
                        name: "target", destination: "Target", declaringEntityName: "Child")
                ],
                superentityName: "Base"),
            Schema.Entity(name: "Target"),
        ])

        XCTAssertThrowsError(
            try driver.write { connection in
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let tables = try driver.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        }
        XCTAssertTrue(tables.isEmpty)
        try driver.close()
    }

    func testHierarchyIndexMigrationFailsBeforeCreatingPhysicalSchema() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-hierarchy-index"))
        let source = Schema([
            Schema.Entity(name: "Base", attributes: [Schema.Attribute(name: "code", type: "String")]),
            Schema.Entity(
                name: "Child",
                attributes: [Schema.Attribute(name: "code", type: "String")],
                superentityName: "Base"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Base",
                attributes: [Schema.Attribute(name: "code", type: "String")],
                indexes: [Schema.Index(properties: ["code"], isUnique: true)]),
            Schema.Entity(
                name: "Child",
                attributes: [Schema.Attribute(name: "code", type: "String")],
                indexes: [Schema.Index(properties: ["code"], isUnique: true)],
                superentityName: "Base"),
        ])

        XCTAssertThrowsError(
            try driver.write { connection in
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let tables = try driver.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        }
        XCTAssertTrue(tables.isEmpty)
        try driver.close()
    }

    func testHierarchyAddOptionalSubtypeAttributeAndReopen() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-hierarchy-add-optional"))
        let source = Schema([
            Schema.Entity(name: "Base", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "Child",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "age", type: "Int"),
                ],
                superentityName: "Base"),
            Schema.Entity(
                name: "Grandchild",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "age", type: "Int"),
                    Schema.Attribute(name: "rank", type: "Int"),
                ],
                superentityName: "Child"),
            Schema.Entity(
                name: "Sibling",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "label", type: "String"),
                ],
                superentityName: "Base"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Base",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "rootNote", type: "String", isOptional: true),
                ]),
            Schema.Entity(
                name: "Child",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "age", type: "Int"),
                    Schema.Attribute(name: "note", type: "String", isOptional: true),
                    Schema.Attribute(name: "rootNote", type: "String", isOptional: true),
                ],
                superentityName: "Base"),
            Schema.Entity(
                name: "Grandchild",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "age", type: "Int"),
                    Schema.Attribute(name: "rank", type: "Int"),
                    Schema.Attribute(name: "note", type: "String", isOptional: true),
                    Schema.Attribute(name: "rankNote", type: "String", isOptional: true),
                    Schema.Attribute(name: "rootNote", type: "String", isOptional: true),
                ],
                superentityName: "Child"),
            Schema.Entity(
                name: "Sibling",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "label", type: "String"),
                    Schema.Attribute(name: "note", type: "String", isOptional: true),
                    Schema.Attribute(name: "rootNote", type: "String", isOptional: true),
                ],
                superentityName: "Base"),
        ])

        try driver.write { try LightweightMigration.openOrMigrate(to: source, connection: $0) }
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZBASE (Z_ENT, Z_OPT, ZAGE, ZNAME) VALUES (?, ?, ?, ?)",
                [.int(Int64(source.entityIDsByName["Child"] ?? 0)), .int(1), .int(7), .text("saved")])
            try connection.execute(
                "INSERT INTO ZBASE (Z_ENT, Z_OPT, ZAGE, ZNAME, ZRANK) VALUES (?, ?, ?, ?, ?)",
                [.int(Int64(source.entityIDsByName["Grandchild"] ?? 0)), .int(1), .int(8), .text("grand"), .int(3)])
            try connection.execute(
                "INSERT INTO ZBASE (Z_ENT, Z_OPT, ZLABEL, ZNAME) VALUES (?, ?, ?, ?)",
                [.int(Int64(source.entityIDsByName["Sibling"] ?? 0)), .int(1), .text("side"), .text("sibling")])
        }
        try driver.write { try LightweightMigration.openOrMigrate(to: destination, connection: $0) }
        let rows = try driver.read {
            try $0.rows(
                "SELECT Z_ENT, ZNAME, ZAGE, ZRANK, ZLABEL, ZROOTNOTE, ZNOTE, ZRANKNOTE FROM ZBASE ORDER BY Z_PK")
        }
        XCTAssertEqual(
            rows,
            [
                [
                    .int(Int64(source.entityIDsByName["Child"] ?? 0)), .text("saved"), .int(7), .null, .null, .null,
                    .null, .null,
                ],
                [
                    .int(Int64(source.entityIDsByName["Grandchild"] ?? 0)), .text("grand"), .int(8), .int(3), .null,
                    .null, .null, .null,
                ],
                [
                    .int(Int64(source.entityIDsByName["Sibling"] ?? 0)), .text("sibling"), .null, .null, .text("side"),
                    .null, .null, .null,
                ],
            ])
        try driver.write { try LightweightMigration.openOrMigrate(to: destination, connection: $0) }
        try driver.close()
    }

    func testHierarchyLeafSubclassAdditionKeepsStoredIDsAndAddsNullableColumns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Animal", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "Dog",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"), Schema.Attribute(name: "age", type: "Int"),
                ],
                superentityName: "Animal"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Animal", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "Bird",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "wingSpan", type: "Double", isOptional: true),
                ],
                superentityName: "Animal"),
            Schema.Entity(
                name: "Cat",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "furColor", type: "String", isOptional: true),
                ],
                superentityName: "Animal"),
            Schema.Entity(
                name: "Dog",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"), Schema.Attribute(name: "age", type: "Int"),
                ],
                superentityName: "Animal"),
        ])
        let sourceDriver = try LightweightMigration.openStore(location: location, schema: source)
        let sourceIDs = source.entityIDsByName
        try sourceDriver.write { connection in
            try connection.execute(
                "INSERT INTO ZANIMAL (Z_ENT, Z_OPT, ZNAME, ZAGE) VALUES (?, 1, ?, ?)",
                [.int(Int64(sourceIDs["Dog"]!)), .text("old dog"), .int(4)])
            try connection.execute(
                "INSERT INTO ZANIMAL (Z_ENT, Z_OPT, ZNAME) VALUES (?, 1, ?)",
                [.int(Int64(sourceIDs["Animal"]!)), .text("old animal")])
        }
        try sourceDriver.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let runtimeIDs = try migrated.read {
            try LightweightMigration.storedEntityIDs(schema: destination, connection: $0)
        }
        let destinationIDs = try XCTUnwrap(runtimeIDs)
        let animalID = try XCTUnwrap(destinationIDs["Animal"])
        let dogID = try XCTUnwrap(destinationIDs["Dog"])
        let birdID = try XCTUnwrap(destinationIDs["Bird"])
        let catID = try XCTUnwrap(destinationIDs["Cat"])
        XCTAssertEqual(animalID, sourceIDs["Animal"])
        XCTAssertEqual(dogID, sourceIDs["Dog"])
        XCTAssertEqual(Set([birdID, catID]).count, 2)
        XCTAssertTrue([birdID, catID].allSatisfy { $0 > (sourceIDs.values.max() ?? 0) })
        let rows = try migrated.read {
            try $0.rows("SELECT Z_PK, Z_ENT, ZNAME, ZFURCOLOR FROM ZANIMAL ORDER BY Z_PK")
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][2...], [.text("old dog"), .null])
        XCTAssertEqual(rows[1][2...], [.text("old animal"), .null])
        let catMetadata = try migrated.read {
            try $0.rows(
                "SELECT Z_SUPER, Z_MAX FROM Z_PRIMARYKEY WHERE Z_ENT = ?", [.int(Int64(catID))])
        }
        XCTAssertEqual(catMetadata, [[.int(Int64(animalID)), .int(0)]])
        let birdMetadata = try migrated.read {
            try $0.rows("SELECT Z_SUPER, Z_MAX FROM Z_PRIMARYKEY WHERE Z_ENT = ?", [.int(Int64(birdID))])
        }
        XCTAssertEqual(birdMetadata, [[.int(Int64(animalID)), .int(0)]])
        let catPrimaryKey = try migrated.write { connection -> Int64 in
            try connection.execute(
                "INSERT INTO ZANIMAL (Z_ENT, Z_OPT, ZNAME, ZFURCOLOR) VALUES (?, 1, ?, ?)",
                [.int(Int64(catID)), .text("new cat"), .text("black")])
            return connection.lastInsertRowID()
        }
        XCTAssertFalse(rows.contains { $0.first == .int(catPrimaryKey) })
        let insertedCat = try migrated.read {
            try $0.rows("SELECT Z_ENT, ZNAME, ZFURCOLOR FROM ZANIMAL WHERE Z_PK = ?", [.int(catPrimaryKey)])
        }
        XCTAssertEqual(insertedCat, [[.int(Int64(catID)), .text("new cat"), .text("black")]])
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try reopened.read { try LightweightMigration.storedEntityIDs(schema: destination, connection: $0) },
            destinationIDs)
        try reopened.close()
    }

    func testHierarchyLeafMigrationAddsSubtypeIndexesAndExpandsAncestorIndexScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(
                name: "Child",
                attributes: [Schema.Attribute(name: "age", type: "Int")],
                indexes: [Schema.Index(properties: ["age"])],
                superentityName: "Base"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(
                name: "Child",
                attributes: [Schema.Attribute(name: "age", type: "Int")],
                indexes: [Schema.Index(properties: ["age"])],
                superentityName: "Base"),
            Schema.Entity(
                name: "Cat",
                attributes: [
                    Schema.Attribute(name: "code", type: "String", isOptional: true, options: [.unique]),
                    Schema.Attribute(name: "label", type: "String", isOptional: true),
                ],
                indexes: [Schema.Index(properties: ["label"])],
                superentityName: "Child"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let identifiers = try XCTUnwrap(
            migrated.read {
                try LightweightMigration.storedEntityIDs(schema: destination, connection: $0)
            })
        let childID = try XCTUnwrap(identifiers["Child"])
        let catID = try XCTUnwrap(identifiers["Cat"])
        let expectedIndexStatements = try SchemaBuilder.build(destination).statements.filter {
            $0.hasPrefix("CREATE INDEX") || $0.hasPrefix("CREATE UNIQUE INDEX")
        }.map { $0.hasSuffix(";") ? String($0.dropLast()) : $0 }.sorted()
        let storedIndexRows = try migrated.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'index' AND name LIKE 'Z%' ORDER BY name")
        }
        XCTAssertEqual(
            storedIndexRows.compactMap { row -> String? in
                guard case let .text(statement)? = row.first else { return nil }
                return statement
            }.sorted(),
            expectedIndexStatements)

        let ancestorIndex = try migrated.read {
            try $0.rows(
                "SELECT sql FROM sqlite_master WHERE name = ?",
                [.text("ZBASE_CHILD_ZAGE_INDEX")]
            ).first?.first
        }
        XCTAssertEqual(
            ancestorIndex,
            .text(
                "CREATE INDEX ZBASE_CHILD_ZAGE_INDEX ON ZBASE (ZAGE) WHERE Z_ENT IN (\(childID), \(catID))"))
        let catIndexes = expectedIndexStatements.filter { $0.contains("CAT") }
        XCTAssertEqual(catIndexes.count, 2)
        try migrated.close()
    }

    func testHierarchyMigrationRejectsTamperedPartialIndexBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(
                name: "Child",
                attributes: [Schema.Attribute(name: "age", type: "Int")],
                indexes: [Schema.Index(properties: ["age"])],
                superentityName: "Base"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(
                name: "Child",
                attributes: [Schema.Attribute(name: "age", type: "Int")],
                indexes: [Schema.Index(properties: ["age"])],
                superentityName: "Base"),
            Schema.Entity(
                name: "Cat",
                attributes: [Schema.Attribute(name: "label", type: "String", isOptional: true)],
                superentityName: "Child"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "hierarchy-tampered-partial-index"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("DROP INDEX ZBASE_CHILD_ZAGE_INDEX")
            try connection.execute("CREATE INDEX ZBASE_CHILD_ZAGE_INDEX ON ZBASE (Z_PK) WHERE Z_ENT IN (2)")
        }
        let originalIDs = try driver.read {
            try $0.rows("SELECT Z_ENT, Z_NAME, Z_SUPER, Z_MAX FROM Z_PRIMARYKEY ORDER BY Z_ENT")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected tampered hierarchy index to be rejected, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT Z_ENT, Z_NAME, Z_SUPER, Z_MAX FROM Z_PRIMARYKEY ORDER BY Z_ENT")
            },
            originalIDs)
        XCTAssertEqual(
            try driver.read { try $0.rows("PRAGMA table_info(ZBASE)").map { $0[1] } },
            [.text("Z_PK"), .text("Z_ENT"), .text("Z_OPT"), .text("ZAGE")])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'ZBASE_CHILD_ZAGE_INDEX'")
            },
            [[.text("CREATE INDEX ZBASE_CHILD_ZAGE_INDEX ON ZBASE (Z_PK) WHERE Z_ENT IN (2)")]])
        try driver.close()
    }

    func testHierarchyMigrationRejectsQuotedLiteralPredicateChange() throws {
        let source = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(
                name: "Child",
                attributes: [Schema.Attribute(name: "age", type: "Int")],
                indexes: [Schema.Index(properties: ["age"])],
                superentityName: "Base"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(
                name: "Child",
                attributes: [Schema.Attribute(name: "age", type: "Int")],
                indexes: [Schema.Index(properties: ["age"])],
                superentityName: "Base"),
            Schema.Entity(name: "Cat", superentityName: "Child"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "hierarchy-index-quoted-literal"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("DROP INDEX ZBASE_CHILD_ZAGE_INDEX")
            try connection.execute("CREATE INDEX ZBASE_CHILD_ZAGE_INDEX ON ZBASE (ZAGE) WHERE Z_ENT IN ('2;')")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected quoted predicate change to be rejected, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_NAME FROM Z_PRIMARYKEY ORDER BY Z_ENT") },
            [[.text("Base")], [.text("Child")]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'ZBASE_CHILD_ZAGE_INDEX'")
            },
            [[.text("CREATE INDEX ZBASE_CHILD_ZAGE_INDEX ON ZBASE (ZAGE) WHERE Z_ENT IN ('2;')")]])
        try driver.close()
    }

    func testHierarchyMigrationRejectsNonPartialReplacementForPartialIndex() throws {
        let source = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(
                name: "Child",
                attributes: [Schema.Attribute(name: "age", type: "Int")],
                indexes: [Schema.Index(properties: ["age"])],
                superentityName: "Base"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(
                name: "Child",
                attributes: [Schema.Attribute(name: "age", type: "Int")],
                indexes: [Schema.Index(properties: ["age"])],
                superentityName: "Base"),
            Schema.Entity(
                name: "Cat",
                attributes: [Schema.Attribute(name: "label", type: "String", isOptional: true)],
                superentityName: "Child"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "hierarchy-nonpartial-index-replacement"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("DROP INDEX ZBASE_CHILD_ZAGE_INDEX")
            try connection.execute("CREATE INDEX ZBASE_CHILD_ZAGE_INDEX ON ZBASE (ZAGE)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected non-partial replacement to be rejected, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_NAME, Z_SUPER FROM Z_PRIMARYKEY ORDER BY Z_ENT") },
            [[.text("Base"), .int(0)], [.text("Child"), .int(1)]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'ZBASE_CHILD_ZAGE_INDEX'")
            },
            [[.text("CREATE INDEX ZBASE_CHILD_ZAGE_INDEX ON ZBASE (ZAGE)")]])
        try driver.close()
    }

    func testAddingFirstLeafSubclassToFlatRootTable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Animal", attributes: [Schema.Attribute(name: "name", type: "String")])
        ])
        let destination = Schema([
            Schema.Entity(name: "Animal", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "Cat",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "furColor", type: "String", isOptional: true),
                ],
                superentityName: "Animal"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZANIMAL (Z_ENT, Z_OPT, ZNAME) VALUES (?, 1, ?)",
                [.int(Int64(source.entityIDsByName["Animal"] ?? 0)), .text("existing")])
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let identifiers = try XCTUnwrap(
            migrated.read {
                try LightweightMigration.storedEntityIDs(schema: destination, connection: $0)
            })
        XCTAssertEqual(identifiers["Animal"], source.entityIDsByName["Animal"])
        let catID = try XCTUnwrap(identifiers["Cat"])
        XCTAssertGreaterThan(catID, try XCTUnwrap(source.entityIDsByName.values.max()))
        let rows = try migrated.read { try $0.rows("SELECT Z_ENT, ZNAME, ZFURCOLOR FROM ZANIMAL") }
        XCTAssertEqual(rows, [[.int(Int64(try XCTUnwrap(identifiers["Animal"]))), .text("existing"), .null]])
        let parent: StoredValue? = try migrated.read {
            try $0.rows(
                "SELECT Z_SUPER FROM Z_PRIMARYKEY WHERE Z_ENT = ?", [.int(Int64(catID))]
            ).first?.first
        }
        XCTAssertEqual(parent, .int(Int64(try XCTUnwrap(identifiers["Animal"]))))
        try migrated.close()
    }

    func testAddingOptionalOwningToOneRelationshipToFlatEntity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Person", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Pet", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Person",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [
                    Schema.Relationship(
                        name: "pet", destination: "Pet", isOptional: true, inverse: nil)
                ]),
            Schema.Entity(name: "Pet", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let sourceIDs = source.entityIDsByName
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZPERSON (Z_ENT, Z_OPT, ZNAME) VALUES (?, 1, ?)",
                [.int(Int64(sourceIDs["Person"] ?? 0)), .text("existing")])
            try connection.execute(
                "INSERT INTO ZPET (Z_ENT, Z_OPT, ZNAME) VALUES (?, 1, ?)",
                [.int(Int64(sourceIDs["Pet"] ?? 0)), .text("companion")])
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let personRows = try migrated.read { try $0.rows("SELECT ZNAME, ZPET FROM ZPERSON") }
        XCTAssertEqual(personRows, [[.text("existing"), .null]])
        let destinationIDs = try XCTUnwrap(
            migrated.read { try LightweightMigration.storedEntityIDs(schema: destination, connection: $0) })
        XCTAssertEqual(destinationIDs, sourceIDs)
        let indexes = try migrated.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZPERSON'")
        }
        XCTAssertTrue(indexes.contains([.text("ZPERSON_ZPET_INDEX")]))
        try migrated.write { connection in
            try connection.execute("UPDATE ZPERSON SET ZPET = 1 WHERE ZNAME = ?", [.text("existing")])
        }
        let linkedRows = try migrated.read {
            try $0.rows(
                "SELECT person.ZNAME, pet.ZNAME FROM ZPERSON AS person "
                    + "JOIN ZPET AS pet ON pet.Z_PK = person.ZPET")
        }
        XCTAssertEqual(linkedRows, [[.text("existing"), .text("companion")]])
        try migrated.close()
    }

    func testFlatOwnerOnlyToManyRelationshipCanBeAddedAndRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Owner", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Tag", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let withRelationship = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let owner = try XCTUnwrap(withRelationship.entity(forName: "Owner"))
        let relationship = try XCTUnwrap(owner.relationships.first)
        let joinTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(
                for: owner, relationship: relationship, schema: withRelationship))
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZNAME) VALUES (1, 2, 'owner')")
            try connection.execute("INSERT INTO ZTAG (Z_ENT, Z_OPT, ZNAME) VALUES (2, 3, 'tag')")
        }
        try initial.close()

        let added = try LightweightMigration.openStore(location: location, schema: withRelationship)
        XCTAssertEqual(try added.read { try $0.rows("SELECT Z_A, Z_B FROM \(joinTable)") }, [])
        XCTAssertEqual(
            try added.read { try $0.rows("SELECT Z_PK, ZNAME FROM ZOWNER") },
            [[.int(1), .text("owner")]])
        XCTAssertEqual(
            try added.read { try $0.rows("SELECT Z_PK, ZNAME FROM ZTAG") },
            [[.int(1), .text("tag")]])
        let joinIndexes = try added.read {
            try $0.rows(
                "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? ORDER BY name",
                [
                    .text(joinTable)
                ])
        }
        XCTAssertEqual(joinIndexes.count, 2)
        try added.write { connection in
            try connection.execute("INSERT INTO \(joinTable) (Z_A, Z_B) VALUES (1, 1)")
        }
        try added.close()

        let removed = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertTrue(
            try removed.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
                    .isEmpty
            })
        XCTAssertEqual(
            try removed.read { try $0.rows("SELECT Z_PK, ZNAME FROM ZOWNER") },
            [[.int(1), .text("owner")]])
        XCTAssertEqual(
            try removed.read { try $0.rows("SELECT Z_PK, ZNAME FROM ZTAG") },
            [[.int(1), .text("tag")]])
        try removed.close()
    }

    func testMultipleFlatOwnerOnlyToManyRelationshipsCanBeRemovedTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("multiple-owner-to-many-removal.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [
                    Schema.Relationship(name: "tags", destination: "Tag", isToMany: true),
                    Schema.Relationship(name: "groups", destination: "Group", isToMany: true),
                ]),
            Schema.Entity(name: "Group", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Tag", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "Owner", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Group", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Tag", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let tagsTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(
                for: try XCTUnwrap(source.entity(forName: "Owner")),
                relationship: try XCTUnwrap(
                    source.entity(forName: "Owner")?.relationships.first(where: { $0.name == "tags" })),
                schema: source))
        let groupsTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(
                for: try XCTUnwrap(source.entity(forName: "Owner")),
                relationship: try XCTUnwrap(
                    source.entity(forName: "Owner")?.relationships.first(where: { $0.name == "groups" })),
                schema: source))
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZNAME) VALUES (2, 5, 'owner')")
            try connection.execute("INSERT INTO ZGROUP (Z_ENT, Z_OPT, ZNAME) VALUES (1, 7, 'group')")
            try connection.execute("INSERT INTO ZTAG (Z_ENT, Z_OPT, ZNAME) VALUES (3, 9, 'tag')")
            try connection.execute("INSERT INTO \(groupsTable) (Z_A, Z_B) VALUES (2, 1)")
            try connection.execute("INSERT INTO \(tagsTable) (Z_A, Z_B) VALUES (2, 1)")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        for joinTable in [groupsTable, tagsTable] {
            XCTAssertTrue(
                try migrated.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
                        .isEmpty
                })
        }
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZOWNER") },
            [[.int(1), .int(5), .text("owner")]])
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZGROUP") },
            [[.int(1), .int(7), .text("group")]])
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZTAG") },
            [[.int(1), .int(9), .text("tag")]])
        try migrated.close()
        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(try reopened.read { try $0.rows("PRAGMA integrity_check") }, [[.text("ok")]])
        try reopened.close()
    }

    func testMultipleOwnerOnlyToManyRemovalsComposeWithScalarAddition() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("multi-join-scalar-add.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [
                    Schema.Relationship(name: "tags", destination: "Tag", isToMany: true),
                    Schema.Relationship(name: "groups", destination: "Group", isToMany: true),
                ]),
            Schema.Entity(name: "Group", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Tag", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "priority", type: "Int16", defaultValue: "12"),
                ]),
            Schema.Entity(name: "Group", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Tag", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let owner = try XCTUnwrap(source.entity(forName: "Owner"))
        let joinTables = try owner.relationships.map { relationship in
            try XCTUnwrap(SchemaBuilder.joinTableName(for: owner, relationship: relationship, schema: source))
        }
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZNAME) VALUES (2, 5, 'owner')")
            try connection.execute("INSERT INTO ZGROUP (Z_ENT, Z_OPT, ZNAME) VALUES (1, 7, 'group')")
            try connection.execute("INSERT INTO ZTAG (Z_ENT, Z_OPT, ZNAME) VALUES (3, 9, 'tag')")
            for table in joinTables { try connection.execute("INSERT INTO \(table) (Z_A, Z_B) VALUES (2, 1)") }
        }
        try initial.close()
        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        for table in joinTables {
            XCTAssertTrue(
                try migrated.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)])
                        .isEmpty
                })
        }
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME, ZPRIORITY FROM ZOWNER") },
            [[.int(1), .int(5), .text("owner"), .int(12)]])
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZGROUP") },
            [[.int(1), .int(7), .text("group")]])
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZTAG") },
            [[.int(1), .int(9), .text("tag")]])
        try migrated.close()
        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(try reopened.read { try $0.rows("PRAGMA integrity_check") }, [[.text("ok")]])
        try reopened.close()
    }

    func testMultipleOwnerToManyRemovalsComposeWithScalarAdditionOnAnotherOwner() throws {
        let source = Schema([
            Schema.Entity(
                name: "AOwner",
                relationships: [
                    Schema.Relationship(name: "first", destination: "First", isToMany: true),
                    Schema.Relationship(name: "second", destination: "Second", isToMany: true),
                ]),
            Schema.Entity(
                name: "BOwner",
                attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "First"), Schema.Entity(name: "Second"),
        ])
        let destination = Schema([
            Schema.Entity(name: "AOwner"),
            Schema.Entity(
                name: "BOwner",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "priority", type: "Int16", defaultValue: "6"),
                ]),
            Schema.Entity(name: "First"), Schema.Entity(name: "Second"),
        ])
        let owner = try XCTUnwrap(source.entity(forName: "AOwner"))
        let tables = try owner.relationships.map {
            try XCTUnwrap(SchemaBuilder.joinTableName(for: owner, relationship: $0, schema: source))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("multi-owner-scalar-add.sqlite"))
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZBOWNER (Z_ENT, Z_OPT, ZNAME) VALUES (2, 8, 'retained')")
            for table in tables { try connection.execute("INSERT INTO \(table) (Z_A, Z_B) VALUES (1, 1)") }
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME, ZPRIORITY FROM ZBOWNER") },
            [[.int(1), .int(8), .text("retained"), .int(6)]])
        for table in tables {
            XCTAssertTrue(
                try migrated.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)])
                        .isEmpty
                })
        }
        try migrated.close()
        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(try reopened.read { try $0.rows("PRAGMA integrity_check") }, [[.text("ok")]])
        try reopened.close()
    }

    func testMultipleJoinScalarAdditionPreflightsEveryJoinBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "first", destination: "First", isToMany: true),
                    Schema.Relationship(name: "second", destination: "Second", isToMany: true),
                ]),
            Schema.Entity(name: "First"), Schema.Entity(name: "Second"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "priority", type: "Int16", isOptional: true)]),
            Schema.Entity(name: "First"), Schema.Entity(name: "Second"),
        ])
        let owner = try XCTUnwrap(source.entity(forName: "Owner"))
        let tables = try owner.relationships.map {
            try XCTUnwrap(SchemaBuilder.joinTableName(for: owner, relationship: $0, schema: source))
        }
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multi-join-scalar-preflight"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("DROP INDEX \(tables[1])_Z_B_INDEX")
        }
        let originalOwnerColumns = try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected tampered second join to fail preflight, got \(error)")
            }
        }
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }, originalOwnerColumns)
        for table in tables {
            XCTAssertFalse(
                try driver.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)])
                        .isEmpty
                })
        }
        try driver.close()
    }

    func testMultipleJoinScalarUniqueAdditionRejectsBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "first", destination: "First", isToMany: true),
                    Schema.Relationship(name: "second", destination: "Second", isToMany: true),
                ]),
            Schema.Entity(name: "First"), Schema.Entity(name: "Second"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "token", type: "Int16", isOptional: true, options: [.unique])]),
            Schema.Entity(name: "First"), Schema.Entity(name: "Second"),
        ])
        let owner = try XCTUnwrap(source.entity(forName: "Owner"))
        let tables = try owner.relationships.map {
            try XCTUnwrap(SchemaBuilder.joinTableName(for: owner, relationship: $0, schema: source))
        }
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multi-join-scalar-unique-preflight"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected unique scalar addition to fail preflight, got \(error)")
            }
        }
        XCTAssertFalse(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZOWNER)").contains(where: { $0.count > 1 && $0[1] == .text("ZTOKEN") })
            })
        for table in tables {
            XCTAssertFalse(
                try driver.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)])
                        .isEmpty
                })
        }
        try driver.close()
    }

    func testMultipleJoinScalarAdditionRejectsDynamicDefaultBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "first", destination: "First", isToMany: true),
                    Schema.Relationship(name: "second", destination: "Second", isToMany: true),
                ]),
            Schema.Entity(name: "First"), Schema.Entity(name: "Second"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [
                    Schema.Attribute(
                        name: "createdAt", type: "Date", isOptional: false, defaultValue: "CURRENT_TIMESTAMP")
                ]),
            Schema.Entity(name: "First"), Schema.Entity(name: "Second"),
        ])
        let owner = try XCTUnwrap(source.entity(forName: "Owner"))
        let tables = try owner.relationships.map {
            try XCTUnwrap(SchemaBuilder.joinTableName(for: owner, relationship: $0, schema: source))
        }
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multi-join-dynamic-default-reject"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected unsupported dynamic default to fail preflight, got \(error)")
            }
        }
        XCTAssertFalse(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZOWNER)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZCREATEDAT")
                })
            })
        for table in tables {
            XCTAssertFalse(
                try driver.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)])
                        .isEmpty
                })
        }
        try driver.close()
    }

    func testMultipleFlatToManyRemovalPreflightsEveryJoinBeforeDroppingAny() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "first", destination: "First", isToMany: true),
                    Schema.Relationship(name: "second", destination: "Second", isToMany: true),
                ]),
            Schema.Entity(name: "First"),
            Schema.Entity(name: "Second"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Owner"), Schema.Entity(name: "First"), Schema.Entity(name: "Second"),
        ])
        let firstTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(
                for: try XCTUnwrap(source.entity(forName: "Owner")),
                relationship: try XCTUnwrap(
                    source.entity(forName: "Owner")?.relationships.first(where: { $0.name == "first" })),
                schema: source))
        let secondTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(
                for: try XCTUnwrap(source.entity(forName: "Owner")),
                relationship: try XCTUnwrap(
                    source.entity(forName: "Owner")?.relationships.first(where: { $0.name == "second" })),
                schema: source))
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-to-many-preflight-second-join"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO \(firstTable) (Z_A, Z_B) VALUES (2, 1)")
            try connection.execute("INSERT INTO \(secondTable) (Z_A, Z_B) VALUES (2, 3)")
            try connection.execute("DROP INDEX \(secondTable)_Z_B_INDEX")
        }
        let originalOwnerTable = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZOWNER'")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected tampered second join table to fail before dropping either, got \(error)")
            }
        }
        for joinTable in [firstTable, secondTable] {
            XCTAssertFalse(
                try driver.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
                        .isEmpty
                })
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ZOWNER'") },
            originalOwnerTable)
        try driver.close()
    }

    func testMultipleFlatToManyRemovalRejectsUnrelatedOriginalNameClaimBeforeDrops() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "first", destination: "First", isToMany: true),
                    Schema.Relationship(name: "second", destination: "Second", isToMany: true),
                ]),
            Schema.Entity(name: "First"),
            Schema.Entity(
                name: "Observer",
                relationships: [Schema.Relationship(name: "first", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Second"),
            Schema.Entity(name: "Tag"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Owner"),
            Schema.Entity(name: "First"),
            Schema.Entity(
                name: "Observer",
                relationships: [
                    Schema.Relationship(name: "items", destination: "Tag", isToMany: true, originalName: "first")
                ]),
            Schema.Entity(name: "Second"),
            Schema.Entity(name: "Tag"),
        ])
        let owner = try XCTUnwrap(source.entity(forName: "Owner"))
        let firstTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(
                for: owner,
                relationship: try XCTUnwrap(owner.relationships.first(where: { $0.name == "first" })),
                schema: source))
        let secondTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(
                for: owner,
                relationship: try XCTUnwrap(owner.relationships.first(where: { $0.name == "second" })),
                schema: source))
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-to-many-unrelated-rename-claim"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO \(firstTable) (Z_A, Z_B) VALUES (1, 1)")
            try connection.execute("INSERT INTO \(secondTable) (Z_A, Z_B) VALUES (1, 1)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected unrelated originalName claim to reject batch, got \(error)")
            }
        }
        for joinTable in [firstTable, secondTable] {
            XCTAssertFalse(
                try driver.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
                        .isEmpty
                })
        }
        try driver.close()
    }

    func testMultipleFlatToManyRemovalRejectsCaseOnlyRenameBeforeDrops() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "tags", destination: "Tag", isToMany: true),
                    Schema.Relationship(name: "target", destination: "Target", isOptional: true),
                ]),
            Schema.Entity(name: "Tag"),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(
                        name: "TARGET", destination: "Target", isOptional: true, originalName: "target")
                ]),
            Schema.Entity(name: "Tag"),
            Schema.Entity(name: "Target"),
        ])
        let owner = try XCTUnwrap(source.entity(forName: "Owner"))
        let joinTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(
                for: owner,
                relationship: try XCTUnwrap(owner.relationships.first(where: { $0.name == "tags" })),
                schema: source))
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multi-to-many-case-rename-reject"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZTARGET) VALUES (1, 3, 1)")
            try connection.execute("INSERT INTO \(joinTable) (Z_A, Z_B) VALUES (1, 1)")
        }
        let originalColumns = try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected case-only rename and join removal to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }, originalColumns)
        XCTAssertFalse(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
                    .isEmpty
            })
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZTARGET FROM ZOWNER") }, [[.int(1), .int(3), .int(1)]])
        try driver.close()
    }

    func testPairedInverseRemovalStillUsesPairPlanner() throws {
        let source = Schema([
            Schema.Entity(
                name: "AOwner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [
                    Schema.Relationship(name: "target", destination: "ZTarget", isOptional: true, inverse: "owners")
                ]),
            Schema.Entity(
                name: "ZTarget",
                relationships: [
                    Schema.Relationship(name: "owners", destination: "AOwner", isToMany: true, inverse: "target")
                ]),
        ])
        let destination = Schema([
            Schema.Entity(name: "AOwner", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "ZTarget"),
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("paired-inverse-removal.sqlite"))
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZAOWNER (Z_ENT, Z_OPT, ZNAME, ZTARGET) VALUES (1, 5, 'owner', 1)")
            try connection.execute("INSERT INTO ZZTARGET (Z_ENT, Z_OPT) VALUES (3, 7)")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertFalse(
            try migrated.read {
                try $0.rows("PRAGMA table_info(ZAOWNER)").contains(where: { $0.count > 1 && $0[1] == .text("ZTARGET") }
                )
            })
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZAOWNER") },
            [[.int(1), .int(5), .text("owner")]])
        XCTAssertEqual(try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT FROM ZZTARGET") }, [[.int(1), .int(7)]])
        try migrated.close()
    }

    func testMixedPairedInverseAndOwnerJoinRemovalRejectsBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(
                name: "AOwner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [
                    Schema.Relationship(name: "target", destination: "ZTarget", isOptional: true, inverse: "owners"),
                    Schema.Relationship(name: "tags", destination: "Tag", isToMany: true),
                ]),
            Schema.Entity(name: "Tag"),
            Schema.Entity(
                name: "ZTarget",
                relationships: [
                    Schema.Relationship(name: "owners", destination: "AOwner", isToMany: true, inverse: "target")
                ]),
        ])
        let destination = Schema([
            Schema.Entity(name: "AOwner", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Tag"),
            Schema.Entity(name: "ZTarget"),
        ])
        let owner = try XCTUnwrap(source.entity(forName: "AOwner"))
        let tagsRelationship = try XCTUnwrap(owner.relationships.first(where: { $0.name == "tags" }))
        let joinTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(for: owner, relationship: tagsRelationship, schema: source))
        let driver = try GRDBSQLiteDriver(location: .memory(name: "mixed-pair-and-join-removal"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZAOWNER (Z_ENT, Z_OPT, ZNAME, ZTARGET) VALUES (1, 5, 'owner', 1)")
            try connection.execute("INSERT INTO ZZTARGET (Z_ENT, Z_OPT) VALUES (3, 7)")
            try connection.execute("INSERT INTO \(joinTable) (Z_A, Z_B) VALUES (1, 1)")
        }
        let originalIndexes = try driver.read {
            try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected mixed inverse/join removals to fail closed, got \(error)")
            }
        }
        XCTAssertFalse(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
                    .isEmpty
            })
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZAOWNER)").contains(where: { $0.count > 1 && $0[1] == .text("ZTARGET") })
            })
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name") },
            originalIndexes)
        try driver.close()
    }

    func testMultipleToManyRemovalRejectsEntityCaseRenameBeforeDrops() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "first", destination: "First", isToMany: true),
                    Schema.Relationship(name: "second", destination: "Second", isToMany: true),
                ]),
            Schema.Entity(name: "First"),
            Schema.Entity(name: "Second"),
        ])
        let destination = Schema([
            Schema.Entity(name: "OWNER"), Schema.Entity(name: "First"), Schema.Entity(name: "Second"),
        ])
        let owner = try XCTUnwrap(source.entity(forName: "Owner"))
        let firstRelationship = try XCTUnwrap(owner.relationships.first(where: { $0.name == "first" }))
        let firstJoinTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(for: owner, relationship: firstRelationship, schema: source))
        let driver = try GRDBSQLiteDriver(location: .memory(name: "join-removal-entity-case-rename"))
        try bootstrap(source, driver: driver)
        let originalColumns = try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected case-only entity rename to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }, originalColumns)
        XCTAssertFalse(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(firstJoinTable)])
                    .isEmpty
            })
        try driver.close()
    }

    func testMultipleOwnerOnlyToManyAdditionsCreateAllJoinTablesTogether() throws {
        let source = Schema([
            Schema.Entity(name: "AOwner", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "BOwner", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "First", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Second", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "AOwner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [Schema.Relationship(name: "first", destination: "First", isToMany: true)]),
            Schema.Entity(
                name: "BOwner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [Schema.Relationship(name: "second", destination: "Second", isToMany: true)]),
            Schema.Entity(name: "First", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Second", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let additionPlans: [String] = try destination.entities.flatMap { entity in
            try entity.relationships.map { relationship in
                try XCTUnwrap(
                    SchemaBuilder.joinTableName(for: entity, relationship: relationship, schema: destination))
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("multi-owner-to-many-add.sqlite"))
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZAOWNER (Z_ENT, Z_OPT, ZNAME) VALUES (1, 3, 'first owner')")
            try connection.execute("INSERT INTO ZBOWNER (Z_ENT, Z_OPT, ZNAME) VALUES (2, 5, 'second owner')")
            try connection.execute("INSERT INTO ZFIRST (Z_ENT, Z_OPT, ZNAME) VALUES (3, 7, 'first target')")
            try connection.execute("INSERT INTO ZSECOND (Z_ENT, Z_OPT, ZNAME) VALUES (4, 9, 'second target')")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        for table in additionPlans {
            XCTAssertTrue(
                try migrated.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)])
                        .count == 1
                })
            let uniqueIndex = "\(table)_UNIQUE_INDEX"
            let reverseIndex = "\(table)_Z_B_INDEX"
            XCTAssertTrue(
                try migrated.read {
                    try $0.rows(
                        "SELECT name FROM sqlite_master WHERE type = 'index' AND name IN (?, ?)",
                        [.text(uniqueIndex), .text(reverseIndex)]
                    ).count == 2
                })
        }
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZAOWNER") },
            [[.int(1), .int(3), .text("first owner")]])
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZBOWNER") },
            [[.int(1), .int(5), .text("second owner")]])
        try migrated.close()
    }

    func testMultipleOwnerOnlyToManyAdditionCollisionFailsBeforeCreatingAnyJoin() throws {
        let source = Schema([
            Schema.Entity(name: "AOwner"), Schema.Entity(name: "BOwner"), Schema.Entity(name: "First"),
            Schema.Entity(name: "Second"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "AOwner",
                relationships: [Schema.Relationship(name: "first", destination: "First", isToMany: true)]),
            Schema.Entity(
                name: "BOwner",
                relationships: [Schema.Relationship(name: "second", destination: "Second", isToMany: true)]),
            Schema.Entity(name: "First"), Schema.Entity(name: "Second"),
        ])
        let plannedTables: [String] = try destination.entities.flatMap { entity in
            try entity.relationships.map { relationship in
                try XCTUnwrap(SchemaBuilder.joinTableName(for: entity, relationship: relationship, schema: destination))
            }
        }
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multi-owner-to-many-add-collision"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("CREATE TABLE \(plannedTables[1])_UNIQUE_INDEX (value INTEGER)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected a later join-name collision to reject the entire batch, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(plannedTables[0])]
                )
                .isEmpty
            })
        XCTAssertFalse(
            try driver.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                    [.text(plannedTables[1] + "_UNIQUE_INDEX")]
                )
                .isEmpty
            })
        try driver.close()
    }

    func testMultipleOwnerOnlyToManyAdditionRejectsMixedJoinRemovalBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(
                name: "AOwner",
                relationships: [Schema.Relationship(name: "existing", destination: "First", isToMany: true)]),
            Schema.Entity(name: "BOwner"), Schema.Entity(name: "First"), Schema.Entity(name: "Second"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "AOwner",
                relationships: [Schema.Relationship(name: "new", destination: "Second", isToMany: true)]),
            Schema.Entity(
                name: "BOwner",
                relationships: [Schema.Relationship(name: "other", destination: "First", isToMany: true)]),
            Schema.Entity(name: "First"), Schema.Entity(name: "Second"),
        ])
        let sourceOwner = try XCTUnwrap(source.entity(forName: "AOwner"))
        let sourceRelationship = try XCTUnwrap(sourceOwner.relationships.first)
        let removedTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(for: sourceOwner, relationship: sourceRelationship, schema: source))
        let destinationTables: [String] = try destination.entities.flatMap { entity in
            try entity.relationships.map { relationship in
                try XCTUnwrap(SchemaBuilder.joinTableName(for: entity, relationship: relationship, schema: destination))
            }
        }
        let driver = try GRDBSQLiteDriver(location: .memory(name: "mixed-join-add-remove"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected mixed join additions and removals to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(removedTable)])
            },
            [[.text(removedTable)]])
        for table in destinationTables {
            XCTAssertTrue(
                try driver.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)])
                        .isEmpty
                })
        }
        try driver.close()
    }

    func testMultipleOwnerOnlyToManyAdditionsRejectNewRootBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(name: "AOwner"), Schema.Entity(name: "BOwner"),
            Schema.Entity(name: "First"), Schema.Entity(name: "Second"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "AOwner",
                relationships: [Schema.Relationship(name: "first", destination: "First", isToMany: true)]),
            Schema.Entity(
                name: "BOwner",
                relationships: [Schema.Relationship(name: "second", destination: "Second", isToMany: true)]),
            Schema.Entity(name: "First"), Schema.Entity(name: "Second"), Schema.Entity(name: "NewRoot"),
        ])
        let destinationTables: [String] = try destination.entities.flatMap { entity in
            try entity.relationships.map { relationship in
                try XCTUnwrap(SchemaBuilder.joinTableName(for: entity, relationship: relationship, schema: destination))
            }
        }
        let driver = try GRDBSQLiteDriver(location: .memory(name: "join-addition-new-root"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected adding a root alongside join additions to fail closed, got \(error)")
            }
        }
        for table in destinationTables {
            XCTAssertTrue(
                try driver.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)])
                        .isEmpty
                })
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZNEWROOT'").isEmpty
            })
        try driver.close()
    }

    func testEntityCaseRenameWithRootReplacementRejectsBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(name: "Owner", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Obsolete", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "Owner", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "obsolete", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "entity-case-rename-root-replacement"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZOBSOLETE (Z_ENT, Z_OPT, ZNAME) VALUES (1, 4, 'keep')")
        }
        let sourceTables = try driver.read {
            try $0.rows(
                "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected case-only entity replacement to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
                )
            },
            sourceTables)
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZOBSOLETE") },
            [[.int(1), .int(4), .text("keep")]])
        try driver.close()
    }

    func testScalarOptionalAdditionComposesWithOwnerOnlyToManyRemoval() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "note", type: "String", isOptional: true),
                ]),
            Schema.Entity(name: "Tag", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let joinTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(
                for: try XCTUnwrap(source.entity(forName: "Owner")),
                relationship: try XCTUnwrap(source.entity(forName: "Owner")?.relationships.first),
                schema: source))
        let driver = try GRDBSQLiteDriver(location: .memory(name: "scalar-add-to-many-remove"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZNAME) VALUES (1, 4, 'owner')")
            try connection.execute("INSERT INTO ZTAG (Z_ENT, Z_OPT, ZNAME) VALUES (2, 6, 'tag')")
            try connection.execute("INSERT INTO \(joinTable) (Z_A, Z_B) VALUES (1, 1)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME, ZNOTE FROM ZOWNER") },
            [[.int(1), .int(4), .text("owner"), .null]])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZTAG") },
            [[.int(1), .int(6), .text("tag")]])
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
                    .isEmpty
            })
        try driver.close()
    }

    func testScalarDefaultedAdditionComposesWithOwnerOnlyToManyRemoval() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "priority", type: "Int16", defaultValue: "12"),
                ]),
            Schema.Entity(name: "Tag"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "scalar-default-add-to-many-remove"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZNAME) VALUES (1, 5, 'owner')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME, ZPRIORITY FROM ZOWNER") },
            [[.int(1), .int(5), .text("owner"), .int(12)]])
        try driver.close()
    }

    func testScalarUniqueAdditionWithOwnerOnlyToManyRemovalFailsAtomically() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "token", type: "String", isOptional: true, options: [.unique]),
                ]),
            Schema.Entity(name: "Tag"),
        ])
        let joinTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(
                for: try XCTUnwrap(source.entity(forName: "Owner")),
                relationship: try XCTUnwrap(source.entity(forName: "Owner")?.relationships.first),
                schema: source))
        let driver = try GRDBSQLiteDriver(location: .memory(name: "scalar-unique-add-to-many-remove-reject"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZNAME) VALUES (1, 3, 'owner')")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected unique addition to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
                    .count == 1
            })
        XCTAssertFalse(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZOWNER)").contains(where: { $0.count > 1 && $0[1] == .text("ZTOKEN") })
            })
        try driver.close()
    }

    func testScalarAdditionWithOwnerOnlyToManyRemovalRejectsTamperedJoinBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "note", type: "String", isOptional: true),
                ]),
            Schema.Entity(name: "Tag"),
        ])
        let owner = try XCTUnwrap(source.entity(forName: "Owner"))
        let relationship = try XCTUnwrap(owner.relationships.first)
        let joinTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(for: owner, relationship: relationship, schema: source))
        let driver = try GRDBSQLiteDriver(location: .memory(name: "scalar-add-to-many-remove-tampered-join"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZNAME) VALUES (1, 3, 'owner')")
            try connection.execute("DROP INDEX \(joinTable)_Z_B_INDEX")
        }
        let originalColumns = try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected tampered join table to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }, originalColumns)
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZOWNER") },
            [[.int(1), .int(3), .text("owner")]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
            },
            [[.text(joinTable)]])
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZOWNER)").allSatisfy({ row in
                    guard row.count > 1, case let .text(name) = row[1] else { return true }
                    return name != "ZNOTE"
                })
            })
        try driver.close()
    }

    func testScalarAdditionFailureRollsBackOwnerOnlyToManyRemoval() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "createdAt", type: "Date", defaultValue: "CURRENT_TIMESTAMP"),
                ]),
            Schema.Entity(name: "Tag"),
        ])
        let owner = try XCTUnwrap(source.entity(forName: "Owner"))
        let relationship = try XCTUnwrap(owner.relationships.first)
        let joinTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(for: owner, relationship: relationship, schema: source))
        let driver = try GRDBSQLiteDriver(location: .memory(name: "scalar-add-failure-to-many-rollback"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZNAME) VALUES (1, 7, 'owner')")
            try connection.execute("INSERT INTO ZTAG (Z_ENT, Z_OPT) VALUES (2, 5)")
            try connection.execute("INSERT INTO \(joinTable) (Z_A, Z_B) VALUES (1, 1)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected dynamic default to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZOWNER") },
            [[.int(1), .int(7), .text("owner")]])
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZOWNER)").allSatisfy({ row in
                    guard row.count > 1, case let .text(name) = row[1] else { return true }
                    return name != "ZCREATEDAT"
                })
            })
        XCTAssertEqual(try driver.read { try $0.rows("SELECT Z_A, Z_B FROM \(joinTable)") }, [[.int(1), .int(1)]])
        try driver.close()
    }

    func testFlatToManyMigrationRejectsInverseConstraintsAndCombinedEdits() throws {
        let cases: [(String, Schema.Relationship, Schema.Relationship?)] = [
            (
                "inverse",
                Schema.Relationship(name: "tags", destination: "Tag", isToMany: true, inverse: "owners"),
                Schema.Relationship(name: "owners", destination: "Owner", isToMany: true, inverse: "tags")
            ),
            (
                "minimum",
                Schema.Relationship(name: "tags", destination: "Tag", isToMany: true, minimumModelCount: 1),
                nil
            ),
        ]
        for (name, ownerRelationship, targetRelationship) in cases {
            let source = Schema([
                Schema.Entity(name: "Owner"),
                Schema.Entity(name: "Tag"),
            ])
            let destination = Schema([
                Schema.Entity(name: "Owner", relationships: [ownerRelationship]),
                Schema.Entity(name: "Tag", relationships: targetRelationship.map { [$0] } ?? []),
            ])
            let driver = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-reject-\(name)"))
            try bootstrap(source, driver: driver)
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected \(name) relationship to fail closed, got \(error)")
                }
            }
            XCTAssertTrue(
                try driver.read {
                    try $0.rows(
                        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'Z_OWNER_TAGS_TAG'"
                    ).isEmpty
                })
            try driver.close()
        }

        let source = Schema([
            Schema.Entity(name: "Owner"),
            Schema.Entity(name: "Tag"),
            Schema.Entity(name: "Other"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner", relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag"),
            Schema.Entity(
                name: "Other", attributes: [Schema.Attribute(name: "note", type: "String", isOptional: true)]),
        ])
        let combined = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-combined-edit"))
        try bootstrap(source, driver: combined)
        XCTAssertThrowsError(
            try combined.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected combined relationship/scalar change to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try combined.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'Z_OWNER_TAGS_TAG'").isEmpty
            })
        try combined.close()

        let membershipDestination = Schema([
            Schema.Entity(
                name: "Owner", relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag"),
            Schema.Entity(name: "NewRoot"),
        ])
        let membershipDriver = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-membership-edit"))
        try bootstrap(source, driver: membershipDriver)
        XCTAssertThrowsError(
            try membershipDriver.write {
                try LightweightMigration.migrate(source: source, destination: membershipDestination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected combined relationship/entity change to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try membershipDriver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'Z_OWNER_TAGS_TAG'").isEmpty
            })
        try membershipDriver.close()
    }

    func testFlatToManyInverseDetectionUsesRelationshipEndpoints() throws {
        let source = Schema([
            Schema.Entity(name: "Owner"),
            Schema.Entity(name: "Tag"),
            Schema.Entity(name: "Other", relationships: [Schema.Relationship(name: "tags", destination: "Other")]),
        ])
        let unrelatedInverseCollision = Schema([
            Schema.Entity(
                name: "Owner", relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag"),
            Schema.Entity(name: "Other", relationships: [Schema.Relationship(name: "tags", destination: "Other")]),
        ])
        let allowedDriver = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-unrelated-inverse-name"))
        try bootstrap(source, driver: allowedDriver)
        try allowedDriver.write {
            try LightweightMigration.migrate(source: source, destination: unrelatedInverseCollision, connection: $0)
        }
        try allowedDriver.close()

        let reciprocalSource = Schema([
            Schema.Entity(
                name: "Owner", relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(
                name: "Tag", relationships: [Schema.Relationship(name: "owners", destination: "Owner", inverse: "tags")]
            ),
        ])
        let reciprocalDestination = Schema([
            Schema.Entity(
                name: "Owner", relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag"),
        ])
        let rejectedDriver = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-reciprocal"))
        try bootstrap(reciprocalSource, driver: rejectedDriver)
        XCTAssertThrowsError(
            try rejectedDriver.write {
                try LightweightMigration.migrate(
                    source: reciprocalSource, destination: reciprocalDestination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected reciprocal relationship to fail closed, got \(error)")
            }
        }
        try rejectedDriver.close()

        let inferredInverseSource = Schema([
            Schema.Entity(name: "Owner"),
            Schema.Entity(name: "Tag", relationships: [Schema.Relationship(name: "owners", destination: "Owner")]),
        ])
        let inferredInverseDestination = Schema([
            Schema.Entity(
                name: "Owner", relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag", relationships: [Schema.Relationship(name: "owners", destination: "Owner")]),
        ])
        let inferredDriver = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-inferred-inverse"))
        try bootstrap(inferredInverseSource, driver: inferredDriver)
        XCTAssertThrowsError(
            try inferredDriver.write {
                try LightweightMigration.migrate(
                    source: inferredInverseSource, destination: inferredInverseDestination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected differently named inferred inverse to fail closed, got \(error)")
            }
        }
        try inferredDriver.close()
    }

    func testFlatToManyRelationshipRenameFailsClosed() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "labels", destination: "Tag", isToMany: true, originalName: "tags")
                ]),
            Schema.Entity(name: "Tag"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-rename"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected to-many rename to fail closed, got \(error)")
            }
        }
        let tables = try driver.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z_%'")
        }
        XCTAssertFalse(tables.isEmpty)
        try driver.close()
    }

    func testFlatToManyDestinationChangeFailsClosed() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [Schema.Relationship(name: "items", destination: "First", isToMany: true)]),
            Schema.Entity(name: "First"),
            Schema.Entity(name: "Second"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [Schema.Relationship(name: "items", destination: "Second", isToMany: true)]),
            Schema.Entity(name: "First"),
            Schema.Entity(name: "Second"),
        ])
        let sourceJoin = try XCTUnwrap(
            SchemaBuilder.joinTableName(
                for: try XCTUnwrap(source.entity(forName: "Owner")),
                relationship: try XCTUnwrap(source.entity(forName: "Owner")?.relationships.first),
                schema: source))
        let driver = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-destination-change"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected to-many destination change to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(sourceJoin)])
            },
            [[.text(sourceJoin)]])
        try driver.close()
    }

    func testFlatToManyAdditionRejectsJoinObjectNameCollisionBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(name: "Owner"),
            Schema.Entity(name: "Tag"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner", relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag"),
        ])
        let owner = try XCTUnwrap(destination.entity(forName: "Owner"))
        let relation = try XCTUnwrap(owner.relationships.first)
        let joinTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(for: owner, relationship: relation, schema: destination))
        let conflictingIndex = "\(joinTable)_Z_B_INDEX"
        let driver = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-add-collision"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("CREATE TABLE ZUNRELATED (Z_PK INTEGER PRIMARY KEY)")
            try connection.execute("CREATE INDEX \(conflictingIndex) ON ZUNRELATED (Z_PK)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected join-index name collision to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
                    .isEmpty
            })
        try driver.close()
    }

    func testFlatToManyAdditionAllowsUnrelatedPhysicalForeignKeys() throws {
        let source = Schema([
            Schema.Entity(name: "Owner"),
            Schema.Entity(name: "Tag"),
            Schema.Entity(name: "Unrelated"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner", relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag"),
            Schema.Entity(name: "Unrelated"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-add-unrelated-fk"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("CREATE TABLE USER_REFERENCE (Z_TARGET INTEGER REFERENCES ZUNRELATED(Z_PK))")
        }
        try driver.write {
            try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
        }
        let owner = try XCTUnwrap(destination.entity(forName: "Owner"))
        let relation = try XCTUnwrap(owner.relationships.first)
        let joinTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(for: owner, relationship: relation, schema: destination))
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
            },
            [[.text(joinTable)]])
        try driver.close()
    }

    func testFlatToManyAdditionAllowsUnrelatedViewsAndTriggers() throws {
        let source = Schema([
            Schema.Entity(name: "Owner"),
            Schema.Entity(name: "Tag"),
            Schema.Entity(name: "Unrelated"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner", relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)]),
            Schema.Entity(name: "Tag"),
            Schema.Entity(name: "Unrelated"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-add-unrelated-view-trigger"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("CREATE VIEW USER_UNRELATED_VIEW AS SELECT Z_PK FROM ZUNRELATED")
            try connection.execute("CREATE VIEW USER_PREFIX_VIEW AS SELECT Z_PK FROM Z_OWNER_TAGS_TAG_PREFIX")
            try connection.execute(
                "CREATE TRIGGER USER_UNRELATED_TRIGGER AFTER INSERT ON ZUNRELATED BEGIN UPDATE ZUNRELATED SET Z_OPT = Z_OPT WHERE Z_PK = NEW.Z_PK; END"
            )
        }
        try driver.write {
            try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
        }
        let owner = try XCTUnwrap(destination.entity(forName: "Owner"))
        let relationship = try XCTUnwrap(owner.relationships.first)
        let table = try XCTUnwrap(
            SchemaBuilder.joinTableName(for: owner, relationship: relationship, schema: destination))
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)])
            },
            [[.text(table)]])
        try driver.close()
    }

    func testFlatToManyRemovalRejectsUnexpectedJoinObjectsBeforeDrop() throws {
        let owner = Schema.Entity(
            name: "Owner", relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)])
        let source = Schema([owner, Schema.Entity(name: "Tag")])
        let destination = Schema([Schema.Entity(name: "Owner"), Schema.Entity(name: "Tag")])
        let joinTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(
                for: owner, relationship: try XCTUnwrap(owner.relationships.first), schema: source))
        let sideObjects = [
            ("index", "CREATE INDEX USER_JOIN_INDEX ON \(joinTable) (Z_A)"),
            ("view", "CREATE VIEW USER_JOIN_VIEW AS SELECT Z_A FROM \(joinTable)"),
        ]
        for (name, statement) in sideObjects {
            let driver = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-drop-\(name)"))
            try bootstrap(source, driver: driver)
            try driver.write { connection in
                try connection.execute("INSERT INTO \(joinTable) (Z_A, Z_B) VALUES (1, 1)")
                try connection.execute(statement)
            }
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected unexpected \(name) to block join removal, got \(error)")
                }
            }
            XCTAssertEqual(try driver.read { try $0.rows("SELECT Z_A, Z_B FROM \(joinTable)") }, [[.int(1), .int(1)]])
            XCTAssertTrue(
                try driver.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
                        .count == 1
                })
            try driver.close()
        }

        let foreignKeyDriver = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-drop-foreign-key"))
        try bootstrap(source, driver: foreignKeyDriver)
        try foreignKeyDriver.write { connection in
            try connection.execute("CREATE TABLE USER_REFERENCE (Z_LINK INTEGER REFERENCES \(joinTable)(Z_A))")
        }
        XCTAssertThrowsError(
            try foreignKeyDriver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected physical foreign key to block join removal, got \(error)")
            }
        }
        XCTAssertEqual(
            try foreignKeyDriver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
            },
            [[.text(joinTable)]])
        try foreignKeyDriver.close()

        let unrelatedViewDriver = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-drop-unrelated-view"))
        try bootstrap(source, driver: unrelatedViewDriver)
        try unrelatedViewDriver.write { connection in
            try connection.execute("CREATE VIEW USER_UNRELATED_VIEW AS SELECT Z_PK FROM ZOWNER")
        }
        try unrelatedViewDriver.write {
            try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
        }
        XCTAssertTrue(
            try unrelatedViewDriver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
                    .isEmpty
            })
        try unrelatedViewDriver.close()
    }

    func testFlatToManyRemovalRejectsMissingGeneratedIndexesAndAlteredColumns() throws {
        let owner = Schema.Entity(
            name: "Owner", relationships: [Schema.Relationship(name: "tags", destination: "Tag", isToMany: true)])
        let source = Schema([owner, Schema.Entity(name: "Tag")])
        let destination = Schema([Schema.Entity(name: "Owner"), Schema.Entity(name: "Tag")])
        let joinTable = try XCTUnwrap(
            SchemaBuilder.joinTableName(
                for: owner, relationship: try XCTUnwrap(owner.relationships.first), schema: source))
        let uniqueIndexName = "\(joinTable)_UNIQUE_INDEX"
        for name in ["missing-index", "altered-ddl", "partial-index"] {
            let driver = try GRDBSQLiteDriver(location: .memory(name: "flat-to-many-corrupt-\(name)"))
            try bootstrap(source, driver: driver)
            try driver.write { connection in
                if name == "missing-index" {
                    try connection.execute("DROP INDEX \(uniqueIndexName)")
                } else if name == "partial-index" {
                    try connection.execute("DROP TABLE \(joinTable)")
                    try connection.execute("CREATE TABLE \(joinTable) (Z_A INTEGER, Z_B INTEGER)")
                    try connection.execute(
                        "CREATE UNIQUE INDEX \(uniqueIndexName) ON \(joinTable) (Z_A, Z_B) WHERE Z_A > 0")
                    try connection.execute("CREATE INDEX \(joinTable)_Z_B_INDEX ON \(joinTable) (Z_B)")
                } else {
                    try connection.execute("DROP TABLE \(joinTable)")
                    try connection.execute("CREATE TABLE \(joinTable) (Z_A INTEGER, Z_B INTEGER, Z_EXTRA BLOB)")
                    try connection.execute("CREATE UNIQUE INDEX \(uniqueIndexName) ON \(joinTable) (Z_A, Z_B)")
                    try connection.execute(
                        "CREATE INDEX \(joinTable)_Z_B_INDEX ON \(joinTable) (Z_B)")
                }
            }
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected \(name) to fail closed, got \(error)")
                }
            }
            XCTAssertEqual(
                try driver.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(joinTable)])
                },
                [[.text(joinTable)]])
            try driver.close()
        }
    }

    func testAddingRequiredOrInverseOwningToOneRelationshipFailsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Person", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Pet", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZPERSON (Z_ENT, Z_OPT, ZNAME) VALUES (?, 1, ?)",
                [.int(Int64(source.entityIDsByName["Person"] ?? 0)), .text("existing")])
        }
        try initial.close()

        let required = Schema([
            Schema.Entity(
                name: "Person",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [
                    Schema.Relationship(
                        name: "pet", destination: "Pet", isOptional: false, inverse: nil)
                ]),
            Schema.Entity(name: "Pet", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let inverse = Schema([
            Schema.Entity(
                name: "Person",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [
                    Schema.Relationship(
                        name: "pet", destination: "Pet", inverse: "owners")
                ]),
            Schema.Entity(
                name: "Pet",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [
                    Schema.Relationship(
                        name: "owners", destination: "Person", isToMany: true, inverse: "pet")
                ]),
        ])
        let collidingColumn = Schema([
            Schema.Entity(
                name: "Person",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "pet", type: "String", isOptional: true),
                ],
                relationships: [Schema.Relationship(name: "pet", destination: "Pet")]),
            Schema.Entity(name: "Pet", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        for destination in [required, inverse, collidingColumn] {
            XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination))
            let reopened = try LightweightMigration.openStore(location: location, schema: source)
            let columns = try reopened.read { try $0.rows("PRAGMA table_info(ZPERSON)") }
            XCTAssertFalse(columns.contains { row in row.count > 1 && row[1] == .text("ZPET") })
            XCTAssertEqual(
                try reopened.read { try $0.rows("SELECT ZNAME FROM ZPERSON") },
                [[.text("existing")]])
            try reopened.close()
        }
    }

    func testAddingIndependentFlatRootPreservesExistingRowsAndAddsIndexes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Person", attributes: [Schema.Attribute(name: "name", type: "String")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Address",
                attributes: [
                    Schema.Attribute(name: "street", type: "String"),
                    Schema.Attribute(name: "code", type: "String", options: [.unique]),
                ],
                indexes: [Schema.Index(properties: ["street"])]),
            Schema.Entity(name: "Person", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let sourceIDs = source.entityIDsByName
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZPERSON (Z_ENT, Z_OPT, ZNAME) VALUES (?, 1, ?)",
                [.int(Int64(sourceIDs["Person"] ?? 0)), .text("existing")])
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let destinationIDs = try XCTUnwrap(
            migrated.read { try LightweightMigration.storedEntityIDs(schema: destination, connection: $0) })
        XCTAssertEqual(destinationIDs["Person"], sourceIDs["Person"])
        let addressID = try XCTUnwrap(destinationIDs["Address"])
        XCTAssertGreaterThan(addressID, try XCTUnwrap(sourceIDs.values.max()))
        XCTAssertEqual(try migrated.read { try $0.rows("SELECT ZNAME FROM ZPERSON") }, [[.text("existing")]])
        XCTAssertEqual(
            try migrated.read {
                try $0.rows("SELECT Z_SUPER, Z_MAX FROM Z_PRIMARYKEY WHERE Z_ENT = ?", [.int(Int64(addressID))])
            },
            [[.int(0), .int(0)]])
        let objects = try migrated.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type IN ('table', 'index')")
        }
        XCTAssertTrue(objects.contains([.text("ZADDRESS")]))
        XCTAssertTrue(objects.contains([.text("ZADDRESS_ZCODE_UNIQUE_INDEX")]))
        XCTAssertTrue(objects.contains([.text("ZADDRESS_ZSTREET_INDEX")]))
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        try reopened.close()
    }

    func testAddingFlatRootRejectsTamperedRetainedIndexBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(
                name: "Person",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                indexes: [Schema.Index(properties: ["name"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Address",
                attributes: [Schema.Attribute(name: "street", type: "String")],
                indexes: [Schema.Index(properties: ["street"])]),
            source.entities[0],
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "add-root-tampered-source-index"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("DROP INDEX ZPERSON_ZNAME_INDEX")
            try connection.execute("CREATE INDEX ZPERSON_ZNAME_INDEX ON ZPERSON (Z_PK)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected retained source index tampering to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZADDRESS'").isEmpty
            })
        XCTAssertEqual(
            try driver.read { try $0.rows("PRAGMA index_info(ZPERSON_ZNAME_INDEX)") }.first?[2],
            .text("Z_PK"))
        try driver.close()
    }

    func testAddingFlatRootWithRelationshipsFailsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Person", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Pet", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "Person", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Pet", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "Kennel",
                relationships: [Schema.Relationship(name: "pets", destination: "Pet", isToMany: true)]),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.close()
        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination))
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        let tables = try reopened.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZKENNEL'")
        }
        XCTAssertTrue(tables.isEmpty)
        try reopened.close()
    }

    func testAddingFlatRootsRejectsCrossObjectTableIndexCollisionAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([Schema.Entity(name: "Person")])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "value", type: "Int")],
                indexes: [Schema.Index(properties: ["value"])]),
            Schema.Entity(name: "Owner_ZValue_INDEX"),
            Schema.Entity(name: "Person"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination))
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        let tables = try reopened.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        XCTAssertEqual(
            Set(
                tables.compactMap { row -> String? in
                    guard case let .text(name)? = row.first else { return nil }
                    return name
                }),
            [
                "ZPERSON", "Z_PRIMARYKEY", "_osd_history_changes", "_osd_history_transactions", "_osd_meta",
                "sqlite_sequence",
            ])
        try reopened.close()
    }

    func testHierarchyMigrationAddsIndependentRootWithoutRenumberingEntities() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Aardvark", attributes: [Schema.Attribute(name: "label", type: "String")]),
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let sourceIDs = try XCTUnwrap(
            initial.read { try LightweightMigration.storedEntityIDs(schema: source, connection: $0) })
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZANIMAL (Z_ENT, Z_OPT) VALUES (?, 1)", [.int(Int64(sourceIDs["Dog"]!))])
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let destinationIDs = try XCTUnwrap(
            migrated.read { try LightweightMigration.storedEntityIDs(schema: destination, connection: $0) })
        XCTAssertEqual(destinationIDs["Animal"], sourceIDs["Animal"])
        XCTAssertEqual(destinationIDs["Dog"], sourceIDs["Dog"])
        let rootID = try XCTUnwrap(destinationIDs["Aardvark"])
        XCTAssertGreaterThan(rootID, try XCTUnwrap(sourceIDs.values.max()))
        let rootMetadata: [StoredValue]? = try migrated.read {
            try $0.rows(
                "SELECT Z_SUPER, Z_MAX FROM Z_PRIMARYKEY WHERE Z_ENT = ?", [.int(Int64(rootID))]
            ).first
        }
        XCTAssertEqual(rootMetadata, [.int(0), .int(0)])
        let oldRows = try migrated.read { try $0.rows("SELECT Z_ENT, Z_PK FROM ZANIMAL") }
        XCTAssertEqual(oldRows, [[.int(Int64(sourceIDs["Dog"]!)), .int(1)]])
        let newRootRows = try migrated.read { try $0.rows("SELECT Z_PK, Z_ENT, ZLABEL FROM ZAARDVARK") }
        XCTAssertTrue(newRootRows.isEmpty)

        try migrated.write { connection in
            try connection.execute(
                "INSERT INTO ZAARDVARK (Z_ENT, Z_OPT, ZLABEL) VALUES (?, 1, ?)",
                [.int(Int64(rootID)), .text("new root")])
        }
        let inserted = try migrated.read { try $0.rows("SELECT Z_PK, Z_ENT, ZLABEL FROM ZAARDVARK") }
        XCTAssertEqual(inserted, [[.int(1), .int(Int64(rootID)), .text("new root")]])
        try migrated.close()
    }

    func testHierarchyMigrationAddsEntirelyNewRootAndLeafTree() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
            Schema.Entity(name: "NewRoot", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "NewLeaf",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "label", type: "String", isOptional: true),
                ],
                relationships: [
                    Schema.Relationship(name: "target", destination: "Target", isToMany: false, isOptional: true)
                ],
                superentityName: "NewRoot"),
            Schema.Entity(name: "Target"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let sourceIDs = try XCTUnwrap(
            initial.read { try LightweightMigration.storedEntityIDs(schema: source, connection: $0) })
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZANIMAL (Z_ENT, Z_OPT) VALUES (?, 1)", [.int(Int64(sourceIDs["Dog"]!))])
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let destinationIDs = try XCTUnwrap(
            migrated.read { try LightweightMigration.storedEntityIDs(schema: destination, connection: $0) })
        XCTAssertEqual(destinationIDs["Animal"], sourceIDs["Animal"])
        XCTAssertEqual(destinationIDs["Dog"], sourceIDs["Dog"])
        XCTAssertEqual(destinationIDs["Target"], sourceIDs["Target"])
        let rootID = try XCTUnwrap(destinationIDs["NewRoot"])
        let leafID = try XCTUnwrap(destinationIDs["NewLeaf"])
        XCTAssertLessThan(rootID, leafID)
        XCTAssertGreaterThan(rootID, try XCTUnwrap(sourceIDs.values.max()))
        XCTAssertEqual(
            try migrated.read {
                try $0.rows("SELECT Z_SUPER FROM Z_PRIMARYKEY WHERE Z_ENT = ?", [.int(Int64(rootID))]).first?.first
            },
            .int(0))
        XCTAssertEqual(
            try migrated.read {
                try $0.rows("SELECT Z_SUPER FROM Z_PRIMARYKEY WHERE Z_ENT = ?", [.int(Int64(leafID))]).first?.first
            },
            .int(Int64(rootID)))
        let columns = try migrated.read { try $0.rows("PRAGMA table_info(ZNEWROOT)") }
        XCTAssertTrue(columns.contains { $0.count > 1 && $0[1] == .text("ZNAME") })
        XCTAssertTrue(columns.contains { $0.count > 1 && $0[1] == .text("ZLABEL") })
        XCTAssertTrue(columns.contains { $0.count > 1 && $0[1] == .text("ZNEWLEAF_TARGET") })
        let oldRows = try migrated.read { try $0.rows("SELECT Z_ENT, Z_PK FROM ZANIMAL") }
        XCTAssertEqual(oldRows, [[.int(Int64(sourceIDs["Dog"]!)), .int(1)]])
        try migrated.close()
    }

    func testHierarchyMigrationAddsIndependentRootWithOptionalToOneRelationship() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Aardvark",
                relationships: [
                    Schema.Relationship(name: "target", destination: "Target", isToMany: false, isOptional: true)
                ]),
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
            Schema.Entity(name: "Target"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let sourceIDs = try XCTUnwrap(
            initial.read { try LightweightMigration.storedEntityIDs(schema: source, connection: $0) })
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZANIMAL (Z_ENT, Z_OPT) VALUES (?, 1)", [.int(Int64(sourceIDs["Dog"]!))])
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let destinationIDs = try XCTUnwrap(
            migrated.read { try LightweightMigration.storedEntityIDs(schema: destination, connection: $0) })
        XCTAssertEqual(destinationIDs["Animal"], sourceIDs["Animal"])
        XCTAssertEqual(destinationIDs["Dog"], sourceIDs["Dog"])
        XCTAssertEqual(destinationIDs["Target"], sourceIDs["Target"])
        let rootID = try XCTUnwrap(destinationIDs["Aardvark"])
        let columns = try migrated.read { try $0.rows("PRAGMA table_info(ZAARDVARK)") }
        XCTAssertTrue(columns.contains { $0.count > 1 && $0[1] == .text("ZTARGET") })
        let rootIndexes = try migrated.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZAARDVARK'")
        }
        let expectedIndex = try XCTUnwrap(
            SchemaBuilder.build(destination).statements.first {
                $0.contains("CREATE INDEX ZAARDVARK_ZTARGET_INDEX")
            })
        XCTAssertTrue(rootIndexes.contains([.text(String(expectedIndex.dropLast()))]))
        let parent = try migrated.read {
            try $0.rows("SELECT Z_SUPER FROM Z_PRIMARYKEY WHERE Z_ENT = ?", [.int(Int64(rootID))]).first?.first
        }
        XCTAssertEqual(parent, .int(0))
        let oldRows = try migrated.read { try $0.rows("SELECT Z_ENT, Z_PK FROM ZANIMAL") }
        XCTAssertEqual(oldRows, [[.int(Int64(sourceIDs["Dog"]!)), .int(1)]])
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        try reopened.close()
    }

    func testHierarchyMigrationAddsIndependentRootWithToManyJoinTable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Aardvark",
                relationships: [
                    Schema.Relationship(name: "targets", destination: "Target", isToMany: true)
                ]),
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
            Schema.Entity(name: "Target"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let sourceIDs = try XCTUnwrap(
            initial.read { try LightweightMigration.storedEntityIDs(schema: source, connection: $0) })
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let destinationIDs = try XCTUnwrap(
            migrated.read { try LightweightMigration.storedEntityIDs(schema: destination, connection: $0) })
        let rootID = try XCTUnwrap(destinationIDs["Aardvark"])
        XCTAssertEqual(destinationIDs["Animal"], sourceIDs["Animal"])
        XCTAssertEqual(destinationIDs["Dog"], sourceIDs["Dog"])
        XCTAssertEqual(destinationIDs["Target"], sourceIDs["Target"])

        let tables = try migrated.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z_%'")
        }
        XCTAssertTrue(tables.contains([.text("Z_AARDVARK_TARGETS_TARGET")]))
        let indexes = try migrated.read {
            try $0.rows(
                "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'Z_AARDVARK_TARGETS_TARGET'"
            )
        }
        XCTAssertEqual(
            Set(
                indexes.compactMap { row -> String? in
                    guard case let .text(name)? = row.first else { return nil }
                    return name
                }),
            ["Z_AARDVARK_TARGETS_TARGET_UNIQUE_INDEX", "Z_AARDVARK_TARGETS_TARGET_Z_B_INDEX"])
        let parent = try migrated.read {
            try $0.rows("SELECT Z_SUPER FROM Z_PRIMARYKEY WHERE Z_ENT = ?", [.int(Int64(rootID))]).first?.first
        }
        XCTAssertEqual(parent, .int(0))
        try migrated.close()
    }

    func testAddingLeafSubclassBelowExistingSubtype() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
            Schema.Entity(
                name: "Puppy",
                attributes: [Schema.Attribute(name: "collar", type: "String", isOptional: true)],
                superentityName: "Dog"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let oldIDs = try initial.read {
            try XCTUnwrap(LightweightMigration.storedEntityIDs(schema: source, connection: $0))
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let newIDs = try migrated.read {
            try XCTUnwrap(LightweightMigration.storedEntityIDs(schema: destination, connection: $0))
        }
        XCTAssertEqual(newIDs["Animal"], oldIDs["Animal"])
        XCTAssertEqual(newIDs["Dog"], oldIDs["Dog"])
        XCTAssertGreaterThan(try XCTUnwrap(newIDs["Puppy"]), try XCTUnwrap(oldIDs.values.max()))
        let rows = try migrated.read {
            try $0.rows("SELECT Z_SUPER FROM Z_PRIMARYKEY WHERE Z_ENT = ?", [.int(Int64(newIDs["Puppy"]!))])
        }
        XCTAssertEqual(rows, [[.int(Int64(newIDs["Dog"]!))]])
        try migrated.close()
    }

    func testFirstSubclassAdditionRejectsExistingRelationshipColumnRenameAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let ownerRelationship = Schema.Relationship(
            name: "target", destination: "Target", isToMany: false, isOptional: true)
        let source = Schema([
            Schema.Entity(name: "Owner", relationships: [ownerRelationship]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Owner", relationships: [ownerRelationship]),
            Schema.Entity(name: "OwnerChild", superentityName: "Owner"),
            Schema.Entity(name: "Target"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let sourceColumns = try initial.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertTrue(sourceColumns.contains { $0.count > 1 && $0[1] == .text("ZTARGET") })
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        let columns = try reopened.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertTrue(columns.contains { $0.count > 1 && $0[1] == .text("ZTARGET") })
        XCTAssertFalse(columns.contains { $0.count > 1 && $0[1] == .text("ZOWNER_TARGET") })
        let primaryKeys = try reopened.read {
            try $0.rows("SELECT Z_NAME FROM Z_PRIMARYKEY ORDER BY Z_ENT")
        }
        XCTAssertEqual(primaryKeys, [[.text("Owner")], [.text("Target")]])
        try reopened.close()
    }

    func testHierarchyLeafSubclassAdditionAllowsRequiredDefaultedAttributes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([Schema.Entity(name: "Animal")])
        let destination = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(
                name: "Cat",
                attributes: [Schema.Attribute(name: "name", type: "String", defaultValue: "Milo")],
                superentityName: "Animal"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let sourceIDs = try initial.read {
            try XCTUnwrap(LightweightMigration.storedEntityIDs(schema: source, connection: $0))
        }
        try initial.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try reopened.read { try LightweightMigration.storedEntityIDs(schema: destination, connection: $0) }?[
                "Animal"],
            sourceIDs["Animal"])
        let definition = try reopened.read {
            try $0.rows("PRAGMA table_info(ZANIMAL)").first { $0.count > 5 && $0[1] == .text("ZNAME") }
        }
        XCTAssertEqual(definition?[2], .text("VARCHAR"))
        XCTAssertEqual(definition?[3], .int(0))
        let rows = try reopened.read { try $0.rows("SELECT Z_PK, Z_ENT, ZNAME FROM ZANIMAL") }
        XCTAssertTrue(rows.isEmpty)
        try reopened.close()
    }

    func testHierarchyLeafMigrationRollsBackEarlierColumnAdditionOnFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([Schema.Entity(name: "Animal")])
        let destination = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(
                name: "Cat",
                attributes: [
                    Schema.Attribute(name: "aColor", type: "String", isOptional: true),
                    Schema.Attribute(name: "zUnsupported", type: "UnsupportedScalar", isOptional: true),
                ],
                superentityName: "Animal"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination))

        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        let columns = try reopened.read { try $0.rows("PRAGMA table_info(ZANIMAL)") }
        XCTAssertFalse(columns.contains { $0.count > 1 && $0[1] == .text("ZACOLOR") })
        let entityIDs = try reopened.read {
            try XCTUnwrap(LightweightMigration.storedEntityIDs(schema: source, connection: $0))
        }
        XCTAssertEqual(entityIDs, source.entityIDsByName)
        let entityRows = try reopened.read {
            try $0.rows("SELECT Z_NAME FROM Z_PRIMARYKEY ORDER BY Z_ENT")
        }
        XCTAssertEqual(entityRows, [[.text("Animal")]])
        try reopened.close()
    }

    func testHierarchyMigrationRejectsReparentingExistingEntityAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let sourceIDs = try initial.read {
            try XCTUnwrap(LightweightMigration.storedEntityIDs(schema: source, connection: $0))
        }
        try initial.write { connection in
            try connection.execute(
                "INSERT INTO ZANIMAL (Z_ENT, Z_OPT) VALUES (?, 1)",
                [.int(Int64(try XCTUnwrap(sourceIDs["Dog"])))])
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try LightweightMigration.storedEntityIDs(schema: source, connection: $0) },
            sourceIDs)
        let rows = try reopened.read { try $0.rows("SELECT Z_ENT FROM ZANIMAL") }
        XCTAssertEqual(rows, [[.int(Int64(try XCTUnwrap(sourceIDs["Dog"])))]])
        try reopened.close()
    }

    func testHierarchyAttributeRemovalFailsBeforeWrites() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-hierarchy-remove-attribute"))
        let source = Schema([
            Schema.Entity(name: "Base", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "Child",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "age", type: "Int"),
                ],
                superentityName: "Base"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Base", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "Child",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                superentityName: "Base"),
        ])

        XCTAssertThrowsError(
            try driver.write { connection in
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let tables = try driver.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        }
        XCTAssertTrue(tables.isEmpty)
        try driver.close()
    }

    func testHierarchySiblingAttributeDefinitionConflictFailsBeforeWrites() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-hierarchy-sibling-conflict"))
        let source = Schema([
            Schema.Entity(name: "Base", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "First", attributes: [Schema.Attribute(name: "name", type: "String")], superentityName: "Base"),
            Schema.Entity(
                name: "Second", attributes: [Schema.Attribute(name: "name", type: "String")], superentityName: "Base"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Base", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "First",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "extra", type: "String", isOptional: true),
                ],
                superentityName: "Base"),
            Schema.Entity(
                name: "Second",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "extra", type: "Int", isOptional: true),
                ],
                superentityName: "Base"),
        ])

        XCTAssertThrowsError(
            try driver.write { connection in
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let tables = try driver.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        }
        XCTAssertTrue(tables.isEmpty)
        try driver.close()
    }

    func testHierarchySiblingCaseVariantColumnAdditionCoalesces() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-hierarchy-case-variant"))
        let source = Schema([
            Schema.Entity(name: "Base", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "First", attributes: [Schema.Attribute(name: "name", type: "String")], superentityName: "Base"),
            Schema.Entity(
                name: "Second", attributes: [Schema.Attribute(name: "name", type: "String")], superentityName: "Base"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Base", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "First",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "note", type: "String", isOptional: true),
                ],
                superentityName: "Base"),
            Schema.Entity(
                name: "Second",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "NOTE", type: "String", isOptional: true),
                ],
                superentityName: "Base"),
        ])

        try driver.write { try LightweightMigration.openOrMigrate(to: source, connection: $0) }
        try driver.write { try LightweightMigration.openOrMigrate(to: destination, connection: $0) }
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZBASE)") }
        XCTAssertEqual(columns.filter { $0.count > 1 && $0[1] == .text("ZNOTE") }.count, 1)
        try driver.close()
    }

    func testHierarchyLeafAdditionMigratesOptionalOwningToOneRelationship() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(name: "Child", superentityName: "Base"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(name: "Child", superentityName: "Base"),
            Schema.Entity(
                name: "Sibling",
                relationships: [
                    Schema.Relationship(name: "mentor", destination: "Base", isToMany: false, isOptional: true)
                ],
                superentityName: "Base"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let sourceIDs = try initial.read {
            try XCTUnwrap(LightweightMigration.storedEntityIDs(schema: source, connection: $0))
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let destinationIDs = try migrated.read {
            try XCTUnwrap(LightweightMigration.storedEntityIDs(schema: destination, connection: $0))
        }
        let siblingID = try XCTUnwrap(destinationIDs["Sibling"])
        XCTAssertEqual(destinationIDs["Base"], sourceIDs["Base"])
        XCTAssertEqual(destinationIDs["Child"], sourceIDs["Child"])
        XCTAssertGreaterThan(siblingID, try XCTUnwrap(sourceIDs.values.max()))
        let columns = try migrated.read { try $0.rows("PRAGMA table_info(ZBASE)") }
        XCTAssertTrue(columns.contains { $0.count > 1 && $0[1] == .text("ZSIBLING_MENTOR") })
        let indexes = try migrated.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'Z%'")
        }
        XCTAssertTrue(indexes.contains([.text("ZBASE_ZSIBLING_MENTOR_INDEX")]))
        let metadata: StoredValue? = try migrated.read {
            try $0.rows(
                "SELECT Z_SUPER FROM Z_PRIMARYKEY WHERE Z_ENT = ?", [.int(Int64(siblingID))]
            ).first?.first
        }
        XCTAssertEqual(metadata, .int(Int64(try XCTUnwrap(destinationIDs["Base"]))))
        try migrated.close()
    }

    func testHierarchyLeafRelationshipMigrationRejectsRequiredToOneRelationship() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(name: "Target"),
            Schema.Entity(
                name: "RequiredChild",
                relationships: [
                    Schema.Relationship(name: "target", destination: "Target", isToMany: false, isOptional: false)
                ],
                superentityName: "Base"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let sourceIDs = try initial.read {
            try XCTUnwrap(LightweightMigration.storedEntityIDs(schema: source, connection: $0))
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try LightweightMigration.storedEntityIDs(schema: source, connection: $0) },
            sourceIDs)
        let primaryKeys = try reopened.read { try $0.rows("SELECT Z_NAME FROM Z_PRIMARYKEY ORDER BY Z_ENT") }
        XCTAssertEqual(primaryKeys, [[.text("Base")], [.text("Target")]])
        try reopened.close()
    }

    func testHierarchyLeafRelationshipMigrationRejectsCascadeToOneRelationship() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(name: "Target"),
            Schema.Entity(
                name: "CascadeChild",
                relationships: [
                    Schema.Relationship(
                        name: "target", destination: "Target", isToMany: false, isOptional: true,
                        deleteRule: .cascade)
                ],
                superentityName: "Base"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let sourceIDs = try initial.read {
            try XCTUnwrap(LightweightMigration.storedEntityIDs(schema: source, connection: $0))
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try LightweightMigration.storedEntityIDs(schema: source, connection: $0) },
            sourceIDs)
        try reopened.close()
    }

    func testHierarchyLeafInverseCannotReattachAnAlreadyInversedRelationship() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(
                        name: "target", destination: "TargetBase", isToMany: false, isOptional: true,
                        inverse: "owners")
                ]),
            Schema.Entity(
                name: "TargetBase",
                relationships: [
                    Schema.Relationship(name: "owners", destination: "Owner", isToMany: true, inverse: "target")
                ]),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(
                        name: "target", destination: "TargetBase", isToMany: false, isOptional: true,
                        inverse: "owners")
                ]),
            Schema.Entity(
                name: "TargetBase",
                relationships: [
                    Schema.Relationship(name: "owners", destination: "Owner", isToMany: true, inverse: "target")
                ]),
            Schema.Entity(
                name: "TargetChild",
                relationships: [
                    Schema.Relationship(name: "owners", destination: "Owner", isToMany: true, inverse: "target")
                ],
                superentityName: "TargetBase"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        let entityNames = try reopened.read {
            try $0.rows("SELECT Z_NAME FROM Z_PRIMARYKEY ORDER BY Z_ENT")
        }
        XCTAssertEqual(entityNames, [[.text("Owner")], [.text("TargetBase")]])
        try reopened.close()
    }

    func testHierarchyLeafRelationshipMigrationRejectsIndexNameCollisionBeforeWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "A"),
            Schema.Entity(name: "A_ZB"),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(name: "A"),
            Schema.Entity(name: "A_ZB"),
            Schema.Entity(name: "Target"),
            Schema.Entity(
                name: "B",
                relationships: [
                    Schema.Relationship(name: "ZLeaf1_Rel", destination: "Target", isOptional: true)
                ],
                superentityName: "A"),
            Schema.Entity(
                name: "Leaf1",
                relationships: [Schema.Relationship(name: "Rel", destination: "Target", isOptional: true)],
                superentityName: "A_ZB"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        let primaryKeys = try reopened.read { try $0.rows("SELECT Z_NAME FROM Z_PRIMARYKEY ORDER BY Z_ENT") }
        XCTAssertEqual(primaryKeys, [[.text("A")], [.text("A_ZB")], [.text("Target")]])
        let indexes = try reopened.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'Z%'")
        }
        XCTAssertFalse(indexes.contains([.text("ZA_ZB_ZLEAF1_REL_INDEX")]))
        try reopened.close()
    }

    func testHierarchyMigrationRejectsDestinationIndexNameCollisionBeforeDDL() throws {
        let source = Schema([Schema.Entity(name: "Base")])
        let destination = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(
                name: "Child",
                attributes: [Schema.Attribute(name: "age", type: "Int")],
                indexes: [Schema.Index(properties: ["age"])],
                superentityName: "Base"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "hierarchy-index-object-collision"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("CREATE TABLE ZBASE_CHILD_ZAGE_INDEX (value INTEGER)")
        }
        let originalTables = try driver.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected hierarchy index name collision to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") },
            originalTables)
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZBASE_CHILD_ZAGE_INDEX'")
                    .isEmpty
            })
        try driver.close()
    }

    func testHierarchyAttributeAdditionRejectsRelationshipColumnCollision() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-hierarchy-fk-collision"))
        let source = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(
                name: "Owner",
                relationships: [Schema.Relationship(name: "target", destination: "Target")],
                superentityName: "Base"),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Base"),
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "Owner_target", type: "Int", isOptional: true)],
                relationships: [Schema.Relationship(name: "target", destination: "Target")],
                superentityName: "Base"),
            Schema.Entity(name: "Target"),
        ])
        try bootstrap(source, driver: driver)

        XCTAssertThrowsError(
            try driver.write { connection in
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZBASE)") }
        let collisionColumn = columns.filter { $0.count > 2 && $0[1] == .text("ZOWNER_TARGET") }
        XCTAssertEqual(collisionColumn.count, 1)
        XCTAssertEqual(collisionColumn.first?[2], .text("INTEGER"))
        try driver.close()
    }

    func testHierarchyTopologyAndAttributeMovesFailClosedBeforeWrites() throws {
        let variants = [
            Schema([
                Schema.Entity(name: "Root", attributes: [Schema.Attribute(name: "name", type: "String")]),
                Schema.Entity(name: "Child", superentityName: "Root"),
            ]),
            Schema([
                Schema.Entity(name: "Root"),
                Schema.Entity(name: "Child", attributes: [Schema.Attribute(name: "name", type: "String")]),
            ]),
            Schema([
                Schema.Entity(name: "Root"),
                Schema.Entity(name: "First", superentityName: "Root"),
                Schema.Entity(name: "Second"),
                Schema.Entity(name: "Grandchild", superentityName: "Second"),
            ]),
        ]
        for (index, destination) in variants.enumerated() {
            let driver = try GRDBSQLiteDriver(location: .memory(name: "hierarchy-migration-guard-\(index)"))
            let source = Schema([
                Schema.Entity(name: "Root", attributes: [Schema.Attribute(name: "name", type: "String")]),
                Schema.Entity(
                    name: "Child", attributes: [Schema.Attribute(name: "name", type: "String")], superentityName: "Root"
                ),
                Schema.Entity(name: "Second"),
                Schema.Entity(name: "Grandchild", superentityName: "Second"),
            ])

            XCTAssertThrowsError(
                try driver.write { connection in
                    try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
                }
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected migrationUnsupported, got \(error)")
                }
            }
            let tables = try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
            }
            XCTAssertTrue(tables.isEmpty)
            try driver.close()
        }
    }

    func testIndexAddAndRemovalMigrateOnExistingRows() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-index-change"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")])
        ])
        let indexed = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")],
                indexes: [Schema.Index(properties: ["title"])])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZTITLE) VALUES (1, 1, ?)", [.text("kept")])
            try LightweightMigration.migrate(source: source, destination: indexed, connection: connection)
        }
        let addedIndexes = try driver.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index'") }
        XCTAssertTrue(addedIndexes.contains([.text("ZRECORD_ZTITLE_INDEX")]))

        try driver.write { try LightweightMigration.migrate(source: indexed, destination: source, connection: $0) }
        let removedIndexes = try driver.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index'") }
        XCTAssertFalse(removedIndexes.contains([.text("ZRECORD_ZTITLE_INDEX")]))
        XCTAssertEqual(try driver.read { try $0.rows("SELECT ZTITLE FROM ZRECORD") }, [[.text("kept")]])
        try driver.close()
    }

    func testCombinedIndexConstraintChangesApplyAsOneMigration() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "combined-index-constraint-changes"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "a", type: "Int"),
                    Schema.Attribute(name: "b", type: "Int"),
                    Schema.Attribute(name: "c", type: "Int"),
                    Schema.Attribute(name: "d", type: "Int"),
                ],
                indexes: [
                    Schema.Index(properties: ["a"]),
                    Schema.Index(properties: ["b"], isUnique: true),
                    Schema.Index(properties: ["c", "d"]),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "a", type: "Int", options: [.unique]),
                    Schema.Attribute(name: "b", type: "Int"),
                    Schema.Attribute(name: "c", type: "Int"),
                    Schema.Attribute(name: "d", type: "Int"),
                ],
                indexes: [
                    Schema.Index(properties: ["a"]),
                    Schema.Index(properties: ["c", "d"], isUnique: true),
                    Schema.Index(properties: ["d", "c"]),
                ])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZA, ZB, ZC, ZD) VALUES (1, 2, 1, 5, 7, 9)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZA, ZB, ZC, ZD) VALUES (1, 3, 2, 6, 7, 10)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        let definitions = try driver.read {
            try $0.rows(
                "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD' ORDER BY name")
        }
        XCTAssertEqual(
            definitions.compactMap { row -> String? in
                guard row.count > 1, case let .text(sql) = row[1] else { return nil }
                return sql
            },
            [
                "CREATE INDEX ZRECORD_ZA_INDEX ON ZRECORD (ZA)",
                "CREATE UNIQUE INDEX ZRECORD_ZA_UNIQUE_INDEX ON ZRECORD (ZA)",
                "CREATE UNIQUE INDEX ZRECORD_ZC_ZD_UNIQUE_INDEX ON ZRECORD (ZC, ZD)",
                "CREATE INDEX ZRECORD_ZD_ZC_INDEX ON ZRECORD (ZD, ZC)",
            ])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZA, ZB, ZC, ZD FROM ZRECORD ORDER BY Z_PK") },
            [
                [.int(1), .int(2), .int(1), .int(5), .int(7), .int(9)],
                [.int(2), .int(3), .int(2), .int(6), .int(7), .int(10)],
            ])
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZA, ZB, ZC, ZD) VALUES (1, 4, 3, 5, 8, 8)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try $0.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZA, ZB, ZC, ZD) VALUES (1, 5, 1, 5, 8, 9)")
            })
        XCTAssertEqual(try driver.read { try $0.rows("SELECT COUNT(*) FROM ZRECORD") }, [[.int(3)]])
        try driver.close()
    }

    func testIndexConstraintMigrationRollsBackAllChangesWhenLaterUniqueCreationFails() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "index-constraint-rollback"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "a", type: "Int"), Schema.Attribute(name: "b", type: "Int")],
                indexes: [Schema.Index(properties: ["a"]), Schema.Index(properties: ["b"])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "a", type: "Int"), Schema.Attribute(name: "b", type: "Int")],
                indexes: [Schema.Index(properties: ["a"], isUnique: true), Schema.Index(properties: ["b"])])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZA, ZB) VALUES (1, 1, 1, 7)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZA, ZB) VALUES (1, 2, 1, 8)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            XCTAssertTrue(String(describing: error).contains("UNIQUE constraint failed"))
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD' ORDER BY name")
            },
            [[.text("ZRECORD_ZA_INDEX")], [.text("ZRECORD_ZB_INDEX")]])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZA, ZB FROM ZRECORD ORDER BY Z_PK") },
            [[.int(1), .int(1), .int(1), .int(7)], [.int(2), .int(2), .int(1), .int(8)]])
        try driver.close()
    }

    func testIndexConstraintMigrationRejectsTamperedAndCollidingPhysicalIndexes() throws {
        let schema = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "a", type: "Int")])
        ])
        let indexed = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "a", type: "Int")],
                indexes: [Schema.Index(properties: ["a"])])
        ])

        let tampered = try GRDBSQLiteDriver(location: .memory(name: "index-constraint-tampered"))
        try bootstrap(indexed, driver: tampered)
        try tampered.write { connection in
            try connection.execute("DROP INDEX ZRECORD_ZA_INDEX")
            try connection.execute("CREATE INDEX ZRECORD_ZA_INDEX ON ZRECORD (Z_PK)")
        }
        XCTAssertThrowsError(
            try tampered.write {
                try LightweightMigration.migrate(source: indexed, destination: schema, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected tampered generated index to be rejected, got \(error)")
            }
        }
        XCTAssertTrue(
            try tampered.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZRECORD_ZA_INDEX'").count
                    == 1
            })
        try tampered.close()

        let collision = try GRDBSQLiteDriver(location: .memory(name: "index-constraint-collision"))
        try bootstrap(schema, driver: collision)
        try collision.write { connection in
            try connection.execute("CREATE INDEX ZRECORD_ZA_INDEX ON ZRECORD (Z_PK)")
        }
        XCTAssertThrowsError(
            try collision.write {
                try LightweightMigration.migrate(source: schema, destination: indexed, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected physical name collision to be rejected, got \(error)")
            }
        }
        XCTAssertEqual(
            try collision.read { try $0.rows("PRAGMA index_info(ZRECORD_ZA_INDEX)") }.first?[2],
            .text("Z_PK"))
        try collision.close()
    }

    func testIndexReconciliationRejectsUntrackedIndexUnderUnchangedGeneratedName() throws {
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "value", type: "Int")],
                indexes: [Schema.Index(properties: ["value"])])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "unchanged-generated-name-impostor"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("CREATE INDEX ZRECORD_ZVALUE_INDEX ON ZRECORD (Z_PK)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected untracked index under generated destination name to fail, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("PRAGMA index_info(ZRECORD_ZVALUE_INDEX)") }.first?[2],
            .text("Z_PK"))
        try driver.close()
    }

    func testIndexReconciliationAllowsValidatedScheduledNameReuse() throws {
        let source = Schema([
            Schema.Entity(
                name: "A", attributes: [Schema.Attribute(name: "old", type: "String")],
                indexes: [Schema.Index(properties: ["old"])]),
            Schema.Entity(name: "B", attributes: [Schema.Attribute(name: "value", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "A", attributes: [Schema.Attribute(name: "value", type: "String", originalName: "old")],
                indexes: [Schema.Index(properties: ["value"])]),
            Schema.Entity(name: "B", attributes: [Schema.Attribute(name: "value", type: "String")]),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "validated-scheduled-index-reuse"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZA (Z_ENT, Z_OPT, ZOLD) VALUES (1, 1, 'a')")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZA'")
            },
            [[.text("ZA_ZVALUE_INDEX"), .text("CREATE INDEX ZA_ZVALUE_INDEX ON ZA (ZVALUE)")]])
        XCTAssertEqual(try driver.read { try $0.rows("SELECT ZVALUE FROM ZA") }, [[.text("a")]])
        try driver.close()
    }

    func testIndexReconciliationRejectsTamperedSourceBeforeAttributeRename() throws {
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "email", type: "String", options: [.unique])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "address", type: "String", options: [.unique], originalName: "email")
                ])
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "tampered-index-rename-preflight"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZEMAIL) VALUES (1, 2, 'kept')")
            try connection.execute("DROP INDEX ZRECORD_ZEMAIL_UNIQUE_INDEX")
            try connection.execute("CREATE INDEX ZRECORD_ZEMAIL_UNIQUE_INDEX ON ZRECORD (Z_PK)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected tampered source index to fail before rename, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT ZEMAIL FROM ZRECORD") },
            [[.text("kept")]])
        XCTAssertTrue(
            try driver.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZRECORD_ZEMAIL_UNIQUE_INDEX'"
                )
                .count == 1
            })
        try driver.close()
    }

    func testUniqueAttributeAdditionCreatesIndexAndDuplicateFailureRollsBack() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-unique-toggle"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "email", type: "String")])
        ])
        let unique = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "email", type: "String", options: [.unique])])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZEMAIL) VALUES (1, 1, ?)", [.text("same")])
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZEMAIL) VALUES (1, 1, ?)", [.text("same")])
        }

        XCTAssertThrowsError(
            try driver.write { try LightweightMigration.migrate(source: source, destination: unique, connection: $0) })
        let indexes = try driver.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index'") }
        XCTAssertFalse(indexes.contains([.text("ZRECORD_ZEMAIL_UNIQUE_INDEX")]))
        XCTAssertEqual(try driver.read { try $0.rows("SELECT COUNT(*) FROM ZRECORD") }, [[.int(2)]])

        try driver.write { connection in
            try connection.execute("DELETE FROM ZRECORD WHERE Z_PK = 2")
            try LightweightMigration.migrate(source: source, destination: unique, connection: connection)
        }
        let migratedIndexes = try driver.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index'") }
        XCTAssertTrue(migratedIndexes.contains([.text("ZRECORD_ZEMAIL_UNIQUE_INDEX")]))
        try driver.close()
    }

    func testUniqueAttributeRemovalDropsConstraintAndPreservesRows() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-unique-removal"))
        let unique = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "email", type: "String", options: [.unique])])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "email", type: "String")])
        ])
        try bootstrap(unique, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZEMAIL) VALUES (1, 1, ?)", [.text("same")])
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZEMAIL) VALUES (1, 1, ?)", [.text("other")])
            try LightweightMigration.migrate(source: unique, destination: destination, connection: connection)
        }
        let remainingIndexes = try driver.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZRECORD'")
        }
        XCTAssertFalse(remainingIndexes.contains([.text("ZRECORD_ZEMAIL_UNIQUE_INDEX")]))
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, ZEMAIL FROM ZRECORD ORDER BY Z_PK") },
            [[.int(1), .text("same")], [.int(2), .text("other")]])
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZEMAIL) VALUES (1, 1, ?)", [.text("same")])
        }
        XCTAssertEqual(try driver.read { try $0.rows("SELECT COUNT(*) FROM ZRECORD") }, [[.int(3)]])
        try driver.close()
    }

    func testOptionalOwningToOneRelationshipRemovalDropsColumnAndIndex() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [Schema.Relationship(name: "favorite", destination: "Target")]),
            Schema.Entity(name: "Target", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "Owner", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Target", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZNAME, ZFAVORITE) VALUES (1, 3, 'owner', 1)")
            try connection.execute("INSERT INTO ZTARGET (Z_ENT, Z_OPT, ZNAME) VALUES (2, 4, 'target')")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let ownerColumns = try migrated.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertFalse(ownerColumns.contains(where: { $0.count > 1 && $0[1] == .text("ZFAVORITE") }))
        let relationshipIndex = try migrated.read {
            try $0.rows(
                "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZOWNER_ZFAVORITE_INDEX'")
        }
        XCTAssertTrue(relationshipIndex.isEmpty)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZOWNER") },
            [[.int(1), .int(3), .text("owner")]])
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZTARGET") },
            [[.int(1), .int(4), .text("target")]])
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertTrue(
            try reopened.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
                .allSatisfy({ $0.count <= 1 || $0[1] != .text("ZFAVORITE") }))
        try reopened.close()
    }

    func testMultipleOptionalOwningToOneRelationshipsCanBeRemovedTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("multiple-to-one-removal.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [
                    Schema.Relationship(name: "primary", destination: "Target"),
                    Schema.Relationship(name: "secondary", destination: "Target"),
                ]),
            Schema.Entity(name: "Target", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "Owner", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Target", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZTARGET (Z_ENT, Z_OPT, ZNAME) VALUES (2, 7, 'target')")
            try connection.execute(
                "INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZNAME, ZPRIMARY, ZSECONDARY) VALUES (1, 4, 'owner', NULL, NULL)")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        let ownerColumns = try migrated.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertFalse(
            ownerColumns.contains(where: { row in
                guard row.count > 1, case let .text(name) = row[1] else { return false }
                return ["ZPRIMARY", "ZSECONDARY"].contains(name)
            }))
        XCTAssertTrue(
            try migrated.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZOWNER'").isEmpty
            })
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT, ZNAME FROM ZOWNER") },
            [[.int(1), .int(1), .int(4), .text("owner")]])
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT, ZNAME FROM ZTARGET") },
            [[.int(1), .int(2), .int(7), .text("target")]])
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(try reopened.read { try $0.rows("SELECT ZNAME FROM ZOWNER") }, [[.text("owner")]])
        try reopened.close()
    }

    func testMultipleToOneRemovalDiscardsLinksWhilePreservingOwnerAndTargetRows() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "first", destination: "Target"),
                    Schema.Relationship(name: "second", destination: "Target"),
                ]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([Schema.Entity(name: "Owner"), Schema.Entity(name: "Target")])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-to-one-nonnull"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 5, NULL, 2)")
            try connection.execute("INSERT INTO ZTARGET (Z_ENT, Z_OPT) VALUES (2, 8)")
        }
        try driver.write {
            try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT FROM ZOWNER") },
            [[.int(1), .int(1), .int(5)]])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT FROM ZTARGET") },
            [[.int(1), .int(2), .int(8)]])
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertFalse(
            columns.contains(where: { row in
                guard row.count > 1, case let .text(name) = row[1] else { return false }
                return ["ZFIRST", "ZSECOND"].contains(name)
            }))
        try driver.close()
    }

    func testMultipleToOneRemovalPreflightsEveryRelationshipBeforeDroppingIndexes() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "first", destination: "Target"),
                    Schema.Relationship(name: "second", destination: "Target"),
                ]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([Schema.Entity(name: "Owner"), Schema.Entity(name: "Target")])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-to-one-preflight"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("DROP INDEX ZOWNER_ZSECOND_INDEX")
            try connection.execute("CREATE INDEX CUSTOM_SECOND_INDEX ON ZOWNER (ZSECOND)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected unsafe second relationship index to reject the removal, got \(error)")
            }
        }
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertTrue(columns.contains(where: { $0.count > 1 && $0[1] == .text("ZFIRST") }))
        XCTAssertTrue(columns.contains(where: { $0.count > 1 && $0[1] == .text("ZSECOND") }))
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZOWNER' ORDER BY name")
            },
            [[.text("CUSTOM_SECOND_INDEX")], [.text("ZOWNER_ZFIRST_INDEX")]])
        try driver.close()
    }

    func testMultipleToOneRemovalRejectsCheckDependencyBeforeDroppingIndexes() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "first", destination: "Target"),
                    Schema.Relationship(name: "second", destination: "Target"),
                ]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([Schema.Entity(name: "Owner"), Schema.Entity(name: "Target")])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-to-one-check-dependency"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("DROP TABLE ZOWNER")
            try connection.execute(
                "CREATE TABLE ZOWNER (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZFIRST INTEGER, ZSECOND INTEGER CHECK (ZSECOND IS NULL OR ZSECOND > 0))"
            )
            try connection.execute("INSERT INTO ZOWNER (Z_PK, Z_ENT, Z_OPT) VALUES (1, 1, 1)")
            try connection.execute("CREATE INDEX ZOWNER_ZFIRST_INDEX ON ZOWNER (ZFIRST)")
            try connection.execute("CREATE INDEX ZOWNER_ZSECOND_INDEX ON ZOWNER (ZSECOND)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected CHECK dependency to reject relationship removal, got \(error)")
            }
        }
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertTrue(columns.contains(where: { $0.count > 1 && $0[1] == .text("ZFIRST") }))
        XCTAssertTrue(columns.contains(where: { $0.count > 1 && $0[1] == .text("ZSECOND") }))
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZOWNER_ZFIRST_INDEX'")
                    .count == 1
            })
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZOWNER_ZSECOND_INDEX'")
                    .count == 1
            })
        try driver.close()
    }

    func testMultipleToOneRelationshipAndScalarRemovalPreservesRows() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [
                    Schema.Attribute(name: "obsolete", type: "String"),
                    Schema.Attribute(name: "identity", type: "String", options: [.unique]),
                ],
                relationships: [
                    Schema.Relationship(name: "first", destination: "Target"),
                    Schema.Relationship(name: "second", destination: "Target"),
                ]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner", attributes: [Schema.Attribute(name: "identity", type: "String", options: [.unique])]),
            Schema.Entity(name: "Target"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-to-one-combined-scalar"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZTARGET (Z_ENT, Z_OPT) VALUES (2, 3)")
            try connection.execute(
                "INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZOBSOLETE, ZIDENTITY, ZFIRST, ZSECOND) "
                    + "VALUES (1, 5, 'remove', 'id-1', 2, 2)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertEqual(
            columns.compactMap { row -> String? in
                guard row.count > 1, case let .text(name) = row[1] else { return nil }
                return name
            },
            ["Z_PK", "Z_ENT", "Z_OPT", "ZIDENTITY"])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT, ZIDENTITY FROM ZOWNER") },
            [[.int(1), .int(1), .int(5), .text("id-1")]])
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZOWNER'")
            },
            [[.text("ZOWNER_ZIDENTITY_UNIQUE_INDEX")]])
        XCTAssertThrowsError(
            try driver.write {
                try $0.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZIDENTITY) VALUES (1, 9, 'id-1')")
            })
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT FROM ZTARGET") }, [[.int(1), .int(2), .int(3)]])
        try driver.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT) VALUES (1, 7)")
        }
        XCTAssertEqual(try driver.read { try $0.rows("SELECT COUNT(*) FROM ZOWNER") }, [[.int(2)]])
        try driver.close()
    }

    func testCombinedScalarRelationshipRemovalUpdatesRetainedOrdinaryIndexes() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [
                    Schema.Attribute(name: "obsolete", type: "String"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                relationships: [Schema.Relationship(name: "target", destination: "Target")],
                indexes: [Schema.Index(properties: ["retained", "obsolete"])]), Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "retained", type: "String")],
                indexes: [Schema.Index(properties: ["retained"])],
            ),
            Schema.Entity(name: "Target"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "combined-removal-index-update"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZOBSOLETE, ZRETAINED, ZTARGET) VALUES (1, 3, 'old', 'kept', NULL)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZOWNER'")
            },
            [[.text("ZOWNER_ZRETAINED_INDEX"), .text("CREATE INDEX ZOWNER_ZRETAINED_INDEX ON ZOWNER (ZRETAINED)")]])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZRETAINED FROM ZOWNER") },
            [[.int(1), .int(3), .text("kept")]])
        try driver.close()
    }

    func testCombinedRemovalDropsSharedCompositeIndexAndAddsRetainedIndex() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [
                    Schema.Attribute(name: "obsolete", type: "String"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                relationships: [Schema.Relationship(name: "target", destination: "Target")],
                indexes: [Schema.Index(properties: ["obsolete", "retained"])]), Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "retained", type: "String")],
                indexes: [Schema.Index(properties: ["retained"])],
            ),
            Schema.Entity(name: "Target"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "combined-removal-composite-index"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZOBSOLETE, ZRETAINED, ZTARGET) VALUES (1, 5, 'drop', 'keep', NULL)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZOWNER'")
            },
            [[.text("ZOWNER_ZRETAINED_INDEX"), .text("CREATE INDEX ZOWNER_ZRETAINED_INDEX ON ZOWNER (ZRETAINED)")]])
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZRETAINED FROM ZOWNER") },
            [[.int(1), .int(5), .text("keep")]])
        try driver.close()
    }

    func testOpeningStoreMigratesCombinedScalarAndRelationshipRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("combined-removal-open.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Target", attributes: [Schema.Attribute(name: "label", type: "String")]),
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "obsolete", type: "Int32", isOptional: true),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                relationships: [
                    Schema.Relationship(
                        name: "target",
                        destination: "Target",
                        isToMany: false,
                        isOptional: true,
                        inverse: nil,
                        deleteRule: .nullify)
                ]),
        ])
        let destination = Schema([
            Schema.Entity(name: "Target", attributes: [Schema.Attribute(name: "label", type: "String")]),
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "retained", type: "String")]),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZTARGET (Z_ENT, Z_OPT, ZLABEL) VALUES (1, 13, 'target stays')")
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZOBSOLETE, ZRETAINED, ZTARGET) VALUES (2, 17, 42, 'owner stays', 1)"
            )
        }
        let sourceHash = try initial.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                .first?.first
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZLABEL FROM ZTARGET") },
            [[.int(1), .int(13), .text("target stays")]])
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZRETAINED FROM ZRECORD") },
            [[.int(1), .int(17), .text("owner stays")]])
        let destinationHash = try migrated.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                .first?.first
        }
        XCTAssertNotEqual(destinationHash, sourceHash)
        XCTAssertFalse(
            try migrated.read {
                try $0.rows("PRAGMA table_info(ZRECORD)").contains(where: {
                    $0.count > 1 && ($0[1] == .text("ZOBSOLETE") || $0[1] == .text("ZTARGET"))
                })
            })
        XCTAssertTrue(
            try migrated.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZRECORD_ZTARGET_INDEX'")
                    .isEmpty
            })
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZRETAINED FROM ZRECORD") },
            [[.int(1), .int(17), .text("owner stays")]])
        XCTAssertEqual(
            try reopened.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                    .first?.first
            },
            destinationHash)
        XCTAssertEqual(try reopened.read { try $0.rows("PRAGMA integrity_check") }, [[.text("ok")]])
        try reopened.close()
    }

    func testOpeningStoreRollsBackCombinedRemovalWhenLaterEntityNarrowingFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("combined-removal-later-failure.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "ARecord",
                attributes: [
                    Schema.Attribute(name: "obsolete", type: "Int32", isOptional: true),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                relationships: [
                    Schema.Relationship(
                        name: "target",
                        destination: "Target",
                        isToMany: false,
                        isOptional: true,
                        inverse: nil,
                        deleteRule: .nullify)
                ]),
            Schema.Entity(name: "Target", attributes: [Schema.Attribute(name: "label", type: "String")]),
            Schema.Entity(name: "ZNumber", attributes: [Schema.Attribute(name: "value", type: "Int64")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "ARecord", attributes: [Schema.Attribute(name: "retained", type: "String")]),
            Schema.Entity(name: "Target", attributes: [Schema.Attribute(name: "label", type: "String")]),
            Schema.Entity(name: "ZNumber", attributes: [Schema.Attribute(name: "value", type: "Int32")]),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZTARGET (Z_ENT, Z_OPT, ZLABEL) VALUES (2, 13, 'target stays')")
            try connection.execute(
                "INSERT INTO ZARECORD (Z_ENT, Z_OPT, ZOBSOLETE, ZRETAINED, ZTARGET) VALUES (1, 17, 42, 'owner stays', 2)"
            )
            try connection.execute("INSERT INTO ZZNUMBER (Z_ENT, Z_OPT, ZVALUE) VALUES (3, 19, 2147483648)")
        }
        let originalHash = try initial.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                .first?.first
        }
        let originalVersion = try initial.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaVersionKey)])
                .first?.first
        }
        let originalRecordColumns = try initial.read { try $0.rows("PRAGMA table_info(ZARECORD)") }
        let originalRecordIndexes = try initial.read {
            try $0.rows(
                "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZARECORD' ORDER BY name")
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected later entity narrowing to fail, got \(error)")
            }
        }

        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZOBSOLETE, ZRETAINED, ZTARGET FROM ZARECORD") },
            [[.int(1), .int(17), .int(42), .text("owner stays"), .int(2)]])
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZLABEL FROM ZTARGET") },
            [[.int(1), .int(13), .text("target stays")]])
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZVALUE FROM ZZNUMBER") },
            [[.int(1), .int(19), .int(2_147_483_648)]])
        XCTAssertEqual(try reopened.read { try $0.rows("PRAGMA table_info(ZARECORD)") }, originalRecordColumns)
        XCTAssertEqual(
            try reopened.read {
                try $0.rows(
                    "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZARECORD' ORDER BY name")
            },
            originalRecordIndexes)
        XCTAssertEqual(
            try reopened.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                    .first?.first
            },
            originalHash)
        XCTAssertEqual(
            try reopened.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaVersionKey)])
                    .first?.first
            },
            originalVersion)
        XCTAssertTrue(
            try reopened.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE name LIKE '%OSD_REBUILD%' OR name LIKE '%_tmp%'")
                    .isEmpty
            })
        XCTAssertEqual(try reopened.read { try $0.rows("PRAGMA integrity_check") }, [[.text("ok")]])
        try reopened.close()
    }

    func testOpeningStoreRemovesReciprocalToOneToManyRelationshipPair() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("inverse-pair-removal.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "AOwner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [
                    Schema.Relationship(
                        name: "target",
                        destination: "ZTarget",
                        isToMany: false,
                        isOptional: true,
                        inverse: "owners",
                        deleteRule: .nullify)
                ]),
            Schema.Entity(
                name: "ZTarget",
                attributes: [Schema.Attribute(name: "label", type: "String")],
                relationships: [
                    Schema.Relationship(
                        name: "owners",
                        destination: "AOwner",
                        isToMany: true,
                        isOptional: true,
                        inverse: "target")
                ]),
        ])
        let destination = Schema([
            Schema.Entity(name: "AOwner", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "ZTarget", attributes: [Schema.Attribute(name: "label", type: "String")]),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZZTARGET (Z_ENT, Z_OPT, ZLABEL) VALUES (2, 23, 'target retained')")
            try connection.execute(
                "INSERT INTO ZAOWNER (Z_ENT, Z_OPT, ZNAME, ZTARGET) VALUES (1, 29, 'owner retained', 1)")
        }
        try initial.close()
        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZAOWNER") },
            [[.int(1), .int(29), .text("owner retained")]])
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZLABEL FROM ZZTARGET") },
            [[.int(1), .int(23), .text("target retained")]])
        XCTAssertFalse(
            try migrated.read {
                try $0.rows("PRAGMA table_info(ZAOWNER)").contains(where: { $0.count > 1 && $0[1] == .text("ZTARGET") })
            })
        XCTAssertTrue(
            try migrated.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZAOWNER_ZTARGET_INDEX'")
                    .isEmpty
            })
        XCTAssertTrue(
            try migrated.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'table' "
                        + "AND name = 'Z_AOWNER_TARGET_ZTARGET_OWNERS'"
                ).isEmpty
            })
        try migrated.close()
        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZAOWNER") },
            [[.int(1), .int(29), .text("owner retained")]])
        XCTAssertEqual(try reopened.read { try $0.rows("PRAGMA integrity_check") }, [[.text("ok")]])
        try reopened.close()
    }

    func testInverseRelationshipPairRemovalRejectsSingleEndpointRemoval() throws {
        let source = Schema([
            Schema.Entity(
                name: "AOwner",
                relationships: [
                    Schema.Relationship(
                        name: "target", destination: "ZTarget", isOptional: true, inverse: "owners")
                ]),
            Schema.Entity(
                name: "ZTarget",
                relationships: [
                    Schema.Relationship(
                        name: "owners", destination: "AOwner", isToMany: true, inverse: "target")
                ]),
        ])
        let destination = Schema([
            Schema.Entity(name: "AOwner"),
            Schema.Entity(
                name: "ZTarget",
                relationships: [
                    Schema.Relationship(
                        name: "owners", destination: "AOwner", isToMany: true, inverse: "target")
                ]),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "inverse-pair-single-endpoint-reject"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected one-sided inverse removal to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZAOWNER)").contains(where: { $0.count > 1 && $0[1] == .text("ZTARGET") })
            })
        try driver.close()
    }

    func testInverseRelationshipPairRemovalRejectsChangedInverseAndManyToMany() throws {
        let source = Schema([
            Schema.Entity(
                name: "AOwner",
                relationships: [
                    Schema.Relationship(
                        name: "target", destination: "ZTarget", isOptional: true, inverse: "owners")
                ]),
            Schema.Entity(
                name: "ZTarget",
                relationships: [
                    Schema.Relationship(
                        name: "owners", destination: "AOwner", isToMany: true, inverse: "target")
                ]),
        ])
        let changedInverse = Schema([
            Schema.Entity(name: "AOwner"),
            Schema.Entity(
                name: "ZTarget",
                relationships: [
                    Schema.Relationship(
                        name: "owners", destination: "AOwner", isToMany: true)
                ]),
        ])
        let manyToManySource = Schema([
            Schema.Entity(
                name: "AOwner",
                relationships: [
                    Schema.Relationship(
                        name: "targets", destination: "ZTarget", isToMany: true, inverse: "owners")
                ]),
            Schema.Entity(
                name: "ZTarget",
                relationships: [
                    Schema.Relationship(
                        name: "owners", destination: "AOwner", isToMany: true, inverse: "targets")
                ]),
        ])
        let manyToManyDestination = Schema([Schema.Entity(name: "AOwner"), Schema.Entity(name: "ZTarget")])
        for (name, source, destination) in [
            ("changed-inverse", source, changedInverse),
            ("many-to-many", manyToManySource, manyToManyDestination),
        ] {
            let driver = try GRDBSQLiteDriver(location: .memory(name: "inverse-pair-reject-\(name)"))
            try bootstrap(source, driver: driver)
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected \(name) pair removal to fail closed, got \(error)")
                }
            }
            try driver.close()
        }
    }

    func testInversePairRemovalRejectsWhenToOneDoesNotOwnStorage() throws {
        let source = Schema([
            Schema.Entity(
                name: "ACollection",
                relationships: [
                    Schema.Relationship(
                        name: "owners", destination: "ZOwner", isToMany: true, inverse: "collection")
                ]),
            Schema.Entity(
                name: "ZOwner",
                relationships: [
                    Schema.Relationship(
                        name: "collection", destination: "ACollection", isOptional: true, inverse: "owners")
                ]),
        ])
        let destination = Schema([Schema.Entity(name: "ACollection"), Schema.Entity(name: "ZOwner")])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "inverse-pair-wrong-owner-reject"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected an inverse pair with reversed ownership to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZZOWNER)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZCOLLECTION")
                })
            })
        try driver.close()
    }

    func testInversePairRemovalRejectsDestinationOriginalNameClaim() throws {
        let source = Schema([
            Schema.Entity(
                name: "AOwner",
                relationships: [
                    Schema.Relationship(
                        name: "target", destination: "ZTarget", isOptional: true, inverse: "owners")
                ]),
            Schema.Entity(
                name: "ZTarget",
                relationships: [
                    Schema.Relationship(
                        name: "owners", destination: "AOwner", isToMany: true, inverse: "target")
                ]),
        ])
        let destination = Schema([
            Schema.Entity(name: "AOwner"),
            Schema.Entity(
                name: "ZTarget",
                relationships: [
                    Schema.Relationship(
                        name: "renamedOwners",
                        destination: "AOwner",
                        isToMany: true,
                        inverse: "target",
                        originalName: "owners")
                ]),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "inverse-pair-original-name-claim-reject"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected destination originalName claim to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZAOWNER)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZTARGET")
                })
            })
        try driver.close()
    }

    func testInversePairRemovalRejectsCaseVariantRetainedEndpoint() throws {
        let source = Schema([
            Schema.Entity(
                name: "AOwner",
                relationships: [
                    Schema.Relationship(
                        name: "target", destination: "ZTarget", isOptional: true, inverse: "owners")
                ]),
            Schema.Entity(
                name: "ZTarget",
                relationships: [
                    Schema.Relationship(
                        name: "owners", destination: "AOwner", isToMany: true, inverse: "target")
                ]),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "AOwner",
                relationships: [
                    Schema.Relationship(
                        name: "TARGET", destination: "ZTarget", isOptional: true)
                ]),
            Schema.Entity(name: "ZTarget"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "inverse-pair-case-variant-endpoint-reject"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected case-variant endpoint retention to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZAOWNER)").contains(where: {
                    $0.count > 1 && $0[1] == .text("ZTARGET")
                })
            })
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA index_list(ZAOWNER)") }.count, 1)
        try driver.close()
    }

    func testInversePairRemovalRejectsTamperedOwnerForeignKeyIndex() throws {
        let source = Schema([
            Schema.Entity(
                name: "AOwner",
                relationships: [
                    Schema.Relationship(
                        name: "target", destination: "ZTarget", isOptional: true, inverse: "owners")
                ]),
            Schema.Entity(
                name: "ZTarget",
                relationships: [
                    Schema.Relationship(
                        name: "owners", destination: "AOwner", isToMany: true, inverse: "target")
                ]),
        ])
        let destination = Schema([Schema.Entity(name: "AOwner"), Schema.Entity(name: "ZTarget")])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "inverse-pair-tampered-owner-index"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZZTARGET (Z_ENT, Z_OPT) VALUES (2, 3)")
            try connection.execute("INSERT INTO ZAOWNER (Z_ENT, Z_OPT, ZTARGET) VALUES (1, 5, 1)")
            try connection.execute("DROP INDEX ZAOWNER_ZTARGET_INDEX")
            try connection.execute("CREATE INDEX ZAOWNER_ZTARGET_INDEX ON ZAOWNER (Z_PK)")
        }
        let originalColumns = try driver.read { try $0.rows("PRAGMA table_info(ZAOWNER)") }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected tampered owner relationship index to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA table_info(ZAOWNER)") }, originalColumns)
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZTARGET FROM ZAOWNER") },
            [[.int(1), .int(5), .int(1)]])
        XCTAssertEqual(
            try driver.read { try $0.rows("PRAGMA index_info(ZAOWNER_ZTARGET_INDEX)") }.compactMap { row -> String? in
                guard row.count > 2, case let .text(column) = row[2] else { return nil }
                return column
            },
            ["Z_PK"])
        try driver.close()
    }

    func testOpeningStoreRollsBackInversePairRemovalOnLaterEntityFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("inverse-pair-later-failure.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "AOwner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [
                    Schema.Relationship(
                        name: "target", destination: "BTarget", isOptional: true, inverse: "owners")
                ]),
            Schema.Entity(
                name: "BTarget",
                attributes: [Schema.Attribute(name: "label", type: "String")],
                relationships: [
                    Schema.Relationship(
                        name: "owners", destination: "AOwner", isToMany: true, inverse: "target")
                ]),
            Schema.Entity(name: "ZNumber", attributes: [Schema.Attribute(name: "value", type: "Int64")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "AOwner", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "BTarget", attributes: [Schema.Attribute(name: "label", type: "String")]),
            Schema.Entity(name: "ZNumber", attributes: [Schema.Attribute(name: "value", type: "Int32")]),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZBTARGET (Z_ENT, Z_OPT, ZLABEL) VALUES (2, 23, 'target retained')")
            try connection.execute(
                "INSERT INTO ZAOWNER (Z_ENT, Z_OPT, ZNAME, ZTARGET) VALUES (1, 29, 'owner retained', 1)")
            try connection.execute("INSERT INTO ZZNUMBER (Z_ENT, Z_OPT, ZVALUE) VALUES (3, 31, 2147483648)")
        }
        let sourceHash = try initial.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                .first?.first
        }
        let sourceVersion = try initial.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaVersionKey)])
                .first?.first
        }
        let sourceOwnerColumns = try initial.read { try $0.rows("PRAGMA table_info(ZAOWNER)") }
        let sourceOwnerIndexes = try initial.read {
            try $0.rows(
                "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZAOWNER' ORDER BY name")
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected later narrowing to fail after inverse-pair removal, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME, ZTARGET FROM ZAOWNER") },
            [[.int(1), .int(29), .text("owner retained"), .int(1)]])
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZLABEL FROM ZBTARGET") },
            [[.int(1), .int(23), .text("target retained")]])
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZVALUE FROM ZZNUMBER") },
            [[.int(1), .int(31), .int(2_147_483_648)]])
        XCTAssertEqual(try reopened.read { try $0.rows("PRAGMA table_info(ZAOWNER)") }, sourceOwnerColumns)
        XCTAssertEqual(
            try reopened.read {
                try $0.rows(
                    "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZAOWNER' ORDER BY name")
            },
            sourceOwnerIndexes)
        XCTAssertEqual(
            try reopened.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)])
                    .first?.first
            },
            sourceHash)
        XCTAssertEqual(
            try reopened.read {
                try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaVersionKey)])
                    .first?.first
            },
            sourceVersion)
        XCTAssertTrue(
            try reopened.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE name LIKE '%OSD_REBUILD%' OR name LIKE '%_tmp%'")
                    .isEmpty
            })
        XCTAssertEqual(try reopened.read { try $0.rows("PRAGMA integrity_check") }, [[.text("ok")]])
        try reopened.close()
    }

    func testInversePairRemovalRejectsCombinedAttributeEdit() throws {
        let source = Schema([
            Schema.Entity(
                name: "AOwner",
                attributes: [Schema.Attribute(name: "retained", type: "String")],
                relationships: [
                    Schema.Relationship(
                        name: "target", destination: "ZTarget", isOptional: true, inverse: "owners")
                ]),
            Schema.Entity(
                name: "ZTarget",
                attributes: [Schema.Attribute(name: "label", type: "String")],
                relationships: [
                    Schema.Relationship(
                        name: "owners", destination: "AOwner", isToMany: true, inverse: "target")
                ]),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "AOwner",
                attributes: [
                    Schema.Attribute(name: "retained", type: "String"),
                    Schema.Attribute(name: "added", type: "String", isOptional: true),
                ]),
            Schema.Entity(name: "ZTarget", attributes: [Schema.Attribute(name: "label", type: "String")]),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "inverse-pair-attribute-edit-reject"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZZTARGET (Z_ENT, Z_OPT, ZLABEL) VALUES (2, 4, 'target')")
            try connection.execute("INSERT INTO ZAOWNER (Z_ENT, Z_OPT, ZRETAINED, ZTARGET) VALUES (1, 6, 'owner', 1)")
        }
        let originalColumns = try driver.read { try $0.rows("PRAGMA table_info(ZAOWNER)") }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected paired removal with attribute addition to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA table_info(ZAOWNER)") }, originalColumns)
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZRETAINED, ZTARGET FROM ZAOWNER") },
            [[.int(1), .int(6), .text("owner"), .int(1)]])
        try driver.close()
    }

    func testCombinedRemovalRejectsCustomCompositeIndexOnRelationshipColumn() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [
                    Schema.Attribute(name: "obsolete", type: "String"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                relationships: [Schema.Relationship(name: "target", destination: "Target")],
                indexes: [Schema.Index(properties: ["retained"])]), Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "retained", type: "String")],
                indexes: [Schema.Index(properties: ["retained"])],
            ),
            Schema.Entity(name: "Target"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "combined-remove-custom-relationship-index"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZTARGET (Z_ENT, Z_OPT) VALUES (2, 1)")
            try connection.execute(
                "INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZOBSOLETE, ZRETAINED, ZTARGET) "
                    + "VALUES (1, 4, 'remove', 'keep', 2)")
            try connection.execute("CREATE INDEX USER_OWNER_TARGET_RETAINED ON ZOWNER (ZTARGET, ZRETAINED)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected custom relationship index to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZOWNER)").contains(where: { $0.count > 1 && $0[1] == .text("ZTARGET") })
            })
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE name = 'USER_OWNER_TARGET_RETAINED'").count == 1
            })
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT Z_PK, Z_OPT, ZRETAINED FROM ZOWNER") },
            [[.int(1), .int(4), .text("keep")]])
        try driver.close()
    }

    func testCombinedRemovalRejectsTamperedGeneratedIndexBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [
                    Schema.Attribute(name: "obsolete", type: "String"),
                    Schema.Attribute(name: "retained", type: "String"),
                ],
                relationships: [Schema.Relationship(name: "target", destination: "Target")],
                indexes: [Schema.Index(properties: ["retained"])]), Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Owner", attributes: [Schema.Attribute(name: "retained", type: "String")]),
            Schema.Entity(name: "Target"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "combined-removal-tampered-generated-index"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZTARGET (Z_ENT, Z_OPT) VALUES (2, 1)")
            try connection.execute(
                "INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZOBSOLETE, ZRETAINED, ZTARGET) "
                    + "VALUES (1, 2, 'drop', 'keep', 2)")
            try connection.execute("DROP INDEX ZOWNER_ZRETAINED_INDEX")
            try connection.execute("CREATE INDEX ZOWNER_ZRETAINED_INDEX ON ZOWNER (ZTARGET, ZRETAINED)")
        }
        let originalIndexSQL = try driver.read {
            try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'ZOWNER_ZRETAINED_INDEX'")
                .first?.first
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected tampered generated index to fail closed, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZOWNER)").contains(where: { $0.count > 1 && $0[1] == .text("ZTARGET") })
            })
        XCTAssertEqual(
            try driver.read {
                try $0.rows("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'ZOWNER_ZRETAINED_INDEX'")
                    .first?.first
            },
            originalIndexSQL)
        try driver.close()
    }

    func testCombinedRemovalRejectsUniqueIndexOnRemovedScalarBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "obsolete", type: "String", options: [.unique])],
                relationships: [Schema.Relationship(name: "target", destination: "Target")]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([Schema.Entity(name: "Owner"), Schema.Entity(name: "Target")])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "combined-removal-unique-reject"))
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZOBSOLETE, ZTARGET) VALUES (1, 3, 'keep', NULL)")
        }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            })
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZOWNER)").contains(where: { $0.count > 1 && $0[1] == .text("ZOBSOLETE") }
                )
            })
        XCTAssertTrue(
            try driver.read {
                try $0.rows("PRAGMA table_info(ZOWNER)").contains(where: { $0.count > 1 && $0[1] == .text("ZTARGET") })
            })
        try driver.close()
    }

    func testCombinedScalarRelationshipRemovalRejectsHierarchyBeforeDDL() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "obsolete", type: "String")],
                relationships: [Schema.Relationship(name: "target", destination: "Target")]),
            Schema.Entity(
                name: "OwnerSubtype",
                attributes: [Schema.Attribute(name: "obsolete", type: "String")],
                superentityName: "Owner"),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Owner"),
            Schema.Entity(
                name: "OwnerSubtype",
                attributes: [Schema.Attribute(name: "obsolete", type: "String")],
                superentityName: "Owner"),
            Schema.Entity(name: "Target"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "combined-removal-hierarchy"))
        try bootstrap(source, driver: driver)
        let originalColumns = try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            })
        XCTAssertEqual(try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }, originalColumns)
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE name LIKE '%OSD_REBUILD%'").isEmpty
            })
        try driver.close()
    }

    func testMultipleToOneRemovalRejectsChangedRetainedRelationshipMetadata() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "removedA", destination: "Target"),
                    Schema.Relationship(name: "removedB", destination: "Target"),
                    Schema.Relationship(name: "retained", destination: "Target"),
                ]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "retained", destination: "Target", deleteRule: .noAction)
                ]),
            Schema.Entity(name: "Target"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-to-one-retained-change"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected changed retained relationship to fail closed, got \(error)")
            }
        }
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        for column in ["ZREMOVEDA", "ZREMOVEDB", "ZRETAINED"] {
            XCTAssertTrue(columns.contains(where: { $0.count > 1 && $0[1] == .text(column) }))
        }
        try driver.close()
    }

    func testMultipleToOneRemovalRejectsRenameFromRemovedRelationship() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "first", destination: "Target"),
                    Schema.Relationship(name: "second", destination: "Target"),
                ]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [Schema.Relationship(name: "renamed", destination: "Target", originalName: "first")]),
            Schema.Entity(name: "Target"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-to-one-removed-rename"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected relationship rename to be rejected in batched removal, got \(error)")
            }
        }
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        for column in ["ZFIRST", "ZSECOND"] {
            XCTAssertTrue(columns.contains(where: { $0.count > 1 && $0[1] == .text(column) }))
        }
        try driver.close()
    }

    func testMultipleToOneRemovalRejectsInverseDeclaredOutsideTargetEntity() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "first", destination: "Target"),
                    Schema.Relationship(name: "second", destination: "Target"),
                ]),
            Schema.Entity(name: "Target"),
            Schema.Entity(
                name: "Unrelated",
                relationships: [Schema.Relationship(name: "back", destination: "Owner", inverse: "first")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "Owner"),
            Schema.Entity(name: "Target"),
            Schema.Entity(
                name: "Unrelated",
                relationships: [Schema.Relationship(name: "back", destination: "Owner", inverse: "first")]),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "multiple-to-one-external-inverse"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected inverse reference from another entity to reject removal, got \(error)")
            }
        }
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertTrue(columns.contains(where: { $0.count > 1 && $0[1] == .text("ZFIRST") }))
        XCTAssertTrue(columns.contains(where: { $0.count > 1 && $0[1] == .text("ZSECOND") }))
        try driver.close()
    }

    func testFlatScalarAndOptionalRelationshipAdditionsComposeAtomically() throws {
        let location = StoreLocation.file(
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "migration-composed-additions-\(UUID().uuidString).sqlite"))
        let source = Schema([
            Schema.Entity(name: "Owner", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(name: "Target", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "rank", type: "Int", defaultValue: "7"),
                ],
                relationships: [Schema.Relationship(name: "favorite", destination: "Target")]),
            Schema.Entity(name: "Target", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZNAME) VALUES (1, 3, 'owner')")
            try connection.execute("INSERT INTO ZTARGET (Z_ENT, Z_OPT, ZNAME) VALUES (2, 4, 'target')")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME, ZRANK, ZFAVORITE FROM ZOWNER") },
            [[.int(1), .int(3), .text("owner"), .int(7), .null]])
        XCTAssertTrue(
            try migrated.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZOWNER_ZFAVORITE_INDEX'")
                    .count == 1
            })
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_OPT, ZNAME FROM ZTARGET") },
            [[.int(1), .int(4), .text("target")]])
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT ZNAME, ZRANK, ZFAVORITE FROM ZOWNER") },
            [[.text("owner"), .int(7), .null]])
        try reopened.close()
    }

    func testRelationshipRemovalRejectsRequiredCascadeAndInverseLinks() throws {
        let cases: [(String, Schema.Relationship, Schema.Relationship?)] = [
            (
                "required",
                Schema.Relationship(name: "favorite", destination: "Target", isOptional: false),
                nil
            ),
            (
                "cascade",
                Schema.Relationship(name: "favorite", destination: "Target", deleteRule: .cascade),
                nil
            ),
            (
                "inverse",
                Schema.Relationship(name: "favorite", destination: "Target", inverse: "owner"),
                Schema.Relationship(name: "owner", destination: "Owner", inverse: "favorite")
            ),
        ]
        for (caseName, ownerRelationship, targetRelationship) in cases {
            let source = Schema([
                Schema.Entity(name: "Owner", relationships: [ownerRelationship]),
                Schema.Entity(name: "Target", relationships: targetRelationship.map { [$0] } ?? []),
            ])
            let destination = Schema([Schema.Entity(name: "Owner"), Schema.Entity(name: "Target")])
            let driver = try GRDBSQLiteDriver(location: .memory(name: "relationship-removal-\(caseName)"))
            try bootstrap(source, driver: driver)
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected migrationUnsupported, got \(error)")
                }
            }
            XCTAssertTrue(
                try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
                    .contains(where: { $0.count > 1 && $0[1] == .text("ZFAVORITE") }))
            try driver.close()
        }
    }

    func testRelationshipRemovalRejectsCustomIndexesTriggersViewsAndForeignKeys() throws {
        let sideObjects: [(String, String)] = [
            ("index", "CREATE INDEX USER_FAVORITE_INDEX ON ZOWNER (ZFAVORITE)"),
            ("trigger", "CREATE TRIGGER USER_FAVORITE_TRIGGER AFTER UPDATE ON ZOWNER BEGIN SELECT 1; END"),
            ("view", "CREATE VIEW USER_FAVORITE_VIEW AS SELECT ZFAVORITE FROM ZOWNER"),
            ("foreign-key", "CREATE TABLE USER_FAVORITE_FK (owner_id INTEGER REFERENCES ZOWNER(ZFAVORITE))"),
        ]
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [Schema.Relationship(name: "favorite", destination: "Target")]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([Schema.Entity(name: "Owner"), Schema.Entity(name: "Target")])
        for (name, statement) in sideObjects {
            let driver = try GRDBSQLiteDriver(location: .memory(name: "relationship-removal-side-object-\(name)"))
            try bootstrap(source, driver: driver)
            try driver.write { try $0.execute(statement) }
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }, "Expected removal to reject \(name)"
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected migrationUnsupported for \(name), got \(error)")
                }
            }
            XCTAssertTrue(
                try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
                    .contains(where: { $0.count > 1 && $0[1] == .text("ZFAVORITE") }))
            try driver.close()
        }
    }

    func testRelationshipRemovalCannotCombineWithRename() throws {
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "favorite", destination: "Target"),
                    Schema.Relationship(name: "backup", destination: "Target"),
                ]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "fallback", destination: "Target", originalName: "backup")
                ]),
            Schema.Entity(name: "Target"),
        ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "relationship-removal-plus-rename"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZOWNER)") }
        XCTAssertTrue(columns.contains(where: { $0.count > 1 && $0[1] == .text("ZFAVORITE") }))
        XCTAssertTrue(columns.contains(where: { $0.count > 1 && $0[1] == .text("ZBACKUP") }))
        try driver.close()
    }

    func testFlatMigrationRollsBackAddedColumnsWhenUniqueIndexCreationFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "code", type: "Int")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "code", type: "Int"),
                    Schema.Attribute(name: "rank", type: "Int", defaultValue: "0"),
                    Schema.Attribute(name: "token", type: "Int", defaultValue: "0", options: [.unique]),
                ])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZCODE) VALUES (1, 3, 10)")
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZCODE) VALUES (1, 4, 20)")
        }
        let originalHash = try initial.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
            ).first?.first
        }
        let originalEntityRows = try initial.read {
            try $0.rows("SELECT Z_ENT, Z_NAME, Z_SUPER, Z_MAX FROM Z_PRIMARYKEY ORDER BY Z_ENT")
        }
        let originalVersion = try initial.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaVersionKey)]
            ).first?.first
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination))
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        let columns = try reopened.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
        XCTAssertFalse(columns.contains(where: { $0.count > 1 && $0[1] == .text("ZRANK") }))
        XCTAssertFalse(columns.contains(where: { $0.count > 1 && $0[1] == .text("ZTOKEN") }))
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, Z_OPT, ZCODE FROM ZRECORD ORDER BY Z_PK") },
            [[.int(1), .int(3), .int(10)], [.int(2), .int(4), .int(20)]])
        XCTAssertEqual(
            try reopened.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
                ).first?
                .first
            },
            originalHash)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_ENT, Z_NAME, Z_SUPER, Z_MAX FROM Z_PRIMARYKEY ORDER BY Z_ENT") },
            originalEntityRows)
        XCTAssertEqual(
            try reopened.read {
                try $0.rows(
                    "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaVersionKey)]
                ).first?.first
            },
            originalVersion)
        XCTAssertTrue(
            try reopened.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZRECORD_ZTOKEN_UNIQUE_INDEX'"
                )
                .isEmpty
            })
        try reopened.close()
    }

    func testIndependentRootEntityRemovalPreservesRetainedRowsAndIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Retained", attributes: [Schema.Attribute(name: "name", type: "String")]),
            Schema.Entity(
                name: "ZRemoved",
                attributes: [Schema.Attribute(name: "value", type: "String")],
                indexes: [Schema.Index(properties: ["value"])]),
            Schema.Entity(name: "ZZRemoved", attributes: [Schema.Attribute(name: "value", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "Retained", attributes: [Schema.Attribute(name: "name", type: "String")])
        ])
        let sourceRetainedID = try XCTUnwrap(source.entityIDsByName["Retained"])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZZREMOVED (Z_ENT, Z_OPT, ZVALUE) VALUES (2, 1, 'discarded')")
            try connection.execute("INSERT INTO ZZZREMOVED (Z_ENT, Z_OPT, ZVALUE) VALUES (3, 1, 'also-discarded')")
            try connection.execute(
                "INSERT INTO ZRETAINED (Z_ENT, Z_OPT, ZNAME) VALUES (?, ?, ?)",
                [
                    .int(Int64(sourceRetainedID)), .int(5), .text("preserved"),
                ])
            try connection.execute(
                "DELETE FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.entityIDHighWatermarkKey)])
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT, ZNAME FROM ZRETAINED") },
            [[.int(1), .int(Int64(sourceRetainedID)), .int(5), .text("preserved")]])
        XCTAssertTrue(
            try migrated.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZZREMOVED'").isEmpty
                    && $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZZZREMOVED'").isEmpty
            })
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY") },
            [[.int(Int64(sourceRetainedID)), .text("Retained")]])
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_PK, ZNAME FROM ZRETAINED") },
            [[.int(1), .text("preserved")]])
        try reopened.close()

        let addedSchema = Schema([
            Schema.Entity(name: "Newcomer"),
            Schema.Entity(name: "Retained", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let added = try LightweightMigration.openStore(location: location, schema: addedSchema)
        XCTAssertEqual(
            try added.read { try $0.rows("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY ORDER BY Z_ENT") },
            [[.int(1), .text("Retained")], [.int(4), .text("Newcomer")]])
        XCTAssertEqual(try added.read { try LightweightMigration.storedNextEntityIdentifier(connection: $0) }, 5)
        try added.close()

        let emptyLocation = StoreLocation.file(directory.appendingPathComponent("empty-schema.sqlite"))
        let onlyEntity = Schema([
            Schema.Entity(name: "Only", attributes: [Schema.Attribute(name: "value", type: "String")])
        ])
        let emptySchema = Schema([])
        let onlyInitial = try LightweightMigration.openStore(location: emptyLocation, schema: onlyEntity)
        try onlyInitial.write { connection in
            try connection.execute("INSERT INTO ZONLY (Z_ENT, Z_OPT, ZVALUE) VALUES (1, 1, 'removed')")
        }
        try onlyInitial.close()
        let emptyStore = try LightweightMigration.openStore(location: emptyLocation, schema: emptySchema)
        XCTAssertTrue(
            try emptyStore.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZONLY'").isEmpty
            })
        XCTAssertTrue(try emptyStore.read { try $0.rows("SELECT Z_ENT FROM Z_PRIMARYKEY").isEmpty })
        try emptyStore.close()
    }

    func testIndependentRootRemovalDropsOutgoingOptionalToOneStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("owner-removal.sqlite"))
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                attributes: [Schema.Attribute(name: "name", type: "String")],
                relationships: [Schema.Relationship(name: "target", destination: "Target")]),
            Schema.Entity(name: "Target", attributes: [Schema.Attribute(name: "name", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "Target", attributes: [Schema.Attribute(name: "name", type: "String")])
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZTARGET (Z_ENT, Z_OPT, ZNAME) VALUES (2, 6, 'target')")
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZNAME, ZTARGET) VALUES (1, 4, 'owner', 1)")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT, ZNAME FROM ZTARGET") },
            [[.int(1), .int(2), .int(6), .text("target")]])
        XCTAssertTrue(
            try migrated.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZOWNER'").isEmpty
            })
        XCTAssertTrue(
            try migrated.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ZOWNER_ZTARGET_INDEX'")
                    .isEmpty
            })
        XCTAssertTrue(
            try migrated.read {
                try $0.rows("SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'Owner'").isEmpty
            })
        XCTAssertEqual(try migrated.read { try LightweightMigration.storedNextEntityIdentifier(connection: $0) }, 3)
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(try reopened.read { try $0.rows("SELECT ZNAME FROM ZTARGET") }, [[.text("target")]])
        try reopened.close()
    }

    func testIndependentRootRemovalRejectsOutgoingLinkToAnotherRemovedRoot() throws {
        let source = Schema([
            Schema.Entity(name: "Retained"),
            Schema.Entity(name: "Owner", relationships: [Schema.Relationship(name: "target", destination: "Target")]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([Schema.Entity(name: "Retained")])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "entity-removal-two-linked-roots"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected linked root removals to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('ZOWNER', 'ZTARGET') ORDER BY name"
                )
            },
            [[.text("ZOWNER")], [.text("ZTARGET")]])
        try driver.close()
    }

    func testMixedRemovalOfRelationshipOwnerAndAdditionPreservesTargetAndIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("mixed-owner-removal.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Alpha"),
            Schema.Entity(name: "Owner", relationships: [Schema.Relationship(name: "target", destination: "Target")]),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Alpha"),
            Schema.Entity(name: "NewRoot"),
            Schema.Entity(name: "Target"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZTARGET (Z_ENT, Z_OPT) VALUES (3, 8)")
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZTARGET) VALUES (2, 5, 1)")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT FROM ZTARGET") }, [[.int(1), .int(3), .int(8)]])
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY ORDER BY Z_ENT") },
            [[.int(1), .text("Alpha")], [.int(3), .text("Target")], [.int(4), .text("NewRoot")]])
        XCTAssertTrue(
            try migrated.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZOWNER'").isEmpty
            })
        XCTAssertEqual(try migrated.read { try LightweightMigration.storedNextEntityIdentifier(connection: $0) }, 5)
        try migrated.close()
    }

    func testMixedRelationshipOwnerRemovalRejectsGeneratedIndexTableCollision() throws {
        let source = Schema([
            Schema.Entity(name: "Retained"),
            Schema.Entity(name: "Owner", relationships: [Schema.Relationship(name: "favorite", destination: "Target")]),
            Schema.Entity(name: "Target"),
        ])
        let nextID = try XCTUnwrap(source.entityIDsByName.values.max()) + 1
        let destination = try Schema(
            [
                Schema.Entity(name: "Retained"),
                Schema.Entity(name: "Target"),
                Schema.Entity(name: "OWNER_ZFAVORITE_INDEX"),
            ],
            entityIDs: [
                "Retained": try XCTUnwrap(source.entityIDsByName["Retained"]),
                "Target": try XCTUnwrap(source.entityIDsByName["Target"]),
                "OWNER_ZFAVORITE_INDEX": nextID,
            ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "mixed-owner-index-table-collision"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected generated relationship index/table collision to fail, got \(error)")
            }
        }
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZOWNER'").count == 1
            })
        XCTAssertTrue(
            try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZOWNER_ZFAVORITE_INDEX'")
                    .isEmpty
            })
        try driver.close()
    }

    func testIndependentRootRemovalRejectsUnsafeOutgoingAndInboundRelationships() throws {
        let cases: [(String, Schema, Schema)] = [
            (
                "required",
                Schema([
                    Schema.Entity(
                        name: "Owner",
                        relationships: [Schema.Relationship(name: "target", destination: "Target", isOptional: false)]),
                    Schema.Entity(name: "Target"),
                ]),
                Schema([Schema.Entity(name: "Target")])
            ),
            (
                "cascade",
                Schema([
                    Schema.Entity(
                        name: "Owner",
                        relationships: [
                            Schema.Relationship(name: "target", destination: "Target", deleteRule: .cascade)
                        ]),
                    Schema.Entity(name: "Target"),
                ]),
                Schema([Schema.Entity(name: "Target")])
            ),
            (
                "inbound",
                Schema([
                    Schema.Entity(name: "Owner"),
                    Schema.Entity(
                        name: "Target", relationships: [Schema.Relationship(name: "owner", destination: "Owner")]),
                ]),
                Schema([
                    Schema.Entity(
                        name: "Target", relationships: [Schema.Relationship(name: "owner", destination: "Owner")])
                ])
            ),
            (
                "to-many",
                Schema([
                    Schema.Entity(
                        name: "Owner",
                        relationships: [Schema.Relationship(name: "targets", destination: "Target", isToMany: true)]),
                    Schema.Entity(name: "Target"),
                ]),
                Schema([Schema.Entity(name: "Target")])
            ),
            (
                "inverse",
                Schema([
                    Schema.Entity(
                        name: "Owner",
                        relationships: [Schema.Relationship(name: "target", destination: "Target", inverse: "owner")]),
                    Schema.Entity(
                        name: "Target",
                        relationships: [Schema.Relationship(name: "owner", destination: "Owner", inverse: "target")]),
                ]),
                Schema([Schema.Entity(name: "Target")])
            ),
            (
                "minimum-count",
                Schema([
                    Schema.Entity(
                        name: "Owner",
                        relationships: [
                            Schema.Relationship(name: "target", destination: "Target", minimumModelCount: 1)
                        ]),
                    Schema.Entity(name: "Target"),
                ]),
                Schema([Schema.Entity(name: "Target")])
            ),
            (
                "maximum-count",
                Schema([
                    Schema.Entity(
                        name: "Owner",
                        relationships: [
                            Schema.Relationship(name: "target", destination: "Target", maximumModelCount: 2)
                        ]),
                    Schema.Entity(name: "Target"),
                ]),
                Schema([Schema.Entity(name: "Target")])
            ),
            (
                "deny",
                Schema([
                    Schema.Entity(
                        name: "Owner",
                        relationships: [Schema.Relationship(name: "target", destination: "Target", deleteRule: .deny)]),
                    Schema.Entity(name: "Target"),
                ]),
                Schema([Schema.Entity(name: "Target")])
            ),
            (
                "external-storage",
                Schema([
                    Schema.Entity(
                        name: "Owner",
                        attributes: [Schema.Attribute(name: "payload", type: "Data", options: [.externalStorage])],
                        relationships: [Schema.Relationship(name: "target", destination: "Target")]),
                    Schema.Entity(name: "Target"),
                ]),
                Schema([Schema.Entity(name: "Target")])
            ),
        ]
        for (name, source, destination) in cases {
            let driver = try GRDBSQLiteDriver(location: .memory(name: "entity-removal-unsafe-relationship-\(name)"))
            try bootstrap(source, driver: driver)
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected \(name) relationship removal to fail closed, got \(error)")
                }
            }
            XCTAssertTrue(
                try driver.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZOWNER'").count == 1
                })
            try driver.close()
        }
    }

    func testIndependentRootRemovalAndAdditionComposeWithoutReusingIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Alpha", attributes: [Schema.Attribute(name: "label", type: "String")]),
            Schema.Entity(name: "Beta", attributes: [Schema.Attribute(name: "label", type: "String")]),
            Schema.Entity(name: "ZRemoved", attributes: [Schema.Attribute(name: "label", type: "String")]),
        ])
        let destination = Schema([
            Schema.Entity(name: "Alpha", attributes: [Schema.Attribute(name: "label", type: "String")]),
            Schema.Entity(name: "Beta", attributes: [Schema.Attribute(name: "label", type: "String")]),
            Schema.Entity(name: "Newcomer", attributes: [Schema.Attribute(name: "label", type: "String")]),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        try initial.write { connection in
            try connection.execute("INSERT INTO ZALPHA (Z_ENT, Z_OPT, ZLABEL) VALUES (1, 2, 'alpha')")
            try connection.execute("INSERT INTO ZBETA (Z_ENT, Z_OPT, ZLABEL) VALUES (2, 3, 'beta')")
            try connection.execute("INSERT INTO ZZREMOVED (Z_ENT, Z_OPT, ZLABEL) VALUES (3, 4, 'removed')")
        }
        try initial.close()

        let migrated = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY ORDER BY Z_ENT") },
            [[.int(1), .text("Alpha")], [.int(2), .text("Beta")], [.int(4), .text("Newcomer")]])
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT, ZLABEL FROM ZALPHA") },
            [[.int(1), .int(1), .int(2), .text("alpha")]])
        XCTAssertEqual(
            try migrated.read { try $0.rows("SELECT Z_PK, Z_ENT, Z_OPT, ZLABEL FROM ZBETA") },
            [[.int(1), .int(2), .int(3), .text("beta")]])
        XCTAssertTrue(
            try migrated.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZZREMOVED'").isEmpty
            })
        XCTAssertEqual(try migrated.read { try LightweightMigration.storedNextEntityIdentifier(connection: $0) }, 5)
        try migrated.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        XCTAssertEqual(
            try reopened.read { try $0.rows("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY ORDER BY Z_ENT") },
            [[.int(1), .text("Alpha")], [.int(2), .text("Beta")], [.int(4), .text("Newcomer")]])
        try reopened.close()
    }

    func testMixedRootRemovalAndAdditionRejectsCollisionWithRetainedTable() throws {
        let source = Schema([
            Schema.Entity(name: "A"),
            Schema.Entity(name: "B"),
            Schema.Entity(name: "Removed"),
        ])
        let destination = Schema([Schema.Entity(name: "A"), Schema.Entity(name: "b")])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "mixed-root-retained-table-collision"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected collision with retained table to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read {
                try $0.rows(
                    "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('ZA', 'ZB', 'ZREMOVED') ORDER BY name"
                )
            },
            [[.text("ZA")], [.text("ZB")], [.text("ZREMOVED")]])
        try driver.close()
    }

    func testCombinedRootChangesRejectRelationshipReferencesAndObjectNameReuse() throws {
        let relationshipSource = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [Schema.Relationship(name: "target", destination: "RemovedTarget")]),
            Schema.Entity(name: "RemovedTarget"),
            Schema.Entity(name: "ZRemoved"),
        ])
        let relationshipDestination = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [Schema.Relationship(name: "target", destination: "RemovedTarget")]),
            Schema.Entity(name: "Newcomer"),
        ])

        let nameReuseSource = Schema([
            Schema.Entity(
                name: "A",
                attributes: [Schema.Attribute(name: "B_ZC", type: "Int")],
                indexes: [Schema.Index(properties: ["B_ZC"])]),
            Schema.Entity(name: "Keep"),
        ])
        let appendedEntityID = try XCTUnwrap(nameReuseSource.entityIDsByName.values.max()) + 1
        let nameReuseDestination = try Schema(
            [
                Schema.Entity(name: "Keep"),
                Schema.Entity(
                    name: "A_ZB",
                    attributes: [Schema.Attribute(name: "C", type: "Int")],
                    indexes: [Schema.Index(properties: ["C"])]),
            ],
            entityIDs: [
                "Keep": try XCTUnwrap(nameReuseSource.entityIDsByName["Keep"]),
                "A_ZB": appendedEntityID,
            ])
        let cases: [(String, Schema, Schema)] = [
            ("relationship", relationshipSource, relationshipDestination),
            ("index-object", nameReuseSource, nameReuseDestination),
        ]
        for (name, source, destination) in cases {
            let driver = try GRDBSQLiteDriver(location: .memory(name: "mixed-entity-change-reject-\(name)"))
            try bootstrap(source, driver: driver)
            XCTAssertThrowsError(
                try driver.write {
                    try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
                }
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected combined \(name) change to fail closed, got \(error)")
                }
            }
            let sourceEntityNames = source.entities.map { $0.name.uppercased() }
            let physicalTableNames = try driver.read {
                try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table'")
            }.compactMap { row -> String? in
                guard case let .text(tableName)? = row.first else { return nil }
                return tableName
            }
            for entityName in sourceEntityNames {
                XCTAssertTrue(physicalTableNames.contains("Z\(entityName)"))
            }
            XCTAssertTrue(
                try driver.read {
                    try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZNEWCOMER'").isEmpty
                })
            try driver.close()
        }
    }

    func testCombinedRootChangesRejectCaseInsensitiveTableNameReuse() throws {
        let source = Schema([Schema.Entity(name: "Foo"), Schema.Entity(name: "Keep")])
        let nextID = try XCTUnwrap(source.entityIDsByName.values.max()) + 1
        let destination = try Schema(
            [Schema.Entity(name: "Keep"), Schema.Entity(name: "foo")],
            entityIDs: [
                "Keep": try XCTUnwrap(source.entityIDsByName["Keep"]),
                "foo": nextID,
            ])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "mixed-entity-case-table-reuse"))
        try bootstrap(source, driver: driver)
        XCTAssertThrowsError(
            try driver.write {
                try LightweightMigration.migrate(source: source, destination: destination, connection: $0)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected case-insensitive object reuse to fail closed, got \(error)")
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZFOO'") },
            [[.text("ZFOO")]])
        try driver.close()
    }

    func testRenamedUniqueAttributeReconcilesGeneratedIndexName() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-rename-unique-index"))
        let source = Schema([
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "email", type: "String", options: [.unique])])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "address", type: "String", options: [.unique], originalName: "email")
                ])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZEMAIL) VALUES (1, 1, ?)", [.text("a")])
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        let indexes = try driver.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index'") }
        XCTAssertTrue(indexes.contains([.text("ZRECORD_ZADDRESS_UNIQUE_INDEX")]))
        XCTAssertFalse(indexes.contains([.text("ZRECORD_ZEMAIL_UNIQUE_INDEX")]))
        XCTAssertEqual(try driver.read { try $0.rows("SELECT ZADDRESS FROM ZRECORD") }, [[.text("a")]])
        try driver.close()
    }

    func testRenamedAndAddedToOneRelationshipsReconcileForeignKeyIndexesOnReopen() throws {
        let location = StoreLocation.memory(name: "migration-rename-relationship-index")
        let driver = try GRDBSQLiteDriver(location: location)
        let source = Schema([
            Schema.Entity(
                name: "Owner", relationships: [Schema.Relationship(name: "child", destination: "Child")]),
            Schema.Entity(name: "Child"),
            Schema.Entity(name: "Pet"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "offspring", destination: "Child", originalName: "child"),
                    Schema.Relationship(name: "pet", destination: "Pet"),
                ]),
            Schema.Entity(name: "Child"),
            Schema.Entity(name: "Pet"),
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZCHILD) VALUES (1, 1, NULL)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        let indexes = try driver.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index'") }
        XCTAssertTrue(indexes.contains([.text("ZOWNER_ZOFFSPRING_INDEX")]))
        XCTAssertTrue(indexes.contains([.text("ZOWNER_ZPET_INDEX")]))
        XCTAssertFalse(indexes.contains([.text("ZOWNER_ZCHILD_INDEX")]))
        XCTAssertTrue(
            try driver.read { try $0.rows("SELECT ZOFFSPRING, ZPET FROM ZOWNER") } == [[.null, .null]])
        try driver.close()

        let reopened = try GRDBSQLiteDriver(location: location)
        try reopened.write { try LightweightMigration.openOrMigrate(to: destination, connection: $0) }
        try reopened.close()
    }

    func testIndexMigrationDoesNotCreateForeignKeyIndexForNonOwningToOne() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-nonowner-fk-index"))
        let source = Schema([
            Schema.Entity(
                name: "Alpha",
                relationships: [Schema.Relationship(name: "beta", destination: "Beta", inverse: "alpha")]),
            Schema.Entity(
                name: "Beta",
                relationships: [Schema.Relationship(name: "alpha", destination: "Alpha", inverse: "beta")]),
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")]),
        ])
        let destination = Schema([
            source.entities[0],
            source.entities[1],
            Schema.Entity(
                name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")],
                indexes: [Schema.Index(properties: ["title"])]),
        ])
        try bootstrap(source, driver: driver)

        try driver.write { try LightweightMigration.migrate(source: source, destination: destination, connection: $0) }
        let indexes = try driver.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index'") }
        XCTAssertTrue(indexes.contains([.text("ZALPHA_ZBETA_INDEX")]))
        XCTAssertFalse(indexes.contains([.text("ZBETA_ZALPHA_INDEX")]))
        XCTAssertTrue(indexes.contains([.text("ZRECORD_ZTITLE_INDEX")]))
        try driver.close()
    }

    func testIndexRenameAcrossEntitiesDropsBeforeCreatingReusedName() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-global-index-transition"))
        let source = Schema([
            Schema.Entity(
                name: "A", attributes: [Schema.Attribute(name: "old", type: "String")],
                indexes: [Schema.Index(properties: ["old"])]),
            Schema.Entity(
                name: "B", attributes: [Schema.Attribute(name: "value", type: "String")],
                indexes: [Schema.Index(properties: ["value"])]),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "A",
                attributes: [Schema.Attribute(name: "value", type: "String", originalName: "old")],
                indexes: [Schema.Index(properties: ["value"])]),
            Schema.Entity(name: "B", attributes: [Schema.Attribute(name: "value", type: "String")]),
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZA (Z_ENT, Z_OPT, ZOLD) VALUES (1, 1, ?)", [.text("a")])
            try connection.execute("INSERT INTO ZB (Z_ENT, Z_OPT, ZVALUE) VALUES (2, 1, ?)", [.text("b")])
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        let indexes = try driver.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index'") }
        XCTAssertEqual(indexes.filter { $0.first == .text("ZA_ZVALUE_INDEX") }.count, 1)
        XCTAssertFalse(indexes.contains([.text("ZA_ZOLD_INDEX")]))
        XCTAssertFalse(indexes.contains([.text("ZB_ZVALUE_INDEX")]))
        try driver.close()
    }

    func testLightweightMigrationRenamesAttributeAndPreservesRows() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-rename"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "name", type: "String", originalName: "title")])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZTITLE) VALUES (1, 1, ?)", [.text("hello")])
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(try driver.read { try $0.rows("SELECT ZNAME FROM ZRECORD") }, [[.text("hello")]])
        try driver.close()
    }

    func testAttributeRenameRequiresOriginalNameMetadata() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-rename-explicit"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")])
        ])
        let inferredRename = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "name", type: "String")])
        ])
        try bootstrap(source, driver: driver)

        XCTAssertThrowsError(
            try driver.write { connection in
                try LightweightMigration.migrate(source: source, destination: inferredRename, connection: connection)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                XCTFail("Expected migrationUnsupported, got \(error)")
                return
            }
        }
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
        XCTAssertTrue(columns.contains { $0.count > 1 && $0[1] == .text("ZTITLE") })
        try driver.close()
    }

    func testAttributeRenamePreservesOtherAttributes() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-rename-other"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "String"),
                    Schema.Attribute(name: "second", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "second", type: "String"),
                    Schema.Attribute(name: "renamed", type: "String", originalName: "first"),
                ])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 1, ?, ?)",
                [.text("one"), .text("two")])
        }

        try driver.write { connection in
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        let rows = try driver.read { try $0.rows("SELECT ZSECOND, ZRENAMED FROM ZRECORD") }
        XCTAssertEqual(rows, [[.text("two"), .text("one")]])
        try driver.close()
    }

    func testExplicitOriginalNameClaimTakesPrecedenceOverSameNameDestination() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-explicit-claim-chain"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "String"),
                    Schema.Attribute(name: "second", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "second", type: "String", originalName: "first"),
                    Schema.Attribute(name: "final", type: "String", originalName: "second"),
                ])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 1, ?, ?)",
                [.text("one"), .text("two")])
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }

        let rows = try driver.read { try $0.rows("SELECT ZSECOND, ZFINAL FROM ZRECORD") }
        XCTAssertEqual(rows, [[.text("one"), .text("two")]])
        try driver.close()
    }

    func testPersistedOriginalNameFallsBackToCurrentNameWhenOldColumnIsGone() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-original-name-fallback"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "renamed", type: "String")
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "renamed", type: "String", originalName: "oldName")
                ])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZRENAMED) VALUES (1, 1, ?)", [.text("value")])
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        XCTAssertEqual(try driver.read { try $0.rows("SELECT ZRENAMED FROM ZRECORD") }, [[.text("value")]])
        try driver.close()
    }

    func testAttributeRenameChainPreservesSourceValues() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-rename-chain"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "String"),
                    Schema.Attribute(name: "second", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "second", type: "String", originalName: "first"),
                    Schema.Attribute(name: "final", type: "String", originalName: "second"),
                ])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 1, ?, ?)",
                [.text("one"), .text("two")])
        }

        try driver.write { connection in
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        let rows = try driver.read { try $0.rows("SELECT ZSECOND, ZFINAL FROM ZRECORD") }
        XCTAssertEqual(rows, [[.text("one"), .text("two")]])
        try driver.close()
    }

    func testDuplicateOriginalNameClaimsFailBeforeChangingRows() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-duplicate-claim"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "String"),
                    Schema.Attribute(name: "other", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "one", type: "String", originalName: "first"),
                    Schema.Attribute(name: "two", type: "String", originalName: "first"),
                ])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZOTHER) VALUES (1, 1, ?, ?)",
                [.text("one"), .text("other")])
        }

        XCTAssertThrowsError(
            try driver.write { connection in
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                XCTFail("Expected migrationUnsupported, got \(error)")
                return
            }
        }
        let rows = try driver.read { try $0.rows("SELECT ZFIRST, ZOTHER FROM ZRECORD") }
        XCTAssertEqual(rows, [[.text("one"), .text("other")]])
        try driver.close()
    }

    func testAttributeRenameSwapFailsBeforeChangingRows() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-rename-swap"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "String"),
                    Schema.Attribute(name: "second", type: "String"),
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "String", originalName: "second"),
                    Schema.Attribute(name: "second", type: "String", originalName: "first"),
                ])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute(
                "INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZFIRST, ZSECOND) VALUES (1, 1, ?, ?)",
                [.text("one"), .text("two")])
        }

        XCTAssertThrowsError(
            try driver.write { connection in
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            })
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT ZFIRST, ZSECOND FROM ZRECORD") },
            [[.text("one"), .text("two")]])
        try driver.close()
    }

    func testSQLiteCaseInsensitiveDestinationCollisionFails() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-case-fold-collision"))
        let source = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "first", type: "String")
                ])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "value", type: "String", originalName: "first"),
                    Schema.Attribute(name: "VALUE", type: "String", isOptional: true),
                ])
        ])
        try bootstrap(source, driver: driver)

        XCTAssertThrowsError(
            try driver.write { connection in
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            })
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
        XCTAssertTrue(columns.contains { $0.count > 1 && $0[1] == .text("ZFIRST") })
        try driver.close()
    }

    func testMigrationMetadataRoundTripsCanonicalSchema() throws {
        let schema = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(
                        name: "payload", type: "Payload", isOptional: true, defaultValue: "a|b\nc",
                        options: [.transformable(by: "Transform|er")], originalName: "oldPayload")
                ],
                relationships: [
                    Schema.Relationship(
                        name: "parent", destination: "Parent", isToMany: false, inverse: "children",
                        deleteRule: .nullify, minimumModelCount: 0, maximumModelCount: 1)
                ],
                indexes: [Schema.Index(properties: ["payload", "createdAt"], isUnique: true)]),
            Schema.Entity(name: "Parent"),
        ])

        let decoded = try SchemaHash.decodeCanonicalDescription(SchemaHash.canonicalDescription(of: schema))

        XCTAssertEqual(SchemaHash.digest(schema), SchemaHash.digest(decoded))
    }

    func testEntityIDMapCodecUsesDeterministicVersionedEncoding() throws {
        let schema = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
            Schema.Entity(name: "Zebra", superentityName: "Animal"),
        ])
        let first = try EntityIDMapCodec.encode(["Zebra": 3, "Animal": 1, "Dog": 2], for: schema)
        let second = try EntityIDMapCodec.encode(["Dog": 2, "Zebra": 3, "Animal": 1], for: schema)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            String(decoding: first, as: UTF8.self),
            "{\"entries\":[{\"identifier\":1,\"name\":\"Animal\"},{\"identifier\":2,\"name\":\"Dog\"},{\"identifier\":3,\"name\":\"Zebra\"}],\"format\":\"entity-id-map.v1\"}"
        )
    }

    func testEntityIDMapMetadataRoundTripsWithoutChangingSchemaHash() throws {
        let schema = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
            Schema.Entity(name: "Zebra", superentityName: "Animal"),
        ])
        let reconciled = try schema.reconciled(with: ["Animal": 4, "Dog": 7, "Zebra": 9])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "entity-id-map-roundtrip"))
        try driver.write { connection in
            try connection.execute("CREATE TABLE _osd_meta (key TEXT PRIMARY KEY, value BLOB);")
            XCTAssertNil(try LightweightMigration.storedEntityIDs(schema: schema, connection: connection))
            try LightweightMigration.writeEntityIDs(
                reconciled.entityIDsByName, schema: schema, connection: connection)
            XCTAssertEqual(
                try LightweightMigration.storedEntityIDs(schema: schema, connection: connection),
                reconciled.entityIDsByName)
        }

        XCTAssertEqual(SchemaHash.hexDigest(schema), SchemaHash.hexDigest(reconciled))
        XCTAssertEqual(SchemaHash.canonicalDescription(of: schema), SchemaHash.canonicalDescription(of: reconciled))
        try driver.close()
    }

    func testEntityIDMapMetadataRejectsInvalidStorageType() throws {
        let schema = Schema([Schema.Entity(name: "Record")])
        let driver = try GRDBSQLiteDriver(location: .memory(name: "entity-id-map-invalid-storage-type"))
        try driver.write { connection in
            try connection.execute("CREATE TABLE _osd_meta (key TEXT PRIMARY KEY, value BLOB);")
            try connection.execute(
                "INSERT INTO _osd_meta (key, value) VALUES (?, ?)",
                [.text(LightweightMigration.entityIDsKey), .text("not a blob")])
            XCTAssertThrowsError(
                try LightweightMigration.storedEntityIDs(schema: schema, connection: connection)
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected migrationUnsupported, got \(error)")
                }
            }
        }
        try driver.close()
    }

    func testOpeningStoreWritesEntityIDMapAndBackfillsLegacyMetadata() throws {
        let location = StoreLocation.memory(name: "entity-id-map-open-backfill")
        let schema = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: schema)
        let initialIDs = try initial.read {
            try LightweightMigration.storedEntityIDs(schema: schema, connection: $0)
        }
        XCTAssertEqual(initialIDs, schema.entityIDsByName)
        try initial.write {
            try $0.execute("DELETE FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.entityIDsKey)])
        }
        try initial.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: schema)
        let backfilledIDs = try reopened.read {
            try LightweightMigration.storedEntityIDs(schema: schema, connection: $0)
        }
        XCTAssertEqual(backfilledIDs, schema.entityIDsByName)
        let hashValue = try reopened.read {
            try $0.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(LightweightMigration.schemaHashKey)]
            ).first?.first
        }
        guard case let .blob(hashBytes)? = hashValue else {
            return XCTFail("Expected the canonical schema hash to remain stored as a blob")
        }
        XCTAssertEqual(String(decoding: hashBytes, as: UTF8.self), SchemaHash.hexDigest(schema))
        try reopened.close()
    }

    func testOpeningStoreRejectsEntityIDMapThatDiffersFromRuntimeSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let schema = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
        ])
        let driver = try LightweightMigration.openStore(location: location, schema: schema)
        let incompatibleIDs = ["Animal": 2, "Dog": 1]
        try driver.write { connection in
            try LightweightMigration.writeEntityIDs(incompatibleIDs, schema: schema, connection: connection)
        }
        XCTAssertEqual(
            try driver.read { try LightweightMigration.storedEntityIDs(schema: schema, connection: $0) },
            incompatibleIDs)
        try driver.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: schema)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
    }

    func testOpeningStoreFailsClosedWhenAddingNewRootWithRequiredRelationship() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
            Schema.Entity(
                name: "Vehicle",
                relationships: [Schema.Relationship(name: "owner", destination: "Animal", isOptional: false)]),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let originalIDs = try initial.read {
            try LightweightMigration.storedEntityIDs(schema: source, connection: $0)
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try LightweightMigration.storedEntityIDs(schema: source, connection: $0) },
            originalIDs)
        try reopened.close()
    }

    func testOpeningStoreFailsClosedWhenNewRootAddsConstrainedToManyRelationship() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
            Schema.Entity(name: "Target"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
            Schema.Entity(name: "Target"),
            Schema.Entity(
                name: "Vehicle",
                relationships: [
                    Schema.Relationship(
                        name: "targets", destination: "Target", isToMany: true, maximumModelCount: 1)
                ]),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let originalIDs = try initial.read {
            try LightweightMigration.storedEntityIDs(schema: source, connection: $0)
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try LightweightMigration.storedEntityIDs(schema: source, connection: $0) },
            originalIDs)
        try reopened.close()
    }

    func testOpeningStoreFailsClosedWhenNewRootRelationshipTargetsNewEntity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
            Schema.Entity(
                name: "Aardvark",
                relationships: [
                    Schema.Relationship(name: "target", destination: "Target", isOptional: true)
                ]),
            Schema.Entity(name: "Target"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let sourceIDs = try initial.read {
            try LightweightMigration.storedEntityIDs(schema: source, connection: $0)
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try LightweightMigration.storedEntityIDs(schema: source, connection: $0) },
            sourceIDs)
        try reopened.close()
    }

    func testOpeningStoreFailsClosedWhenAddingIntermediateUnderExistingRoot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
        ])
        let destination = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
            Schema.Entity(name: "Mammal", superentityName: "Animal"),
            Schema.Entity(name: "Cat", superentityName: "Mammal"),
        ])
        let initial = try LightweightMigration.openStore(location: location, schema: source)
        let sourceIDs = try initial.read {
            try LightweightMigration.storedEntityIDs(schema: source, connection: $0)
        }
        try initial.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: destination)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        let reopened = try LightweightMigration.openStore(location: location, schema: source)
        XCTAssertEqual(
            try reopened.read { try LightweightMigration.storedEntityIDs(schema: source, connection: $0) },
            sourceIDs)
        try reopened.close()
    }

    func testEntityIDMapCodecRejectsMalformedOrIncompatibleMaps() throws {
        let schema = Schema([
            Schema.Entity(name: "Animal"),
            Schema.Entity(name: "Dog", superentityName: "Animal"),
        ])
        let invalidDocuments = [
            "{\"entries\":[],\"format\":\"entity-id-map.v2\"}",
            "{\"entries\":[{\"identifier\":1,\"name\":\"Animal\"},{\"identifier\":1,\"name\":\"Dog\"}],\"format\":\"entity-id-map.v1\"}",
            "{\"entries\":[{\"identifier\":1,\"name\":\"Animal\"},{\"identifier\":2,\"name\":\"Other\"}],\"format\":\"entity-id-map.v1\"}",
        ]

        for document in invalidDocuments {
            XCTAssertThrowsError(
                try EntityIDMapCodec.decode(Array(document.utf8), for: schema)
            ) { error in
                guard case SwiftDataError.migrationUnsupported = error else {
                    return XCTFail("Expected migrationUnsupported, got \(error)")
                }
            }
        }
        XCTAssertThrowsError(try EntityIDMapCodec.encode(["Animal": 1, "Dog": 1], for: schema))
    }

    func testOpeningExistingStoreAutomaticallyMigratesFromPersistedSchemaDefinition() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String"),
                    Schema.Attribute(name: "notes", type: "String", isOptional: true),
                ])
        ])
        let first = try LightweightMigration.openStore(location: location, schema: source)
        try first.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZTITLE) VALUES (1, 1, ?)", [.text("kept")])
        }
        try first.close()

        let reopened = try LightweightMigration.openStore(location: location, schema: destination)
        let rows = try reopened.read { try $0.rows("SELECT ZTITLE, ZNOTES FROM ZRECORD") }
        XCTAssertEqual(rows, [[.text("kept"), .null]])
        let storedHash = try reopened.read {
            try $0.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text("schema.hash.v1")])
        }
        XCTAssertEqual(storedHash.first?.first, .blob(Array(SchemaHash.hexDigest(destination).utf8)))
        try reopened.close()
    }

    func testOpeningStoreWithInconsistentSchemaMetadataFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let schema = Schema([Schema.Entity(name: "Record")])
        let driver = try LightweightMigration.openStore(location: location, schema: schema)
        try driver.write { connection in
            try connection.execute(
                "UPDATE _osd_meta SET value = ? WHERE key = ?",
                [.blob(Array("broken".utf8)), .text("schema.definition.v1")])
        }
        try driver.close()

        XCTAssertThrowsError(
            try LightweightMigration.openStore(location: location, schema: Schema([Schema.Entity(name: "Other")]))
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                XCTFail("Expected migrationUnsupported, got \(error)")
                return
            }
        }
    }

    func testOpeningStoreDetectsPhysicalSchemaDriftDespiteMatchingMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let schema = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")])
        ])
        let driver = try LightweightMigration.openStore(location: location, schema: schema)
        try driver.write { connection in
            try connection.execute("ALTER TABLE ZRECORD DROP COLUMN ZTITLE")
        }
        try driver.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: schema)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                XCTFail("Expected migrationUnsupported, got \(error)")
                return
            }
        }
    }

    func testOpeningStoreDetectsDroppedIndexDespiteMatchingMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation.file(directory.appendingPathComponent("store.sqlite"))
        let schema = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [Schema.Attribute(name: "email", type: "String", options: [.unique])])
        ])
        let driver = try LightweightMigration.openStore(location: location, schema: schema)
        try driver.write { try $0.execute("DROP INDEX ZRECORD_ZEMAIL_UNIQUE_INDEX") }
        try driver.close()

        XCTAssertThrowsError(try LightweightMigration.openStore(location: location, schema: schema)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                XCTFail("Expected migrationUnsupported, got \(error)")
                return
            }
        }
    }

    func testOpeningUntrackedPartialStoreFailsWithoutOverwritingTables() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-partial-existing"))
        try driver.write { try $0.execute("CREATE TABLE ZOLD (Z_PK INTEGER PRIMARY KEY)") }
        XCTAssertThrowsError(
            try driver.write { connection in
                try LightweightMigration.openOrMigrate(
                    to: Schema([Schema.Entity(name: "Record")]), connection: connection)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                XCTFail("Expected migrationUnsupported, got \(error)")
                return
            }
        }
        XCTAssertEqual(
            try driver.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table'") },
            [[.text("ZOLD")]])
        try driver.close()
    }

    func testCardinalityChangeFailsAndPreservesStore() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-cardinality"))
        let source = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [Schema.Relationship(name: "child", destination: "Child", isToMany: false)]),
            Schema.Entity(name: "Child"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [Schema.Relationship(name: "child", destination: "Child", isToMany: true)]),
            Schema.Entity(name: "Child"),
        ])
        try bootstrap(source, driver: driver)

        XCTAssertThrowsError(
            try driver.write { connection in
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            }
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                XCTFail("Expected migrationUnsupported, got \(error)")
                return
            }
        }
        let tables = try driver.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        XCTAssertTrue(tables.contains([.text("ZOWNER")]))
        try driver.close()
    }

    func testFailedMigrationRollsBackSchemaAndRows() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-rollback"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")])
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Record",
                attributes: [
                    Schema.Attribute(name: "title", type: "String"),
                    Schema.Attribute(name: "requiredValue", type: "Int"),
                ])
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZRECORD (Z_ENT, Z_OPT, ZTITLE) VALUES (1, 1, ?)", [.text("kept")])
        }
        XCTAssertThrowsError(
            try driver.write { connection in
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            })

        let rows = try driver.read { try $0.rows("SELECT ZTITLE FROM ZRECORD") }
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
        XCTAssertEqual(rows, [[.text("kept")]])
        XCTAssertFalse(columns.contains { $0.count > 1 && $0[1] == .text("ZREQUIREDVALUE") })
        try driver.close()
    }

    func testIncompatibleTypeChangeFailsWithoutChangingSchema() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "migration-invalid-type"))
        let source = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "String")])
        ])
        let destination = Schema([
            Schema.Entity(name: "Record", attributes: [Schema.Attribute(name: "title", type: "Int")])
        ])
        try bootstrap(source, driver: driver)

        XCTAssertThrowsError(
            try driver.write { connection in
                try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
            })
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
        XCTAssertTrue(columns.contains { $0.count > 1 && $0[1] == .text("ZTITLE") })
        try driver.close()
    }

    private func bootstrap(_ schema: Schema, driver: GRDBSQLiteDriver) throws {
        let built = try SchemaBuilder.build(schema)
        try driver.write { connection in
            for statement in built.statements { try connection.execute(statement) }
            for row in built.bootstrapRows {
                try connection.execute(
                    "INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME, Z_SUPER, Z_MAX) VALUES (?, ?, ?, ?)",
                    [.int(row.entityID), .text(row.name), .int(row.superEntityID), .int(row.maximumPrimaryKey)])
            }
        }
    }
}
