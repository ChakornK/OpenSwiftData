import Foundation
import OSDCore

package indirect enum PredicateIR: Sendable, Equatable {
    case conjunction(PredicateIR, PredicateIR)
    case disjunction(PredicateIR, PredicateIR)
    case negation(PredicateIR)
    case comparison(ComparisonOperator, PredicateIR, PredicateIR)
    case keyPath([String])
    case value(StoredValue)
    case nilCoalesce(PredicateIR, PredicateIR)
    case sequenceContains(PredicateIR, PredicateIR)

    package enum ComparisonOperator: Sendable, Equatable {
        case equal
        case notEqual
        case lessThan
        case lessThanOrEqual
        case greaterThan
        case greaterThanOrEqual
    }
}

package enum PredicateIRBuilder {
    package static func build(_ node: PredicateMirrorWalker.Node) throws -> PredicateIR {
        switch node {
        case let .capture(typeName, description):
            if typeName.hasPrefix("Swift.KeyPath<") {
                return .keyPath(try keyPath(description))
            }
            return try capturedValue(typeName: typeName, description: description)
        case let .expression(name, children):
            let fields = Dictionary(uniqueKeysWithValues: children)
            switch name {
            case "Conjunction":
                return .conjunction(try field("lhs", from: fields), try field("rhs", from: fields))
            case "Disjunction":
                return .disjunction(try field("lhs", from: fields), try field("rhs", from: fields))
            case "Negation":
                return .negation(try field("expression", from: fields))
            case "Comparison":
                guard let operatorNode = fields["op"] else {
                    throw PredicateCatalogError.malformedNode("Comparison", missingChildren: ["op"])
                }
                return .comparison(
                    try comparisonOperator(operatorNode),
                    try field("lhs", from: fields),
                    try field("rhs", from: fields))
            case "Equal":
                return .comparison(.equal, try field("lhs", from: fields), try field("rhs", from: fields))
            case "KeyPath":
                guard let field = fields["keyPath"] else {
                    throw SwiftDataError.unsupportedPredicate("KeyPath")
                }
                if case let .capture("Swift.KeyPath", description) = field {
                    return .keyPath(try keyPath(description))
                }
                return try build(field)
            case "Swift.KeyPath":
                throw SwiftDataError.unsupportedPredicate("Swift.KeyPath must be captured as a leaf")
            case "Value":
                return try field("value", from: fields)
            case "NilCoalesce":
                return .nilCoalesce(try field("lhs", from: fields), try field("rhs", from: fields))
            case "SequenceContains":
                return .sequenceContains(try field("sequence", from: fields), try field("element", from: fields))
            default:
                throw SwiftDataError.unsupportedPredicate(name)
            }
        }
    }

    private static func field(_ name: String, from fields: [String: PredicateMirrorWalker.Node]) throws -> PredicateIR {
        guard let node = fields[name] else {
            throw PredicateCatalogError.malformedNode("PredicateIR", missingChildren: [name])
        }
        return try build(node)
    }

    private static func capturedValue(typeName: String, description: String) throws -> PredicateIR {
        switch typeName {
        case "Swift.String":
            return .value(.text(description))
        case "Swift.Bool":
            guard let value = Bool(description) else { throw SwiftDataError.unsupportedPredicate(typeName) }
            return .value(.int(value ? 1 : 0))
        case "Swift.Int", "Swift.Int8", "Swift.Int16", "Swift.Int32", "Swift.Int64":
            guard let value = Int64(description) else { throw SwiftDataError.unsupportedPredicate(typeName) }
            return .value(.int(value))
        case "Swift.Double", "Swift.Float":
            guard let value = Double(description) else { throw SwiftDataError.unsupportedPredicate(typeName) }
            return .value(.double(value))
        case "Swift.UInt", "Swift.UInt8", "Swift.UInt16", "Swift.UInt32", "Swift.UInt64":
            guard let value = UInt64(description), value <= UInt64(Int64.max) else {
                throw SwiftDataError.unsupportedPredicate(typeName)
            }
            return .value(.int(Int64(value)))
        default:
            throw SwiftDataError.unsupportedPredicate(typeName)
        }
    }

    private static func comparisonOperator(_ node: PredicateMirrorWalker.Node) throws -> PredicateIR.ComparisonOperator
    {
        guard case let .capture(_, description) = node else {
            throw SwiftDataError.unsupportedPredicate("ComparisonOperator")
        }
        let value = description.split(separator: ".").last.map(String.init) ?? description
        switch value {
        case "equal": return .equal
        case "notEqual": return .notEqual
        case "lessThan": return .lessThan
        case "lessThanOrEqual": return .lessThanOrEqual
        case "greaterThan": return .greaterThan
        case "greaterThanOrEqual": return .greaterThanOrEqual
        default: throw SwiftDataError.unsupportedPredicate("ComparisonOperator.\(value)")
        }
    }

    private static func keyPath(_ description: String) throws -> [String] {
        let components = description.split(separator: ".")
        guard description.first == "\\", let member = components.last,
            member.utf8.allSatisfy({
                ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95
            })
        else {
            throw SwiftDataError.unsupportedPredicate("KeyPath column metadata is unavailable")
        }
        return [String(member)]
    }
}
