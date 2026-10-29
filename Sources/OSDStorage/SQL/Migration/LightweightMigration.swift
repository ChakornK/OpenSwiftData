import Foundation
import OSDCore

package enum LightweightMigration {
    package static let schemaHashKey = "schema.hash.v1"
    package static let schemaDescriptionKey = "schema.definition.v1"
    package static let schemaVersionKey = "schema.version.v1"
    package static let pendingMigrationKey = "schema.migration.pending.v1"

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
        let sourceSchema = persistedSource
        let sourceHash = SchemaHash.hexDigest(sourceSchema)
        guard stored == sourceHash else {
            throw SwiftDataError.migrationUnsupported("The stored schema hash does not match the source schema.")
        }
        try validatePhysicalSchema(sourceSchema, connection: connection)
        if stored == destinationHash {
            try writeSchemaVersion(destination.version, connection: connection)
            return
        }
        try connection.execute("SAVEPOINT osd_schema_migration")
        do {
            try migrate(source: sourceSchema, destination: destination, connection: connection)
            try writeSchemaMetadata(destination, connection: connection)
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
        for entity in schema.entities {
            let table = "Z\(entity.name.uppercased())"
            let columns = try tableColumns(table, connection: connection)
            guard columns.contains("Z_PK"), columns.contains("Z_ENT"), columns.contains("Z_OPT") else {
                throw SwiftDataError.migrationUnsupported(
                    "Physical schema is missing required columns for \(entity.name).")
            }
            for attribute in entity.attributes {
                let expectedColumns =
                    attribute.options.contains(.flattened)
                    ? attribute.components.map(\.columnName) : [attribute.name]
                for column in expectedColumns where !columns.contains("Z\(column.uppercased())") {
                    throw SwiftDataError.migrationUnsupported(
                        "Physical schema is missing attribute column \(entity.name).\(column).")
                }
            }
            for relationship in entity.relationships where !relationship.isToMany {
                guard columns.contains("Z\(relationship.name.uppercased())") else {
                    throw SwiftDataError.migrationUnsupported(
                        "Physical schema is missing relationship \(entity.name).\(relationship.name).")
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
        guard Set(source.entities.map(\.name)) == Set(destination.entities.map(\.name)) else {
            throw SwiftDataError.migrationUnsupported("Entity additions and removals require a versioned row mapping.")
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
                indexTransitions: &indexTransitions,
                connection: connection)
        }
        try reconcileIndexes(indexTransitions, connection: connection)
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
        indexTransitions: inout [([IndexDefinition], [IndexDefinition])],
        connection: SQLConnection
    ) throws {
        let table = "Z\(source.name.uppercased())"
        let existing = try tableColumns(table, connection: connection)
        let mappings = try attributeMappings(source: source, destination: destination)
        try validateAttributeColumns(mappings, destination: destination, existing: existing)
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
            throw SwiftDataError.migrationUnsupported("Attribute removal requires a table rebuild.")
        }
        let renamePlan = try orderedRenames(mappings)
        for (sourceName, destinationName) in renamePlan {
            try connection.execute(
                "ALTER TABLE \(table) RENAME COLUMN Z\(sourceName.uppercased()) TO Z\(destinationName.uppercased())")
        }

        for mapping in mappings {
            let attribute = mapping.destination
            guard let old = mapping.source else {
                guard attribute.isOptional else {
                    throw SwiftDataError.migrationUnsupported(
                        "Adding required attribute \(destination.name).\(attribute.name) requires a table rebuild.")
                }
                let type = try SQLColumnType.resolve(
                    attribute.type, property: "\(destination.name).\(attribute.name)", options: attribute.options)
                try connection.execute(
                    "ALTER TABLE \(table) ADD COLUMN Z\(attribute.name.uppercased()) \(type.rawValue)")
                continue
            }
            guard old.isOptional == attribute.isOptional else {
                throw SwiftDataError.migrationUnsupported("Optionality changes require a table rebuild.")
            }
            guard old.type == attribute.type else {
                throw SwiftDataError.migrationUnsupported(
                    "Attribute type change requires a table rebuild for \(destination.name).\(attribute.name).")
            }
        }
        try migrateRelationships(source: source, destination: destination, connection: connection, existing: existing)
        indexTransitions.append(
            (
                indexDefinitions(for: source, entities: sourceEntities),
                indexDefinitions(for: destination, entities: destinationEntities)
            ))
    }

    private static func migrateRelationships(
        source: Schema.Entity,
        destination: Schema.Entity,
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
            for index in indexDefinitions(for: entity, entities: schema.entities) {
                guard seen.insert(index.name.uppercased()).inserted else {
                    throw SwiftDataError.migrationUnsupported(
                        "Destination schema contains colliding index name '\(index.name)'.")
                }
            }
        }
    }

    private static func indexDefinitions(for entity: Schema.Entity, entities: [Schema.Entity]) -> [IndexDefinition] {
        var definitions: [IndexDefinition] = []
        for relationship in entity.relationships where !relationship.isToMany {
            guard !SchemaBuilder.isNonOwner(entity, relationship, entities) else { continue }
            let name = "Z\(entity.name.uppercased())_Z\(relationship.name.uppercased())_INDEX"
            definitions.append(
                IndexDefinition(
                    name: name,
                    statement: "CREATE INDEX \(name) ON Z\(entity.name.uppercased()) "
                        + "(Z\(relationship.name.uppercased()));"))
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
