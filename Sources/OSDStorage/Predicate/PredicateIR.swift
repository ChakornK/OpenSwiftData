import Foundation
import OSDCore

package indirect enum PredicateIR: Sendable, Equatable {
    case conjunction(PredicateIR, PredicateIR)
    case disjunction(PredicateIR, PredicateIR)
    case negation(PredicateIR)
    case comparison(ComparisonOperator, PredicateIR, PredicateIR)
    case decimalComparison(ComparisonOperator, PredicateIR, PredicateIR)
    case optionalComparison(ComparisonOperator, PredicateIR, PredicateIR, decimal: Bool)
    case arithmetic(ArithmeticOperator, PredicateIR, PredicateIR)
    case boundedArithmetic(ArithmeticOperator, PredicateIR, PredicateIR, PredicateIntegerWidth)
    case realArithmetic(ArithmeticOperator, PredicateIR, PredicateIR)
    case unaryNegation(PredicateIR, integerWidth: PredicateIntegerWidth?)
    case floatArithmetic(ArithmeticOperator, PredicateIR, PredicateIR)
    case floatNegation(PredicateIR)
    case keyPath([String])
    case persistentIdentifier([String])
    case identifierValue(PersistentIdentifier)
    case persistentIdentifierComparison(ComparisonOperator, PersistentIdentifier, [String])
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
        attributeTypes: [String: String] = [:],
        optionalAttributeNames: Set<String> = []
    ) throws -> PredicateIR {
        func field(_ name: String, from fields: [String: PredicateMirrorWalker.Node]) throws -> PredicateIR {
            guard let node = fields[name] else {
                throw PredicateCatalogError.malformedNode("PredicateIR", missingChildren: [name])
            }
            return try build(
                node,
                attributeTypes: attributeTypes,
                optionalAttributeNames: optionalAttributeNames)
        }
        switch node {
        case let .propertyReference(name):
            if let path = persistentIdentifierPath(name) {
                return .persistentIdentifier(path)
            }
            return .keyPath([name])
        case let .persistentIdentifierReference(path):
            return .persistentIdentifier(path)
        case let .identifierCapture(identifier):
            return .identifierValue(identifier)
        case let .typedValue(value):
            return .value(value)
        case let .typedCapture(value, typeName):
            if typeName == "Swift.Float", case let .double(number) = value {
                guard number.isFinite else { throw SwiftDataError.unsupportedPredicate(typeName) }
                let rounded = Float(number)
                guard rounded.isFinite else { throw SwiftDataError.unsupportedPredicate(typeName) }
                return .value(.double(Double(rounded)))
            }
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
                    try field("lhs", from: fields),
                    try field("rhs", from: fields))
            case "Disjunction":
                return .disjunction(
                    try field("lhs", from: fields),
                    try field("rhs", from: fields))
            case "Negation":
                return .negation(try field("wrapped", from: fields))
            case "UnaryMinus":
                let operand = try field("wrapped", from: fields)
                if let width = try integerArithmeticWidth(
                    for: fields["wrapped"]!, and: nil, attributeTypes: attributeTypes)
                {
                    guard width.isSigned else {
                        throw SwiftDataError.unsupportedPredicate("Unary minus is unsupported for unsigned integers.")
                    }
                    return .unaryNegation(operand, integerWidth: width)
                }
                if isFloatArithmeticOperand(fields["wrapped"]!, attributeTypes: attributeTypes) {
                    return .floatNegation(operand)
                }
                guard isDoubleArithmeticOperand(operand, attributeTypes: attributeTypes) else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Unary minus requires a signed integer or Double operand.")
                }
                return .unaryNegation(operand, integerWidth: nil)
            case "Comparison":
                guard let operatorNode = fields["op"] else {
                    throw PredicateCatalogError.malformedNode("Comparison", missingChildren: ["op"])
                }
                let op = try comparisonOperator(operatorNode)
                let lhs = try field("lhs", from: fields)
                let rhs = try field("rhs", from: fields)
                if let capture = persistentIdentifierCapture(lhs, comparedTo: rhs) {
                    return try persistentIdentifierComparison(
                        op, capture.identifier, path: capture.path, attributeTypes: attributeTypes)
                }
                if let capture = persistentIdentifierCapture(rhs, comparedTo: lhs) {
                    return try persistentIdentifierComparison(
                        op, capture.identifier, path: capture.path, attributeTypes: attributeTypes)
                }
                return try comparisonIR(
                    op,
                    lhs,
                    rhs,
                    attributeTypes: attributeTypes,
                    optionalAttributeNames: optionalAttributeNames)
            case "Arithmetic":
                let op = try arithmeticOperator(try fieldNode("op", from: fields))
                let lhs = try field("lhs", from: fields)
                let rhs = try field("rhs", from: fields)
                let integerWidth: PredicateIntegerWidth?
                do {
                    integerWidth = try integerArithmeticWidth(
                        for: fields["lhs"]!, and: fields["rhs"]!, attributeTypes: attributeTypes)
                } catch {
                    if op != .remainder,
                        isFloatArithmeticOperand(fields["lhs"]!, attributeTypes: attributeTypes),
                        isFloatArithmeticOperand(fields["rhs"]!, attributeTypes: attributeTypes)
                    {
                        return .floatArithmetic(op, lhs, rhs)
                    }
                    if op != .remainder,
                        isDoubleArithmeticOperand(lhs, attributeTypes: attributeTypes),
                        isDoubleArithmeticOperand(rhs, attributeTypes: attributeTypes)
                    {
                        return .realArithmetic(op, lhs, rhs)
                    }
                    throw error
                }
                if let width = integerWidth {
                    return .boundedArithmetic(op, lhs, rhs, width)
                }
                if case .value(.int) = lhs, case .value(.int) = rhs {
                    return .boundedArithmetic(op, lhs, rhs, .int64)
                }
                if op != .remainder,
                    isFloatArithmeticOperand(fields["lhs"]!, attributeTypes: attributeTypes),
                    isFloatArithmeticOperand(fields["rhs"]!, attributeTypes: attributeTypes)
                {
                    return .floatArithmetic(op, lhs, rhs)
                }
                guard op != .remainder,
                    isDoubleArithmeticOperand(lhs, attributeTypes: attributeTypes),
                    isDoubleArithmeticOperand(rhs, attributeTypes: attributeTypes)
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Arithmetic requires matching supported integer widths or two Double operands.")
                }
                return .realArithmetic(op, lhs, rhs)
            case "FloatDivision":
                let lhs = try field("lhs", from: fields)
                let rhs = try field("rhs", from: fields)
                if isFloatArithmeticOperand(fields["lhs"]!, attributeTypes: attributeTypes),
                    isFloatArithmeticOperand(fields["rhs"]!, attributeTypes: attributeTypes)
                {
                    return .floatArithmetic(.divide, lhs, rhs)
                }
                guard isDoubleArithmeticOperand(lhs, attributeTypes: attributeTypes),
                    isDoubleArithmeticOperand(rhs, attributeTypes: attributeTypes)
                else {
                    throw SwiftDataError.unsupportedPredicate("Floating-point division requires Double operands.")
                }
                return .realArithmetic(.divide, lhs, rhs)
            case "IntDivision":
                let lhs = try field("lhs", from: fields)
                let rhs = try field("rhs", from: fields)
                let width =
                    try integerArithmeticWidth(
                        for: fields["lhs"]!, and: fields["rhs"]!, attributeTypes: attributeTypes)
                guard let width else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Integer division requires matching supported integer operands.")
                }
                return .boundedArithmetic(.divide, lhs, rhs, width)
            case "IntRemainder":
                let lhs = try field("lhs", from: fields)
                let rhs = try field("rhs", from: fields)
                let width =
                    try integerArithmeticWidth(
                        for: fields["lhs"]!, and: fields["rhs"]!, attributeTypes: attributeTypes)
                guard let width else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Integer remainder requires matching supported integer operands.")
                }
                return .boundedArithmetic(.remainder, lhs, rhs, width)
            case "Equal":
                let lhs = try field("lhs", from: fields)
                let rhs = try field("rhs", from: fields)
                if let capture = persistentIdentifierCapture(lhs, comparedTo: rhs) {
                    return try persistentIdentifierComparison(
                        .equal, capture.identifier, path: capture.path, attributeTypes: attributeTypes)
                }
                if let capture = persistentIdentifierCapture(rhs, comparedTo: lhs) {
                    return try persistentIdentifierComparison(
                        .equal, capture.identifier, path: capture.path, attributeTypes: attributeTypes)
                }
                return try comparisonIR(
                    .equal,
                    lhs,
                    rhs,
                    attributeTypes: attributeTypes,
                    optionalAttributeNames: optionalAttributeNames)
            case "NotEqual":
                let lhs = try field("lhs", from: fields)
                let rhs = try field("rhs", from: fields)
                if let capture = persistentIdentifierCapture(lhs, comparedTo: rhs) {
                    return try persistentIdentifierComparison(
                        .notEqual, capture.identifier, path: capture.path, attributeTypes: attributeTypes)
                }
                if let capture = persistentIdentifierCapture(rhs, comparedTo: lhs) {
                    return try persistentIdentifierComparison(
                        .notEqual, capture.identifier, path: capture.path, attributeTypes: attributeTypes)
                }
                return try comparisonIR(
                    .notEqual,
                    lhs,
                    rhs,
                    attributeTypes: attributeTypes,
                    optionalAttributeNames: optionalAttributeNames)
            case "NilLiteral":
                return .value(.null)
            case "KeyPath":
                guard let field = fields["keyPath"] else {
                    throw SwiftDataError.unsupportedPredicate("KeyPath")
                }
                if case let .capture("Swift.KeyPath", description) = field {
                    return .keyPath(try keyPath(description))
                }
                return try build(
                    field,
                    attributeTypes: attributeTypes,
                    optionalAttributeNames: optionalAttributeNames)
            case "Swift.KeyPath":
                throw SwiftDataError.unsupportedPredicate("Swift.KeyPath must be captured as a leaf")
            case "Value":
                return try field("value", from: fields)
            case "NilCoalesce":
                return .nilCoalesce(
                    try field("lhs", from: fields),
                    try field("rhs", from: fields))
            case "OptionalFlatMap":
                let wrapped = try field("wrapped", from: fields)
                let transform = try field("transform", from: fields)
                if case let .keyPath(path) = wrapped, path.count == 1,
                    let collectionElement = scalarCollectionElement(attributeTypes[path[0]]),
                    !collectionElement.isOptional,
                    case let .collectionContains(name, elementType, element) = transform,
                    name == path[0], elementType == collectionElement.type
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
                    try field("test", from: fields),
                    try field("trueBranch", from: fields),
                    try field("falseBranch", from: fields))
            case "StringLocalizedStandardContains", "OSDLocalizedStandardContains":
                let lhs = try field("root", from: fields)
                try validateStringOperand(lhs, attributeTypes: attributeTypes)
                return .localizedStandardContains(lhs, try field("other", from: fields))
            case "CollectionContainsCollection":
                let base = try field("base", from: fields)
                guard case let .keyPath(path) = base, path.count == 1,
                    hasStringType(for: path, attributeTypes: attributeTypes)
                else {
                    throw SwiftDataError.unsupportedPredicate("Only direct persisted string contains is supported")
                }
                return .stringContains(base, try field("other", from: fields))
            case "SequenceStartsWith":
                let base = try field("base", from: fields)
                guard case let .keyPath(path) = base, path.count == 1,
                    hasStringType(for: path, attributeTypes: attributeTypes)
                else {
                    throw SwiftDataError.unsupportedPredicate("Only direct persisted string prefixes are supported")
                }
                return .stringStartsWith(base, try field("prefix", from: fields))
            case "RangeExpressionContains":
                let element = try field("element", from: fields)
                guard case let .keyPath(path) = element, path.count == 1,
                    hasIntegerType(for: path, attributeTypes: attributeTypes),
                    case let .expression(rangeName, rangeChildren) = fields["range"]
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Only integer range containment on direct attributes is supported")
                }
                switch rangeName {
                case "ClosedRange", "Range":
                    let rangeFields = try validatedFields(
                        rangeChildren, nodeName: rangeName, expected: ["lower", "upper"])
                    let lower = try field("lower", from: rangeFields)
                    let upper = try field("upper", from: rangeFields)
                    guard case .value(.int) = lower, case .value(.int) = upper else {
                        throw SwiftDataError.unsupportedPredicate("Range bounds must be typed integer captures")
                    }
                    return .conjunction(
                        .comparison(.greaterThanOrEqual, element, lower),
                        .comparison(
                            rangeName == "ClosedRange" ? .lessThanOrEqual : .lessThan,
                            element,
                            upper))
                case "PartialRangeFrom", "PartialRangeThrough", "PartialRangeUpTo":
                    let expectedBound = rangeName == "PartialRangeFrom" ? "lowerBound" : "upperBound"
                    let rangeFields = try validatedFields(
                        rangeChildren, nodeName: rangeName, expected: [expectedBound])
                    let bound = try field(expectedBound, from: rangeFields)
                    guard case .value(.int) = bound else {
                        throw SwiftDataError.unsupportedPredicate("Partial range bounds require integer captures.")
                    }
                    let operation: PredicateIR.ComparisonOperator =
                        switch rangeName {
                        case "PartialRangeFrom": .greaterThanOrEqual
                        case "PartialRangeThrough": .lessThanOrEqual
                        default: .lessThan
                        }
                    return .comparison(operation, element, bound)
                default:
                    throw SwiftDataError.unsupportedPredicate("Unsupported integer range kind '\(rangeName)'.")
                }
            case "SequenceContains":
                let sequence = try field("sequence", from: fields)
                let elementNode = fields["element"]!
                guard case let .keyPath(path) = sequence, path.count == 1,
                    let collectionElement = scalarCollectionElement(attributeTypes[path[0]])
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "SequenceContains requires a direct Codable collection of supported scalar values.")
                }
                let unsignedElementType: String? =
                    switch collectionElement.type {
                    case "UInt", "UInt64": collectionElement.type
                    default: nil
                    }
                let element: PredicateIR
                if let unsignedElementType,
                    let unsignedValue = unsignedCollectionCapture(elementNode, matching: unsignedElementType)
                {
                    element = .value(unsignedValue)
                } else {
                    element = try build(
                        elementNode,
                        attributeTypes: attributeTypes,
                        optionalAttributeNames: optionalAttributeNames)
                }
                func compatible(_ value: StoredValue) -> Bool {
                    if value == .null { return collectionElement.isOptional }
                    if unsignedElementType != nil, case .text = value { return true }
                    switch (collectionElement.type, value) {
                    case ("String", .text), ("Bool", .int),
                        ("Int", .int), ("Int8", .int), ("Int16", .int), ("Int32", .int),
                        ("Int64", .int), ("UInt", .int), ("UInt8", .int), ("UInt16", .int),
                        ("UInt32", .int), ("UInt64", .int):
                        return true
                    default:
                        return false
                    }
                }
                guard case let .value(value) = element,
                    compatible(value)
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "SequenceContains requires a compatible scalar element value.")
                }
                let baseElementType = unsignedElementType.map { "Unsigned<\($0)>" } ?? collectionElement.type
                let elementType = collectionElement.isOptional ? "Optional<\(baseElementType)>" : baseElementType
                return .collectionContains(path[0], elementType, element)
            case "OSDSequenceContainsWhere":
                guard case let .keyPath(path) = try field("sequence", from: fields),
                    !path.isEmpty
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "SequenceContainsWhere requires a relationship collection key path.")
                }
                let relationship = path.joined(separator: ".")
                return .relationshipContains(
                    relationship,
                    try elementPredicate(
                        field("test", from: fields), relationship: relationship,
                        attributeTypes: attributeTypes))
            case "OSDSequenceIsEmpty":
                guard
                    case let .keyPath(path) = try field(
                        "sequence", from: fields),
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
                        "sequence", from: fields), !path.isEmpty
                else {
                    throw SwiftDataError.unsupportedPredicate("Collection count requires a relationship path.")
                }
                return .relationshipCount(
                    path.flatMap { $0.split(separator: ".").map(String.init) }
                        .joined(separator: "."))
            case "OSDScalarCollectionAllEqual":
                guard
                    case let .keyPath(path) = try field(
                        "sequence", from: fields), path.count == 1,
                    let collectionElement = scalarCollectionElement(attributeTypes[path[0]]),
                    !collectionElement.isOptional,
                    case let .value(value) = try field("value", from: fields)
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Codable collection allSatisfy requires a direct scalar collection and capture.")
                }
                return .collectionAllEqual(path[0], collectionElement.type, .value(value))
            case "OSDScalarCollectionAllLessThan", "OSDScalarCollectionAllLessThanOrEqual",
                "OSDScalarCollectionAllGreaterThan", "OSDScalarCollectionAllGreaterThanOrEqual":
                guard
                    case let .keyPath(path) = try field(
                        "sequence", from: fields), path.count == 1,
                    let collectionElement = scalarCollectionElement(attributeTypes[path[0]]),
                    !collectionElement.isOptional,
                    ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt64"]
                        .contains(collectionElement.type),
                    case let .value(value) = try field("value", from: fields)
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
                return .collectionAllCompare(path[0], collectionElement.type, operation, .value(value))
            case "OSDCodableCollectionIsEmpty":
                guard
                    case let .keyPath(path) = try field(
                        "collection", from: fields), path.count == 1,
                    scalarCollectionElement(attributeTypes[path[0]])?.isOptional == false
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Codable collection isEmpty requires a direct scalar collection attribute.")
                }
                return .codableCollectionIsEmpty(path[0])
            case "OSDCodableCollectionCount":
                guard
                    case let .keyPath(path) = try field(
                        "collection", from: fields), path.count == 1,
                    scalarCollectionElement(attributeTypes[path[0]])?.isOptional == false
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Codable collection count requires a direct scalar collection attribute.")
                }
                return .codableCollectionCount(path[0])
            case "OSDSequenceAllSatisfy":
                guard
                    case let .keyPath(path) = try field(
                        "sequence", from: fields), !path.isEmpty
                else {
                    throw SwiftDataError.unsupportedPredicate("allSatisfy requires a relationship collection path.")
                }
                let relationship = path.joined(separator: ".")
                let body = try elementPredicate(
                    field("test", from: fields),
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
        case let .persistentIdentifier(path):
            let fullPath =
                path.starts(with: normalizedRelationships)
                ? path
                : normalizedRelationships + path
            return .persistentIdentifier(fullPath)
        case .identifierValue:
            return ir
        case let .persistentIdentifierComparison(op, identifier, path):
            let fullPath =
                path.starts(with: normalizedRelationships)
                ? path
                : normalizedRelationships + path
            return .persistentIdentifierComparison(
                op,
                identifier,
                try validatedPersistentIdentifierPath(fullPath, attributeTypes: attributeTypes))
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
            if fullPath.last == PredicatePlanProperty.persistentIdentifier {
                let relationshipPath = fullPath.dropLast().joined(separator: ".")
                guard !relationshipPath.isEmpty,
                    attributeTypes[relationshipPath] == "OSDToOneRelationship"
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Persistent identifier relationship paths must resolve to a to-one relationship.")
                }
                return .keyPath(fullPath)
            }
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
        case let .optionalComparison(op, lhs, rhs, decimal):
            return .optionalComparison(
                op,
                try prefixRelationshipPath(lhs, relationships: relationships, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationships: relationships, attributeTypes: attributeTypes),
                decimal: decimal)
        case let .arithmetic(op, lhs, rhs):
            return .arithmetic(
                op,
                try prefixRelationshipPath(lhs, relationships: relationships, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationships: relationships, attributeTypes: attributeTypes))
        case let .boundedArithmetic(op, lhs, rhs, width):
            return .boundedArithmetic(
                op,
                try prefixRelationshipPath(lhs, relationships: relationships, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationships: relationships, attributeTypes: attributeTypes),
                width)
        case let .unaryNegation(value, width):
            return .unaryNegation(
                try prefixRelationshipPath(value, relationships: relationships, attributeTypes: attributeTypes),
                integerWidth: width)
        case let .realArithmetic(op, lhs, rhs):
            return .realArithmetic(
                op,
                try prefixRelationshipPath(lhs, relationships: relationships, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationships: relationships, attributeTypes: attributeTypes))
        case let .floatArithmetic(op, lhs, rhs):
            return .floatArithmetic(
                op,
                try prefixRelationshipPath(lhs, relationships: relationships, attributeTypes: attributeTypes),
                try prefixRelationshipPath(rhs, relationships: relationships, attributeTypes: attributeTypes))
        case let .floatNegation(value):
            return .floatNegation(
                try prefixRelationshipPath(value, relationships: relationships, attributeTypes: attributeTypes))
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
        case let .comparison(_, lhs, rhs), let .decimalComparison(_, lhs, rhs),
            let .optionalComparison(_, lhs, rhs, _), let .arithmetic(_, lhs, rhs),
            let .boundedArithmetic(_, lhs, rhs, _), let .realArithmetic(_, lhs, rhs),
            let .floatArithmetic(_, lhs, rhs),
            let .nilCoalesce(lhs, rhs),
            let .localizedStandardContains(lhs, rhs), let .stringContains(lhs, rhs),
            let .stringStartsWith(lhs, rhs), let .conjunction(lhs, rhs), let .disjunction(lhs, rhs):
            return referencesDecimal(lhs, attributeTypes: attributeTypes)
                || referencesDecimal(rhs, attributeTypes: attributeTypes)
        case let .unaryNegation(value, _):
            return referencesDecimal(value, attributeTypes: attributeTypes)
        case let .floatNegation(value):
            return referencesDecimal(value, attributeTypes: attributeTypes)
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
        case .sequenceContains, .relationshipIsPresent, .relationshipCount, .persistentIdentifier,
            .identifierValue, .persistentIdentifierComparison, .value:
            return false
        }
    }

    private static func comparison(
        _ op: PredicateIR.ComparisonOperator,
        _ lhs: PredicateIR,
        _ rhs: PredicateIR,
        decimal: Bool
    ) -> PredicateIR {
        decimal ? .decimalComparison(op, lhs, rhs) : .comparison(op, lhs, rhs)
    }

    private static func comparisonIR(
        _ op: PredicateIR.ComparisonOperator,
        _ lhs: PredicateIR,
        _ rhs: PredicateIR,
        attributeTypes: [String: String],
        optionalAttributeNames: Set<String>
    ) throws -> PredicateIR {
        try validateFlattenedBlobComparison(op, lhs: lhs, rhs: rhs, attributeTypes: attributeTypes)
        let decimal =
            referencesDecimal(lhs, attributeTypes: attributeTypes)
            || referencesDecimal(rhs, attributeTypes: attributeTypes)
        let hasNullLiteral = isNullLiteral(lhs) || isNullLiteral(rhs)
        let hasNullableOperand =
            isNullablePredicateValue(
                lhs, attributeTypes: attributeTypes, optionalAttributeNames: optionalAttributeNames)
            || isNullablePredicateValue(
                rhs, attributeTypes: attributeTypes, optionalAttributeNames: optionalAttributeNames)
        guard !hasNullLiteral, hasNullableOperand else {
            return comparison(op, lhs, rhs, decimal: decimal)
        }
        return .optionalComparison(op, lhs, rhs, decimal: decimal)
    }

    private static func persistentIdentifierPath(_ name: String) -> [String]? {
        let components = name.split(separator: ".").map(String.init)
        guard components.last == PredicatePlanProperty.persistentIdentifier else { return nil }
        return Array(components.dropLast())
    }

    private static func persistentIdentifierCapture(
        _ lhs: PredicateIR,
        comparedTo rhs: PredicateIR
    ) -> (identifier: PersistentIdentifier, path: [String])? {
        guard case let .persistentIdentifier(path) = lhs,
            case let .identifierValue(identifier) = rhs
        else { return nil }
        return (identifier, path)
    }

    private static func persistentIdentifierComparison(
        _ op: PredicateIR.ComparisonOperator,
        _ identifier: PersistentIdentifier,
        path: [String],
        attributeTypes: [String: String]
    ) throws -> PredicateIR {
        guard op == .equal || op == .notEqual else {
            throw SwiftDataError.unsupportedPredicate("PersistentIdentifier supports equality comparisons only.")
        }
        let validatedPath = try validatedPersistentIdentifierPath(path, attributeTypes: attributeTypes)
        return .persistentIdentifierComparison(op, identifier, validatedPath)
    }

    private static func validatedPersistentIdentifierPath(
        _ path: [String],
        attributeTypes: [String: String]
    ) throws -> [String] {
        guard !path.contains(where: { $0.isEmpty || $0 == PredicatePlanProperty.persistentIdentifier }) else {
            throw SwiftDataError.unsupportedPredicate("Invalid persistent identifier relationship path.")
        }
        guard !path.isEmpty else { return path }
        var relationshipPath: [String] = []
        for component in path {
            relationshipPath.append(component)
            guard attributeTypes[relationshipPath.joined(separator: ".")] == "OSDToOneRelationship" else {
                throw SwiftDataError.unsupportedPredicate(
                    "Persistent identifier paths must contain only declared to-one relationships.")
            }
        }
        return path
    }

    private static func isNullLiteral(_ value: PredicateIR) -> Bool {
        if case .value(.null) = value { return true }
        return false
    }

    private static func isNullablePredicateValue(
        _ value: PredicateIR,
        attributeTypes: [String: String],
        optionalAttributeNames: Set<String>
    ) -> Bool {
        switch value {
        case let .keyPath(path):
            let name = path.joined(separator: ".")
            return optionalAttributeNames.contains(name) || attributeTypes[name]?.hasSuffix("?") == true
        case .value(.null):
            return true
        case let .arithmetic(_, lhs, rhs), let .realArithmetic(_, lhs, rhs),
            let .floatArithmetic(_, lhs, rhs),
            let .boundedArithmetic(_, lhs, rhs, _):
            return isNullablePredicateValue(
                lhs, attributeTypes: attributeTypes, optionalAttributeNames: optionalAttributeNames)
                || isNullablePredicateValue(
                    rhs, attributeTypes: attributeTypes, optionalAttributeNames: optionalAttributeNames)
        case let .unaryNegation(value, _):
            return isNullablePredicateValue(
                value, attributeTypes: attributeTypes, optionalAttributeNames: optionalAttributeNames)
        case let .floatNegation(value):
            return isNullablePredicateValue(
                value, attributeTypes: attributeTypes, optionalAttributeNames: optionalAttributeNames)
        case let .nilCoalesce(lhs, rhs):
            return isNullablePredicateValue(
                lhs, attributeTypes: attributeTypes, optionalAttributeNames: optionalAttributeNames)
                && isNullablePredicateValue(
                    rhs, attributeTypes: attributeTypes, optionalAttributeNames: optionalAttributeNames)
        case let .conditional(_, trueBranch, falseBranch):
            return isNullablePredicateValue(
                trueBranch, attributeTypes: attributeTypes, optionalAttributeNames: optionalAttributeNames)
                || isNullablePredicateValue(
                    falseBranch, attributeTypes: attributeTypes, optionalAttributeNames: optionalAttributeNames)
        case let .localizedStandardContains(lhs, rhs), let .stringContains(lhs, rhs),
            let .stringStartsWith(lhs, rhs):
            return isNullablePredicateValue(
                lhs, attributeTypes: attributeTypes, optionalAttributeNames: optionalAttributeNames)
                || isNullablePredicateValue(
                    rhs, attributeTypes: attributeTypes, optionalAttributeNames: optionalAttributeNames)
        case .comparison, .decimalComparison, .optionalComparison, .conjunction, .disjunction, .negation,
            .persistentIdentifier, .identifierValue, .persistentIdentifierComparison,
            .relationshipIsPresent, .value, .sequenceContains, .collectionContains, .collectionAllEqual,
            .collectionAllCompare, .codableCollectionIsEmpty, .codableCollectionCount,
            .relationshipContains, .relationshipCount:
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
        case let .optionalComparison(op, lhs, rhs, decimal):
            return .optionalComparison(
                op,
                try elementPredicate(lhs, relationship: relationship, attributeTypes: attributeTypes, depth: depth),
                try elementPredicate(rhs, relationship: relationship, attributeTypes: attributeTypes, depth: depth),
                decimal: decimal)
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
            guard depth < OSDQueryLimits.maximumNestedCollectionPredicateDepth - 1 else {
                throw SwiftDataError.unsupportedPredicate(
                    "Nested collection predicates support at most \(OSDQueryLimits.maximumNestedCollectionPredicateDepth) levels."
                )
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

    private static func attributeType(for path: String, in attributeTypes: [String: String]) -> String? {
        if let exact = attributeTypes[path] { return exact }
        let suffix = attributeTypes.filter { $0.key.hasSuffix(".\(path)") }.map(\.value)
        guard suffix.count == 1 else { return nil }
        return suffix[0]
    }

    private static func integerArithmeticWidth(
        for lhs: PredicateMirrorWalker.Node,
        and rhs: PredicateMirrorWalker.Node?,
        attributeTypes: [String: String]
    ) throws -> PredicateIntegerWidth? {
        enum OperandType {
            case width(PredicateIntegerWidth)
            case integerLiteral
            case unsupported
        }
        func merge(_ lhs: OperandType, _ rhs: OperandType) throws -> OperandType {
            switch (lhs, rhs) {
            case let (.width(lhsWidth), .width(rhsWidth)):
                guard lhsWidth == rhsWidth else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Integer arithmetic operands must have matching widths (\(lhsWidth.rawValue), \(rhsWidth.rawValue))."
                    )
                }
                return .width(lhsWidth)
            case let (.width(width), .integerLiteral), let (.integerLiteral, .width(width)):
                return .width(width)
            case (.integerLiteral, .integerLiteral):
                return .integerLiteral
            default:
                return .unsupported
            }
        }
        func width(forTypeName typeName: String?) -> OperandType {
            guard let typeName else { return .unsupported }
            let unwrapped = typeName.hasSuffix("?") ? String(typeName.dropLast()) : typeName
            switch unwrapped {
            case "Int8", "Swift.Int8": return .width(.int8)
            case "Int16", "Swift.Int16": return .width(.int16)
            case "Int32", "Swift.Int32": return .width(.int32)
            case "Int", "Swift.Int", "Int64", "Swift.Int64": return .width(.int64)
            case "UInt8", "Swift.UInt8": return .width(.uint8)
            case "UInt16", "Swift.UInt16": return .width(.uint16)
            case "UInt32", "Swift.UInt32": return .width(.uint32)
            case "UInt", "Swift.UInt", "UInt64", "Swift.UInt64": return .unsupported
            default: return .unsupported
            }
        }
        func width(of node: PredicateMirrorWalker.Node) throws -> OperandType {
            switch node {
            case let .propertyReference(path):
                let typeName = attributeType(for: path, in: attributeTypes)
                return width(forTypeName: typeName)
            case let .capture(typeName, _):
                return width(forTypeName: typeName)
            case let .typedValue(value):
                guard case .int = value else { return .unsupported }
                return .integerLiteral
            case let .typedCapture(value, typeName):
                let operandType = width(forTypeName: typeName)
                guard case let .width(width) = operandType else { return operandType }
                guard case let .int(integer) = value,
                    integer >= width.minimumValue, integer <= width.maximumValue
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Integer capture is outside its declared \(typeName) range.")
                }
                return operandType
            case .persistentIdentifierReference, .identifierCapture:
                return .unsupported
            case let .expression(name, children):
                let fields = Dictionary(uniqueKeysWithValues: children)
                switch name {
                case "Value":
                    guard let captured = fields["value"] else { return .unsupported }
                    return try width(of: captured)
                case "UnaryMinus":
                    guard let wrapped = fields["wrapped"] else { return .unsupported }
                    return try width(of: wrapped)
                case "Arithmetic", "IntDivision", "IntRemainder", "NilCoalesce":
                    guard let lhs = fields["lhs"], let rhs = fields["rhs"] else { return .unsupported }
                    return try merge(width(of: lhs), width(of: rhs))
                case "OptionalFlatMap":
                    guard let transform = fields["transform"] else { return .unsupported }
                    return try width(of: transform)
                default:
                    return .unsupported
                }
            }
        }
        let lhsType = try width(of: lhs)
        let resultType: OperandType
        if let rhs {
            resultType = try merge(lhsType, width(of: rhs))
        } else {
            resultType = lhsType
        }
        switch resultType {
        case let .width(width): return width
        case .integerLiteral: return .int64
        case .unsupported:
            return nil
        }
    }

    private static func isDoubleArithmeticOperand(
        _ ir: PredicateIR,
        attributeTypes: [String: String]
    ) -> Bool {
        switch ir {
        case let .keyPath(path):
            guard !path.isEmpty else { return false }
            let typeName = attributeType(for: path.joined(separator: "."), in: attributeTypes)
            let unwrapped = typeName.map { $0.hasSuffix("?") ? String($0.dropLast()) : $0 }
            return ["Double", "Swift.Double"].contains(unwrapped ?? "")
        case .value(.double):
            return true
        case let .realArithmetic(_, lhs, rhs):
            return isDoubleArithmeticOperand(lhs, attributeTypes: attributeTypes)
                && isDoubleArithmeticOperand(rhs, attributeTypes: attributeTypes)
        case let .unaryNegation(value, integerWidth):
            return integerWidth == nil && isDoubleArithmeticOperand(value, attributeTypes: attributeTypes)
        case let .nilCoalesce(lhs, rhs):
            return isDoubleArithmeticOperand(lhs, attributeTypes: attributeTypes)
                && isDoubleArithmeticOperand(rhs, attributeTypes: attributeTypes)
        default:
            return false
        }
    }

    private static func isFloatArithmeticOperand(
        _ node: PredicateMirrorWalker.Node,
        attributeTypes: [String: String]
    ) -> Bool {
        func isFloat(_ typeName: String?) -> Bool {
            let unwrapped = typeName.map { $0.hasSuffix("?") ? String($0.dropLast()) : $0 }
            return ["Float", "Swift.Float"].contains(unwrapped ?? "")
        }
        switch node {
        case let .propertyReference(path):
            return isFloat(attributeType(for: path, in: attributeTypes))
        case let .capture(typeName, _), let .typedCapture(_, typeName):
            return isFloat(typeName)
        case let .expression(name, children):
            let fields = Dictionary(uniqueKeysWithValues: children)
            switch name {
            case "Value", "UnaryMinus":
                let label = name == "Value" ? "value" : "wrapped"
                guard let operand = fields[label] else { return false }
                return isFloatArithmeticOperand(operand, attributeTypes: attributeTypes)
            case "Arithmetic", "FloatDivision":
                guard let lhs = fields["lhs"], let rhs = fields["rhs"] else { return false }
                return isFloatArithmeticOperand(lhs, attributeTypes: attributeTypes)
                    && isFloatArithmeticOperand(rhs, attributeTypes: attributeTypes)
            case "NilCoalesce":
                guard let lhs = fields["lhs"], let rhs = fields["rhs"] else { return false }
                return isFloatArithmeticOperand(lhs, attributeTypes: attributeTypes)
                    && isFloatArithmeticOperand(rhs, attributeTypes: attributeTypes)
            case "OptionalFlatMap":
                guard let transform = fields["transform"] else { return false }
                return isFloatArithmeticOperand(transform, attributeTypes: attributeTypes)
            default:
                return false
            }
        case .typedValue, .persistentIdentifierReference, .identifierCapture:
            return false
        }
    }

    private static func scalarCollectionElement(_ typeName: String?) -> (type: String, isOptional: Bool)? {
        guard let typeName,
            let opening = typeName.firstIndex(of: "<"), typeName.last == ">"
        else { return nil }
        let collectionName = typeName[..<opening].split(separator: ".").last.map(String.init) ?? ""
        guard collectionName == "Array" || collectionName == "Set" else { return nil }
        let rawElement = String(typeName[typeName.index(after: opening)..<typeName.index(before: typeName.endIndex)])
        let element: String
        let isOptional: Bool
        let unqualifiedElement =
            rawElement.hasPrefix("Swift.")
            ? String(rawElement.dropFirst("Swift.".count))
            : rawElement
        if unqualifiedElement.hasPrefix("Optional<"), unqualifiedElement.hasSuffix(">"),
            let opening = unqualifiedElement.firstIndex(of: "<")
        {
            let wrapped = String(
                unqualifiedElement[
                    unqualifiedElement.index(
                        after: opening)..<unqualifiedElement.index(before: unqualifiedElement.endIndex)
                ])
            guard !wrapped.contains("<"), !wrapped.contains(">") else { return nil }
            element = wrapped.hasPrefix("Swift.") ? String(wrapped.dropFirst("Swift.".count)) : wrapped
            isOptional = true
        } else {
            element = unqualifiedElement
            isOptional = false
        }
        guard
            [
                "String", "Bool", "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16",
                "UInt32", "UInt64",
            ].contains(element)
        else { return nil }
        return (element, isOptional)
    }

    private static func unsignedCollectionCapture(
        _ node: PredicateMirrorWalker.Node,
        matching collectionType: String
    ) -> StoredValue? {
        let capture: PredicateMirrorWalker.Node
        if case let .expression("Value", children) = node,
            children.count == 1,
            children[0].0 == "value"
        {
            capture = children[0].1
        } else {
            capture = node
        }
        guard case let .capture(typeName, description) = capture else { return nil }
        let decimal: String
        if typeName == "Swift.\(collectionType)" {
            decimal = description
        } else if typeName == "Swift.Optional<Swift.\(collectionType)>",
            description.hasPrefix("Optional("), description.hasSuffix(")")
        {
            decimal = String(description.dropFirst("Optional(".count).dropLast())
        } else {
            return nil
        }
        guard let value = UInt64(decimal) else {
            return nil
        }
        return .text(String(value))
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
        case "Negation", "UnaryMinus": ["wrapped"]
        case "Comparison": ["op", "lhs", "rhs"]
        case "Arithmetic": ["op", "lhs", "rhs"]
        case "FloatDivision", "IntDivision", "IntRemainder": ["lhs", "rhs"]
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
        case "PartialRangeFrom": ["lowerBound"]
        case "PartialRangeThrough", "PartialRangeUpTo": ["upperBound"]
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

    private static func capturedValue(typeName: String, description: String) throws -> PredicateIR {
        switch typeName {
        case "Swift.String":
            return .value(.text(description))
        case "Swift.Bool":
            guard let value = Bool(description) else { throw SwiftDataError.unsupportedPredicate(typeName) }
            return .value(.int(value ? 1 : 0))
        case "Swift.Int8":
            guard let value = Int64(description) else { throw SwiftDataError.unsupportedPredicate(typeName) }
            guard value >= Int64(Int8.min), value <= Int64(Int8.max) else {
                throw SwiftDataError.unsupportedPredicate(typeName)
            }
            return .value(.int(value))
        case "Swift.Int16":
            guard let value = Int64(description) else { throw SwiftDataError.unsupportedPredicate(typeName) }
            guard value >= Int64(Int16.min), value <= Int64(Int16.max) else {
                throw SwiftDataError.unsupportedPredicate(typeName)
            }
            return .value(.int(value))
        case "Swift.Int32":
            guard let value = Int64(description) else { throw SwiftDataError.unsupportedPredicate(typeName) }
            guard value >= Int64(Int32.min), value <= Int64(Int32.max) else {
                throw SwiftDataError.unsupportedPredicate(typeName)
            }
            return .value(.int(value))
        case "Swift.Int", "Swift.Int64":
            guard let value = Int64(description) else { throw SwiftDataError.unsupportedPredicate(typeName) }
            return .value(.int(value))
        case "Swift.Float":
            guard let value = Float(description), value.isFinite else {
                throw SwiftDataError.unsupportedPredicate(typeName)
            }
            return .value(.double(Double(value)))
        case "Swift.Double":
            guard let value = Double(description) else { throw SwiftDataError.unsupportedPredicate(typeName) }
            return .value(.double(value))
        case "Swift.UInt8":
            guard let value = UInt8(description) else { throw SwiftDataError.unsupportedPredicate(typeName) }
            return .value(.int(Int64(value)))
        case "Swift.UInt16":
            guard let value = UInt16(description) else { throw SwiftDataError.unsupportedPredicate(typeName) }
            return .value(.int(Int64(value)))
        case "Swift.UInt32":
            guard let value = UInt32(description) else { throw SwiftDataError.unsupportedPredicate(typeName) }
            return .value(.int(Int64(value)))
        case "Swift.UInt", "Swift.UInt64":
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
