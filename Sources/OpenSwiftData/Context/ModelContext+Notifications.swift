import Foundation

extension ModelContext {
    /// Notification posted immediately before a context begins saving pending changes.
    public nonisolated static let willSave = Notification.Name("ModelContextWillSave")

    /// Notification posted after a context successfully commits pending changes.
    public nonisolated static let didSave = Notification.Name("ModelContextDidSave")

    /// Keys for values included in save notification user info.
    public enum NotificationKey: String, Sendable {
        /// The query generation token of the save.
        case queryGeneration = "newQueryGeneration"
        /// Identifiers invalidated wholesale, such as by a batch delete.
        case invalidatedAllIdentifiers = "invalidatedAll"
        /// Identifiers of inserted models.
        case insertedIdentifiers = "inserted"
        /// Identifiers of updated models.
        case updatedIdentifiers = "updated"
        /// Identifiers of deleted models.
        case deletedIdentifiers = "deleted"
    }
}

// On Linux, `NSObject` already makes contexts equatable by identity.
#if canImport(ObjectiveC)
    extension ModelContext: Equatable {
        /// Returns whether both operands are the same context instance.
        public nonisolated static func == (lhs: ModelContext, rhs: ModelContext) -> Bool { lhs === rhs }
    }
#endif

/// Identifies one model context's edits to a data store.
public struct EditingState: Identifiable, Sendable {
    /// The identifier of the editing context.
    public let id: UUID
    /// The author recorded with the context's history transactions.
    public var author: String?
}
