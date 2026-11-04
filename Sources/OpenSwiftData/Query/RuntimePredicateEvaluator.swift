import Foundation
import CoreFoundation

package enum RuntimePredicateEvaluator {
    package struct Context {
        package let values: [String: RuntimeValue]
        package let relationships: [String: [Context]]

        package init(values: [String: RuntimeValue], relationships: [String: [Context]] = [:]) {
            self.values = values
            self.relationships = relationships
        }
    }

    package enum TruthValue: Equatable {
        case yes
        case no
        case unknown
    }

    package static func matches(
        _ plan: PredicatePlan,
        values: [String: RuntimeValue],
        relationshipValues: [String: [[String: RuntimeValue]]] = [:]
    ) throws -> Bool {
        let context = Context(
            values: values,
            relationships: relationshipValues.mapValues { $0.map { Context(values: $0) } })
        return try matches(plan, context: context)
    }

    package static func matches(_ plan: PredicatePlan, context: Context) throws -> Bool {
        try evaluateTruth(plan, context: context) == .yes
    }

    package static func referencedProperties(in plan: PredicatePlan) -> Set<String> {
        switch plan {
        case let .conjunction(lhs, rhs), let .disjunction(lhs, rhs), let .comparison(_, lhs, rhs),
            let .decimalComparison(_, lhs, rhs), let .arithmetic(_, lhs, rhs), let .boundedArithmetic(_, lhs, rhs, _),
            let .floatArithmetic(_, lhs, rhs),
            let .coalesce(lhs, rhs), let .localizedStandardContains(lhs, rhs), let .stringContains(lhs, rhs),
            let .stringStartsWith(lhs, rhs):
            referencedProperties(in: lhs).union(referencedProperties(in: rhs))
        case let .collectionContains(name, _, element):
            Set([name]).union(referencedProperties(in: element))
        case let .collectionAllEqual(name, _, element):
            Set([name]).union(referencedProperties(in: element))
        case let .collectionAllCompare(name, _, _, element):
            Set([name]).union(referencedProperties(in: element))
        case let .codableCollectionIsEmpty(name):
            [name]
        case let .codableCollectionCount(name):
            [name]
        case let .conditional(test, trueBranch, falseBranch):
            referencedProperties(in: test).union(referencedProperties(in: trueBranch)).union(
                referencedProperties(in: falseBranch))
        case let .negation(value), let .unaryNegation(value, _), let .floatNegation(value):
            referencedProperties(in: value)
        case let .isNull(value, _):
            referencedProperties(in: value)
        case let .property(name):
            [name]
        case .relationshipContains, .collectionCount:
            []
        case .value:
            []
        }
    }

    package static func relationshipProperties(in plan: PredicatePlan) -> [String: Set<String>] {
        switch plan {
        case let .relationshipContains(name, body):
            return [name: referencedProperties(in: body)]
        case let .collectionContains(_, _, element):
            return relationshipProperties(in: element)
        case let .collectionAllEqual(_, _, element):
            return relationshipProperties(in: element)
        case let .collectionAllCompare(_, _, _, element):
            return relationshipProperties(in: element)
        case .codableCollectionIsEmpty:
            return [:]
        case .codableCollectionCount:
            return [:]
        case let .collectionCount(name):
            return [name: []]
        case let .property(name):
            let components = name.split(separator: ".", maxSplits: 1).map(String.init)
            guard components.count == 2 else { return [:] }
            return [components[0]: [components[1]]]
        case let .conjunction(lhs, rhs), let .disjunction(lhs, rhs):
            return merge(relationshipProperties(in: lhs), relationshipProperties(in: rhs))
        case let .negation(value), let .unaryNegation(value, _), let .floatNegation(value), let .isNull(value, _):
            return relationshipProperties(in: value)
        case let .comparison(_, lhs, rhs), let .decimalComparison(_, lhs, rhs),
            let .arithmetic(_, lhs, rhs), let .boundedArithmetic(_, lhs, rhs, _),
            let .floatArithmetic(_, lhs, rhs), let .coalesce(lhs, rhs),
            let .localizedStandardContains(lhs, rhs), let .stringContains(lhs, rhs),
            let .stringStartsWith(lhs, rhs):
            return merge(relationshipProperties(in: lhs), relationshipProperties(in: rhs))
        case let .conditional(test, trueBranch, falseBranch):
            return merge(
                relationshipProperties(in: test),
                merge(
                    relationshipProperties(in: trueBranch), relationshipProperties(in: falseBranch)))
        case .value:
            return [:]
        }
    }

    package static func nestedRelationshipNames(in plan: PredicatePlan) -> Set<String> {
        var names: Set<String> = []
        func walk(_ plan: PredicatePlan, collectionDepth: Int) {
            switch plan {
            case let .relationshipContains(name, body):
                if collectionDepth > 0 { names.insert(name) }
                walk(body, collectionDepth: collectionDepth + 1)
            case let .conjunction(lhs, rhs), let .disjunction(lhs, rhs), let .comparison(_, lhs, rhs),
                let .decimalComparison(_, lhs, rhs), let .arithmetic(_, lhs, rhs),
                let .boundedArithmetic(_, lhs, rhs, _), let .floatArithmetic(_, lhs, rhs),
                let .coalesce(lhs, rhs), let .localizedStandardContains(lhs, rhs), let .stringContains(lhs, rhs),
                let .stringStartsWith(lhs, rhs):
                walk(lhs, collectionDepth: collectionDepth)
                walk(rhs, collectionDepth: collectionDepth)
            case let .negation(value), let .unaryNegation(value, _), let .floatNegation(value), let .isNull(value, _):
                walk(value, collectionDepth: collectionDepth)
            case let .conditional(test, yes, no):
                walk(test, collectionDepth: collectionDepth)
                walk(yes, collectionDepth: collectionDepth)
                walk(no, collectionDepth: collectionDepth)
            case let .collectionContains(_, _, value), let .collectionAllEqual(_, _, value),
                let .collectionAllCompare(_, _, _, value):
                walk(value, collectionDepth: collectionDepth)
            case .property, .value, .collectionCount, .codableCollectionIsEmpty, .codableCollectionCount:
                break
            }
        }
        walk(plan, collectionDepth: 0)
        return names
    }

    package static func containsNestedRelationship(_ plan: PredicatePlan, depth: Int = 0) -> Bool {
        switch plan {
        case let .relationshipContains(_, body):
            return depth > 0 || containsNestedRelationship(body, depth: depth + 1)
        case let .conjunction(lhs, rhs), let .disjunction(lhs, rhs), let .comparison(_, lhs, rhs),
            let .decimalComparison(_, lhs, rhs), let .arithmetic(_, lhs, rhs),
            let .boundedArithmetic(_, lhs, rhs, _), let .floatArithmetic(_, lhs, rhs), let .coalesce(lhs, rhs),
            let .localizedStandardContains(lhs, rhs), let .stringContains(lhs, rhs), let .stringStartsWith(lhs, rhs):
            return containsNestedRelationship(lhs, depth: depth) || containsNestedRelationship(rhs, depth: depth)
        case let .negation(value), let .unaryNegation(value, _), let .floatNegation(value), let .isNull(value, _):
            return containsNestedRelationship(value, depth: depth)
        case let .conditional(test, yes, no):
            return containsNestedRelationship(test, depth: depth)
                || containsNestedRelationship(yes, depth: depth)
                || containsNestedRelationship(no, depth: depth)
        case let .collectionContains(_, _, value), let .collectionAllEqual(_, _, value),
            let .collectionAllCompare(_, _, _, value):
            return containsNestedRelationship(value, depth: depth)
        case .property, .value, .collectionCount, .codableCollectionIsEmpty, .codableCollectionCount:
            return false
        }
    }

    private static func merge(
        _ lhs: [String: Set<String>],
        _ rhs: [String: Set<String>]
    ) -> [String: Set<String>] {
        var result = lhs
        for (name, properties) in rhs { result[name, default: []].formUnion(properties) }
        return result
    }

    private static func evaluateTruth(_ plan: PredicatePlan, context: Context) throws -> TruthValue {
        switch plan {
        case let .conjunction(lhs, rhs):
            return and(
                try evaluateTruth(lhs, context: context),
                try evaluateTruth(rhs, context: context))
        case let .disjunction(lhs, rhs):
            return or(
                try evaluateTruth(lhs, context: context),
                try evaluateTruth(rhs, context: context))
        case let .negation(value):
            switch try evaluateTruth(value, context: context) {
            case .yes: return .no
            case .no: return .yes
            case .unknown: return .unknown
            }
        case let .conditional(test, trueBranch, falseBranch):
            switch try evaluateTruth(test, context: context) {
            case .yes: return try evaluateTruth(trueBranch, context: context)
            case .no, .unknown:
                return try evaluateTruth(falseBranch, context: context)
            }
        case let .comparison(op, lhs, rhs):
            let lhsValue = try evaluateValue(lhs, context: context)
            let rhsValue = try evaluateValue(rhs, context: context)
            guard lhsValue != .null, rhsValue != .null else { return .unknown }
            if case let .double(value) = lhsValue, value.isNaN { return .unknown }
            if case let .double(value) = rhsValue, value.isNaN { return .unknown }
            guard let result = compare(lhsValue, op, rhsValue) else {
                throw SwiftDataError.unsupportedPredicate("Pending evaluation cannot compare these stored value types")
            }
            return result ? .yes : .no
        case let .decimalComparison(op, lhs, rhs):
            let lhsValue = try evaluateValue(lhs, context: context)
            let rhsValue = try evaluateValue(rhs, context: context)
            guard lhsValue != .null, rhsValue != .null else { return .unknown }
            guard case let .text(left) = lhsValue, case let .text(right) = rhsValue else {
                throw SwiftDataError.unsupportedPredicate("Decimal comparison requires text operands")
            }
            return compare(DecimalText.compare(left, right), op) ? .yes : .no
        case .arithmetic:
            throw SwiftDataError.unsupportedPredicate("Arithmetic expression is not a boolean predicate")
        case .boundedArithmetic, .unaryNegation, .floatArithmetic, .floatNegation:
            throw SwiftDataError.unsupportedPredicate("Arithmetic expression is not a boolean predicate")
        case let .isNull(value, negated):
            let isNull = try evaluateValue(value, context: context) == .null
            return isNull != negated ? .yes : .no
        case let .localizedStandardContains(lhs, rhs):
            return try evaluateStringPredicate(.localizedStandardContains(lhs, rhs), context: context)
        case let .stringContains(lhs, rhs):
            return try evaluateStringPredicate(.stringContains(lhs, rhs), context: context)
        case let .stringStartsWith(lhs, rhs):
            return try evaluateStringPredicate(.stringStartsWith(lhs, rhs), context: context)
        case let .relationshipContains(name, body):
            for endpointContext in context.relationships[name] ?? [] {
                if try evaluateTruth(body, context: endpointContext) == .yes { return .yes }
            }
            return .no
        case .collectionContains, .collectionAllEqual, .collectionAllCompare, .codableCollectionIsEmpty:
            let value = try evaluateValue(plan, context: context)
            guard value != .null else { return .unknown }
            guard case let .int(integer) = value else {
                throw SwiftDataError.unsupportedPredicate(
                    "Scalar collection membership does not evaluate to a boolean value")
            }
            return integer == 0 ? .no : .yes
        case .property, .value, .coalesce, .collectionCount, .codableCollectionCount:
            let value = try evaluateValue(plan, context: context)
            guard case let .int(integer) = value else {
                throw SwiftDataError.unsupportedPredicate("Predicate expression does not evaluate to a boolean value")
            }
            return integer == 0 ? .no : .yes
        }
    }

    private static func evaluateArithmetic(
        _ operation: PredicateArithmeticOperator,
        lhs: PredicatePlan,
        rhs: PredicatePlan,
        context: Context
    ) throws -> RuntimeValue {
        let lhsValue = try evaluateValue(lhs, context: context)
        let rhsValue = try evaluateValue(rhs, context: context)
        switch (lhsValue, rhsValue) {
        case let (.int(left), .int(right)):
            let result: Int64?
            switch operation {
            case .add:
                let (value, overflow) = left.addingReportingOverflow(right)
                result = overflow ? nil : value
            case .subtract:
                let (value, overflow) = left.subtractingReportingOverflow(right)
                result = overflow ? nil : value
            case .multiply:
                let (value, overflow) = left.multipliedReportingOverflow(by: right)
                result = overflow ? nil : value
            case .divide:
                result = right == 0 || (left == .min && right == -1) ? nil : left / right
            case .remainder:
                result = right == 0 || (left == .min && right == -1) ? nil : left % right
            }
            return result.map(RuntimeValue.int) ?? .null
        case let (.double(left), .double(right)) where left.isFinite && right.isFinite:
            guard operation != .remainder else {
                throw SwiftDataError.unsupportedPredicate("Floating-point remainder is unsupported")
            }
            let result: Double
            switch operation {
            case .add: result = left + right
            case .subtract: result = left - right
            case .multiply: result = left * right
            case .divide: result = left / right
            case .remainder: return .null
            }
            return result.isFinite ? .double(result) : .null
        case let (.double(left), .double(right)) where !left.isFinite || !right.isFinite:
            return .null
        default:
            throw SwiftDataError.unsupportedPredicate("Arithmetic operands must have matching numeric types")
        }
    }

    private static func evaluateBoundedArithmetic(
        _ operation: PredicateArithmeticOperator,
        lhs: PredicatePlan,
        rhs: PredicatePlan,
        width: PredicateIntegerWidth,
        context: Context
    ) throws -> RuntimeValue {
        let lhsValue = try evaluateValue(lhs, context: context)
        let rhsValue = try evaluateValue(rhs, context: context)
        guard case let .int(left) = lhsValue, case let .int(right) = rhsValue else {
            if lhsValue == .null || rhsValue == .null { return .null }
            throw SwiftDataError.unsupportedPredicate("Integer arithmetic requires signed integer operands")
        }
        if !width.isSigned,
            left < width.minimumValue || left > width.maximumValue
                || right < width.minimumValue || right > width.maximumValue
        {
            return .null
        }
        if width.isSigned, (operation == .divide || operation == .remainder), left == width.minimumValue,
            right == -1
        {
            return .null
        }
        let result: Int64?
        switch operation {
        case .add:
            let (value, overflow) = left.addingReportingOverflow(right)
            result = overflow ? nil : value
        case .subtract:
            let (value, overflow) = left.subtractingReportingOverflow(right)
            result = overflow ? nil : value
        case .multiply:
            let (value, overflow) = left.multipliedReportingOverflow(by: right)
            result = overflow ? nil : value
        case .divide:
            result = right == 0 || (left == .min && right == -1) ? nil : left / right
        case .remainder:
            result = right == 0 || (left == .min && right == -1) ? nil : left % right
        }
        guard let result, result >= width.minimumValue, result <= width.maximumValue else { return .null }
        return .int(result)
    }

    private static func evaluateFloatArithmetic(
        _ operation: PredicateArithmeticOperator,
        lhs: PredicatePlan,
        rhs: PredicatePlan,
        context: Context
    ) throws -> RuntimeValue {
        let lhsValue = try evaluateValue(lhs, context: context)
        let rhsValue = try evaluateValue(rhs, context: context)
        guard case let .double(left) = lhsValue, case let .double(right) = rhsValue,
            let lhs = exactFloat(left), let rhs = exactFloat(right)
        else { return .null }
        guard operation != .remainder else {
            throw SwiftDataError.unsupportedPredicate("Floating-point remainder is unsupported")
        }
        let result: Float
        switch operation {
        case .add: result = lhs + rhs
        case .subtract: result = lhs - rhs
        case .multiply: result = lhs * rhs
        case .divide: result = lhs / rhs
        case .remainder: return .null
        }
        return result.isFinite ? .double(Double(result)) : .null
    }

    private static func exactFloat(_ value: Double) -> Float? {
        let result = Float(value)
        guard result.isFinite, Double(result) == value else { return nil }
        return result
    }

    private static func evaluateStringPredicate(
        _ plan: PredicatePlan,
        context: Context
    ) throws -> TruthValue {
        let left: PredicatePlan
        let right: PredicatePlan
        switch plan {
        case let .localizedStandardContains(lhs, rhs), let .stringContains(lhs, rhs), let .stringStartsWith(lhs, rhs):
            left = lhs
            right = rhs
        default:
            throw SwiftDataError.unsupportedPredicate("Expected a string predicate plan")
        }
        let lhsValue = try evaluateValue(left, context: context)
        let rhsValue = try evaluateValue(right, context: context)
        guard case let .text(haystack) = lhsValue, case let .text(needle) = rhsValue else {
            if lhsValue == .null || rhsValue == .null { return .unknown }
            throw SwiftDataError.unsupportedPredicate("String predicate requires string operands")
        }
        let result: Bool
        switch plan {
        case .localizedStandardContains:
            result = OSDStringMatch.localizedStandardContains(haystack, needle)
        case .stringContains:
            result = OSDStringMatch.contains(haystack, needle)
        case .stringStartsWith:
            result = OSDStringMatch.startsWith(haystack, needle)
        default:
            throw SwiftDataError.unsupportedPredicate("Expected a string predicate plan")
        }
        return result ? .yes : .no
    }

    private static func evaluateValue(_ plan: PredicatePlan, context: Context) throws -> RuntimeValue {
        switch plan {
        case let .property(name):
            guard let value = context.values[name] else {
                throw SwiftDataError.unsupportedPredicate("Pending model has no encoded predicate property '\(name)'")
            }
            return value
        case let .collectionCount(name):
            return .int(Int64(context.relationships[name]?.count ?? 0))
        case let .collectionContains(name, elementType, element):
            let collectionValue = try evaluateValue(
                .property(name), context: context)
            guard case let .blob(bytes) = collectionValue else { return .null }
            let elementValue = try evaluateValue(element, context: context)
            guard let array = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [Any] else {
                throw SwiftDataError.unsupportedPredicate("Codable collection contains malformed JSON data")
            }
            let contains: Bool
            switch (elementType, elementValue) {
            case ("String", let .text(needle)):
                contains = array.contains { ($0 as? String) == needle }
            case ("Bool", let .int(needle)):
                contains = array.contains { value in
                    guard let number = value as? NSNumber,
                        CFGetTypeID(number) == CFBooleanGetTypeID()
                    else { return false }
                    return number.boolValue == (needle != 0)
                }
            case (_, let .int(needle)):
                contains = array.contains { value in
                    guard let number = value as? NSNumber,
                        CFGetTypeID(number) != CFBooleanGetTypeID()
                    else { return false }
                    return Int64(number.stringValue) == needle
                }
            default:
                throw SwiftDataError.unsupportedPredicate(
                    "Pending scalar collection membership received an incompatible element value")
            }
            return .int(contains ? 1 : 0)
        case let .collectionAllEqual(name, elementType, element):
            let collectionValue = try evaluateValue(
                .property(name), context: context)
            guard case let .blob(bytes) = collectionValue else { return .null }
            let elementValue = try evaluateValue(element, context: context)
            guard let array = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [Any] else {
                throw SwiftDataError.unsupportedPredicate("Codable collection allSatisfy received malformed JSON data")
            }
            let allMatch: Bool
            switch (elementType, elementValue) {
            case ("String", let .text(expected)):
                allMatch = array.allSatisfy { ($0 as? String) == expected }
            case ("Bool", let .int(expected)):
                allMatch = array.allSatisfy { value in
                    guard let number = value as? NSNumber,
                        CFGetTypeID(number) == CFBooleanGetTypeID()
                    else { return false }
                    return number.boolValue == (expected != 0)
                }
            case (_, let .int(expected)):
                allMatch = array.allSatisfy { value in
                    guard let number = value as? NSNumber,
                        CFGetTypeID(number) != CFBooleanGetTypeID()
                    else { return false }
                    return Int64(number.stringValue) == expected
                }
            default:
                throw SwiftDataError.unsupportedPredicate(
                    "Pending scalar collection allSatisfy received an incompatible element value")
            }
            return .int(allMatch ? 1 : 0)
        case let .collectionAllCompare(name, elementType, operation, element):
            let collectionValue = try evaluateValue(
                .property(name), context: context)
            guard case let .blob(bytes) = collectionValue else { return .null }
            let boundValue = try evaluateValue(element, context: context)
            func matches<T: Comparable>(_ value: T, _ bound: T) -> Bool {
                switch operation {
                case .lessThan: value < bound
                case .lessThanOrEqual: value <= bound
                case .greaterThan: value > bound
                case .greaterThanOrEqual: value >= bound
                case .equal: value == bound
                case .notEqual: value != bound
                }
            }
            switch (elementType, boundValue) {
            case ("Int", let .int(bound)), ("Int8", let .int(bound)), ("Int16", let .int(bound)),
                ("Int32", let .int(bound)), ("Int64", let .int(bound)):
                guard let values = try? JSONDecoder().decode([Int64].self, from: Data(bytes)) else {
                    throw SwiftDataError.unsupportedPredicate("Codable integer collection contains malformed data")
                }
                return .int(values.allSatisfy { matches($0, bound) } ? 1 : 0)
            case ("UInt", .int(let bound)),
                ("UInt64", .int(let bound)) where bound >= 0:
                guard let values = try? JSONDecoder().decode([UInt64].self, from: Data(bytes)) else {
                    throw SwiftDataError.unsupportedPredicate("Codable unsigned collection contains malformed data")
                }
                let unsignedBound = UInt64(bound)
                return .int(values.allSatisfy { matches($0, unsignedBound) } ? 1 : 0)
            case ("UInt", .text(let text)), ("UInt64", .text(let text)):
                guard let unsignedBound = UInt64(text),
                    let values = try? JSONDecoder().decode([UInt64].self, from: Data(bytes))
                else {
                    throw SwiftDataError.unsupportedPredicate("Codable unsigned collection has an invalid bound")
                }
                return .int(values.allSatisfy { matches($0, unsignedBound) } ? 1 : 0)
            default:
                throw SwiftDataError.unsupportedPredicate(
                    "Codable collection allSatisfy ordering requires a matching integer capture")
            }
        case let .codableCollectionIsEmpty(name):
            let value = try evaluateValue(.property(name), context: context)
            guard case let .blob(bytes) = value else { return .null }
            guard let array = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [Any] else {
                throw SwiftDataError.unsupportedPredicate("Codable collection isEmpty received malformed JSON data")
            }
            return .int(array.isEmpty ? 1 : 0)
        case let .codableCollectionCount(name):
            let value = try evaluateValue(.property(name), context: context)
            guard case let .blob(bytes) = value else { return .null }
            guard let array = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [Any] else {
                throw SwiftDataError.unsupportedPredicate("Codable collection count received malformed JSON data")
            }
            return .int(Int64(array.count))
        case let .value(value):
            return runtimeValue(value)
        case let .coalesce(lhs, rhs):
            let lhsValue = try evaluateValue(lhs, context: context)
            return lhsValue == .null
                ? try evaluateValue(rhs, context: context) : lhsValue
        case let .arithmetic(op, lhs, rhs):
            return try evaluateArithmetic(
                op, lhs: lhs, rhs: rhs, context: context)
        case let .boundedArithmetic(op, lhs, rhs, integerWidth):
            return try evaluateBoundedArithmetic(
                op, lhs: lhs, rhs: rhs, width: integerWidth, context: context)
        case let .unaryNegation(value, integerWidth):
            let operand = try evaluateValue(value, context: context)
            switch (operand, integerWidth) {
            case (.null, _): return .null
            case let (.int(integer), .some(width)):
                guard width.isSigned else {
                    throw SwiftDataError.unsupportedPredicate("Unary minus is unsupported for unsigned integers")
                }
                guard integer >= width.minimumValue, integer <= width.maximumValue,
                    integer != width.minimumValue
                else {
                    return .null
                }
                return .int(-integer)
            case let (.double(number), .none) where number.isFinite:
                let negated = -number
                return negated.isFinite ? .double(negated) : .null
            case (.double(_), .none): return .null
            default:
                throw SwiftDataError.unsupportedPredicate("Unary minus operand type does not match its numeric width")
            }
        case let .floatArithmetic(operation, lhs, rhs):
            return try evaluateFloatArithmetic(operation, lhs: lhs, rhs: rhs, context: context)
        case let .floatNegation(value):
            let operand = try evaluateValue(value, context: context)
            guard case let .double(number) = operand, number.isFinite, let float = exactFloat(number) else {
                return .null
            }
            let result = -float
            return result.isFinite ? .double(Double(result)) : .null
        case let .conditional(test, trueBranch, falseBranch):
            switch try evaluateTruth(test, context: context) {
            case .yes: return try evaluateValue(trueBranch, context: context)
            case .no, .unknown:
                return try evaluateValue(falseBranch, context: context)
            }
        case let .localizedStandardContains(lhs, rhs):
            let lhsValue = try evaluateValue(lhs, context: context)
            let rhsValue = try evaluateValue(rhs, context: context)
            guard case let .text(haystack) = lhsValue, case let .text(needle) = rhsValue else {
                if lhsValue == .null || rhsValue == .null { return .null }
                throw SwiftDataError.unsupportedPredicate("localizedStandardContains requires string operands")
            }
            return .int(OSDStringMatch.localizedStandardContains(haystack, needle) ? 1 : 0)
        case let .stringContains(lhs, rhs):
            let lhsValue = try evaluateValue(lhs, context: context)
            let rhsValue = try evaluateValue(rhs, context: context)
            guard case let .text(haystack) = lhsValue, case let .text(needle) = rhsValue else {
                if lhsValue == .null || rhsValue == .null { return .null }
                throw SwiftDataError.unsupportedPredicate("String contains requires string operands")
            }
            return .int(OSDStringMatch.contains(haystack, needle) ? 1 : 0)
        case let .stringStartsWith(lhs, rhs):
            let lhsValue = try evaluateValue(lhs, context: context)
            let rhsValue = try evaluateValue(rhs, context: context)
            guard case let .text(value) = lhsValue, case let .text(prefix) = rhsValue else {
                if lhsValue == .null || rhsValue == .null { return .null }
                throw SwiftDataError.unsupportedPredicate("String prefix requires string operands")
            }
            return .int(OSDStringMatch.startsWith(value, prefix) ? 1 : 0)
        case .comparison, .decimalComparison, .conjunction, .disjunction, .negation, .isNull, .relationshipContains:
            switch try evaluateTruth(plan, context: context) {
            case .yes: return .int(1)
            case .no: return .int(0)
            case .unknown: return .null
            }
        }
    }

    private static func compare(
        _ lhs: RuntimeValue,
        _ op: PredicateComparisonOperator,
        _ rhs: RuntimeValue
    ) -> Bool? {
        switch (lhs, rhs) {
        case let (.int(lhs), .int(rhs)):
            return compare(lhs, op, rhs)
        case let (.int(lhs), .double(rhs)):
            return compare(compareIntegerAndDouble(lhs, rhs), op)
        case let (.double(lhs), .int(rhs)):
            let result = compareIntegerAndDouble(rhs, lhs)
            let reversed: ComparisonResult
            switch result {
            case .orderedAscending: reversed = .orderedDescending
            case .orderedSame: reversed = .orderedSame
            case .orderedDescending: reversed = .orderedAscending
            @unknown default: reversed = .orderedSame
            }
            return compare(reversed, op)
        case let (.double(lhs), .double(rhs)):
            return compare(lhs, op, rhs)
        case let (.text(lhs), .text(rhs)):
            let lhsBytes = Array(lhs.utf8)
            let rhsBytes = Array(rhs.utf8)
            let ordering: Int =
                lhsBytes == rhsBytes ? 0 : lhsBytes.lexicographicallyPrecedes(rhsBytes) ? -1 : 1
            return compare(ordering, op, 0)
        case let (.blob(lhs), .blob(rhs)) where op == .equal || op == .notEqual:
            return (lhs == rhs) == (op == .equal)
        default:
            return nil
        }
    }

    private static func compareIntegerAndDouble(_ integer: Int64, _ real: Double) -> ComparisonResult {
        if real < -0x1p63 { return .orderedDescending }
        if real >= 0x1p63 { return .orderedAscending }
        let truncated = Int64(real)
        if integer < truncated { return .orderedAscending }
        if integer > truncated { return .orderedDescending }
        let exactInteger = Double(integer)
        if exactInteger < real { return .orderedAscending }
        if exactInteger > real { return .orderedDescending }
        return .orderedSame
    }

    private static func compare(_ ordering: ComparisonResult, _ op: PredicateComparisonOperator) -> Bool {
        switch op {
        case .equal: ordering == .orderedSame
        case .notEqual: ordering != .orderedSame
        case .lessThan: ordering == .orderedAscending
        case .lessThanOrEqual: ordering != .orderedDescending
        case .greaterThan: ordering == .orderedDescending
        case .greaterThanOrEqual: ordering != .orderedAscending
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ op: PredicateComparisonOperator, _ rhs: T) -> Bool {
        switch op {
        case .equal: lhs == rhs
        case .notEqual: lhs != rhs
        case .lessThan: lhs < rhs
        case .lessThanOrEqual: lhs <= rhs
        case .greaterThan: lhs > rhs
        case .greaterThanOrEqual: lhs >= rhs
        }
    }

    private static func runtimeValue(_ value: StoredValue) -> RuntimeValue {
        switch value {
        case .null: .null
        case let .int(value): .int(value)
        case let .double(value): .double(value)
        case let .text(value): .text(value)
        case let .blob(value): .blob(value)
        }
    }

    private static func and(_ lhs: TruthValue, _ rhs: TruthValue) -> TruthValue {
        switch (lhs, rhs) {
        case (.no, _), (_, .no): .no
        case (.yes, .yes): .yes
        default: .unknown
        }
    }

    private static func or(_ lhs: TruthValue, _ rhs: TruthValue) -> TruthValue {
        switch (lhs, rhs) {
        case (.yes, _), (_, .yes): .yes
        case (.no, .no): .no
        default: .unknown
        }
    }
}
