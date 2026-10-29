import Foundation

extension ModelContext {
    /// Notification posted immediately before a context begins saving pending changes.
    public nonisolated static let willSave = Notification.Name("ModelContext.willSave")

    /// Notification posted after a context successfully commits pending changes.
    public nonisolated static let didSave = Notification.Name("ModelContext.didSave")

    /// Keys for identifier arrays included in save notification user info.
    public enum NotificationKey: String, Sendable {
        case insertedIdentifiers
        case updatedIdentifiers
        case deletedIdentifiers
    }
}
