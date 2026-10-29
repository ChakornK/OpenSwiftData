import Foundation

package struct FetchSQLInput: Equatable {
    package let table: String
    package let columns: [String]
    package let predicateSQL: String?
    package let predicateArguments: [RuntimeValue]
    package let orderSQL: String
    package let limit: Int?
    package let offset: Int?

    package init(
        table: String,
        columns: [String],
        predicateSQL: String?,
        predicateArguments: [RuntimeValue],
        orderSQL: String,
        limit: Int?,
        offset: Int?
    ) {
        self.table = table
        self.columns = columns
        self.predicateSQL = predicateSQL
        self.predicateArguments = predicateArguments
        self.orderSQL = orderSQL
        self.limit = limit
        self.offset = offset
    }
}

package struct FetchSQL: Equatable {
    package let sql: String
    package let arguments: [RuntimeValue]
}

package enum FetchSQLBuilder {
    package static func build(_ input: FetchSQLInput) -> FetchSQL {
        let selectedColumns = (["Z_PK", "Z_OPT"] + input.columns).joined(separator: ", ")
        var sql = "SELECT \(selectedColumns) FROM \(input.table) AS t0"
        if let predicateSQL = input.predicateSQL {
            sql += " WHERE \(predicateSQL)"
        }
        sql += " ORDER BY \(input.orderSQL), t0.Z_PK ASC"
        if let limit = input.limit {
            sql += " LIMIT \(limit)"
        }
        if let offset = input.offset {
            if input.limit == nil { sql += " LIMIT -1" }
            sql += " OFFSET \(offset)"
        }
        return FetchSQL(sql: sql, arguments: input.predicateArguments)
    }
}
