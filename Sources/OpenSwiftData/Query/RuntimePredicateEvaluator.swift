import Foundation

package enum RuntimePredicateEvaluator {
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
        try evaluateTruth(plan, values: values, relationshipValues: relationshipValues) == .yes
    }

    package static func referencedProperties(in plan: PredicatePlan) -> Set<String> {
        switch plan {
        case let .conjunction(lhs, rhs), let .disjunction(lhs, rhs), let .comparison(_, lhs, rhs),
            let .arithmetic(_, lhs, rhs),
            let .coalesce(lhs, rhs), let .localizedStandardContains(lhs, rhs), let .stringContains(lhs, rhs),
            let .stringStartsWith(lhs, rhs):
            referencedProperties(in: lhs).union(referencedProperties(in: rhs))
        case let .conditional(test, trueBranch, falseBranch):
            referencedProperties(in: test).union(referencedProperties(in: trueBranch)).union(
                referencedProperties(in: falseBranch))
        case let .negation(value):
            referencedProperties(in: value)
        case let .isNull(value, _):
            referencedProperties(in: value)
        case let .property(name):
            [name]
        case .relationshipContains:
            []
        case .value:
            []
        }
    }

    package static func relationshipProperties(in plan: PredicatePlan) -> [String: Set<String>] {
        switch plan {
        case let .relationshipContains(name, body):
            [name: referencedProperties(in: body)]
        case let .conjunction(lhs, rhs), let .disjunction(lhs, rhs):
            merge(relationshipProperties(in: lhs), relationshipProperties(in: rhs))
        case let .negation(value), let .isNull(value, _):
            relationshipProperties(in: value)
        case let .comparison(_, lhs, rhs), let .arithmetic(_, lhs, rhs), let .coalesce(lhs, rhs),
            let .localizedStandardContains(lhs, rhs), let .stringContains(lhs, rhs),
            let .stringStartsWith(lhs, rhs):
            merge(relationshipProperties(in: lhs), relationshipProperties(in: rhs))
        case let .conditional(test, trueBranch, falseBranch):
            merge(
                relationshipProperties(in: test),
                merge(
                    relationshipProperties(in: trueBranch), relationshipProperties(in: falseBranch)))
        case .property, .value:
            [:]
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

    private static func evaluateTruth(
        _ plan: PredicatePlan,
        values: [String: RuntimeValue],
        relationshipValues: [String: [[String: RuntimeValue]]]
    ) throws -> TruthValue {
        switch plan {
        case let .conjunction(lhs, rhs):
            return and(
                try evaluateTruth(lhs, values: values, relationshipValues: relationshipValues),
                try evaluateTruth(rhs, values: values, relationshipValues: relationshipValues))
        case let .disjunction(lhs, rhs):
            return or(
                try evaluateTruth(lhs, values: values, relationshipValues: relationshipValues),
                try evaluateTruth(rhs, values: values, relationshipValues: relationshipValues))
        case let .negation(value):
            switch try evaluateTruth(value, values: values, relationshipValues: relationshipValues) {
            case .yes: return .no
            case .no: return .yes
            case .unknown: return .unknown
            }
        case let .conditional(test, trueBranch, falseBranch):
            switch try evaluateTruth(test, values: values, relationshipValues: relationshipValues) {
            case .yes: return try evaluateTruth(trueBranch, values: values, relationshipValues: relationshipValues)
            case .no, .unknown:
                return try evaluateTruth(falseBranch, values: values, relationshipValues: relationshipValues)
            }
        case let .comparison(op, lhs, rhs):
            let lhsValue = try evaluateValue(lhs, values: values, relationshipValues: relationshipValues)
            let rhsValue = try evaluateValue(rhs, values: values, relationshipValues: relationshipValues)
            guard lhsValue != .null, rhsValue != .null else { return .unknown }
            if case let .double(value) = lhsValue, value.isNaN { return .unknown }
            if case let .double(value) = rhsValue, value.isNaN { return .unknown }
            guard let result = compare(lhsValue, op, rhsValue) else {
                throw SwiftDataError.unsupportedPredicate("Pending evaluation cannot compare these stored value types")
            }
            return result ? .yes : .no
        case .arithmetic:
            throw SwiftDataError.unsupportedPredicate("Arithmetic expression is not a boolean predicate")
        case let .isNull(value, negated):
            let isNull = try evaluateValue(value, values: values, relationshipValues: relationshipValues) == .null
            return isNull != negated ? .yes : .no
        case let .localizedStandardContains(lhs, rhs):
            return try evaluateStringPredicate(
                .localizedStandardContains(lhs, rhs), values: values, relationshipValues: relationshipValues)
        case let .stringContains(lhs, rhs):
            return try evaluateStringPredicate(
                .stringContains(lhs, rhs), values: values, relationshipValues: relationshipValues)
        case let .stringStartsWith(lhs, rhs):
            return try evaluateStringPredicate(
                .stringStartsWith(lhs, rhs), values: values, relationshipValues: relationshipValues)
        case let .relationshipContains(name, body):
            for endpointValues in relationshipValues[name] ?? [] {
                if try evaluateTruth(body, values: endpointValues, relationshipValues: [:]) == .yes { return .yes }
            }
            return .no
        case .property, .value, .coalesce:
            let value = try evaluateValue(plan, values: values, relationshipValues: relationshipValues)
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
        values: [String: RuntimeValue],
        relationshipValues: [String: [[String: RuntimeValue]]]
    ) throws -> RuntimeValue {
        let lhsValue = try evaluateValue(lhs, values: values, relationshipValues: relationshipValues)
        let rhsValue = try evaluateValue(rhs, values: values, relationshipValues: relationshipValues)
        guard case let .int(left) = lhsValue, case let .int(right) = rhsValue else {
            throw SwiftDataError.unsupportedPredicate("Checked integer arithmetic requires integer operands")
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
        return result.map(RuntimeValue.int) ?? .null
    }

    private static func evaluateStringPredicate(
        _ plan: PredicatePlan,
        values: [String: RuntimeValue],
        relationshipValues: [String: [[String: RuntimeValue]]]
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
        let lhsValue = try evaluateValue(left, values: values, relationshipValues: relationshipValues)
        let rhsValue = try evaluateValue(right, values: values, relationshipValues: relationshipValues)
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

    private static func evaluateValue(
        _ plan: PredicatePlan,
        values: [String: RuntimeValue],
        relationshipValues: [String: [[String: RuntimeValue]]]
    ) throws -> RuntimeValue {
        switch plan {
        case let .property(name):
            guard let value = values[name] else {
                throw SwiftDataError.unsupportedPredicate("Pending model has no encoded predicate property '\(name)'")
            }
            return value
        case let .value(value):
            return runtimeValue(value)
        case let .coalesce(lhs, rhs):
            let lhsValue = try evaluateValue(lhs, values: values, relationshipValues: relationshipValues)
            return lhsValue == .null
                ? try evaluateValue(rhs, values: values, relationshipValues: relationshipValues) : lhsValue
        case let .arithmetic(op, lhs, rhs):
            return try evaluateArithmetic(
                op, lhs: lhs, rhs: rhs, values: values, relationshipValues: relationshipValues)
        case let .conditional(test, trueBranch, falseBranch):
            switch try evaluateTruth(test, values: values, relationshipValues: relationshipValues) {
            case .yes: return try evaluateValue(trueBranch, values: values, relationshipValues: relationshipValues)
            case .no, .unknown:
                return try evaluateValue(falseBranch, values: values, relationshipValues: relationshipValues)
            }
        case let .localizedStandardContains(lhs, rhs):
            let lhsValue = try evaluateValue(lhs, values: values, relationshipValues: relationshipValues)
            let rhsValue = try evaluateValue(rhs, values: values, relationshipValues: relationshipValues)
            guard case let .text(haystack) = lhsValue, case let .text(needle) = rhsValue else {
                if lhsValue == .null || rhsValue == .null { return .null }
                throw SwiftDataError.unsupportedPredicate("localizedStandardContains requires string operands")
            }
            return .int(OSDStringMatch.localizedStandardContains(haystack, needle) ? 1 : 0)
        case let .stringContains(lhs, rhs):
            let lhsValue = try evaluateValue(lhs, values: values, relationshipValues: relationshipValues)
            let rhsValue = try evaluateValue(rhs, values: values, relationshipValues: relationshipValues)
            guard case let .text(haystack) = lhsValue, case let .text(needle) = rhsValue else {
                if lhsValue == .null || rhsValue == .null { return .null }
                throw SwiftDataError.unsupportedPredicate("String contains requires string operands")
            }
            return .int(OSDStringMatch.contains(haystack, needle) ? 1 : 0)
        case let .stringStartsWith(lhs, rhs):
            let lhsValue = try evaluateValue(lhs, values: values, relationshipValues: relationshipValues)
            let rhsValue = try evaluateValue(rhs, values: values, relationshipValues: relationshipValues)
            guard case let .text(value) = lhsValue, case let .text(prefix) = rhsValue else {
                if lhsValue == .null || rhsValue == .null { return .null }
                throw SwiftDataError.unsupportedPredicate("String prefix requires string operands")
            }
            return .int(OSDStringMatch.startsWith(value, prefix) ? 1 : 0)
        case .comparison, .conjunction, .disjunction, .negation, .isNull, .relationshipContains:
            switch try evaluateTruth(plan, values: values, relationshipValues: relationshipValues) {
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
