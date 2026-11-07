/// An error produced by persistence operations.
///
/// Errors compare equal when they have the same code, regardless of their explanations, so a thrown error
/// matches the corresponding static constant: `catch SwiftDataError.unsupportedPredicate { ... }`.
public struct SwiftDataError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Identifies the kind of failure.
    package enum Code: String, Hashable, Sendable {
        case includePendingChangesWithBatchSize
        case unsupportedPredicate
        case unsupportedKeyPath
        case sortingPendingChangesWithIdentifiers
        case unsupportedSortDescriptor
        case duplicateConfiguration
        case configurationFileNameTooLong
        case configurationFileNameContainsInvalidCharacters
        case configurationSchemaNotFoundInContainerSchema
        case loadIssueModelContainer
        case modelValidationFailure
        case missingModelContext
        case backwardMigration
        case unknownSchema
        case historyTokenExpired
        case invalidTransactionFetchRequest
        case migrationUnsupported
        case optimisticLockConflict
        case unsupportedStore
        case duplicateEntityName
        case unsupportedSchemaProperty
        case unsupportedRelationshipElement
        case relationshipValueTypeMismatch
        case relationshipContextMismatch
        case relationshipGraphConflict
    }

    /// The kind of failure.
    package let code: Code
    /// Additional detail about this occurrence, when available.
    package let explanation: String?

    package init(_ code: Code, explanation: String? = nil) {
        self.code = code
        self.explanation = explanation
    }

    /// Returns whether both errors have the same code.
    public static func == (lhs: SwiftDataError, rhs: SwiftDataError) -> Bool { lhs.code == rhs.code }

    /// Hashes the error code.
    public func hash(into hasher: inout Hasher) { hasher.combine(code) }

    /// Returns whether `rhs` is a `SwiftDataError` with the same code as `lhs`.
    public static func ~= (lhs: SwiftDataError, rhs: any Error) -> Bool {
        (rhs as? SwiftDataError).map { $0.code == lhs.code } ?? false
    }

    /// Describes the error in SwiftData's format, such as
    /// `SwiftDataError(_error: SwiftData.SwiftDataError._Error.unsupportedPredicate, _explanation: nil)`.
    public var description: String {
        let explanation = self.explanation.map { "Optional(\($0.debugDescription))" } ?? "nil"
        return "SwiftDataError(_error: SwiftData.SwiftDataError._Error.\(code.rawValue), _explanation: \(explanation))"
    }

    /// A fetch requested pending changes together with a batch size.
    public static let includePendingChangesWithBatchSize = SwiftDataError(.includePendingChangesWithBatchSize)
    /// A predicate cannot be evaluated.
    public static let unsupportedPredicate = SwiftDataError(.unsupportedPredicate)
    /// A key path does not name a persisted property.
    public static let unsupportedKeyPath = SwiftDataError(.unsupportedKeyPath)
    /// An identifier fetch requested sorting while including pending changes.
    public static let sortingPendingChangesWithIdentifiers = SwiftDataError(.sortingPendingChangesWithIdentifiers)
    /// A sort descriptor cannot be applied.
    public static let unsupportedSortDescriptor = SwiftDataError(.unsupportedSortDescriptor)
    /// A container received more than one configuration with the same name.
    public static let duplicateConfiguration = SwiftDataError(.duplicateConfiguration)
    /// A configuration name is too long to form a store file name.
    public static let configurationFileNameTooLong = SwiftDataError(.configurationFileNameTooLong)
    /// A configuration name contains characters that cannot appear in a store file name.
    public static let configurationFileNameContainsInvalidCharacters = SwiftDataError(
        .configurationFileNameContainsInvalidCharacters)
    /// A configuration's schema names entities that the container's schema lacks.
    public static let configurationSchemaNotFoundInContainerSchema = SwiftDataError(
        .configurationSchemaNotFoundInContainerSchema)
    /// A container could not load one of its stores.
    public static let loadIssueModelContainer = SwiftDataError(.loadIssueModelContainer)
    /// A model failed validation while saving.
    public static let modelValidationFailure = SwiftDataError(.modelValidationFailure)
    /// An operation required a model context that is unavailable.
    public static let missingModelContext = SwiftDataError(.missingModelContext)
    /// A store was created by a newer schema version than the container's.
    public static let backwardMigration = SwiftDataError(.backwardMigration)
    /// A store's schema matches no known schema version.
    public static let unknownSchema = SwiftDataError(.unknownSchema)
    /// A history token refers to history that has been deleted.
    public static let historyTokenExpired = SwiftDataError(.historyTokenExpired)
    /// A history fetch request is invalid.
    public static let invalidTransactionFetchRequest = SwiftDataError(.invalidTransactionFetchRequest)
    /// A schema change cannot be migrated automatically.
    public static let migrationUnsupported = SwiftDataError(.migrationUnsupported)
    /// A saved model was changed by another context since it was fetched.
    public static let optimisticLockConflict = SwiftDataError(.optimisticLockConflict)
    /// A persistence operation is unavailable for the configured store.
    public static let unsupportedStore = SwiftDataError(.unsupportedStore)
    /// Multiple model types have the same unqualified entity name.
    public static let duplicateEntityName = SwiftDataError(.duplicateEntityName)
    /// A model property cannot be represented in the schema.
    public static let unsupportedSchemaProperty = SwiftDataError(.unsupportedSchemaProperty)
    /// A relationship collection contains optional model elements.
    public static let unsupportedRelationshipElement = SwiftDataError(.unsupportedRelationshipElement)
    /// A relationship adapter received a value with an incompatible type.
    public static let relationshipValueTypeMismatch = SwiftDataError(.relationshipValueTypeMismatch)
    /// A relationship endpoint belongs to a different model context.
    public static let relationshipContextMismatch = SwiftDataError(.relationshipContextMismatch)
    /// A relationship mutation would leave the object graph in a conflicting state.
    public static let relationshipGraphConflict = SwiftDataError(.relationshipGraphConflict)

    /// A predicate cannot be evaluated, with detail.
    public static func unsupportedPredicate(_ explanation: String) -> SwiftDataError {
        SwiftDataError(.unsupportedPredicate, explanation: explanation)
    }
    /// A schema change cannot be migrated automatically, with detail.
    public static func migrationUnsupported(_ explanation: String) -> SwiftDataError {
        SwiftDataError(.migrationUnsupported, explanation: explanation)
    }
    /// A persistence operation is unavailable, with detail.
    public static func unsupportedStore(_ explanation: String) -> SwiftDataError {
        SwiftDataError(.unsupportedStore, explanation: explanation)
    }
    /// Multiple model types share an entity name, with detail.
    public static func duplicateEntityName(_ explanation: String) -> SwiftDataError {
        SwiftDataError(.duplicateEntityName, explanation: explanation)
    }
    /// A model property cannot be represented in the schema, with detail.
    public static func unsupportedSchemaProperty(_ explanation: String) -> SwiftDataError {
        SwiftDataError(.unsupportedSchemaProperty, explanation: explanation)
    }
    /// A relationship collection contains optional model elements, with detail.
    public static func unsupportedRelationshipElement(_ explanation: String) -> SwiftDataError {
        SwiftDataError(.unsupportedRelationshipElement, explanation: explanation)
    }
    /// A relationship adapter received a value of type `actual` where `expected` was required.
    public static func relationshipValueTypeMismatch(property: String, expected: String, actual: String)
        -> SwiftDataError
    {
        SwiftDataError(
            .relationshipValueTypeMismatch,
            explanation: "Relationship '\(property)' expected '\(expected)' but received '\(actual)'.")
    }
    /// A relationship mutation would leave the object graph in a conflicting state, with detail.
    public static func relationshipGraphConflict(_ explanation: String) -> SwiftDataError {
        SwiftDataError(.relationshipGraphConflict, explanation: explanation)
    }
}
