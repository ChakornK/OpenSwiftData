import Foundation
import GRDB
import OSDCore

package enum LightweightMigration {
    package static let schemaHashKey = "schema.hash.v1"
    package static let schemaDescriptionKey = "schema.definition.v1"
    package static let schemaVersionKey = "schema.version.v1"
    package static let entityIDsKey = "schema.entity-ids.v1"
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
        let reconciledDestination = try destination.reconciled(with: resolvedSourceEntityIDs)
        if stored == destinationHash {
            if sourceEntityIDs == nil {
                try writeSchemaMetadata(reconciledDestination, connection: connection)
            } else {
                try writeSchemaVersion(destination.version, connection: connection)
            }
            return
        }
        try connection.execute("SAVEPOINT osd_schema_migration")
        do {
            try migrate(source: sourceSchema, destination: reconciledDestination, connection: connection)
            try writeSchemaMetadata(reconciledDestination, connection: connection)
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

    private static func reconcileHierarchyIndexes(
        sourceStatements: [String], destinationStatements: [String], connection: SQLConnection
    ) throws {
        func indexStatements(_ statements: [String]) throws -> [String: String] {
            var result: [String: String] = [:]
            for statement in statements
            where statement.hasPrefix("CREATE INDEX") || statement.hasPrefix("CREATE UNIQUE INDEX") {
                let tokens = statement.split(separator: " ")
                guard let indexPosition = tokens.firstIndex(of: "INDEX"), tokens.indices.contains(indexPosition + 1)
                else {
                    throw SwiftDataError.migrationUnsupported("Unable to parse a generated hierarchy index statement.")
                }
                let name = String(tokens[indexPosition + 1])
                guard result.updateValue(statement, forKey: name.uppercased()) == nil else {
                    throw SwiftDataError.migrationUnsupported("Hierarchy index names are not unique.")
                }
            }
            return result
        }
        let sourceIndexes = try indexStatements(sourceStatements)
        let destinationIndexes = try indexStatements(destinationStatements)
        guard Set(sourceIndexes.keys).isSubset(of: Set(destinationIndexes.keys)) else {
            throw SwiftDataError.migrationUnsupported("Hierarchy migration cannot remove existing indexes.")
        }
        for name in destinationIndexes.keys.sorted() {
            guard let statement = destinationIndexes[name] else { continue }
            if sourceIndexes[name] == statement { continue }
            if sourceIndexes[name] != nil {
                try connection.execute("DROP INDEX \(name)")
            }
            try connection.execute(statement)
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

    private static func writeSchemaMetadata(_ schema: Schema, connection: SQLConnection) throws {
        try writeHash(SchemaHash.hexDigest(schema), connection: connection)
        try connection.execute(
            "INSERT INTO _osd_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(schemaDescriptionKey), .blob(Array(SchemaHash.canonicalDescription(of: schema).utf8))])
        try writeEntityIDs(schema.entityIDsByName, schema: schema, connection: connection)
        try writeSchemaVersion(schema.version, connection: connection)
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
        let sourceNames = Set(source.entities.map(\.name))
        let destinationNames = Set(destination.entities.map(\.name))
        guard sourceNames.isSubset(of: destinationNames) else {
            throw SwiftDataError.migrationUnsupported("Entity removals require a versioned row mapping.")
        }
        if sourceNames != destinationNames {
            try applyFlatIndependentRootAdditions(source: source, destination: destination, connection: connection)
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
        try reconcileIndexes(indexTransitions, connection: connection)
    }

    private static func applyFlatIndependentRootAdditions(
        source: Schema,
        destination: Schema,
        connection: SQLConnection
    ) throws {
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
        try reconcileHierarchyIndexes(
            sourceStatements: sourceBuilt.statements, destinationStatements: destinationBuilt.statements,
            connection: connection)
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
        if let removedAttribute = try removableScalarAttribute(
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
            let column = "Z\(removedAttribute.name.uppercased())"
            try validateColumnRemovalSideEffects(table: table, connection: connection)
            try connection.execute("ALTER TABLE \(table) DROP COLUMN \(column)")
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
            source: source, destination: destination, schema: Schema(destinationEntities),
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
        guard changes.count == 1,
            let change = changes.first,
            let oldAttribute = change.source,
            oldAttribute.name == change.destination.name,
            oldAttribute.isOptional == change.destination.isOptional,
            oldAttribute.defaultValue == change.destination.defaultValue,
            oldAttribute.options == change.destination.options,
            oldAttribute.originalName == change.destination.originalName,
            oldAttribute.components.isEmpty,
            change.destination.components.isEmpty,
            let sourceWidth = signedIntegerWidth(oldAttribute.type),
            let destinationWidth = signedIntegerWidth(change.destination.type),
            destinationWidth > sourceWidth,
            mappings.count == source.attributes.count,
            mappings.count == destination.attributes.count,
            mappings.allSatisfy({ mapping in
                guard let old = mapping.source else { return false }
                return old == oldAttribute || old == mapping.destination
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
            destination.superentityName == nil,
            !oldAttribute.options.contains(.codable),
            !oldAttribute.options.contains(.flattened),
            !oldAttribute.options.contains(.externalStorage),
            !oldAttribute.options.contains(where: { if case .transformable = $0 { true } else { false } }),
            try SQLColumnType.resolve(
                oldAttribute.type, property: "\(source.name).\(oldAttribute.name)", options: oldAttribute.options)
                == .integer,
            try SQLColumnType.resolve(
                change.destination.type,
                property: "\(destination.name).\(change.destination.name)",
                options: change.destination.options) == .integer
        else {
            throw SwiftDataError.migrationUnsupported(
                "Numeric widening must be a single signed-integer change with unchanged storage metadata.")
        }
        return true
    }

    private static func signedIntegerWidth(_ typeName: String) -> Int? {
        let name = typeName.split(separator: ".").last.map(String.init) ?? typeName
        return switch name {
        case "Int8": 8
        case "Int16": 16
        case "Int32": 32
        case "Int64": 64
        case "Int": Int.bitWidth
        default: nil
        }
    }

    private static func removableScalarAttribute(
        _ mappings: [AttributeMapping],
        source: Schema.Entity,
        destination: Schema.Entity,
        sourceEntities: [Schema.Entity],
        destinationEntities: [Schema.Entity],
        sourceEntityIDs: [String: Int],
        destinationEntityIDs: [String: Int]
    ) throws -> Schema.Attribute? {
        let removed = source.attributes.filter { sourceAttribute in
            !mappings.contains(where: { $0.source?.name == sourceAttribute.name })
        }
        guard !removed.isEmpty else { return nil }
        guard removed.count == 1,
            let removedAttribute = removed.first,
            removedAttribute.options.isDisjoint(with: [.unique, .codable, .flattened, .externalStorage]),
            !removedAttribute.options.contains(where: { if case .transformable = $0 { true } else { false } }),
            !source.indexes.contains(where: { $0.properties.contains(removedAttribute.name) }),
            !destination.attributes.contains(where: { $0.originalName == removedAttribute.name }),
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
            sourceEntities.allSatisfy({ $0.relationships.isEmpty }),
            destinationEntities.allSatisfy({ $0.relationships.isEmpty })
        else {
            throw SwiftDataError.migrationUnsupported(
                "Attribute removal must remove one unindexed scalar from a flat schema without other edits.")
        }
        _ = try SQLColumnType.resolve(
            removedAttribute.type,
            property: "\(source.name).\(removedAttribute.name)",
            options: removedAttribute.options)
        return removedAttribute
    }

    private static func validateColumnRemovalSideEffects(
        table: String,
        connection: SQLConnection
    ) throws {
        let sideObjects = try connection.rows(
            "SELECT 1 FROM sqlite_master WHERE type IN ('trigger', 'view') LIMIT 1")
        guard sideObjects.isEmpty else {
            throw SwiftDataError.migrationUnsupported("Attribute removal is unsupported when triggers or views exist.")
        }
        let tables = try connection.rows(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        for row in tables {
            guard case let .text(name)? = row.first else { continue }
            let quotedName = "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
            let foreignKeys = try connection.rows("PRAGMA foreign_key_list(\(quotedName))")
            guard foreignKeys.isEmpty else {
                throw SwiftDataError.migrationUnsupported("Attribute removal is unsupported when foreign keys exist.")
            }
        }
        let tableInfo = try connection.rows("PRAGMA table_info(\(table))")
        guard
            tableInfo.contains(where: { row in
                row.count > 5
                    && row[1] == .text("Z_PK")
                    && row[2] == .text("INTEGER")
                    && row[5] == .int(1)
            })
        else {
            throw SwiftDataError.migrationUnsupported("Attribute removal requires the standard INTEGER primary key.")
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

    private static func migrateRelationships(
        source: Schema.Entity,
        destination: Schema.Entity,
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
        guard mappedSources.count == source.relationships.count else {
            throw SwiftDataError.migrationUnsupported(
                "Adding or removing relationships requires graph transformation metadata.")
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

    private struct IndexDefinition: Equatable {
        let name: String
        let statement: String
    }

    private static func reconcileIndexes(
        _ transitions: [([IndexDefinition], [IndexDefinition])],
        connection: SQLConnection
    ) throws {
        var oldByName: [String: IndexDefinition] = [:]
        var newByName: [String: IndexDefinition] = [:]
        for (old, new) in transitions {
            for definition in old { oldByName[definition.name.uppercased()] = definition }
            for definition in new { newByName[definition.name.uppercased()] = definition }
        }
        for (name, old) in oldByName where newByName[name] != old {
            try connection.execute("DROP INDEX IF EXISTS \(old.name)")
        }
        for (name, new) in newByName where oldByName[name] != new {
            try connection.execute(new.statement)
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
                        + "(Z\(columnName.uppercased()));"))
        }
        for attribute in entity.attributes where attribute.options.contains(.unique) {
            let name = "Z\(entity.name.uppercased())_Z\(attribute.name.uppercased())_UNIQUE_INDEX"
            definitions.append(
                IndexDefinition(
                    name: name,
                    statement: "CREATE UNIQUE INDEX \(name) ON Z\(entity.name.uppercased()) "
                        + "(Z\(attribute.name.uppercased()));"))
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
                        + "ON Z\(entity.name.uppercased()) (\(columns.joined(separator: ", ")));"))
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
