import Foundation
import OSDCore

package indirect enum PredicateIR: Sendable, Equatable {
    case conjunction(PredicateIR, PredicateIR)
    case disjunction(PredicateIR, PredicateIR)
    case negation(PredicateIR)
    case comparison(ComparisonOperator, PredicateIR, PredicateIR)
    case decimalComparison(ComparisonOperator, PredicateIR, PredicateIR)
    case arithmetic(ArithmeticOperator, PredicateIR, PredicateIR)
    case keyPath([String])
    case relationshipIsPresent([String])
    case value(StoredValue)
    case nilCoalesce(PredicateIR, PredicateIR)
    case conditional(PredicateIR, PredicateIR, PredicateIR)
    case sequenceContains(PredicateIR, PredicateIR)
    case collectionContains(String, String, PredicateIR)
    case collectionAllEqual(String, String, PredicateIR)
    case collectionAllCompare(String, String, ComparisonOperator, PredicateIR)
    case codableCollectionIsEmpty(String)
    case codableCollectionCount(String)
    case relationshipContains(String, PredicateIR)
    case relationshipCount(String)
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
                if referencesDecimal(lhs, attributeTypes: attributeTypes)
                    || referencesDecimal(rhs, attributeTypes: attributeTypes)
                {
                    try validateFlattenedBlobComparison(op, lhs: lhs, rhs: rhs, attributeTypes: attributeTypes)
                    return .decimalComparison(op, lhs, rhs)
                }
                try validateFlattenedBlobComparison(op, lhs: lhs, rhs: rhs, attributeTypes: attributeTypes)
                return .comparison(
                    op, lhs, rhs)
            case "Arithmetic":
                let op = try arithmeticOperator(try fieldNode("op", from: fields))
                let lhs = try field("lhs", from: fields, attributeTypes: attributeTypes)
                let rhs = try field("rhs", from: fields, attributeTypes: attributeTypes)
                guard isIntegerArithmeticOperand(lhs, attributeTypes: attributeTypes),
                    isIntegerArithmeticOperand(rhs, attributeTypes: attributeTypes)
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Arithmetic currently supports signed integer operands only.")
                }
                return .arithmetic(op, lhs, rhs)
            case "IntDivision":
                let lhs = try field("lhs", from: fields, attributeTypes: attributeTypes)
                let rhs = try field("rhs", from: fields, attributeTypes: attributeTypes)
                guard isIntegerArithmeticOperand(lhs, attributeTypes: attributeTypes),
                    isIntegerArithmeticOperand(rhs, attributeTypes: attributeTypes)
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Integer division requires signed integer operands.")
                }
                return .arithmetic(.divide, lhs, rhs)
            case "IntRemainder":
                let lhs = try field("lhs", from: fields, attributeTypes: attributeTypes)
                let rhs = try field("rhs", from: fields, attributeTypes: attributeTypes)
                guard isIntegerArithmeticOperand(lhs, attributeTypes: attributeTypes),
                    isIntegerArithmeticOperand(rhs, attributeTypes: attributeTypes)
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Integer remainder requires signed integer operands.")
                }
                return .arithmetic(.remainder, lhs, rhs)
            case "Equal":
                let lhs = try field("lhs", from: fields, attributeTypes: attributeTypes)
                let rhs = try field("rhs", from: fields, attributeTypes: attributeTypes)
                try validateFlattenedBlobComparison(.equal, lhs: lhs, rhs: rhs, attributeTypes: attributeTypes)
                if referencesDecimal(lhs, attributeTypes: attributeTypes)
                    || referencesDecimal(rhs, attributeTypes: attributeTypes)
                {
                    return .decimalComparison(.equal, lhs, rhs)
                }
                return .comparison(.equal, lhs, rhs)
            case "NotEqual":
                let lhs = try field("lhs", from: fields, attributeTypes: attributeTypes)
                let rhs = try field("rhs", from: fields, attributeTypes: attributeTypes)
                try validateFlattenedBlobComparison(.notEqual, lhs: lhs, rhs: rhs, attributeTypes: attributeTypes)
                if referencesDecimal(lhs, attributeTypes: attributeTypes)
                    || referencesDecimal(rhs, attributeTypes: attributeTypes)
                {
                    return .decimalComparison(.notEqual, lhs, rhs)
                }
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
                let wrapped = try field("wrapped", from: fields, attributeTypes: attributeTypes)
                let transform = try field("transform", from: fields, attributeTypes: attributeTypes)
                if case let .keyPath(path) = wrapped, path.count == 1,
                    let collectionElement = scalarCollectionElementType(attributeTypes[path[0]]),
                    case let .collectionContains(name, elementType, element) = transform,
                    name == path[0], elementType == collectionElement
                {
                    return .collectionContains(name, elementType, element)
                }
                guard case let .keyPath(relationshipPath) = wrapped, !relationshipPath.isEmpty
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Optional predicates require a supported to-one relationship or Codable collection path.")
                }
                let prefixedTransform = try prefixRelationshipPath(
                    transform,
                    relationships: relationshipPath,
                    attributeTypes: attributeTypes)
                if isNegatedRelationshipContains(transform) {
                    return .conjunction(
                        .relationshipIsPresent(relationshipPath),
                        prefixedTransform)
                }
                return prefixedTransform
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
                let sequence = try field("sequence", from: fields, attributeTypes: attributeTypes)
                let element = try field("element", from: fields, attributeTypes: attributeTypes)
                guard case let .keyPath(path) = sequence, path.count == 1,
                    let elementType = scalarCollectionElementType(attributeTypes[path[0]])
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "SequenceContains requires a direct Codable collection of supported scalar values.")
                }
                guard case .value = element else {
                    throw SwiftDataError.unsupportedPredicate(
                        "SequenceContains requires a captured scalar element value.")
                }
                return .collectionContains(path[0], elementType, element)
            case "OSDSequenceContainsWhere":
                guard case let .keyPath(path) = try field("sequence", from: fields, attributeTypes: attributeTypes),
                    !path.isEmpty
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "SequenceContainsWhere requires a relationship collection key path.")
                }
                let relationship = path.joined(separator: ".")
                return .relationshipContains(
                    relationship,
                    try elementPredicate(
                        field("test", from: fields, attributeTypes: attributeTypes), relationship: relationship,
                        attributeTypes: attributeTypes))
            case "OSDSequenceIsEmpty":
                guard
                    case let .keyPath(path) = try field(
                        "sequence", from: fields, attributeTypes: attributeTypes),
                    !path.isEmpty
                else {
                    throw SwiftDataError.unsupportedPredicate("Collection isEmpty requires a relationship path.")
                }
                let relationship = path.flatMap { $0.split(separator: ".").map(String.init) }
                guard let collection = relationship.last else {
                    throw SwiftDataError.unsupportedPredicate("Collection isEmpty requires a relationship path.")
                }
                guard attributeTypes[relationship.joined(separator: ".")] == "OSDToManyRelationship" else {
                    throw SwiftDataError.unsupportedPredicate("Collection isEmpty requires a to-many relationship.")
                }
                let isEmpty = PredicateIR.negation(
                    .relationshipContains(relationship.joined(separator: "."), .value(.int(1))))
                let ownerPath = Array(relationship.dropLast())
                guard !ownerPath.isEmpty else { return isEmpty }
                guard !collection.isEmpty else {
                    throw SwiftDataError.unsupportedPredicate("Collection isEmpty requires a relationship path.")
                }
                return .conjunction(
                    .comparison(.notEqual, .keyPath(ownerPath), .value(.null)),
                    isEmpty)
            case "OSDSequenceCount":
                guard
                    case let .keyPath(path) = try field(
                        "sequence", from: fields, attributeTypes: attributeTypes), !path.isEmpty
                else {
                    throw SwiftDataError.unsupportedPredicate("Collection count requires a relationship path.")
                }
                return .relationshipCount(
                    path.flatMap { $0.split(separator: ".").map(String.init) }
                        .joined(separator: "."))
            case "OSDScalarCollectionAllEqual":
                guard
                    case let .keyPath(path) = try field(
                        "sequence", from: fields, attributeTypes: attributeTypes), path.count == 1,
                    let elementType = scalarCollectionElementType(attributeTypes[path[0]]),
                    case let .value(value) = try field("value", from: fields, attributeTypes: attributeTypes)
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Codable collection allSatisfy requires a direct scalar collection and capture.")
                }
                return .collectionAllEqual(path[0], elementType, .value(value))
            case "OSDScalarCollectionAllLessThan", "OSDScalarCollectionAllLessThanOrEqual",
                "OSDScalarCollectionAllGreaterThan", "OSDScalarCollectionAllGreaterThanOrEqual":
                guard
                    case let .keyPath(path) = try field(
                        "sequence", from: fields, attributeTypes: attributeTypes), path.count == 1,
                    let elementType = scalarCollectionElementType(attributeTypes[path[0]]),
                    ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt64"]
                        .contains(elementType),
                    case let .value(value) = try field("value", from: fields, attributeTypes: attributeTypes)
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Codable collection ordering allSatisfy requires an integer collection and capture.")
                }
                let operation: PredicateIR.ComparisonOperator
                switch name {
                case "OSDScalarCollectionAllLessThan": operation = .lessThan
                case "OSDScalarCollectionAllLessThanOrEqual": operation = .lessThanOrEqual
                case "OSDScalarCollectionAllGreaterThan": operation = .greaterThan
                default: operation = .greaterThanOrEqual
                }
                return .collectionAllCompare(path[0], elementType, operation, .value(value))
            case "OSDCodableCollectionIsEmpty":
                guard
                    case let .keyPath(path) = try field(
                        "collection", from: fields, attributeTypes: attributeTypes), path.count == 1,
                    scalarCollectionElementType(attributeTypes[path[0]]) != nil
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Codable collection isEmpty requires a direct scalar collection attribute.")
                }
                return .codableCollectionIsEmpty(path[0])
            case "OSDCodableCollectionCount":
                guard
                    case let .keyPath(path) = try field(
                        "collection", from: fields, attributeTypes: attributeTypes), path.count == 1,
                    scalarCollectionElementType(attributeTypes[path[0]]) != nil
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Codable collection count requires a direct scalar collection attribute.")
                }
                return .codableCollectionCount(path[0])
            case "OSDSequenceAllSatisfy":
                guard
                    case let .keyPath(path) = try field(
                        "sequence", from: fields, attributeTypes: attributeTypes), !path.isEmpty
                else {
                    throw SwiftDataError.unsupportedPredicate("allSatisfy requires a relationship collection path.")
                }
                let relationship = path.joined(separator: ".")
                let body = try elementPredicate(
                    field("test", from: fields, attributeTypes: attributeTypes),
                    relationship: relationship,
                    attributeTypes: attributeTypes)
                return .negation(.relationshipContains(relationship, .negation(body)))
            default:
                throw SwiftDataError.unsupportedPredicate(name)
            }
        }
    }

    private static func prefixRelationshipPath(
        _ ir: PredicateIR,
        relationships: [String],
        attributeTypes: [String: String]
    ) throws -> PredicateIR {
        let normalizedRelationships = relationships.flatMap { $0.split(separator: ".").map(String.init) }
        switch ir {
        case let .keyPath(path):
            guard !path.isEmpty else {
                throw SwiftDataError.unsupportedPredicate(
                    "Optional relationship predicates require a destination property path.")
            }
            let expandedPath = path.flatMap { $0.split(separator: ".").map(String.init) }
            let normalizedPath =
                expandedPath.starts(with: normalizedRelationships)
                ? Array(expandedPath.dropFirst(normalizedRelationships.count)) : expandedPath
            let fullPath = normalizedRelationships + normalizedPath
            let fullName = fullPath.joined(separator: ".")
            if attributeTypes[fullName] == "OSDToOneRelationship" {
                return .keyPath(fullPath)
            }
            guard isSupportedElementScalar(attributeTypes[fullName]) else {
                throw SwiftDataError.unsupportedPredicate(
                    "Optional relationship predicates must end in a persisted scalar property.")
            }
            return .keyPath(fullPath)
        case let .relationshipIsPresent(path):
            let relationshipParts = path.flatMap { $0.split(separator: ".").map(String.init) }
            let fullPath =
                relationshipParts.starts(with: normalizedRelationships)
                ? relationshipParts
                : normalizedRelationships + relationshipParts
            return .relationshipIsPresent(fullPath)
        case let .value(value):
            return .value(value)
        case let .comparison(op, lhs, rhs), let .decimalComparison(op, lhs, rhs):
            let prefixedLHS = try prefixRelationshipPath(
                lhs, relationships: relationships, attributeTypes: attributeTypes)
            let prefixedRHS = try prefixRelationshipPath(
                rhs, relationships: relationships, attributeTypes: attributeTypes)
            if case .decimalComparison = ir { return .decimalComparison(op, prefixedLHS, prefixedRHS) }
            return .comparison(op, prefixedLHS, prefixedRHS)
        case let .arithmetic(op, lhs, rhs):
            return .arithmetic(
                op,
                try prefixRelationshipPath(lhs, relationships: relationships, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationships: relationships, attributeTypes: attributeTypes))
        case let .nilCoalesce(lhs, rhs):
            return .nilCoalesce(
                try prefixRelationshipPath(lhs, relationships: relationships, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationships: relationships, attributeTypes: attributeTypes))
        case let .conditional(test, trueBranch, falseBranch):
            return .conditional(
                try prefixRelationshipPath(test, relationships: relationships, attributeTypes: attributeTypes),
                try prefixRelationshipPath(trueBranch, relationships: relationships, attributeTypes: attributeTypes),
                try prefixRelationshipPath(falseBranch, relationships: relationships, attributeTypes: attributeTypes))
        case let .localizedStandardContains(lhs, rhs):
            return .localizedStandardContains(
                try prefixRelationshipPath(lhs, relationships: relationships, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationships: relationships, attributeTypes: attributeTypes))
        case let .stringContains(lhs, rhs):
            return .stringContains(
                try prefixRelationshipPath(lhs, relationships: relationships, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationships: relationships, attributeTypes: attributeTypes))
        case let .stringStartsWith(lhs, rhs):
            return .stringStartsWith(
                try prefixRelationshipPath(lhs, relationships: relationships, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationships: relationships, attributeTypes: attributeTypes))
        case let .conjunction(lhs, rhs):
            return .conjunction(
                try prefixRelationshipPath(lhs, relationships: relationships, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationships: relationships, attributeTypes: attributeTypes))
        case let .disjunction(lhs, rhs):
            return .disjunction(
                try prefixRelationshipPath(lhs, relationships: relationships, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationships: relationships, attributeTypes: attributeTypes))
        case let .negation(value):
            return .negation(
                try prefixRelationshipPath(value, relationships: relationships, attributeTypes: attributeTypes))
        case let .relationshipContains(name, body):
            let relationshipParts = name.split(separator: ".").map(String.init)
            let fullName =
                relationshipParts.starts(with: normalizedRelationships)
                ? name
                : (normalizedRelationships + relationshipParts).joined(separator: ".")
            return .relationshipContains(fullName, body)
        case let .collectionContains(name, elementType, element):
            guard relationships.isEmpty else {
                throw SwiftDataError.unsupportedPredicate(
                    "Scalar collection membership inside relationship predicates is unsupported.")
            }
            return .collectionContains(name, elementType, element)
        case let .collectionAllEqual(name, elementType, element):
            guard relationships.isEmpty else {
                throw SwiftDataError.unsupportedPredicate(
                    "Scalar collection allSatisfy inside relationship predicates is unsupported.")
            }
            return .collectionAllEqual(name, elementType, element)
        case let .collectionAllCompare(name, elementType, operation, element):
            guard relationships.isEmpty else {
                throw SwiftDataError.unsupportedPredicate(
                    "Scalar collection ordering allSatisfy inside relationship predicates is unsupported.")
            }
            return .collectionAllCompare(name, elementType, operation, element)
        case let .codableCollectionIsEmpty(name):
            return .codableCollectionIsEmpty(name)
        case let .codableCollectionCount(name):
            return .codableCollectionCount(name)
        case let .relationshipCount(name):
            let relationshipParts = name.split(separator: ".").map(String.init)
            let fullName =
                relationshipParts.starts(with: normalizedRelationships)
                ? name
                : (normalizedRelationships + relationshipParts).joined(separator: ".")
            return .relationshipCount(fullName)
        case .sequenceContains:
            throw SwiftDataError.unsupportedPredicate("Nested relationship predicates are unsupported.")
        }
    }

    private static func isNegatedRelationshipContains(_ ir: PredicateIR) -> Bool {
        guard case let .negation(value) = ir, case .relationshipContains = value else { return false }
        return true
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

    private static func referencesDecimal(_ ir: PredicateIR, attributeTypes: [String: String]) -> Bool {
        switch ir {
        case let .keyPath(path):
            guard let type = attributeTypes[path.joined(separator: ".")] else { return false }
            let unwrapped = type.hasSuffix("?") ? String(type.dropLast()) : type
            return unwrapped == "Decimal" || unwrapped == "Foundation.Decimal"
        case let .comparison(_, lhs, rhs), let .decimalComparison(_, lhs, rhs), let .arithmetic(_, lhs, rhs),
            let .nilCoalesce(lhs, rhs),
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
        case let .collectionContains(_, _, element):
            return referencesDecimal(element, attributeTypes: attributeTypes)
        case let .collectionAllEqual(_, _, element):
            return referencesDecimal(element, attributeTypes: attributeTypes)
        case let .collectionAllCompare(_, _, _, element):
            return referencesDecimal(element, attributeTypes: attributeTypes)
        case .codableCollectionIsEmpty:
            return false
        case .codableCollectionCount:
            return false
        case .sequenceContains, .relationshipIsPresent, .relationshipCount, .value:
            return false
        }
    }

    private static func elementPredicate(
        _ ir: PredicateIR,
        relationship: String,
        attributeTypes: [String: String],
        depth: Int = 0
    ) throws -> PredicateIR {
        switch ir {
        case let .keyPath(path):
            guard path.count == 1 else {
                throw SwiftDataError.unsupportedPredicate(
                    "Collection predicate bodies support direct scalar properties of the related model.")
            }
            let propertyPath = path[0]
            let localPath: String
            if propertyPath.hasPrefix("\(relationship)[].") {
                localPath = String(propertyPath.dropFirst(relationship.count + 3))
            } else if let finalScope = relationship.split(separator: ".").last.map(String.init),
                propertyPath.hasPrefix("\(finalScope)[].")
            {
                localPath = String(propertyPath.dropFirst(finalScope.count + 3))
            } else if !propertyPath.contains("."),
                isSupportedElementScalar(attributeTypes["\(relationship)[].\(propertyPath)"])
                    || isSupportedElementScalar(attributeTypes[propertyPath])
            {
                localPath = propertyPath
            } else {
                throw SwiftDataError.unsupportedPredicate(
                    "Collection predicate bodies support direct scalar properties of the related model.")
            }
            let typeName = attributeTypes[path[0]] ?? attributeTypes["\(relationship)[].\(path[0])"]
            guard isSupportedElementScalar(typeName) else {
                throw SwiftDataError.unsupportedPredicate(
                    "Collection predicate bodies require direct persisted scalar attributes.")
            }
            return .keyPath([localPath])
        case let .relationshipIsPresent(path):
            let nestedParts = path.flatMap { $0.split(separator: ".").map(String.init) }
            let fullPath =
                nestedParts.starts(with: [relationship]) ? nestedParts : [relationship] + nestedParts
            return .relationshipIsPresent(fullPath)
        case let .value(value):
            return .value(value)
        case let .comparison(op, lhs, rhs), let .decimalComparison(op, lhs, rhs):
            let normalizedLHS = try elementPredicate(
                lhs, relationship: relationship, attributeTypes: attributeTypes, depth: depth)
            let normalizedRHS = try elementPredicate(
                rhs, relationship: relationship, attributeTypes: attributeTypes, depth: depth)
            if case .decimalComparison = ir {
                return .decimalComparison(op, normalizedLHS, normalizedRHS)
            }
            return .comparison(
                op,
                normalizedLHS,
                normalizedRHS)
        case let .relationshipContains(name, body):
            let prefix = "\(relationship)[]."
            let localName: String
            let nextRelationship: String
            if name.hasPrefix(prefix),
                let nextPart = String(name.dropFirst(prefix.count)).split(separator: ".").first
            {
                localName = nextPart.hasSuffix("[]") ? String(nextPart.dropLast(2)) : String(nextPart)
                nextRelationship = "\(relationship)[].\(localName)"
            } else if !name.contains("."), !name.contains("[]") {
                localName = name
                nextRelationship = "\(relationship)[].\(localName)"
            } else {
                throw SwiftDataError.unsupportedPredicate(
                    "Nested collection relationship '\(name)' is not direct from '\(relationship)'.")
            }
            guard depth < 2 else {
                throw SwiftDataError.unsupportedPredicate("Nested collection predicates support at most three levels.")
            }
            return .relationshipContains(
                localName,
                try elementPredicate(
                    body, relationship: nextRelationship, attributeTypes: attributeTypes, depth: depth + 1))
        case let .conjunction(lhs, rhs):
            return .conjunction(
                try elementPredicate(lhs, relationship: relationship, attributeTypes: attributeTypes, depth: depth),
                try elementPredicate(rhs, relationship: relationship, attributeTypes: attributeTypes, depth: depth))
        case let .disjunction(lhs, rhs):
            return .disjunction(
                try elementPredicate(lhs, relationship: relationship, attributeTypes: attributeTypes, depth: depth),
                try elementPredicate(rhs, relationship: relationship, attributeTypes: attributeTypes, depth: depth))
        case let .negation(value):
            return .negation(
                try elementPredicate(value, relationship: relationship, attributeTypes: attributeTypes, depth: depth))
        case let .localizedStandardContains(lhs, rhs):
            try validateElementStringOperand(lhs, relationship: relationship, attributeTypes: attributeTypes)
            return .localizedStandardContains(
                try elementPredicate(lhs, relationship: relationship, attributeTypes: attributeTypes, depth: depth),
                try elementPredicate(rhs, relationship: relationship, attributeTypes: attributeTypes, depth: depth))
        case let .stringContains(lhs, rhs):
            try validateElementStringOperand(lhs, relationship: relationship, attributeTypes: attributeTypes)
            return .stringContains(
                try elementPredicate(lhs, relationship: relationship, attributeTypes: attributeTypes, depth: depth),
                try elementPredicate(rhs, relationship: relationship, attributeTypes: attributeTypes, depth: depth))
        case let .stringStartsWith(lhs, rhs):
            try validateElementStringOperand(lhs, relationship: relationship, attributeTypes: attributeTypes)
            return .stringStartsWith(
                try elementPredicate(lhs, relationship: relationship, attributeTypes: attributeTypes, depth: depth),
                try elementPredicate(rhs, relationship: relationship, attributeTypes: attributeTypes, depth: depth))
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
        let propertyPath = path[0]
        let scopedType =
            attributeTypes[propertyPath]
            ?? attributeTypes["\(relationship)[].\(propertyPath)"]
            ?? relationship.split(separator: ".").last.map(String.init).flatMap {
                attributeTypes["\($0)[].\(propertyPath)"]
            }
        let isScopedElementPath =
            propertyPath.hasPrefix("\(relationship)[].")
            && !propertyPath.dropFirst(relationship.count + 3).contains(".")
            && !propertyPath.dropFirst(relationship.count + 3).contains("[]")
        guard (!propertyPath.contains(".") || isScopedElementPath), isStringAttribute(scopedType) else {
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

    private static func isIntegerArithmeticOperand(
        _ ir: PredicateIR,
        attributeTypes: [String: String]
    ) -> Bool {
        switch ir {
        case let .keyPath(path):
            guard !path.isEmpty else { return false }
            let typeName =
                attributeTypes[path.joined(separator: ".")]
                ?? attributeTypes[path.last ?? ""]
                ?? attributeTypes.first(where: { $0.key.hasSuffix(".\(path.last ?? "")") })?.value
            let unwrapped = typeName.map { $0.hasSuffix("?") ? String($0.dropLast()) : $0 }
            return [
                "Int", "Swift.Int", "Int8", "Swift.Int8", "Int16", "Swift.Int16", "Int32", "Swift.Int32",
                "Int64", "Swift.Int64",
            ].contains(unwrapped ?? "")
        case .value(.int):
            return true
        case let .arithmetic(_, lhs, rhs):
            return isIntegerArithmeticOperand(lhs, attributeTypes: attributeTypes)
                && isIntegerArithmeticOperand(rhs, attributeTypes: attributeTypes)
        case let .nilCoalesce(lhs, rhs):
            return isIntegerArithmeticOperand(lhs, attributeTypes: attributeTypes)
                && isIntegerArithmeticOperand(rhs, attributeTypes: attributeTypes)
        default:
            return false
        }
    }

    private static func scalarCollectionElementType(_ typeName: String?) -> String? {
        guard let typeName,
            let opening = typeName.firstIndex(of: "<"), typeName.last == ">"
        else { return nil }
        let collectionName = typeName[..<opening].split(separator: ".").last.map(String.init) ?? ""
        guard collectionName == "Array" || collectionName == "Set" else { return nil }
        let rawElement = String(typeName[typeName.index(after: opening)..<typeName.index(before: typeName.endIndex)])
        let element = rawElement.split(separator: ".").last.map(String.init) ?? rawElement
        guard
            [
                "String", "Bool", "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16",
                "UInt32", "UInt64",
            ].contains(element)
        else { return nil }
        return element
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
        case "OSDSequenceAllSatisfy": ["sequence", "test"]
        case "OSDScalarCollectionAllEqual": ["sequence", "value"]
        case "OSDScalarCollectionAllLessThan", "OSDScalarCollectionAllLessThanOrEqual",
            "OSDScalarCollectionAllGreaterThan", "OSDScalarCollectionAllGreaterThanOrEqual":
            ["sequence", "value"]
        case "OSDSequenceIsEmpty": ["sequence"]
        case "OSDSequenceCount": ["sequence"]
        case "OSDCodableCollectionIsEmpty": ["collection"]
        case "OSDCodableCollectionCount": ["collection"]
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
