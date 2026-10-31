import Foundation
import OSDCore

package indirect enum PredicateIR: Sendable, Equatable {
    case conjunction(PredicateIR, PredicateIR)
    case disjunction(PredicateIR, PredicateIR)
    case negation(PredicateIR)
    case comparison(ComparisonOperator, PredicateIR, PredicateIR)
    case arithmetic(ArithmeticOperator, PredicateIR, PredicateIR)
    case keyPath([String])
    case value(StoredValue)
    case nilCoalesce(PredicateIR, PredicateIR)
    case conditional(PredicateIR, PredicateIR, PredicateIR)
    case sequenceContains(PredicateIR, PredicateIR)
    case relationshipContains(String, PredicateIR)
    case localizedStandardContains(PredicateIR, PredicateIR)
    case stringContains(PredicateIR, PredicateIR)
    case stringStartsWith(PredicateIR, PredicateIR)

    package enum ComparisonOperator: Sendable, Equatable {
        case equal
        case notEqual
        case lessThan
        case lessThanOrEqual
        case greaterThan
        case greaterThanOrEqual
    }

    package enum ArithmeticOperator: Sendable, Equatable {
        case add
        case subtract
        case multiply
        case divide
        case remainder
    }
}

package enum PredicateIRBuilder {
    package static func build(
        _ node: PredicateMirrorWalker.Node,
        attributeTypes: [String: String] = [:]
    ) throws -> PredicateIR {
        switch node {
        case let .propertyReference(name):
            return .keyPath([name])
        case let .typedValue(value):
            return .value(value)
        case let .capture(typeName, description):
            if typeName.hasPrefix("Swift.KeyPath<") {
                return .keyPath(try keyPath(description))
            }
            return try capturedValue(typeName: typeName, description: description)
        case let .expression(name, children):
            guard let expected = expectedFields(for: name) else {
                throw SwiftDataError.unsupportedPredicate(name)
            }
            let fields = try validatedFields(children, nodeName: name, expected: expected)
            switch name {
            case "Conjunction":
                return .conjunction(
                    try field("lhs", from: fields, attributeTypes: attributeTypes),
                    try field("rhs", from: fields, attributeTypes: attributeTypes))
            case "Disjunction":
                return .disjunction(
                    try field("lhs", from: fields, attributeTypes: attributeTypes),
                    try field("rhs", from: fields, attributeTypes: attributeTypes))
            case "Negation":
                return .negation(try field("wrapped", from: fields, attributeTypes: attributeTypes))
            case "Comparison":
                guard let operatorNode = fields["op"] else {
                    throw PredicateCatalogError.malformedNode("Comparison", missingChildren: ["op"])
                }
                let op = try comparisonOperator(operatorNode)
                let lhs = try field("lhs", from: fields, attributeTypes: attributeTypes)
                let rhs = try field("rhs", from: fields, attributeTypes: attributeTypes)
                try validateDecimalOrdering(op, lhs: lhs, rhs: rhs, attributeTypes: attributeTypes)
                try validateFlattenedBlobComparison(op, lhs: lhs, rhs: rhs, attributeTypes: attributeTypes)
                return .comparison(
                    op, lhs, rhs)
            case "Arithmetic":
                let op = try arithmeticOperator(try fieldNode("op", from: fields))
                return .arithmetic(
                    op, try field("lhs", from: fields, attributeTypes: attributeTypes),
                    try field("rhs", from: fields, attributeTypes: attributeTypes))
            case "IntDivision":
                return .arithmetic(
                    .divide, try field("lhs", from: fields, attributeTypes: attributeTypes),
                    try field("rhs", from: fields, attributeTypes: attributeTypes))
            case "IntRemainder":
                return .arithmetic(
                    .remainder, try field("lhs", from: fields, attributeTypes: attributeTypes),
                    try field("rhs", from: fields, attributeTypes: attributeTypes))
            case "Equal":
                let lhs = try field("lhs", from: fields, attributeTypes: attributeTypes)
                let rhs = try field("rhs", from: fields, attributeTypes: attributeTypes)
                try validateFlattenedBlobComparison(.equal, lhs: lhs, rhs: rhs, attributeTypes: attributeTypes)
                return .comparison(.equal, lhs, rhs)
            case "NotEqual":
                let lhs = try field("lhs", from: fields, attributeTypes: attributeTypes)
                let rhs = try field("rhs", from: fields, attributeTypes: attributeTypes)
                try validateFlattenedBlobComparison(.notEqual, lhs: lhs, rhs: rhs, attributeTypes: attributeTypes)
                return .comparison(.notEqual, lhs, rhs)
            case "NilLiteral":
                return .value(.null)
            case "KeyPath":
                guard let field = fields["keyPath"] else {
                    throw SwiftDataError.unsupportedPredicate("KeyPath")
                }
                if case let .capture("Swift.KeyPath", description) = field {
                    return .keyPath(try keyPath(description))
                }
                return try build(field, attributeTypes: attributeTypes)
            case "Swift.KeyPath":
                throw SwiftDataError.unsupportedPredicate("Swift.KeyPath must be captured as a leaf")
            case "Value":
                return try field("value", from: fields, attributeTypes: attributeTypes)
            case "NilCoalesce":
                return .nilCoalesce(
                    try field("lhs", from: fields, attributeTypes: attributeTypes),
                    try field("rhs", from: fields, attributeTypes: attributeTypes))
            case "OptionalFlatMap":
                guard
                    case let .keyPath(relationshipPath) = try field(
                        "wrapped", from: fields, attributeTypes: attributeTypes),
                    relationshipPath.count == 1
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Optional relationship predicates support one direct to-one scalar traversal.")
                }
                return try prefixRelationshipPath(
                    field("transform", from: fields, attributeTypes: attributeTypes),
                    relationship: relationshipPath[0],
                    attributeTypes: attributeTypes)
            case "Conditional":
                return .conditional(
                    try field("test", from: fields, attributeTypes: attributeTypes),
                    try field("trueBranch", from: fields, attributeTypes: attributeTypes),
                    try field("falseBranch", from: fields, attributeTypes: attributeTypes))
            case "StringLocalizedStandardContains", "OSDLocalizedStandardContains":
                let lhs = try field("root", from: fields, attributeTypes: attributeTypes)
                try validateStringOperand(lhs, attributeTypes: attributeTypes)
                return .localizedStandardContains(lhs, try field("other", from: fields, attributeTypes: attributeTypes))
            case "CollectionContainsCollection":
                let base = try field("base", from: fields, attributeTypes: attributeTypes)
                guard case let .keyPath(path) = base, path.count == 1,
                    hasStringType(for: path, attributeTypes: attributeTypes)
                else {
                    throw SwiftDataError.unsupportedPredicate("Only direct persisted string contains is supported")
                }
                return .stringContains(base, try field("other", from: fields, attributeTypes: attributeTypes))
            case "SequenceStartsWith":
                let base = try field("base", from: fields, attributeTypes: attributeTypes)
                guard case let .keyPath(path) = base, path.count == 1,
                    hasStringType(for: path, attributeTypes: attributeTypes)
                else {
                    throw SwiftDataError.unsupportedPredicate("Only direct persisted string prefixes are supported")
                }
                return .stringStartsWith(base, try field("prefix", from: fields, attributeTypes: attributeTypes))
            case "RangeExpressionContains":
                let element = try field("element", from: fields, attributeTypes: attributeTypes)
                guard case let .keyPath(path) = element, path.count == 1,
                    hasIntegerType(for: path, attributeTypes: attributeTypes),
                    case let .expression(rangeName, rangeChildren) = fields["range"]
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Only integer range containment on direct attributes is supported")
                }
                guard rangeName == "ClosedRange" || rangeName == "Range" else {
                    throw SwiftDataError.unsupportedPredicate("Only integer Range and ClosedRange are supported")
                }
                let rangeFields = try validatedFields(rangeChildren, nodeName: rangeName, expected: ["lower", "upper"])
                let lower = try field("lower", from: rangeFields, attributeTypes: attributeTypes)
                let upper = try field("upper", from: rangeFields, attributeTypes: attributeTypes)
                guard case .value(.int) = lower, case .value(.int) = upper else {
                    throw SwiftDataError.unsupportedPredicate("Range bounds must be typed integer captures")
                }
                return .conjunction(
                    .comparison(.greaterThanOrEqual, element, lower),
                    .comparison(
                        rangeName == "ClosedRange" ? .lessThanOrEqual : .lessThan,
                        element,
                        upper))
            case "SequenceContains":
                return .sequenceContains(
                    try field("sequence", from: fields, attributeTypes: attributeTypes),
                    try field("element", from: fields, attributeTypes: attributeTypes))
            case "OSDSequenceContainsWhere":
                guard case let .keyPath(path) = try field("sequence", from: fields, attributeTypes: attributeTypes),
                    path.count == 1,
                    let relationship = path.first, !relationship.isEmpty
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "SequenceContainsWhere requires a direct relationship collection key path.")
                }
                return .relationshipContains(
                    relationship,
                    try elementPredicate(
                        field("test", from: fields, attributeTypes: attributeTypes), relationship: relationship,
                        attributeTypes: attributeTypes))
            default:
                throw SwiftDataError.unsupportedPredicate(name)
            }
        }
    }

    private static func prefixRelationshipPath(
        _ ir: PredicateIR,
        relationship: String,
        attributeTypes: [String: String]
    ) throws -> PredicateIR {
        switch ir {
        case let .keyPath(path):
            guard path.count == 1, let rawProperty = path.first else {
                throw SwiftDataError.unsupportedPredicate(
                    "Optional relationship predicates support one direct scalar destination property.")
            }
            let property =
                rawProperty.hasPrefix("\(relationship).")
                ? String(rawProperty.dropFirst(relationship.count + 1))
                : rawProperty
            guard !property.isEmpty, !property.contains("."),
                isSupportedElementScalar(attributeTypes["\(relationship).\(property)"])
            else {
                throw SwiftDataError.unsupportedPredicate(
                    "Optional relationship predicates support one direct scalar destination property.")
            }
            return .keyPath([relationship, property])
        case let .value(value):
            return .value(value)
        case let .comparison(op, lhs, rhs):
            return .comparison(
                op,
                try prefixRelationshipPath(lhs, relationship: relationship, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationship: relationship, attributeTypes: attributeTypes))
        case let .arithmetic(op, lhs, rhs):
            return .arithmetic(
                op,
                try prefixRelationshipPath(lhs, relationship: relationship, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationship: relationship, attributeTypes: attributeTypes))
        case let .nilCoalesce(lhs, rhs):
            return .nilCoalesce(
                try prefixRelationshipPath(lhs, relationship: relationship, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationship: relationship, attributeTypes: attributeTypes))
        case let .conditional(test, trueBranch, falseBranch):
            return .conditional(
                try prefixRelationshipPath(test, relationship: relationship, attributeTypes: attributeTypes),
                try prefixRelationshipPath(trueBranch, relationship: relationship, attributeTypes: attributeTypes),
                try prefixRelationshipPath(falseBranch, relationship: relationship, attributeTypes: attributeTypes))
        case let .localizedStandardContains(lhs, rhs):
            return .localizedStandardContains(
                try prefixRelationshipPath(lhs, relationship: relationship, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationship: relationship, attributeTypes: attributeTypes))
        case let .stringContains(lhs, rhs):
            return .stringContains(
                try prefixRelationshipPath(lhs, relationship: relationship, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationship: relationship, attributeTypes: attributeTypes))
        case let .stringStartsWith(lhs, rhs):
            return .stringStartsWith(
                try prefixRelationshipPath(lhs, relationship: relationship, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationship: relationship, attributeTypes: attributeTypes))
        case let .conjunction(lhs, rhs):
            return .conjunction(
                try prefixRelationshipPath(lhs, relationship: relationship, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationship: relationship, attributeTypes: attributeTypes))
        case let .disjunction(lhs, rhs):
            return .disjunction(
                try prefixRelationshipPath(lhs, relationship: relationship, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationship: relationship, attributeTypes: attributeTypes))
        case let .negation(value):
            return .negation(
                try prefixRelationshipPath(value, relationship: relationship, attributeTypes: attributeTypes))
        case .sequenceContains, .relationshipContains:
            throw SwiftDataError.unsupportedPredicate("Nested relationship predicates are unsupported.")
        }
    }

    private static func hasStringType(for path: [String], attributeTypes: [String: String]) -> Bool {
        guard !path.isEmpty else { return false }
        if isStringAttribute(attributeTypes[path.joined(separator: ".")]) { return true }
        return path.count == 1
            && attributeTypes.contains { key, type in
                key.hasSuffix(".\(path[0])") && isStringAttribute(type)
            }
    }

    private static func hasIntegerType(for path: [String], attributeTypes: [String: String]) -> Bool {
        guard !path.isEmpty else { return false }
        if isIntegerAttribute(attributeTypes[path.joined(separator: ".")]) { return true }
        return path.count == 1
            && attributeTypes.contains { key, type in
                key.hasSuffix(".\(path[0])") && isIntegerAttribute(type)
            }
    }

    private static func validateFlattenedBlobComparison(
        _ op: PredicateIR.ComparisonOperator,
        lhs: PredicateIR,
        rhs: PredicateIR,
        attributeTypes: [String: String]
    ) throws {
        let blobNames = Set(
            attributeTypes.compactMap { name, type in
                ["Data", "Foundation.Data", "UUID", "Foundation.UUID"].contains(type) ? name : nil
            })
        let referencesBlob: Bool
        switch (lhs, rhs) {
        case let (.keyPath(path), .value), let (.value, .keyPath(path)):
            referencesBlob = path.count == 1 && blobNames.contains(path[0])
        default:
            referencesBlob = false
        }
        if referencesBlob, op != .equal, op != .notEqual {
            throw SwiftDataError.unsupportedPredicate(
                "Ordering comparisons on flattened BLOB components are unsupported")
        }
    }

    private static func validateDecimalOrdering(
        _ op: PredicateIR.ComparisonOperator,
        lhs: PredicateIR,
        rhs: PredicateIR,
        attributeTypes: [String: String]
    ) throws {
        guard op != .equal, op != .notEqual else { return }
        if referencesDecimal(lhs, attributeTypes: attributeTypes)
            || referencesDecimal(rhs, attributeTypes: attributeTypes)
        {
            throw SwiftDataError.unsupportedPredicate(
                "Ordering comparisons on Decimal attributes are unsupported until numeric SQL semantics are available.")
        }
    }

    private static func referencesDecimal(_ ir: PredicateIR, attributeTypes: [String: String]) -> Bool {
        switch ir {
        case let .keyPath(path):
            guard let type = attributeTypes[path.joined(separator: ".")] else { return false }
            let unwrapped = type.hasSuffix("?") ? String(type.dropLast()) : type
            return unwrapped == "Decimal" || unwrapped == "Foundation.Decimal"
        case let .comparison(_, lhs, rhs), let .arithmetic(_, lhs, rhs), let .nilCoalesce(lhs, rhs),
            let .localizedStandardContains(lhs, rhs), let .stringContains(lhs, rhs),
            let .stringStartsWith(lhs, rhs), let .conjunction(lhs, rhs), let .disjunction(lhs, rhs):
            return referencesDecimal(lhs, attributeTypes: attributeTypes)
                || referencesDecimal(rhs, attributeTypes: attributeTypes)
        case let .conditional(test, trueBranch, falseBranch):
            return referencesDecimal(test, attributeTypes: attributeTypes)
                || referencesDecimal(trueBranch, attributeTypes: attributeTypes)
                || referencesDecimal(falseBranch, attributeTypes: attributeTypes)
        case let .negation(value):
            return referencesDecimal(value, attributeTypes: attributeTypes)
        case let .relationshipContains(_, body):
            return referencesDecimal(body, attributeTypes: attributeTypes)
        case .sequenceContains, .value:
            return false
        }
    }

    private static func elementPredicate(
        _ ir: PredicateIR,
        relationship: String,
        attributeTypes: [String: String]
    ) throws -> PredicateIR {
        switch ir {
        case let .keyPath(path):
            guard path.count == 1 else {
                throw SwiftDataError.unsupportedPredicate(
                    "Collection predicate bodies support direct scalar properties of the related model.")
            }
            let elementPath = path[0].components(separatedBy: "[].")
            guard elementPath.count == 2, elementPath[0] == relationship else {
                throw SwiftDataError.unsupportedPredicate(
                    "Collection predicate bodies support direct scalar properties of the related model.")
            }
            let typeName = attributeTypes[path[0]]
            guard isSupportedElementScalar(typeName) else {
                throw SwiftDataError.unsupportedPredicate(
                    "Collection predicate bodies require direct persisted scalar attributes.")
            }
            return .keyPath([elementPath[1]])
        case let .value(value):
            return .value(value)
        case let .comparison(op, lhs, rhs):
            return .comparison(
                op,
                try elementPredicate(lhs, relationship: relationship, attributeTypes: attributeTypes),
                try elementPredicate(rhs, relationship: relationship, attributeTypes: attributeTypes))
        case let .conjunction(lhs, rhs):
            return .conjunction(
                try elementPredicate(lhs, relationship: relationship, attributeTypes: attributeTypes),
                try elementPredicate(rhs, relationship: relationship, attributeTypes: attributeTypes))
        case let .disjunction(lhs, rhs):
            return .disjunction(
                try elementPredicate(lhs, relationship: relationship, attributeTypes: attributeTypes),
                try elementPredicate(rhs, relationship: relationship, attributeTypes: attributeTypes))
        case let .negation(value):
            return .negation(
                try elementPredicate(value, relationship: relationship, attributeTypes: attributeTypes))
        case let .localizedStandardContains(lhs, rhs):
            try validateElementStringOperand(lhs, relationship: relationship, attributeTypes: attributeTypes)
            return .localizedStandardContains(
                try elementPredicate(lhs, relationship: relationship, attributeTypes: attributeTypes),
                try elementPredicate(rhs, relationship: relationship, attributeTypes: attributeTypes))
        case let .stringContains(lhs, rhs):
            try validateElementStringOperand(lhs, relationship: relationship, attributeTypes: attributeTypes)
            return .stringContains(
                try elementPredicate(lhs, relationship: relationship, attributeTypes: attributeTypes),
                try elementPredicate(rhs, relationship: relationship, attributeTypes: attributeTypes))
        case let .stringStartsWith(lhs, rhs):
            try validateElementStringOperand(lhs, relationship: relationship, attributeTypes: attributeTypes)
            return .stringStartsWith(
                try elementPredicate(lhs, relationship: relationship, attributeTypes: attributeTypes),
                try elementPredicate(rhs, relationship: relationship, attributeTypes: attributeTypes))
        default:
            throw SwiftDataError.unsupportedPredicate(
                "Collection predicate bodies support scalar comparisons and boolean combinations only.")
        }
    }

    private static func validateElementStringOperand(
        _ ir: PredicateIR,
        relationship: String,
        attributeTypes: [String: String]
    ) throws {
        guard case let .keyPath(path) = ir, path.count == 1 else {
            throw SwiftDataError.unsupportedPredicate(
                "Collection string predicates require a direct persisted String element property.")
        }
        let components = path[0].components(separatedBy: "[].")
        guard components.count == 2, components[0] == relationship,
            isStringAttribute(attributeTypes[path[0]])
        else {
            throw SwiftDataError.unsupportedPredicate(
                "Collection string predicates require a direct persisted String element property.")
        }
    }

    private static func isSupportedElementScalar(_ typeName: String?) -> Bool {
        guard let typeName, !typeName.contains("["), !typeName.contains("<") else { return false }
        let unwrapped = typeName.hasSuffix("?") ? String(typeName.dropLast()) : typeName
        return [
            "String", "Swift.String", "Bool", "Swift.Bool", "Int", "Swift.Int", "Int8", "Swift.Int8",
            "Int16", "Swift.Int16", "Int32", "Swift.Int32", "Int64", "Swift.Int64", "UInt", "Swift.UInt",
            "UInt8", "Swift.UInt8", "UInt16", "Swift.UInt16", "UInt32", "Swift.UInt32", "UInt64", "Swift.UInt64",
            "Float", "Swift.Float", "Double", "Swift.Double", "Decimal", "Foundation.Decimal", "Date",
            "Foundation.Date", "URL", "Foundation.URL",
        ].contains(unwrapped)
    }

    private static func validateStringOperand(
        _ ir: PredicateIR,
        attributeTypes: [String: String]
    ) throws {
        guard case let .keyPath(path) = ir, path.count == 1, hasStringType(for: path, attributeTypes: attributeTypes)
        else {
            throw SwiftDataError.unsupportedPredicate("String predicate requires a direct persisted String attribute")
        }
    }

    private static func isStringAttribute(_ typeName: String?) -> Bool {
        guard let typeName else { return false }
        let unwrapped = typeName.hasSuffix("?") ? String(typeName.dropLast()) : typeName
        return unwrapped == "String" || unwrapped == "Swift.String"
    }

    private static func isIntegerAttribute(_ typeName: String?) -> Bool {
        guard let typeName else { return false }
        let unwrapped = typeName.hasSuffix("?") ? String(typeName.dropLast()) : typeName
        return [
            "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Swift.Int", "Swift.Int8", "Swift.Int16", "Swift.Int32", "Swift.Int64", "Swift.UInt", "Swift.UInt8",
            "Swift.UInt16", "Swift.UInt32", "Swift.UInt64",
        ].contains(unwrapped)
    }

    private static func expectedFields(for name: String) -> Set<String>? {
        switch name {
        case "Conjunction", "Disjunction", "Equal", "NotEqual", "NilCoalesce": ["lhs", "rhs"]
        case "Conditional": ["test", "trueBranch", "falseBranch"]
        case "Negation": ["wrapped"]
        case "Comparison": ["op", "lhs", "rhs"]
        case "Arithmetic": ["op", "lhs", "rhs"]
        case "IntDivision", "IntRemainder": ["lhs", "rhs"]
        case "KeyPath": ["root", "keyPath"]
        case "Value": ["value"]
        case "OptionalFlatMap": ["wrapped", "transform", "variable"]
        case "StringLocalizedStandardContains", "OSDLocalizedStandardContains": ["root", "other"]
        case "CollectionContainsCollection": ["base", "other"]
        case "SequenceStartsWith": ["base", "prefix"]
        case "SequenceContains": ["sequence", "element"]
        case "OSDSequenceContainsWhere": ["sequence", "test"]
        case "RangeExpressionContains": ["range", "element"]
        case "ClosedRange", "Range": ["lower", "upper"]
        case "NilLiteral": []
        default: nil
        }
    }

    private static func validatedFields(
        _ children: [(String, PredicateMirrorWalker.Node)],
        nodeName: String,
        expected: Set<String>
    ) throws -> [String: PredicateMirrorWalker.Node] {
        var fields: [String: PredicateMirrorWalker.Node] = [:]
        for (label, node) in children {
            guard fields.updateValue(node, forKey: label) == nil else {
                throw SwiftDataError.unsupportedPredicate("Duplicate child label '\(label)' in \(nodeName)")
            }
        }
        let actual = Set(fields.keys)
        guard actual == expected else {
            throw SwiftDataError.unsupportedPredicate(
                "Malformed predicate node \(nodeName): expected \(expected.sorted()), found \(actual.sorted())")
        }
        return fields
    }

    private static func field(
        _ name: String,
        from fields: [String: PredicateMirrorWalker.Node],
        attributeTypes: [String: String]
    ) throws -> PredicateIR {
        guard let node = fields[name] else {
            throw PredicateCatalogError.malformedNode("PredicateIR", missingChildren: [name])
        }
        return try build(node, attributeTypes: attributeTypes)
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

    package static func comparisonOperator(_ node: PredicateMirrorWalker.Node) throws -> PredicateIR.ComparisonOperator
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

    private static func fieldNode(
        _ name: String, from fields: [String: PredicateMirrorWalker.Node]
    ) throws -> PredicateMirrorWalker.Node {
        guard let node = fields[name] else {
            throw PredicateCatalogError.malformedNode("PredicateIR", missingChildren: [name])
        }
        return node
    }

    private static func arithmeticOperator(
        _ node: PredicateMirrorWalker.Node
    ) throws -> PredicateIR.ArithmeticOperator {
        guard case let .capture(_, description) = node else {
            throw SwiftDataError.unsupportedPredicate("ArithmeticOperator")
        }
        let value = description.split(separator: ".").last.map(String.init) ?? description
        switch value {
        case "add": return .add
        case "subtract": return .subtract
        case "multiply": return .multiply
        case "divide": return .divide
        case "remainder": return .remainder
        default: throw SwiftDataError.unsupportedPredicate("ArithmeticOperator.\(value)")
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
