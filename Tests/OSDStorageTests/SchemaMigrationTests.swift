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
                attributes: [Schema.Attribute(name: "code", type: "String")],
                indexes: [Schema.Index(properties: ["code"], isUnique: true)],
                superentityName: "Base"),
        ])

        XCTAssertNotEqual(SchemaHash.digest(withoutIndex), SchemaHash.digest(withIndex))
        let decoded = try SchemaHash.decodeCanonicalDescription(SchemaHash.canonicalDescription(of: withIndex))
        XCTAssertEqual(decoded.entities, withIndex.entities)
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

    func testRenamedToOneRelationshipReconcilesForeignKeyIndexOnReopen() throws {
        let location = StoreLocation.memory(name: "migration-rename-relationship-index")
        let driver = try GRDBSQLiteDriver(location: location)
        let source = Schema([
            Schema.Entity(
                name: "Owner", relationships: [Schema.Relationship(name: "child", destination: "Child")]),
            Schema.Entity(name: "Child"),
        ])
        let destination = Schema([
            Schema.Entity(
                name: "Owner",
                relationships: [
                    Schema.Relationship(name: "offspring", destination: "Child", originalName: "child")
                ]),
            Schema.Entity(name: "Child"),
        ])
        try bootstrap(source, driver: driver)
        try driver.write { connection in
            try connection.execute("INSERT INTO ZOWNER (Z_ENT, Z_OPT, ZCHILD) VALUES (1, 1, NULL)")
            try LightweightMigration.migrate(source: source, destination: destination, connection: connection)
        }
        let indexes = try driver.read { try $0.rows("SELECT name FROM sqlite_master WHERE type = 'index'") }
        XCTAssertTrue(indexes.contains([.text("ZOWNER_ZOFFSPRING_INDEX")]))
        XCTAssertFalse(indexes.contains([.text("ZOWNER_ZCHILD_INDEX")]))
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
