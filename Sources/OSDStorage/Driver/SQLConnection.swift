import Foundation
import GRDB
import OSDCore

package struct SQLConnection {
    private let database: Database

    package init(database: Database) {
        self.database = database
    }

    package func execute(_ sql: String, _ args: [StoredValue] = []) throws {
        try database.execute(sql: sql, arguments: StatementArguments(args.map(Self.databaseValue)))
    }

    package func rows(_ sql: String, _ args: [StoredValue] = []) throws -> [[StoredValue]] {
        let statement = try database.makeStatement(sql: sql)
        try statement.setArguments(StatementArguments(args.map(Self.databaseValue)))
        return try Row.fetchAll(statement).map { row in
            row.map { Self.storedValue($0.1) }
        }
    }

    package func lastInsertRowID() -> Int64 {
        database.lastInsertedRowID
    }

    package func changesCount() -> Int {
        database.changesCount
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
