import Foundation

/// A GRDB-free persistence store used by a model container.
public protocol RuntimeStore: Sendable {
    /// Executes a read operation against the configured store.
    func read<T>(_ body: (RuntimeConnection) throws -> T) throws -> T
    /// Executes an atomic write operation against the configured store.
    func write<T>(_ body: (RuntimeConnection) throws -> T) throws -> T
    /// Closes the underlying store.
    func close() throws
}

/// A GRDB-free SQL connection exposed to runtime persistence operations.
public protocol RuntimeConnection {
    /// Executes SQL with positional values.
    func execute(_ sql: String, arguments: [RuntimeValue]) throws
    /// Returns rows of positional values.
    func rows(_ sql: String, arguments: [RuntimeValue]) throws -> [[RuntimeValue]]
    /// The most recently inserted row identifier.
    func lastInsertRowID() -> Int64
    /// The number of rows affected by the last statement.
    func changesCount() -> Int
}

/// SQL values exchanged across the runtime-store boundary.
public enum RuntimeValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob([UInt8])
}

/// The non-SQLite store location selected by a model configuration.
public enum RuntimeStoreLocation: Sendable {
    case file(URL)
    case memory(name: String)
}

/// Creates a runtime store for a location.
public typealias RuntimeStoreFactory = @Sendable (RuntimeStoreLocation, Schema) throws -> any RuntimeStore
