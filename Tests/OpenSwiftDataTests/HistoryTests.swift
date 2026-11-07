import Foundation
import XCTest
@testable import OpenSwiftData

@Model
final class HistoryFixture {
    @Attribute(.unique) var name: String
    init(name: String) { self.name = name }
}

private typealias Transactions = HistoryDescriptor<DefaultHistoryTransaction>

private extension HistoryChange {
    var kind: HistoryChangeType {
        switch self {
        case .insert: .insert
        case .update: .update
        case .delete: .delete
        }
    }
}

private extension ModelContext {
    func allHistory() throws -> [DefaultHistoryTransaction] { try fetchHistory(Transactions()) }

    func history(after token: DefaultHistoryToken) throws -> [DefaultHistoryTransaction] {
        try fetchHistory(Transactions(predicate: #Predicate { $0.token > token }))
    }
}

final class HistoryTests: XCTestCase {
    @MainActor
    func testHistoryRecordsInsertUpdateDeleteAndPrunesByToken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(
            for: HistoryFixture.self,
            configurations: .sqliteFile("history", url: directory.appendingPathComponent("store.sqlite")))
        let context = container.mainContext

        context.historyAuthor = "seed"
        let model = HistoryFixture(name: "first")
        context.insert(model)
        try context.save()
        let inserted = try XCTUnwrap(context.allHistory().first)
        XCTAssertEqual(inserted.author, "seed")
        XCTAssertEqual(inserted.changes.map(\.kind), [.insert])
        XCTAssertEqual(inserted.changes.map(\.changedPersistentIdentifier), [model.persistentModelID])

        context.historyAuthor = "editor"
        try context.transaction {
            model.name = "intermediate"
            try context.save()
            model.name = "updated"
        }
        let update = try XCTUnwrap(context.history(after: inserted.token).first)
        XCTAssertEqual(update.author, "editor")
        XCTAssertEqual(update.changes.first?.kind, .update)

        context.historyAuthor = "cleanup"
        context.delete(model)
        try context.save()
        let delete = try XCTUnwrap(context.history(after: update.token).first)
        XCTAssertEqual(delete.author, "cleanup")
        XCTAssertEqual(delete.changes.first?.kind, .delete)

        var limited = Transactions()
        limited.fetchLimit = 1
        XCTAssertEqual(try context.fetchHistory(limited).count, 1)
        let updateToken = update.token
        try context.deleteHistory(Transactions(predicate: #Predicate { $0.token <= updateToken }))
        XCTAssertEqual(try context.allHistory().map(\.token), [delete.token])

        let reopened = try ModelContainer(
            for: HistoryFixture.self,
            configurations: .sqliteFile("history-reopened", url: directory.appendingPathComponent("store.sqlite")))
        XCTAssertEqual(
            try reopened.makeContext().allHistory().map(\.transactionIdentifier), [delete.transactionIdentifier])
    }

    @MainActor
    func testFailedModelWriteDoesNotCommitHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataHistoryRollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(
            for: HistoryFixture.self,
            configurations: .sqliteFile("history-rollback", url: directory.appendingPathComponent("store.sqlite")))
        let context = container.mainContext
        try container.store?.write { connection in
            try connection.execute(
                "CREATE TRIGGER reject_history_insert BEFORE INSERT ON ZHISTORYFIXTURE "
                    + "BEGIN SELECT RAISE(ABORT, 'reject model write'); END;",
                arguments: [])
        }
        context.insert(HistoryFixture(name: "rejected"))
        XCTAssertThrowsError(try context.save())
        XCTAssertEqual(try context.allHistory(), [])
    }

    @MainActor
    func testUniqueInsertReplacementIsRecordedAsUpdate() throws {
        let container = try ModelContainer(
            for: HistoryFixture.self, configurations: .sqliteMemory("history-upsert"))
        let context = container.mainContext
        context.insert(HistoryFixture(name: "same"))
        try context.save()
        let replacement = HistoryFixture(name: "same")
        context.insert(replacement)
        try context.save()
        let transactions = try context.allHistory()
        XCTAssertEqual(transactions.map { $0.changes.first?.kind }, [.insert, .update])
        XCTAssertEqual(try context.fetch(FetchDescriptor<HistoryFixture>()).count, 1)
    }
}
