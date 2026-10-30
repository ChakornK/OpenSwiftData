import OSDCore

package struct SchemaBootstrapRow: Equatable, Sendable {
    package let entityID: Int64
    package let name: String
    package let superEntityID: Int64
    package let maximumPrimaryKey: Int64

    package init(entityID: Int64, name: String, superEntityID: Int64 = 0, maximumPrimaryKey: Int64 = 0) {
        self.entityID = entityID
        self.name = name
        self.superEntityID = superEntityID
        self.maximumPrimaryKey = maximumPrimaryKey
    }
}

package struct BuiltSchema: Equatable, Sendable {
    package let statements: [String]
    package let bootstrapRows: [SchemaBootstrapRow]
}

package enum SchemaBuilder {
    private static func bytewiseLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func identifierKey(_ identifier: String) -> String {
        identifier.uppercased()
    }

    private static func validateUniqueNames(_ names: [String], scope: String) throws {
        var seen: Set<String> = []
        for name in names {
            guard seen.insert(identifierKey(name)).inserted else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Duplicate or colliding \(scope) identifier '\(name)'."
                )
            }
        }
    }

    private static func validateRelationships(
        _ relationships: [Schema.Relationship],
        in entity: Schema.Entity,
        schema: Schema
    ) throws {
        let entities = schema.entities
        for relationship in relationships {
            let property = "\(entity.name).\(relationship.name)"
            guard entities.contains(where: { $0.name == relationship.destination }) else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Relationship '\(property)' targets missing entity '\(relationship.destination)'."
                )
            }
            if let minimum = relationship.minimumModelCount, minimum < 0 {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Relationship '\(property)' has a negative minimum model count."
                )
            }
            if let maximum = relationship.maximumModelCount, maximum < 0 {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Relationship '\(property)' has a negative maximum model count."
                )
            }
            if let minimum = relationship.minimumModelCount, let maximum = relationship.maximumModelCount,
                minimum > maximum
            {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Relationship '\(property)' has a minimum model count greater than its maximum."
                )
            }
            guard let inverseName = relationship.inverse else {
                continue
            }
            guard relationship.destination != entity.name || inverseName != relationship.name else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Relationship '\(property)' cannot be its own inverse."
                )
            }
            guard let destination = entities.first(where: { $0.name == relationship.destination }),
                let inverse = destination.relationships.first(where: { $0.name == inverseName })
            else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Relationship '\(property)' references missing inverse '\(relationship.destination).\(inverseName)'."
                )
            }
            let logicalOwnerName =
                schema.relationshipStorageMapping(
                    modelEntityName: entity.name, relationshipName: relationship.name)?.declaringEntityName
                ?? entity.name
            var ownerAncestor: String? = logicalOwnerName
            var visitedOwners: Set<String> = []
            var inverseTargetsOwner = false
            while let name = ownerAncestor, visitedOwners.insert(name).inserted {
                if inverse.destination == name {
                    inverseTargetsOwner = true
                    break
                }
                ownerAncestor = schema.entity(forName: name)?.superentityName
            }
            guard inverseTargetsOwner, inverse.inverse == relationship.name else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Relationship '\(property)' has incompatible inverse '\(relationship.destination).\(inverseName)'."
                )
            }
        }
    }

    package static func build(_ schema: Schema) throws -> BuiltSchema {
        try schema.validateRelationshipStorageMappings()
        let entities = schema.entities.sorted { bytewiseLess($0.name, $1.name) }
        try validateUniqueNames(entities.map(\.name), scope: "entity")
        let entitiesByName = Dictionary(uniqueKeysWithValues: entities.map { ($0.name, $0) })
        for entity in entities {
            guard let parent = entity.superentityName else { continue }
            guard parent != entity.name, entitiesByName[parent] != nil else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Entity '\(entity.name)' references missing or self superentity '\(parent)'.")
            }
            var visited: Set<String> = [entity.name]
            var current: String? = parent
            while let name = current {
                guard visited.insert(name).inserted else {
                    throw SwiftDataError.unsupportedSchemaProperty("Schema inheritance contains a cycle.")
                }
                current = entitiesByName[name]?.superentityName
            }
        }
        if entities.contains(where: { $0.superentityName != nil }) {
            return try buildInheritedSchema(
                schema, entities, entitiesByName: entitiesByName, entityIDs: schema.entityIDsByName)
        }
        for entity in entities {
            for index in entity.indexes {
                guard !index.properties.isEmpty, Set(index.properties).count == index.properties.count else {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Index on entity '\(entity.name)' must contain distinct properties.")
                }
                for property in index.properties where !entity.attributes.contains(where: { $0.name == property }) {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Index on entity '\(entity.name)' references missing attribute '\(property)'.")
                }
                for property in index.properties
                where
                    entity.attributes.first(where: { $0.name == property })?.options.contains(.flattened) == true
                {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Index on entity '\(entity.name)' cannot target flattened composite '\(property)'; index a scalar component instead."
                    )
                }
            }
        }
        let tableNames = entities.map { "Z\($0.name)" }
        try validateUniqueNames(["Z_PRIMARYKEY", "_osd_meta"] + tableNames, scope: "table")
        let reservedColumns = Set(["Z_PK", "Z_ENT", "Z_OPT", "Z_PRIMARYKEY", "Z_OSD_META"].map(identifierKey))
        for entity in entities where reservedColumns.contains(identifierKey("Z\(entity.name)")) {
            throw SwiftDataError.unsupportedSchemaProperty(
                "Entity '\(entity.name)' generates a table identifier colliding with reserved columns."
            )
        }
        var statements = [
            "CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);",
            "CREATE TABLE _osd_meta (key TEXT PRIMARY KEY, value BLOB);",
        ]
        for entity in entities {
            try validateRelationships(entity.relationships, in: entity, schema: schema)
        }

        var allIndexNames: [String] = []
        for entity in entities {
            allIndexNames.append(
                contentsOf: entity.relationships.compactMap { relationship in
                    guard !relationship.isToMany, !isNonOwner(entity, relationship, schema: schema) else {
                        return nil
                    }
                    let mapping = schema.relationshipStorageMapping(
                        modelEntityName: entity.name, relationshipName: relationship.name)
                    let storageEntityName = mapping?.ownerRootEntityName ?? entity.name
                    let columnName = mapping?.storageColumnName ?? relationship.name
                    return "Z\(storageEntityName.uppercased())_Z\(columnName.uppercased())_INDEX"
                })
            allIndexNames.append(
                contentsOf: entity.attributes.filter { $0.options.contains(.unique) }.map {
                    "Z\(entity.name.uppercased())_Z\($0.name.uppercased())_UNIQUE_INDEX"
                })
            allIndexNames.append(
                contentsOf: entity.indexes.compactMap { index in
                    let duplicatesAttributeUnique =
                        index.isUnique && index.properties.count == 1
                        && entity.attributes.first(where: { $0.name == index.properties[0] })?.options.contains(.unique)
                            == true
                    return duplicatesAttributeUnique ? nil : indexName(entity: entity, index: index)
                })
            for relationship in entity.relationships where relationship.isToMany {
                if let table = joinTableName(for: entity, relationship: relationship, schema: schema) {
                    allIndexNames.append("\(table)_UNIQUE_INDEX")
                    allIndexNames.append("\(table)_Z_B_INDEX")
                }
            }
        }
        let joinTableNames = entities.flatMap { entity in
            entity.relationships.compactMap { relationship in
                relationship.isToMany
                    ? joinTableName(for: entity, relationship: relationship, schema: schema)
                    : nil
            }
        }
        try validateUniqueNames(tableNames + joinTableNames, scope: "table")
        var generatedIndexNames = Set<String>()
        for name in allIndexNames {
            guard generatedIndexNames.insert(identifierKey(name)).inserted else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Duplicate or colliding index identifier '\(name)'.")
            }
        }

        for entity in entities {
            for attribute in entity.attributes {
                let isFlattened = attribute.options.contains(.flattened)
                guard isFlattened == !attribute.components.isEmpty else {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Flattened attribute '\(entity.name).\(attribute.name)' must declare components, and ordinary attributes must not."
                    )
                }
                if isFlattened {
                    guard !attribute.isOptional,
                        !attribute.options.contains(.unique),
                        !attribute.options.contains(.externalStorage),
                        !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
                    else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Flattened attribute '\(entity.name).\(attribute.name)' cannot be optional, unique, external, or transformed."
                        )
                    }
                    try validateUniqueNames(
                        attribute.components.map(\.name),
                        scope: "flattened component in \(entity.name).\(attribute.name)"
                    )
                    for component in attribute.components {
                        guard component.columnName == "\(attribute.name)_\(component.name)" else {
                            throw SwiftDataError.unsupportedSchemaProperty(
                                "Flattened component column name is not canonical for '\(entity.name).\(attribute.name)'."
                            )
                        }
                        guard
                            component.name.utf8.allSatisfy({
                                ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95
                            })
                        else {
                            throw SwiftDataError.unsupportedSchemaProperty(
                                "Flattened component '\(component.name)' is not a valid property identifier.")
                        }
                        _ = try SQLColumnType.resolve(
                            component.type, property: "\(entity.name).\(component.columnName)")
                    }
                }
            }
            let attributeColumns = entity.attributes.flatMap { attribute in
                attribute.options.contains(.flattened)
                    ? attribute.components.map(\.columnName) : [attribute.name]
            }
            let propertyNames = attributeColumns + entity.relationships.map(\.name)
            try validateUniqueNames(propertyNames, scope: "property in entity '\(entity.name)'")
            let generatedProperties = propertyNames.map { "Z\($0)" }
            let logicalAndPhysicalNames =
                entity.attributes.flatMap { attribute in
                    [attribute.name] + attribute.components.map(\.columnName)
                } + entity.relationships.map(\.name)
            try validateUniqueNames(
                logicalAndPhysicalNames,
                scope: "attribute, flattened component, or relationship in entity '\(entity.name)'"
            )
            let generatedColumnKeys = Set(generatedProperties.map(identifierKey))
            guard generatedColumnKeys.count == generatedProperties.count else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Property names in entity '\(entity.name)' generate colliding column identifiers."
                )
            }
            let reservedColumnKeys = Set(["Z_PK", "Z_ENT", "Z_OPT", "ZPRIMARYKEY", "Z_OSD_META"].map(identifierKey))
            guard generatedColumnKeys.isDisjoint(with: reservedColumnKeys) else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Property in entity '\(entity.name)' collides with a reserved column."
                )
            }
            try validateUniqueNames(
                ["Z_PK", "Z_ENT", "Z_OPT"] + generatedProperties,
                scope: "column in entity '\(entity.name)'"
            )
            for index in entity.indexes {
                guard !index.properties.isEmpty, Set(index.properties).count == index.properties.count else {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Index on entity '\(entity.name)' must contain distinct properties.")
                }
                for property in index.properties where !entity.attributes.contains(where: { $0.name == property }) {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Index on entity '\(entity.name)' references missing attribute '\(property)'.")
                }
            }

            var columns = ["Z_PK INTEGER PRIMARY KEY", "Z_ENT INTEGER", "Z_OPT INTEGER"]
            let attributes = entity.attributes.sorted { bytewiseLess($0.name, $1.name) }
            for attribute in attributes {
                if attribute.options.contains(.flattened) {
                    for component in attribute.components {
                        let type = try SQLColumnType.resolve(
                            component.type, property: "\(entity.name).\(component.columnName)")
                        columns.append("Z\(component.columnName.uppercased()) \(type.rawValue)")
                    }
                    continue
                }
                let type = try SQLColumnType.resolve(
                    attribute.type, property: "\(entity.name).\(attribute.name)", options: attribute.options)
                columns.append("Z\(attribute.name.uppercased()) \(type.rawValue)")
            }
            let relationships = entity.relationships.sorted { bytewiseLess($0.name, $1.name) }
            let toOne = relationships.filter { !$0.isToMany && !isNonOwner(entity, $0, schema: schema) }
            for relationship in toOne {
                let mapping = schema.relationshipStorageMapping(
                    modelEntityName: entity.name, relationshipName: relationship.name)
                let columnName = mapping?.storageColumnName ?? relationship.name
                columns.append("Z\(columnName.uppercased()) INTEGER")
            }
            statements.append("CREATE TABLE Z\(entity.name.uppercased()) (\(columns.joined(separator: ", ")));")

            for relationship in toOne {
                let mapping = schema.relationshipStorageMapping(
                    modelEntityName: entity.name, relationshipName: relationship.name)
                let storageEntityName = mapping?.ownerRootEntityName ?? entity.name
                let columnName = mapping?.storageColumnName ?? relationship.name
                statements.append(
                    "CREATE INDEX Z\(storageEntityName.uppercased())_Z\(columnName.uppercased())_INDEX ON Z\(storageEntityName.uppercased()) (Z\(columnName.uppercased()));"
                )
            }
            for attribute in attributes where attribute.options.contains(.unique) {
                statements.append(
                    "CREATE UNIQUE INDEX Z\(entity.name.uppercased())_Z\(attribute.name.uppercased())_UNIQUE_INDEX ON Z\(entity.name.uppercased()) (Z\(attribute.name.uppercased()));"
                )
            }
            for index in entity.indexes {
                let duplicatesAttributeUnique =
                    index.isUnique && index.properties.count == 1
                    && attributes.first(where: { $0.name == index.properties[0] })?.options.contains(.unique) == true
                if duplicatesAttributeUnique { continue }
                statements.append(indexStatement(entity: entity, properties: index.properties, unique: index.isUnique))
            }
        }

        for entity in entities {
            for relationship in entity.relationships.sorted(by: { bytewiseLess($0.name, $1.name) })
            where relationship.isToMany {
                guard let joinTable = joinTableName(for: entity, relationship: relationship, schema: schema) else {
                    continue
                }
                statements.append("CREATE TABLE \(joinTable) (Z_A INTEGER, Z_B INTEGER);")
                statements.append("CREATE UNIQUE INDEX \(joinTable)_UNIQUE_INDEX ON \(joinTable) (Z_A, Z_B);")
                statements.append("CREATE INDEX \(joinTable)_Z_B_INDEX ON \(joinTable) (Z_B);")
            }
        }

        let rows = entities.enumerated().map { offset, entity in
            SchemaBootstrapRow(entityID: Int64(offset + 1), name: entity.name)
        }
        return BuiltSchema(statements: statements, bootstrapRows: rows)
    }

    private static func buildInheritedSchema(
        _ schema: Schema,
        _ entities: [Schema.Entity],
        entitiesByName: [String: Schema.Entity],
        entityIDs: [String: Int]
    ) throws -> BuiltSchema {
        for entity in entities where !entity.indexes.isEmpty {
            throw SwiftDataError.unsupportedSchemaProperty(
                "Single-table inheritance currently requires an index-free hierarchy ('\(entity.name)')."
            )
        }

        let roots = entities.filter { $0.superentityName == nil }.sorted { bytewiseLess($0.name, $1.name) }
        guard entities.allSatisfy({ entityIDs[$0.name] != nil }) else {
            throw SwiftDataError.unsupportedSchemaProperty("Schema inheritance has incomplete entity identifiers.")
        }
        let ordered = entities.sorted { (entityIDs[$0.name] ?? 0) < (entityIDs[$1.name] ?? 0) }
        guard ordered.count == entities.count else {
            throw SwiftDataError.unsupportedSchemaProperty("Schema inheritance contains an unreachable entity.")
        }

        var rootsByEntity: [String: String] = [:]
        for entity in ordered {
            if let parent = entity.superentityName {
                guard let parentRoot = rootsByEntity[parent] else {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Entity '\(entity.name)' has an invalid inheritance order.")
                }
                rootsByEntity[entity.name] = parentRoot
            } else {
                rootsByEntity[entity.name] = entity.name
            }
        }

        var statements = [
            "CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);",
            "CREATE TABLE _osd_meta (key TEXT PRIMARY KEY, value BLOB);",
        ]
        try validateUniqueNames(
            ["Z_PRIMARYKEY", "_osd_meta"] + roots.map { "Z\($0.name)" }, scope: "table")
        let reservedColumnKeys = Set(["Z_PK", "Z_ENT", "Z_OPT", "ZPRIMARYKEY", "Z_OSD_META"].map(identifierKey))
        var inheritedJoinTablesByName: [String: String] = [:]

        for root in roots {
            let members = ordered.filter { rootsByEntity[$0.name] == root.name }
            var relationshipsByColumn: [String: Schema.RelationshipStorageMapping] = [:]
            for member in members {
                for relationship in member.relationships {
                    guard
                        let mapping = schema.relationshipStorageMapping(
                            modelEntityName: member.name, relationshipName: relationship.name)
                    else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Relationship '\(member.name).\(relationship.name)' has no physical storage mapping.")
                    }
                    guard mapping.declaringEntityName == member.name else { continue }
                    if relationship.isToMany {
                        if relationship.inverse == nil {
                            guard mapping.ownerRootEntityName == root.name,
                                mapping.destinationRootEntityName == mapping.destinationEntityName,
                                let destination = entitiesByName[mapping.destinationEntityName],
                                destination.superentityName == nil,
                                let joinTable = joinTableName(for: member, relationship: relationship, schema: schema)
                            else {
                                throw SwiftDataError.unsupportedSchemaProperty(
                                    "Inherited to-many owner '\(member.name).\(relationship.name)' requires a flat destination."
                                )
                            }
                            inheritedJoinTablesByName[joinTable] = root.name
                            continue
                        }
                        guard isNonOwner(member, relationship, schema: schema) else {
                            throw SwiftDataError.unsupportedSchemaProperty(
                                "Inherited schema does not yet support to-many owner relationships ('\(member.name).\(relationship.name)')."
                            )
                        }
                        continue
                    }
                    let hasSupportedInverse: Bool
                    if let inverseName = relationship.inverse,
                        let destination = schema.entity(forName: relationship.destination),
                        let inverse = destination.relationships.first(where: { $0.name == inverseName })
                    {
                        hasSupportedInverse = inverse.isToMany && inverse.inverse == relationship.name
                    } else {
                        hasSupportedInverse = relationship.inverse == nil
                    }
                    guard hasSupportedInverse,
                        relationship.deleteRule == .nullify,
                        relationship.minimumModelCount == nil,
                        relationship.maximumModelCount == nil,
                        mapping.ownerRootEntityName == root.name,
                        mapping.destinationRootEntityName == mapping.destinationEntityName
                    else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Inherited schema currently supports to-one relationships with optional to-many inverses to flat destinations ('\(member.name).\(relationship.name)')."
                        )
                    }
                    let columnKey = identifierKey(mapping.storageColumnName)
                    if relationshipsByColumn[columnKey] != nil {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Hierarchy relationships collide on physical column '\(mapping.storageColumnName)'.")
                    }
                    relationshipsByColumn[columnKey] = mapping
                }
            }
            var attributesByName: [String: (Schema.Attribute, String)] = [:]
            for entity in members {
                let parentAttributes = entity.superentityName.flatMap { entitiesByName[$0]?.attributes } ?? []
                let parentAttributesByName = Dictionary(
                    uniqueKeysWithValues: parentAttributes.map { (identifierKey($0.name), $0) })
                let declared = try entity.attributes.filter { attribute in
                    guard let inherited = parentAttributesByName[identifierKey(attribute.name)] else { return true }
                    guard inherited == attribute else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Inheritance column '\(attribute.name)' is redeclared incompatibly by '\(entity.name)'.")
                    }
                    return false
                }
                try validateUniqueNames(
                    declared.map(\.name), scope: "property declared by entity '\(entity.name)'")
                for attribute in declared {
                    guard !attribute.options.contains(.unique),
                        !attribute.options.contains(.externalStorage),
                        !attribute.options.contains(.flattened),
                        !attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
                    else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Inherited schema currently supports plain scalar attributes only ('\(entity.name).\(attribute.name)')."
                        )
                    }
                    _ = try SQLColumnType.resolve(
                        attribute.type, property: "\(entity.name).\(attribute.name)", options: attribute.options)
                    if let existing = attributesByName[identifierKey(attribute.name)] {
                        guard existing.0.type == attribute.type,
                            existing.0.options == attribute.options,
                            existing.0.originalName == attribute.originalName
                        else {
                            throw SwiftDataError.unsupportedSchemaProperty(
                                "Inheritance column '\(attribute.name)' has incompatible declarations in '\(existing.1)' and '\(entity.name)'."
                            )
                        }
                    } else {
                        attributesByName[identifierKey(attribute.name)] = (attribute, entity.name)
                    }
                }
            }

            let allRootRequiredNames = Set(
                rootsByEntity
                    .filter { $0.value == root.name }
                    .compactMap { entityName, _ in
                        entitiesByName[entityName]?.superentityName == nil
                            ? entitiesByName[entityName]?.attributes.filter { !$0.isOptional }.map(\.name)
                            : nil
                    }
                    .flatMap { $0 })
            for requiredName in allRootRequiredNames {
                guard
                    members.allSatisfy({ entity in
                        entity.attributes.contains { identifierKey($0.name) == identifierKey(requiredName) }
                    })
                else {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Required root attribute '\(requiredName)' is missing from a descendant entity.")
                }
            }

            var columns = ["Z_PK INTEGER PRIMARY KEY", "Z_ENT INTEGER", "Z_OPT INTEGER"]
            for (key, (attribute, declaringEntity)) in attributesByName.sorted(by: { bytewiseLess($0.key, $1.key) }) {
                let sqlType = try SQLColumnType.resolve(
                    attribute.type,
                    property: "\(declaringEntity).\(attribute.name)",
                    options: attribute.options)
                let requiredAtRoot = allRootRequiredNames.contains {
                    identifierKey($0) == identifierKey(attribute.name)
                }
                let nullable = attribute.isOptional || !requiredAtRoot
                columns.append("Z\(key) \(sqlType.rawValue)\(nullable ? "" : " NOT NULL")")
            }
            for columnKey in relationshipsByColumn.keys.sorted(by: bytewiseLess) {
                columns.append("Z\(columnKey) INTEGER")
            }
            let generatedColumns = columns.dropFirst(3).map { $0.split(separator: " ", maxSplits: 1)[0] }
            let generatedKeys = Set(generatedColumns.map { identifierKey(String($0)) })
            guard generatedKeys.count == generatedColumns.count,
                generatedKeys.isDisjoint(with: reservedColumnKeys)
            else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Hierarchy rooted at '\(root.name)' has colliding or reserved SQL columns.")
            }
            statements.append("CREATE TABLE Z\(root.name.uppercased()) (\(columns.joined(separator: ", ")));")
            for columnKey in relationshipsByColumn.keys.sorted(by: bytewiseLess) {
                let indexName = "Z\(root.name.uppercased())_Z\(columnKey)_INDEX"
                statements.append(
                    "CREATE INDEX \(indexName) ON Z\(root.name.uppercased()) (Z\(columnKey));")
            }
        }

        try validateUniqueNames(
            roots.map { "Z\($0.name)" } + inheritedJoinTablesByName.keys.sorted(by: bytewiseLess),
            scope: "table")
        for joinTable in inheritedJoinTablesByName.keys.sorted(by: bytewiseLess) {
            statements.append("CREATE TABLE \(joinTable) (Z_A INTEGER, Z_B INTEGER);")
            statements.append("CREATE UNIQUE INDEX \(joinTable)_UNIQUE_INDEX ON \(joinTable) (Z_A, Z_B);")
            statements.append("CREATE INDEX \(joinTable)_Z_B_INDEX ON \(joinTable) (Z_B);")
        }

        let rows = try ordered.map { entity -> SchemaBootstrapRow in
            guard let entityID = entityIDs[entity.name] else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Schema inheritance has no identifier for entity '\(entity.name)'.")
            }
            let superEntityID: Int64
            if let parent = entity.superentityName {
                guard let parentID = entityIDs[parent] else {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Schema inheritance has no identifier for parent '\(parent)'.")
                }
                superEntityID = Int64(parentID)
            } else {
                superEntityID = 0
            }
            return SchemaBootstrapRow(
                entityID: Int64(entityID),
                name: entity.name,
                superEntityID: superEntityID)
        }
        return BuiltSchema(statements: statements, bootstrapRows: rows)
    }

    private static func indexStatement(entity: Schema.Entity, properties: [String], unique: Bool) -> String {
        let columns = properties.map { "Z\($0.uppercased())" }
        let indexName = indexName(entity: entity, properties: properties, unique: unique)
        return
            "CREATE \(unique ? "UNIQUE " : "")INDEX \(indexName) ON Z\(entity.name.uppercased()) (\(columns.joined(separator: ", ")));"
    }

    private static func indexName(entity: Schema.Entity, index: Schema.Index) -> String {
        indexName(entity: entity, properties: index.properties, unique: index.isUnique)
    }

    private static func indexName(entity: Schema.Entity, properties: [String], unique: Bool) -> String {
        let columns = properties.map { "Z\($0.uppercased())" }
        return "Z\(entity.name.uppercased())_\(columns.joined(separator: "_"))\(unique ? "_UNIQUE" : "")_INDEX"
    }

    package static func isNonOwner(
        _ entity: Schema.Entity, _ relationship: Schema.Relationship, schema: Schema
    ) -> Bool {
        guard let inverseName = relationship.inverse,
            let destination = schema.entity(forName: relationship.destination),
            let inverse = destination.relationships.first(where: { $0.name == inverseName }),
            inverse.inverse == relationship.name
        else { return false }
        let mapping = schema.relationshipStorageMapping(
            modelEntityName: entity.name, relationshipName: relationship.name)
        let logicalOwnerName = mapping?.declaringEntityName ?? entity.name
        var currentEntityName: String? = logicalOwnerName
        var visited: Set<String> = []
        var inverseDestinationMatchesOwner = false
        while let currentName = currentEntityName, visited.insert(currentName).inserted {
            if currentName == inverse.destination { inverseDestinationMatchesOwner = true; break }
            currentEntityName = schema.entity(forName: currentName)?.superentityName
        }
        guard inverseDestinationMatchesOwner else { return false }
        if relationship.isToMany, inverse.isToMany {
            let current = "\(logicalOwnerName).\(relationship.name)"
            let other = "\(destination.name).\(inverse.name)"
            return !bytewiseLess(current, other)
        }
        if relationship.isToMany, !inverse.isToMany { return true }
        guard !relationship.isToMany, !inverse.isToMany else { return false }
        let current = "\(logicalOwnerName).\(relationship.name)"
        let other = "\(destination.name).\(inverse.name)"
        return bytewiseLess(other, current)
    }

    private static func joinTableName(
        for entity: Schema.Entity, relationship: Schema.Relationship, schema: Schema
    ) -> String? {
        guard relationship.isToMany else { return nil }
        let mapping = schema.relationshipStorageMapping(
            modelEntityName: entity.name, relationshipName: relationship.name)
        let declaringEntityName = mapping?.declaringEntityName ?? entity.name
        let destinationEntityName = mapping?.destinationEntityName ?? relationship.destination
        let owner = "\(declaringEntityName).\(relationship.name)"
        if let inverseName = relationship.inverse,
            let destination = schema.entity(forName: destinationEntityName),
            let inverse = destination.relationships.first(where: { $0.name == inverseName }), inverse.isToMany
        {
            let other = "\(destination.name).\(inverse.name)"
            guard bytewiseLess(owner, other) else { return nil }
            return
                "Z_\(declaringEntityName.uppercased())_\(relationship.name.uppercased())_\(destination.name.uppercased())_\(inverse.name.uppercased())"
        }
        guard relationship.inverse == nil else { return nil }
        return
            "Z_\(declaringEntityName.uppercased())_\(relationship.name.uppercased())_\(destinationEntityName.uppercased())"
    }
}
