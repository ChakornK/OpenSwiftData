import Foundation
import GRDB
import OSDCore

package struct SQLConnection {
    private let database: Database
    private let externalStorage: ExternalStorage?
    private let pendingExternalFiles: PendingExternalFiles?
    private let externalColumns: Set<String>
    private let afterCommitActions: AfterCommitActions?

    package init(
        database: Database,
        externalStorage: ExternalStorage? = nil,
        pendingExternalFiles: PendingExternalFiles? = nil,
        externalColumns: Set<String> = [],
        afterCommitActions: AfterCommitActions? = nil
    ) {
        self.database = database
        self.externalStorage = externalStorage
        self.pendingExternalFiles = pendingExternalFiles
        self.externalColumns = externalColumns
        self.afterCommitActions = afterCommitActions
    }

    package func execute(_ sql: String, _ args: [StoredValue] = []) throws {
        try database.execute(sql: sql, arguments: StatementArguments(args.map(Self.databaseValue)))
    }

    package func rows(_ sql: String, _ args: [StoredValue] = []) throws -> [[StoredValue]] {
        let statement = try database.cachedStatement(sql: sql)
        try statement.setArguments(StatementArguments(args.map(Self.databaseValue)))
        return try Row.fetchAll(statement).map { row in row.map { Self.storedValue($0.1) } }
    }

    package func lastInsertRowID() -> Int64 {
        database.lastInsertedRowID
    }

    package func changesCount() -> Int {
        database.changesCount
    }

    package func externalizedData(_ bytes: [UInt8]) throws -> StoredValue {
        guard let externalStorage, let pendingExternalFiles else { return .blob(bytes) }
        return .blob(try externalStorage.externalized(bytes, pending: pendingExternalFiles))
    }

    package func resolved(_ value: StoredValue) throws -> StoredValue {
        guard let externalStorage, case let .blob(bytes) = value else { return value }
        return .blob(try externalStorage.resolved(bytes))
    }

    package func reconcileExternalFiles() throws {
        guard let externalStorage else { return }
        try externalStorage.removeOrphans(referencedNames: referencedExternalFileNames())
    }

    package func afterCommit(_ action: @escaping (SQLConnection) -> Void) {
        afterCommitActions?.append { [database, externalStorage, externalColumns] in
            action(
                SQLConnection(
                    database: database, externalStorage: externalStorage, externalColumns: externalColumns,
                    afterCommitActions: afterCommitActions))
        }
    }

    private func referencedExternalFileNames() throws -> Set<String> {
        let tables = try rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        return try tables.reduce(into: Set<String>()) { names, row in
            guard case let .text(table)? = row.first, table != "_osd_meta", table != "Z_PRIMARYKEY",
                table.utf8.allSatisfy({
                    ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95
                })
            else { return }
            let columns = try rows("PRAGMA table_info(\(table))")
            for column in columns {
                guard column.count > 1, case let .text(name) = column[1], name.hasPrefix("Z"),
                    externalColumns.contains("\(table).\(name)"),
                    name.utf8.allSatisfy({
                        ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95
                    })
                else { continue }
                let values = try rows("SELECT \(name) FROM \(table) WHERE typeof(\(name)) = 'blob'")
                for valueRow in values {
                    guard case let .blob(bytes)? = valueRow.first,
                        let fileName = ExternalStorage.fileName(in: bytes)
                    else { continue }
                    names.insert(fileName)
                }
            }
        }
    }

    private static func databaseValue(_ value: StoredValue) -> DatabaseValue {
        switch value {
        case .null:
            .null
        case let .int(value):
            value.databaseValue
        case let .double(value):
            value.databaseValue
        case let .text(value):
            value.databaseValue
        case let .blob(value):
            Data(value).databaseValue
        }
    }

    private static func storedValue(_ value: DatabaseValue) -> StoredValue {
        switch value.storage {
        case .null:
            .null
        case let .int64(value):
            .int(value)
        case let .double(value):
            .double(value)
        case let .string(value):
            .text(value)
        case let .blob(value):
            .blob(Array(value))
        }
    }
}
