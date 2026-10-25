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

    package static func build(_ schema: Schema) throws -> BuiltSchema {
        let entities = schema.entities.sorted { bytewiseLess($0.name, $1.name) }
        try validateUniqueNames(entities.map(\.name), scope: "entity")
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
        let entityNames = Set(entities.map(\.name))

        for entity in entities {
            let propertyNames = entity.attributes.map(\.name) + entity.relationships.map(\.name)
            try validateUniqueNames(propertyNames, scope: "property in entity '\(entity.name)'")
            let generatedProperties = propertyNames.map { "Z\($0)" }
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

            var columns = ["Z_PK INTEGER PRIMARY KEY", "Z_ENT INTEGER", "Z_OPT INTEGER"]
            let attributes = entity.attributes.sorted { bytewiseLess($0.name, $1.name) }
            for attribute in attributes {
                let type = try SQLColumnType.resolve(
                    attribute.type, property: "\(entity.name).\(attribute.name)", options: attribute.options)
                columns.append("Z\(attribute.name.uppercased()) \(type.rawValue)")
            }
            let relationships = entity.relationships.sorted { bytewiseLess($0.name, $1.name) }
            let toOne = relationships.filter { !$0.isToMany && !isOneToOneNonOwner(entity, $0, entities) }
            for relationship in toOne {
                guard entityNames.contains(relationship.destination) else {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Relationship '\(entity.name).\(relationship.name)' targets missing entity '\(relationship.destination)'."
                    )
                }
                columns.append("Z\(relationship.name.uppercased()) INTEGER")
            }
            statements.append("CREATE TABLE Z\(entity.name.uppercased()) (\(columns.joined(separator: ", ")));")

            for relationship in toOne {
                statements.append(
                    "CREATE INDEX Z\(entity.name.uppercased())_Z\(relationship.name.uppercased())_INDEX ON Z\(entity.name.uppercased()) (Z\(relationship.name.uppercased()));"
                )
            }
            for attribute in attributes where attribute.options.contains(.unique) {
                statements.append(
                    "CREATE UNIQUE INDEX Z\(entity.name.uppercased())_Z\(attribute.name.uppercased())_UNIQUE_INDEX ON Z\(entity.name.uppercased()) (Z\(attribute.name.uppercased()));"
                )
            }
            for relationship in relationships where relationship.isToMany && relationship.inverse == nil {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Join-table DDL for relationship '\(entity.name).\(relationship.name)' is not specified canonically."
                )
            }
        }

        let rows = entities.enumerated().map { offset, entity in
            SchemaBootstrapRow(entityID: Int64(offset + 1), name: entity.name)
        }
        return BuiltSchema(statements: statements, bootstrapRows: rows)
    }

    private static func isOneToOneNonOwner(
        _ entity: Schema.Entity,
        _ relationship: Schema.Relationship,
        _ entities: [Schema.Entity]
    ) -> Bool {
        guard let inverseName = relationship.inverse,
            let destination = entities.first(where: { $0.name == relationship.destination }),
            let inverse = destination.relationships.first(where: { $0.name == inverseName }),
            !inverse.isToMany,
            inverse.destination == entity.name,
            inverse.inverse == relationship.name
        else {
            return false
        }
        let current = "\(entity.name).\(relationship.name)"
        let other = "\(destination.name).\(inverse.name)"
        return bytewiseLess(other, current)
    }
}
