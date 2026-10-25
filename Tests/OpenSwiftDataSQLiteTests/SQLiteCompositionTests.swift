import Foundation
import OpenSwiftData
import OpenSwiftDataSQLite
import OSDCore
import XCTest

final class SQLiteCompositionTests: XCTestCase {
    func testExternalClientUsesExistingConfigurationAPI() throws {
        let memory = try openExternalClientMemoryContainer()
        XCTAssertEqual(memory.schema.entities.map(\.name), ["ExternalClientModel"])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osd-external-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
        }
        let file = try openExternalClientFileContainer(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(file.schema.entities.map(\.name), ["ExternalClientModel"])
    }

    func testMemoryConfigurationCreatesAndBootstrapsSchema() throws {
        let schema = Schema([
            Schema.Entity(
                name: "Person",
                attributes: [Schema.Attribute(name: "name", type: "String")]
            )
        ])
        let container = try ModelContainer(for: schema, configurations: [.sqliteMemory("memory-test")])
        guard let store = container.store else { return XCTFail("Expected an opened store") }
        let rows = try store.read { connection in
            try connection.rows("SELECT Z_ENT, Z_NAME, Z_SUPER, Z_MAX FROM Z_PRIMARYKEY", arguments: [])
        }
        XCTAssertEqual(rows, [[.int(1), .text("Person"), .int(0), .int(0)]])
    }

    func testFileConfigurationCreatesStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osd-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
        }
        let schema = Schema([Schema.Entity(name: "Person")])
        let container = try ModelContainer(for: schema, configurations: [.sqliteFile("file-test", url: url)])
        XCTAssertNotNil(container.store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testConfigurationWithoutSelectedProviderThrowsUnsupportedStore() {
        let schema = Schema([Schema.Entity(name: "Person")])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osd-unsupported-\(UUID().uuidString).sqlite")
        let configurations = [
            ModelConfiguration("url", schema: schema, url: url),
            ModelConfiguration("memory", schema: schema, isStoredInMemoryOnly: true),
        ]

        for configuration in configurations {
            XCTAssertThrowsError(try ModelContainer(for: schema, configurations: [configuration])) { error in
                guard case SwiftDataError.unsupportedStore(let message) = error else {
                    return XCTFail("Expected unsupportedStore, got \\(error)")
                }
                XCTAssertTrue(message.contains("backend/provider"))
                XCTAssertTrue(message.contains("unavailable"))
            }
        }
    }

    func testUnsupportedSchemaDoesNotLeavePartialFileStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osd-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
        }
        let schema = Schema([
            Schema.Entity(name: "Person", attributes: [Schema.Attribute(name: "value", type: "Opaque")])
        ])
        XCTAssertThrowsError(try ModelContainer(for: schema, configurations: [.sqliteFile("invalid", url: url)]))
    }
}
