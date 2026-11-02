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

    func testSignedIntegerNarrowingFailsWithoutChangingStore() throws {
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
            [[.int(2_147_483_648)]])
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
