@testable import OpenSwiftData
import XCTest

final class FetchSQLBuilderTests: XCTestCase {
    func testBuildsFilteredFetchWithLimitAndOffset() {
        let query = FetchSQLBuilder.build(
            FetchSQLInput(
                table: "ZITEM",
                columns: ["ZNAME", "ZRANK"],
                predicateSQL: "(t0.ZRANK >= ?)",
                predicateArguments: [.int(4)],
                orderSQL: "t0.ZNAME COLLATE swiftLocalizedStandardCompare ASC",
                limit: 8,
                offset: 3))

        XCTAssertEqual(
            query.sql,
            "SELECT Z_PK, Z_OPT, ZNAME, ZRANK FROM ZITEM AS t0 WHERE (t0.ZRANK >= ?) "
                + "ORDER BY t0.ZNAME COLLATE swiftLocalizedStandardCompare ASC, t0.Z_PK ASC LIMIT 8 OFFSET 3")
        XCTAssertEqual(query.arguments, [.int(4)])
    }

    func testBuildsOffsetOnlyAndUnboundedPendingQueries() {
        let offsetQuery = FetchSQLBuilder.build(
            FetchSQLInput(
                table: "ZITEM", columns: [], predicateSQL: nil, predicateArguments: [],
                orderSQL: "t0.Z_PK ASC", limit: nil, offset: 5))
        let pendingQuery = FetchSQLBuilder.build(
            FetchSQLInput(
                table: "ZITEM", columns: ["ZNAME"], predicateSQL: nil, predicateArguments: [],
                orderSQL: "t0.Z_PK ASC", limit: nil, offset: nil))

        XCTAssertEqual(
            offsetQuery.sql,
            "SELECT Z_PK, Z_OPT FROM ZITEM AS t0 ORDER BY t0.Z_PK ASC, t0.Z_PK ASC LIMIT -1 OFFSET 5")
        XCTAssertEqual(
            pendingQuery.sql,
            "SELECT Z_PK, Z_OPT, ZNAME FROM ZITEM AS t0 ORDER BY t0.Z_PK ASC, t0.Z_PK ASC")
    }
}
