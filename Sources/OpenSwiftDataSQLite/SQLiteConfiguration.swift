import Foundation
import OpenSwiftData

/// SQLite store composition for OpenSwiftData containers.
public enum OpenSwiftDataSQLite {
    static let sqliteVersionReader: RuntimeSchemaVersionReader = SQLiteStoreProvider.versionReader
    static let sqliteSchemaCompatibilityReader: RuntimeSchemaCompatibilityReader =
        SQLiteStoreProvider.schemaCompatibilityReader
    static let sqliteFactory: RuntimeStoreFactory = SQLiteStoreProvider.factory
}

extension ModelConfiguration {
    /// Creates a SQLite-backed configuration for memory storage.
    public static func sqliteMemory(_ name: String = "default", allowsSave: Bool = true) -> Self {
        Self(
            name, isStoredInMemoryOnly: true, allowsSave: allowsSave,
            storeFactory: OpenSwiftDataSQLite.sqliteFactory,
            schemaVersionReader: OpenSwiftDataSQLite.sqliteVersionReader,
            schemaCompatibilityReader: OpenSwiftDataSQLite.sqliteSchemaCompatibilityReader)
    }

    /// Creates a SQLite-backed configuration at an explicit URL.
    public static func sqliteFile(
        _ name: String = "default",
        url: URL,
        allowsSave: Bool = true
    ) -> Self {
        Self(
            name, url: url, allowsSave: allowsSave,
            storeFactory: OpenSwiftDataSQLite.sqliteFactory,
            schemaVersionReader: OpenSwiftDataSQLite.sqliteVersionReader,
            schemaCompatibilityReader: OpenSwiftDataSQLite.sqliteSchemaCompatibilityReader)
    }
}
