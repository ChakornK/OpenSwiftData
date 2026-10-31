import Foundation
import OSDCore

package struct CompiledPredicate: Sendable, Equatable {
    package let sql: String
    package let arguments: [StoredValue]
    package let cacheKey: String

    package init(sql: String, arguments: [StoredValue], cacheKey: String) {
        self.sql = sql
        self.arguments = arguments
        self.cacheKey = cacheKey
    }
}

package enum PredicatePlanBuilder {
    package static func build(_ ir: PredicateIR) -> PredicatePlan? {
        switch ir {
        case let .conjunction(lhs, rhs):
            guard let lhs = build(lhs), let rhs = build(rhs) else { return nil }
            return .conjunction(lhs, rhs)
        case let .disjunction(lhs, rhs):
            guard let lhs = build(lhs), let rhs = build(rhs) else { return nil }
            return .disjunction(lhs, rhs)
        case let .negation(value):
            guard let value = build(value) else { return nil }
            return .negation(value)
        case let .comparison(op, lhs, rhs):
            if (op == .equal || op == .notEqual), case .value(.null) = rhs {
                guard let lhsPlan = build(lhs) else { return nil }
                return .isNull(lhsPlan, negated: op == .notEqual)
            }
            if (op == .equal || op == .notEqual), case .value(.null) = lhs {
                guard let rhsPlan = build(rhs) else { return nil }
                return .isNull(rhsPlan, negated: op == .notEqual)
            }
            guard let lhs = build(lhs), let rhs = build(rhs) else { return nil }
            return .comparison(runtimeOperator(op), lhs, rhs)
        case let .decimalComparison(op, lhs, rhs):
            if (op == .equal || op == .notEqual), case .value(.null) = rhs {
                guard let lhsPlan = build(lhs) else { return nil }
                return .isNull(lhsPlan, negated: op == .notEqual)
            }
            if (op == .equal || op == .notEqual), case .value(.null) = lhs {
                guard let rhsPlan = build(rhs) else { return nil }
                return .isNull(rhsPlan, negated: op == .notEqual)
            }
            guard let lhs = build(lhs), let rhs = build(rhs) else { return nil }
            return .decimalComparison(runtimeOperator(op), lhs, rhs)
        case let .arithmetic(op, lhs, rhs):
            guard let lhs = build(lhs), let rhs = build(rhs) else { return nil }
            return .arithmetic(runtimeArithmeticOperator(op), lhs, rhs)
        case let .keyPath(path):
            guard !path.isEmpty else { return nil }
            return .property(path.joined(separator: "."))
        case let .value(value):
            return .value(value)
        case let .nilCoalesce(lhs, rhs):
            guard let lhs = build(lhs), let rhs = build(rhs) else { return nil }
            return .coalesce(lhs, rhs)
        case let .conditional(test, trueBranch, falseBranch):
            guard let test = build(test), let trueBranch = build(trueBranch), let falseBranch = build(falseBranch)
            else { return nil }
            return .conditional(test, trueBranch, falseBranch)
        case let .localizedStandardContains(lhs, rhs):
            guard let lhs = build(lhs), let rhs = build(rhs) else { return nil }
            return .localizedStandardContains(lhs, rhs)
        case let .stringContains(lhs, rhs):
            guard let lhs = build(lhs), let rhs = build(rhs) else { return nil }
            return .stringContains(lhs, rhs)
        case let .stringStartsWith(lhs, rhs):
            guard let lhs = build(lhs), let rhs = build(rhs) else { return nil }
            return .stringStartsWith(lhs, rhs)
        case let .collectionContains(name, elementType, element):
            guard let element = build(element) else { return nil }
            return .collectionContains(name, elementType, element)
        case let .collectionAllEqual(name, elementType, element):
            guard let element = build(element) else { return nil }
            return .collectionAllEqual(name, elementType, element)
        case let .codableCollectionIsEmpty(name):
            return .codableCollectionIsEmpty(name)
        case let .codableCollectionCount(name):
            return .codableCollectionCount(name)
        case let .relationshipContains(name, body):
            guard let body = build(body) else { return nil }
            return .relationshipContains(name, body)
        case let .relationshipCount(name):
            return .collectionCount(name)
        case .sequenceContains:
            return nil
        }
    }

    private static func runtimeOperator(_ value: PredicateIR.ComparisonOperator) -> PredicateComparisonOperator {
        switch value {
        case .equal: .equal
        case .notEqual: .notEqual
        case .lessThan: .lessThan
        case .lessThanOrEqual: .lessThanOrEqual
        case .greaterThan: .greaterThan
        case .greaterThanOrEqual: .greaterThanOrEqual
        }
    }

    private static func runtimeArithmeticOperator(_ value: PredicateIR.ArithmeticOperator)
        -> PredicateArithmeticOperator
    {
        switch value {
        case .add: .add
        case .subtract: .subtract
        case .multiply: .multiply
        case .divide: .divide
        case .remainder: .remainder
        }
    }
}

