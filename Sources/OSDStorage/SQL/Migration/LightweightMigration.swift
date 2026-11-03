import Foundation
import GRDB
import OSDCore

package enum LightweightMigration {
    package static let schemaHashKey = "schema.hash.v1"
    package static let schemaDescriptionKey = "schema.definition.v1"
    package static let schemaVersionKey = "schema.version.v1"
    package static let entityIDsKey = "schema.entity-ids.v1"
    package static let entityIDHighWatermarkKey = "schema.entity-id-next.v1"
    package static let pendingMigrationKey = "schema.migration.pending.v1"

    package static func storedEntityIDs(schema: Schema, connection: SQLConnection) throws -> [String: Int]? {
        guard
            let row = try connection.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(entityIDsKey)]
            ).first
        else { return nil }
        guard case let .blob(bytes)? = row.first else {
            throw SwiftDataError.migrationUnsupported("Stored entity identifier map has an invalid storage type.")
        }
        return try EntityIDMapCodec.decode(bytes, for: schema)
    }

    package static func writeEntityIDs(
        _ identifiers: [String: Int], schema: Schema, connection: SQLConnection
    ) throws {
        try connection.execute(
            "INSERT INTO _osd_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(entityIDsKey), .blob(try EntityIDMapCodec.encode(identifiers, for: schema))])
    }

    package static func storedNextEntityIdentifier(connection: SQLConnection) throws -> Int? {
        guard
            let row = try connection.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(entityIDHighWatermarkKey)]
            ).first
        else { return nil }
        guard case let .blob(bytes)? = row.first,
            let text = String(bytes: bytes, encoding: .utf8),
            let value = Int(text), value > 0, String(value) == text
        else {
            throw SwiftDataError.migrationUnsupported("Stored next entity identifier is invalid.")
        }
        return value
    }

    package static func storedSchemaVersion(connection: SQLConnection) throws -> RuntimeSchemaVersionState {
        let metadataTable = try connection.rows(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '_osd_meta'")
        guard !metadataTable.isEmpty else { return .empty }
        if let row = try connection.rows(
            "SELECT value FROM _osd_meta WHERE key = ?", [.text(pendingMigrationKey)]
        ).first,
            case let .blob(bytes)? = row.first,
            let identifier = String(bytes: bytes, encoding: .utf8)
        {
            return .pending(destinationIdentifier: identifier)
        }
        guard try storedHash(connection) != nil else {
            let userTables = try connection.rows(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != '_osd_meta'"
            )
            return userTables.isEmpty ? .empty : .unversioned
        }
        guard
            let row = try connection.rows("SELECT value FROM _osd_meta WHERE key = ?", [.text(schemaVersionKey)]).first,
            case let .blob(bytes)? = row.first,
            let identifier = String(bytes: bytes, encoding: .utf8)
        else { return .unversioned }
        return .version(try Schema.Version.decode(identifier))
    }

    package static func setPendingMigration(_ identifier: String?, connection: SQLConnection) throws {
        guard let identifier else {
            try connection.execute("DELETE FROM _osd_meta WHERE key = ?", [.text(pendingMigrationKey)])
            return
        }
        try connection.execute(
            "INSERT INTO _osd_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(pendingMigrationKey), .blob(Array(identifier.utf8))])
    }

    private struct AttributeMapping {
        let source: Schema.Attribute?
        let destination: Schema.Attribute
    }

    private struct OwnerOnlyToManyRemovalPlan {
        let joinTable: String
    }

    private struct OwnerOnlyToManyRemovalBatchPlan {
        let removedRelationshipNamesByOwner: [String: Set<String>]
        let joinTables: [String]
        let addedAttributesByOwner: [String: [Schema.Attribute]]
    }

    private struct PairedInverseRelationshipRemoval {
        let ownerEntityName: String
        let ownerRelationshipName: String
        let inverseEntityName: String
        let inverseRelationshipName: String
        let column: String
        let indexName: String
    }

    package static func openOrMigrate(
        to destination: Schema,
        connection: SQLConnection
    ) throws {
        try ensureMetadataTable(connection)
        guard let stored = try storedHash(connection) else {
            try ensureStoreIsEmpty(connection)
            try initialize(destination, connection: connection)
            return
        }
        let persistedSource = try storedSchemaDescription(connection)
        guard let persistedSource else {
            throw SwiftDataError.migrationUnsupported("The stored schema description is missing.")
        }
        guard SchemaHash.hexDigest(persistedSource) == stored else {
            throw SwiftDataError.migrationUnsupported("The stored schema hash and description disagree.")
        }
        let destinationHash = SchemaHash.hexDigest(destination)
        let sourceHash = SchemaHash.hexDigest(persistedSource)
        guard stored == sourceHash else {
            throw SwiftDataError.migrationUnsupported("The stored schema hash does not match the source schema.")
        }
        let sourceEntityIDs = try storedEntityIDs(schema: persistedSource, connection: connection)
        let resolvedSourceEntityIDs = sourceEntityIDs ?? persistedSource.entityIDsByName
        let sourceSchema = try persistedSource.reconciled(with: resolvedSourceEntityIDs)
        try validatePhysicalSchema(sourceSchema, connection: connection)
        let physicalMaximumEntityID = try connection.rows("SELECT MAX(Z_ENT) FROM Z_PRIMARYKEY")
            .first?.first
        let physicalNextEntityID: Int
        if case let .int(maximumEntityID)? = physicalMaximumEntityID {
            guard let maximum = Int(exactly: maximumEntityID) else {
                throw SwiftDataError.migrationUnsupported("Physical entity identifier exceeds the supported range.")
            }
            let (next, overflow) = maximum.addingReportingOverflow(1)
            guard !overflow else {
                throw SwiftDataError.migrationUnsupported(
                    "Physical entity identifiers leave no appendable identifier space.")
            }
            physicalNextEntityID = next
        } else {
            physicalNextEntityID = 1
        }
        let minimumNextEntityID = max(
            try nextEntityIdentifier(after: resolvedSourceEntityIDs.values),
            max(try storedNextEntityIdentifier(connection: connection) ?? 1, physicalNextEntityID))
        let destinationEntityNames = Set(destination.entities.map(\.name))
        let retainedEntityIDs = resolvedSourceEntityIDs.filter { destinationEntityNames.contains($0.key) }
        let reconciledDestination = try destination.reconciled(
            with: retainedEntityIDs, minimumNextIdentifier: minimumNextEntityID)
        if stored == destinationHash {
            if sourceEntityIDs == nil {
                try connection.execute("SAVEPOINT osd_schema_metadata_backfill")
                do {
                    try writeSchemaMetadata(
                        reconciledDestination, minimumNextEntityID: minimumNextEntityID, connection: connection)
                    try connection.execute("RELEASE SAVEPOINT osd_schema_metadata_backfill")
                } catch {
                    try? connection.execute("ROLLBACK TO SAVEPOINT osd_schema_metadata_backfill")
                    try? connection.execute("RELEASE SAVEPOINT osd_schema_metadata_backfill")
                    throw error
                }
            } else {
                try writeSchemaVersion(destination.version, connection: connection)
                try writeEntityIDHighWatermark(
                    max(
                        minimumNextEntityID,
                        try nextEntityIdentifier(after: reconciledDestination.entityIDsByName.values)),
                    connection: connection)
            }
            return
        }
        try connection.execute("SAVEPOINT osd_schema_migration")
        do {
            try migrate(source: sourceSchema, destination: reconciledDestination, connection: connection)
            try writeSchemaMetadata(
                reconciledDestination, minimumNextEntityID: minimumNextEntityID, connection: connection)
            try connection.execute("RELEASE SAVEPOINT osd_schema_migration")
        } catch {
            try? connection.execute("ROLLBACK TO SAVEPOINT osd_schema_migration")
            try? connection.execute("RELEASE SAVEPOINT osd_schema_migration")
            throw error
        }
    }

    package static func openStore(
        location: StoreLocation,
        schema: Schema,
        externalColumns: Set<String> = [],
        externalStorageOperations: ExternalStorageFileOperations = .live
    ) throws -> GRDBSQLiteDriver {
        let driver = try GRDBSQLiteDriver(
            location: location, externalColumns: externalColumns,
            externalStorageOperations: externalStorageOperations)
        do {
            try driver.write { connection in
                try connection.execute("SAVEPOINT osd_schema_open")
                do {
                    try openOrMigrate(to: schema, connection: connection)
                    try createHistoryTables(connection)
                    try connection.execute("RELEASE SAVEPOINT osd_schema_open")
                } catch {
                    try? connection.execute("ROLLBACK TO SAVEPOINT osd_schema_open")
                    try? connection.execute("RELEASE SAVEPOINT osd_schema_open")
                    throw error
                }
            }
            try driver.write { connection in
                connection.afterCommit { connection in
                    do {
                        try connection.reconcileExternalFiles()
                    } catch {
                        OSDLog.debug("External Data orphan cleanup failed: \(error)")
                    }
                }
            }
            return driver
        } catch {
            try? driver.close()
            throw error
        }
    }

    private static func createHistoryTables(_ connection: SQLConnection) throws {
        try connection.execute(
            "CREATE TABLE IF NOT EXISTS _osd_history_transactions "
                + "(id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp REAL NOT NULL, author TEXT)")
        try connection.execute(
            "CREATE TABLE IF NOT EXISTS _osd_history_changes "
                + "(transaction_id INTEGER NOT NULL, ordinal INTEGER NOT NULL, type TEXT NOT NULL, "
                + "entity TEXT NOT NULL, primary_key INTEGER NOT NULL, PRIMARY KEY(transaction_id, ordinal))")
        try connection.execute(
            "CREATE INDEX IF NOT EXISTS _osd_history_changes_transaction "
                + "ON _osd_history_changes (transaction_id)")
    }

    package static func migrate(
        source: Schema,
        destination: Schema,
        connection: SQLConnection
    ) throws {
        try validateCardinality(source: source, destination: destination)
        try connection.execute("SAVEPOINT osd_lightweight_migration")
        do {
            try apply(source: source, destination: destination, connection: connection)
            try connection.execute("RELEASE SAVEPOINT osd_lightweight_migration")
        } catch {
            try? connection.execute("ROLLBACK TO SAVEPOINT osd_lightweight_migration")
            try? connection.execute("RELEASE SAVEPOINT osd_lightweight_migration")
            throw error
        }
    }

    private static func ensureMetadataTable(_ connection: SQLConnection) throws {
        try connection.execute("CREATE TABLE IF NOT EXISTS _osd_meta (key TEXT PRIMARY KEY, value BLOB);")
    }

    private static func ensureStoreIsEmpty(_ connection: SQLConnection) throws {
        let rows = try connection.rows(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != '_osd_meta'")
        guard rows.isEmpty else {
            throw SwiftDataError.migrationUnsupported("Existing store tables have no OpenSwiftData schema metadata.")
        }
    }

    private static func validatePhysicalSchema(_ schema: Schema, connection: SQLConnection) throws {
        let entityRows = try connection.rows("SELECT Z_ENT, Z_NAME, Z_SUPER FROM Z_PRIMARYKEY")
        guard entityRows.count == schema.entities.count else {
            throw SwiftDataError.migrationUnsupported("Physical entity metadata does not match the stored schema.")
        }
        var validatedEntities = Set<String>()
        for row in entityRows {
            guard row.count >= 3,
                case let .int(rawEntityID) = row[0],
                let entityID = Int(exactly: rawEntityID),
                case let .text(entityName) = row[1],
                case let .int(rawSuperEntityID) = row[2],
                let entity = schema.entity(forName: entityName),
                validatedEntities.insert(entityName).inserted,
                schema.entityIDsByName[entityName] == entityID
            else {
                throw SwiftDataError.migrationUnsupported("Physical entity metadata contains an invalid row.")
            }
            let expectedSuperEntityID = entity.superentityName.flatMap { schema.entityIDsByName[$0] } ?? 0
            guard rawSuperEntityID == Int64(expectedSuperEntityID) else {
                throw SwiftDataError.migrationUnsupported(
                    "Physical parent identifier does not match the schema for \(entityName).")
            }
        }
        let entitiesByName = Dictionary(uniqueKeysWithValues: schema.entities.map { ($0.name, $0) })
        func rootName(for entity: Schema.Entity) throws -> String {
            var current = entity
            var visited = Set<String>()
            while let parentName = current.superentityName {
                guard visited.insert(current.name).inserted,
                    let parent = entitiesByName[parentName]
                else {
                    throw SwiftDataError.migrationUnsupported(
                        "Physical schema has invalid inheritance for \(entity.name).")
                }
                current = parent
            }
            return current.name
        }
        let roots = schema.entities.filter { $0.superentityName == nil }
        for root in roots {
            let members = try schema.entities.filter { try rootName(for: $0) == root.name }
            let table = "Z\(root.name.uppercased())"
            let columns = try tableColumns(table, connection: connection)
            guard columns.contains("Z_PK"), columns.contains("Z_ENT"), columns.contains("Z_OPT") else {
                throw SwiftDataError.migrationUnsupported(
                    "Physical root table is missing required columns for \(root.name).")
            }
            for entity in members {
                for attribute in entity.attributes {
                    let expectedColumns =
                        attribute.options.contains(.flattened)
                        ? attribute.components.map(\.columnName) : [attribute.name]
                    for column in expectedColumns where !columns.contains("Z\(column.uppercased())") {
                        throw SwiftDataError.migrationUnsupported(
                            "Physical root table is missing attribute column \(entity.name).\(column).")
                    }
                }
                for relationship in entity.relationships where !relationship.isToMany {
                    guard !SchemaBuilder.isNonOwner(entity, relationship, schema: schema),
                        let mapping = schema.relationshipStorageMapping(
                            modelEntityName: entity.name, relationshipName: relationship.name),
                        columns.contains("Z\(mapping.storageColumnName.uppercased())")
                    else {
                        if SchemaBuilder.isNonOwner(entity, relationship, schema: schema) { continue }
                        throw SwiftDataError.migrationUnsupported(
                            "Physical root table is missing relationship column \(entity.name).\(relationship.name).")
                    }
                }
            }
        }
        if !roots.isEmpty {
            for entity in schema.entities where entity.superentityName != nil {
                let table = "Z\(entity.name.uppercased())"
                guard try tableColumns(table, connection: connection).isEmpty else {
                    throw SwiftDataError.migrationUnsupported(
                        "Physical hierarchy contains an unexpected per-entity table \(table).")
                }
            }
        }
        let actualIndexes = Set(
            try connection.rows(
                "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'Z%'"
            ).compactMap { row -> String? in
                guard case let .text(name)? = row.first else { return nil }
                return name.uppercased()
            })
        let expected = try expectedIndexNames(schema)
        guard expected == actualIndexes else {
            throw SwiftDataError.migrationUnsupported("Physical indexes do not match stored schema metadata.")
        }
    }

    private static func expectedIndexNames(_ schema: Schema) throws -> Set<String> {
        let indexStatements = try SchemaBuilder.build(schema).statements.filter {
            $0.hasPrefix("CREATE INDEX") || $0.hasPrefix("CREATE UNIQUE INDEX")
        }
        return Set(
            indexStatements.compactMap { statement in
                let tokens = statement.split(separator: " ")
                guard let index = tokens.firstIndex(of: "INDEX"), tokens.indices.contains(index + 1) else {
                    return nil
                }
                return String(tokens[index + 1]).uppercased()
            })
    }

    private struct HierarchyIndexPlan {
        let source: [String: String]
        let destination: [String: String]
        let destinationDefinitions: [String: IndexDefinition]
    }

    private static func planHierarchyIndexes(
        sourceStatements: [String],
        destinationStatements: [String],
        connection: SQLConnection
    ) throws -> HierarchyIndexPlan {
        let sourceIndexes = try indexStatementsByName(sourceStatements)
        let destinationIndexes = try indexStatementsByName(destinationStatements)
        let destinationDefinitions = try indexDefinitions(from: destinationIndexes)
        guard Set(sourceIndexes.keys).isSubset(of: Set(destinationIndexes.keys)) else {
            throw SwiftDataError.migrationUnsupported("Hierarchy migration cannot remove existing indexes.")
        }
        for name in destinationIndexes.keys {
            let physicalObjects = try connection.rows(
                "SELECT type, sql FROM sqlite_master WHERE name = ? COLLATE NOCASE",
                [.text(name)])
            guard let object = physicalObjects.first else { continue }
            let allowedSourceIndex: Bool
            if physicalObjects.count == 1,
                let oldStatement = sourceIndexes[name],
                object.count > 1,
                case .text("index") = object[0],
                case let .text(actualSQL) = object[1]
            {
                allowedSourceIndex = normalizedIndexSQL(actualSQL) == normalizedIndexSQL(oldStatement)
            } else {
                allowedSourceIndex = false
            }
            guard allowedSourceIndex else {
                throw SwiftDataError.migrationUnsupported(
                    "Hierarchy index \(name) collides with an existing physical object.")
            }
        }
        return HierarchyIndexPlan(
            source: sourceIndexes, destination: destinationIndexes, destinationDefinitions: destinationDefinitions)
    }

    private static func indexStatementsByName(_ statements: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for statement in statements
        where statement.hasPrefix("CREATE INDEX") || statement.hasPrefix("CREATE UNIQUE INDEX") {
            let tokens = statement.split(whereSeparator: \.isWhitespace)
            guard let indexPosition = tokens.firstIndex(of: "INDEX"), tokens.indices.contains(indexPosition + 1)
            else {
                throw SwiftDataError.migrationUnsupported("Unable to parse a generated index statement.")
            }
            let name = String(tokens[indexPosition + 1])
            guard result.updateValue(statement, forKey: name.uppercased()) == nil else {
                throw SwiftDataError.migrationUnsupported("Generated index names are not unique.")
            }
        }
        return result
    }

    private static func indexDefinitions(from statements: [String: String]) throws -> [String: IndexDefinition] {
        var definitions: [String: IndexDefinition] = [:]
        for (name, statement) in statements {
            guard let table = expectedIndexTable(in: statement),
                let columns = indexColumns(in: statement),
                !columns.isEmpty
            else {
                throw SwiftDataError.migrationUnsupported("Unable to parse generated hierarchy index keys.")
            }
            definitions[name] = IndexDefinition(name: name, statement: statement, table: table, columns: columns)
        }
        return definitions
    }

    private static func reconcileHierarchyIndexes(
        _ plan: HierarchyIndexPlan,
        connection: SQLConnection
    ) throws {
        for name in plan.destination.keys.sorted() {
            guard let statement = plan.destination[name] else { continue }
            if plan.source[name] == statement { continue }
            if plan.source[name] != nil {
                try connection.execute("DROP INDEX \(name)")
            }
            try connection.execute(statement)
            guard let definition = plan.destinationDefinitions[name] else {
                throw SwiftDataError.migrationUnsupported("Hierarchy index definition is missing.")
            }
            try validatePhysicalIndexMetadata(
                definition,
                connection: connection,
                expectedPartial: statement.range(of: " WHERE ") != nil)
        }
    }

    private static func initialize(_ schema: Schema, connection: SQLConnection) throws {
        let built = try SchemaBuilder.build(schema)
        try connection.execute("SAVEPOINT osd_schema_initialization")
        do {
            for statement in built.statements {
                if statement.hasPrefix("CREATE TABLE _osd_meta") { continue }
                try connection.execute(statement)
            }
            for row in built.bootstrapRows {
                try connection.execute(
                    "INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME, Z_SUPER, Z_MAX) VALUES (?, ?, ?, ?)",
                    [.int(row.entityID), .text(row.name), .int(row.superEntityID), .int(row.maximumPrimaryKey)])
            }
            try ensureMetadataTable(connection)
            try writeSchemaMetadata(schema, connection: connection)
            try connection.execute("RELEASE SAVEPOINT osd_schema_initialization")
        } catch {
            try? connection.execute("ROLLBACK TO SAVEPOINT osd_schema_initialization")
            try? connection.execute("RELEASE SAVEPOINT osd_schema_initialization")
            throw error
        }
    }

    private static func storedHash(_ connection: SQLConnection) throws -> String? {
        guard
            let row = try connection.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(schemaHashKey)]
            ).first,
            case let .blob(bytes)? = row.first
        else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func writeHash(_ value: String, connection: SQLConnection) throws {
        try connection.execute(
            "INSERT INTO _osd_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(schemaHashKey), .blob(Array(value.utf8))])
    }

    private static func storedSchemaDescription(_ connection: SQLConnection) throws -> Schema? {
        guard
            let row = try connection.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", [.text(schemaDescriptionKey)]
            ).first,
            case let .blob(bytes)? = row.first,
            let description = String(bytes: bytes, encoding: .utf8)
        else { return nil }
        return try SchemaHash.decodeCanonicalDescription(description)
    }

    private static func writeSchemaMetadata(
        _ schema: Schema,
        minimumNextEntityID: Int? = nil,
        connection: SQLConnection
    ) throws {
        try writeHash(SchemaHash.hexDigest(schema), connection: connection)
        try connection.execute(
            "INSERT INTO _osd_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(schemaDescriptionKey), .blob(Array(SchemaHash.canonicalDescription(of: schema).utf8))])
        try writeEntityIDs(schema.entityIDsByName, schema: schema, connection: connection)
        try writeEntityIDHighWatermark(
            max(minimumNextEntityID ?? 1, try nextEntityIdentifier(after: schema.entityIDsByName.values)),
            connection: connection)
        try writeSchemaVersion(schema.version, connection: connection)
    }

    private static func writeEntityIDHighWatermark(_ nextIdentifier: Int, connection: SQLConnection) throws {
        guard nextIdentifier > 0 else {
            throw SwiftDataError.migrationUnsupported("Next entity identifier must be positive.")
        }
        try connection.execute(
            "INSERT INTO _osd_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(entityIDHighWatermarkKey), .blob(Array(String(nextIdentifier).utf8))])
    }

    private static func nextEntityIdentifier<S: Sequence>(after identifiers: S) throws -> Int
    where S.Element == Int {
        let maximumIdentifier = identifiers.max() ?? 0
        let (nextIdentifier, overflow) = maximumIdentifier.addingReportingOverflow(1)
        guard !overflow else {
            throw SwiftDataError.migrationUnsupported("Stored entity identifiers leave no appendable identifier space.")
        }
        return nextIdentifier
    }

    private static func writeSchemaVersion(_ version: Schema.Version?, connection: SQLConnection) throws {
        if let version {
            try connection.execute(
                "INSERT INTO _osd_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(schemaVersionKey), .blob(try version.encoded())])
        } else {
            try connection.execute("DELETE FROM _osd_meta WHERE key = ?", [.text(schemaVersionKey)])
        }
    }

    private static func validateCardinality(source: Schema, destination: Schema) throws {
        for sourceEntity in source.entities {
            guard let target = destination.entity(forName: sourceEntity.name) else { continue }
            for relationship in sourceEntity.relationships {
                guard
                    let next = target.relationships.first(where: {
                        $0.name == relationship.name || $0.originalName == relationship.name
                    })
                else { continue }
                guard relationship.isToMany == next.isToMany else {
                    throw SwiftDataError.migrationUnsupported(
                        "Relationship cardinality changed for \(sourceEntity.name).\(relationship.name).")
                }
            }
        }
    }

    private static func apply(source: Schema, destination: Schema, connection: SQLConnection) throws {
        let sourceHasInheritance = source.entities.contains { $0.superentityName != nil }
        let destinationHasInheritance = destination.entities.contains { $0.superentityName != nil }
        if sourceHasInheritance || destinationHasInheritance {
            try applyHierarchyOptionalAttributeAdditions(
                source: source, destination: destination, connection: connection,
                destinationHasInheritance: destinationHasInheritance)
            return
        }
        for schema in [source, destination] {
            try schema.validateRelationshipStorageMappings()
            let hasInheritance = schema.entities.contains { $0.superentityName != nil }
            guard
                !hasInheritance
                    || schema.entities.allSatisfy({ entity in
                        entity.relationships.isEmpty && entity.indexes.isEmpty
                            && !entity.attributes.contains(where: { $0.options.contains(.unique) })
                    })
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Lightweight migration does not support inherited relationships or indexes.")
            }
        }
        let validatedSourceIndexSQL = try validateSourceIndexLayout(source, connection: connection)
        let sourceNames = Set(source.entities.map(\.name))
        let destinationNames = Set(destination.entities.map(\.name))
        let sourceNamesByFoldedName = Dictionary(
            uniqueKeysWithValues: source.entities.map { ($0.name.uppercased(), $0.name) })
        let destinationNamesByFoldedName = Dictionary(
            uniqueKeysWithValues: destination.entities.map { ($0.name.uppercased(), $0.name) })
        for (foldedName, sourceName) in sourceNamesByFoldedName {
            if let destinationName = destinationNamesByFoldedName[foldedName], destinationName != sourceName {
                throw SwiftDataError.migrationUnsupported("Entity names cannot change case during migration.")
            }
        }
        if sourceNames != destinationNames {
            if sourceNames.isSubset(of: destinationNames) {
                try applyFlatIndependentRootAdditions(
                    source: source,
                    destination: destination,
                    validatedSourceIndexSQL: validatedSourceIndexSQL,
                    connection: connection)
            } else if destinationNames.isSubset(of: sourceNames) {
                try applyFlatIndependentRootRemovals(source: source, destination: destination, connection: connection)
            } else {
                try applyFlatIndependentRootAdditionsAndRemovals(
                    source: source,
                    destination: destination,
                    validatedSourceIndexSQL: validatedSourceIndexSQL,
                    connection: connection)
            }
            return
        }
        try validateDestinationIndexNames(destination)
        let pairedInverseRemovals = try planPairedInverseRelationshipRemovals(
            source: source, destination: destination, connection: connection)
        let toManyRemovalPlan = try planMultipleFlatOwnerOnlyToManyRemovals(
            source: source,
            destination: destination,
            sourceIndexSQL: validatedSourceIndexSQL,
            excludedEndpoints: Set(
                pairedInverseRemovals.flatMap {
                    [
                        "\($0.ownerEntityName).\($0.ownerRelationshipName)",
                        "\($0.inverseEntityName).\($0.inverseRelationshipName)",
                    ]
                }),
            connection: connection)
        if let toManyRemovalPlan {
            for joinTable in toManyRemovalPlan.joinTables {
                try connection.execute("DROP TABLE \(joinTable)")
            }
        }
        if let toManyRemovalPlan, !toManyRemovalPlan.addedAttributesByOwner.isEmpty {
            let sourceEntities = Dictionary(uniqueKeysWithValues: source.entities.map { ($0.name, $0) })
            for entity in destination.entities {
                guard let additions = toManyRemovalPlan.addedAttributesByOwner[entity.name],
                    let sourceEntity = sourceEntities[entity.name]
                else { continue }
                try addPlannedScalarColumns(
                    additions, source: sourceEntity, destination: entity, connection: connection)
            }
        }
        let sourceEntities = Dictionary(uniqueKeysWithValues: source.entities.map { ($0.name, $0) })
        var indexTransitions: [([IndexDefinition], [IndexDefinition])] = []
        for entity in destination.entities {
            guard let old = sourceEntities[entity.name] else {
                throw SwiftDataError.migrationUnsupported("Missing source entity mapping for \(entity.name).")
            }
            try migrate(
                entity: old,
                to: entity,
                sourceEntities: source.entities,
                destinationEntities: destination.entities,
                sourceEntityIDs: source.entityIDsByName,
                destinationEntityIDs: destination.entityIDsByName,
                pairedInverseRemovals: pairedInverseRemovals,
                toManyRemovalPlan: toManyRemovalPlan,
                indexTransitions: &indexTransitions,
                connection: connection)
        }
        try reconcileIndexes(indexTransitions, validatedSourceIndexSQL: validatedSourceIndexSQL, connection: connection)
    }

    private static func addPlannedScalarColumns(
        _ attributes: [Schema.Attribute],
        source: Schema.Entity,
        destination: Schema.Entity,
        connection: SQLConnection
    ) throws {
        let table = "Z\(source.name.uppercased())"
        for attribute in attributes.sorted(by: {
            $0.name.utf8.lexicographicallyPrecedes($1.name.utf8)
        }) {
            let defaultLiteral = try migrationDefaultLiteral(for: attribute)
            guard attribute.isOptional || defaultLiteral != nil else {
                throw SwiftDataError.migrationUnsupported(
                    "Adding required attribute \(destination.name).\(attribute.name) requires a literal default.")
            }
            let type = try SQLColumnType.resolve(
                attribute.type, property: "\(destination.name).\(attribute.name)", options: attribute.options)
            let required = attribute.isOptional ? "" : " NOT NULL"
            let defaultSQL = defaultLiteral.map { " DEFAULT \($0)" } ?? ""
            try connection.execute(
                "ALTER TABLE \(table) ADD COLUMN Z\(attribute.name.uppercased()) \(type.rawValue)"
                    + "\(required)\(defaultSQL)")
        }
    }

    private static func planPairedInverseRelationshipRemovals(
        source: Schema,
        destination: Schema,
        connection: SQLConnection
    ) throws -> [PairedInverseRelationshipRemoval] {
        guard source.entities.count == destination.entities.count,
            Set(source.entities.map(\.name)) == Set(destination.entities.map(\.name)),
            source.entityIDsByName == destination.entityIDsByName,
            source.entities.allSatisfy({ $0.superentityName == nil }),
            destination.entities.allSatisfy({ $0.superentityName == nil })
        else { return [] }

        let destinationEntities = Dictionary(uniqueKeysWithValues: destination.entities.map { ($0.name, $0) })
        let removedRelationships = source.entities.flatMap { entity in
            entity.relationships.compactMap { relationship -> (Schema.Entity, Schema.Relationship)? in
                guard let destinationEntity = destinationEntities[entity.name],
                    relationship.inverse != nil
                        || source.entities.contains(where: { candidate in
                            candidate.relationships.contains(where: { $0.inverse == relationship.name })
                        }),
                    !destinationEntity.relationships.contains(where: {
                        $0.name.caseInsensitiveCompare(relationship.name) == .orderedSame
                    })
                else { return nil }
                return (entity, relationship)
            }
        }
        guard !removedRelationships.isEmpty else { return [] }

        var plans: [PairedInverseRelationshipRemoval] = []
        var consumedEndpoints = Set<String>()
        for (owner, relationship) in removedRelationships.sorted(by: {
            ($0.0.name, $0.1.name) < ($1.0.name, $1.1.name)
        }) {
            let ownerKey = "\(owner.name).\(relationship.name)"
            guard !consumedEndpoints.contains(ownerKey) else { continue }
            guard let inverseName = relationship.inverse,
                let inverseEntity = source.entity(forName: relationship.destination),
                inverseEntity.name != owner.name,
                let inverse = inverseEntity.relationships.first(where: { $0.name == inverseName }),
                inverse.inverse == relationship.name,
                inverse.destination == owner.name,
                !relationship.isToMany,
                inverse.isToMany,
                relationship.isOptional,
                relationship.originalName == nil,
                inverse.originalName == nil,
                relationship.minimumModelCount == nil || relationship.minimumModelCount == 0,
                relationship.maximumModelCount == nil || relationship.maximumModelCount == 1,
                relationship.deleteRule == .nullify || relationship.deleteRule == .noAction,
                let ownerDestination = destinationEntities[owner.name],
                ownerDestination.relationships.allSatisfy({
                    $0.name.caseInsensitiveCompare(relationship.name) != .orderedSame
                        && $0.originalName?.caseInsensitiveCompare(relationship.name) != .orderedSame
                }),
                let inverseDestination = destinationEntities[inverseEntity.name],
                inverseDestination.relationships.allSatisfy({
                    $0.name.caseInsensitiveCompare(inverse.name) != .orderedSame
                        && $0.originalName?.caseInsensitiveCompare(inverse.name) != .orderedSame
                }),
                !source.entities.contains(where: { entity in
                    entity.relationships.contains(where: { candidate in
                        candidate != relationship && candidate != inverse
                            && (candidate.inverse == relationship.name || candidate.inverse == inverse.name)
                    })
                }),
                !destination.entities.contains(where: { entity in
                    entity.relationships.contains(where: { candidate in
                        candidate.inverse == relationship.name || candidate.inverse == inverse.name
                    })
                }),
                let mapping = source.relationshipStorageMapping(
                    modelEntityName: owner.name, relationshipName: relationship.name),
                !SchemaBuilder.isNonOwner(owner, relationship, schema: source),
                SchemaBuilder.isNonOwner(inverseEntity, inverse, schema: source),
                mapping.ownerRootEntityName == owner.name,
                mapping.declaringEntityName == owner.name
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Inverse relationship removals require a reciprocal, owning optional to-one/to-many pair with unchanged endpoints."
                )
            }

            let inverseKey = "\(inverseEntity.name).\(inverse.name)"
            for sourceEntity in source.entities {
                guard let destinationEntity = destinationEntities[sourceEntity.name],
                    sourceEntity.superentityName == destinationEntity.superentityName,
                    sourceEntity.attributes == destinationEntity.attributes,
                    sourceEntity.indexes == destinationEntity.indexes
                else {
                    throw SwiftDataError.migrationUnsupported(
                        "Inverse relationship removal cannot be combined with attribute, index, or hierarchy changes."
                    )
                }
                let retainedSourceRelationships = sourceEntity.relationships.filter { candidate in
                    let endpointKey = "\(sourceEntity.name).\(candidate.name)"
                    return endpointKey != "\(owner.name).\(relationship.name)" && endpointKey != inverseKey
                }
                let removedEndpointNames = Set(
                    retainedSourceRelationships.compactMap { candidate -> String? in
                        guard
                            !destinationEntity.relationships.contains(where: {
                                $0.name.caseInsensitiveCompare(candidate.name) == .orderedSame
                                    || $0.originalName?.caseInsensitiveCompare(candidate.name) == .orderedSame
                            })
                        else { return nil }
                        return "\(sourceEntity.name).\(candidate.name)"
                    })
                let hasOwnerOnlyToManyRemovals =
                    sourceEntity.name == owner.name
                    && retainedSourceRelationships.contains(where: { $0.isToMany })
                    && !removedEndpointNames.isEmpty
                guard removedEndpointNames.isEmpty || hasOwnerOnlyToManyRemovals else {
                    throw SwiftDataError.migrationUnsupported(
                        "Inverse relationship removal cannot be combined with other relationship removals."
                    )
                }
            }

            let ownerTable = "Z\(owner.name.uppercased())"
            let sourceColumns = try tableColumns(ownerTable, connection: connection)
            let indexName =
                "Z\(mapping.ownerRootEntityName.uppercased())_Z\(relationship.name.uppercased())_INDEX"
            let sourceIndex = indexDefinitions(for: owner, schema: source).first(where: {
                $0.name.caseInsensitiveCompare(indexName) == .orderedSame
            })
            guard sourceColumns.contains("Z\(mapping.storageColumnName.uppercased())"),
                sourceIndex?.table.caseInsensitiveCompare(ownerTable) == .orderedSame,
                sourceIndex?.columns == ["Z\(mapping.storageColumnName.uppercased())"],
                sourceIndex?.statement.hasPrefix("CREATE INDEX") == true,
                Database.sqliteLibVersionNumber >= 3_035_000
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Paired inverse relationship removal requires an existing owner foreign-key column and supported SQLite version."
                )
            }
            try validateOptionalRelationshipColumnRemoval(
                table: ownerTable,
                column: "Z\(mapping.storageColumnName.uppercased())",
                relationship: relationship,
                owner: owner,
                schema: source,
                connection: connection)
            guard consumedEndpoints.insert(ownerKey).inserted,
                consumedEndpoints.insert(inverseKey).inserted
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Inverse relationship removal plan contains overlapping pairs.")
            }
            plans.append(
                PairedInverseRelationshipRemoval(
                    ownerEntityName: owner.name,
                    ownerRelationshipName: relationship.name,
                    inverseEntityName: inverseEntity.name,
                    inverseRelationshipName: inverse.name,
                    column: "Z\(mapping.storageColumnName.uppercased())",
                    indexName: indexName
                ))
        }
        return plans
    }

    private static func applyFlatIndependentRootAdditions(
        source: Schema,
        destination: Schema,
        validatedSourceIndexSQL: [String: String],
        connection: SQLConnection
    ) throws {
        let sourceIndexDefinitions = source.entities.flatMap { indexDefinitions(for: $0, schema: source) }
        guard
            sourceIndexDefinitions.allSatisfy({
                validatedSourceIndexSQL[$0.name.uppercased()] == normalizedIndexSQL($0.statement)
            })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Adding root entities requires every source generated index to be validated.")
        }
        let sourceEntities = Dictionary(uniqueKeysWithValues: source.entities.map { ($0.name, $0) })
        let destinationEntities = Dictionary(uniqueKeysWithValues: destination.entities.map { ($0.name, $0) })
        guard source.entities.allSatisfy({ destinationEntities[$0.name] == $0 }) else {
            throw SwiftDataError.migrationUnsupported(
                "Adding flat roots cannot be combined with changes to existing entities.")
        }
        let added = destination.entities.filter { sourceEntities[$0.name] == nil }
        guard !added.isEmpty, added.allSatisfy({ $0.superentityName == nil && $0.relationships.isEmpty }) else {
            throw SwiftDataError.migrationUnsupported(
                "Flat migrations only add independent root entities without relationships.")
        }
        try validateDestinationIndexNames(destination)
        let built = try SchemaBuilder.build(destination)
        let physicalNames = Set(
            try connection.rows(
                "SELECT name FROM sqlite_master WHERE type IN ('table', 'index', 'view')"
            ).compactMap { row -> String? in
                guard case let .text(name)? = row.first else { return nil }
                return name.uppercased()
            })
        let maximumSourceID = source.entityIDsByName.values.max() ?? 0
        var plannedObjectNames = physicalNames
        var plans:
            [(
                entity: Schema.Entity, identifier: Int64, tableName: String, statement: String,
                indexes: [IndexDefinition]
            )] = []
        for entity in added.sorted(by: { lhs, rhs in
            let lhsID = destination.entityIDsByName[lhs.name] ?? .max
            let rhsID = destination.entityIDsByName[rhs.name] ?? .max
            return lhsID == rhsID ? lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8) : lhsID < rhsID
        }) {
            guard let rawIdentifier = destination.entityIDsByName[entity.name],
                rawIdentifier > maximumSourceID,
                let identifier = Int64(exactly: rawIdentifier)
            else {
                throw SwiftDataError.migrationUnsupported(
                    "New root entity identifiers must append after all persisted identifiers.")
            }
            let tableName = "Z\(entity.name.uppercased())"
            guard plannedObjectNames.insert(tableName).inserted else {
                throw SwiftDataError.migrationUnsupported("New root table '\(tableName)' already exists.")
            }
            guard let statement = built.statements.first(where: { $0.hasPrefix("CREATE TABLE \(tableName) ") }) else {
                throw SwiftDataError.migrationUnsupported("SchemaBuilder did not create table \(tableName).")
            }
            let definitions = indexDefinitions(for: entity, schema: destination)
            for definition in definitions {
                guard plannedObjectNames.insert(definition.name.uppercased()).inserted else {
                    throw SwiftDataError.migrationUnsupported(
                        "New root index '\(definition.name)' collides with another schema object.")
                }
            }
            plans.append((entity, identifier, tableName, statement, definitions))
        }
        for plan in plans {
            try connection.execute(plan.statement)
            for definition in plan.indexes { try connection.execute(definition.statement) }
            try connection.execute(
                "INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME, Z_SUPER, Z_MAX) VALUES (?, ?, 0, 0)",
                [.int(plan.identifier), .text(plan.entity.name)])
        }
    }

    private static func applyFlatIndependentRootRemovals(
        source: Schema,
        destination: Schema,
        connection: SQLConnection
    ) throws {
        let removedNames = source.entities.filter { destination.entity(forName: $0.name) == nil }.map(\.name)
        let sourceHasHierarchy = source.entities.contains { $0.superentityName != nil }
        let destinationHasHierarchy = destination.entities.contains { $0.superentityName != nil }
        let destinationEntityNames = Set(destination.entities.map(\.name))
        let retainedIDs = source.entityIDsByName.filter { destinationEntityNames.contains($0.key) }
        let removedEntityNames = Set(removedNames)
        let removedEntities = source.entities.filter { removedEntityNames.contains($0.name) }
        guard !removedNames.isEmpty,
            !sourceHasHierarchy,
            !destinationHasHierarchy,
            removedEntities.allSatisfy({ entity in
                entity.relationships.allSatisfy({ destination.entity(forName: $0.destination) != nil })
            }),
            removedEntities.allSatisfy({
                isSafelyRemovableRootEntity($0, source: source, destination: destination)
            }),
            source.entities.filter({ !removedEntityNames.contains($0.name) }).allSatisfy({ entity in
                entity.relationships.allSatisfy { !removedEntityNames.contains($0.destination) }
            })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Entity removal is limited to unreferenced flat roots without relationships or inheritance.")
        }
        guard retainedIDs == destination.entityIDsByName else {
            throw SwiftDataError.migrationUnsupported("Entity removal cannot renumber retained entity identifiers.")
        }
        for retained in destination.entities {
            guard let original = source.entity(forName: retained.name),
                equivalentEntityMetadata(original, retained)
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Entity removal cannot be combined with changes to retained entities.")
            }
        }
        try validateEntityRemovalSideEffects(source: source, destination: destination, connection: connection)
        for removedEntity in removedEntities {
            guard let removedID = source.entityIDsByName[removedEntity.name] else {
                throw SwiftDataError.migrationUnsupported("Removed entity metadata is incomplete.")
            }
            let table = "Z\(removedEntity.name.uppercased())"
            let tableExists = try connection.rows(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? COLLATE NOCASE LIMIT 1",
                [.text(table)])
            guard !tableExists.isEmpty else {
                throw SwiftDataError.migrationUnsupported(
                    "Physical table for removed entity \(removedEntity.name) is missing.")
            }
            try connection.execute("DROP TABLE \(table)")
            try connection.execute("DELETE FROM Z_PRIMARYKEY WHERE Z_ENT = ?", [.int(Int64(removedID))])
            guard connection.changesCount() == 1 else {
                throw SwiftDataError.migrationUnsupported(
                    "Entity identifier row for \(removedEntity.name) is missing.")
            }
        }
    }

    private static func applyFlatIndependentRootAdditionsAndRemovals(
        source: Schema,
        destination: Schema,
        validatedSourceIndexSQL: [String: String],
        connection: SQLConnection
    ) throws {
        let sourceNames = Set(source.entities.map(\.name))
        let destinationNames = Set(destination.entities.map(\.name))
        let retainedNames = sourceNames.intersection(destinationNames)
        let removedNames = sourceNames.subtracting(destinationNames)
        let addedNames = destinationNames.subtracting(sourceNames)
        guard !retainedNames.isEmpty, !removedNames.isEmpty, !addedNames.isEmpty,
            !source.entities.contains(where: { $0.superentityName != nil }),
            !destination.entities.contains(where: { $0.superentityName != nil })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Combined entity changes require at least one retained, removed, and added flat root.")
        }
        for retainedName in retainedNames {
            guard let sourceEntity = source.entity(forName: retainedName),
                let destinationEntity = destination.entity(forName: retainedName),
                equivalentEntityMetadata(sourceEntity, destinationEntity)
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Combined entity changes cannot modify retained entities.")
            }
        }
        let removedEntities = source.entities.filter { removedNames.contains($0.name) }
        let addedEntities = destination.entities.filter { addedNames.contains($0.name) }
        guard
            removedEntities.allSatisfy({ entity in
                entity.relationships.allSatisfy({ destination.entity(forName: $0.destination) != nil })
            }),
            removedEntities.allSatisfy({
                isSafelyRemovableRootEntity($0, source: source, destination: destination)
            }),
            addedEntities.allSatisfy({ $0.relationships.isEmpty && $0.superentityName == nil }),
            source.entities.filter({ !removedNames.contains($0.name) }).allSatisfy({ entity in
                entity.relationships.allSatisfy { !removedNames.contains($0.destination) }
            }),
            addedEntities.allSatisfy({ entity in
                entity.attributes.allSatisfy({ !$0.options.contains(.externalStorage) })
            })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Combined entity changes only support unrelated flat roots without external storage.")
        }
        let sourceMaximumID = source.entityIDsByName.values.max() ?? 0
        guard
            addedEntities.allSatisfy({
                guard let identifier = destination.entityIDsByName[$0.name] else { return false }
                return identifier > sourceMaximumID
            })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Added entity identifiers must append after all source identifiers, including removed entities.")
        }
        let removedObjects = Set(
            removedEntities.flatMap { entity in
                ["Z\(entity.name.uppercased())"]
                    + indexDefinitions(for: entity, schema: source).map { $0.name.uppercased() }
            })
        let addedObjects = Set(
            addedEntities.flatMap { entity in
                ["Z\(entity.name.uppercased())"]
                    + indexDefinitions(for: entity, schema: destination).map { $0.name.uppercased() }
            })
        let retainedObjects = Set(
            source.entities.filter({ retainedNames.contains($0.name) }).flatMap { entity in
                ["Z\(entity.name.uppercased())"]
                    + indexDefinitions(for: entity, schema: source).map { $0.name.uppercased() }
            })
        let physicalRetainedObjects = Set(
            try connection.rows("SELECT name FROM sqlite_master WHERE type IN ('table', 'index')")
                .compactMap { row -> String? in
                    guard case let .text(name)? = row.first,
                        retainedObjects.contains(name.uppercased())
                    else { return nil }
                    return name.uppercased()
                })
        guard removedObjects.isDisjoint(with: addedObjects),
            physicalRetainedObjects.isDisjoint(with: addedObjects)
        else {
            throw SwiftDataError.migrationUnsupported(
                "Added entity tables or indexes collide with existing schema objects.")
        }
        let retainedEntities = source.entities.filter { retainedNames.contains($0.name) }
        let retainedIDs = source.entityIDsByName.filter { retainedNames.contains($0.key) }
        let retainedSchema = try Schema(retainedEntities, version: source.version, entityIDs: retainedIDs)
        let retainedIndexNames = Set(
            retainedSchema.entities.flatMap { indexDefinitions(for: $0, schema: retainedSchema) }
                .map { $0.name.uppercased() })
        let retainedIndexSQL = validatedSourceIndexSQL.filter { retainedIndexNames.contains($0.key) }
        guard retainedIndexSQL.count == retainedIndexNames.count else {
            throw SwiftDataError.migrationUnsupported(
                "Combined entity changes require validated source indexes for every retained entity.")
        }
        try applyFlatIndependentRootRemovals(
            source: source, destination: retainedSchema, connection: connection)
        try applyFlatIndependentRootAdditions(
            source: retainedSchema,
            destination: destination,
            validatedSourceIndexSQL: retainedIndexSQL,
            connection: connection)
    }

    private static func equivalentEntityMetadata(_ lhs: Schema.Entity, _ rhs: Schema.Entity) -> Bool {
        lhs.name == rhs.name
            && lhs.superentityName == rhs.superentityName
            && lhs.attributes.count == rhs.attributes.count
            && lhs.attributes.allSatisfy { rhs.attributes.contains($0) }
            && lhs.relationships.count == rhs.relationships.count
            && lhs.relationships.allSatisfy { rhs.relationships.contains($0) }
            && lhs.indexes.count == rhs.indexes.count
            && lhs.indexes.allSatisfy { rhs.indexes.contains($0) }
    }

    private static func isSafelyRemovableRootEntity(
        _ entity: Schema.Entity,
        source: Schema,
        destination: Schema
    ) -> Bool {
        guard entity.superentityName == nil,
            !source.entities.contains(where: { $0.superentityName == entity.name }),
            !entity.attributes.contains(where: { $0.options.contains(.externalStorage) }),
            entity.relationships.allSatisfy({ relationship in
                guard !relationship.isToMany,
                    relationship.isOptional,
                    relationship.inverse == nil,
                    relationship.originalName == nil,
                    relationship.minimumModelCount == nil || relationship.minimumModelCount == 0,
                    relationship.maximumModelCount == nil || relationship.maximumModelCount == 1,
                    relationship.deleteRule == .nullify || relationship.deleteRule == .noAction,
                    destination.entity(forName: relationship.destination) != nil,
                    source.entity(forName: relationship.destination) != nil
                else { return false }
                guard
                    let mapping = source.relationshipStorageMapping(
                        modelEntityName: entity.name, relationshipName: relationship.name),
                    !SchemaBuilder.isNonOwner(entity, relationship, schema: source),
                    mapping.declaringEntityName == entity.name,
                    mapping.ownerRootEntityName == entity.name
                else { return false }
                return true
            }),
            !source.entities.contains(where: { candidate in
                candidate.name != entity.name
                    && candidate.relationships.contains(where: { candidateRelationship in
                        candidateRelationship.destination == entity.name
                            || entity.relationships.contains(where: { $0.name == candidateRelationship.inverse })
                    })
            })
        else { return false }
        return true
    }

    private static func validateEntityRemovalSideEffects(
        source: Schema,
        destination: Schema,
        connection: SQLConnection
    ) throws {
        let removedEntities = source.entities.filter { destination.entity(forName: $0.name) == nil }
        guard
            removedEntities.allSatisfy({ entity in
                !entity.attributes.contains(where: { $0.options.contains(.externalStorage) })
            })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Entity removal is unsupported for entities with external-storage attributes.")
        }
        let sideObjects = try connection.rows(
            "SELECT 1 FROM sqlite_master WHERE type IN ('trigger', 'view') LIMIT 1")
        guard sideObjects.isEmpty else {
            throw SwiftDataError.migrationUnsupported("Entity removal is unsupported when triggers or views exist.")
        }
        _ = try validateSourceIndexLayout(source, connection: connection)
        let expectedIndexes = try expectedIndexNames(source)
        let removalStatements = try SchemaBuilder.build(source).statements.filter {
            $0.hasPrefix("CREATE INDEX") || $0.hasPrefix("CREATE UNIQUE INDEX")
        }
        let removalDefinitions = try indexDefinitions(from: indexStatementsByName(removalStatements))
        try validatePhysicalIndexStatements(
            removalStatements,
            definitionsByName: removalDefinitions,
            connection: connection)
        let removedTableNames = Set(
            source.entities.filter { destination.entity(forName: $0.name) == nil }
                .map { "Z\($0.name.uppercased())" })
        let generatedModelTables = Set(source.entities.map { "Z\($0.name.uppercased())" })
        for row in try connection.rows("SELECT name, tbl_name FROM sqlite_master WHERE type = 'index'") {
            guard row.count > 1, case let .text(name) = row[0], case let .text(table) = row[1] else { continue }
            if name.lowercased().hasPrefix("sqlite_autoindex_"), generatedModelTables.contains(table.uppercased()) {
                throw SwiftDataError.migrationUnsupported(
                    "Entity removal is unsupported when unexpected SQLite autoindex \(name) exists.")
            }
            guard removedTableNames.contains(table.uppercased()), !expectedIndexes.contains(name.uppercased()) else {
                continue
            }
            throw SwiftDataError.migrationUnsupported(
                "Entity removal is unsupported when untracked index \(name) exists on \(table).")
        }
        let tables = try connection.rows(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        let generatedTables = try SchemaBuilder.build(source).statements.compactMap { statement -> String? in
            guard statement.hasPrefix("CREATE TABLE "),
                let tableName = statement.split(separator: " ").dropFirst(2).first
            else { return nil }
            return String(tableName).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        }
        let physicalTables = Set(
            tables.compactMap { row -> String? in
                guard case let .text(name)? = row.first else { return nil }
                return name.uppercased()
            })
        guard generatedTables.allSatisfy({ physicalTables.contains($0.uppercased()) }) else {
            throw SwiftDataError.migrationUnsupported(
                "Entity removal requires every source table and relationship join table to exist.")
        }
        let expectedTables = Set(
            generatedTables.map { $0.uppercased() }
                + ["_OSD_HISTORY_TRANSACTIONS", "_OSD_HISTORY_CHANGES"])
        let destinationTables = Set(
            try SchemaBuilder.build(destination).statements.compactMap { statement -> String? in
                guard statement.hasPrefix("CREATE TABLE "),
                    let tableName = statement.split(separator: " ").dropFirst(2).first
                else { return nil }
                return String(tableName).trimmingCharacters(in: CharacterSet(charactersIn: ";")).uppercased()
            })
        let sourceJoinTables = Set(
            generatedTables.map({ $0.uppercased() }).filter { $0.hasPrefix("Z_") })
        guard sourceJoinTables.isSubset(of: destinationTables) else {
            throw SwiftDataError.migrationUnsupported(
                "Entity removal cannot change relationship join-table layouts.")
        }
        for row in tables {
            guard case let .text(name)? = row.first else { continue }
            guard expectedTables.contains(name.uppercased()) else {
                throw SwiftDataError.migrationUnsupported(
                    "Entity removal is unsupported when unexpected table \(name) exists.")
            }
            let quotedName = "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
            guard try connection.rows("PRAGMA foreign_key_list(\(quotedName))").isEmpty else {
                throw SwiftDataError.migrationUnsupported("Entity removal is unsupported when foreign keys exist.")
            }
        }
    }

    private static func applyHierarchyOptionalAttributeAdditions(
        source: Schema,
        destination: Schema,
        connection: SQLConnection,
        destinationHasInheritance: Bool
    ) throws {
        let sourceBuilt: BuiltSchema
        let destinationBuilt: BuiltSchema
        do {
            sourceBuilt = try SchemaBuilder.build(source)
            destinationBuilt = try SchemaBuilder.build(destination)
        } catch {
            throw SwiftDataError.migrationUnsupported(
                "Destination hierarchy schema is invalid for lightweight migration: \(error)")
        }
        func columnKey(_ name: String) -> String { name.uppercased() }
        func less(_ lhs: String, _ rhs: String) -> Bool {
            lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
        }
        func sameAttributeDefinition(_ lhs: Schema.Attribute, _ rhs: Schema.Attribute) -> Bool {
            lhs.type == rhs.type
                && lhs.isOptional == rhs.isOptional
                && lhs.defaultValue == rhs.defaultValue
                && lhs.options == rhs.options
                && lhs.originalName == rhs.originalName
                && lhs.components == rhs.components
        }
        let sourceNames = Set(source.entities.map(\.name))
        let destinationNames = Set(destination.entities.map(\.name))
        guard destinationHasInheritance,
            sourceNames.isSubset(of: destinationNames),
            source.entities.allSatisfy({ source.entityIDsByName[$0.name] == destination.entityIDsByName[$0.name] })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Hierarchy migration cannot remove entities or change existing entity identifiers.")
        }
        try source.validateRelationshipStorageMappings()
        try destination.validateRelationshipStorageMappings()
        let sourceIndexStatements = sourceBuilt.statements.filter {
            $0.hasPrefix("CREATE INDEX") || $0.hasPrefix("CREATE UNIQUE INDEX")
        }
        let sourceDefinitions = try indexDefinitions(
            from: Dictionary(
                uniqueKeysWithValues: sourceIndexStatements.compactMap { statement -> (String, String)? in
                    let tokens = statement.split(whereSeparator: \.isWhitespace)
                    guard let indexPosition = tokens.firstIndex(of: "INDEX"),
                        tokens.indices.contains(indexPosition + 1)
                    else { return nil }
                    return (String(tokens[indexPosition + 1]).uppercased(), statement)
                }))
        try validatePhysicalIndexStatements(
            sourceIndexStatements,
            definitionsByName: sourceDefinitions,
            connection: connection,
            allowsPartialIndexes: true)
        let hierarchyIndexPlan = try planHierarchyIndexes(
            sourceStatements: sourceBuilt.statements,
            destinationStatements: destinationBuilt.statements,
            connection: connection)

        let sourceByName = Dictionary(uniqueKeysWithValues: source.entities.map { ($0.name, $0) })
        let destinationByName = Dictionary(uniqueKeysWithValues: destination.entities.map { ($0.name, $0) })
        func rootName(for entityName: String, schema: Schema) throws -> String {
            var current = schema.entity(forName: entityName)
            var visited = Set<String>()
            while let entity = current, let parentName = entity.superentityName {
                guard visited.insert(entity.name).inserted,
                    let parent = schema.entity(forName: parentName)
                else {
                    throw SwiftDataError.migrationUnsupported("Hierarchy contains an invalid parent mapping.")
                }
                current = parent
            }
            guard let root = current else {
                throw SwiftDataError.migrationUnsupported("Hierarchy migration cannot find an entity root.")
            }
            return root.name
        }
        let newEntities = destination.entities.filter { sourceByName[$0.name] == nil }
        func isAncestor(_ ancestorName: String, of entityName: String) -> Bool {
            var current = destination.entity(forName: entityName)
            var visited = Set<String>()
            while let entity = current, visited.insert(entity.name).inserted {
                if entity.name == ancestorName { return true }
                current = entity.superentityName.flatMap(destination.entity(forName:))
            }
            return false
        }
        func sameRelationshipExceptInverse(_ lhs: Schema.Relationship, _ rhs: Schema.Relationship) -> Bool {
            lhs.name == rhs.name
                && lhs.destination == rhs.destination
                && lhs.isToMany == rhs.isToMany
                && lhs.isOptional == rhs.isOptional
                && lhs.deleteRule == rhs.deleteRule
                && lhs.minimumModelCount == rhs.minimumModelCount
                && lhs.maximumModelCount == rhs.maximumModelCount
                && lhs.originalName == rhs.originalName
                && lhs.declaringEntityName == rhs.declaringEntityName
        }
        func permitsMetadataOnlyInverseAttachment(
            newEntity: Schema.Entity,
            inverseRelationship: Schema.Relationship,
            ownerEntity: Schema.Entity,
            sourceOwnerRelationship: Schema.Relationship,
            destinationOwnerRelationship: Schema.Relationship
        ) -> Bool {
            guard inverseRelationship.isToMany,
                inverseRelationship.isOptional,
                inverseRelationship.inverse == sourceOwnerRelationship.name,
                inverseRelationship.minimumModelCount == nil,
                inverseRelationship.maximumModelCount == nil,
                inverseRelationship.originalName == nil,
                inverseRelationship.deleteRule == .nullify || inverseRelationship.deleteRule == .noAction,
                inverseRelationship.destination == ownerEntity.name,
                SchemaBuilder.isNonOwner(newEntity, inverseRelationship, schema: destination),
                !sourceOwnerRelationship.isToMany,
                sourceOwnerRelationship.inverse == nil,
                sourceOwnerRelationship.isOptional,
                sourceOwnerRelationship.destination == newEntity.superentityName
                    || isAncestor(sourceOwnerRelationship.destination, of: newEntity.name),
                sameRelationshipExceptInverse(sourceOwnerRelationship, destinationOwnerRelationship),
                let sourceMapping = source.relationshipStorageMapping(
                    modelEntityName: ownerEntity.name, relationshipName: sourceOwnerRelationship.name),
                let destinationMapping = destination.relationshipStorageMapping(
                    modelEntityName: ownerEntity.name, relationshipName: destinationOwnerRelationship.name),
                sourceMapping == destinationMapping
            else { return false }
            return true
        }
        for entity in newEntities {
            let hasNewDescendants = destination.entities.contains { $0.superentityName == entity.name }
            let entityRootName = try rootName(for: entity.name, schema: destination)
            let rootIsNew = sourceByName[entityRootName] == nil
            if let parentName = entity.superentityName, !rootIsNew {
                guard sourceByName[parentName] != nil, !hasNewDescendants else {
                    throw SwiftDataError.migrationUnsupported(
                        "Hierarchy migration only adds leaf subclasses beneath existing entities.")
                }
            } else if entity.superentityName == nil {
                guard rootIsNew else {
                    throw SwiftDataError.migrationUnsupported(
                        "Hierarchy migration cannot add a root over an existing entity.")
                }
            } else if !rootIsNew {
                throw SwiftDataError.migrationUnsupported(
                    "Hierarchy migration cannot add an intermediate class beneath an existing root.")
            }
            for relationship in entity.relationships {
                if relationship.isToMany, relationship.inverse != nil {
                    guard let ownerEntity = sourceByName[relationship.destination],
                        let sourceOwnerRelationship = ownerEntity.relationships.first(where: {
                            $0.name == relationship.inverse
                        }),
                        let destinationOwnerRelationship = destinationByName[ownerEntity.name]?.relationships
                            .first(where: { $0.name == relationship.inverse }),
                        permitsMetadataOnlyInverseAttachment(
                            newEntity: entity,
                            inverseRelationship: relationship,
                            ownerEntity: ownerEntity,
                            sourceOwnerRelationship: sourceOwnerRelationship,
                            destinationOwnerRelationship: destinationOwnerRelationship)
                    else {
                        throw SwiftDataError.migrationUnsupported(
                            "New inverse relationships must attach to unchanged existing to-one storage.")
                    }
                    continue
                }
                guard relationship.inverse == nil,
                    relationship.deleteRule == .nullify || relationship.deleteRule == .noAction,
                    relationship.originalName == nil,
                    source.entity(forName: relationship.destination) != nil
                else {
                    throw SwiftDataError.migrationUnsupported(
                        "New hierarchy relationships must be no-inverse and target existing entities with nullify or noAction delete rules."
                    )
                }
                if relationship.isToMany {
                    guard relationship.minimumModelCount == nil, relationship.maximumModelCount == nil else {
                        throw SwiftDataError.migrationUnsupported(
                            "New hierarchy to-many relationships cannot have cardinality constraints.")
                    }
                    if rootIsNew {
                        guard source.entity(forName: relationship.destination) != nil,
                            entity.name != relationship.destination
                        else {
                            throw SwiftDataError.migrationUnsupported(
                                "New root to-many relationships require an existing destination outside the root.")
                        }
                    } else {
                        let ownerRootName = try rootName(for: entity.name, schema: destination)
                        let destinationHasHierarchy = source.entities.contains {
                            $0.superentityName == relationship.destination
                        }
                        guard let targetEntity = source.entity(forName: relationship.destination),
                            targetEntity.superentityName == nil, !destinationHasHierarchy,
                            ownerRootName != relationship.destination
                        else {
                            throw SwiftDataError.migrationUnsupported(
                                "New leaf to-many relationships require an existing flat destination outside the owner hierarchy."
                            )
                        }
                    }
                } else {
                    guard relationship.isOptional,
                        relationship.minimumModelCount == nil || relationship.minimumModelCount == 0,
                        relationship.maximumModelCount == nil || relationship.maximumModelCount == 1
                    else {
                        throw SwiftDataError.migrationUnsupported(
                            "New hierarchy to-one relationships must be optional and unconstrained."
                        )
                    }
                }
            }
        }
        for sourceEntity in source.entities {
            guard let destinationEntity = destinationByName[sourceEntity.name],
                sourceEntity.superentityName == destinationEntity.superentityName,
                sourceEntity.indexes == destinationEntity.indexes
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Hierarchy migration cannot change topology, relationships, or constraints.")
            }
            let destinationRelationships = Dictionary(
                uniqueKeysWithValues: destinationEntity.relationships.map { ($0.name, $0) })
            guard sourceEntity.relationships.count == destinationEntity.relationships.count else {
                throw SwiftDataError.migrationUnsupported(
                    "Hierarchy migration cannot add or remove relationships on existing entities.")
            }
            for sourceRelationship in sourceEntity.relationships {
                guard let destinationRelationship = destinationRelationships[sourceRelationship.name] else {
                    throw SwiftDataError.migrationUnsupported(
                        "Hierarchy migration cannot rename relationships on existing entities.")
                }
                guard sourceRelationship != destinationRelationship else { continue }
                let hasMetadataOnlyInverse = newEntities.contains { newEntity in
                    newEntity.relationships.contains { inverseRelationship in
                        permitsMetadataOnlyInverseAttachment(
                            newEntity: newEntity,
                            inverseRelationship: inverseRelationship,
                            ownerEntity: sourceEntity,
                            sourceOwnerRelationship: sourceRelationship,
                            destinationOwnerRelationship: destinationRelationship)
                    }
                }
                guard hasMetadataOnlyInverse else {
                    throw SwiftDataError.migrationUnsupported(
                        "Hierarchy migration cannot change existing relationship storage metadata.")
                }
            }
        }

        func isAncestor(_ ancestorName: String, of entityName: String, schema: Schema) -> Bool {
            var current = schema.entity(forName: entityName)
            var visited = Set<String>()
            while let entity = current, visited.insert(entity.name).inserted {
                if entity.name == ancestorName { return true }
                current = entity.superentityName.flatMap(schema.entity(forName:))
            }
            return false
        }

        var sourceColumnsByRoot: [String: Set<String>] = [:]
        for entity in source.entities {
            let root = try rootName(for: entity.name, schema: source)
            var existingColumns = Set(
                entity.attributes.flatMap { attribute in
                    attribute.options.contains(.flattened)
                        ? attribute.components.map { "Z\($0.columnName)" } : ["Z\(attribute.name)"]
                }.map(columnKey))
            for relationship in entity.relationships where !relationship.isToMany {
                guard !SchemaBuilder.isNonOwner(entity, relationship, schema: source),
                    let mapping = source.relationshipStorageMapping(
                        modelEntityName: entity.name, relationshipName: relationship.name)
                else { continue }
                existingColumns.insert(columnKey("Z\(mapping.storageColumnName)"))
            }
            existingColumns.formUnion(["Z_PK", "Z_ENT", "Z_OPT"])
            sourceColumnsByRoot[root, default: []].formUnion(existingColumns)
        }

        var additionsByRootAndColumn: [String: (root: String, column: String, attribute: Schema.Attribute)] = [:]
        var additionOwnersByRootAndColumn: [String: [String]] = [:]
        var relationshipAdditionsByRootAndColumn: [String: (root: String, column: String)] = [:]
        var joinTableAdditions: Set<String> = []
        for destinationEntity in destination.entities {
            let sourceEntity = sourceByName[destinationEntity.name]
            let sourceAttributes = Dictionary(
                uniqueKeysWithValues: (sourceEntity?.attributes ?? []).map { ($0.name, $0) })
            let destinationAttributesByName = Dictionary(
                uniqueKeysWithValues: destinationEntity.attributes.map { ($0.name, $0) })
            let destinationParentAttributes =
                destinationEntity.superentityName
                .flatMap { destinationByName[$0]?.attributes }
                ?? []
            guard sourceAttributes.allSatisfy({ name, _ in destinationAttributesByName[name] != nil }) else {
                throw SwiftDataError.migrationUnsupported(
                    "Hierarchy migration cannot remove persisted attributes from \(destinationEntity.name).")
            }
            for attribute in destinationEntity.attributes {
                if let existing = sourceAttributes[attribute.name] {
                    guard existing == attribute else {
                        throw SwiftDataError.migrationUnsupported(
                            "Hierarchy migration cannot change existing attribute \(destinationEntity.name).\(attribute.name)."
                        )
                    }
                    continue
                }
                if let inherited = destinationParentAttributes.first(where: {
                    columnKey($0.name) == columnKey(attribute.name)
                }) {
                    guard sameAttributeDefinition(inherited, attribute) else {
                        throw SwiftDataError.migrationUnsupported(
                            "Hierarchy migration cannot redeclare a newly inherited attribute incompatibly.")
                    }
                    continue
                }
                let isNewRoot = sourceEntity == nil && destinationEntity.superentityName == nil
                let isNewLeaf = sourceEntity == nil && destinationEntity.superentityName != nil
                let destinationRootName = try rootName(for: destinationEntity.name, schema: destination)
                let isNewTreeEntity = sourceEntity == nil && sourceByName[destinationRootName] == nil
                guard isNewRoot || isNewLeaf || (attribute.isOptional && attribute.defaultValue == nil),
                    attribute.originalName == nil,
                    (!attribute.options.contains(.unique) || sourceEntity == nil),
                    !attribute.options.contains(.externalStorage),
                    !attribute.options.contains(.flattened),
                    attribute.components.isEmpty,
                    !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
                else {
                    throw SwiftDataError.migrationUnsupported(
                        "Hierarchy migration only adds optional scalar attributes without defaults.")
                }
                if isNewTreeEntity { continue }
                let root = try rootName(for: destinationEntity.name, schema: destination)
                let keyName = columnKey("Z\(attribute.name)")
                guard !sourceColumnsByRoot[root, default: []].contains(keyName) else {
                    throw SwiftDataError.migrationUnsupported(
                        "Hierarchy migration cannot add an attribute over an existing union column.")
                }
                let key = "\(root):\(keyName)"
                if let existing = additionsByRootAndColumn[key] {
                    guard sameAttributeDefinition(existing.attribute, attribute) else {
                        throw SwiftDataError.migrationUnsupported(
                            "Hierarchy siblings add incompatible definitions for \(attribute.name).")
                    }
                    let existingOwners = additionOwnersByRootAndColumn[key] ?? []
                    guard
                        !existingOwners.contains(where: {
                            isAncestor($0, of: destinationEntity.name, schema: destination)
                                || isAncestor(destinationEntity.name, of: $0, schema: destination)
                        })
                    else {
                        throw SwiftDataError.migrationUnsupported(
                            "Hierarchy migration cannot redeclare one new column along an ancestor chain.")
                    }
                    additionOwnersByRootAndColumn[key, default: []].append(destinationEntity.name)
                } else {
                    additionsByRootAndColumn[key] = (root, attribute.name, attribute)
                    additionOwnersByRootAndColumn[key] = [destinationEntity.name]
                }
            }
        }

        for entity in newEntities {
            let rootIsNew = sourceByName[try rootName(for: entity.name, schema: destination)] == nil
            for relationship in entity.relationships {
                if rootIsNew {
                    if !relationship.isToMany {
                        guard
                            let mapping = destination.relationshipStorageMapping(
                                modelEntityName: entity.name, relationshipName: relationship.name),
                            mapping.declaringEntityName == entity.name,
                            mapping.ownerRootEntityName == (try rootName(for: entity.name, schema: destination))
                        else {
                            throw SwiftDataError.migrationUnsupported(
                                "New-tree to-one relationships must use directly owned storage.")
                        }
                        continue
                    }
                }
                if relationship.isToMany {
                    if relationship.inverse != nil,
                        SchemaBuilder.isNonOwner(entity, relationship, schema: destination)
                    {
                        continue
                    }
                    guard
                        let joinTable = SchemaBuilder.joinTableName(
                            for: entity, relationship: relationship, schema: destination)
                    else {
                        throw SwiftDataError.migrationUnsupported(
                            "New hierarchy to-many relationship has no join-table mapping.")
                    }
                    let sourceJoinTables = source.entities.flatMap { sourceEntity in
                        sourceEntity.relationships.compactMap { sourceRelationship in
                            SchemaBuilder.joinTableName(
                                for: sourceEntity, relationship: sourceRelationship, schema: source)
                        }
                    }
                    let tableAlreadyExists =
                        try connection.rows(
                            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? COLLATE NOCASE LIMIT 1",
                            [.text(joinTable)]
                        ).isEmpty == false
                    guard !sourceJoinTables.contains(where: { $0.caseInsensitiveCompare(joinTable) == .orderedSame }),
                        !tableAlreadyExists
                    else {
                        throw SwiftDataError.migrationUnsupported(
                            "New hierarchy join table collides with existing storage.")
                    }
                    joinTableAdditions.insert(joinTable)
                    continue
                }
                guard
                    let mapping = destination.relationshipStorageMapping(
                        modelEntityName: entity.name, relationshipName: relationship.name),
                    mapping.declaringEntityName == entity.name,
                    mapping.ownerRootEntityName == (try rootName(for: entity.name, schema: destination))
                else {
                    throw SwiftDataError.migrationUnsupported(
                        "New hierarchy to-one relationship has incomplete storage metadata.")
                }
                let root = mapping.ownerRootEntityName
                let column = "Z\(mapping.storageColumnName)"
                let normalizedColumn = columnKey(column)
                let key = "\(root):\(normalizedColumn)"
                guard !sourceColumnsByRoot[root, default: []].contains(normalizedColumn),
                    additionsByRootAndColumn[key] == nil,
                    relationshipAdditionsByRootAndColumn[key] == nil
                else {
                    throw SwiftDataError.migrationUnsupported(
                        "New hierarchy relationship column collides with existing storage."
                    )
                }
                relationshipAdditionsByRootAndColumn[key] = (root, column)
            }
        }

        for (root, column, attribute) in additionsByRootAndColumn.values.sorted(by: {
            if $0.root != $1.root { return less($0.root, $1.root) }
            return less($0.column, $1.column)
        }) {
            let sqlType = try SQLColumnType.resolve(
                attribute.type, property: "\(root).\(attribute.name)", options: attribute.options)
            let table = "Z\(root.uppercased())"
            let physicalColumn = "Z\(column.uppercased())"
            try connection.execute(
                "ALTER TABLE \(table) ADD COLUMN \(physicalColumn) \(sqlType.rawValue)")
            let definition = try connection.rows("PRAGMA table_info(\(table))").first {
                $0.count > 4 && $0[1] == .text(physicalColumn)
            }
            guard let definition, definition[2] == .text(sqlType.rawValue),
                definition[3] == .int(0), definition[4] == .null
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Added hierarchy column \(table).\(physicalColumn) has an incompatible physical definition.")
            }
        }
        for entity in newEntities where entity.superentityName == nil {
            let tableName = "Z\(entity.name.uppercased())"
            let existingTable =
                try connection.rows(
                    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? COLLATE NOCASE LIMIT 1",
                    [.text(tableName)]
                ).isEmpty == false
            guard !existingTable,
                let statement = destinationBuilt.statements.first(where: {
                    $0.hasPrefix("CREATE TABLE \(tableName) (")
                })
            else {
                throw SwiftDataError.migrationUnsupported(
                    "New root entity table collides with existing storage or lacks a DDL definition.")
            }
            try connection.execute(statement)
        }
        for (root, column) in relationshipAdditionsByRootAndColumn.values.sorted(by: {
            if $0.root != $1.root { return less($0.root, $1.root) }
            return less($0.column, $1.column)
        }) {
            let table = "Z\(root.uppercased())"
            let physicalColumn = column.uppercased()
            try connection.execute("ALTER TABLE \(table) ADD COLUMN \(physicalColumn) INTEGER")
            let definition = try connection.rows("PRAGMA table_info(\(table))").first {
                $0.count > 4 && $0[1] == .text(physicalColumn)
            }
            guard let definition, definition[2] == .text("INTEGER"), definition[3] == .int(0), definition[4] == .null
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Added hierarchy relationship column \(table).\(physicalColumn) has an incompatible definition."
                )
            }
        }
        for joinTable in joinTableAdditions.sorted(by: less) {
            try connection.execute("CREATE TABLE \(joinTable) (Z_A INTEGER, Z_B INTEGER);")
        }
        try reconcileHierarchyIndexes(hierarchyIndexPlan, connection: connection)
        for entity in newEntities.sorted(by: {
            destination.entityIDsByName[$0.name, default: 0] < destination.entityIDsByName[$1.name, default: 0]
        }) {
            guard let entityID = destination.entityIDsByName[entity.name] else {
                throw SwiftDataError.migrationUnsupported("New hierarchy entity has incomplete ID metadata.")
            }
            let parentID = entity.superentityName.flatMap { destination.entityIDsByName[$0] } ?? 0
            guard entity.superentityName == nil || parentID > 0 else {
                throw SwiftDataError.migrationUnsupported("New hierarchy entity has incomplete parent ID metadata.")
            }
            try connection.execute(
                "INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME, Z_SUPER, Z_MAX) VALUES (?, ?, ?, ?)",
                [.int(Int64(entityID)), .text(entity.name), .int(Int64(parentID)), .int(0)])
        }
        try validatePhysicalSchema(destination, connection: connection)
    }

    private static func attributeMappings(
        source: Schema.Entity,
        destination: Schema.Entity
    ) throws -> [AttributeMapping] {
        func columnKey(_ property: String) -> String { "Z\(property.uppercased())" }
        let sourceByName = Dictionary(uniqueKeysWithValues: source.attributes.map { (columnKey($0.name), $0) })
        var explicitClaims: [String: Schema.Attribute] = [:]
        for target in destination.attributes {
            guard let originalName = target.originalName,
                columnKey(originalName) != columnKey(target.name),
                sourceByName[columnKey(originalName)] != nil
            else { continue }
            let sourceColumn = columnKey(originalName)
            guard explicitClaims[sourceColumn] == nil else {
                throw SwiftDataError.migrationUnsupported(
                    "Multiple destination attributes claim original name \(originalName).")
            }
            explicitClaims[sourceColumn] = target
        }
        let claimedSources = Set(explicitClaims.keys)
        return destination.attributes.map { target in
            if let originalName = target.originalName,
                columnKey(originalName) != columnKey(target.name),
                let source = sourceByName[columnKey(originalName)]
            {
                return AttributeMapping(source: source, destination: target)
            }
            if let source = sourceByName[columnKey(target.name)], !claimedSources.contains(columnKey(source.name)) {
                return AttributeMapping(source: source, destination: target)
            }
            return AttributeMapping(source: nil, destination: target)
        }
    }

    private static func removeCombinedScalarAndRelationshipColumns(
        mappings: [AttributeMapping],
        removedRelationships: [Schema.Relationship],
        addedRelationships: [Schema.Relationship],
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceEntities: [Schema.Entity],
        destinationEntities: [Schema.Entity],
        sourceEntityIDs: [String: Int],
        destinationEntityIDs: [String: Int],
        existingColumns: Set<String>,
        connection: SQLConnection
    ) throws -> Bool {
        let mappedSourceNames = Set(mappings.compactMap { $0.source?.name })
        let removedAttributes = source.attributes.filter { !mappedSourceNames.contains($0.name) }
        let addedMappings = mappings.filter { $0.source == nil }
        guard (!removedAttributes.isEmpty || !addedMappings.isEmpty), !removedRelationships.isEmpty else {
            return false
        }

        let removedRelationshipNames = Set(removedRelationships.map(\.name))
        let retainedRelationships = source.relationships.filter { !removedRelationshipNames.contains($0.name) }
        let sourceSchema = Schema(sourceEntities)
        let destinationSchema = Schema(destinationEntities)
        guard addedRelationships.isEmpty,
            try mappings.allSatisfy({ mapping in
                guard let old = mapping.source else {
                    let attribute = mapping.destination
                    let defaultLiteral = try migrationDefaultLiteral(for: attribute)
                    return (attribute.isOptional || defaultLiteral != nil)
                        && attribute.originalName == nil
                        && attribute.components.isEmpty
                        && !attribute.options.contains(.unique)
                        && !attribute.options.contains(.codable)
                        && !attribute.options.contains(.flattened)
                        && !attribute.options.contains(.externalStorage)
                        && !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
                }
                return old == mapping.destination
            }),
            mappings.count == destination.attributes.count,
            destination.relationships.count == retainedRelationships.count,
            retainedRelationships.allSatisfy({ destination.relationships.contains($0) }),
            destination.relationships.allSatisfy({ retainedRelationships.contains($0) }),
            removedRelationships.allSatisfy({ relationship in
                !relationship.isToMany
                    && relationship.isOptional
                    && relationship.inverse == nil
                    && relationship.originalName == nil
                    && (relationship.minimumModelCount == nil || relationship.minimumModelCount == 0)
                    && (relationship.maximumModelCount == nil || relationship.maximumModelCount == 1)
                    && (relationship.deleteRule == .nullify || relationship.deleteRule == .noAction)
                    && relationship.destination != source.name
            }),
            source.name == destination.name,
            source.superentityName == nil,
            destination.superentityName == nil,
            !sourceEntities.contains(where: { $0.superentityName == source.name }),
            !destinationEntities.contains(where: { $0.superentityName == destination.name }),
            sourceEntityIDs == destinationEntityIDs,
            Set(sourceEntities.map(\.name)) == Set(destinationEntities.map(\.name)),
            sourceEntities.allSatisfy({ sourceEntity in
                guard let destinationEntity = destinationEntities.first(where: { $0.name == sourceEntity.name }) else {
                    return false
                }
                if sourceEntity.name == source.name {
                    let retainedSourceAttributes = sourceEntity.attributes.filter { !removedAttributes.contains($0) }
                    let addedAttributes = addedMappings.map(\.destination)
                    return sourceEntity.superentityName == destinationEntity.superentityName
                        && retainedSourceAttributes.count + addedAttributes.count == destinationEntity.attributes.count
                        && retainedSourceAttributes.allSatisfy({ destinationEntity.attributes.contains($0) })
                        && addedAttributes.allSatisfy({ destinationEntity.attributes.contains($0) })
                        && sourceEntity.relationships.filter({ !removedRelationshipNames.contains($0.name) })
                            == destinationEntity.relationships
                }
                return equivalentEntityMetadata(sourceEntity, destinationEntity)
            }),
            sourceEntities.allSatisfy({
                $0.name == source.name || $0.relationships == destinationSchema.entity(forName: $0.name)?.relationships
            }),
            destinationEntities.allSatisfy({
                $0.name == destination.name || $0.relationships == sourceSchema.entity(forName: $0.name)?.relationships
            }),
            removedAttributes.allSatisfy({ attribute in
                attribute.components.isEmpty
                    && !attribute.options.contains(.unique)
                    && !attribute.options.contains(.codable)
                    && !attribute.options.contains(.flattened)
                    && !attribute.options.contains(.externalStorage)
                    && !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
            }),
            !destination.attributes.contains(where: { attribute in
                attribute.originalName.map({ removedAttributes.map(\.name).contains($0) }) ?? false
            })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Combined removals require unchanged retained metadata and optional owning to-one relationships.")
        }

        let removedColumns = Set(
            removedAttributes.map { "Z\($0.name.uppercased())" }
                + removedRelationships.compactMap { relationship -> String? in
                    guard
                        let mapping = sourceSchema.relationshipStorageMapping(
                            modelEntityName: source.name, relationshipName: relationship.name)
                    else { return nil }
                    return "Z\(mapping.storageColumnName.uppercased())"
                })
        guard removedColumns.count == removedAttributes.count + removedRelationships.count,
            removedColumns.isSubset(of: existingColumns),
            Database.sqliteLibVersionNumber >= 3_035_000
        else {
            throw SwiftDataError.migrationUnsupported(
                "Combined removals require existing columns and SQLite 3.35 or newer.")
        }

        let sourceIndexes = indexDefinitions(for: source, schema: sourceSchema)
        let destinationIndexes = indexDefinitions(for: destination, schema: destinationSchema)
        let uniqueSource = sourceIndexes.filter { $0.statement.hasPrefix("CREATE UNIQUE INDEX") }
        let uniqueDestination = destinationIndexes.filter { $0.statement.hasPrefix("CREATE UNIQUE INDEX") }
        guard uniqueSource.count == uniqueDestination.count,
            uniqueSource.allSatisfy({ uniqueDestination.contains($0) }),
            destinationIndexes.allSatisfy({ !$0.columns.contains(where: { removedColumns.contains($0.uppercased()) }) })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Combined removals cannot change unique constraints or retain indexes on removed columns.")
        }

        try validateColumnRemovalSideEffects(
            table: "Z\(source.name.uppercased())",
            entity: source,
            schema: sourceSchema,
            removedColumns: removedColumns,
            connection: connection)
        try validateGeneratedIndexesForAttributeRemoval(
            table: "Z\(source.name.uppercased())",
            definitions: sourceIndexes,
            connection: connection)
        let removableIndexNames = Set(
            sourceIndexes.filter { definition in
                definition.columns.contains(where: { removedColumns.contains($0.uppercased()) })
                    && !definition.statement.hasPrefix("CREATE UNIQUE INDEX")
            }.map { $0.name.uppercased() })
        let knownIndexNames = Set(sourceIndexes.map { $0.name.uppercased() })
        let physicalIndexes = try connection.rows(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? COLLATE NOCASE",
            [.text("Z\(source.name.uppercased())")])
        for row in physicalIndexes {
            guard case let .text(name)? = row.first, knownIndexNames.contains(name.uppercased()) else {
                throw SwiftDataError.migrationUnsupported(
                    "Combined removal cannot preserve an untracked index on \(source.name).")
            }
        }
        for attribute in removedAttributes {
            try validateIndexesForAttributeRemoval(
                table: "Z\(source.name.uppercased())",
                column: "Z\(attribute.name.uppercased())",
                removableIndexNames: removableIndexNames,
                knownIndexNames: knownIndexNames,
                connection: connection)
        }
        for relationship in removedRelationships {
            let mapping = try validatedRemovedRelationshipMapping(
                relationship, owner: source, sourceSchema: sourceSchema)
            try validateOptionalRelationshipColumnRemoval(
                table: "Z\(source.name.uppercased())",
                column: "Z\(mapping.storageColumnName.uppercased())",
                relationship: relationship,
                owner: source,
                schema: sourceSchema,
                connection: connection,
                validatePhysicalLayout: false)
        }

        for indexName in removableIndexNames.sorted() {
            try connection.execute("DROP INDEX IF EXISTS \(indexName)")
        }
        for column in removedColumns.sorted() {
            try connection.execute("ALTER TABLE Z\(source.name.uppercased()) DROP COLUMN \(column)")
        }
        for attribute in addedMappings.map(\.destination).sorted(by: {
            $0.name.utf8.lexicographicallyPrecedes($1.name.utf8)
        }) {
            let defaultLiteral = try migrationDefaultLiteral(for: attribute)
            guard attribute.isOptional || defaultLiteral != nil else {
                throw SwiftDataError.migrationUnsupported(
                    "Adding required attribute \(destination.name).\(attribute.name) requires a literal default.")
            }
            let type = try SQLColumnType.resolve(
                attribute.type, property: "\(destination.name).\(attribute.name)", options: attribute.options)
            let required = attribute.isOptional ? "" : " NOT NULL"
            let defaultSQL = defaultLiteral.map { " DEFAULT \($0)" } ?? ""
            try connection.execute(
                "ALTER TABLE Z\(source.name.uppercased()) ADD COLUMN Z\(attribute.name.uppercased()) "
                    + "\(type.rawValue)\(required)\(defaultSQL)")
        }
        return true
    }

    private static func addScalarsWithOwnerOnlyToManyRemoval(
        mappings: [AttributeMapping],
        removedRelationships: [Schema.Relationship],
        addedRelationships: [Schema.Relationship],
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceEntities: [Schema.Entity],
        destinationEntities: [Schema.Entity],
        sourceEntityIDs: [String: Int],
        destinationEntityIDs: [String: Int],
        connection: SQLConnection
    ) throws -> Bool {
        let addedAttributes = mappings.filter { $0.source == nil }.map(\.destination)
        guard !addedAttributes.isEmpty,
            removedRelationships.count == 1,
            removedRelationships[0].isToMany
        else { return false }
        guard
            addedRelationships.isEmpty,
            let relationship = removedRelationships.first,
            source.relationships.filter({ $0.name != relationship.name }) == destination.relationships,
            source.name == destination.name,
            source.superentityName == nil,
            destination.superentityName == nil,
            !sourceEntities.contains(where: { $0.superentityName == source.name }),
            !destinationEntities.contains(where: { $0.superentityName == destination.name }),
            sourceEntityIDs == destinationEntityIDs,
            Set(sourceEntities.map(\.name)) == Set(destinationEntities.map(\.name)),
            sourceEntities.allSatisfy({ sourceEntity in
                guard let destinationEntity = destinationEntities.first(where: { $0.name == sourceEntity.name }) else {
                    return false
                }
                if sourceEntity.name == source.name {
                    return sourceEntity.attributes.allSatisfy({ destinationEntity.attributes.contains($0) })
                        && addedAttributes.allSatisfy({ destinationEntity.attributes.contains($0) })
                        && destinationEntity.attributes.count == sourceEntity.attributes.count + addedAttributes.count
                        && sourceEntity.relationships.filter({ $0.name != relationship.name })
                            == destinationEntity.relationships
                }
                return equivalentEntityMetadata(sourceEntity, destinationEntity)
            }),
            source.attributes.count == mappings.compactMap({ $0.source }).count,
            try mappings.allSatisfy({ mapping in
                if let old = mapping.source { return old == mapping.destination }
                let attribute = mapping.destination
                let literal = try migrationDefaultLiteral(for: attribute)
                return (attribute.isOptional || literal != nil)
                    && attribute.originalName == nil
                    && !attribute.options.contains(.unique)
                    && attribute.components.isEmpty
                    && !attribute.options.contains(.codable)
                    && !attribute.options.contains(.flattened)
                    && !attribute.options.contains(.externalStorage)
                    && !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
            }),
            addedAttributes.allSatisfy({ attribute in
                attribute.originalName == nil
                    && attribute.components.isEmpty
                    && !attribute.options.contains(.unique)
                    && !attribute.options.contains(.codable)
                    && !attribute.options.contains(.flattened)
                    && !attribute.options.contains(.externalStorage)
                    && !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
            }),
            source.attributes.allSatisfy({ old in destination.attributes.contains(old) }),
            source.indexes.filter(\.isUnique).count == destination.indexes.filter(\.isUnique).count,
            source.indexes.filter(\.isUnique).allSatisfy({ destination.indexes.contains($0) }),
            Set(source.attributes.filter({ $0.options.contains(.unique) }).map(\.name))
                == Set(destination.attributes.filter({ $0.options.contains(.unique) }).map(\.name))
        else {
            throw SwiftDataError.migrationUnsupported(
                "To-many removal with scalar additions requires unchanged flat metadata and literal defaults.")
        }

        for attribute in addedAttributes {
            _ = try SQLColumnType.resolve(
                attribute.type, property: "\(destination.name).\(attribute.name)", options: attribute.options)
            _ = try migrationDefaultLiteral(for: attribute)
        }
        let sourceSchema = Schema(sourceEntities)
        let destinationSchema = Schema(destinationEntities)
        let table = "Z\(source.name.uppercased())"
        let existingColumns = try tableColumns(table, connection: connection)
        let addedColumnNames = Set(addedAttributes.map { "Z\($0.name.uppercased())" })
        guard addedColumnNames.count == addedAttributes.count,
            addedColumnNames.isDisjoint(with: existingColumns)
        else {
            throw SwiftDataError.migrationUnsupported("Added scalar columns collide with the physical source table.")
        }
        try validateSourceTableLayout(source, schema: sourceSchema, connection: connection)
        _ = try validateSourceIndexLayout(sourceSchema, connection: connection)
        let sourceIndexDefinitions = indexDefinitions(for: source, schema: Schema(sourceEntities))
        let destinationIndexDefinitions = indexDefinitions(for: destination, schema: Schema(destinationEntities))
        let destinationIndexNames = Set(destinationIndexDefinitions.map { $0.name.uppercased() })
        let sourceIndexNames = Set(sourceIndexDefinitions.map { $0.name.uppercased() })
        guard
            destinationIndexNames.subtracting(sourceIndexNames).allSatisfy({ newName in
                sourceIndexDefinitions.allSatisfy({ $0.name.uppercased() != newName })
            })
        else {
            throw SwiftDataError.migrationUnsupported("Destination index names collide during to-many removal.")
        }
        guard
            let plan = try planOwnerOnlyToManyRemoval(
                source: source,
                destination: destination,
                sourceSchema: sourceSchema,
                destinationSchema: destinationSchema,
                relationship: relationship,
                addedAttributes: addedAttributes,
                connection: connection)
        else {
            throw SwiftDataError.migrationUnsupported("To-many relationship removal could not be planned.")
        }

        try validateDestinationIndexNames(Schema(destinationEntities))

        try applyOwnerOnlyToManyRemoval(plan, connection: connection)
        try addPlannedScalarColumns(addedAttributes, source: source, destination: destination, connection: connection)
        return true
    }

    private static func validateAttributeColumns(
        _ mappings: [AttributeMapping],
        destination: Schema.Entity,
        existing: Set<String>
    ) throws {
        let reserved = Set(["Z_PK", "Z_ENT", "Z_OPT"].map { $0.uppercased() })
        let targetColumns = mappings.map { "Z\($0.destination.name.uppercased())" }
        guard Set(targetColumns).count == targetColumns.count,
            Set(targetColumns).isDisjoint(with: reserved)
        else {
            throw SwiftDataError.migrationUnsupported("Destination attribute columns collide in \(destination.name).")
        }
        for mapping in mappings {
            guard let source = mapping.source, source.name != mapping.destination.name else { continue }
            let sourceColumn = "Z\(source.name.uppercased())"
            let targetColumn = "Z\(mapping.destination.name.uppercased())"
            guard existing.contains(sourceColumn) else {
                throw SwiftDataError.migrationUnsupported("Rename source column \(sourceColumn) does not exist.")
            }
            let targetVacated = mappings.contains { candidate in
                guard let candidateSource = candidate.source else { return false }
                return candidateSource.name.caseInsensitiveCompare(mapping.destination.name) == .orderedSame
                    && candidate.destination.name.caseInsensitiveCompare(mapping.destination.name) != .orderedSame
            }
            guard !existing.contains(targetColumn) || targetVacated else {
                throw SwiftDataError.migrationUnsupported(
                    "Attribute rename collision for \(destination.name).\(mapping.destination.name).")
            }
        }
    }

    private static func orderedRenames(_ mappings: [AttributeMapping]) throws -> [(String, String)] {
        var remaining = mappings.compactMap { mapping -> (String, String)? in
            guard let source = mapping.source, source.name != mapping.destination.name else { return nil }
            return (source.name, mapping.destination.name)
        }
        var result: [(String, String)] = []
        while !remaining.isEmpty {
            let sources = Set(remaining.map(\.0).map { $0.uppercased() })
            guard let index = remaining.firstIndex(where: { !sources.contains($0.1.uppercased()) }) else {
                throw SwiftDataError.migrationUnsupported("Attribute rename cycles require a table rebuild.")
            }
            result.append(remaining.remove(at: index))
        }
        return result
    }

    private static func migrate(
        entity source: Schema.Entity,
        to destination: Schema.Entity,
        sourceEntities: [Schema.Entity],
        destinationEntities: [Schema.Entity],
        sourceEntityIDs: [String: Int],
        destinationEntityIDs: [String: Int],
        pairedInverseRemovals: [PairedInverseRelationshipRemoval],
        toManyRemovalPlan: OwnerOnlyToManyRemovalBatchPlan?,
        indexTransitions: inout [([IndexDefinition], [IndexDefinition])],
        connection: SQLConnection
    ) throws {
        let table = "Z\(source.name.uppercased())"
        let existing = try tableColumns(table, connection: connection)
        let mappings = try attributeMappings(source: source, destination: destination)
        try validateAttributeColumns(mappings, destination: destination, existing: existing)
        let mappedRelationshipSources = Set(
            destination.relationships.compactMap { relationship in
                source.relationships.first(where: { sourceRelationship in
                    sourceRelationship.name.caseInsensitiveCompare(relationship.name) == .orderedSame
                        || relationship.originalName.map { originalName in
                            sourceRelationship.name.caseInsensitiveCompare(originalName) == .orderedSame
                        } == true
                })?.name
            })
        let removedRelationships = source.relationships.filter { !mappedRelationshipSources.contains($0.name) }
        let removedRelationshipNames = Set(removedRelationships.map(\.name))
        let addedRelationships = destination.relationships.filter { relationship in
            !source.relationships.contains(where: { sourceRelationship in
                sourceRelationship.name.caseInsensitiveCompare(relationship.name) == .orderedSame
                    || (relationship.originalName.map {
                        sourceRelationship.name.caseInsensitiveCompare($0) == .orderedSame
                    } == true && !removedRelationshipNames.contains(sourceRelationship.name))
            })
        }
        if try addScalarsWithOwnerOnlyToManyRemoval(
            mappings: mappings,
            removedRelationships: removedRelationships,
            addedRelationships: addedRelationships,
            source: source,
            destination: destination,
            sourceEntities: sourceEntities,
            destinationEntities: destinationEntities,
            sourceEntityIDs: sourceEntityIDs,
            destinationEntityIDs: destinationEntityIDs,
            connection: connection)
        {
            indexTransitions.append(
                (
                    indexDefinitions(for: source, schema: Schema(sourceEntities)),
                    indexDefinitions(for: destination, schema: Schema(destinationEntities))
                ))
            return
        }
        let plannedToManyRemovals = toManyRemovalPlan?.removedRelationshipNamesByOwner[source.name] ?? []
        let plannedAdditions = toManyRemovalPlan?.addedAttributesByOwner[source.name] ?? []
        if !plannedToManyRemovals.isEmpty, !plannedAdditions.isEmpty {
            let removedNames = Set(removedRelationships.map(\.name))
            let addedNames = Set(mappings.filter { $0.source == nil }.map { $0.destination.name })
            guard removedNames == plannedToManyRemovals,
                source.attributes.allSatisfy(destination.attributes.contains),
                destination.attributes.count == source.attributes.count + plannedAdditions.count,
                plannedAdditions.allSatisfy(destination.attributes.contains),
                addedRelationships.isEmpty,
                source.indexes == destination.indexes,
                source.superentityName == destination.superentityName,
                addedNames == Set(plannedAdditions.map(\.name))
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Batched to-many removal with scalar additions does not match the global plan.")
            }
            return
        }
        if !plannedToManyRemovals.isEmpty {
            let removedNames = Set(removedRelationships.map(\.name))
            guard removedNames == plannedToManyRemovals,
                plannedAdditions.isEmpty,
                addedRelationships.isEmpty,
                source.attributes == destination.attributes,
                source.indexes == destination.indexes,
                source.superentityName == destination.superentityName
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Batched to-many removals cannot be combined with other entity edits.")
            }
            return
        }
        if try removeCombinedScalarAndRelationshipColumns(
            mappings: mappings,
            removedRelationships: removedRelationships,
            addedRelationships: addedRelationships,
            source: source,
            destination: destination,
            sourceEntities: sourceEntities,
            destinationEntities: destinationEntities,
            sourceEntityIDs: sourceEntityIDs,
            destinationEntityIDs: destinationEntityIDs,
            existingColumns: existing,
            connection: connection)
        {
            indexTransitions.append(
                (
                    indexDefinitions(for: source, schema: Schema(sourceEntities)),
                    indexDefinitions(for: destination, schema: Schema(destinationEntities))
                ))
            return
        }
        if removedRelationships.count > 1,
            addedRelationships.isEmpty,
            removedRelationships.allSatisfy({ !$0.isToMany })
        {
            guard
                !destination.relationships.contains(where: {
                    $0.originalName.map(removedRelationshipNames.contains) == true
                        || removedRelationshipNames.contains($0.name)
                })
            else {
                throw SwiftDataError.migrationUnsupported(
                    "A relationship rename cannot be combined with multiple relationship removals.")
            }
            let sourceSchema = Schema(sourceEntities)
            let destinationSchema = Schema(destinationEntities)
            let removals = try planOptionalToOneRelationshipRemovals(
                removedRelationships,
                addedRelationships: addedRelationships,
                source: source,
                destination: destination,
                sourceSchema: sourceSchema,
                destinationSchema: destinationSchema)
            guard Database.sqliteLibVersionNumber >= 3_035_000,
                removals.allSatisfy({ existing.contains($0.column) })
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Relationship removal requires existing root foreign-key columns and SQLite 3.35 or newer.")
            }
            try validateColumnRemovalSideEffects(
                table: table,
                entity: source,
                schema: sourceSchema,
                removedColumns: Set(removals.map(\.column)),
                connection: connection)
            for removal in removals {
                try validateOptionalRelationshipColumnRemoval(
                    table: table,
                    column: removal.column,
                    relationship: removal.relationship,
                    owner: source,
                    schema: sourceSchema,
                    connection: connection,
                    validatePhysicalLayout: false)
            }
            for removal in removals.sorted(by: { $0.indexName < $1.indexName }) {
                try connection.execute("DROP INDEX IF EXISTS \(removal.indexName)")
            }
            for removal in removals.sorted(by: { $0.column < $1.column }) {
                try connection.execute("ALTER TABLE \(table) DROP COLUMN \(removal.column)")
            }
            indexTransitions.append(
                (
                    indexDefinitions(for: source, schema: sourceSchema),
                    indexDefinitions(for: destination, schema: destinationSchema)
                ))
            return
        }
        if let optionalityChanges = try optionalToRequiredAttributeChanges(
            mappings,
            source: source,
            destination: destination,
            sourceEntities: sourceEntities,
            destinationEntities: destinationEntities,
            sourceEntityIDs: sourceEntityIDs,
            destinationEntityIDs: destinationEntityIDs)
        {
            let backfills = try optionalityChanges.sorted {
                $0.destination.name.utf8.lexicographicallyPrecedes($1.destination.name.utf8)
            }.map { mapping -> (mapping: AttributeMapping, literal: String, column: String) in
                guard let literal = try migrationDefaultLiteral(for: mapping.destination), literal != "NULL" else {
                    throw SwiftDataError.migrationUnsupported(
                        "Making attribute \(destination.name).\(mapping.destination.name) required requires a non-NULL literal default."
                    )
                }
                guard let old = mapping.source,
                    try SQLColumnType.resolve(
                        old.type, property: "\(source.name).\(old.name)", options: old.options)
                        == SQLColumnType.resolve(
                            mapping.destination.type,
                            property: "\(destination.name).\(mapping.destination.name)",
                            options: mapping.destination.options)
                else {
                    throw SwiftDataError.migrationUnsupported(
                        "Optional-to-required backfill changed storage affinity for \(destination.name).\(mapping.destination.name)."
                    )
                }
                let column = "Z\(mapping.destination.name.uppercased())"
                try validateOptionalityBackfillSideEffects(table: table, column: column, connection: connection)
                return (mapping, literal, column)
            }
            for backfill in backfills {
                do {
                    try connection.execute(
                        "UPDATE \(table) SET \(backfill.column) = \(backfill.literal) WHERE \(backfill.column) IS NULL")
                } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                    throw SwiftDataError.migrationUnsupported(
                        "Backfilling \(destination.name).\(backfill.mapping.destination.name) violates a uniqueness constraint."
                    )
                }
                let nullRows = try connection.rows("SELECT COUNT(*) FROM \(table) WHERE \(backfill.column) IS NULL")
                guard case let .int(count)? = nullRows.first?.first, count == 0 else {
                    throw SwiftDataError.migrationUnsupported(
                        "Required attribute \(destination.name).\(backfill.mapping.destination.name) still contains NULL values."
                    )
                }
            }
            indexTransitions.append(
                (
                    indexDefinitions(for: source, schema: Schema(sourceEntities)),
                    indexDefinitions(for: destination, schema: Schema(destinationEntities))
                ))
            return
        }
        if let optionalityChange = try requiredToOptionalAttributeChange(
            mappings,
            source: source,
            destination: destination,
            sourceEntities: sourceEntities,
            destinationEntities: destinationEntities,
            sourceEntityIDs: sourceEntityIDs,
            destinationEntityIDs: destinationEntityIDs)
        {
            guard let old = optionalityChange.source,
                try SQLColumnType.resolve(
                    old.type, property: "\(source.name).\(old.name)", options: old.options)
                    == SQLColumnType.resolve(
                        optionalityChange.destination.type,
                        property: "\(destination.name).\(optionalityChange.destination.name)",
                        options: optionalityChange.destination.options)
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Required-to-optional scalar storage affinity changed unexpectedly.")
            }
            try validateFlatOptionalityDDLCompatibility(
                source: Schema(sourceEntities), destination: Schema(destinationEntities))
            indexTransitions.append(
                (
                    indexDefinitions(for: source, schema: Schema(sourceEntities)),
                    indexDefinitions(for: destination, schema: Schema(destinationEntities))
                ))
            return
        }
        if try compatibleIntegerWidening(
            mappings,
            source: source,
            destination: destination,
            sourceEntities: sourceEntities,
            destinationEntities: destinationEntities,
            sourceEntityIDs: sourceEntityIDs,
            destinationEntityIDs: destinationEntityIDs)
        {
            indexTransitions.append(
                (
                    indexDefinitions(for: source, schema: Schema(sourceEntities)),
                    indexDefinitions(for: destination, schema: Schema(destinationEntities))
                ))
            return
        }
        let changedTypeMappings = mappings.filter { mapping in
            guard let old = mapping.source else { return false }
            return old.type != mapping.destination.type
        }
        if changedTypeMappings.count > 1,
            let conversions = try compatibleExactNumericRebuilds(
                mappings,
                source: source,
                destination: destination,
                sourceEntities: sourceEntities,
                destinationEntities: destinationEntities,
                sourceEntityIDs: sourceEntityIDs,
                destinationEntityIDs: destinationEntityIDs)
        {
            let sourceSchema = Schema(sourceEntities)
            let destinationSchema = Schema(destinationEntities)
            try validateRebuildIndexPlan(
                table: table,
                source: source,
                destination: destination,
                sourceSchema: sourceSchema,
                destinationSchema: destinationSchema,
                connection: connection)
            for (mapping, conversion) in conversions {
                guard let old = mapping.source else {
                    throw SwiftDataError.migrationUnsupported("Numeric rebuild conversion has no source attribute.")
                }
                let column = "Z\(old.name.uppercased())"
                switch conversion {
                case .signedIntegerToFloating:
                    try validateIntegerValuesForFloatingConversion(
                        table: table,
                        column: column,
                        destinationType: mapping.destination.type,
                        isOptional: old.isOptional,
                        connection: connection)
                case .floatingToSignedInteger:
                    try validateFloatingValuesForIntegerConversion(
                        table: table,
                        column: column,
                        destinationType: mapping.destination.type,
                        isOptional: old.isOptional,
                        connection: connection)
                }
            }
            try rebuildTable(
                source: source,
                destination: destination,
                destinationSchema: destinationSchema,
                conversions: conversions.compactMap { mapping, conversion in
                    guard let old = mapping.source else { return nil }
                    return RebuildColumnConversion(
                        column: "Z\(old.name.uppercased())", conversion: conversion)
                },
                connection: connection)
            return
        }
        let hasFloatingToIntegerMapping = changedTypeMappings.contains { mapping in
            guard let old = mapping.source else { return false }
            return (old.type == "Float" || old.type == "Double")
                && signedIntegerWidth(mapping.destination.type) != nil
        }
        guard !hasFloatingToIntegerMapping || changedTypeMappings.count == 1 else {
            throw SwiftDataError.migrationUnsupported(
                "Floating-to-integer rebuild cannot be combined with another type change.")
        }
        let hasIntegerToFloatingMapping = changedTypeMappings.contains { mapping in
            guard let old = mapping.source else { return false }
            return signedIntegerWidth(old.type) != nil
                && (mapping.destination.type == "Float" || mapping.destination.type == "Double")
        }
        guard !hasIntegerToFloatingMapping || changedTypeMappings.count == 1 else {
            throw SwiftDataError.migrationUnsupported(
                "Integer-to-floating rebuild cannot be combined with another type change.")
        }
        if let narrowings = try compatibleIntegerNarrowings(
            mappings,
            source: source,
            destination: destination,
            sourceEntities: sourceEntities,
            destinationEntities: destinationEntities,
            sourceEntityIDs: sourceEntityIDs,
            destinationEntityIDs: destinationEntityIDs)
        {
            for narrowing in narrowings {
                try validateStoredIntegerRange(
                    table: table,
                    column: "Z\(narrowing.destination.name.uppercased())",
                    destinationType: narrowing.destination.type,
                    isOptional: narrowing.destination.isOptional,
                    connection: connection)
            }
            indexTransitions.append(
                (
                    indexDefinitions(for: source, schema: Schema(sourceEntities)),
                    indexDefinitions(for: destination, schema: Schema(destinationEntities))
                ))
            return
        }
        if let integerToFloating = try compatibleIntegerToFloating(
            mappings,
            source: source,
            destination: destination,
            sourceEntities: sourceEntities,
            destinationEntities: destinationEntities,
            sourceEntityIDs: sourceEntityIDs,
            destinationEntityIDs: destinationEntityIDs)
        {
            try rebuildIntegerColumnAsFloating(
                attribute: integerToFloating,
                source: source,
                destination: destination,
                sourceSchema: Schema(sourceEntities),
                destinationSchema: Schema(destinationEntities),
                connection: connection)
            return
        }
        if let floatingToInteger = try compatibleFloatingToInteger(
            mappings,
            source: source,
            destination: destination,
            sourceEntities: sourceEntities,
            destinationEntities: destinationEntities,
            sourceEntityIDs: sourceEntityIDs,
            destinationEntityIDs: destinationEntityIDs)
        {
            try rebuildFloatingColumnAsInteger(
                attribute: floatingToInteger,
                source: source,
                destination: destination,
                sourceSchema: Schema(sourceEntities),
                destinationSchema: Schema(destinationEntities),
                connection: connection)
            return
        }
        if let floatingTypeChange = try compatibleFloatTypeChange(
            mappings,
            source: source,
            destination: destination,
            sourceEntities: sourceEntities,
            destinationEntities: destinationEntities,
            sourceEntityIDs: sourceEntityIDs,
            destinationEntityIDs: destinationEntityIDs)
        {
            let column = "Z\(floatingTypeChange.destination.name.uppercased())"
            try validateFloatValuesForWidening(
                table: table,
                column: column,
                isOptional: floatingTypeChange.source?.isOptional ?? false,
                requiresExactFloatRoundTrip: true,
                connection: connection)
            indexTransitions.append(
                (
                    indexDefinitions(for: source, schema: Schema(sourceEntities)),
                    indexDefinitions(for: destination, schema: Schema(destinationEntities))
                ))
            return
        }
        if let removedAttributes = try removableScalarAttributes(
            mappings,
            source: source,
            destination: destination,
            sourceEntities: sourceEntities,
            destinationEntities: destinationEntities,
            sourceEntityIDs: sourceEntityIDs,
            destinationEntityIDs: destinationEntityIDs)
        {
            guard Database.sqliteLibVersionNumber >= 3_035_000 else {
                throw SwiftDataError.migrationUnsupported("SQLite does not support dropping table columns.")
            }
            let removedAttributeNames = Set(removedAttributes.map(\.name))
            let removedPhysicalColumns = Set(
                removedAttributes.flatMap { attribute in
                    attribute.options.contains(.flattened)
                        ? attribute.components.map { "Z\($0.columnName.uppercased())" }
                        : ["Z\(attribute.name.uppercased())"]
                })
            try validateColumnRemovalSideEffects(
                table: table,
                entity: source,
                schema: Schema(sourceEntities),
                removedColumns: removedPhysicalColumns,
                connection: connection)
            let renamePlan = try orderedRenames(mappings)
            if !renamePlan.isEmpty {
                let renameNames = Set(renamePlan.flatMap { [$0.0.uppercased(), $0.1.uppercased()] })
                guard renameNames.isDisjoint(with: removedPhysicalColumns) else {
                    throw SwiftDataError.migrationUnsupported(
                        "A scalar rename cannot target or free a column removed in the same migration.")
                }
            }
            let sourceIndexDefinitions = indexDefinitions(for: source, schema: Schema(sourceEntities))
            let renameIndexNames = Set(
                sourceIndexDefinitions.compactMap { definition -> String? in
                    renamePlan.contains(where: { sourceName, _ in
                        definition.columns == ["Z\(sourceName.uppercased())"]
                            && definition.statement.hasPrefix("CREATE INDEX")
                    }) ? definition.name.uppercased() : nil
                })
            let removableIndexNames = Set(
                source.indexes.compactMap { index -> String? in
                    guard !index.properties.isEmpty,
                        index.properties.contains(where: { removedAttributeNames.contains($0) }),
                        !index.isUnique || index.properties.allSatisfy({ removedAttributeNames.contains($0) })
                    else { return nil }
                    let columns = index.properties.map { "Z\($0.uppercased())" }
                    return "Z\(source.name.uppercased())_\(columns.joined(separator: "_"))_INDEX"
                }
                    + removedAttributes.compactMap { attribute in
                        attribute.options.contains(.unique)
                            ? "Z\(source.name.uppercased())_Z\(attribute.name.uppercased())_UNIQUE_INDEX" : nil
                    }
                    + Array(renameIndexNames))
            let removedIndexDefinitions = sourceIndexDefinitions.filter {
                let name = $0.name.uppercased()
                return removableIndexNames.contains(name)
                    || renameIndexNames.contains(name)
            }
            try validateGeneratedIndexesForAttributeRemoval(
                table: table,
                definitions: indexDefinitions(for: source, schema: Schema(sourceEntities)),
                connection: connection)
            for column in removedPhysicalColumns {
                try validateIndexesForAttributeRemoval(
                    table: table,
                    column: column,
                    removableIndexNames: removableIndexNames,
                    knownIndexNames: Set(
                        indexDefinitions(for: source, schema: Schema(sourceEntities)).map {
                            $0.name.uppercased()
                        }),
                    connection: connection)
            }
            let knownIndexNames = Set(
                indexDefinitions(for: source, schema: Schema(sourceEntities)).map { $0.name.uppercased() })
            for attribute in removedAttributes where !attribute.options.contains(.flattened) {
                try validateIndexesForAttributeRemoval(
                    table: table,
                    column: "Z\(attribute.name.uppercased())",
                    removableIndexNames: removableIndexNames,
                    knownIndexNames: knownIndexNames,
                    connection: connection)
            }
            for definition in removedIndexDefinitions {
                try connection.execute("DROP INDEX IF EXISTS \(definition.name)")
            }
            for (sourceName, destinationName) in renamePlan {
                try connection.execute(
                    "ALTER TABLE \(table) RENAME COLUMN Z\(sourceName.uppercased()) TO Z\(destinationName.uppercased())"
                )
            }
            for attribute in removedAttributes.sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }) {
                let columns =
                    attribute.options.contains(.flattened)
                    ? attribute.components.map { "Z\($0.columnName.uppercased())" }
                    : ["Z\(attribute.name.uppercased())"]
                for column in columns.sorted() {
                    try connection.execute("ALTER TABLE \(table) DROP COLUMN \(column)")
                }
            }
            let addedAttributes = mappings.filter { $0.source == nil }.map(\.destination)
            for attribute in addedAttributes.sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }) {
                let defaultLiteral = try migrationDefaultLiteral(for: attribute)
                guard attribute.isOptional || defaultLiteral != nil else {
                    throw SwiftDataError.migrationUnsupported(
                        "Adding required attribute \(destination.name).\(attribute.name) requires a literal default.")
                }
                let type = try SQLColumnType.resolve(
                    attribute.type, property: "\(destination.name).\(attribute.name)", options: attribute.options)
                let required = attribute.isOptional ? "" : " NOT NULL"
                let defaultSQL = defaultLiteral.map { " DEFAULT \($0)" } ?? ""
                try connection.execute(
                    "ALTER TABLE \(table) ADD COLUMN Z\(attribute.name.uppercased()) \(type.rawValue)"
                        + "\(required)\(defaultSQL)")
            }
            indexTransitions.append(
                (
                    indexDefinitions(for: source, schema: Schema(sourceEntities)),
                    indexDefinitions(for: destination, schema: Schema(destinationEntities))
                ))
            return
        }
        for mapping in mappings {
            guard let old = mapping.source else { continue }
            let oldIsFlattened = old.options.contains(.flattened)
            let newIsFlattened = mapping.destination.options.contains(.flattened)
            let oldUsesExternalStorage = old.options.contains(.externalStorage)
            let newUsesExternalStorage = mapping.destination.options.contains(.externalStorage)
            guard oldIsFlattened == newIsFlattened,
                old.components == mapping.destination.components,
                oldUsesExternalStorage == newUsesExternalStorage
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Changing storage layout for \(destination.name).\(mapping.destination.name) requires an explicit migration."
                )
            }
        }
        let mappedSources = Set(mappings.compactMap { $0.source?.name })
        guard mappedSources.count == source.attributes.count else {
            throw SwiftDataError.migrationUnsupported(
                "Attribute removal requires an eligible unindexed scalar column.")
        }
        let renamePlan = try orderedRenames(mappings)
        let addedAttributes = mappings.filter { $0.source == nil }.map(\.destination)
        let addedColumnNames = Set(addedAttributes.map { "Z\($0.name.uppercased())" })
        guard addedColumnNames.count == addedAttributes.count,
            addedColumnNames.isDisjoint(with: existing)
        else {
            throw SwiftDataError.migrationUnsupported("Added scalar columns collide with the physical source table.")
        }
        for attribute in addedAttributes {
            let defaultLiteral = try migrationDefaultLiteral(for: attribute)
            guard attribute.isOptional || defaultLiteral != nil else {
                throw SwiftDataError.migrationUnsupported(
                    "Adding required attribute \(destination.name).\(attribute.name) requires a literal default.")
            }
            _ = try SQLColumnType.resolve(
                attribute.type, property: "\(destination.name).\(attribute.name)", options: attribute.options)
        }
        if !renamePlan.isEmpty {
            try validateSourceTableLayout(source, schema: Schema(sourceEntities), connection: connection)
            _ = try validateSourceIndexLayout(Schema(sourceEntities), connection: connection)
        }
        for (sourceName, destinationName) in renamePlan {
            try connection.execute(
                "ALTER TABLE \(table) RENAME COLUMN Z\(sourceName.uppercased()) TO Z\(destinationName.uppercased())")
        }

        for mapping in mappings {
            let attribute = mapping.destination
            guard let old = mapping.source else {
                let defaultLiteral = try migrationDefaultLiteral(for: attribute)
                guard attribute.isOptional || defaultLiteral != nil else {
                    throw SwiftDataError.migrationUnsupported(
                        "Adding required attribute \(destination.name).\(attribute.name) requires a literal default.")
                }
                let type = try SQLColumnType.resolve(
                    attribute.type, property: "\(destination.name).\(attribute.name)", options: attribute.options)
                let required = attribute.isOptional ? "" : " NOT NULL"
                let defaultSQL = defaultLiteral.map { " DEFAULT \($0)" } ?? ""
                try connection.execute(
                    "ALTER TABLE \(table) ADD COLUMN Z\(attribute.name.uppercased()) \(type.rawValue)"
                        + "\(required)\(defaultSQL)")
                continue
            }
            guard old.isOptional == attribute.isOptional else {
                throw SwiftDataError.migrationUnsupported(
                    "Optionality changes require an eligible literal-default backfill migration.")
            }
            guard old.type == attribute.type else {
                throw SwiftDataError.migrationUnsupported(
                    "Attribute type change requires a table rebuild for \(destination.name).\(attribute.name).")
            }
        }
        try migrateRelationships(
            source: source, destination: destination,
            sourceSchema: Schema(sourceEntities), schema: Schema(destinationEntities),
            pairedInverseRemovals: pairedInverseRemovals,
            toManyRemovalPlan: toManyRemovalPlan,
            connection: connection, existing: existing)
        indexTransitions.append(
            (
                indexDefinitions(for: source, schema: Schema(sourceEntities)),
                indexDefinitions(for: destination, schema: Schema(destinationEntities))
            ))
    }

    private static func optionalToRequiredAttributeChanges(
        _ mappings: [AttributeMapping],
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceEntities: [Schema.Entity],
        destinationEntities: [Schema.Entity],
        sourceEntityIDs: [String: Int],
        destinationEntityIDs: [String: Int]
    ) throws -> [AttributeMapping]? {
        let changes = mappings.filter { mapping in
            guard let source = mapping.source else { return false }
            return source.isOptional != mapping.destination.isOptional
        }.sorted { $0.destination.name.utf8.lexicographicallyPrecedes($1.destination.name.utf8) }
        guard !changes.isEmpty else { return nil }
        guard changes.contains(where: { $0.source?.isOptional == true && !$0.destination.isOptional }) else {
            return nil
        }
        guard
            changes.allSatisfy({ change in
                guard let oldAttribute = change.source else { return false }
                return oldAttribute.isOptional
                    && !change.destination.isOptional
                    && oldAttribute.name == change.destination.name
                    && oldAttribute.type == change.destination.type
                    && oldAttribute.options == change.destination.options
                    && oldAttribute.originalName == change.destination.originalName
                    && oldAttribute.components == change.destination.components
            }),
            mappings.count == source.attributes.count,
            mappings.count == destination.attributes.count,
            mappings.allSatisfy({ mapping in
                guard let old = mapping.source else { return false }
                return changes.contains(where: { $0.source?.name == old.name }) || old == mapping.destination
            }),
            source.name == destination.name,
            sourceEntities.count == destinationEntities.count,
            sourceEntityIDs == destinationEntityIDs,
            sourceEntities.allSatisfy({ sourceEntity in
                guard let destinationEntity = destinationEntities.first(where: { $0.name == sourceEntity.name }) else {
                    return false
                }
                if sourceEntity.name == source.name {
                    return sourceEntity.superentityName == destinationEntity.superentityName
                        && sourceEntity.relationships == destinationEntity.relationships
                        && sourceEntity.indexes == destinationEntity.indexes
                }
                return sourceEntity.superentityName == destinationEntity.superentityName
                    && sourceEntity.attributes.count == destinationEntity.attributes.count
                    && sourceEntity.attributes.allSatisfy { attribute in
                        destinationEntity.attributes.contains(attribute)
                    }
                    && sourceEntity.relationships == destinationEntity.relationships
                    && sourceEntity.indexes == destinationEntity.indexes
            }),
            source.superentityName == nil,
            destination.superentityName == nil,
            source.relationships.isEmpty,
            destination.relationships.isEmpty,
            source.indexes.filter(\.isUnique) == destination.indexes.filter(\.isUnique),
            sourceEntities.allSatisfy({ entity in
                guard let destinationEntity = destinationEntities.first(where: { $0.name == entity.name }) else {
                    return false
                }
                return entity.indexes.filter(\.isUnique) == destinationEntity.indexes.filter(\.isUnique)
                    && entity.attributes.filter({ $0.options.contains(.unique) }).map(\.name)
                        == destinationEntity.attributes.filter({ $0.options.contains(.unique) }).map(\.name)
            }),
            sourceEntities.allSatisfy({ $0.relationships.isEmpty }),
            destinationEntities.allSatisfy({ $0.relationships.isEmpty })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Optional-to-required migration must change only flat scalar attributes without other schema edits.")
        }
        for change in changes {
            _ = try SQLColumnType.resolve(
                change.destination.type,
                property: "\(destination.name).\(change.destination.name)",
                options: change.destination.options)
        }
        return changes
    }

    private static func requiredToOptionalAttributeChange(
        _ mappings: [AttributeMapping],
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceEntities: [Schema.Entity],
        destinationEntities: [Schema.Entity],
        sourceEntityIDs: [String: Int],
        destinationEntityIDs: [String: Int]
    ) throws -> AttributeMapping? {
        guard
            !mappings.contains(where: { mapping in
                guard let old = mapping.source else { return false }
                return old.type != mapping.destination.type
            })
        else { return nil }
        let changes = mappings.filter { mapping in
            guard let old = mapping.source else { return false }
            return old.isOptional != mapping.destination.isOptional
        }
        guard !changes.isEmpty else { return nil }
        guard changes.count == 1,
            let change = changes.first,
            let old = change.source,
            !old.isOptional,
            change.destination.isOptional,
            old.name == change.destination.name,
            old.type == change.destination.type,
            old.defaultValue == change.destination.defaultValue,
            old.options == change.destination.options,
            old.originalName == change.destination.originalName,
            old.components == change.destination.components,
            mappings.count == source.attributes.count,
            mappings.count == destination.attributes.count,
            mappings.allSatisfy({ mapping in
                guard let original = mapping.source else { return false }
                return original == old || original == mapping.destination
            }),
            source.name == destination.name,
            source.superentityName == nil,
            destination.superentityName == nil,
            source.relationships.isEmpty,
            destination.relationships.isEmpty,
            sourceEntityIDs == destinationEntityIDs,
            Set(sourceEntities.map(\.name)) == Set(destinationEntities.map(\.name)),
            sourceEntities.allSatisfy({ sourceEntity in
                guard let destinationEntity = destinationEntities.first(where: { $0.name == sourceEntity.name }) else {
                    return false
                }
                if sourceEntity.name == source.name {
                    let oldAttributes = sourceEntity.attributes.filter { $0.name != old.name }
                    let newAttributes = destinationEntity.attributes.filter { $0.name != change.destination.name }
                    return sourceEntity.indexes == destinationEntity.indexes
                        && sourceEntity.relationships == destinationEntity.relationships
                        && oldAttributes.count == newAttributes.count
                        && oldAttributes.allSatisfy({ newAttributes.contains($0) })
                }
                return equivalentEntityMetadata(sourceEntity, destinationEntity)
            }),
            sourceEntities.allSatisfy({ $0.relationships.isEmpty }),
            destinationEntities.allSatisfy({ $0.relationships.isEmpty }),
            sourceEntities.allSatisfy({ entity in
                entity.attributes.allSatisfy { attribute in
                    !attribute.options.contains(.codable)
                        && !attribute.options.contains(.flattened)
                        && !attribute.options.contains(.externalStorage)
                        && !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
                }
            }),
            destinationEntities.allSatisfy({ entity in
                entity.attributes.allSatisfy { attribute in
                    !attribute.options.contains(.codable)
                        && !attribute.options.contains(.flattened)
                        && !attribute.options.contains(.externalStorage)
                        && !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
                }
            }),
            !old.options.contains(.codable),
            !old.options.contains(.flattened),
            !old.options.contains(.externalStorage),
            !old.options.contains(where: { if case .transformable = $0 { true } else { false } }),
            try SQLColumnType.resolve(old.type, property: "\(source.name).\(old.name)", options: old.options)
                == SQLColumnType.resolve(
                    change.destination.type,
                    property: "\(destination.name).\(change.destination.name)",
                    options: change.destination.options)
        else {
            throw SwiftDataError.migrationUnsupported(
                "Required-to-optional migration must change one flat scalar attribute without other edits.")
        }
        return change
    }

    private static func compatibleIntegerWidening(
        _ mappings: [AttributeMapping],
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceEntities: [Schema.Entity],
        destinationEntities: [Schema.Entity],
        sourceEntityIDs: [String: Int],
        destinationEntityIDs: [String: Int]
    ) throws -> Bool {
        let changes = mappings.filter { mapping in
            guard let source = mapping.source else { return false }
            return source.type != mapping.destination.type
        }
        guard !changes.isEmpty else { return false }
        let hasSignedIntegerType = changes.contains { mapping in
            guard let old = mapping.source else { return false }
            return signedIntegerWidth(old.type) != nil || signedIntegerWidth(mapping.destination.type) != nil
        }
        guard hasSignedIntegerType,
            changes.contains(where: { mapping in
                guard let old = mapping.source,
                    let sourceWidth = signedIntegerWidth(old.type),
                    let destinationWidth = signedIntegerWidth(mapping.destination.type)
                else { return false }
                return destinationWidth > sourceWidth
            })
        else { return false }
        guard !changes.isEmpty,
            mappings.count == source.attributes.count,
            mappings.count == destination.attributes.count,
            try mappings.allSatisfy({ mapping in
                guard let old = mapping.source else { return false }
                if old.type == mapping.destination.type {
                    return old == mapping.destination
                }
                guard old.name == mapping.destination.name,
                    old.isOptional == mapping.destination.isOptional,
                    old.defaultValue == mapping.destination.defaultValue,
                    old.options == mapping.destination.options,
                    old.originalName == mapping.destination.originalName,
                    old.components.isEmpty,
                    mapping.destination.components.isEmpty,
                    let sourceWidth = signedIntegerWidth(old.type),
                    let destinationWidth = signedIntegerWidth(mapping.destination.type),
                    destinationWidth > sourceWidth,
                    !old.options.contains(.codable),
                    !old.options.contains(.flattened),
                    !old.options.contains(.externalStorage),
                    !old.options.contains(where: { if case .transformable = $0 { true } else { false } }),
                    try SQLColumnType.resolve(old.type, property: "\(source.name).\(old.name)", options: old.options)
                        == .integer,
                    try SQLColumnType.resolve(
                        mapping.destination.type,
                        property: "\(destination.name).\(mapping.destination.name)",
                        options: mapping.destination.options) == .integer
                else { return false }
                return true
            }),
            source.name == destination.name,
            sourceEntityIDs == destinationEntityIDs,
            sourceEntities.count == destinationEntities.count,
            sourceEntities.allSatisfy({ sourceEntity in
                guard let destinationEntity = destinationEntities.first(where: { $0.name == sourceEntity.name }) else {
                    return false
                }
                if sourceEntity.name == source.name {
                    return sourceEntity.superentityName == destinationEntity.superentityName
                        && sourceEntity.relationships == destinationEntity.relationships
                        && equivalentUniqueIndexes(sourceEntity.indexes, destinationEntity.indexes)
                }
                return sourceEntity.superentityName == destinationEntity.superentityName
                    && sourceEntity.attributes.count == destinationEntity.attributes.count
                    && sourceEntity.attributes.allSatisfy({ destinationEntity.attributes.contains($0) })
                    && sourceEntity.relationships == destinationEntity.relationships
                    && sourceEntity.indexes == destinationEntity.indexes
            }),
            source.superentityName == nil,
            destination.superentityName == nil
        else {
            throw SwiftDataError.migrationUnsupported(
                "Numeric widening must contain only compatible signed-integer widenings with unchanged storage metadata."
            )
        }
        return true
    }

    private static func compatibleIntegerNarrowings(
        _ mappings: [AttributeMapping],
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceEntities: [Schema.Entity],
        destinationEntities: [Schema.Entity],
        sourceEntityIDs: [String: Int],
        destinationEntityIDs: [String: Int]
    ) throws -> [AttributeMapping]? {
        let changes = mappings.filter { mapping in
            guard let old = mapping.source else { return false }
            return old.type != mapping.destination.type
        }.sorted { $0.destination.name.utf8.lexicographicallyPrecedes($1.destination.name.utf8) }
        guard !changes.isEmpty else { return nil }
        let hasSignedIntegerType = changes.contains { mapping in
            guard let old = mapping.source else { return false }
            return signedIntegerWidth(old.type) != nil || signedIntegerWidth(mapping.destination.type) != nil
        }
        let hasSignedNarrowing = changes.contains { mapping in
            guard let old = mapping.source,
                let sourceWidth = signedIntegerWidth(old.type),
                let destinationWidth = signedIntegerWidth(mapping.destination.type)
            else { return false }
            return destinationWidth < sourceWidth
        }
        guard hasSignedIntegerType, hasSignedNarrowing else { return nil }
        for change in changes {
            guard let oldAttribute = change.source,
                let sourceWidth = signedIntegerWidth(oldAttribute.type),
                let destinationWidth = signedIntegerWidth(change.destination.type),
                destinationWidth < sourceWidth,
                oldAttribute.name == change.destination.name,
                oldAttribute.isOptional == change.destination.isOptional,
                oldAttribute.defaultValue == change.destination.defaultValue,
                oldAttribute.options == change.destination.options,
                oldAttribute.originalName == change.destination.originalName,
                oldAttribute.components.isEmpty,
                change.destination.components.isEmpty,
                !oldAttribute.options.contains(.codable),
                !oldAttribute.options.contains(.flattened),
                !oldAttribute.options.contains(.externalStorage),
                !oldAttribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Numeric narrowing must contain only compatible signed-integer changes with unchanged storage metadata."
                )
            }
            guard
                try SQLColumnType.resolve(
                    oldAttribute.type, property: "\(source.name).\(oldAttribute.name)", options: oldAttribute.options)
                    == .integer,
                try SQLColumnType.resolve(
                    change.destination.type,
                    property: "\(destination.name).\(change.destination.name)",
                    options: change.destination.options) == .integer
            else {
                throw SwiftDataError.migrationUnsupported("Numeric narrowing changed SQL storage affinity.")
            }
        }
        guard
            mappings.count == source.attributes.count,
            mappings.count == destination.attributes.count,
            mappings.allSatisfy({ mapping in
                guard let old = mapping.source else { return false }
                return changes.contains(where: { $0.source?.name == old.name }) || old == mapping.destination
            }),
            source.name == destination.name,
            sourceEntityIDs == destinationEntityIDs,
            sourceEntities.count == destinationEntities.count,
            sourceEntities.allSatisfy({ sourceEntity in
                guard let destinationEntity = destinationEntities.first(where: { $0.name == sourceEntity.name }) else {
                    return false
                }
                if sourceEntity.name == source.name {
                    return sourceEntity.superentityName == destinationEntity.superentityName
                        && sourceEntity.relationships == destinationEntity.relationships
                        && equivalentUniqueIndexes(sourceEntity.indexes, destinationEntity.indexes)
                }
                return equivalentEntityMetadata(sourceEntity, destinationEntity)
            }),
            source.superentityName == nil,
            destination.superentityName == nil
        else {
            throw SwiftDataError.migrationUnsupported(
                "Numeric narrowing must contain only compatible signed-integer changes with unchanged storage metadata."
            )
        }
        return changes
    }

    private static func validateStoredIntegerRange(
        table: String,
        column: String,
        destinationType: String,
        isOptional: Bool,
        connection: SQLConnection
    ) throws {
        guard let width = signedIntegerWidth(destinationType) else {
            throw SwiftDataError.migrationUnsupported("Unsupported signed-integer destination type.")
        }
        let minimum = width == 64 ? Int64.min : -(Int64(1) << (width - 1))
        let maximum = width == 64 ? Int64.max : (Int64(1) << (width - 1)) - 1
        let rows = try connection.rows("SELECT typeof(\(column)), \(column) FROM \(table) ORDER BY Z_PK")
        for row in rows {
            guard row.count > 1, case let .text(storageType) = row[0] else {
                throw SwiftDataError.migrationUnsupported("Integer column \(column) has invalid storage metadata.")
            }
            switch (storageType, row[1]) {
            case ("null", .null) where isOptional:
                continue
            case ("null", .null):
                throw SwiftDataError.migrationUnsupported("Required integer column \(column) contains NULL.")
            case ("integer", .int(let value)) where value >= minimum && value <= maximum:
                continue
            case ("integer", .int):
                throw SwiftDataError.migrationUnsupported(
                    "Integer column \(column) contains a value outside the destination range.")
            default:
                throw SwiftDataError.migrationUnsupported(
                    "Integer column \(column) contains unsupported SQLite storage type '\(storageType)'.")
            }
        }
    }

    private static func compatibleIntegerToFloating(
        _ mappings: [AttributeMapping],
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceEntities: [Schema.Entity],
        destinationEntities: [Schema.Entity],
        sourceEntityIDs: [String: Int],
        destinationEntityIDs: [String: Int]
    ) throws -> AttributeMapping? {
        let changes = mappings.filter { mapping in
            guard let old = mapping.source else { return false }
            return old.type != mapping.destination.type
        }
        guard !changes.isEmpty else { return nil }
        let hasIntegerToFloating = changes.contains { mapping in
            guard let old = mapping.source,
                signedIntegerWidth(old.type) != nil,
                mapping.destination.type == "Float" || mapping.destination.type == "Double",
                old.name == mapping.destination.name,
                old.isOptional == mapping.destination.isOptional,
                old.defaultValue == mapping.destination.defaultValue,
                old.options == mapping.destination.options,
                old.originalName == mapping.destination.originalName,
                old.components.isEmpty,
                mapping.destination.components.isEmpty
            else { return false }
            return true
        }
        guard hasIntegerToFloating else { return nil }
        guard changes.count == 1,
            let change = changes.first,
            let old = change.source,
            signedIntegerWidth(old.type) != nil,
            (change.destination.type == "Float" || change.destination.type == "Double"),
            old.name == change.destination.name,
            old.isOptional == change.destination.isOptional,
            old.defaultValue == change.destination.defaultValue,
            old.options == change.destination.options,
            old.originalName == change.destination.originalName,
            old.components.isEmpty,
            change.destination.components.isEmpty,
            !old.options.contains(.codable),
            !old.options.contains(.flattened),
            !old.options.contains(.externalStorage),
            !old.options.contains(where: { if case .transformable = $0 { true } else { false } }),
            mappings.count == source.attributes.count,
            mappings.count == destination.attributes.count,
            mappings.allSatisfy({ mapping in
                guard let sourceAttribute = mapping.source else { return false }
                return sourceAttribute.name == old.name || sourceAttribute == mapping.destination
            }),
            source.name == destination.name,
            source.superentityName == nil,
            destination.superentityName == nil,
            source.relationships.isEmpty,
            destination.relationships.isEmpty,
            source.attributes.allSatisfy({ attribute in
                attribute.components.isEmpty
                    && !attribute.options.contains(.codable)
                    && !attribute.options.contains(.flattened)
                    && !attribute.options.contains(.externalStorage)
                    && !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
            }),
            destination.attributes.allSatisfy({ attribute in
                attribute.components.isEmpty
                    && !attribute.options.contains(.codable)
                    && !attribute.options.contains(.flattened)
                    && !attribute.options.contains(.externalStorage)
                    && !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
            }),
            sourceEntityIDs == destinationEntityIDs,
            sourceEntities.count == destinationEntities.count,
            sourceEntities.allSatisfy({ entity in
                guard let destinationEntity = destinationEntities.first(where: { $0.name == entity.name }) else {
                    return false
                }
                if entity.name == source.name {
                    let destinationAttributes = Dictionary(
                        uniqueKeysWithValues: destinationEntity.attributes.map { ($0.name, $0) })
                    return entity.superentityName == destinationEntity.superentityName
                        && entity.relationships == destinationEntity.relationships
                        && entity.indexes.filter(\.isUnique) == destinationEntity.indexes.filter(\.isUnique)
                        && entity.attributes.allSatisfy({ sourceAttribute in
                            guard let destinationAttribute = destinationAttributes[sourceAttribute.name] else {
                                return false
                            }
                            return sourceAttribute.name == old.name
                                ? equivalentAttributeMetadataExceptTypeAndUnique(sourceAttribute, destinationAttribute)
                                : sourceAttribute == destinationAttribute
                        })
                }
                return equivalentEntityMetadata(entity, destinationEntity)
            }),
            sourceEntities.allSatisfy({ $0.relationships.isEmpty }),
            destinationEntities.allSatisfy({ $0.relationships.isEmpty }),
            try SQLColumnType.resolve(old.type, property: "\(source.name).\(old.name)", options: old.options)
                == .integer,
            try SQLColumnType.resolve(
                change.destination.type,
                property: "\(destination.name).\(change.destination.name)",
                options: change.destination.options) == .float
        else {
            throw SwiftDataError.migrationUnsupported(
                "Integer-to-floating conversion requires one flat scalar change with unchanged metadata and no indexes."
            )
        }
        return change
    }

    private static func compatibleExactNumericRebuilds(
        _ mappings: [AttributeMapping],
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceEntities: [Schema.Entity],
        destinationEntities: [Schema.Entity],
        sourceEntityIDs: [String: Int],
        destinationEntityIDs: [String: Int]
    ) throws -> [(AttributeMapping, RebuildConversion)]? {
        let changed = mappings.filter { mapping in
            guard let old = mapping.source else { return false }
            return old.type != mapping.destination.type
        }.sorted {
            $0.destination.name.utf8.lexicographicallyPrecedes($1.destination.name.utf8)
        }
        guard changed.count > 1 else { return nil }

        var conversions: [(AttributeMapping, RebuildConversion)] = []
        for mapping in changed {
            guard let old = mapping.source,
                old.name == mapping.destination.name,
                (!old.isOptional || mapping.destination.isOptional),
                old.originalName == mapping.destination.originalName,
                old.components.isEmpty,
                mapping.destination.components.isEmpty,
                old.options.contains(.unique) == mapping.destination.options.contains(.unique),
                !old.options.contains(.codable),
                !old.options.contains(.flattened),
                !old.options.contains(.externalStorage),
                !old.options.contains(where: { if case .transformable = $0 { true } else { false } }),
                !mapping.destination.options.contains(.codable),
                !mapping.destination.options.contains(.flattened),
                !mapping.destination.options.contains(.externalStorage),
                !mapping.destination.options.contains(where: {
                    if case .transformable = $0 { true } else { false }
                })
            else { return nil }

            if signedIntegerWidth(old.type) != nil,
                mapping.destination.type == "Float" || mapping.destination.type == "Double"
            {
                guard old.defaultValue == mapping.destination.defaultValue,
                    old.options == mapping.destination.options,
                    try SQLColumnType.resolve(old.type, property: "\(source.name).\(old.name)", options: old.options)
                        == .integer,
                    try SQLColumnType.resolve(
                        mapping.destination.type,
                        property: "\(destination.name).\(mapping.destination.name)",
                        options: mapping.destination.options) == .float
                else { return nil }
                conversions.append((mapping, .signedIntegerToFloating))
            } else if (old.type == "Float" || old.type == "Double"),
                signedIntegerWidth(mapping.destination.type) != nil
            {
                guard old.defaultValue == nil,
                    mapping.destination.defaultValue == nil,
                    old.options.subtracting([.unique]) == mapping.destination.options.subtracting([.unique]),
                    try SQLColumnType.resolve(old.type, property: "\(source.name).\(old.name)", options: old.options)
                        == .float,
                    try SQLColumnType.resolve(
                        mapping.destination.type,
                        property: "\(destination.name).\(mapping.destination.name)",
                        options: mapping.destination.options) == .integer
                else { return nil }
                conversions.append((mapping, .floatingToSignedInteger))
            } else {
                return nil
            }
        }

        let conversionNames = Set(conversions.compactMap { $0.0.source?.name })
        guard conversionNames.count == conversions.count,
            mappings.count == source.attributes.count,
            mappings.count == destination.attributes.count,
            mappings.allSatisfy({ mapping in
                guard let old = mapping.source else { return false }
                return conversionNames.contains(old.name) || old == mapping.destination
            }),
            source.name == destination.name,
            source.superentityName == nil,
            destination.superentityName == nil,
            source.relationships.isEmpty,
            destination.relationships.isEmpty,
            sourceEntityIDs == destinationEntityIDs,
            sourceEntities.count == destinationEntities.count,
            sourceEntities.allSatisfy({ sourceEntity in
                guard let destinationEntity = destinationEntities.first(where: { $0.name == sourceEntity.name }) else {
                    return false
                }
                guard sourceEntity.name == source.name else {
                    return equivalentEntityMetadata(sourceEntity, destinationEntity)
                }
                guard sourceEntity.superentityName == destinationEntity.superentityName,
                    sourceEntity.relationships == destinationEntity.relationships
                else { return false }
                let destinationAttributes = Dictionary(
                    uniqueKeysWithValues: destinationEntity.attributes.map { ($0.name, $0) })
                guard
                    sourceEntity.attributes.allSatisfy({ old in
                        guard let new = destinationAttributes[old.name] else { return false }
                        guard let conversion = conversions.first(where: { $0.0.source?.name == old.name }) else {
                            return old == new
                        }
                        switch conversion.1 {
                        case .signedIntegerToFloating:
                            return old.type != new.type
                                && old.name == new.name
                                && (!old.isOptional || new.isOptional)
                                && old.defaultValue == new.defaultValue
                                && old.options == new.options
                                && old.originalName == new.originalName
                                && old.components == new.components
                        case .floatingToSignedInteger:
                            return old.type != new.type
                                && old.name == new.name
                                && (!old.isOptional || new.isOptional)
                                && old.defaultValue == new.defaultValue
                                && old.options.subtracting([.unique]) == new.options.subtracting([.unique])
                                && old.originalName == new.originalName
                                && old.components == new.components
                        }
                    })
                else { return false }
                let sourceUniqueIndexes = sourceEntity.indexes.filter(\.isUnique)
                let destinationUniqueIndexes = destinationEntity.indexes.filter(\.isUnique)
                return equivalentUniqueIndexes(sourceUniqueIndexes, destinationUniqueIndexes)
            }),
            sourceEntities.allSatisfy({ $0.relationships.isEmpty }),
            destinationEntities.allSatisfy({ $0.relationships.isEmpty })
        else { return nil }
        return conversions
    }

    private static func compatibleFloatingToInteger(
        _ mappings: [AttributeMapping],
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceEntities: [Schema.Entity],
        destinationEntities: [Schema.Entity],
        sourceEntityIDs: [String: Int],
        destinationEntityIDs: [String: Int]
    ) throws -> AttributeMapping? {
        let changes = mappings.filter { mapping in
            guard let old = mapping.source else { return false }
            return old.type != mapping.destination.type
        }
        guard !changes.isEmpty else { return nil }
        let hasFloatingToSignedInteger = changes.contains { mapping in
            guard let old = mapping.source,
                mapping.destination.defaultValue == nil,
                signedIntegerWidth(mapping.destination.type) != nil
            else { return false }
            return old.type == "Float" || old.type == "Double"
        }
        guard hasFloatingToSignedInteger else { return nil }
        guard changes.count == 1, let change = changes.first, let old = change.source else {
            throw SwiftDataError.migrationUnsupported(
                "Floating-to-integer conversion requires one type change.")
        }
        let sourceColumnType = try SQLColumnType.resolve(
            old.type, property: "\(source.name).\(old.name)", options: old.options)
        let destinationColumnType = try SQLColumnType.resolve(
            change.destination.type,
            property: "\(destination.name).\(change.destination.name)",
            options: change.destination.options)
        let changedAttributeIsCompatible =
            (old.type == "Float" || old.type == "Double")
            && signedIntegerWidth(change.destination.type) != nil
            && old.name == change.destination.name
            && old.isOptional == change.destination.isOptional
            && old.defaultValue == nil
            && change.destination.defaultValue == nil
            && old.options.subtracting([.unique]) == change.destination.options.subtracting([.unique])
            && old.originalName == change.destination.originalName
            && old.components.isEmpty
            && change.destination.components.isEmpty
            && sourceColumnType == .float
            && destinationColumnType == .integer
        guard changedAttributeIsCompatible else {
            throw SwiftDataError.migrationUnsupported(
                "Floating-to-integer conversion changed unsupported attribute metadata.")
        }
        let flatAttributes =
            source.attributes.allSatisfy({ attribute in
                attribute.components.isEmpty
                    && !attribute.options.contains(.codable)
                    && !attribute.options.contains(.flattened)
                    && !attribute.options.contains(.externalStorage)
                    && !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
            })
            && destination.attributes.allSatisfy({ attribute in
                attribute.components.isEmpty
                    && !attribute.options.contains(.codable)
                    && !attribute.options.contains(.flattened)
                    && !attribute.options.contains(.externalStorage)
                    && !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
            })
        guard flatAttributes else {
            throw SwiftDataError.migrationUnsupported(
                "Floating-to-integer conversion requires ordinary scalar attributes.")
        }
        let mappedAttributesMatch =
            mappings.count == source.attributes.count
            && mappings.count == destination.attributes.count
            && mappings.allSatisfy({ mapping in
                guard let sourceAttribute = mapping.source else { return false }
                return sourceAttribute.name == old.name
                    ? equivalentAttributeMetadataExceptTypeAndUnique(sourceAttribute, mapping.destination)
                    : sourceAttribute == mapping.destination
            })
        guard mappedAttributesMatch else {
            throw SwiftDataError.migrationUnsupported(
                "Floating-to-integer conversion cannot be combined with other attribute changes.")
        }
        let entityMetadataMatches =
            source.name == destination.name
            && source.superentityName == nil
            && destination.superentityName == nil
            && source.relationships.isEmpty
            && destination.relationships.isEmpty
            && sourceEntityIDs == destinationEntityIDs
            && sourceEntities.count == destinationEntities.count
            && sourceEntities.allSatisfy({ sourceEntity in
                guard let destinationEntity = destinationEntities.first(where: { $0.name == sourceEntity.name }) else {
                    return false
                }
                if sourceEntity.name == source.name {
                    let destinationAttributes = Dictionary(
                        uniqueKeysWithValues: destinationEntity.attributes.map { ($0.name, $0) })
                    return sourceEntity.superentityName == destinationEntity.superentityName
                        && sourceEntity.relationships == destinationEntity.relationships
                        && sourceEntity.attributes.allSatisfy({ sourceAttribute in
                            guard let destinationAttribute = destinationAttributes[sourceAttribute.name] else {
                                return false
                            }
                            return sourceAttribute.name == old.name
                                ? equivalentAttributeMetadataExceptTypeAndUnique(sourceAttribute, destinationAttribute)
                                : sourceAttribute == destinationAttribute
                        })
                }
                return equivalentEntityMetadata(sourceEntity, destinationEntity)
            })
            && sourceEntities.allSatisfy({ $0.relationships.isEmpty })
            && destinationEntities.allSatisfy({ $0.relationships.isEmpty })
        guard entityMetadataMatches else {
            throw SwiftDataError.migrationUnsupported(
                "Floating-to-integer conversion changes unsupported entity metadata or relationships.")
        }
        return change
    }

    private static func rebuildFloatingColumnAsInteger(
        attribute mapping: AttributeMapping,
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceSchema: Schema,
        destinationSchema: Schema,
        connection: SQLConnection
    ) throws {
        guard let sourceAttribute = mapping.source,
            signedIntegerWidth(mapping.destination.type) != nil
        else {
            throw SwiftDataError.migrationUnsupported("Floating-to-integer migration has invalid attribute metadata.")
        }
        let table = "Z\(source.name.uppercased())"
        let convertedColumn = "Z\(sourceAttribute.name.uppercased())"
        try validateRebuildIndexPlan(
            table: table,
            source: source,
            destination: destination,
            sourceSchema: sourceSchema,
            destinationSchema: destinationSchema,
            connection: connection)
        try validateFloatingValuesForIntegerConversion(
            table: table,
            column: convertedColumn,
            destinationType: mapping.destination.type,
            isOptional: sourceAttribute.isOptional,
            connection: connection)
        try rebuildTable(
            source: source,
            destination: destination,
            destinationSchema: destinationSchema,
            conversions: [
                RebuildColumnConversion(column: convertedColumn, conversion: .floatingToSignedInteger)
            ],
            connection: connection)
    }

    private static func validateFloatingValuesForIntegerConversion(
        table: String,
        column: String,
        destinationType: String,
        isOptional: Bool,
        connection: SQLConnection
    ) throws {
        guard let width = signedIntegerWidth(destinationType) else {
            throw SwiftDataError.migrationUnsupported("Unsupported signed-integer destination type.")
        }
        let rows = try connection.rows("SELECT typeof(\(column)), \(column) FROM \(table) ORDER BY Z_PK")
        for row in rows {
            guard row.count > 1, case let .text(storageType) = row[0] else {
                throw SwiftDataError.migrationUnsupported("Floating column \(column) has invalid SQLite metadata.")
            }
            switch (storageType, row[1]) {
            case ("null", .null) where isOptional:
                continue
            case ("null", .null):
                throw SwiftDataError.migrationUnsupported(
                    "Required floating column \(column) contains NULL; NaN may be stored as NULL.")
            case ("integer", .int(let value)):
                let minimum = width == 64 ? Int64.min : -(Int64(1) << (width - 1))
                let maximum = width == 64 ? Int64.max : (Int64(1) << (width - 1)) - 1
                guard value >= minimum, value <= maximum else {
                    throw SwiftDataError.migrationUnsupported(
                        "Integer value in \(column) is outside the destination range.")
                }
            case ("real", .double(let value)):
                guard value.isFinite,
                    isWithinSignedIntegerRange(value, width: width),
                    let converted = exactSignedInteger(value, width: width),
                    Double(converted) == value
                else {
                    throw SwiftDataError.migrationUnsupported(
                        "Floating column \(column) contains a non-integral or out-of-range value.")
                }
            default:
                throw SwiftDataError.migrationUnsupported(
                    "Floating column \(column) contains unsupported SQLite storage type '\(storageType)'.")
            }
        }
    }

    private static func isWithinSignedIntegerRange(_ value: Double, width: Int) -> Bool {
        guard (1...64).contains(width) else { return false }
        let exclusiveUpperBound = Double(sign: .plus, exponent: width - 1, significand: 1)
        let inclusiveLowerBound = -exclusiveUpperBound
        return value >= inclusiveLowerBound && value < exclusiveUpperBound
    }

    private static func exactSignedInteger(_ value: Double, width: Int) -> Int64? {
        guard width > 0 else { return nil }
        return switch width {
        case 8: Int8(exactly: value).map(Int64.init)
        case 16: Int16(exactly: value).map(Int64.init)
        case 32: Int32(exactly: value).map(Int64.init)
        case 64: Int64(exactly: value)
        default: nil
        }
    }

    private enum RebuildConversion {
        case signedIntegerToFloating
        case floatingToSignedInteger

        var castType: String {
            switch self {
            case .signedIntegerToFloating: "REAL"
            case .floatingToSignedInteger: "INTEGER"
            }
        }

        var storageType: String {
            switch self {
            case .signedIntegerToFloating: "real"
            case .floatingToSignedInteger: "integer"
            }
        }

        var diagnosticName: String {
            switch self {
            case .signedIntegerToFloating: "Integer-to-floating"
            case .floatingToSignedInteger: "Floating-to-integer"
            }
        }
    }

    private struct RebuildColumnConversion {
        let column: String
        let conversion: RebuildConversion
    }

    private static func validateRebuildIndexPlan(
        table: String,
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceSchema: Schema,
        destinationSchema: Schema,
        connection: SQLConnection
    ) throws {
        let sourceHasHierarchy = sourceSchema.entities.contains { entity in
            (entity.name == source.name && entity.superentityName != nil)
                || entity.superentityName == source.name
        }
        let destinationHasHierarchy = destinationSchema.entities.contains { entity in
            (entity.name == destination.name && entity.superentityName != nil)
                || entity.superentityName == destination.name
        }
        guard !sourceHasHierarchy, !destinationHasHierarchy else {
            throw SwiftDataError.migrationUnsupported("Numeric rebuild does not support entity hierarchies.")
        }
        try validateTableRebuildSideEffects(table: table, schema: sourceSchema, connection: connection)
        let sourceIndexes = indexDefinitions(for: source, schema: sourceSchema)
        let destinationIndexes = indexDefinitions(for: destination, schema: destinationSchema)
        guard (sourceIndexes + destinationIndexes).allSatisfy({ !$0.statement.contains(" WHERE ") }) else {
            throw SwiftDataError.migrationUnsupported("Numeric rebuild does not support partial indexes.")
        }
        _ = try validateSourceIndexLayout(sourceSchema, connection: connection)
        let physicalIndexes = try connection.rows(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? COLLATE NOCASE", [.text(table)])
        let expectedIndexNames = Set(sourceIndexes.map { $0.name.uppercased() })
        let actualIndexNames = physicalIndexes.compactMap { row -> String? in
            guard case let .text(name)? = row.first else { return nil }
            return name.uppercased()
        }
        guard actualIndexNames.count == physicalIndexes.count, Set(actualIndexNames) == expectedIndexNames else {
            throw SwiftDataError.migrationUnsupported("Numeric rebuild found untracked or missing physical indexes.")
        }
        try validateRebuildDestinationIndexNames(
            destinationIndexes,
            sourceIndexNames: expectedIndexNames,
            table: table,
            connection: connection)
    }

    private static func rebuildTable(
        source: Schema.Entity,
        destination: Schema.Entity,
        destinationSchema: Schema,
        conversions: [RebuildColumnConversion],
        connection: SQLConnection
    ) throws {
        let table = "Z\(source.name.uppercased())"
        let destinationIndexes = indexDefinitions(for: destination, schema: destinationSchema)
        let destinationBuilt = try SchemaBuilder.build(destinationSchema)
        guard
            let destinationTableStatement = destinationBuilt.statements.first(where: {
                $0.hasPrefix("CREATE TABLE \(table) (")
            })
        else {
            throw SwiftDataError.migrationUnsupported("Destination table DDL is missing for \(table).")
        }
        let temporaryTable = "\(table)_OSD_REBUILD"
        let existingObjects = try connection.rows(
            "SELECT 1 FROM sqlite_master WHERE name = ? COLLATE NOCASE LIMIT 1", [.text(temporaryTable)])
        guard existingObjects.isEmpty else {
            throw SwiftDataError.migrationUnsupported("Temporary rebuild table name collides with an existing object.")
        }
        let temporaryTableStatement = destinationTableStatement.replacingOccurrences(
            of: "CREATE TABLE \(table) ", with: "CREATE TABLE \(temporaryTable) ")
        let destinationColumns = destinationTableColumnNames(destination)
        let sourceColumnInfo = try connection.rows("PRAGMA table_xinfo(\(table))")
        let sourceColumns = sourceColumnInfo.compactMap { row -> String? in
            guard row.count > 6, case let .text(name) = row[1], row[6] == .int(0) else { return nil }
            return name
        }
        let convertedColumnNames = conversions.map { $0.column.uppercased() }
        let destinationColumnNames = Set(destinationColumns.map { $0.uppercased() })
        let conversionsByColumn = Dictionary(uniqueKeysWithValues: conversions.map { ($0.column.uppercased(), $0) })
        guard sourceColumnInfo.count == destinationColumns.count,
            sourceColumns == destinationColumns,
            destinationBuilt.statements.contains(where: { $0 == destinationTableStatement }),
            Set(convertedColumnNames).count == conversions.count,
            Set(convertedColumnNames).isSubset(of: destinationColumnNames)
        else {
            throw SwiftDataError.migrationUnsupported("Numeric rebuild has an invalid conversion plan or table layout.")
        }
        let insertColumns = destinationColumns.joined(separator: ", ")
        let selectExpressions = destinationColumns.map { column in
            guard let conversion = conversionsByColumn[column.uppercased()] else { return column }
            return "CAST(\(column) AS \(conversion.conversion.castType))"
        }.joined(separator: ", ")
        let originalPrimaryKeys = try connection.rows("SELECT Z_PK FROM \(table) ORDER BY Z_PK")
        try connection.execute(temporaryTableStatement)
        try connection.execute(
            "INSERT INTO \(temporaryTable) (\(insertColumns)) SELECT \(selectExpressions) FROM \(table)")

        let rebuiltCount = try connection.rows("SELECT COUNT(*) FROM \(temporaryTable)")
        guard rebuiltCount.first?.first == .int(Int64(originalPrimaryKeys.count)) else {
            throw SwiftDataError.migrationUnsupported("Numeric rebuild changed the row count.")
        }
        let rebuiltPrimaryKeys = try connection.rows("SELECT Z_PK FROM \(temporaryTable) ORDER BY Z_PK")
        guard rebuiltPrimaryKeys == originalPrimaryKeys else {
            throw SwiftDataError.migrationUnsupported("Numeric rebuild changed primary keys.")
        }
        for plan in conversionsByColumn.values.sorted(by: { $0.column < $1.column }) {
            let invalidConvertedRows = try connection.rows(
                "SELECT COUNT(*) FROM \(temporaryTable) "
                    + "WHERE \(plan.column) IS NOT NULL AND typeof(\(plan.column)) != '\(plan.conversion.storageType)'"
            )
            guard invalidConvertedRows.first?.first == .int(0) else {
                throw SwiftDataError.migrationUnsupported(
                    "\(plan.conversion.diagnosticName) copy produced invalid storage class for \(plan.column).")
            }
        }
        let mismatchPredicate = destinationColumns.map { column in
            "source.\(column) IS NOT rebuilt.\(column)"
        }.joined(separator: " OR ")
        let mismatchedRows = try connection.rows(
            "SELECT COUNT(*) FROM \(table) AS source JOIN \(temporaryTable) AS rebuilt USING (Z_PK) "
                + "WHERE \(mismatchPredicate)")
        guard mismatchedRows.first?.first == .int(0) else {
            throw SwiftDataError.migrationUnsupported("Numeric rebuild changed stored row values.")
        }
        try validateRebuildUniqueIndexes(destinationIndexes, table: temporaryTable, connection: connection)

        try connection.execute("DROP TABLE \(table)")
        try connection.execute("ALTER TABLE \(temporaryTable) RENAME TO \(table)")
        for definition in destinationIndexes {
            try connection.execute(definition.statement)
            try validatePhysicalIndexMetadata(definition, connection: connection)
        }
    }

    private static func validateRebuildUniqueIndexes(
        _ indexes: [IndexDefinition],
        table: String,
        connection: SQLConnection
    ) throws {
        for index in indexes where index.statement.hasPrefix("CREATE UNIQUE INDEX") {
            guard !index.columns.isEmpty else {
                throw SwiftDataError.migrationUnsupported("Unique rebuild index has no columns.")
            }
            let nonNullPredicate = index.columns.map { "\($0) IS NOT NULL" }.joined(separator: " AND ")
            let columns = index.columns.joined(separator: ", ")
            let duplicateGroups = try connection.rows(
                "SELECT COUNT(*) FROM (SELECT 1 FROM \(table) WHERE \(nonNullPredicate) "
                    + "GROUP BY \(columns) HAVING COUNT(*) > 1)")
            guard duplicateGroups.first?.first == .int(0) else {
                throw SwiftDataError.migrationUnsupported(
                    "Unique index \(index.name) would reject duplicate converted values.")
            }
        }
    }

    private static func rebuildIntegerColumnAsFloating(
        attribute mapping: AttributeMapping,
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceSchema: Schema,
        destinationSchema: Schema,
        connection: SQLConnection
    ) throws {
        guard let sourceAttribute = mapping.source else {
            throw SwiftDataError.migrationUnsupported("Integer-to-floating migration has no source attribute.")
        }
        let table = "Z\(source.name.uppercased())"
        let convertedColumn = "Z\(sourceAttribute.name.uppercased())"
        let destinationType = mapping.destination.type
        try validateRebuildIndexPlan(
            table: table,
            source: source,
            destination: destination,
            sourceSchema: sourceSchema,
            destinationSchema: destinationSchema,
            connection: connection)
        try validateIntegerValuesForFloatingConversion(
            table: table,
            column: convertedColumn,
            destinationType: destinationType,
            isOptional: sourceAttribute.isOptional,
            connection: connection)

        try rebuildTable(
            source: source,
            destination: destination,
            destinationSchema: destinationSchema,
            conversions: [RebuildColumnConversion(column: convertedColumn, conversion: .signedIntegerToFloating)],
            connection: connection)
    }

    private static func validateRebuildDestinationIndexNames(
        _ destinationIndexes: [IndexDefinition],
        sourceIndexNames: Set<String>,
        table: String,
        connection: SQLConnection
    ) throws {
        for definition in destinationIndexes {
            let objects = try connection.rows(
                "SELECT type, tbl_name FROM sqlite_master WHERE name = ? COLLATE NOCASE",
                [.text(definition.name)])
            guard let object = objects.first else { continue }
            guard objects.count == 1,
                object.count > 1,
                case .text("index") = object[0],
                case let .text(indexTable) = object[1],
                indexTable.caseInsensitiveCompare(table) == .orderedSame,
                sourceIndexNames.contains(definition.name.uppercased())
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Destination rebuild index \(definition.name) collides with an unrelated physical object.")
            }
        }
    }

    private static func destinationTableColumnNames(_ entity: Schema.Entity) -> [String] {
        ["Z_PK", "Z_ENT", "Z_OPT"]
            + entity.attributes.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
            .map { "Z\($0.name.uppercased())" }
    }

    private static func validateTableRebuildSideEffects(
        table: String,
        schema: Schema,
        connection: SQLConnection
    ) throws {
        let sideObjects = try connection.rows(
            "SELECT type, name FROM sqlite_master WHERE type IN ('trigger', 'view')")
        guard sideObjects.isEmpty else {
            throw SwiftDataError.migrationUnsupported("Table rebuild is unsupported when triggers or views exist.")
        }
        let sourceDDL = try SchemaBuilder.build(schema).statements
        guard let createTable = sourceDDL.first(where: { $0.hasPrefix("CREATE TABLE \(table) (") }),
            !createTable.uppercased().contains("AUTOINCREMENT")
        else {
            throw SwiftDataError.migrationUnsupported(
                "Numeric rebuild requires canonical non-AUTOINCREMENT DDL.")
        }
        let actualDDL = try connection.rows(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ? COLLATE NOCASE", [.text(table)])
        guard actualDDL.count == 1,
            case let .text(actualCreateTable)? = actualDDL.first?.first,
            normalizedCreateTableSQL(actualCreateTable) == normalizedCreateTableSQL(createTable)
        else {
            throw SwiftDataError.migrationUnsupported(
                "Numeric rebuild requires canonical source table DDL.")
        }
        let tableNames = try connection.rows(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        )
        .compactMap { row -> String? in
            guard case let .text(name)? = row.first else { return nil }
            return name
        }
        for name in tableNames {
            let quotedName = "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
            let foreignKeys = try connection.rows("PRAGMA foreign_key_list(\(quotedName))")
            guard foreignKeys.isEmpty else {
                throw SwiftDataError.migrationUnsupported(
                    "Numeric rebuild is unsupported with foreign keys.")
            }
        }
        let hasSequence = try connection.rows(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence' LIMIT 1")
        if !hasSequence.isEmpty {
            let tableSequence = try connection.rows(
                "SELECT 1 FROM sqlite_sequence WHERE name = ? COLLATE NOCASE LIMIT 1", [.text(table)])
            guard tableSequence.isEmpty else {
                throw SwiftDataError.migrationUnsupported(
                    "Numeric rebuild does not migrate the source table's sqlite_sequence entry.")
            }
        }
    }

    private static func normalizedCreateTableSQL(_ sql: String) -> String {
        var normalized = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix(";") { normalized.removeLast() }
        return normalized.lowercased().filter { !$0.isWhitespace }
    }

    private static func validateIntegerValuesForFloatingConversion(
        table: String,
        column: String,
        destinationType: String,
        isOptional: Bool,
        connection: SQLConnection
    ) throws {
        let rows = try connection.rows("SELECT typeof(\(column)), \(column) FROM \(table) ORDER BY Z_PK")
        let maximumExactInteger: Int64
        switch destinationType {
        case "Float": maximumExactInteger = 16_777_216
        case "Double": maximumExactInteger = 9_007_199_254_740_992
        default:
            throw SwiftDataError.migrationUnsupported("Unsupported floating-point destination type.")
        }
        for row in rows {
            guard row.count > 1, case let .text(storageType) = row[0] else {
                throw SwiftDataError.migrationUnsupported("Integer column \(column) has invalid SQLite metadata.")
            }
            switch (storageType, row[1]) {
            case ("null", .null) where isOptional:
                continue
            case ("null", .null):
                throw SwiftDataError.migrationUnsupported("Required integer column \(column) contains NULL.")
            case ("integer", .int(let value)) where value >= -maximumExactInteger && value <= maximumExactInteger:
                continue
            case ("integer", .int):
                throw SwiftDataError.migrationUnsupported(
                    "Integer column \(column) contains a value not exactly representable as \(destinationType).")
            default:
                throw SwiftDataError.migrationUnsupported(
                    "Integer column \(column) contains unsupported SQLite storage type '\(storageType)'.")
            }
        }
    }

    private static func validateFlatOptionalityDDLCompatibility(
        source: Schema,
        destination: Schema
    ) throws {
        let sourceBuilt = try SchemaBuilder.build(source)
        let destinationBuilt = try SchemaBuilder.build(destination)
        let sourceTables = sourceBuilt.statements.filter { $0.hasPrefix("CREATE TABLE Z") }
        let destinationTables = destinationBuilt.statements.filter { $0.hasPrefix("CREATE TABLE Z") }
        guard sourceTables == destinationTables else {
            throw SwiftDataError.migrationUnsupported(
                "Required-to-optional migration changes physical DDL and requires explicit rebuild support.")
        }
        let sourceIndexes = source.entities.flatMap { indexDefinitions(for: $0, schema: source) }
        let destinationIndexes = destination.entities.flatMap { indexDefinitions(for: $0, schema: destination) }
        guard sourceIndexes == destinationIndexes else {
            throw SwiftDataError.migrationUnsupported(
                "Required-to-optional migration cannot combine index or uniqueness changes.")
        }
    }

    private static func signedIntegerWidth(_ typeName: String) -> Int? {
        let trimmedTypeName = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonOptionalTypeName =
            trimmedTypeName.hasSuffix("?")
            ? String(trimmedTypeName.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedTypeName
        let name = nonOptionalTypeName.split(separator: ".").last.map(String.init) ?? nonOptionalTypeName
        return switch name {
        case "Int8": 8
        case "Int16": 16
        case "Int32": 32
        case "Int64": 64
        case "Int": Int.bitWidth
        default: nil
        }
    }

    private static func equivalentUniqueIndexes(_ lhs: [Schema.Index], _ rhs: [Schema.Index]) -> Bool {
        let left = lhs.filter(\.isUnique)
        let right = rhs.filter(\.isUnique)
        return left.count == right.count && left.allSatisfy { right.contains($0) }
    }

    private static func equivalentAttributeMetadataExceptTypeAndUnique(
        _ lhs: Schema.Attribute,
        _ rhs: Schema.Attribute
    ) -> Bool {
        lhs.name == rhs.name
            && lhs.isOptional == rhs.isOptional
            && lhs.defaultValue == rhs.defaultValue
            && lhs.options.subtracting([.unique]) == rhs.options.subtracting([.unique])
            && lhs.originalName == rhs.originalName
            && lhs.components == rhs.components
    }

    private static func compatibleFloatTypeChange(
        _ mappings: [AttributeMapping],
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceEntities: [Schema.Entity],
        destinationEntities: [Schema.Entity],
        sourceEntityIDs: [String: Int],
        destinationEntityIDs: [String: Int]
    ) throws -> AttributeMapping? {
        let changed = mappings.filter { mapping in
            guard let source = mapping.source else { return false }
            return source.type != mapping.destination.type
        }
        guard !changed.isEmpty else { return nil }
        guard changed.count == 1,
            let mapping = changed.first,
            let sourceAttribute = mapping.source,
            (sourceAttribute.type == "Float" && mapping.destination.type == "Double")
                || (sourceAttribute.type == "Double" && mapping.destination.type == "Float"),
            sourceAttribute.name == mapping.destination.name,
            sourceAttribute.isOptional == mapping.destination.isOptional,
            sourceAttribute.defaultValue == mapping.destination.defaultValue,
            sourceAttribute.options == mapping.destination.options,
            sourceAttribute.originalName == mapping.destination.originalName,
            sourceAttribute.components.isEmpty,
            mapping.destination.components.isEmpty,
            mappings.count == source.attributes.count,
            mappings.count == destination.attributes.count,
            mappings.allSatisfy({ candidate in
                guard let old = candidate.source else { return false }
                return old == sourceAttribute || old == candidate.destination
            }),
            source.name == destination.name,
            source.superentityName == nil,
            destination.superentityName == nil,
            source.relationships.isEmpty,
            destination.relationships.isEmpty,
            source.indexes == destination.indexes,
            sourceEntityIDs == destinationEntityIDs,
            sourceEntities.count == destinationEntities.count,
            sourceEntities.allSatisfy({ sourceEntity in
                guard let destinationEntity = destinationEntities.first(where: { $0.name == sourceEntity.name }) else {
                    return false
                }
                if sourceEntity.name == source.name {
                    return sourceEntity.relationships == destinationEntity.relationships
                        && sourceEntity.superentityName == destinationEntity.superentityName
                        && sourceEntity.indexes == destinationEntity.indexes
                }
                return equivalentEntityMetadata(sourceEntity, destinationEntity)
            }),
            !sourceAttribute.options.contains(.codable),
            !sourceAttribute.options.contains(.flattened),
            !sourceAttribute.options.contains(.externalStorage),
            !sourceAttribute.options.contains(where: { if case .transformable = $0 { true } else { false } }),
            try SQLColumnType.resolve(
                sourceAttribute.type, property: "\(source.name).\(sourceAttribute.name)",
                options: sourceAttribute.options)
                == .float,
            try SQLColumnType.resolve(
                mapping.destination.type,
                property: "\(destination.name).\(mapping.destination.name)",
                options: mapping.destination.options) == .float
        else {
            throw SwiftDataError.migrationUnsupported(
                "Float/Double type changes must be a single flat scalar change with unchanged storage metadata.")
        }
        return mapping
    }

    private static func validateFloatValuesForWidening(
        table: String,
        column: String,
        isOptional: Bool,
        requiresExactFloatRoundTrip: Bool,
        connection: SQLConnection
    ) throws {
        let rows = try connection.rows(
            "SELECT typeof(\(column)), \(column) FROM \(table) ORDER BY Z_PK")
        for row in rows {
            guard row.count > 1, case let .text(storageType) = row[0] else {
                throw SwiftDataError.migrationUnsupported("Float column \(column) has invalid SQLite storage metadata.")
            }
            switch (storageType, row[1]) {
            case ("null", .null) where isOptional:
                continue
            case ("null", .null):
                throw SwiftDataError.migrationUnsupported("Required Float column \(column) contains NULL.")
            case ("integer", .int(let value)):
                let floatValue = Float(value)
                guard Int64(exactly: floatValue) == value else {
                    throw SwiftDataError.migrationUnsupported(
                        "Float column \(column) contains an integer not exactly representable as Float.")
                }
            case ("real", .double(let value)):
                let floatValue = Float(value)
                guard !requiresExactFloatRoundTrip || Double(floatValue) == value else {
                    throw SwiftDataError.migrationUnsupported(
                        "Float column \(column) contains a value not exactly representable as Float.")
                }
            default:
                throw SwiftDataError.migrationUnsupported(
                    "Float column \(column) contains unsupported SQLite storage type '\(storageType)'.")
            }
        }
    }

    private static func removableScalarAttributes(
        _ mappings: [AttributeMapping],
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceEntities: [Schema.Entity],
        destinationEntities: [Schema.Entity],
        sourceEntityIDs: [String: Int],
        destinationEntityIDs: [String: Int]
    ) throws -> [Schema.Attribute]? {
        let removed = source.attributes.filter { sourceAttribute in
            !mappings.contains(where: { $0.source?.name == sourceAttribute.name })
        }
        guard !removed.isEmpty else { return nil }
        let removedNames = Set(removed.map(\.name))
        let normalizedRemovedNames = Set(removed.map { $0.name.uppercased() })
        let removedFlattenedColumnNames = Set(
            removed.filter { $0.options.contains(.flattened) }
                .flatMap { attribute in [attribute.name] + attribute.components.map(\.columnName) }
                .map { $0.uppercased() })
        let removedIndexPropertyNames = normalizedRemovedNames.union(removedFlattenedColumnNames)
        let renameMappings = mappings.filter { mapping in
            guard let old = mapping.source else { return false }
            return old.name.caseInsensitiveCompare(mapping.destination.name) != .orderedSame
        }
        let renamedSourceNames = Set(renameMappings.compactMap { $0.source?.name.uppercased() })
        let renamedDestinationNames = Set(renameMappings.map { $0.destination.name.uppercased() })
        let renameIndexPropertyNames = renamedSourceNames.union(renamedDestinationNames)
        let addedMappings = mappings.filter { $0.source == nil }
        let targetEntityMatches = sourceEntities.allSatisfy({ sourceEntity in
            guard let destinationEntity = destinationEntities.first(where: { $0.name == sourceEntity.name }) else {
                return false
            }
            guard sourceEntity.name == source.name else {
                return sourceEntity.superentityName == destinationEntity.superentityName
                    && sourceEntity.attributes.count == destinationEntity.attributes.count
                    && sourceEntity.attributes.allSatisfy({ destinationEntity.attributes.contains($0) })
                    && sourceEntity.relationships == destinationEntity.relationships
                    && sourceEntity.indexes == destinationEntity.indexes
            }
            let retainedSourceAttributes = sourceEntity.attributes.filter { !removedNames.contains($0.name) }
            let destinationAttributes = destinationEntity.attributes
            let additions = addedMappings.map(\.destination)
            let removableAttributeUniqueIndex =
                removed.count == 1
                    && removed[0].options.contains(.unique)
                ? removed[0].name : nil
            let sourceUniqueIndexes = sourceEntity.indexes.filter { index in
                index.isUnique
                    && !(index.properties.count == 1 && index.properties.first == removableAttributeUniqueIndex)
            }
            let destinationUniqueIndexes = destinationEntity.indexes.filter(\.isUnique)
            return sourceEntity.superentityName == destinationEntity.superentityName
                && sourceEntity.relationships == destinationEntity.relationships
                && retainedSourceAttributes.count + additions.count == destinationAttributes.count
                && retainedSourceAttributes.allSatisfy({ old in
                    guard let mapping = mappings.first(where: { $0.source?.name == old.name }) else { return false }
                    return destinationAttributes.contains(mapping.destination)
                        && (old.name.caseInsensitiveCompare(mapping.destination.name) == .orderedSame
                            ? old == mapping.destination
                            : renameMappings.contains(where: {
                                $0.source?.name == old.name && $0.destination == mapping.destination
                            }))
                })
                && additions.allSatisfy({ destinationAttributes.contains($0) })
                && sourceUniqueIndexes.count == destinationUniqueIndexes.count
                && sourceUniqueIndexes.allSatisfy({ destinationUniqueIndexes.contains($0) })
                && (!additions.isEmpty
                    ? Set(sourceEntity.attributes.filter({ $0.options.contains(.unique) }).map(\.name))
                        == Set(destinationEntity.attributes.filter({ $0.options.contains(.unique) }).map(\.name))
                    : true)
                && sourceEntity.indexes.allSatisfy({ index in
                    !index.properties.contains(where: { property in
                        renameIndexPropertyNames.contains(property.uppercased())
                    }) || (!index.isUnique && index.properties.count == 1)
                })
                && destinationEntity.indexes.allSatisfy({ index in
                    !index.properties.contains(where: { property in
                        renameIndexPropertyNames.contains(property.uppercased())
                    }) || (!index.isUnique && index.properties.count == 1)
                })
        })
        guard targetEntityMatches else {
            throw SwiftDataError.migrationUnsupported(
                "Removal target entity metadata does not match the migration plan.")
        }
        let sourceIndexDefinitions = indexDefinitions(for: source, schema: Schema(sourceEntities))
        let destinationIndexDefinitions = indexDefinitions(for: destination, schema: Schema(destinationEntities))
        let renameIndexesAreOrdinary = renameMappings.allSatisfy({ mapping in
            guard let old = mapping.source else { return false }
            let sourceOnOld = sourceIndexDefinitions.filter { $0.columns == ["Z\(old.name.uppercased())"] }
            let destinationOnNew = destinationIndexDefinitions.filter {
                $0.columns == ["Z\(mapping.destination.name.uppercased())"]
            }
            return sourceOnOld.count <= destinationOnNew.count
                && sourceOnOld.count <= 1
                && destinationOnNew.count <= 1
                && sourceOnOld.allSatisfy({ $0.statement.hasPrefix("CREATE INDEX") })
                && destinationOnNew.allSatisfy({ $0.statement.hasPrefix("CREATE INDEX") })
        })
        let destinationIndexes = destination.indexes
        guard
            destinationIndexes.allSatisfy({ index in
                !index.properties.contains(where: { normalizedRemovedNames.contains($0.uppercased()) })
                    && !index.properties.contains(where: { removedFlattenedColumnNames.contains($0.uppercased()) })
                    && (addedMappings.isEmpty
                        ? !index.isUnique
                        : equivalentUniqueIndexes(source.indexes, destination.indexes))
            })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Attribute removal cannot be combined with unique constraints or indexes on removed columns.")
        }
        guard
            !source.indexes.contains(where: { index in
                guard index.isUnique,
                    index.properties.contains(where: {
                        normalizedRemovedNames.contains($0.uppercased())
                            || removedFlattenedColumnNames.contains($0.uppercased())
                    })
                else { return false }
                return
                    !(index.properties.count == 1
                    && removed.count == 1
                    && index.properties.first == removed[0].name
                    && removed[0].options.contains(.unique))
            })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Removing attributes cannot alter schema-level unique indexes.")
        }
        guard
            destinationEntities.contains(where: { $0.name == destination.name }),
            try removed.allSatisfy({ try isRemovableAttributeStorage($0, entity: source) }),
            !destination.attributes.contains(where: { attribute in
                attribute.originalName.map { removedNames.contains($0) } ?? false
            }),
            mappings.count == destination.attributes.count,
            try mappings.allSatisfy({ mapping in
                guard let old = mapping.source else {
                    let attribute = mapping.destination
                    let literal = try migrationDefaultLiteral(for: attribute)
                    return (attribute.isOptional || literal != nil)
                        && attribute.originalName == nil
                        && attribute.components.isEmpty
                        && !attribute.options.contains(.unique)
                        && !attribute.options.contains(.codable)
                        && !attribute.options.contains(.flattened)
                        && !attribute.options.contains(.externalStorage)
                        && !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
                }
                return old.name.caseInsensitiveCompare(mapping.destination.name) == .orderedSame
                    ? old == mapping.destination
                    : old.type == mapping.destination.type
                        && old.isOptional == mapping.destination.isOptional
                        && old.defaultValue == mapping.destination.defaultValue
                        && old.options == mapping.destination.options
                        && old.components == mapping.destination.components
                        && mapping.destination.originalName == old.name
            }),
            renameMappings.count <= 1,
            (renameMappings.isEmpty || (removed.count == 1 && addedMappings.isEmpty)),
            renameMappings.allSatisfy({ mapping in
                guard let old = mapping.source else { return false }
                return !removedNames.contains(mapping.destination.name)
                    && !removedNames.contains(old.name)
                    && !source.attributes.contains(where: {
                        $0.name.caseInsensitiveCompare(mapping.destination.name) == .orderedSame
                            && $0.name.caseInsensitiveCompare(old.name) != .orderedSame
                    })
            }),
            source.name == destination.name,
            source.superentityName == nil,
            destination.superentityName == nil,
            source.relationships.isEmpty,
            destination.relationships.isEmpty,
            renameIndexesAreOrdinary,
            !destination.indexes.contains(where: { index in
                index.properties.contains(where: {
                    removedIndexPropertyNames.contains($0.uppercased())
                })
            }),
            sourceEntityIDs == destinationEntityIDs,
            sourceEntities.count == destinationEntities.count,
            targetEntityMatches,
            sourceEntities.allSatisfy({ $0.relationships.isEmpty }),
            destinationEntities.allSatisfy({ $0.relationships.isEmpty })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Attribute removal must remove flat scalar columns without changing retained metadata or partial indexes."
            )
        }
        for attribute in removed {
            if attribute.options.contains(.flattened) {
                for component in attribute.components {
                    _ = try SQLColumnType.resolve(
                        component.type, property: "\(source.name).\(component.columnName)")
                }
            } else {
                _ = try SQLColumnType.resolve(
                    attribute.type, property: "\(source.name).\(attribute.name)", options: attribute.options)
            }
        }
        return removed
    }

    private static func isRemovableAttributeStorage(_ attribute: Schema.Attribute, entity: Schema.Entity) throws -> Bool
    {
        guard !attribute.options.contains(.externalStorage),
            !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
        else { return false }
        guard attribute.options.contains(.flattened) else { return true }
        guard !attribute.isOptional,
            !attribute.options.contains(.unique),
            !attribute.components.isEmpty,
            Set(attribute.components.map(\.name)).count == attribute.components.count
        else { return false }
        for component in attribute.components {
            guard component.columnName == "\(attribute.name)_\(component.name)",
                component.name.utf8.allSatisfy({
                    ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95
                })
            else { return false }
            _ = try SQLColumnType.resolve(
                component.type, property: "\(entity.name).\(component.columnName)")
        }
        return true
    }

    private static func validateColumnRemovalSideEffects(
        table: String,
        entity: Schema.Entity,
        schema: Schema,
        removedColumns: Set<String>,
        connection: SQLConnection
    ) throws {
        let sideObjects = try connection.rows(
            "SELECT 1 FROM sqlite_master WHERE type IN ('trigger', 'view') LIMIT 1")
        guard sideObjects.isEmpty else {
            throw SwiftDataError.migrationUnsupported("Attribute removal is unsupported when triggers or views exist.")
        }
        let tableSQL = try connection.rows(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ? COLLATE NOCASE", [.text(table)])
        guard tableSQL.count == 1,
            case let .text(createSQL)? = tableSQL.first?.first
        else {
            throw SwiftDataError.migrationUnsupported("Attribute removal requires a tracked physical table.")
        }
        let normalizedSQL = createSQL.uppercased()
        let checkConstraintPattern = try NSRegularExpression(pattern: #"(?i)\bCHECK\s*\("#)
        let sqlRange = NSRange(normalizedSQL.startIndex..<normalizedSQL.endIndex, in: normalizedSQL)
        guard checkConstraintPattern.firstMatch(in: normalizedSQL, range: sqlRange) == nil else {
            throw SwiftDataError.migrationUnsupported(
                "Attribute removal is unsupported for tables with CHECK constraints.")
        }
        let tables = try connection.rows(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        for row in tables {
            guard case let .text(name)? = row.first else { continue }
            let quotedName = "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
            let foreignKeys = try connection.rows("PRAGMA foreign_key_list(\(quotedName))")
            let referencesRemovedColumn = foreignKeys.contains { foreignKey in
                guard foreignKey.count > 4,
                    case let .text(referencedTable) = foreignKey[2],
                    case let .text(referencingColumn) = foreignKey[3]
                else { return false }
                if name.caseInsensitiveCompare(table) == .orderedSame {
                    return removedColumns.contains(referencingColumn.uppercased())
                }
                guard referencedTable.caseInsensitiveCompare(table) == .orderedSame,
                    case let .text(referencedColumn) = foreignKey[4]
                else { return false }
                return removedColumns.contains(referencedColumn.uppercased())
            }
            guard !referencesRemovedColumn else {
                throw SwiftDataError.migrationUnsupported(
                    "Attribute removal cannot change a column referenced by a foreign key.")
            }
        }
        let tableInfo = try connection.rows("PRAGMA table_info(\(table))")
        let expectedColumns: [(name: String, type: String, notNull: Int64, primaryKey: Int64)] =
            [
                ("Z_PK", "INTEGER", 0, 1),
                ("Z_ENT", "INTEGER", 0, 0),
                ("Z_OPT", "INTEGER", 0, 0),
            ]
            + (try entity.attributes.sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }).flatMap {
                attribute in
                if attribute.options.contains(.flattened) {
                    return try attribute.components.map { component in
                        let type = try SQLColumnType.resolve(
                            component.type, property: "\(entity.name).\(component.columnName)")
                        return ("Z\(component.columnName.uppercased())", type.rawValue, Int64(0), Int64(0))
                    }
                }
                let type = try SQLColumnType.resolve(
                    attribute.type, property: "\(entity.name).\(attribute.name)", options: attribute.options)
                return [("Z\(attribute.name.uppercased())", type.rawValue, Int64(0), Int64(0))]
            })
            + entity.relationships.compactMap { relationship in
                guard !relationship.isToMany,
                    !SchemaBuilder.isNonOwner(entity, relationship, schema: schema),
                    let mapping = schema.relationshipStorageMapping(
                        modelEntityName: entity.name, relationshipName: relationship.name)
                else { return nil }
                return ("Z\(mapping.storageColumnName.uppercased())", "INTEGER", 0, 0)
            }
        let expectedByName = Dictionary(uniqueKeysWithValues: expectedColumns.map { ($0.name, $0) })
        let normalizedRemovedColumns = Set(removedColumns.map { $0.uppercased() })
        guard normalizedRemovedColumns.isSubset(of: Set(expectedColumns.map(\.name))),
            tableInfo.count == expectedColumns.count,
            tableInfo.allSatisfy({ row in
                guard row.count > 5, case let .text(columnName) = row[1],
                    let expected = expectedByName[columnName]
                else { return false }
                return row[2] == .text(expected.type)
                    && row[3] == .int(expected.notNull) && row[4] == .null
                    && row[5] == .int(expected.primaryKey)
            })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Column removal requires a physical table matching the flat source schema layout.")
        }
        let extendedTableInfo = try connection.rows("PRAGMA table_xinfo(\(table))")
        guard
            !extendedTableInfo.contains(where: { row in
                row.count > 6 && row[6] != .int(0)
            })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Attribute removal is unsupported for tables with generated or hidden columns.")
        }
    }

    private static func validateSourceTableLayout(
        _ entity: Schema.Entity,
        schema: Schema,
        connection: SQLConnection
    ) throws {
        let table = "Z\(entity.name.uppercased())"
        let tableInfo = try connection.rows("PRAGMA table_info(\(table))")
        let expectedColumns: [(name: String, type: String, notNull: Int64, primaryKey: Int64)] =
            [
                ("Z_PK", "INTEGER", 0, 1),
                ("Z_ENT", "INTEGER", 0, 0),
                ("Z_OPT", "INTEGER", 0, 0),
            ]
            + (try entity.attributes.sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }).map {
                attribute in
                let type = try SQLColumnType.resolve(
                    attribute.type, property: "\(entity.name).\(attribute.name)", options: attribute.options)
                return ("Z\(attribute.name.uppercased())", type.rawValue, 0, 0)
            })
            + entity.relationships.compactMap { relationship in
                guard !relationship.isToMany,
                    !SchemaBuilder.isNonOwner(entity, relationship, schema: schema),
                    let mapping = schema.relationshipStorageMapping(
                        modelEntityName: entity.name, relationshipName: relationship.name)
                else { return nil }
                return ("Z\(mapping.storageColumnName.uppercased())", "INTEGER", 0, 0)
            }
        let expectedByName = Dictionary(uniqueKeysWithValues: expectedColumns.map { ($0.name, $0) })
        guard tableInfo.count == expectedColumns.count,
            tableInfo.allSatisfy({ row in
                guard row.count > 5, case let .text(columnName) = row[1],
                    let expected = expectedByName[columnName.uppercased()]
                else { return false }
                return row[2] == .text(expected.type)
                    && row[3] == .int(expected.notNull)
                    && row[4] == .null
                    && row[5] == .int(expected.primaryKey)
            })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Scalar addition requires a physical table matching the flat source schema layout.")
        }
        let extendedTableInfo = try connection.rows("PRAGMA table_xinfo(\(table))")
        guard !extendedTableInfo.contains(where: { $0.count > 6 && $0[6] != .int(0) }) else {
            throw SwiftDataError.migrationUnsupported(
                "Scalar addition is unsupported for tables with generated or hidden columns.")
        }
    }

    private static func validateGeneratedIndexesForAttributeRemoval(
        table: String,
        definitions: [IndexDefinition],
        connection: SQLConnection
    ) throws {
        for definition in definitions {
            let rows = try connection.rows(
                "SELECT sql, tbl_name FROM sqlite_master WHERE type = 'index' AND name = ? COLLATE NOCASE",
                [.text(definition.name)])
            let normalizedExpected = definition.statement.lowercased().filter { !$0.isWhitespace && $0 != ";" }
            let normalizedActual = rows.first?.first.flatMap { value -> String? in
                guard case let .text(sql) = value else { return nil }
                return sql.lowercased().filter { !$0.isWhitespace && $0 != ";" && $0 != "`" && $0 != "\"" }
            }
            guard rows.count == 1,
                normalizedActual == normalizedExpected,
                rows[0].count > 1,
                rows[0][1] == .text(table)
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Generated index \(definition.name) has unexpected SQL or constraint semantics.")
            }
            let quotedIndex = "\"\(definition.name.replacingOccurrences(of: "\"", with: "\"\""))\""
            let indexList = try connection.rows("PRAGMA index_list(\(table))")
            guard
                let metadata = indexList.first(where: { row in
                    guard row.count > 4, case let .text(indexName) = row[1] else { return false }
                    return indexName.caseInsensitiveCompare(definition.name) == .orderedSame
                }),
                metadata[2] == .int(definition.statement.hasPrefix("CREATE UNIQUE INDEX") ? 1 : 0),
                metadata[4] == .int(0)
            else {
                throw SwiftDataError.migrationUnsupported("Generated index \(definition.name) is partial or missing.")
            }
            let expectedColumns =
                definition.statement
                .split(separator: "(").last?
                .split(separator: ")").first?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).uppercased() } ?? []
            let info = try connection.rows("PRAGMA index_info(\(quotedIndex))")
            guard info.count == expectedColumns.count,
                info.enumerated().allSatisfy({ offset, row in
                    row.count > 2 && row[0] == .int(Int64(offset))
                        && row[2] == .text(expectedColumns[offset])
                })
            else {
                throw SwiftDataError.migrationUnsupported("Generated index \(definition.name) has unexpected keys.")
            }
        }
    }

    private static func validateIndexesForAttributeRemoval(
        table: String,
        column: String,
        removableIndexNames: Set<String>,
        knownIndexNames: Set<String>,
        connection: SQLConnection
    ) throws {
        let indexes = try connection.rows(
            "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? COLLATE NOCASE",
            [.text(table)])
        for row in indexes {
            guard row.count > 1, case let .text(name) = row[0] else { continue }
            let normalizedName = name.uppercased()
            if removableIndexNames.contains(normalizedName) { continue }
            guard !knownIndexNames.contains(normalizedName) else { continue }

            let quotedName = "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
            let indexedColumns = try connection.rows("PRAGMA index_info(\(quotedName))")
            let referencesColumn = indexedColumns.contains { indexRow in
                guard indexRow.count > 2, case let .text(indexedName) = indexRow[2] else { return false }
                return indexedName.caseInsensitiveCompare(column) == .orderedSame
            }
            let sqlReferencesColumn: Bool
            if case let .text(sql) = row[1] {
                sqlReferencesColumn =
                    sql.range(
                        of: #"(?i)(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: column)
                            + #"(?![A-Za-z0-9_])"#,
                        options: .regularExpression) != nil
            } else {
                sqlReferencesColumn = false
            }
            guard !referencesColumn, !sqlReferencesColumn else {
                throw SwiftDataError.migrationUnsupported(
                    "Attribute removal cannot preserve untracked index \(name) referencing \(column).")
            }
        }
    }

    private static func validateOptionalityBackfillSideEffects(
        table: String,
        column: String,
        connection: SQLConnection
    ) throws {
        let triggers = try connection.rows(
            "SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ? COLLATE NOCASE LIMIT 1",
            [.text(table)])
        guard triggers.isEmpty else {
            throw SwiftDataError.migrationUnsupported(
                "Optional-to-required backfill does not run user-defined triggers on \(table).")
        }
        let tables = try connection.rows(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        for row in tables {
            guard case let .text(name)? = row.first else { continue }
            let quotedName = "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
            let foreignKeys = try connection.rows("PRAGMA foreign_key_list(\(quotedName))")
            for foreignKey in foreignKeys {
                guard foreignKey.count > 4,
                    case let .text(referencedTable) = foreignKey[2],
                    case let .text(referencingColumn) = foreignKey[3]
                else { continue }
                let referencesColumn: Bool
                if case let .text(referencedColumn) = foreignKey[4] {
                    referencesColumn = referencedColumn.caseInsensitiveCompare(column) == .orderedSame
                } else {
                    referencesColumn = false
                }
                let referencesUpdatedColumn =
                    referencedTable.caseInsensitiveCompare(table) == .orderedSame && referencesColumn
                let updatesForeignKeyColumn =
                    name.caseInsensitiveCompare(table) == .orderedSame
                    && referencingColumn.caseInsensitiveCompare(column) == .orderedSame
                guard !referencesUpdatedColumn, !updatesForeignKeyColumn else {
                    throw SwiftDataError.migrationUnsupported(
                        "Optional-to-required backfill cannot change a foreign-key column in \(table).")
                }
            }
        }
    }

    private static func migrationDefaultLiteral(for attribute: Schema.Attribute) throws -> String? {
        guard let source = attribute.defaultValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if source == "nil" {
            guard attribute.isOptional else {
                throw SwiftDataError.migrationUnsupported(
                    "Required attribute \(attribute.name) cannot use nil as a migration default.")
            }
            return "NULL"
        }
        let typeName = attribute.type.split(separator: ".").last.map(String.init) ?? attribute.type
        switch typeName {
        case "Bool":
            guard source == "true" || source == "false" else { break }
            return source == "true" ? "1" : "0"
        case "Int", "Int64":
            guard let value = Int64(source) else { break }
            return String(value)
        case "Int8":
            guard let value = Int8(source) else { break }
            return String(value)
        case "Int16":
            guard let value = Int16(source) else { break }
            return String(value)
        case "Int32":
            guard let value = Int32(source) else { break }
            return String(value)
        case "UInt", "UInt64":
            guard let value = UInt64(source), value <= UInt64(Int64.max) else { break }
            return String(value)
        case "UInt8":
            guard let value = UInt8(source) else { break }
            return String(value)
        case "UInt16":
            guard let value = UInt16(source) else { break }
            return String(value)
        case "UInt32":
            guard let value = UInt32(source) else { break }
            return String(value)
        case "Float":
            guard let value = Float(source), value.isFinite else { break }
            return String(value)
        case "Double":
            guard let value = Double(source), value.isFinite else { break }
            return String(value)
        case "String":
            guard let data = source.data(using: .utf8),
                let value = try? JSONDecoder().decode(String.self, from: data)
            else { break }
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        case "Decimal":
            guard let value = Decimal(string: source, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN
            else { break }
            let text = NSDecimalNumber(decimal: value).stringValue
            return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        default:
            break
        }
        throw SwiftDataError.migrationUnsupported(
            "Attribute \(attribute.name) has a nonliteral or unsupported migration default.")
    }

    private struct RelationshipColumnRemoval {
        let relationship: Schema.Relationship
        let column: String
        let indexName: String
    }

    private static func planOptionalToOneRelationshipRemovals(
        _ removedRelationships: [Schema.Relationship],
        addedRelationships: [Schema.Relationship],
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceSchema: Schema,
        destinationSchema: Schema
    ) throws -> [RelationshipColumnRemoval] {
        let removedNames = Set(removedRelationships.map(\.name))
        let retainedRelationships = source.relationships.filter { !removedNames.contains($0.name) }
        guard !removedRelationships.isEmpty,
            addedRelationships.isEmpty,
            source.attributes.count == destination.attributes.count,
            source.attributes.allSatisfy({ destination.attributes.contains($0) }),
            destination.relationships.count == source.relationships.count - removedRelationships.count,
            retainedRelationships.allSatisfy({ destination.relationships.contains($0) }),
            destination.relationships.count == retainedRelationships.count,
            destination.relationships.allSatisfy({ relationship in
                retainedRelationships.contains(relationship)
            }),
            source.indexes == destination.indexes,
            source.superentityName == destination.superentityName,
            sourceSchema.entityIDsByName == destinationSchema.entityIDsByName,
            Set(sourceSchema.entities.map(\.name)) == Set(destinationSchema.entities.map(\.name)),
            sourceSchema.entities.filter({ $0.name != source.name }).allSatisfy({ sourceEntity in
                guard let destinationEntity = destinationSchema.entity(forName: sourceEntity.name) else { return false }
                return equivalentEntityMetadata(sourceEntity, destinationEntity)
            }),
            source.superentityName == nil,
            destination.superentityName == nil,
            !sourceSchema.entities.contains(where: { $0.superentityName == source.name })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Multiple relationship removals must be the only edit to a flat root schema.")
        }

        return try removedRelationships.map { relationship in
            guard !relationship.isToMany,
                relationship.isOptional,
                relationship.inverse == nil,
                relationship.originalName == nil,
                relationship.minimumModelCount == nil || relationship.minimumModelCount == 0,
                relationship.maximumModelCount == nil || relationship.maximumModelCount == 1,
                relationship.deleteRule == .nullify || relationship.deleteRule == .noAction,
                relationship.destination != source.name,
                let targetSource = sourceSchema.entity(forName: relationship.destination),
                let targetDestination = destinationSchema.entity(forName: relationship.destination),
                targetSource.superentityName == nil,
                targetDestination.superentityName == nil,
                !sourceSchema.entities.contains(where: { $0.superentityName == targetSource.name }),
                !destinationSchema.entities.contains(where: { $0.superentityName == targetDestination.name }),
                !sourceSchema.entities.contains(where: { candidate in
                    candidate.relationships.contains(where: { $0.inverse == relationship.name })
                }),
                !destinationSchema.entities.contains(where: { candidate in
                    candidate.relationships.contains(where: { $0.inverse == relationship.name })
                }),
                let mapping = sourceSchema.relationshipStorageMapping(
                    modelEntityName: source.name, relationshipName: relationship.name),
                !SchemaBuilder.isNonOwner(source, relationship, schema: sourceSchema),
                mapping.ownerRootEntityName == source.name,
                mapping.declaringEntityName == source.name
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Only optional owning no-inverse to-one relationships to retained roots can be removed.")
            }
            return RelationshipColumnRemoval(
                relationship: relationship,
                column: "Z\(mapping.storageColumnName.uppercased())",
                indexName:
                    "Z\(mapping.ownerRootEntityName.uppercased())_Z\(mapping.relationshipName.uppercased())_INDEX")
        }
    }

    private static func migrateRelationships(
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceSchema: Schema,
        schema: Schema,
        pairedInverseRemovals: [PairedInverseRelationshipRemoval],
        toManyRemovalPlan: OwnerOnlyToManyRemovalBatchPlan?,
        connection: SQLConnection,
        existing: Set<String>
    ) throws {
        let mappedSources = Set(
            destination.relationships.compactMap { relationship in
                source.relationships.first(where: { sourceRelationship in
                    sourceRelationship.name.caseInsensitiveCompare(relationship.name) == .orderedSame
                        || relationship.originalName.map { originalName in
                            sourceRelationship.name.caseInsensitiveCompare(originalName) == .orderedSame
                        } == true
                })?.name
            })
        let removedRelationships = source.relationships.filter { !mappedSources.contains($0.name) }
        let addedRelationships = destination.relationships.filter { relationship in
            !source.relationships.contains(where: { sourceRelationship in
                sourceRelationship.name.caseInsensitiveCompare(relationship.name) == .orderedSame
                    || relationship.originalName.map { originalName in
                        sourceRelationship.name.caseInsensitiveCompare(originalName) == .orderedSame
                    } == true
            })
        }
        let ownerPairRemovals = pairedInverseRemovals.filter { $0.ownerEntityName == source.name }
        let inversePairRemovals = pairedInverseRemovals.filter { $0.inverseEntityName == source.name }
        if !ownerPairRemovals.isEmpty || !inversePairRemovals.isEmpty {
            let plannedNames = Set(
                ownerPairRemovals.map(\.ownerRelationshipName)
                    + inversePairRemovals.map(\.inverseRelationshipName))
            guard ownerPairRemovals.count + inversePairRemovals.count == plannedNames.count,
                removedRelationships.count == plannedNames.count,
                Set(removedRelationships.map(\.name)) == plannedNames,
                addedRelationships.isEmpty,
                source.attributes == destination.attributes,
                source.indexes == destination.indexes,
                source.superentityName == destination.superentityName
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Paired inverse relationship removal cannot be combined with other entity edits.")
            }
            for removal in ownerPairRemovals {
                guard
                    let relationship = source.relationships.first(where: {
                        $0.name == removal.ownerRelationshipName
                    }),
                    removal.ownerEntityName != removal.inverseEntityName,
                    let mapping = sourceSchema.relationshipStorageMapping(
                        modelEntityName: source.name, relationshipName: relationship.name),
                    "Z\(mapping.storageColumnName.uppercased())" == removal.column,
                    existing.contains(removal.column),
                    Database.sqliteLibVersionNumber >= 3_035_000
                else {
                    throw SwiftDataError.migrationUnsupported(
                        "Paired inverse relationship removal requires the planned owner foreign-key column.")
                }
            }
            for removal in ownerPairRemovals.sorted(by: { $0.indexName < $1.indexName }) {
                try connection.execute("DROP INDEX IF EXISTS \(removal.indexName)")
            }
            for removal in ownerPairRemovals.sorted(by: { $0.column < $1.column }) {
                try connection.execute("ALTER TABLE Z\(source.name.uppercased()) DROP COLUMN \(removal.column)")
            }
            return
        }
        let plannedToManyRemovals = toManyRemovalPlan?.removedRelationshipNamesByOwner[source.name] ?? []
        if !plannedToManyRemovals.isEmpty {
            let removedNames = Set(removedRelationships.map(\.name))
            guard removedNames == plannedToManyRemovals,
                addedRelationships.isEmpty,
                source.attributes == destination.attributes,
                source.indexes == destination.indexes,
                source.superentityName == destination.superentityName
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Batched to-many removals cannot be combined with other entity edits.")
            }
            return
        }
        let changedMappedToMany = destination.relationships.contains { relationship in
            guard relationship.isToMany,
                let original = source.relationships.first(where: {
                    $0.name == relationship.name || $0.name == relationship.originalName
                })
            else { return false }
            return original != relationship
        }
        guard !changedMappedToMany else {
            throw SwiftDataError.migrationUnsupported(
                "Changing a to-many relationship requires explicit join-table migration metadata.")
        }
        let removedToMany = removedRelationships.filter(\.isToMany)
        let addedToMany = addedRelationships.filter(\.isToMany)
        if !removedToMany.isEmpty || !addedToMany.isEmpty {
            guard removedRelationships.count + addedRelationships.count == 1,
                removedToMany.count + addedToMany.count == 1
            else {
                throw SwiftDataError.migrationUnsupported(
                    "To-many join migration must add or remove exactly one relationship.")
            }
            try migrateFlatOwnerOnlyToMany(
                source: source,
                destination: destination,
                sourceSchema: sourceSchema,
                destinationSchema: schema,
                removed: removedToMany.first,
                added: addedToMany.first,
                connection: connection)
            return
        }
        guard removedRelationships.count + mappedSources.count == source.relationships.count else {
            throw SwiftDataError.migrationUnsupported(
                "Adding or removing relationships requires graph transformation metadata.")
        }
        if !removedRelationships.isEmpty {
            guard removedRelationships.count == 1, addedRelationships.isEmpty,
                let relationship = removedRelationships.first,
                source.attributes.count == destination.attributes.count,
                source.attributes.allSatisfy({ destination.attributes.contains($0) }),
                destination.relationships.count == source.relationships.count - 1,
                source.relationships.filter({ $0.name != relationship.name }).allSatisfy({ retainedRelationship in
                    destination.relationships.contains(retainedRelationship)
                }),
                source.indexes == destination.indexes,
                source.superentityName == destination.superentityName,
                sourceSchema.entityIDsByName == schema.entityIDsByName,
                sourceSchema.entities.count == schema.entities.count,
                sourceSchema.entities.filter({ $0.name != source.name }).allSatisfy({ sourceEntity in
                    guard let destinationEntity = schema.entity(forName: sourceEntity.name) else { return false }
                    return equivalentEntityMetadata(sourceEntity, destinationEntity)
                }),
                !relationship.isToMany,
                relationship.isOptional,
                relationship.inverse == nil,
                relationship.originalName == nil,
                relationship.minimumModelCount == nil || relationship.minimumModelCount == 0,
                relationship.maximumModelCount == nil || relationship.maximumModelCount == 1,
                relationship.deleteRule == .nullify || relationship.deleteRule == .noAction,
                relationship.destination != source.name,
                source.superentityName == nil,
                !sourceSchema.entities.contains(where: { $0.superentityName == source.name }),
                !sourceSchema.entities.contains(where: { entity in
                    entity.name != source.name
                        && entity.relationships.contains(where: { $0.inverse == relationship.name })
                }),
                let mapping = sourceSchema.relationshipStorageMapping(
                    modelEntityName: source.name, relationshipName: relationship.name),
                !SchemaBuilder.isNonOwner(source, relationship, schema: sourceSchema),
                mapping.ownerRootEntityName == source.name,
                mapping.declaringEntityName == source.name
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Only one unconstrained owning optional to-one relationship can be removed here.")
            }
            let column = "Z\(mapping.storageColumnName.uppercased())"
            guard existing.contains(column), Database.sqliteLibVersionNumber >= 3_035_000 else {
                throw SwiftDataError.migrationUnsupported(
                    "Relationship removal requires an existing foreign-key column and SQLite 3.35 or newer.")
            }
            try validateOptionalRelationshipColumnRemoval(
                table: "Z\(source.name.uppercased())",
                column: column,
                relationship: relationship,
                owner: source,
                schema: sourceSchema,
                connection: connection)
        }
        let sourceMany = Set(source.relationships.filter(\.isToMany).map(\.name))
        let destinationMany = Set(
            destination.relationships.filter(\.isToMany).compactMap { relationship in
                source.relationships.first(where: {
                    $0.name == relationship.name || $0.name == relationship.originalName
                })?.name
            })
        guard sourceMany == destinationMany else {
            throw SwiftDataError.migrationUnsupported("To-many relationship join layouts cannot be transformed safely.")
        }
        let existingColumnNames = Set(existing.map { $0.uppercased() })
        let occupiedColumns = Set(
            destination.attributes.flatMap { attribute in
                attribute.options.contains(.flattened)
                    ? attribute.components.map { "Z\($0.columnName)".uppercased() }
                    : ["Z\(attribute.name)".uppercased()]
            }
                + destination.relationships.compactMap { relationship in
                    guard
                        source.relationships.contains(where: {
                            $0.name == relationship.name || $0.name == relationship.originalName
                        }), !relationship.isToMany,
                        let mapping = schema.relationshipStorageMapping(
                            modelEntityName: destination.name, relationshipName: relationship.name)
                    else { return nil }
                    return "Z\(mapping.storageColumnName)".uppercased()
                })
        for relationship in destination.relationships
        where !source.relationships.contains(where: {
            $0.name == relationship.name || $0.name == relationship.originalName
        }) {
            guard !relationship.isToMany,
                relationship.isOptional,
                relationship.inverse == nil,
                relationship.originalName == nil,
                relationship.minimumModelCount == nil || relationship.minimumModelCount == 0,
                relationship.maximumModelCount == nil || relationship.maximumModelCount == 1,
                relationship.deleteRule == .nullify || relationship.deleteRule == .noAction,
                relationship.destination != destination.name,
                let target = schema.entity(forName: relationship.destination),
                target.superentityName == nil,
                !schema.entities.contains(where: { $0.superentityName == target.name }),
                let mapping = schema.relationshipStorageMapping(
                    modelEntityName: destination.name, relationshipName: relationship.name),
                mapping.ownerRootEntityName == destination.name,
                mapping.declaringEntityName == destination.name
            else {
                throw SwiftDataError.migrationUnsupported(
                    "New flat relationships must be optional owning to-one links to existing flat entities.")
            }
            let columnName = "Z\(mapping.storageColumnName)".uppercased()
            guard !existingColumnNames.contains(columnName), !occupiedColumns.contains(columnName) else {
                throw SwiftDataError.migrationUnsupported(
                    "New relationship column '\(columnName)' collides with an existing column.")
            }
            try connection.execute("ALTER TABLE Z\(destination.name.uppercased()) ADD COLUMN \(columnName) INTEGER")
        }
        for relationship in removedRelationships {
            let mapping = try validatedRemovedRelationshipMapping(
                relationship, owner: source, sourceSchema: sourceSchema)
            let column = "Z\(mapping.storageColumnName.uppercased())"
            let indexName =
                "Z\(mapping.ownerRootEntityName.uppercased())_Z\(mapping.relationshipName.uppercased())_INDEX"
            try connection.execute("DROP INDEX IF EXISTS \(indexName)")
            try connection.execute("ALTER TABLE Z\(source.name.uppercased()) DROP COLUMN \(column)")
        }
        for relationship in destination.relationships where !relationship.isToMany {
            guard
                let old = source.relationships.first(where: {
                    $0.name == relationship.name || $0.name == relationship.originalName
                })
            else { continue }
            guard old.isToMany == relationship.isToMany else {
                throw SwiftDataError.migrationUnsupported("Relationship cardinality changed.")
            }
            if old.name != relationship.name {
                try connection.execute(
                    "ALTER TABLE Z\(destination.name.uppercased()) RENAME COLUMN Z\(old.name.uppercased()) TO Z\(relationship.name.uppercased())"
                )
            }
        }
    }

    private static func migrateFlatOwnerOnlyToMany(
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceSchema: Schema,
        destinationSchema: Schema,
        removed: Schema.Relationship?,
        added: Schema.Relationship?,
        connection: SQLConnection
    ) throws {
        if let removed, added == nil {
            guard
                let plan = try planOwnerOnlyToManyRemoval(
                    source: source,
                    destination: destination,
                    sourceSchema: sourceSchema,
                    destinationSchema: destinationSchema,
                    relationship: removed,
                    addedAttributes: [],
                    connection: connection)
            else {
                throw SwiftDataError.migrationUnsupported("To-many relationship removal could not be planned.")
            }
            try applyOwnerOnlyToManyRemoval(plan, connection: connection)
            return
        }
        let expectedDestinationRelationshipCount = source.relationships.count + (added == nil ? -1 : 1)
        guard (removed == nil) != (added == nil),
            let relationship = removed ?? added,
            relationship.isToMany,
            relationship.inverse == nil,
            relationship.originalName == nil,
            relationship.minimumModelCount == nil || relationship.minimumModelCount == 0,
            relationship.maximumModelCount == nil,
            relationship.deleteRule == .nullify || relationship.deleteRule == .noAction,
            relationship.destination != source.name,
            source.name == destination.name,
            source.superentityName == nil,
            destination.superentityName == nil,
            !sourceSchema.entities.contains(where: { $0.superentityName == source.name }),
            !destinationSchema.entities.contains(where: { $0.superentityName == destination.name }),
            source.attributes.count == destination.attributes.count,
            source.attributes.allSatisfy({ destination.attributes.contains($0) }),
            source.indexes == destination.indexes,
            source.superentityName == destination.superentityName,
            sourceSchema.entityIDsByName == destinationSchema.entityIDsByName,
            Set(sourceSchema.entities.map(\.name)) == Set(destinationSchema.entities.map(\.name)),
            sourceSchema.entities.filter({ $0.name != source.name }).allSatisfy({ sourceEntity in
                guard let destinationEntity = destinationSchema.entity(forName: sourceEntity.name) else { return false }
                return equivalentEntityMetadata(sourceEntity, destinationEntity)
            }),
            source.relationships.filter({ $0.name != removed?.name }).allSatisfy({ retained in
                destination.relationships.contains(retained)
            }),
            destination.relationships.filter({ $0.name != added?.name }).allSatisfy({ retained in
                source.relationships.contains(retained)
            }),
            destination.relationships.count == expectedDestinationRelationshipCount,
            let targetSource = sourceSchema.entity(forName: relationship.destination),
            let targetDestination = destinationSchema.entity(forName: relationship.destination),
            targetSource.superentityName == nil,
            targetDestination.superentityName == nil,
            !sourceSchema.entities.contains(where: { $0.superentityName == targetSource.name }),
            !destinationSchema.entities.contains(where: { $0.superentityName == targetDestination.name })
        else {
            throw SwiftDataError.migrationUnsupported(
                "To-many migration is limited to one unconstrained no-inverse relationship between flat root entities.")
        }
        guard
            !hasReciprocalRelationship(
                named: relationship.name, from: source.name, to: relationship.destination, schema: sourceSchema),
            !hasReciprocalRelationship(
                named: relationship.name, from: source.name, to: relationship.destination, schema: destinationSchema)
        else {
            throw SwiftDataError.migrationUnsupported(
                "Inverse-backed to-many relationships require graph migration metadata.")
        }
        let relationshipSchema = removed == nil ? destinationSchema : sourceSchema
        let relationshipOwner = removed == nil ? destination : source
        guard
            let joinTable = SchemaBuilder.joinTableName(
                for: relationshipOwner, relationship: relationship, schema: relationshipSchema)
        else {
            throw SwiftDataError.migrationUnsupported("Relationship does not map to an owner-only join table.")
        }
        let schema = relationshipSchema
        let built = try SchemaBuilder.build(schema)
        let tablePrefix = "CREATE TABLE \(joinTable) "
        let tableStatement = built.statements.first(where: { $0.hasPrefix(tablePrefix) })
        let uniqueIndexName = "\(joinTable)_UNIQUE_INDEX"
        let reverseIndexName = "\(joinTable)_Z_B_INDEX"
        let uniqueIndexStatement = built.statements.first(where: {
            $0.hasPrefix("CREATE UNIQUE INDEX \(uniqueIndexName) ")
        })
        let reverseIndexStatement = built.statements.first(where: {
            $0.hasPrefix("CREATE INDEX \(reverseIndexName) ")
        })
        guard let tableStatement, let uniqueIndexStatement, let reverseIndexStatement else {
            throw SwiftDataError.migrationUnsupported("SchemaBuilder did not generate the expected join-table objects.")
        }
        if added != nil {
            let plannedNames = [joinTable, uniqueIndexName, reverseIndexName].map { $0.uppercased() }
            let existingNames = Set(
                try connection.rows(
                    "SELECT name FROM sqlite_master WHERE type IN ('table', 'index', 'view', 'trigger')"
                )
                .compactMap { row -> String? in
                    guard case let .text(name)? = row.first else { return nil }
                    return name.uppercased()
                })
            guard Set(plannedNames).isDisjoint(with: existingNames) else {
                throw SwiftDataError.migrationUnsupported(
                    "New relationship join-table objects collide with existing objects.")
            }
            try validateJoinTableNoPhysicalForeignKeys(
                table: joinTable, checkReferences: false, connection: connection)
            try validateNoJoinTableDependencies(joinTable, connection: connection)
            try connection.execute(tableStatement)
            try connection.execute(uniqueIndexStatement)
            try connection.execute(reverseIndexStatement)
            return
        }

        try validateJoinTableNoPhysicalForeignKeys(
            table: joinTable, checkReferences: true, connection: connection)
        try validateExistingOwnerOnlyJoinTable(
            table: joinTable,
            uniqueIndexName: uniqueIndexName,
            reverseIndexName: reverseIndexName,
            connection: connection)
        try connection.execute("DROP TABLE \(joinTable)")
    }

    private static func planOwnerOnlyToManyRemoval(
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceSchema: Schema,
        destinationSchema: Schema,
        relationship: Schema.Relationship,
        addedAttributes: [Schema.Attribute],
        connection: SQLConnection
    ) throws -> OwnerOnlyToManyRemovalPlan? {
        guard relationship.isToMany,
            relationship.inverse == nil,
            relationship.originalName == nil,
            relationship.minimumModelCount == nil || relationship.minimumModelCount == 0,
            relationship.maximumModelCount == nil,
            relationship.deleteRule == .nullify || relationship.deleteRule == .noAction,
            relationship.destination != source.name,
            source.name == destination.name,
            source.superentityName == nil,
            destination.superentityName == nil,
            !sourceSchema.entities.contains(where: { $0.superentityName == source.name }),
            !destinationSchema.entities.contains(where: { $0.superentityName == destination.name }),
            sourceSchema.entityIDsByName == destinationSchema.entityIDsByName,
            Set(sourceSchema.entities.map(\.name)) == Set(destinationSchema.entities.map(\.name)),
            source.relationships.contains(relationship),
            !destination.relationships.contains(where: { $0.name == relationship.name }),
            source.attributes.allSatisfy({ destination.attributes.contains($0) }),
            addedAttributes.allSatisfy({ destination.attributes.contains($0) }),
            destination.attributes.count == source.attributes.count + addedAttributes.count,
            source.indexes == destination.indexes,
            destination.relationships == source.relationships.filter({ $0.name != relationship.name }),
            sourceSchema.entities.filter({ $0.name != source.name }).allSatisfy({ entity in
                guard let destinationEntity = destinationSchema.entity(forName: entity.name) else { return false }
                return equivalentEntityMetadata(entity, destinationEntity)
            }),
            let targetSource = sourceSchema.entity(forName: relationship.destination),
            let targetDestination = destinationSchema.entity(forName: relationship.destination),
            targetSource.superentityName == nil,
            targetDestination.superentityName == nil,
            !sourceSchema.entities.contains(where: { $0.superentityName == targetSource.name }),
            !destinationSchema.entities.contains(where: { $0.superentityName == targetDestination.name }),
            !hasReciprocalRelationship(
                named: relationship.name, from: source.name, to: relationship.destination, schema: sourceSchema),
            !hasReciprocalRelationship(
                named: relationship.name, from: source.name, to: relationship.destination, schema: destinationSchema)
        else { return nil }

        return try planOwnerOnlyToManyJoinTableRemoval(
            relationship, owner: source, schema: sourceSchema, connection: connection)
    }

    private static func planOwnerOnlyToManyJoinTableRemoval(
        _ relationship: Schema.Relationship,
        owner: Schema.Entity,
        schema: Schema,
        connection: SQLConnection
    ) throws -> OwnerOnlyToManyRemovalPlan? {
        guard relationship.isToMany,
            relationship.inverse == nil,
            relationship.originalName == nil,
            relationship.minimumModelCount == nil || relationship.minimumModelCount == 0,
            relationship.maximumModelCount == nil,
            relationship.deleteRule == .nullify || relationship.deleteRule == .noAction,
            relationship.destination != owner.name,
            let target = schema.entity(forName: relationship.destination),
            target.superentityName == nil,
            !schema.entities.contains(where: { $0.superentityName == target.name }),
            !hasReciprocalRelationship(
                named: relationship.name, from: owner.name, to: relationship.destination, schema: schema),
            let joinTable = SchemaBuilder.joinTableName(for: owner, relationship: relationship, schema: schema)
        else { return nil }

        let built = try SchemaBuilder.build(schema)
        let tableStatement = built.statements.first(where: { $0.hasPrefix("CREATE TABLE \(joinTable) ") })
        let uniqueIndexName = "\(joinTable)_UNIQUE_INDEX"
        let reverseIndexName = "\(joinTable)_Z_B_INDEX"
        guard tableStatement != nil,
            built.statements.contains(where: { $0.hasPrefix("CREATE UNIQUE INDEX \(uniqueIndexName) ") }),
            built.statements.contains(where: { $0.hasPrefix("CREATE INDEX \(reverseIndexName) ") })
        else {
            throw SwiftDataError.migrationUnsupported("SchemaBuilder did not generate the expected join-table objects.")
        }
        try validateJoinTableNoPhysicalForeignKeys(table: joinTable, checkReferences: true, connection: connection)
        try validateExistingOwnerOnlyJoinTable(
            table: joinTable,
            uniqueIndexName: uniqueIndexName,
            reverseIndexName: reverseIndexName,
            connection: connection)
        return OwnerOnlyToManyRemovalPlan(joinTable: joinTable)
    }

    private static func applyOwnerOnlyToManyRemoval(
        _ plan: OwnerOnlyToManyRemovalPlan,
        connection: SQLConnection
    ) throws {
        try connection.execute("DROP TABLE \(plan.joinTable)")
    }

    private static func planMultipleFlatOwnerOnlyToManyRemovals(
        source: Schema,
        destination: Schema,
        sourceIndexSQL: [String: String],
        excludedEndpoints: Set<String>,
        connection: SQLConnection
    ) throws -> OwnerOnlyToManyRemovalBatchPlan? {
        let destinationNamesByFoldedName = Dictionary(
            uniqueKeysWithValues: destination.entities.map { ($0.name.uppercased(), $0.name) })
        let sourceNamesByFoldedName = Dictionary(
            uniqueKeysWithValues: source.entities.map { ($0.name.uppercased(), $0.name) })
        guard Set(sourceNamesByFoldedName.keys) == Set(destinationNamesByFoldedName.keys) else { return nil }
        guard
            source.entities.allSatisfy({ entity in
                destinationNamesByFoldedName[entity.name.uppercased()] == entity.name
            })
        else {
            throw SwiftDataError.migrationUnsupported("Entity names cannot change case during relationship removal.")
        }
        let destinationByName = Dictionary(uniqueKeysWithValues: destination.entities.map { ($0.name, $0) })
        let removedByOwnerEntries = source.entities.compactMap { sourceEntity -> (String, [Schema.Relationship])? in
            guard let destinationEntity = destinationByName[sourceEntity.name] else { return nil }
            let removed = sourceEntity.relationships.filter { relationship in
                guard !excludedEndpoints.contains("\(sourceEntity.name).\(relationship.name)") else { return false }
                return !destinationEntity.relationships.contains(where: {
                    $0.name.caseInsensitiveCompare(relationship.name) == .orderedSame
                        || $0.originalName?.caseInsensitiveCompare(relationship.name) == .orderedSame
                })
            }
            return (sourceEntity.name, removed)
        }
        guard removedByOwnerEntries.count == source.entities.count else { return nil }
        let removedByOwner = Dictionary(uniqueKeysWithValues: removedByOwnerEntries)
        let allRemovedEndpoints = source.entities.flatMap { entity in
            entity.relationships.compactMap { relationship -> String? in
                guard let next = destinationByName[entity.name],
                    !next.relationships.contains(where: {
                        $0.name.caseInsensitiveCompare(relationship.name) == .orderedSame
                            || $0.originalName?.caseInsensitiveCompare(relationship.name) == .orderedSame
                    })
                else { return nil }
                return "\(entity.name).\(relationship.name)"
            }
        }
        let excludedRemovalEndpoints = allRemovedEndpoints.filter(excludedEndpoints.contains)
        if !excludedRemovalEndpoints.isEmpty {
            guard excludedRemovalEndpoints.count == allRemovedEndpoints.count else {
                throw SwiftDataError.migrationUnsupported(
                    "Paired inverse removals cannot be combined with owner-only join removals.")
            }
            return nil
        }
        let removedRelationships = removedByOwner.values.flatMap { $0 }
        let allRemovedRelationships = source.entities.flatMap { entity in
            entity.relationships.filter { relationship in
                !destinationByName[entity.name, default: entity].relationships.contains(where: {
                    $0.name.caseInsensitiveCompare(relationship.name) == .orderedSame
                        || $0.originalName?.caseInsensitiveCompare(relationship.name) == .orderedSame
                })
            }
        }
        guard allRemovedRelationships.count > 1 else { return nil }
        if allRemovedRelationships.allSatisfy({ !$0.isToMany }) { return nil }
        guard allRemovedRelationships.allSatisfy(\.isToMany) else {
            throw SwiftDataError.migrationUnsupported(
                "Mixed to-one and to-many relationship removals cannot be batched.")
        }
        guard removedRelationships.count == allRemovedRelationships.count else {
            throw SwiftDataError.migrationUnsupported(
                "Paired inverse removals cannot be combined with owner-only join removals.")
        }
        let changedOwnerNames = Set(removedByOwner.filter { !$0.value.isEmpty }.map(\.key))
        let addedAttributeEntries: [(String, [Schema.Attribute])] = try source.entities.compactMap { entity in
            guard let next = destinationByName[entity.name] else { return nil }
            let mappings = try attributeMappings(source: entity, destination: next)
            let added = mappings.filter { $0.source == nil }.map(\.destination)
            guard !added.isEmpty else {
                guard mappings.count == entity.attributes.count,
                    mappings.allSatisfy({ $0.source == $0.destination })
                else {
                    throw SwiftDataError.migrationUnsupported(
                        "Join-removal batches cannot rename or remove scalar attributes.")
                }
                return nil
            }
            guard removedByOwner[entity.name]?.isEmpty == false,
                mappings.count == next.attributes.count,
                mappings.compactMap({ $0.source }).count == entity.attributes.count,
                try mappings.allSatisfy({ mapping in
                    guard let old = mapping.source else {
                        let attribute = mapping.destination
                        let literal = try migrationDefaultLiteral(for: attribute)
                        return (attribute.isOptional || literal != nil)
                            && attribute.originalName == nil
                            && attribute.components.isEmpty
                            && !attribute.options.contains(.unique)
                            && !attribute.options.contains(.codable)
                            && !attribute.options.contains(.flattened)
                            && !attribute.options.contains(.externalStorage)
                            && !attribute.options.contains(where: {
                                if case .transformable = $0 { true } else { false }
                            })
                    }
                    return old == mapping.destination
                }),
                added.allSatisfy({ attribute in
                    attribute.originalName == nil
                        && attribute.components.isEmpty
                        && !attribute.options.contains(.unique)
                        && !attribute.options.contains(.codable)
                        && !attribute.options.contains(.flattened)
                        && !attribute.options.contains(.externalStorage)
                        && !attribute.options.contains(where: {
                            if case .transformable = $0 { true } else { false }
                        })
                }),
                entity.attributes.allSatisfy({ old in next.attributes.contains(old) }),
                entity.indexes.filter(\.isUnique).count == next.indexes.filter(\.isUnique).count,
                entity.indexes.filter(\.isUnique).allSatisfy({ next.indexes.contains($0) }),
                Set(entity.attributes.filter({ $0.options.contains(.unique) }).map(\.name))
                    == Set(next.attributes.filter({ $0.options.contains(.unique) }).map(\.name))
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Join-removal scalar additions require optional or literal-defaulted flat attributes.")
            }
            for attribute in added {
                _ = try SQLColumnType.resolve(
                    attribute.type, property: "\(next.name).\(attribute.name)", options: attribute.options)
                _ = try migrationDefaultLiteral(for: attribute)
            }
            let existingColumns = try tableColumns("Z\(entity.name.uppercased())", connection: connection)
            let addedColumns = Set(added.map { "Z\($0.name.uppercased())" })
            guard addedColumns.count == added.count, addedColumns.isDisjoint(with: existingColumns) else {
                throw SwiftDataError.migrationUnsupported(
                    "Added scalar columns collide with the physical source table.")
            }
            let oldDefinitions = indexDefinitions(for: entity, schema: source)
            let newDefinitions = indexDefinitions(for: next, schema: destination)
            let oldNames = Set(oldDefinitions.map { $0.name.uppercased() })
            let newNames = Set(newDefinitions.map { $0.name.uppercased() })
            guard
                newNames.subtracting(oldNames).allSatisfy({ newName in
                    oldDefinitions.allSatisfy({ $0.name.uppercased() != newName })
                })
            else {
                throw SwiftDataError.migrationUnsupported("Destination index names collide during to-many removal.")
            }
            let oldUniqueDefinitions = oldDefinitions.filter { $0.statement.hasPrefix("CREATE UNIQUE INDEX") }
            let newUniqueDefinitions = newDefinitions.filter { $0.statement.hasPrefix("CREATE UNIQUE INDEX") }
            guard oldUniqueDefinitions.count == newUniqueDefinitions.count,
                oldUniqueDefinitions.allSatisfy({ newUniqueDefinitions.contains($0) }),
                newDefinitions.allSatisfy({ definition in
                    !definition.columns.contains(where: { addedColumns.contains($0.uppercased()) })
                })
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Join-removal scalar additions cannot change unique or retained index definitions.")
            }
            return (entity.name, added)
        }
        let addedAttributesByOwner = Dictionary(uniqueKeysWithValues: addedAttributeEntries)

        guard source.entityIDsByName == destination.entityIDsByName,
            source.entities.allSatisfy({ $0.superentityName == nil }),
            destination.entities.allSatisfy({ $0.superentityName == nil }),
            source.entities.allSatisfy({ entity in
                guard let next = destinationByName[entity.name] else { return false }
                let hasScalarAdditions = addedAttributesByOwner[entity.name] != nil
                return
                    (hasScalarAdditions
                    ? (entity.attributes.allSatisfy(next.attributes.contains)
                        && next.attributes.count == entity.attributes.count
                            + (addedAttributesByOwner[entity.name]?.count ?? 0)
                        && addedAttributesByOwner[entity.name]?.allSatisfy(next.attributes.contains) == true)
                    : entity.attributes == next.attributes)
                    && entity.indexes == next.indexes
                    && entity.superentityName == next.superentityName
                    && (changedOwnerNames.contains(entity.name)
                        ? next.relationships
                            == entity.relationships.filter {
                                !(removedByOwner[entity.name]?.contains($0) ?? false)
                            }
                        : entity.relationships == next.relationships)
            })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Batched to-many removals must be the only schema edits on flat root entities.")
        }

        let sourceSchema = source
        var relationshipNamesByOwner: [String: Set<String>] = [:]
        var plans: [OwnerOnlyToManyRemovalPlan] = []
        for sourceEntity in source.entities.sorted(by: {
            $0.name.utf8.lexicographicallyPrecedes($1.name.utf8)
        }) {
            let removed = removedByOwner[sourceEntity.name] ?? []
            guard !removed.isEmpty else { continue }
            guard let destinationEntity = destinationByName[sourceEntity.name] else {
                throw SwiftDataError.migrationUnsupported("Destination schema omits a retained owner entity.")
            }
            guard
                (addedAttributesByOwner[sourceEntity.name] != nil
                    ? sourceEntity.attributes.allSatisfy(destinationEntity.attributes.contains)
                        && destinationEntity.attributes.count == sourceEntity.attributes.count
                            + (addedAttributesByOwner[sourceEntity.name]?.count ?? 0)
                    : sourceEntity.attributes == destinationEntity.attributes),
                sourceEntity.indexes == destinationEntity.indexes,
                sourceEntity.superentityName == destinationEntity.superentityName
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Batched to-many removal cannot be combined with entity metadata changes.")
            }
            let removedByEntity = Set(removed.map(\.name))
            let actualRemovedNames = Set(
                sourceEntity.relationships.compactMap { relationship -> String? in
                    destinationEntity.relationships.contains(where: {
                        $0.name.caseInsensitiveCompare(relationship.name) == .orderedSame
                            || $0.originalName?.caseInsensitiveCompare(relationship.name) == .orderedSame
                    }) ? nil : relationship.name
                })
            let plannedAttributes = addedAttributesByOwner[sourceEntity.name] ?? []
            let plannedScalarAdditionNames = Set(plannedAttributes.map(\.name))
            let retainedRelationships = sourceEntity.relationships.filter { !removedByEntity.contains($0.name) }
            guard actualRemovedNames == removedByEntity,
                retainedRelationships == destinationEntity.relationships,
                destinationEntity.attributes.count == sourceEntity.attributes.count + plannedAttributes.count,
                sourceEntity.attributes.allSatisfy(destinationEntity.attributes.contains),
                plannedAttributes.allSatisfy(destinationEntity.attributes.contains),
                Set(
                    destinationEntity.attributes.filter({ attribute in
                        !sourceEntity.attributes.contains(where: { $0.name == attribute.name })
                    }).map(\.name)) == plannedScalarAdditionNames,
                sourceEntity.superentityName == destinationEntity.superentityName,
                sourceEntity.indexes == destinationEntity.indexes
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Batched relationship removals do not match all detected owner endpoints.")
            }
            guard
                removed.allSatisfy({ relationship in
                    relationship.originalName == nil
                        && !destination.entities.contains(where: { entity in
                            entity.relationships.contains(where: { candidate in
                                candidate.originalName?.caseInsensitiveCompare(relationship.name) == .orderedSame
                            })
                        })
                })
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Batched to-many removal cannot rename a removed relationship endpoint.")
            }
            for relationship in removed.sorted(by: {
                $0.name.utf8.lexicographicallyPrecedes($1.name.utf8)
            }) {
                guard
                    let plan = try planOwnerOnlyToManyJoinTableRemoval(
                        relationship, owner: sourceEntity, schema: sourceSchema, connection: connection)
                else {
                    throw SwiftDataError.migrationUnsupported(
                        "Batched to-many removals require independent owner-only join tables.")
                }
                relationshipNamesByOwner[sourceEntity.name, default: []].insert(relationship.name)
                plans.append(plan)
            }
        }

        let plannedNames = Set(
            plans.flatMap { plan in
                [plan.joinTable, "\(plan.joinTable)_UNIQUE_INDEX", "\(plan.joinTable)_Z_B_INDEX"]
                    .map { $0.uppercased() }
            })
        guard plannedNames.count == plans.count * 3 else {
            throw SwiftDataError.migrationUnsupported("Batched join-table object names collide.")
        }

        let expectedSourceIndexNames = Set(
            source.entities.flatMap { indexDefinitions(for: $0, schema: source) }.map { $0.name.uppercased() })
        guard Set(sourceIndexSQL.keys) == expectedSourceIndexNames,
            source.entities.allSatisfy({ entity in
                let old = indexDefinitions(for: entity, schema: source)
                guard let next = destinationByName[entity.name] else { return false }
                let new = indexDefinitions(for: next, schema: destination)
                if let additions = addedAttributesByOwner[entity.name] {
                    let oldUnique = old.filter { $0.statement.hasPrefix("CREATE UNIQUE INDEX") }
                    let newUnique = new.filter { $0.statement.hasPrefix("CREATE UNIQUE INDEX") }
                    return oldUnique.count == newUnique.count
                        && oldUnique.allSatisfy(newUnique.contains)
                        && new.allSatisfy({ definition in
                            !definition.columns.contains(where: { column in
                                additions.contains(where: { "Z\($0.name.uppercased())" == column.uppercased() })
                            })
                        })
                }
                return old == new
            })
        else {
            throw SwiftDataError.migrationUnsupported("Join-removal index plan contains unsupported metadata changes.")
        }
        return OwnerOnlyToManyRemovalBatchPlan(
            removedRelationshipNamesByOwner: relationshipNamesByOwner,
            joinTables: plans.map(\.joinTable).sorted(),
            addedAttributesByOwner: addedAttributesByOwner)
    }

    private static func validateJoinTableNoPhysicalForeignKeys(
        table joinTable: String,
        checkReferences: Bool,
        connection: SQLConnection
    ) throws {
        let quotedJoinTable = "\"\(joinTable.replacingOccurrences(of: "\"", with: "\"\""))\""
        guard try connection.rows("PRAGMA foreign_key_list(\(quotedJoinTable))").isEmpty else {
            throw SwiftDataError.migrationUnsupported("Join table has unexpected foreign-key constraints.")
        }
        if checkReferences {
            try validateNoJoinTableDependencies(joinTable, connection: connection)
            let tables = try connection.rows(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
            for row in tables {
                guard case let .text(name)? = row.first else { continue }
                let quotedName = "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
                let references = try connection.rows("PRAGMA foreign_key_list(\(quotedName))")
                guard
                    !references.contains(where: { foreignKey in
                        guard foreignKey.count > 2, case let .text(target) = foreignKey[2] else { return false }
                        return target.caseInsensitiveCompare(joinTable) == .orderedSame
                    })
                else {
                    throw SwiftDataError.migrationUnsupported("A physical foreign key references the join table.")
                }
            }
        }
    }

    private static func hasReciprocalRelationship(
        named relationshipName: String,
        from ownerName: String,
        to destinationName: String,
        schema: Schema
    ) -> Bool {
        schema.entity(forName: destinationName)?.relationships.contains(where: { candidate in
            guard candidate.destination == ownerName else { return false }
            return candidate.inverse == nil || candidate.inverse == relationshipName
        }) ?? false
    }

    private static func validateNoJoinTableDependencies(_ table: String, connection: SQLConnection) throws {
        let sideObjects = try connection.rows(
            "SELECT type, name, sql FROM sqlite_master WHERE type IN ('trigger', 'view')")
        let escapedName = NSRegularExpression.escapedPattern(for: table.uppercased())
        let tableIdentifier = try NSRegularExpression(pattern: "(?<![A-Z0-9_])\(escapedName)(?![A-Z0-9_])")
        guard
            !sideObjects.contains(where: { row in
                guard row.count > 2, case let .text(sql) = row[2] else { return false }
                let normalizedSQL = sql.uppercased()
                let range = NSRange(normalizedSQL.startIndex..<normalizedSQL.endIndex, in: normalizedSQL)
                return tableIdentifier.firstMatch(in: normalizedSQL, range: range) != nil
            })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Join-table creation conflicts with an existing trigger or view.")
        }
    }

    private static func validateExistingOwnerOnlyJoinTable(
        table: String,
        uniqueIndexName: String,
        reverseIndexName: String,
        connection: SQLConnection
    ) throws {
        let tables = try connection.rows(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? COLLATE NOCASE",
            [.text(table)])
        guard tables.count == 1 else {
            throw SwiftDataError.migrationUnsupported("Expected join table \(table) is missing or ambiguous.")
        }
        let columns = try connection.rows("PRAGMA table_info(\(table))")
        guard columns.count == 2,
            columns[0].count > 5, columns[0][0] == .int(0), columns[0][1] == .text("Z_A"),
            columns[0][2] == .text("INTEGER"), columns[0][3] == .int(0), columns[0][4] == .null,
            columns[0][5] == .int(0),
            columns[1][0] == .int(1), columns[1][1] == .text("Z_B"), columns[1][2] == .text("INTEGER"),
            columns[1][3] == .int(0), columns[1][4] == .null, columns[1][5] == .int(0)
        else {
            throw SwiftDataError.migrationUnsupported("Join table \(table) has an unexpected physical layout.")
        }
        let indexRows = try connection.rows(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? COLLATE NOCASE",
            [.text(table)])
        let actualIndexNames = Set(
            indexRows.compactMap { row -> String? in
                guard case let .text(name)? = row.first else { return nil }
                return name.uppercased()
            })
        let expectedIndexNames = Set([uniqueIndexName, reverseIndexName].map { $0.uppercased() })
        let quotedTable = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
        let indexList = try connection.rows("PRAGMA index_list(\(quotedTable))")
        guard actualIndexNames == expectedIndexNames, indexList.count == 2 else {
            throw SwiftDataError.migrationUnsupported("Join table \(table) has unexpected physical indexes.")
        }
        try validateJoinIndex(
            name: uniqueIndexName,
            table: table,
            unique: true,
            columns: ["Z_A", "Z_B"],
            indexList: indexList,
            connection: connection)
        try validateJoinIndex(
            name: reverseIndexName,
            table: table,
            unique: false,
            columns: ["Z_B"],
            indexList: indexList,
            connection: connection)
    }

    private static func validateJoinIndex(
        name: String,
        table: String,
        unique: Bool,
        columns: [String],
        indexList: [[StoredValue]],
        connection: SQLConnection
    ) throws {
        let quotedName = "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
        let matchingRows = indexList.filter { item in
            guard item.count > 4, case let .text(indexName) = item[1] else { return false }
            return indexName.caseInsensitiveCompare(name) == .orderedSame
        }
        guard matchingRows.count == 1,
            let row = matchingRows.first,
            row[2] == .int(unique ? 1 : 0),
            row[3] == .text("c"),
            row[4] == .int(0)
        else {
            throw SwiftDataError.migrationUnsupported("Join index \(name) has unexpected flags.")
        }
        let info = try connection.rows("PRAGMA index_info(\(quotedName))")
        guard info.count == columns.count,
            info.enumerated().allSatisfy({ offset, item in
                guard item.count > 2,
                    item[0] == .int(Int64(offset)),
                    case let .int(columnID) = item[1], columnID >= 0,
                    case let .text(column) = item[2]
                else { return false }
                return column.uppercased() == columns[offset]
            })
        else {
            throw SwiftDataError.migrationUnsupported("Join index \(name) has unexpected columns.")
        }
        let indexSQL = try connection.rows(
            "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ? COLLATE NOCASE",
            [.text(name)])
        let expectedSQL =
            unique
            ? "CREATE UNIQUE INDEX \(name) ON \(table) (Z_A, Z_B)"
            : "CREATE INDEX \(name) ON \(table) (Z_B)"
        let normalizedExpectedSQL = expectedSQL.lowercased().filter { !$0.isWhitespace }
        let normalizedActualSQL = indexSQL.first?.first.flatMap { value -> String? in
            guard case let .text(sql) = value else { return nil }
            return sql.lowercased().filter { !$0.isWhitespace && $0 != "`" && $0 != "\"" }
        }
        guard indexSQL.count == 1, normalizedActualSQL == normalizedExpectedSQL else {
            throw SwiftDataError.migrationUnsupported("Join index \(name) has unexpected SQL semantics.")
        }
        let extendedInfo = try connection.rows("PRAGMA index_xinfo(\(quotedName))")
        let keyRows = extendedInfo.filter { row in row.count > 5 && row[5] == .int(1) }
        guard keyRows.count == columns.count,
            keyRows.enumerated().allSatisfy({ offset, item in
                guard item.count > 5,
                    item[0] == .int(Int64(offset)),
                    case let .int(columnID) = item[1], columnID >= 0,
                    item[3] == .int(0)
                else { return false }
                return item[2] == .text(columns[offset]) && item[4] == .text("BINARY")
            })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Join index \(name) has unexpected key metadata.")
        }
    }

    private static func validatedRemovedRelationshipMapping(
        _ relationship: Schema.Relationship,
        owner: Schema.Entity,
        sourceSchema: Schema
    ) throws -> Schema.RelationshipStorageMapping {
        guard
            let mapping = sourceSchema.relationshipStorageMapping(
                modelEntityName: owner.name, relationshipName: relationship.name),
            !SchemaBuilder.isNonOwner(owner, relationship, schema: sourceSchema),
            mapping.ownerRootEntityName == owner.name,
            mapping.declaringEntityName == owner.name
        else {
            throw SwiftDataError.migrationUnsupported(
                "Relationship removal requires an owning to-one foreign-key column on the entity root.")
        }
        return mapping
    }

    private static func validateOptionalRelationshipColumnRemoval(
        table: String,
        column: String,
        relationship: Schema.Relationship,
        owner: Schema.Entity,
        schema: Schema,
        connection: SQLConnection,
        validatePhysicalLayout: Bool = true
    ) throws {
        if validatePhysicalLayout {
            try validateColumnRemovalSideEffects(
                table: table,
                entity: owner,
                schema: schema,
                removedColumns: [column.uppercased()],
                connection: connection)
        }
        let sideObjects = try connection.rows(
            "SELECT 1 FROM sqlite_master WHERE type IN ('trigger', 'view') LIMIT 1")
        guard sideObjects.isEmpty else {
            throw SwiftDataError.migrationUnsupported(
                "Relationship removal is unsupported when triggers or views exist.")
        }
        try validateOptionalityBackfillSideEffects(table: table, column: column, connection: connection)
        let expectedIndexes = try expectedIndexNames(schema)
        let tableIndexes = try connection.rows(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? COLLATE NOCASE", [.text(table)])
        if validatePhysicalLayout {
            for row in tableIndexes {
                guard case let .text(name)? = row.first, expectedIndexes.contains(name.uppercased()) else {
                    throw SwiftDataError.migrationUnsupported(
                        "Relationship removal cannot preserve an untracked index on \(table).")
                }
            }
        }
        let mapping = try validatedRemovedRelationshipMapping(relationship, owner: owner, sourceSchema: schema)
        let generatedIndex =
            "Z\(mapping.ownerRootEntityName.uppercased())_Z\(mapping.relationshipName.uppercased())_INDEX"
        guard expectedIndexes.contains(generatedIndex.uppercased()),
            tableIndexes.contains(where: { row in
                guard case let .text(name)? = row.first else { return false }
                return name.caseInsensitiveCompare(generatedIndex) == .orderedSame
            })
        else {
            throw SwiftDataError.migrationUnsupported("Generated relationship index \(generatedIndex) is missing.")
        }
        let quotedIndex = "\"\(generatedIndex.replacingOccurrences(of: "\"", with: "\"\""))\""
        let indexMetadata = try connection.rows("PRAGMA index_list(\"\(table)\")")
        guard
            let generatedMetadata = indexMetadata.first(where: { row in
                guard row.count > 4, case let .text(name) = row[1] else { return false }
                return name.caseInsensitiveCompare(generatedIndex) == .orderedSame
            }), generatedMetadata[2] == .int(0), generatedMetadata[4] == .int(0)
        else {
            throw SwiftDataError.migrationUnsupported(
                "Generated relationship index \(generatedIndex) has incompatible flags.")
        }
        let indexedColumns = try connection.rows("PRAGMA index_info(\(quotedIndex))")
        guard indexedColumns.count == 1,
            indexedColumns[0].count > 2,
            case let .text(indexedColumn) = indexedColumns[0][2],
            indexedColumn.caseInsensitiveCompare(column) == .orderedSame
        else {
            throw SwiftDataError.migrationUnsupported(
                "Generated relationship index \(generatedIndex) does not index only \(column).")
        }
    }

    private struct IndexDefinition: Equatable {
        let name: String
        let statement: String
        let table: String
        let columns: [String]
    }

    private static func reconcileIndexes(
        _ transitions: [([IndexDefinition], [IndexDefinition])],
        validatedSourceIndexSQL: [String: String],
        connection: SQLConnection
    ) throws {
        var oldByName: [String: IndexDefinition] = [:]
        var newByName: [String: IndexDefinition] = [:]
        for (old, new) in transitions {
            for definition in old { oldByName[definition.name.uppercased()] = definition }
            for definition in new { newByName[definition.name.uppercased()] = definition }
        }
        for (name, new) in newByName {
            guard let old = oldByName[name] else { continue }
            guard old.table.caseInsensitiveCompare(new.table) == .orderedSame,
                old.columns.map({ $0.uppercased() }) == new.columns.map({ $0.uppercased() }),
                old.statement.hasPrefix("CREATE UNIQUE INDEX") == new.statement.hasPrefix("CREATE UNIQUE INDEX")
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Generated index name \(new.name) is reused for a different key definition.")
            }
        }
        let changedNew = newByName.filter { oldByName[$0.key] != $0.value }
        try validatePhysicalIndexes(
            destination: Array(newByName.values),
            changedNew: Array(changedNew.values),
            validatedSourceIndexSQL: validatedSourceIndexSQL,
            connection: connection)
        for (name, old) in oldByName where newByName[name] != old {
            try connection.execute("DROP INDEX IF EXISTS \(old.name)")
        }
        for (name, new) in newByName where oldByName[name] != new {
            try connection.execute(new.statement)
        }
    }

    private static func validateSourceIndexLayout(
        _ schema: Schema,
        connection: SQLConnection
    ) throws -> [String: String] {
        let definitions = schema.entities.flatMap { indexDefinitions(for: $0, schema: schema) }
        var validatedSQL: [String: String] = [:]
        for definition in definitions {
            let rows = try connection.rows(
                "SELECT sql, tbl_name FROM sqlite_master WHERE type = 'index' AND name = ? COLLATE NOCASE",
                [.text(definition.name)])
            let expectedSQL = normalizedIndexSQL(definition.statement)
            guard rows.count == 1,
                case let .text(actualSQL)? = rows.first?.first,
                expectedSQL != nil,
                normalizedIndexSQL(actualSQL) == expectedSQL,
                rows.first?.count ?? 0 > 1,
                case let .text(table)? = rows.first?[1],
                definition.table.caseInsensitiveCompare(table) == .orderedSame
            else {
                throw SwiftDataError.migrationUnsupported(
                    "Generated index \(definition.name) is missing or has unexpected SQL.")
            }
            try validatePhysicalIndexMetadata(definition, connection: connection)
            guard let normalizedSQL = normalizedIndexSQL(definition.statement) else {
                throw SwiftDataError.migrationUnsupported("Unable to normalize generated index SQL.")
            }
            validatedSQL[definition.name.uppercased()] = normalizedSQL
        }
        return validatedSQL
    }

    private static func validatePhysicalIndexes(
        destination: [IndexDefinition],
        changedNew: [IndexDefinition],
        validatedSourceIndexSQL: [String: String],
        connection: SQLConnection
    ) throws {
        let changedNewNames = Set(changedNew.map { $0.name.uppercased() })
        for definition in destination {
            let rows = try connection.rows(
                "SELECT type, sql FROM sqlite_master WHERE name = ? COLLATE NOCASE",
                [.text(definition.name)])
            guard let row = rows.first else { continue }
            if let expectedSourceSQL = validatedSourceIndexSQL[definition.name.uppercased()] {
                let sourceDefinitionChanged = changedNewNames.contains(definition.name.uppercased())
                if !sourceDefinitionChanged {
                    guard rows.count == 1, row.count > 1,
                        case .text("index") = row[0],
                        case let .text(actualSQL) = row[1],
                        normalizedIndexSQL(actualSQL) == expectedSourceSQL
                    else {
                        throw SwiftDataError.migrationUnsupported(
                            "Existing generated index \(definition.name) differs from the validated source schema.")
                    }
                    continue
                }
            }
            guard changedNewNames.contains(definition.name.uppercased()) else {
                throw SwiftDataError.migrationUnsupported(
                    "Destination index \(definition.name) collides with an untracked physical object.")
            }
            let isScheduledGeneratedIndex: Bool
            if rows.count == 1,
                let expectedOldSQL = validatedSourceIndexSQL[definition.name.uppercased()],
                row.count > 1,
                case .text("index") = row[0],
                case let .text(actualSQL) = row[1]
            {
                isScheduledGeneratedIndex = normalizedIndexSQL(actualSQL) == expectedOldSQL
            } else {
                isScheduledGeneratedIndex = false
            }
            guard isScheduledGeneratedIndex else {
                throw SwiftDataError.migrationUnsupported(
                    "Destination index \(definition.name) collides with an existing physical object.")
            }
        }
    }

    private static func validatePhysicalIndexMetadata(
        _ definition: IndexDefinition,
        connection: SQLConnection,
        expectedPartial: Bool = false
    ) throws {
        let table = definition.table
        let quotedTable = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
        let quotedIndex = "\"\(definition.name.replacingOccurrences(of: "\"", with: "\"\""))\""
        let metadata = try connection.rows("PRAGMA index_list(\(quotedTable))")
        guard
            let index = metadata.first(where: { row in
                guard row.count > 4, case let .text(name) = row[1] else { return false }
                return name.caseInsensitiveCompare(definition.name) == .orderedSame
            }),
            index[2] == .int(definition.statement.hasPrefix("CREATE UNIQUE INDEX") ? 1 : 0),
            index[4] == .int(expectedPartial ? 1 : 0)
        else {
            throw SwiftDataError.migrationUnsupported(
                "Generated index \(definition.name) has incompatible uniqueness or partial-index metadata.")
        }
        let actualColumns = try connection.rows("PRAGMA index_info(\(quotedIndex))")
        guard actualColumns.count == definition.columns.count,
            actualColumns.enumerated().allSatisfy({ offset, row in
                row.count > 2 && row[0] == .int(Int64(offset))
                    && row[2] == .text(definition.columns[offset].uppercased())
            })
        else {
            throw SwiftDataError.migrationUnsupported("Generated index \(definition.name) has unexpected keys.")
        }
    }

    private static func validatePhysicalIndexStatements(
        _ statements: [String],
        definitionsByName: [String: IndexDefinition],
        connection: SQLConnection,
        allowsPartialIndexes: Bool = false
    ) throws {
        for statement in statements {
            let tokens = statement.split(whereSeparator: \.isWhitespace)
            guard let indexPosition = tokens.firstIndex(of: "INDEX"),
                tokens.indices.contains(indexPosition + 1)
            else {
                throw SwiftDataError.migrationUnsupported("Unable to parse a generated index statement.")
            }
            let name = String(tokens[indexPosition + 1])
            guard let definition = definitionsByName[name.uppercased()] else {
                throw SwiftDataError.migrationUnsupported("Generated index \(name) has no schema definition.")
            }
            let rows = try connection.rows(
                "SELECT sql, tbl_name FROM sqlite_master WHERE type = 'index' AND name = ? COLLATE NOCASE",
                [.text(name)])
            let expectedSQL = normalizedIndexSQL(statement)
            guard rows.count == 1,
                case let .text(actualSQL)? = rows.first?.first,
                expectedSQL != nil,
                normalizedIndexSQL(actualSQL) == expectedSQL,
                rows.first?.count ?? 0 > 1,
                case let .text(actualTable)? = rows.first?[1],
                actualTable.caseInsensitiveCompare(definition.table) == .orderedSame
            else {
                throw SwiftDataError.migrationUnsupported("Generated index \(name) is missing or has unexpected SQL.")
            }
            try validatePhysicalIndexMetadata(
                definition, connection: connection,
                expectedPartial: allowsPartialIndexes && statement.range(of: " WHERE ") != nil)
        }
    }

    private static func normalizedIndexSQL(_ sql: String) -> String? {
        let scalars = Array(sql.unicodeScalars)
        var tokens: [String] = []
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                index += 1
                continue
            }
            if scalar == "'" {
                var literal = "'"
                index += 1
                var closed = false
                while index < scalars.count {
                    let current = scalars[index]
                    guard current != ";" else { return nil }
                    literal.unicodeScalars.append(current)
                    index += 1
                    guard current == "'" else { continue }
                    guard index < scalars.count, scalars[index] == "'" else {
                        closed = true
                        break
                    }
                    literal.unicodeScalars.append(scalars[index])
                    index += 1
                }
                guard closed else { return nil }
                tokens.append("LITERAL:\(literal)")
                continue
            }
            if scalar == "\"" || scalar == "`" || scalar == "[" {
                let closing: Unicode.Scalar = scalar == "[" ? "]" : scalar
                var identifier = ""
                index += 1
                var closed = false
                while index < scalars.count {
                    let current = scalars[index]
                    guard current != ";" else { return nil }
                    if current == closing {
                        if closing != "]", index + 1 < scalars.count, scalars[index + 1] == closing {
                            identifier.unicodeScalars.append(current)
                            index += 2
                            continue
                        }
                        closed = true
                        index += 1
                        break
                    }
                    identifier.unicodeScalars.append(current)
                    index += 1
                }
                guard closed else { return nil }
                tokens.append("IDENTIFIER:\(identifier)")
                continue
            }
            if scalar == ";" {
                let trailing = scalars[(index + 1)...].allSatisfy {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                }
                guard trailing else { return nil }
                break
            }
            if scalar == "(" || scalar == ")" || scalar == "," {
                tokens.append("PUNCTUATION:\(scalar)")
                index += 1
                continue
            }
            if CharacterSet.decimalDigits.contains(scalar) {
                var number = String(scalar)
                index += 1
                while index < scalars.count, CharacterSet.decimalDigits.contains(scalars[index]) {
                    number.unicodeScalars.append(scalars[index])
                    index += 1
                }
                tokens.append("NUMBER:\(number)")
                continue
            }
            if CharacterSet.letters.contains(scalar) || scalar == "_" {
                var word = String(scalar)
                index += 1
                while index < scalars.count,
                    CharacterSet.alphanumerics.contains(scalars[index]) || scalars[index] == "_"
                        || scalars[index] == "$"
                {
                    word.unicodeScalars.append(scalars[index])
                    index += 1
                }
                tokens.append("IDENTIFIER:\(word)")
                continue
            }
            return nil
        }
        return tokens.joined(separator: "|")
    }

    private static func expectedIndexTable(in statement: String) -> String? {
        guard let onRange = statement.range(of: " ON ") else { return nil }
        let remainder = statement[onRange.upperBound...]
        let tableToken = remainder.prefix { !$0.isWhitespace && $0 != "(" }
        guard !tableToken.isEmpty else { return nil }
        return String(tableToken).trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
    }

    private static func indexColumns(in statement: String) -> [String]? {
        let scalars = Array(statement.unicodeScalars)
        guard let openParen = scalars.firstIndex(of: "(") else { return nil }
        var columns: [String] = []
        var column = ""
        var index = openParen + 1
        var closed = false
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "," || scalar == ")" {
                let value = column.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isGeneratedIndexColumn(value) else { return nil }
                columns.append(value.uppercased())
                column = ""
                if scalar == ")" {
                    closed = true
                    break
                }
            } else {
                guard scalar.isASCII else { return nil }
                column.unicodeScalars.append(scalar)
            }
            index += 1
        }
        guard closed else { return nil }
        return columns
    }

    private static func isGeneratedIndexColumn(_ column: String) -> Bool {
        guard column.first == "Z", column.utf8.count > 1 else { return false }
        return column.utf8.dropFirst().allSatisfy { byte in
            (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57) || byte == 95
        }
    }

    private static func validateDestinationIndexNames(_ schema: Schema) throws {
        var seen: Set<String> = []
        for entity in schema.entities {
            for index in indexDefinitions(for: entity, schema: schema) {
                guard seen.insert(index.name.uppercased()).inserted else {
                    throw SwiftDataError.migrationUnsupported(
                        "Destination schema contains colliding index name '\(index.name)'.")
                }
            }
        }
    }

    private static func indexDefinitions(for entity: Schema.Entity, schema: Schema) -> [IndexDefinition] {
        var definitions: [IndexDefinition] = []
        for relationship in entity.relationships where !relationship.isToMany {
            guard !SchemaBuilder.isNonOwner(entity, relationship, schema: schema) else { continue }
            let mapping = schema.relationshipStorageMapping(
                modelEntityName: entity.name, relationshipName: relationship.name)
            let storageEntityName = mapping?.ownerRootEntityName ?? entity.name
            let columnName = mapping?.relationshipName ?? relationship.name
            let name = "Z\(storageEntityName.uppercased())_Z\(columnName.uppercased())_INDEX"
            definitions.append(
                IndexDefinition(
                    name: name,
                    statement: "CREATE INDEX \(name) ON Z\(storageEntityName.uppercased()) "
                        + "(Z\(columnName.uppercased()));",
                    table: "Z\(storageEntityName.uppercased())",
                    columns: ["Z\(columnName.uppercased())"]))
        }
        for attribute in entity.attributes where attribute.options.contains(.unique) {
            let name = "Z\(entity.name.uppercased())_Z\(attribute.name.uppercased())_UNIQUE_INDEX"
            definitions.append(
                IndexDefinition(
                    name: name,
                    statement: "CREATE UNIQUE INDEX \(name) ON Z\(entity.name.uppercased()) "
                        + "(Z\(attribute.name.uppercased()));",
                    table: "Z\(entity.name.uppercased())",
                    columns: ["Z\(attribute.name.uppercased())"]))
        }
        for index in entity.indexes {
            if index.isUnique, index.properties.count == 1,
                entity.attributes.first(where: { $0.name == index.properties[0] })?.options.contains(.unique) == true
            {
                continue
            }
            let columns = index.properties.map { "Z\($0.uppercased())" }
            let name =
                "Z\(entity.name.uppercased())_\(columns.joined(separator: "_"))"
                + "\(index.isUnique ? "_UNIQUE" : "")_INDEX"
            definitions.append(
                IndexDefinition(
                    name: name,
                    statement: "CREATE \(index.isUnique ? "UNIQUE " : "")INDEX \(name) "
                        + "ON Z\(entity.name.uppercased()) (\(columns.joined(separator: ", ")));",
                    table: "Z\(entity.name.uppercased())",
                    columns: columns))
        }
        return definitions
    }

    private static func tableColumns(_ table: String, connection: SQLConnection) throws -> Set<String> {
        Set(
            try connection.rows("PRAGMA table_info(\(table))").compactMap { row in
                guard row.count > 1, case let .text(name) = row[1] else { return nil }
                return name
            })
    }

}
