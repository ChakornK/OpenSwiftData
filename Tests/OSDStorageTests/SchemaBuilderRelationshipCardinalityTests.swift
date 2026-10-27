import XCTest
import OSDCore
@testable import OSDStorage

final class SchemaBuilderRelationshipCardinalityTests: XCTestCase {
    func testAcceptsToManyToReciprocalToOneAsSupportedOneToManyPair() {
        let schema = Schema([
            Schema.Entity(
                name: "Parent",
                relationships: [
                    Schema.Relationship(name: "children", destination: "Child", isToMany: true, inverse: "parent")
                ]
            ),
            Schema.Entity(
                name: "Child",
                relationships: [Schema.Relationship(name: "parent", destination: "Parent", inverse: "children")]
            ),
        ])

        XCTAssertNoThrow(try SchemaBuilder.build(schema))
    }

    func testAcceptsToOnePointingToReciprocalToManyAsSupportedOneToManyPair() {
        let schema = Schema([
            Schema.Entity(
                name: "Parent",
                relationships: [Schema.Relationship(name: "child", destination: "Child", inverse: "parents")]
            ),
            Schema.Entity(
                name: "Child",
                relationships: [
                    Schema.Relationship(name: "parents", destination: "Parent", isToMany: true, inverse: "child")
                ]
            ),
        ])

        XCTAssertNoThrow(try SchemaBuilder.build(schema))
    }

    func testOneToManyUsesToOneSideAsForeignKeyOwner() throws {
        let toManyOwned = Schema([
            Schema.Entity(
                name: "Parent",
                relationships: [
                    Schema.Relationship(name: "children", destination: "Child", isToMany: true, inverse: "parent")
                ]
            ),
            Schema.Entity(
                name: "Child",
                relationships: [Schema.Relationship(name: "parent", destination: "Parent", inverse: "children")]
            ),
        ])
        let toOneOwned = Schema([
            Schema.Entity(
                name: "Parent",
                relationships: [Schema.Relationship(name: "children", destination: "Child", inverse: "parent")]
            ),
            Schema.Entity(
                name: "Child",
                relationships: [
                    Schema.Relationship(name: "parent", destination: "Parent", isToMany: true, inverse: "children")
                ]
            ),
        ])

        let toManyBuilt = try SchemaBuilder.build(toManyOwned)
        XCTAssertTrue(
            toManyBuilt.statements.contains(
                "CREATE TABLE ZCHILD (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZPARENT INTEGER);"))
        XCTAssertTrue(toManyBuilt.statements.contains("CREATE INDEX ZCHILD_ZPARENT_INDEX ON ZCHILD (ZPARENT);"))
        XCTAssertFalse(toManyBuilt.statements.contains { $0.hasPrefix("CREATE TABLE Z_PARENT_CHILDREN") })

        let toOneBuilt = try SchemaBuilder.build(toOneOwned)
        XCTAssertTrue(
            toOneBuilt.statements.contains(
                "CREATE TABLE ZPARENT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCHILDREN INTEGER);"))
        XCTAssertTrue(toOneBuilt.statements.contains("CREATE INDEX ZPARENT_ZCHILDREN_INDEX ON ZPARENT (ZCHILDREN);"))
        XCTAssertFalse(toOneBuilt.statements.contains { $0.hasPrefix("CREATE TABLE Z_PARENT_CHILDREN") })
    }

    func testInverseToManyUsesToOneSideForeignKey() throws {
        let schema = Schema([
            Schema.Entity(
                name: "Parent",
                relationships: [Schema.Relationship(name: "child", destination: "Child", inverse: "parents")]
            ),
            Schema.Entity(
                name: "Child",
                relationships: [
                    Schema.Relationship(name: "parents", destination: "Parent", isToMany: true, inverse: "child")
                ]
            ),
        ])

        let built = try SchemaBuilder.build(schema)
        XCTAssertTrue(
            built.statements.contains(
                "CREATE TABLE ZPARENT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCHILD INTEGER);"))
        XCTAssertTrue(built.statements.contains("CREATE INDEX ZPARENT_ZCHILD_INDEX ON ZPARENT (ZCHILD);"))
        XCTAssertFalse(built.statements.contains { $0.hasPrefix("CREATE TABLE Z_CHILD_PARENTS") })
    }
}
