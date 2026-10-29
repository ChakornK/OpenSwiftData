import Foundation

/// Identifies the sequence position of one persisted history transaction.
public struct HistoryToken: Sendable, Hashable, Codable, Comparable {
    /// The transaction's monotonically increasing store identifier.
    public let rawValue: Int64

    /// Creates a token from its transaction identifier.
    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// Compares tokens by their transaction sequence identifiers.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Describes the kind of one persisted model change.
public enum HistoryChangeType: String, Sendable, Hashable, Codable {
    case insert
    case update
    case delete
}

/// Describes one model row change within a history transaction.
public struct HistoryChange: Sendable, Hashable, Codable {
    /// The change kind.
    public let type: HistoryChangeType
    /// The stable schema entity name.
    public let entityName: String
    /// The row's primary key in the store.
    public let primaryKey: Int64
    /// The order of this change within its transaction.
    public let ordinal: Int

    /// Creates a history change record.
    public init(type: HistoryChangeType, entityName: String, primaryKey: Int64, ordinal: Int) {
        self.type = type
        self.entityName = entityName
        self.primaryKey = primaryKey
        self.ordinal = ordinal
    }
}

/// Describes one committed group of model changes.
public struct HistoryTransaction: Sendable, Hashable, Codable {
    /// The position of this transaction in store history.
    public let token: HistoryToken
    /// The commit time.
    public let timestamp: Date
    /// The optional author associated with the context that saved the changes.
    public let author: String?
    /// The row changes committed by this transaction.
    public let changes: [HistoryChange]

    /// Creates a history transaction record.
    public init(token: HistoryToken, timestamp: Date, author: String?, changes: [HistoryChange]) {
        self.token = token
        self.timestamp = timestamp
        self.author = author
        self.changes = changes
    }
}

/// Filters history transactions by token and maximum result count.
public struct HistoryDescriptor: Sendable, Hashable {
    /// Returns transactions strictly newer than this token, or all transactions when nil.
    public let after: HistoryToken?
    /// The maximum number of transactions to return.
    public let fetchLimit: Int?

    /// Creates a history query descriptor.
    public init(after: HistoryToken? = nil, fetchLimit: Int? = nil) {
        self.after = after
        self.fetchLimit = fetchLimit.map { max(0, $0) }
    }
}
