import Foundation
import XCTest
@testable import OpenSwiftData

@Model
final class HistoryFixture {
    @Attribute(.unique) var name: String
    init(name: String) { self.name = name }
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
        let inserted = try XCTUnwrap(context.fetchHistory().first)
        XCTAssertEqual(inserted.author, "seed")
        XCTAssertEqual(
            inserted.changes,
            [
                HistoryChange(
                    type: .insert, entityName: "HistoryFixture",
                    primaryKey: try XCTUnwrap(model.persistentModelID.primaryKey), ordinal: 0)
            ])

        context.historyAuthor = "editor"
        try context.transaction {
            model.name = "intermediate"
            try context.save()
            model.name = "updated"
        }
        let update = try XCTUnwrap(context.fetchHistory(HistoryDescriptor(after: inserted.token)).first)
        XCTAssertEqual(update.author, "editor")
        XCTAssertEqual(update.changes.first?.type, .update)

        context.historyAuthor = "cleanup"
        context.delete(model)
        try context.save()
        let delete = try XCTUnwrap(context.fetchHistory(HistoryDescriptor(after: update.token)).first)
        XCTAssertEqual(delete.author, "cleanup")
        XCTAssertEqual(delete.changes.first?.type, .delete)

        XCTAssertEqual(try context.fetchHistory(HistoryDescriptor(fetchLimit: 1)).count, 1)
        XCTAssertEqual(try context.fetchHistory(HistoryDescriptor(fetchLimit: 0)), [])
        XCTAssertEqual(try context.deleteHistory(before: update.token), 2)
        XCTAssertEqual(try context.fetchHistory().map(\.token), [delete.token])

        let reopened = try ModelContainer(
            for: HistoryFixture.self,
            configurations: .sqliteFile("history-reopened", url: directory.appendingPathComponent("store.sqlite")))
        XCTAssertEqual(try reopened.makeContext().fetchHistory().map(\.token), [delete.token])
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
        XCTAssertEqual(try context.fetchHistory(), [])
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
        let transactions = try context.fetchHistory()
        XCTAssertEqual(transactions.map { $0.changes.first?.type }, [.insert, .update])
        XCTAssertEqual(try context.fetch(FetchDescriptor<HistoryFixture>()).count, 1)
    }
}
