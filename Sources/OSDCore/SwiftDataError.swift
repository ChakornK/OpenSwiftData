/// An error produced by OpenSwiftData persistence operations.
public enum SwiftDataError: Error, Sendable, Equatable {
    /// The requested predicate cannot be evaluated by OpenSwiftData.
    case unsupportedPredicate(String)
    /// The requested schema change cannot be migrated automatically.
    case migrationUnsupported(String)
    /// A saved model was changed by another context since it was fetched.
    case optimisticLockConflict
    /// The requested persistence operation is unavailable in this implementation.
    case unsupportedStore(String)
    /// Multiple model types have the same unqualified entity name.
    case duplicateEntityName(String)
    /// A model property cannot be represented in the inferred schema.
    case unsupportedSchemaProperty(String)
    /// A relationship collection contains optional model elements.
    case unsupportedRelationshipElement(String)
    /// A relationship adapter received a value with an incompatible type.
    case relationshipValueTypeMismatch(property: String, expected: String, actual: String)
}
