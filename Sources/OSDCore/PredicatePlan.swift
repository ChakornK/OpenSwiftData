/// A storage-independent predicate plan used by SQL and in-memory evaluation.
public indirect enum PredicatePlan: Sendable, Equatable {
    case conjunction(PredicatePlan, PredicatePlan)
    case disjunction(PredicatePlan, PredicatePlan)
    case negation(PredicatePlan)
    case comparison(PredicateComparisonOperator, PredicatePlan, PredicatePlan)
    case arithmetic(PredicateArithmeticOperator, PredicatePlan, PredicatePlan)
    case isNull(PredicatePlan, negated: Bool)
    case property(String)
    case value(StoredValue)
    case coalesce(PredicatePlan, PredicatePlan)
    case conditional(PredicatePlan, PredicatePlan, PredicatePlan)
    case localizedStandardContains(PredicatePlan, PredicatePlan)
    case stringContains(PredicatePlan, PredicatePlan)
    case stringStartsWith(PredicatePlan, PredicatePlan)
}

/// A checked numeric operation supported by SQL and pending predicate evaluation.
public enum PredicateArithmeticOperator: Sendable, Equatable {
    case add
    case subtract
    case multiply
    case divide
    case remainder
}

/// A scalar comparison supported by predicate execution.
public enum PredicateComparisonOperator: Sendable, Equatable {
    case equal
    case notEqual
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
}
