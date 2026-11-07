import Foundation

/// Describes the kind of one persisted model change.
public enum HistoryChangeType: String, Sendable, Hashable, Codable {
    case insert
    case update
    case delete
}

/// One model row change as stored in a history transaction.
package struct StoredHistoryChange: Sendable {
    package let type: HistoryChangeType
    package let entityName: String
    package let primaryKey: Int64
    package let updatedAttributes: [String]
    package let tombstone: [String: StoredValue]
}

/// One committed group of model changes as stored.
package struct StoredHistoryTransaction: Sendable {
    package let id: Int64
    package let timestamp: Date
    package let author: String?
    package let bundleIdentifier: String
    package let processIdentifier: String
    package let changes: [StoredHistoryChange]
}

/// The JSON payload stored with each history change.
package struct StoredHistoryChangeDetails: Codable {
    package var updatedAttributes: [String] = []
    package var tombstone: [String: StoredValue] = [:]

    package init(updatedAttributes: [String] = [], tombstone: [String: StoredValue] = [:]) {
        self.updatedAttributes = updatedAttributes
        self.tombstone = tombstone
    }
}

/// Identifies the process that writes history transactions.
package enum HistoryWriter {
    /// The writing app's bundle identifier, or its process name when it has none.
    package static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    }

    /// The writing process's identifier.
    package static var processIdentifier: String { String(ProcessInfo.processInfo.processIdentifier) }
}
