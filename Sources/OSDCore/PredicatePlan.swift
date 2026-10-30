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

/// A resolved to-one relationship path used by runtime predicate compilers.
public struct RuntimePredicateRelationship: Sendable, Equatable {
    /// The entity that declares the relationship.
    public let ownerEntityName: String
    /// The relationship property name.
    public let propertyName: String
    /// The requested destination entity.
    public let destinationEntityName: String
    /// The root entity that stores destination rows.
    public let destinationRootEntityName: String
    /// The physical foreign-key column on the owner root table.
    public let foreignKeyColumnName: String
    /// Concrete entity identifiers allowed by the destination entity's inheritance subtree.
    public let destinationEntityIDs: [Int]

    /// Creates a resolved to-one relationship path.
    public init(
        ownerEntityName: String,
        propertyName: String,
        destinationEntityName: String,
        destinationRootEntityName: String,
        foreignKeyColumnName: String,
        destinationEntityIDs: [Int]
    ) {
        self.ownerEntityName = ownerEntityName
        self.propertyName = propertyName
        self.destinationEntityName = destinationEntityName
        self.destinationRootEntityName = destinationRootEntityName
        self.foreignKeyColumnName = foreignKeyColumnName
        self.destinationEntityIDs = destinationEntityIDs
    }
}
