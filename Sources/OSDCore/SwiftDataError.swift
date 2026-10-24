/// An error produced by OpenSwiftData persistence operations.
public enum SwiftDataError: Error, Sendable, Equatable {
    /// The requested predicate cannot be evaluated by OpenSwiftData.
    case unsupportedPredicate(String)
    /// The requested schema change cannot be migrated automatically.
    case migrationUnsupported(String)
    /// A saved model was changed by another context since it was fetched.
    case optimisticLockConflict
}
