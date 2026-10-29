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

    func testCheckedIntegerArithmeticFunctionsMatchSwiftSemantics() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "checked-integer-arithmetic"))
        defer { try? driver.close() }

        let rows = try driver.read { connection in
            try connection.rows(
                "SELECT osd_int_add(7, 3), osd_int_subtract(7, 10), osd_int_multiply(7, 3), "
                    + "osd_int_divide(-7, 2), osd_int_remainder(-7, 2), osd_int_remainder(7, -3), "
                    + "osd_int_divide(7, 0), osd_int_multiply(9223372036854775807, 2), "
                    + "osd_int_add(9223372036854775807, 1), osd_int_subtract(-9223372036854775808, 1), "
                    + "osd_int_divide(-9223372036854775808, -1), "
                    + "osd_int_remainder(-9223372036854775808, -1)")
        }
        XCTAssertEqual(
            rows,
            [[.int(10), .int(-3), .int(21), .int(-3), .int(-1), .int(1), .null, .null, .null, .null, .null, .null]])
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

    func testExternalDataRollbackRemovesPublishedSidecar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OSDExternalRollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("store.sqlite")
        let externalStorage = try XCTUnwrap(ExternalStorage(databaseURL: databaseURL))
        let pending = PendingExternalFiles()
        let driver = try GRDBSQLiteDriver(location: .file(databaseURL))
        try driver.write { connection in
            try connection.execute("CREATE TABLE ZRECORD (Z_PK INTEGER PRIMARY KEY, Z_PAYLOAD BLOB)")
        }
        XCTAssertThrowsError(
            try driver.write { connection in
                let externalValue = try externalStorage.externalized(
                    Array(repeating: UInt8(1), count: ExternalStorage.threshold + 1), pending: pending)
                try connection.execute(
                    "INSERT INTO ZRECORD (Z_PAYLOAD) VALUES (?)",
                    [.blob(externalValue)])
                throw TestFailure.expected
            })
        let sidecarDirectory = directory.appendingPathComponent("store.sqlite.external", isDirectory: true)
        externalStorage.rollback(pending)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sidecarDirectory.path), [])
        XCTAssertEqual(try driver.read { try $0.rows("SELECT Z_PAYLOAD FROM ZRECORD") }, [])
        try driver.close()
    }

    func testExternalStorageAppliesExactThresholdAndRoundTripsFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OSDExternalThreshold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("store.sqlite")
        let externalStorage = try XCTUnwrap(ExternalStorage(databaseURL: databaseURL))
        let pending = PendingExternalFiles()
        let boundary = Array(repeating: UInt8(7), count: ExternalStorage.threshold)
        let large = Array(repeating: UInt8(9), count: ExternalStorage.threshold + 1)

        let inline = try externalStorage.externalized(boundary, pending: pending)
        XCTAssertEqual(inline, boundary)
        let reference = try externalStorage.externalized(large, pending: pending)
        XCTAssertNotEqual(reference, large)
        let fileName = "data-\(SHA256.hash(large).map { String(format: "%02x", $0) }.joined()).blob"
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("store.sqlite.external/\(fileName)")), Data(large))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path + "/store.sqlite.external").count, 1)
        externalStorage.rollback(pending)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path + "/store.sqlite.external"), [])
    }

    func testDriverWriteSessionExternalizesOversizedData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OSDExternalSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("store.sqlite")
        let driver = try GRDBSQLiteDriver(
            location: .file(databaseURL), externalColumns: ["ZRECORD.ZPAYLOAD"])
        let payload = Array(repeating: UInt8(6), count: ExternalStorage.threshold + 1)
        let value = try driver.writeWithExternalData { connection, session in
            try connection.execute("CREATE TABLE ZRECORD (ZPAYLOAD BLOB)")
            let value = try session.externalizedValue(payload)
            try connection.execute("INSERT INTO ZRECORD (ZPAYLOAD) VALUES (?)", [value])
            return value
        }
        guard case let .blob(reference) = value else { return XCTFail("Expected a reference BLOB") }
        XCTAssertNotEqual(reference.count, payload.count, "External write session returned \(reference.count) bytes")
        XCTAssertEqual(
            String(bytes: reference, encoding: .utf8),
            "OSD_EXTERNAL_DATA_V1\u{0}data-\(SHA256.hash(payload).map { String(format: "%02x", $0) }.joined()).blob")
        XCTAssertNotNil(ExternalStorage.fileName(in: reference))
        let files = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("store.sqlite.external").path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".blob") }.count, 1)
        try driver.close()
    }

    func testOpenRemovesUnreferencedSidecarFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OSDExternalOrphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("store.sqlite")
        let sidecarDirectory = directory.appendingPathComponent("store.sqlite.external", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecarDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: sidecarDirectory.appendingPathComponent("data-deadbeef.blob"))
        try Data([4]).write(to: sidecarDirectory.appendingPathComponent(".abandoned.tmp"))
        let driver = try LightweightMigration.openStore(
            location: .file(databaseURL), schema: Schema([Schema.Entity(name: "Record")]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sidecarDirectory.path), [])
        try driver.close()
    }

    func testUnmarkedLargeBlobRemainsInline() throws {
        let driver = try GRDBSQLiteDriver(location: .memory(name: "unmarked-large-blob"))
        defer { try? driver.close() }
        let payload = Array(repeating: UInt8(5), count: ExternalStorage.threshold + 1)
        try driver.write { connection in
            try connection.execute("CREATE TABLE values_table (value BLOB)")
            try connection.execute("INSERT INTO values_table VALUES (?)", [.blob(payload)])
        }
        XCTAssertEqual(try driver.read { try $0.rows("SELECT value FROM values_table") }, [[.blob(payload)]])
    }
}

private enum TestFailure: Error {
    case expected
}
