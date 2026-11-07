/// Names internal properties synthesized for runtime predicate plans.
package enum PredicatePlanProperty {
    /// The pending model's complete persistent identifier.
    package static let persistentIdentifier = "__osd_persistent_identifier"
}

/// A storage-independent predicate plan used by SQL and in-memory evaluation.
public indirect enum PredicatePlan: Sendable, Equatable {
    case conjunction(PredicatePlan, PredicatePlan)
    case disjunction(PredicatePlan, PredicatePlan)
    case negation(PredicatePlan)
    case comparison(PredicateComparisonOperator, PredicatePlan, PredicatePlan)
    case decimalComparison(PredicateComparisonOperator, PredicatePlan, PredicatePlan)
    case arithmetic(PredicateArithmeticOperator, PredicatePlan, PredicatePlan)
    case boundedArithmetic(
        PredicateArithmeticOperator, PredicatePlan, PredicatePlan, integerWidth: PredicateIntegerWidth)
    case unaryNegation(PredicatePlan, integerWidth: PredicateIntegerWidth?)
    case floatArithmetic(PredicateArithmeticOperator, PredicatePlan, PredicatePlan)
    case floatNegation(PredicatePlan)
    case isNull(PredicatePlan, negated: Bool)
    case property(String)
    case value(StoredValue)
    case coalesce(PredicatePlan, PredicatePlan)
    case conditional(PredicatePlan, PredicatePlan, PredicatePlan)
    case localizedStandardContains(PredicatePlan, PredicatePlan)
    case stringContains(PredicatePlan, PredicatePlan)
    case stringStartsWith(PredicatePlan, PredicatePlan)
    /// The number of `Character`s in a string operand.
    case stringCount(PredicatePlan)
    case collectionContains(String, String, PredicatePlan)
    case collectionAllEqual(String, String, PredicatePlan)
    case collectionAllNil(String)
    case collectionAllCompare(String, String, PredicateComparisonOperator, PredicatePlan)
    case codableCollectionIsEmpty(String)
    case codableCollectionCount(String)
    /// A JSON member path inside a Codable attribute, such as `address.city`.
    case codableMember(String, [String])
    case relationshipContains(String, PredicatePlan)
    case collectionCount(String)
}

/// A checked numeric operation supported by SQL and pending predicate evaluation.
public enum PredicateArithmeticOperator: Sendable, Equatable {
    case add
    case subtract
    case multiply
    case divide
    case remainder
}

/// The integer width used to validate predicate arithmetic.
///
/// Raw values are stable runtime tags; use `bitWidth` to inspect the integer width.
public enum PredicateIntegerWidth: Int, Sendable, Equatable, Codable {
    /// An 8-bit signed integer width.
    case int8 = 8
    /// A 16-bit signed integer width.
    case int16 = 16
    /// A 32-bit signed integer width.
    case int32 = 32
    /// A 64-bit signed integer width.
    case int64 = 64
    /// An 8-bit unsigned integer width.
    case uint8 = 108
    /// A 16-bit unsigned integer width.
    case uint16 = 116
    /// A 32-bit unsigned integer width.
    case uint32 = 132

    /// Whether this width represents a signed integer type.
    public var isSigned: Bool {
        switch self {
        case .int8, .int16, .int32, .int64: true
        case .uint8, .uint16, .uint32: false
        }
    }

    /// The number of bits in this integer type.
    public var bitWidth: Int {
        switch self {
        case .int8, .uint8: 8
        case .int16, .uint16: 16
        case .int32, .uint32: 32
        case .int64: 64
        }
    }

    /// The minimum value representable at this width.
    public var minimumValue: Int64 {
        switch self {
        case .int8: Int64(Int8.min)
        case .int16: Int64(Int16.min)
        case .int32: Int64(Int32.min)
        case .int64: Int64.min
        case .uint8, .uint16, .uint32: 0
        }
    }

    /// The maximum value representable at this width.
    public var maximumValue: Int64 {
        switch self {
        case .int8: Int64(Int8.max)
        case .int16: Int64(Int16.max)
        case .int32: Int64(Int32.max)
        case .int64: Int64.max
        case .uint8: Int64(UInt8.max)
        case .uint16: Int64(UInt16.max)
        case .uint32: Int64(UInt32.max)
        }
    }
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

/// A resolved relationship path used by runtime predicate compilers.
public struct RuntimePredicateRelationship: Sendable, Equatable {
    /// The entity that declares the relationship.
    public let ownerEntityName: String
    /// The relationship property name.
    public let propertyName: String
    /// The requested destination entity.
    public let destinationEntityName: String
    /// The root entity that stores destination rows.
    public let destinationRootEntityName: String
    /// The physical foreign-key column for a to-one or inverse one-to-many relationship.
    public let foreignKeyColumnName: String
    /// Whether a queried to-many relationship is stored as a foreign key on each destination row.
    public let storesForeignKeyOnDestination: Bool
    /// Whether the relationship contains multiple destinations.
    public let isToMany: Bool
    /// Whether a scalar inverse traversal finds its endpoint through a foreign key on the inverse owner.
    public let queriesInverseToOne: Bool
    /// The root entity storing the inverse to-one foreign key.
    public let inverseOwnerRootEntityName: String?
    /// Concrete entity identifiers allowed by the inverse owner's inheritance subtree.
    public let inverseOwnerEntityIDs: [Int]
    /// The join table used for direct or many-to-many collection relationships.
    public let joinTableName: String?
    /// The owner primary-key column in the join table.
    public let ownerJoinColumnName: String
    /// The destination primary-key column in the join table.
    public let destinationJoinColumnName: String
    /// Concrete entity identifiers allowed by the destination entity's inheritance subtree.
    public let destinationEntityIDs: [Int]

    /// Creates a resolved relationship path.
    public init(
        ownerEntityName: String,
        propertyName: String,
        destinationEntityName: String,
        destinationRootEntityName: String,
        foreignKeyColumnName: String,
        destinationEntityIDs: [Int],
        isToMany: Bool = false,
        storesForeignKeyOnDestination: Bool = false,
        queriesInverseToOne: Bool = false,
        inverseOwnerRootEntityName: String? = nil,
        inverseOwnerEntityIDs: [Int] = [],
        joinTableName: String? = nil,
        ownerJoinColumnName: String = "Z_A",
        destinationJoinColumnName: String = "Z_B"
    ) {
        self.ownerEntityName = ownerEntityName
        self.propertyName = propertyName
        self.destinationEntityName = destinationEntityName
        self.destinationRootEntityName = destinationRootEntityName
        self.foreignKeyColumnName = foreignKeyColumnName
        self.storesForeignKeyOnDestination = storesForeignKeyOnDestination
        self.destinationEntityIDs = destinationEntityIDs
        self.isToMany = isToMany
        self.queriesInverseToOne = queriesInverseToOne
        self.inverseOwnerRootEntityName = inverseOwnerRootEntityName
        self.inverseOwnerEntityIDs = inverseOwnerEntityIDs
        self.joinTableName = joinTableName
        self.ownerJoinColumnName = ownerJoinColumnName
        self.destinationJoinColumnName = destinationJoinColumnName
    }
}
