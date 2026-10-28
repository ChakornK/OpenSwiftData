import Foundation
import OpenSwiftData
import OSDCore
import OSDStorage

private struct SQLiteRuntimeStore: RuntimeStore {
    let driver: GRDBSQLiteDriver

    func read<T>(_ body: (any RuntimeConnection) throws -> T) throws -> T {
        try driver.read { connection in
            try body(SQLiteRuntimeConnection(connection: connection))
        }
    }

    func write<T>(_ body: (any RuntimeConnection) throws -> T) throws -> T {
        try driver.write { connection in
            try body(SQLiteRuntimeConnection(connection: connection))
        }
    }

    func close() throws {
        try driver.close()
    }
}

private struct SQLiteRuntimeConnection: RuntimeConnection {
    let connection: SQLConnection

    func execute(_ sql: String, arguments: [RuntimeValue]) throws {
        try connection.execute(sql, arguments.map(Self.storageValue))
    }

    func rows(_ sql: String, arguments: [RuntimeValue]) throws -> [[RuntimeValue]] {
        try connection.rows(sql, arguments.map(Self.storageValue)).map { $0.map(Self.runtimeValue) }
    }

    func lastInsertRowID() -> Int64 { connection.lastInsertRowID() }
    func changesCount() -> Int { connection.changesCount() }

    private static func storageValue(_ value: RuntimeValue) -> StoredValue {
        switch value {
        case .null: .null
        case let .int(value): .int(value)
        case let .double(value): .double(value)
        case let .text(value): .text(value)
        case let .blob(value): .blob(value)
        }
    }

    private static func runtimeValue(_ value: StoredValue) -> RuntimeValue {
        switch value {
        case .null: .null
        case let .int(value): .int(value)
        case let .double(value): .double(value)
        case let .text(value): .text(value)
        case let .blob(value): .blob(value)
        }
    }
}

/// SQLite store composition for OpenSwiftData containers.
public enum OpenSwiftDataSQLite {
    static let sqliteFactory: RuntimeStoreFactory = { location, schema in
        let driverLocation: StoreLocation =
            switch location {
            case let .memory(name): .memory(name: name)
            case let .file(url): .file(url)
            }
        let driver = try LightweightMigration.openStore(location: driverLocation, schema: schema)
        let store = SQLiteRuntimeStore(driver: driver)
        return store
    }
}

extension ModelConfiguration {
    /// Creates a SQLite-backed configuration for memory storage.
    public static func sqliteMemory(_ name: String = "default", allowsSave: Bool = true) -> Self {
        Self(name, isStoredInMemoryOnly: true, allowsSave: allowsSave, storeFactory: OpenSwiftDataSQLite.sqliteFactory)
    }

    /// Creates a SQLite-backed configuration at an explicit URL.
    public static func sqliteFile(
        _ name: String = "default",
        url: URL,
        allowsSave: Bool = true
    ) -> Self {
        Self(name, url: url, allowsSave: allowsSave, storeFactory: OpenSwiftDataSQLite.sqliteFactory)
    }
}
