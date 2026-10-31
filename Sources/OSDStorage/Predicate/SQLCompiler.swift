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
        case let .relationshipContains(name, body):
            guard let body = build(body) else { return nil }
            return .relationshipContains(name, body)
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
            if path.count == 2,
                let relationship = relationships.first(where: {
                    $0.ownerEntityName == entity && $0.propertyName == path[0]
                })
            {
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
        case let .relationshipContains(name, body):
            guard
                let relationship = relationships.first(where: {
                    $0.ownerEntityName == entity && $0.propertyName == name && $0.isToMany
                }),
                Self.validIdentifier(relationship.destinationRootEntityName),
                !relationship.destinationEntityIDs.isEmpty
            else {
                throw SwiftDataError.unsupportedPredicate(
                    "SequenceContainsWhere requires supported to-many relationship storage.")
            }
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
                    + "WHERE t1.Z\(relationship.foreignKeyColumnName.uppercased()) = \(tableAlias).Z_PK "
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
                + "WHERE j.\(relationship.ownerJoinColumnName.uppercased()) = \(tableAlias).Z_PK "
                + "AND t1.Z_ENT IN (\(placeholders)) AND \(bodySQL))"
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
        case let .sequenceContains(sequence, element): "contains(\(structure(sequence)),\(structure(element)))"
        case let .relationshipContains(name, body): "relationshipContains(\(name),\(structure(body)))"
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
