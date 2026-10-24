import Foundation
import GRDB

package enum StoreLocation: Sendable {
    case file(URL)
    case memory(name: String)
}

package protocol SQLiteDriver: Sendable {
    func read<T>(_ body: (SQLConnection) throws -> T) throws -> T
    func write<T>(_ body: (SQLConnection) throws -> T) throws -> T
    func close() throws
}

package final class GRDBSQLiteDriver: SQLiteDriver, Sendable {
    private enum DatabaseStorage: Sendable {
        case queue(DatabaseQueue)
        case pool(DatabasePool)
    }

    private let storage: DatabaseStorage

    package init(location: StoreLocation) throws {
        switch location {
        case let .memory(name):
            storage = .queue(try DatabaseQueue(path: ":memory:", configuration: Self.configuration(name: name)))
        case let .file(url):
            storage = .pool(try DatabasePool(path: url.path, configuration: Self.configuration(name: nil)))
        }
    }

    package func read<T>(_ body: (SQLConnection) throws -> T) throws -> T {
        switch storage {
        case let .queue(queue):
            try queue.read { try body(SQLConnection(database: $0)) }
        case let .pool(pool):
            try pool.read { try body(SQLConnection(database: $0)) }
        }
    }

    package func write<T>(_ body: (SQLConnection) throws -> T) throws -> T {
        switch storage {
        case let .queue(queue):
            try queue.write { try body(SQLConnection(database: $0)) }
        case let .pool(pool):
            try pool.write { try body(SQLConnection(database: $0)) }
        }
    }

    package func close() throws {
        switch storage {
        case let .queue(queue):
            try queue.close()
        case let .pool(pool):
            try pool.close()
        }
    }

    private static func configuration(name: String?) -> Configuration {
        var configuration = Configuration()
        configuration.label = name.map { "OpenSwiftData.\($0)" } ?? "OpenSwiftData.SQLiteDriver"
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA synchronous = NORMAL")
            try database.execute(sql: "PRAGMA foreign_keys = OFF")
            try database.execute(sql: "PRAGMA busy_timeout = 5000")
            try database.execute(sql: "PRAGMA mmap_size = 268435456")
        }
        return configuration
    }
}
