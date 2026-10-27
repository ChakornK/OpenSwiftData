import Foundation
import XCTest
import OSDCore
import GRDB
@testable import OSDStorage

final class SQLiteDriverTests: XCTestCase {
    func testMemoryDriverMapsAndBindsEveryStoredValue() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "mapping"))
        defer { try? driver.close() }

        let expected: [StoredValue] = [
            .null,
            .int(Int64.min),
            .double(3.25),
            .text("O'Brien; SELECT 1"),
            .blob([]),
            .blob([0, 1, 127, 255]),
        ]

        let actual = try driver.write { connection -> [StoredValue] in
            try connection.execute("CREATE TABLE values_table (a, b, c, d, e, f)")
            try connection.execute("INSERT INTO values_table VALUES (?, ?, ?, ?, ?, ?)", expected)
            XCTAssertEqual(connection.lastInsertRowID(), 1)
            XCTAssertEqual(connection.changesCount(), 1)
            return try connection.rows("SELECT a, b, c, d, e, f FROM values_table")
                .first ?? []
        }

        XCTAssertEqual(actual, expected)
    }

    func testReadWriteReturnValuesAndErrors() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "results"))
        defer { try? driver.close() }

        let writeResult = try driver.write { connection -> String in
            try connection.execute("CREATE TABLE items (value TEXT)")
            try connection.execute("INSERT INTO items VALUES (?)", [.text("kept")])
            return "written"
        }
        XCTAssertEqual(writeResult, "written")

        let readResult = try driver.read { connection in
            try connection.rows("SELECT value FROM items").first
        }
        XCTAssertEqual(readResult, [.text("kept")])

        XCTAssertThrowsError(
            try driver.read { _ -> Void in
                throw TestFailure.expected
            }
        ) { error in
            XCTAssertTrue(error is TestFailure)
        }
        XCTAssertThrowsError(
            try driver.write { _ -> Void in
                throw TestFailure.expected
            }
        ) { error in
            XCTAssertTrue(error is TestFailure)
        }
    }

    func testWriteRollsBackWhenClosureThrows() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "rollback"))
        defer { try? driver.close() }

        try driver.write { connection in
            try connection.execute("CREATE TABLE items (value INTEGER)")
        }
        XCTAssertThrowsError(
            try driver.write { connection in
                try connection.execute("INSERT INTO items VALUES (1)")
                throw TestFailure.expected
            })

        let rows = try driver.read { try $0.rows("SELECT value FROM items") }
        XCTAssertTrue(rows.isEmpty)
    }

    func testFileDriverPersistsAndCleansUpTemporaryDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OSDStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("store.sqlite")
        let driver = try GRDBSQLiteDriver(location: .file(databaseURL))
        try driver.write { connection in
            try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)")
            try connection.execute("INSERT INTO items (value) VALUES (?)", [.text("persisted")])
            XCTAssertEqual(connection.lastInsertRowID(), 1)
        }
        try driver.close()

        let reopened = try GRDBSQLiteDriver(location: .file(databaseURL))
        defer { try? reopened.close() }
        let rows = try reopened.read { try $0.rows("SELECT value FROM items") }
        XCTAssertEqual(rows, [[.text("persisted")]])
    }

    func testFileDriverConfiguresWALAndConnectionPragmas() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OSDStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let driver = try GRDBSQLiteDriver(location: .file(directory.appendingPathComponent("store.sqlite")))
        defer { try? driver.close() }

        try driver.write { connection in
            XCTAssertEqual(try connection.rows("PRAGMA journal_mode").first, [.text("wal")])
            XCTAssertEqual(try connection.rows("PRAGMA synchronous").first, [.int(1)])
            XCTAssertEqual(try connection.rows("PRAGMA foreign_keys").first, [.int(0)])
            XCTAssertEqual(try connection.rows("PRAGMA busy_timeout").first, [.int(5000)])
            XCTAssertEqual(try connection.rows("PRAGMA mmap_size").first, [.int(268435456)])
        }

        try driver.read { connection in
            XCTAssertThrowsError(try connection.execute("CREATE TABLE read_only_probe (value INTEGER)"))
        }

        try driver.write { connection in
            try connection.execute("CREATE TABLE writable_probe (value INTEGER)")
            try connection.execute("INSERT INTO writable_probe VALUES (1)")
        }
        XCTAssertEqual(try driver.read { try $0.rows("SELECT value FROM writable_probe") }, [[.int(1)]])
    }

    func testMemoryDriverUsesSingleQueueWithoutWAL() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "configuration"))
        defer { try? driver.close() }

        try driver.write { connection in
            XCTAssertEqual(try connection.rows("PRAGMA journal_mode").first, [.text("memory")])
            XCTAssertEqual(try connection.rows("PRAGMA synchronous").first, [.int(1)])
            XCTAssertEqual(try connection.rows("PRAGMA foreign_keys").first, [.int(0)])
            XCTAssertEqual(try connection.rows("PRAGMA busy_timeout").first, [.int(5000)])
        }

        try driver.read { connection in
            XCTAssertThrowsError(try connection.execute("CREATE TABLE read_only_probe (value INTEGER)"))
        }

        try driver.write { connection in
            try connection.execute("CREATE TABLE writable_probe (value INTEGER)")
            try connection.execute("INSERT INTO writable_probe VALUES (1)")
        }
        XCTAssertEqual(try driver.read { try $0.rows("SELECT value FROM writable_probe") }, [[.int(1)]])
    }

    func testRowsRebindArgumentsThroughCachedQueryPath() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "statement-cache"))
        defer { try? driver.close() }

        try driver.write { connection in
            try connection.execute("CREATE TABLE items (value INTEGER)")
            try connection.execute("INSERT INTO items VALUES (1), (2)")
        }

        let results = try driver.read { connection in
            let first = try connection.rows("SELECT value FROM items WHERE value = ?", [.int(1)])
            let second = try connection.rows("SELECT value FROM items WHERE value = ?", [.int(2)])
            let missing = try connection.rows("SELECT value FROM items WHERE value = ?", [.int(3)])
            return (first, second, missing)
        }

        XCTAssertEqual(results.0, [[.int(1)]])
        XCTAssertEqual(results.1, [[.int(2)]])
        XCTAssertEqual(results.2, [])
    }
}

private enum TestFailure: Error {
    case expected
}
