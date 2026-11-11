import Foundation

/// Apple's history-providing protocol, reimplemented as a stub for
/// API-surface coverage. OpenSwiftData surfaces history via
/// ``ModelContext``/``HistoryDescriptor`` and does not require stores to
/// conform to a `HistoryProviding` protocol.
public protocol HistoryProviding {
    /// The transaction type this provider records.
    associatedtype HistoryType: HistoryTransaction

    /// The history transaction type, accessible without an instance.
    static var historyType: HistoryType.Type { get }

    /// Fetches transactions matching the descriptor.
    func fetchHistory(_ descriptor: HistoryDescriptor<HistoryType>) throws -> [HistoryType]

    /// Deletes transactions matching the descriptor.
    func deleteHistory(_ descriptor: HistoryDescriptor<HistoryType>) throws
}

/// Default no-op implementations so conforming types (e.g. ``DefaultStore``)
/// do not need to implement `fetchHistory`/`deleteHistory` for the coverage stub.
public extension HistoryProviding {
    func fetchHistory(_ descriptor: HistoryDescriptor<HistoryType>) throws -> [HistoryType] { [] }
    func deleteHistory(_ descriptor: HistoryDescriptor<HistoryType>) throws {}
}