package enum SQLCompiler {
    private static let cache = PredicatePlanCache()

    package static func compile(
        _ ir: PredicateIR,
        entity: String,
        ordering: [String] = [],
        relationships: [RuntimePredicateRelationship] = []
    ) throws -> CompiledPredicate {
        let key = structuralKey(ir, entity: entity, ordering: ordering, relationships: relationships)
        if let cached = cache.value(for: key) {
            var arguments: [StoredValue] = []
            _ = try render(ir, arguments: &arguments, entity: entity, relationships: relationships)
            return CompiledPredicate(sql: cached.sql, arguments: arguments, cacheKey: key)
        }
        var arguments: [StoredValue] = []
        let sql = try render(ir, arguments: &arguments, entity: entity, relationships: relationships)
        cache.insert(Plan(sql: sql), for: key)
        return CompiledPredicate(sql: sql, arguments: arguments, cacheKey: key)
    }

    package static func compile(
        _ node: PredicateMirrorWalker.Node,
        entity: String,
        ordering: [String] = []
    ) throws -> CompiledPredicate {
        try compile(PredicateIRBuilder.build(node), entity: entity, ordering: ordering)
    }

    private static func render(
        _ ir: PredicateIR,
        arguments: inout [StoredValue],
        entity: String,
        relationships: [RuntimePredicateRelationship],
        tableAlias: String = "t0"
    ) throws -> String {
        switch ir {
        case let .conjunction(lhs, rhs):
            return
                "(\(try render(lhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)) AND \(try render(rhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)))"
        case let .disjunction(lhs, rhs):
            return
                "(\(try render(lhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)) OR \(try render(rhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)))"
        case let .negation(value):
            return
                "(NOT \(try render(value, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)))"
        case let .comparison(op, lhs, rhs):
            if case .value(.null) = rhs, op == .equal || op == .notEqual {
                let lhsSQL = try render(
                    lhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)
                return "(\(lhsSQL) IS \(op == .notEqual ? "NOT " : "")NULL)"
            }
            if case .value(.null) = lhs, op == .equal || op == .notEqual {
                let rhsSQL = try render(
                    rhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)
                return "(\(rhsSQL) IS \(op == .notEqual ? "NOT " : "")NULL)"
            }
            let lhsSQL = try render(
                lhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)
            let rhsSQL = try render(
                rhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)
            return "(\(lhsSQL) \(comparisonSymbol(op)) \(rhsSQL))"
        case let .decimalComparison(op, lhs, rhs):
            if case .value(.null) = rhs, op == .equal || op == .notEqual {
                let lhsSQL = try render(
                    lhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)
                return "(\(lhsSQL) IS \(op == .notEqual ? "NOT " : "")NULL)"
            }
            if case .value(.null) = lhs, op == .equal || op == .notEqual {
                let rhsSQL = try render(
                    rhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)
                return "(\(rhsSQL) IS \(op == .notEqual ? "NOT " : "")NULL)"
            }
            let lhsSQL = try render(
                lhs, arguments: &arguments, entity: entity, relationships: relationships,
                tableAlias: tableAlias)
            let rhsSQL = try render(
                rhs, arguments: &arguments, entity: entity, relationships: relationships,
                tableAlias: tableAlias)
            return "(\(lhsSQL) COLLATE OSD_DECIMAL \(comparisonSymbol(op)) \(rhsSQL))"
        case let .arithmetic(op, lhs, rhs):
            let function =
                switch op {
                case .add: "osd_int_add"
                case .subtract: "osd_int_subtract"
                case .multiply: "osd_int_multiply"
                case .divide: "osd_int_divide"
                case .remainder: "osd_int_remainder"
                }
            return
                "\(function)(\(try render(lhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)), \(try render(rhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)))"
        case let .keyPath(path):
            guard let property = path.last, Self.validIdentifier(property) else {
                throw SwiftDataError.unsupportedPredicate("Invalid key path")
            }
            if path.count > 2 {
                let relationshipNames = Array(path.dropLast())
                func renderHop(_ index: Int, ownerEntityName: String, ownerAlias: String) throws -> String {
                    guard index < relationshipNames.count,
                        let relationship = relationships.first(where: {
                            $0.ownerEntityName == ownerEntityName && $0.propertyName == relationshipNames[index]
                        }),
                        !relationship.isToMany,
                        Self.validIdentifier(relationship.foreignKeyColumnName)
                    else {
                        throw SwiftDataError.unsupportedPredicate(
                            "Nested relationship predicate requires to-one foreign keys.")
                    }
                    let destinationEntityName: String
                    let destinationRootEntityName: String
                    let destinationEntityIDs: [Int]
                    let foreignKeyOwner: Bool
                    if relationship.queriesInverseToOne {
                        guard let inverseOwnerRoot = relationship.inverseOwnerRootEntityName,
                            Self.validIdentifier(inverseOwnerRoot),
                            !relationship.inverseOwnerEntityIDs.isEmpty,
                            relationship.destinationRootEntityName == inverseOwnerRoot
                        else {
                            throw SwiftDataError.unsupportedPredicate(
                                "Nested inverse relationship requires a flat to-one destination.")
                        }
                        destinationEntityName = relationship.destinationEntityName
                        destinationRootEntityName = inverseOwnerRoot
                        destinationEntityIDs = relationship.inverseOwnerEntityIDs
                        foreignKeyOwner = false
                    } else {
                        guard Self.validIdentifier(relationship.destinationRootEntityName),
                            !relationship.destinationEntityIDs.isEmpty
                        else {
                            throw SwiftDataError.unsupportedPredicate(
                                "Nested relationship predicate has incomplete destination metadata.")
                        }
                        destinationEntityName = relationship.destinationEntityName
                        destinationRootEntityName = relationship.destinationRootEntityName
                        destinationEntityIDs = relationship.destinationEntityIDs
                        foreignKeyOwner = true
                    }
                    let alias = "osd_rel_\(index + 1)"
                    let selected =
                        index + 1 == relationshipNames.count
                        ? "\(alias).Z\(property.uppercased())"
                        : try renderHop(index + 1, ownerEntityName: destinationEntityName, ownerAlias: alias)
                    let placeholders = Array(repeating: "?", count: destinationEntityIDs.count)
                        .joined(separator: ", ")
                    arguments.append(contentsOf: destinationEntityIDs.map { .int(Int64($0)) })
                    let correlation =
                        foreignKeyOwner
                        ? "\(alias).Z_PK = \(ownerAlias).Z\(relationship.foreignKeyColumnName.uppercased())"
                        : "\(alias).Z\(relationship.foreignKeyColumnName.uppercased()) = \(ownerAlias).Z_PK"
                    let ordering = foreignKeyOwner ? "" : " ORDER BY \(alias).Z_PK ASC"
                    return
                        "(SELECT \(selected) FROM Z\(destinationRootEntityName.uppercased()) AS \(alias) "
                        + "WHERE \(correlation) AND \(alias).Z_ENT IN (\(placeholders))"
                        + "\(ordering) LIMIT 1)"
                }
                return try renderHop(0, ownerEntityName: entity, ownerAlias: tableAlias)
            }
            if path.count == 2,
                let relationship = relationships.first(where: {
                    $0.ownerEntityName == entity && $0.propertyName == path[0]
                })
            {
                if relationship.queriesInverseToOne {
                    guard let inverseOwnerRoot = relationship.inverseOwnerRootEntityName,
                        !relationship.inverseOwnerEntityIDs.isEmpty,
                        Self.validIdentifier(inverseOwnerRoot),
                        Self.validIdentifier(relationship.foreignKeyColumnName)
                    else {
                        throw SwiftDataError.unsupportedPredicate(
                            "Inverse to-one predicate has incomplete foreign-key metadata")
                    }
                    let placeholders = Array(repeating: "?", count: relationship.inverseOwnerEntityIDs.count)
                        .joined(separator: ", ")
                    arguments.append(contentsOf: relationship.inverseOwnerEntityIDs.map { .int(Int64($0)) })
                    return
                        "(SELECT t1.Z\(property.uppercased()) FROM Z\(inverseOwnerRoot.uppercased()) AS t1 "
                        + "WHERE t1.Z\(relationship.foreignKeyColumnName.uppercased()) = t0.Z_PK "
                        + "AND t1.Z_ENT IN (\(placeholders)) ORDER BY t1.Z_PK ASC LIMIT 1)"
                }
                let destinationIDs = relationship.destinationEntityIDs
                guard !destinationIDs.isEmpty else {
                    throw SwiftDataError.unsupportedPredicate("Relationship predicate has no destination entities")
                }
                let placeholders = Array(repeating: "?", count: destinationIDs.count).joined(separator: ", ")
                arguments.append(contentsOf: destinationIDs.map { .int(Int64($0)) })
                return
                    "(SELECT t1.Z\(property.uppercased()) FROM Z\(relationship.destinationRootEntityName.uppercased()) AS t1 "
                    + "WHERE t1.Z_PK = t0.Z\(relationship.foreignKeyColumnName.uppercased()) "
                    + "AND t1.Z_ENT IN (\(placeholders)) LIMIT 1)"
            }
            if path.count == 1,
                let relationship = relationships.first(where: {
                    $0.ownerEntityName == entity && $0.propertyName == property
                })
            {
                if relationship.queriesInverseToOne {
                    guard let inverseOwnerRoot = relationship.inverseOwnerRootEntityName,
                        Self.validIdentifier(inverseOwnerRoot),
                        !relationship.inverseOwnerEntityIDs.isEmpty,
                        Self.validIdentifier(relationship.foreignKeyColumnName)
                    else {
                        throw SwiftDataError.unsupportedPredicate(
                            "Inverse to-one relationship has incomplete foreign-key metadata")
                    }
                    let placeholders = Array(repeating: "?", count: relationship.inverseOwnerEntityIDs.count)
                        .joined(separator: ", ")
                    arguments.append(contentsOf: relationship.inverseOwnerEntityIDs.map { .int(Int64($0)) })
                    return
                        "(SELECT t1.Z_PK FROM Z\(inverseOwnerRoot.uppercased()) AS t1 "
                        + "WHERE t1.Z\(relationship.foreignKeyColumnName.uppercased()) = \(tableAlias).Z_PK "
                        + "AND t1.Z_ENT IN (\(placeholders)) ORDER BY t1.Z_PK ASC LIMIT 1)"
                }
                return "t0.Z\(relationship.foreignKeyColumnName.uppercased())"
            }
            guard path.count == 1 else {
                throw SwiftDataError.unsupportedPredicate("Unsupported relationship predicate path")
            }
            return "\(tableAlias).Z\(property.uppercased())"
        case let .value(value):
            arguments.append(value)
            return "?"
        case let .nilCoalesce(lhs, rhs):
            return
                "COALESCE(\(try render(lhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)), \(try render(rhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)))"
        case let .conditional(test, trueBranch, falseBranch):
            return
                "(CASE WHEN \(try render(test, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)) THEN \(try render(trueBranch, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)) ELSE \(try render(falseBranch, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)) END)"
        case let .localizedStandardContains(lhs, rhs):
            return
                "osd_localized_standard_contains(\(try render(lhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)), \(try render(rhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)))"
        case let .stringContains(lhs, rhs):
            return
                "osd_string_contains(\(try render(lhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)), \(try render(rhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)))"
        case let .stringStartsWith(lhs, rhs):
            return
                "osd_string_starts_with(\(try render(lhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)), \(try render(rhs, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)))"
        case let .collectionContains(name, elementType, element):
            guard Self.validIdentifier(name),
                [
                    "String", "Bool", "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32",
                    "UInt64",
                ]
                .contains(elementType)
            else {
                throw SwiftDataError.unsupportedPredicate("Unsupported scalar collection membership type")
            }
            let elementSQL = try render(
                element, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)
            arguments.append(.text(elementType))
            return "osd_json_array_contains(\(tableAlias).Z\(name.uppercased()), \(elementSQL), ?)"
        case let .collectionAllEqual(name, elementType, element):
            guard Self.validIdentifier(name) else {
                throw SwiftDataError.unsupportedPredicate("Invalid Codable collection property name")
            }
            let elementSQL = try render(
                element, arguments: &arguments, entity: entity, relationships: relationships, tableAlias: tableAlias)
            arguments.append(.text(elementType))
            return "osd_json_array_all_equal(\(tableAlias).Z\(name.uppercased()), \(elementSQL), ?)"
        case let .codableCollectionIsEmpty(name):
            guard Self.validIdentifier(name) else {
                throw SwiftDataError.unsupportedPredicate("Invalid Codable collection property name")
            }
            return "osd_json_array_is_empty(\(tableAlias).Z\(name.uppercased()))"
        case let .codableCollectionCount(name):
            guard Self.validIdentifier(name) else {
                throw SwiftDataError.unsupportedPredicate("Invalid Codable collection property name")
            }
            return "osd_json_array_count(\(tableAlias).Z\(name.uppercased()))"
        case let .relationshipContains(name, body):
            let path = name.split(separator: ".").map(String.init)
            guard let collectionName = path.last else {
                throw SwiftDataError.unsupportedPredicate("SequenceContainsWhere has an empty collection path.")
            }
            let ownerPath = Array(path.dropLast())
            var collectionOwnerEntityName = entity
            for hop in ownerPath {
                guard
                    let ownerRelationship = relationships.first(where: {
                        $0.ownerEntityName == collectionOwnerEntityName && $0.propertyName == hop
                    }),
                    !ownerRelationship.isToMany
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Nested collection predicates require to-one relationships before the collection.")
                }
                collectionOwnerEntityName = ownerRelationship.destinationEntityName
            }
            guard
                let relationship = relationships.first(where: {
                    $0.ownerEntityName == collectionOwnerEntityName
                        && $0.propertyName == collectionName && $0.isToMany
                }),
                Self.validIdentifier(relationship.destinationRootEntityName),
                !relationship.destinationEntityIDs.isEmpty
            else {
                throw SwiftDataError.unsupportedPredicate(
                    "SequenceContainsWhere requires supported to-many relationship storage.")
            }
            func renderOwnerPrimaryKey(
                _ index: Int,
                ownerEntityName: String,
                ownerAlias: String
            ) throws -> String {
                guard index < ownerPath.count else { return "\(ownerAlias).Z_PK" }
                guard
                    let ownerRelationship = relationships.first(where: {
                        $0.ownerEntityName == ownerEntityName && $0.propertyName == ownerPath[index]
                    }),
                    !ownerRelationship.isToMany,
                    Self.validIdentifier(ownerRelationship.foreignKeyColumnName)
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Nested collection predicates require resolved to-one owner hops.")
                }
                let alias = "osd_collection_owner_\(index + 1)"
                let selected = try renderOwnerPrimaryKey(
                    index + 1,
                    ownerEntityName: ownerRelationship.destinationEntityName,
                    ownerAlias: alias)
                if ownerRelationship.queriesInverseToOne {
                    guard let inverseOwnerRoot = ownerRelationship.inverseOwnerRootEntityName,
                        Self.validIdentifier(inverseOwnerRoot),
                        !ownerRelationship.inverseOwnerEntityIDs.isEmpty
                    else {
                        throw SwiftDataError.unsupportedPredicate(
                            "Nested inverse collection owner has incomplete metadata.")
                    }
                    let placeholders = Array(repeating: "?", count: ownerRelationship.inverseOwnerEntityIDs.count)
                        .joined(separator: ", ")
                    arguments.append(
                        contentsOf: ownerRelationship.inverseOwnerEntityIDs.map { .int(Int64($0)) })
                    return
                        "(SELECT \(selected) FROM Z\(inverseOwnerRoot.uppercased()) AS \(alias) "
                        + "WHERE \(alias).Z\(ownerRelationship.foreignKeyColumnName.uppercased()) = \(ownerAlias).Z_PK "
                        + "AND \(alias).Z_ENT IN (\(placeholders)) ORDER BY \(alias).Z_PK ASC LIMIT 1)"
                }
                guard Self.validIdentifier(ownerRelationship.destinationRootEntityName),
                    !ownerRelationship.destinationEntityIDs.isEmpty
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Nested collection owner has incomplete destination metadata.")
                }
                let placeholders = Array(repeating: "?", count: ownerRelationship.destinationEntityIDs.count)
                    .joined(separator: ", ")
                arguments.append(
                    contentsOf: ownerRelationship.destinationEntityIDs.map { .int(Int64($0)) })
                return
                    "(SELECT \(selected) FROM Z\(ownerRelationship.destinationRootEntityName.uppercased()) AS \(alias) "
                    + "WHERE \(alias).Z_PK = \(ownerAlias).Z\(ownerRelationship.foreignKeyColumnName.uppercased()) "
                    + "AND \(alias).Z_ENT IN (\(placeholders)) LIMIT 1)"
            }
            let ownerPrimaryKeySQL = try renderOwnerPrimaryKey(
                0, ownerEntityName: entity, ownerAlias: tableAlias)
            let placeholders = Array(repeating: "?", count: relationship.destinationEntityIDs.count)
                .joined(separator: ", ")
            arguments.append(contentsOf: relationship.destinationEntityIDs.map { .int(Int64($0)) })
            let bodySQL = try render(
                body, arguments: &arguments, entity: relationship.destinationEntityName,
                relationships: relationships, tableAlias: "t1")
            if relationship.storesForeignKeyOnDestination {
                guard Self.validIdentifier(relationship.foreignKeyColumnName) else {
                    throw SwiftDataError.unsupportedPredicate("Invalid inverse relationship foreign-key column")
                }
                return "EXISTS (SELECT 1 FROM Z\(relationship.destinationRootEntityName.uppercased()) AS t1 "
                    + "WHERE t1.Z\(relationship.foreignKeyColumnName.uppercased()) = \(ownerPrimaryKeySQL) "
                    + "AND t1.Z_ENT IN (\(placeholders)) AND \(bodySQL))"
            }
            guard let joinTable = relationship.joinTableName, Self.validIdentifier(joinTable),
                Self.validIdentifier(relationship.ownerJoinColumnName),
                Self.validIdentifier(relationship.destinationJoinColumnName)
            else {
                throw SwiftDataError.unsupportedPredicate(
                    "SequenceContainsWhere requires a supported to-many relationship join table.")
            }
            return "EXISTS (SELECT 1 FROM \(joinTable.uppercased()) AS j "
                + "JOIN Z\(relationship.destinationRootEntityName.uppercased()) AS t1 "
                + "ON t1.Z_PK = j.\(relationship.destinationJoinColumnName.uppercased()) "
                + "WHERE j.\(relationship.ownerJoinColumnName.uppercased()) = \(ownerPrimaryKeySQL) "
                + "AND t1.Z_ENT IN (\(placeholders)) AND \(bodySQL))"
        case let .relationshipCount(name):
            guard
                let relationship = relationships.first(where: {
                    $0.ownerEntityName == entity && $0.propertyName == name && $0.isToMany
                }),
                Self.validIdentifier(relationship.destinationRootEntityName),
                !relationship.destinationEntityIDs.isEmpty
            else {
                throw SwiftDataError.unsupportedPredicate(
                    "Collection count requires supported direct to-many relationship storage.")
            }
            let placeholders = Array(repeating: "?", count: relationship.destinationEntityIDs.count)
                .joined(separator: ", ")
            arguments.append(contentsOf: relationship.destinationEntityIDs.map { .int(Int64($0)) })
            if relationship.storesForeignKeyOnDestination {
                guard Self.validIdentifier(relationship.foreignKeyColumnName) else {
                    throw SwiftDataError.unsupportedPredicate("Invalid inverse relationship foreign-key column")
                }
                return "(SELECT COUNT(*) FROM Z\(relationship.destinationRootEntityName.uppercased()) AS t1 "
                    + "WHERE t1.Z\(relationship.foreignKeyColumnName.uppercased()) = \(tableAlias).Z_PK "
                    + "AND t1.Z_ENT IN (\(placeholders)))"
            }
            guard let joinTable = relationship.joinTableName, Self.validIdentifier(joinTable),
                Self.validIdentifier(relationship.ownerJoinColumnName),
                Self.validIdentifier(relationship.destinationJoinColumnName)
            else {
                throw SwiftDataError.unsupportedPredicate("Collection count requires a supported join table.")
            }
            return "(SELECT COUNT(*) FROM \(joinTable.uppercased()) AS j "
                + "JOIN Z\(relationship.destinationRootEntityName.uppercased()) AS t1 "
                + "ON t1.Z_PK = j.\(relationship.destinationJoinColumnName.uppercased()) "
                + "WHERE j.\(relationship.ownerJoinColumnName.uppercased()) = \(tableAlias).Z_PK "
                + "AND t1.Z_ENT IN (\(placeholders)))"
        case .sequenceContains:
            throw SwiftDataError.unsupportedPredicate(
                "SequenceContains SQL compilation requires collection encoding metadata")
        }
    }

    private static func comparisonSymbol(_ op: PredicateIR.ComparisonOperator) -> String {
        switch op {
        case .equal: "="
        case .notEqual: "!="
        case .lessThan: "<"
        case .lessThanOrEqual: "<="
        case .greaterThan: ">"
        case .greaterThanOrEqual: ">="
        }
    }

    private static func structuralKey(
        _ ir: PredicateIR,
        entity: String,
        ordering: [String],
        relationships: [RuntimePredicateRelationship]
    ) -> String {
        let relationshipKey = relationships.sorted {
            "\($0.ownerEntityName).\($0.propertyName)" < "\($1.ownerEntityName).\($1.propertyName)"
        }.map {
            "\($0.ownerEntityName).\($0.propertyName)[toMany=\($0.isToMany),destinationFK=\($0.storesForeignKeyOnDestination)]->\($0.destinationRootEntityName).\($0.foreignKeyColumnName).\($0.joinTableName ?? "").\($0.ownerJoinColumnName).\($0.destinationJoinColumnName).\($0.destinationEntityIDs)"
        }.joined(separator: ";")
        return "\(entity)|\(ordering.joined(separator: ","))|\(relationshipKey)|\(structure(ir))"
    }

    private static func structure(_ ir: PredicateIR) -> String {
        switch ir {
        case let .conjunction(lhs, rhs): "and(\(structure(lhs)),\(structure(rhs)))"
        case let .disjunction(lhs, rhs): "or(\(structure(lhs)),\(structure(rhs)))"
        case let .negation(value): "not(\(structure(value)))"
        case let .comparison(op, lhs, rhs): "compare(\(op),\(structure(lhs)),\(structure(rhs)))"
        case let .decimalComparison(op, lhs, rhs): "decimalCompare(\(op),\(structure(lhs)),\(structure(rhs)))"
        case let .arithmetic(op, lhs, rhs): "arithmetic(\(op),\(structure(lhs)),\(structure(rhs)))"
        case let .keyPath(path): "keypath(\(path.joined(separator: ".")))"
        case let .value(value):
            if case .null = value { "value(NULL)" } else { "value(?)" }
        case let .nilCoalesce(lhs, rhs): "coalesce(\(structure(lhs)),\(structure(rhs)))"
        case let .conditional(test, trueBranch, falseBranch):
            "conditional(\(structure(test)),\(structure(trueBranch)),\(structure(falseBranch)))"
        case let .localizedStandardContains(lhs, rhs): "localizedContains(\(structure(lhs)),\(structure(rhs)))"
        case let .stringContains(lhs, rhs): "stringContains(\(structure(lhs)),\(structure(rhs)))"
        case let .stringStartsWith(lhs, rhs): "stringStartsWith(\(structure(lhs)),\(structure(rhs)))"
        case let .collectionContains(name, elementType, element):
            "collectionContains(\(name),\(elementType),\(structure(element)))"
        case let .collectionAllEqual(name, elementType, element):
            "collectionAllEqual(\(name),\(elementType),\(structure(element)))"
        case let .codableCollectionIsEmpty(name): "codableCollectionIsEmpty(\(name))"
        case let .codableCollectionCount(name): "codableCollectionCount(\(name))"
        case let .sequenceContains(sequence, element): "contains(\(structure(sequence)),\(structure(element)))"
        case let .relationshipContains(name, body): "relationshipContains(\(name),\(structure(body)))"
        case let .relationshipCount(name): "relationshipCount(\(name))"
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.allSatisfy { byte in
                (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 95
            }
    }

    private struct Plan: Sendable {
        let sql: String
    }

    private final class PredicatePlanCache: @unchecked Sendable {
        private let lock = NSLock()
        private var plans: [String: Plan] = [:]

        func value(for key: String) -> Plan? {
            lock.lock()
            defer { lock.unlock() }
            return plans[key]
        }

        func insert(_ plan: Plan, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            plans[key] = plan
        }
    }
}
