import Foundation
import XCTest
import OSDCore
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
}

private enum TestFailure: Error {
    case expected
}
