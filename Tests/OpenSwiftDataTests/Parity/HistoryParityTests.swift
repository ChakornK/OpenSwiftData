import Foundation
import OpenSwiftData
import Testing

@Model final class HistoryParityItem {
    var name: String
    var count: Int
    @Attribute(.preserveValueOnDeletion) var code: String
    init(name: String, count: Int, code: String) {
        self.name = name
        self.count = count
        self.code = code
    }
}

/// Persistent history, matching Apple's SwiftData.
@MainActor @Suite struct HistoryParityTests {
    typealias Transactions = HistoryDescriptor<DefaultHistoryTransaction>
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: HistoryParityItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// Saves an insert of two items, an update, an unchanged reassignment, a delete, and a transaction insert.
    private func recordHistory() throws -> (a: HistoryParityItem, b: HistoryParityItem) {
        context.author = "alice"
        let a = HistoryParityItem(name: "a", count: 1, code: "A")
        let b = HistoryParityItem(name: "b", count: 2, code: "B")
        context.insert(a)
        context.insert(b)
        try context.save()
        a.count = 5
        a.name = "a2"
        try context.save()
        a.count = 5
        try context.save()
        context.author = nil
        context.delete(b)
        try context.save()
        try context.transaction { context.insert(HistoryParityItem(name: "c", count: 3, code: "C")) }
        return (a, b)
    }

    @Test func `each save with changes records one transaction`() throws {
        #expect(try context.fetchHistory(Transactions()).isEmpty)
        let (a, b) = try recordHistory()
        let history = try context.fetchHistory(Transactions())
        #expect(history.count == 4)
        #expect(history.map(\.author) == ["alice", "alice", nil, nil])
        #expect(history.allSatisfy { $0.id == $0.transactionIdentifier })
        #expect(zip(history, history.dropFirst()).allSatisfy { $0.transactionIdentifier < $1.transactionIdentifier })
        #expect(zip(history, history.dropFirst()).allSatisfy { $0.token < $1.token })
        #expect(history.allSatisfy { $0.token.tokenValue?.count == 1 })
        #expect(!history[0].bundleIdentifier.isEmpty)
        #expect(!history[0].processIdentifier.isEmpty)

        guard case .insert = history[0].changes[0], history[0].changes.count == 2 else {
            Issue.record("expected two inserts")
            return
        }
        guard case .update(let update) = history[1].changes.first,
            let typed = update as? DefaultHistoryUpdate<HistoryParityItem>
        else {
            Issue.record("expected an update")
            return
        }
        #expect(typed.changedPersistentIdentifier == a.persistentModelID)
        #expect(Set(typed.updatedAttributes.map { $0 as AnyKeyPath }) == [\HistoryParityItem.count, \HistoryParityItem.name])

        guard case .delete(let delete) = history[2].changes.first,
            let deleted = delete as? DefaultHistoryDelete<HistoryParityItem>
        else {
            Issue.record("expected a delete")
            return
        }
        #expect(deleted.changedPersistentIdentifier == b.persistentModelID)
        #expect(deleted.tombstone[\HistoryParityItem.code] as? String == "B")
        #expect(deleted.tombstone[\HistoryParityItem.name] == nil)
        #expect(Array(deleted.tombstone).count == 1)
    }

    @Test func `descriptors filter, sort, and limit transactions`() throws {
        _ = try recordHistory()
        let all = try context.fetchHistory(Transactions())
        let second = all[1].token
        #expect(try context.fetchHistory(Transactions(predicate: #Predicate { $0.token > second })).count == 2)
        #expect(try context.fetchHistory(Transactions(predicate: #Predicate { $0.author == "alice" })).count == 2)
        var limited = Transactions()
        limited.fetchLimit = 2
        #expect(try context.fetchHistory(limited).map(\.transactionIdentifier) == all.prefix(2).map(\.transactionIdentifier))
        let reversed = try context.fetchHistory(
            Transactions(sortBy: [SortDescriptor(\.transactionIdentifier, order: .reverse)]))
        #expect(reversed.map(\.transactionIdentifier) == all.reversed().map(\.transactionIdentifier))
        #expect(Transactions().fetchLimit == 0)
    }

    @Test func `tokens encode their store and transaction`() throws {
        _ = try recordHistory()
        let token = try #require(try context.fetchHistory(Transactions()).first?.token)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(token)) as? [String: Any])
        let storeTokens = try #require(object["storeTokens"] as? [String: Int64])
        #expect(storeTokens.count == 1)
        #expect(try JSONDecoder().decode(DefaultHistoryToken.self, from: JSONEncoder().encode(token)) == token)
    }

    @Test func `deleting history expires tokens that refer to deleted transactions`() throws {
        _ = try recordHistory()
        let all = try context.fetchHistory(Transactions())
        let first = all[0].token
        let second = all[1].token
        try context.deleteHistory(Transactions(predicate: #Predicate { $0.token <= second }))
        #expect(try context.fetchHistory(Transactions()).count == 2)
        #expect(throws: SwiftDataError.historyTokenExpired) {
            try context.fetchHistory(Transactions(predicate: #Predicate { $0.token > second }))
        }
        #expect(throws: SwiftDataError.historyTokenExpired) {
            try context.fetchHistory(Transactions(predicate: #Predicate { $0.token > first }))
        }
        try context.deleteHistory(Transactions())
        #expect(try context.fetchHistory(Transactions()).isEmpty)
    }
}
