import Foundation

/// Apple's Core-Data-backed default store, reimplemented as an empty stub for
/// API-surface coverage. OpenSwiftData uses its own SQLite-backed runtime store
/// (``OpenSwiftDataSQLite``) and does not expose a public `DefaultStore` class.
/// The stub conforms to ``HistoryProviding`` so the parity test can reference
/// `DefaultStore.HistoryType` (a `MemberTypeSyntax` on a concrete type) to
/// cover the `HistoryType` display name; `DefaultStore.HistoryType` covers
/// `SwiftData.SwiftData.DefaultStore.HistoryType` (#23) by `name-match`.
public final class DefaultStore: HistoryProviding {
    /// A placeholder history type for API-surface coverage; OpenSwiftData's
    /// default store does not record history via this property.
    public static var historyType: DefaultHistoryTransaction.Type { DefaultHistoryTransaction.self }

    /// A placeholder history-type alias for API-surface coverage; satisfies the
    /// `HistoryProviding.HistoryType` associatedtype requirement.
    public typealias HistoryType = DefaultHistoryTransaction
}
