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

package enum SQLCompiler {
    private static let cache = PredicatePlanCache()

    package static func compile(
        _ node: PredicateMirrorWalker.Node,
        entity: String,
        ordering: [String] = []
    ) throws -> CompiledPredicate {
        let ir = try PredicateIRBuilder.build(node)
        let key = structuralKey(ir, entity: entity, ordering: ordering)
        if let cached = cache.value(for: key) {
            var arguments: [StoredValue] = []
            _ = try render(ir, arguments: &arguments)
            return CompiledPredicate(sql: cached.sql, arguments: arguments, cacheKey: key)
        }
        var arguments: [StoredValue] = []
        let sql = try render(ir, arguments: &arguments)
        cache.insert(Plan(sql: sql), for: key)
        return CompiledPredicate(sql: sql, arguments: arguments, cacheKey: key)
    }

    private static func render(_ ir: PredicateIR, arguments: inout [StoredValue]) throws -> String {
        switch ir {
        case let .conjunction(lhs, rhs):
            return "(\(try render(lhs, arguments: &arguments)) AND \(try render(rhs, arguments: &arguments)))"
        case let .disjunction(lhs, rhs):
            return "(\(try render(lhs, arguments: &arguments)) OR \(try render(rhs, arguments: &arguments)))"
        case let .negation(value):
            return "(NOT \(try render(value, arguments: &arguments)))"
        case let .comparison(op, lhs, rhs):
            let lhsSQL = try render(lhs, arguments: &arguments)
            let rhsSQL = try render(rhs, arguments: &arguments)
            let symbol: String
            switch op {
            case .equal: symbol = "="
            case .notEqual: symbol = "!="
            case .lessThan: symbol = "<"
            case .lessThanOrEqual: symbol = "<="
            case .greaterThan: symbol = ">"
            case .greaterThanOrEqual: symbol = ">="
            }
            return "(\(lhsSQL) \(symbol) \(rhsSQL))"
        case let .keyPath(path):
            guard let property = path.last, Self.validIdentifier(property) else {
                throw SwiftDataError.unsupportedPredicate("Invalid key path")
            }
            return "t0.Z\(property.uppercased())"
        case let .value(value):
            arguments.append(value)
            return "?"
        case let .nilCoalesce(lhs, rhs):
            return "COALESCE(\(try render(lhs, arguments: &arguments)), \(try render(rhs, arguments: &arguments)))"
        case .sequenceContains:
            throw SwiftDataError.unsupportedPredicate(
                "SequenceContains SQL compilation requires collection encoding metadata")
        }
    }

    private static func structuralKey(_ ir: PredicateIR, entity: String, ordering: [String]) -> String {
        "\(entity)|\(ordering.joined(separator: ","))|\(structure(ir))"
    }

    private static func structure(_ ir: PredicateIR) -> String {
        switch ir {
        case let .conjunction(lhs, rhs): "and(\(structure(lhs)),\(structure(rhs)))"
        case let .disjunction(lhs, rhs): "or(\(structure(lhs)),\(structure(rhs)))"
        case let .negation(value): "not(\(structure(value)))"
        case let .comparison(op, lhs, rhs): "compare(\(op),\(structure(lhs)),\(structure(rhs)))"
        case let .keyPath(path): "keypath(\(path.joined(separator: ".")))"
        case .value: "value(?)"
        case let .nilCoalesce(lhs, rhs): "coalesce(\(structure(lhs)),\(structure(rhs)))"
        case let .sequenceContains(sequence, element): "contains(\(structure(sequence)),\(structure(element)))"
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
