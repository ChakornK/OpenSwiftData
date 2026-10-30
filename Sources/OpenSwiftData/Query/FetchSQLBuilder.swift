import Foundation

package struct FetchSQLInput: Equatable {
    package let table: String
    package let columns: [String]
    package let predicateSQL: String?
    package let predicateArguments: [RuntimeValue]
    package let orderSQL: String
    package let limit: Int?
    package let offset: Int?
    package let entityIDs: [Int]?

    package init(
        table: String,
        columns: [String],
        predicateSQL: String?,
        predicateArguments: [RuntimeValue],
        orderSQL: String,
        limit: Int?,
        offset: Int?,
        entityIDs: [Int]? = nil
    ) {
        self.table = table
        self.columns = columns
        self.predicateSQL = predicateSQL
        self.predicateArguments = predicateArguments
        self.orderSQL = orderSQL
        self.limit = limit
        self.offset = offset
        self.entityIDs = entityIDs
    }
}

package struct FetchSQL: Equatable {
    package let sql: String
    package let arguments: [RuntimeValue]
}

package enum FetchSQLBuilder {
    package static func build(_ input: FetchSQLInput) -> FetchSQL {
        let identityColumns = input.entityIDs == nil ? ["Z_PK", "Z_OPT"] : ["Z_PK", "Z_OPT", "Z_ENT"]
        let selectedColumns = (identityColumns + input.columns).joined(separator: ", ")
        var sql = "SELECT \(selectedColumns) FROM \(input.table) AS t0"
        var filters: [String] = []
        var arguments = input.predicateArguments
        if let entityIDs = input.entityIDs, !entityIDs.isEmpty {
            filters.append("t0.Z_ENT IN (\(Array(repeating: "?", count: entityIDs.count).joined(separator: ", ")))")
            arguments = entityIDs.map { .int(Int64($0)) } + arguments
        }
        if let predicateSQL = input.predicateSQL { filters.append(predicateSQL) }
        if !filters.isEmpty {
            let whereSQL =
                input.entityIDs == nil
                ? filters.joined(separator: " AND ") : filters.map { "(\($0))" }.joined(separator: " AND ")
            sql += " WHERE \(whereSQL)"
        }
        sql += " ORDER BY \(input.orderSQL), t0.Z_PK ASC"
        if let limit = input.limit {
            sql += " LIMIT \(limit)"
        }
        if let offset = input.offset {
            if input.limit == nil { sql += " LIMIT -1" }
            sql += " OFFSET \(offset)"
        }
        return FetchSQL(sql: sql, arguments: arguments)
    }
}
