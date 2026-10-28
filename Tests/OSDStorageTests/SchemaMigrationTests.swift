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

    func testAddingDefaultedRequiredAttributeFailsBeforeChangingTable() throws {
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
                ])
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
        let columns = try driver.read { try $0.rows("PRAGMA table_info(ZRECORD)") }
        XCTAssertFalse(columns.contains { $0.count > 1 && $0[1] == .text("ZPRIORITY") })
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
