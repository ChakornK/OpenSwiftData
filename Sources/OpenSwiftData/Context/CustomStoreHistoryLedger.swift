import Foundation

/// In-memory history ledger for containers backed by a custom data store.
///
/// Custom stores have no runtime store to persist history rows, so transactions reported through
/// `DataStoreSaveChangesResult.historyToken` are held here for `fetchHistory` and `deleteHistory`.
final class CustomStoreHistoryLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var transactions: [StoredHistoryTransaction] = []
    private var nextIdentifier: Int64 = 1

    /// Appends a transaction and returns its assigned identifier.
    ///
    /// When the store reported a token value, that value is recorded inside the token so history
    /// predicates referencing it resolve; the ledger's own identifier stays monotonic.
    func lockedAppend(
        changes: [StoredHistoryChange], author: String?,
        storeIdentifier: String, reportedToken: any HistoryToken
    ) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let identifier = nextIdentifier
        nextIdentifier += 1
        transactions.append(
            StoredHistoryTransaction(
                id: identifier, timestamp: Date(), author: author,
                bundleIdentifier: HistoryWriter.bundleIdentifier,
                processIdentifier: HistoryWriter.processIdentifier, changes: changes))
        return identifier
    }

    func lockedTransactions() -> [StoredHistoryTransaction] {
        lock.lock()
        defer { lock.unlock() }
        return transactions
    }

    func lockedLatestIdentifier() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return nextIdentifier - 1
    }

    func lockedRemove(identifiers: [Int64]) {
        lock.lock()
        defer { lock.unlock() }
        let removed = Set(identifiers)
        transactions.removeAll { removed.contains($0.id) }
    }
}
