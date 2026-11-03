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
                indexTransitions: &indexTransitions,
                connection: connection)
        }
        try reconcileIndexes(indexTransitions, validatedSourceIndexSQL: validatedSourceIndexSQL, connection: connection)
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
        indexTransitions: inout [([IndexDefinition], [IndexDefinition])],
        connection: SQLConnection
    ) throws {
        let table = "Z\(source.name.uppercased())"
        let existing = try tableColumns(table, connection: connection)
        let mappings = try attributeMappings(source: source, destination: destination)
        try validateAttributeColumns(mappings, destination: destination, existing: existing)
        let mappedRelationshipSources = Set(
            destination.relationships.compactMap { relationship in
                source.relationships.first(where: {
                    $0.name == relationship.name || $0.name == relationship.originalName
                })?.name
            })
        let removedRelationships = source.relationships.filter { !mappedRelationshipSources.contains($0.name) }
        let removedRelationshipNames = Set(removedRelationships.map(\.name))
        let addedRelationships = destination.relationships.filter { relationship in
            !source.relationships.contains(where: {
                $0.name == relationship.name
                    || ($0.name == relationship.originalName && !removedRelationshipNames.contains($0.name))
            })
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
        if let optionalityChange = try optionalToRequiredAttributeChange(
            mappings,
            source: source,
            destination: destination,
            sourceEntities: sourceEntities,
            destinationEntities: destinationEntities,
            sourceEntityIDs: sourceEntityIDs,
            destinationEntityIDs: destinationEntityIDs)
        {
            guard let literal = try migrationDefaultLiteral(for: optionalityChange.destination) else {
                throw SwiftDataError.migrationUnsupported(
                    "Making attribute \(destination.name).\(optionalityChange.destination.name) required requires a literal default."
                )
            }
            let column = "Z\(optionalityChange.destination.name.uppercased())"
            try validateOptionalityBackfillSideEffects(table: table, column: column, connection: connection)
            do {
                try connection.execute("UPDATE \(table) SET \(column) = \(literal) WHERE \(column) IS NULL")
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                throw SwiftDataError.migrationUnsupported(
                    "Backfilling \(destination.name).\(optionalityChange.destination.name) violates a uniqueness constraint."
                )
            }
            let nullRows = try connection.rows("SELECT COUNT(*) FROM \(table) WHERE \(column) IS NULL")
            guard case let .int(count)? = nullRows.first?.first, count == 0 else {
                throw SwiftDataError.migrationUnsupported(
                    "Required attribute \(destination.name).\(optionalityChange.destination.name) still contains NULL values."
                )
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
            try validateColumnRemovalSideEffects(
                table: table,
                entity: source,
                schema: Schema(sourceEntities),
                removedColumns: Set(removedAttributes.map { "Z\($0.name.uppercased())" }),
                connection: connection)
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
                    })
            let removedIndexDefinitions = indexDefinitions(for: source, schema: Schema(sourceEntities)).filter {
                removableIndexNames.contains($0.name.uppercased())
            }
            try validateGeneratedIndexesForAttributeRemoval(
                table: table,
                definitions: indexDefinitions(for: source, schema: Schema(sourceEntities)),
                connection: connection)
            let knownIndexNames = Set(
                indexDefinitions(for: source, schema: Schema(sourceEntities)).map { $0.name.uppercased() })
            for attribute in removedAttributes {
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
            for attribute in removedAttributes.sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }) {
                try connection.execute("ALTER TABLE \(table) DROP COLUMN Z\(attribute.name.uppercased())")
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
            connection: connection, existing: existing)
        indexTransitions.append(
            (
                indexDefinitions(for: source, schema: Schema(sourceEntities)),
                indexDefinitions(for: destination, schema: Schema(destinationEntities))
            ))
    }

    private static func optionalToRequiredAttributeChange(
        _ mappings: [AttributeMapping],
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceEntities: [Schema.Entity],
        destinationEntities: [Schema.Entity],
        sourceEntityIDs: [String: Int],
        destinationEntityIDs: [String: Int]
    ) throws -> AttributeMapping? {
        let changes = mappings.filter { mapping in
            guard let source = mapping.source else { return false }
            return source.isOptional != mapping.destination.isOptional
        }
        guard !changes.isEmpty else { return nil }
        guard changes.contains(where: { $0.source?.isOptional == true && !$0.destination.isOptional }) else {
            return nil
        }
        guard changes.count == 1,
            let change = changes.first,
            let oldAttribute = change.source,
            oldAttribute.isOptional,
            !change.destination.isOptional,
            oldAttribute.name == change.destination.name,
            oldAttribute.type == change.destination.type,
            oldAttribute.options == change.destination.options,
            oldAttribute.originalName == change.destination.originalName,
            oldAttribute.components == change.destination.components,
            mappings.count == source.attributes.count,
            mappings.count == destination.attributes.count,
            mappings.allSatisfy({ mapping in
                guard let old = mapping.source else { return false }
                return old == oldAttribute || old == mapping.destination
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
            sourceEntities.allSatisfy({ $0.relationships.isEmpty }),
            destinationEntities.allSatisfy({ $0.relationships.isEmpty })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Optional-to-required migration must change one flat scalar attribute without other schema edits.")
        }
        _ = try SQLColumnType.resolve(
            change.destination.type,
            property: "\(destination.name).\(change.destination.name)",
            options: change.destination.options)
        return change
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
        guard hasSignedIntegerType else { return false }
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
                        && sourceEntity.indexes == destinationEntity.indexes
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
        guard
            !source.indexes.contains(where: { index in
                guard index.isUnique,
                    index.properties.contains(where: { removedNames.contains($0) })
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
            let remainingSourceEntity = destinationEntities.first(where: { $0.name == destination.name }),
            source.indexes.filter({ index in
                !index.properties.contains(where: { removedNames.contains($0) })
            }) == remainingSourceEntity.indexes,
            removed.allSatisfy({ attribute in
                !attribute.options.contains(.codable)
                    && !attribute.options.contains(.flattened)
                    && !attribute.options.contains(.externalStorage)
                    && !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
            }),
            !destination.attributes.contains(where: { attribute in
                attribute.originalName.map { removedNames.contains($0) } ?? false
            }),
            mappings.count == destination.attributes.count,
            mappings.allSatisfy({ mapping in
                guard let old = mapping.source else { return false }
                return old == mapping.destination
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
                if sourceEntity.name == source.name {
                    let retainedIndexes = sourceEntity.indexes.filter {
                        !$0.properties.contains(where: { removedNames.contains($0) })
                    }
                    return sourceEntity.superentityName == destinationEntity.superentityName
                        && sourceEntity.relationships == destinationEntity.relationships
                        && retainedIndexes == destinationEntity.indexes
                }
                return sourceEntity.superentityName == destinationEntity.superentityName
                    && sourceEntity.attributes.count == destinationEntity.attributes.count
                    && sourceEntity.attributes.allSatisfy({ destinationEntity.attributes.contains($0) })
                    && sourceEntity.relationships == destinationEntity.relationships
                    && sourceEntity.indexes == destinationEntity.indexes
            }),
            sourceEntities.allSatisfy({ $0.relationships.isEmpty }),
            destinationEntities.allSatisfy({ $0.relationships.isEmpty })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Attribute removal must remove flat scalar columns without changing retained metadata or partial indexes."
            )
        }
        for attribute in removed {
            _ = try SQLColumnType.resolve(
                attribute.type, property: "\(source.name).\(attribute.name)", options: attribute.options)
        }
        return removed
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
        connection: SQLConnection,
        existing: Set<String>
    ) throws {
        let mappedSources = Set(
            destination.relationships.compactMap { relationship in
                source.relationships.first(where: {
                    $0.name == relationship.name || $0.name == relationship.originalName
                })?.name
            })
        let removedRelationships = source.relationships.filter { !mappedSources.contains($0.name) }
        let addedRelationships = destination.relationships.filter { relationship in
            !source.relationships.contains(where: {
                $0.name == relationship.name || $0.name == relationship.originalName
            })
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
        for row in tableIndexes {
            guard case let .text(name)? = row.first, expectedIndexes.contains(name.uppercased()) else {
                throw SwiftDataError.migrationUnsupported(
                    "Relationship removal cannot preserve an untracked index on \(table).")
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
