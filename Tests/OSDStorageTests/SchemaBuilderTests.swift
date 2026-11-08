import XCTest
import OSDCore
@testable import OSDStorage

final class SchemaBuilderTests: XCTestCase {
    func testInheritanceRejectsMissingParentAndCycles() {
        XCTAssertThrowsError(
            try SchemaBuilder.build(
                SchemaDescriptor([SchemaDescriptor.Entity(name: "Child", superentityName: "Missing")]))
        ) { error in
            guard case SwiftDataError.unsupportedSchemaProperty = error else {
                return XCTFail("Expected unsupportedSchemaProperty, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try SchemaBuilder.build(
                SchemaDescriptor([
                    SchemaDescriptor.Entity(name: "First", superentityName: "Second"),
                    SchemaDescriptor.Entity(name: "Second", superentityName: "First"),
                ]))
        ) { error in
            guard case SwiftDataError.unsupportedSchemaProperty = error else {
                return XCTFail("Expected unsupportedSchemaProperty, got \(error)")
            }
        }
    }

    func testRelationshipStorageOwnerUsesLogicalDeclarationAndAncestorInverse() throws {
        let base = SchemaDescriptor.Entity(name: "Base")
        let child = SchemaDescriptor.Entity(
            name: "Child",
            relationships: [
                SchemaDescriptor.Relationship(
                    name: "destination", destination: "Target", inverse: "sources",
                    declaringEntityName: "Child")
            ],
            superentityName: "Base")
        let target = SchemaDescriptor.Entity(
            name: "Target",
            relationships: [
                SchemaDescriptor.Relationship(
                    name: "sources", destination: "Child", inverse: "destination")
            ])
        let schema = SchemaDescriptor([base, child, target])
        let childRelationship = try XCTUnwrap(child.relationships.first)
        let targetRelationship = try XCTUnwrap(target.relationships.first)

        XCTAssertFalse(SchemaBuilder.isNonOwner(child, childRelationship, schema: schema))
        XCTAssertTrue(SchemaBuilder.isNonOwner(target, targetRelationship, schema: schema))
        XCTAssertEqual(
            schema.relationshipStorageMapping(modelEntityName: "Child", relationshipName: "destination")?
                .ownerRootEntityName,
            "Base")
    }

    func testRelationshipMappingRejectsDeclarationOutsideModelAncestry() {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base"),
            SchemaDescriptor.Entity(name: "Sibling"),
            SchemaDescriptor.Entity(
                name: "Child",
                relationships: [
                    SchemaDescriptor.Relationship(
                        name: "target", destination: "Target", declaringEntityName: "Sibling")
                ],
                superentityName: "Base"),
            SchemaDescriptor.Entity(name: "Target"),
        ])

        XCTAssertThrowsError(try SchemaBuilder.build(schema)) { error in
            guard case SwiftDataError.unsupportedSchemaProperty = error else {
                return XCTFail("Expected unsupportedSchemaProperty, got \(error)")
            }
        }
    }

    func testInheritedToOneRelationshipUsesDeclaredColumnOnRootTable() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base"),
            SchemaDescriptor.Entity(
                name: "Child",
                relationships: [
                    SchemaDescriptor.Relationship(
                        name: "target", destination: "Target", declaringEntityName: "Child")
                ],
                superentityName: "Base"),
            SchemaDescriptor.Entity(
                name: "Grandchild",
                relationships: [
                    SchemaDescriptor.Relationship(
                        name: "target", destination: "Target", declaringEntityName: "Child")
                ],
                superentityName: "Child"),
            SchemaDescriptor.Entity(name: "Target", attributes: [SchemaDescriptor.Attribute(name: "title", type: "String")]),
        ])

        let built = try SchemaBuilder.build(schema)

        XCTAssertTrue(
            built.statements.contains(
                "CREATE TABLE ZBASE (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCHILD_TARGET INTEGER);"))
        XCTAssertTrue(
            built.statements.contains(
                "CREATE INDEX ZBASE_ZCHILD_TARGET_INDEX ON ZBASE (ZCHILD_TARGET);"))
        XCTAssertFalse(built.statements.contains { $0.contains("ZCHILD (Z_PK") || $0.contains("ZGRANDCHILD (Z_PK") })
        XCTAssertEqual(built.bootstrapRows.map(\.name), ["Base", "Child", "Grandchild", "Target"])
    }

    func testInheritedToOneRelationshipMayTargetAnotherHierarchy() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "OwnerBase"),
            SchemaDescriptor.Entity(
                name: "OwnerChild",
                relationships: [
                    SchemaDescriptor.Relationship(
                        name: "target", destination: "TargetBase", declaringEntityName: "OwnerChild")
                ],
                superentityName: "OwnerBase"),
            SchemaDescriptor.Entity(name: "TargetBase"),
            SchemaDescriptor.Entity(name: "TargetChild", superentityName: "TargetBase"),
        ])

        let built = try SchemaBuilder.build(schema)

        XCTAssertTrue(
            built.statements.contains(
                "CREATE TABLE ZOWNERBASE (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, "
                    + "ZOWNERCHILD_TARGET INTEGER);"))
        XCTAssertEqual(
            schema.relationshipStorageMapping(modelEntityName: "OwnerChild", relationshipName: "target")?
                .destinationRootEntityName,
            "TargetBase")
    }

    func testInverseNamesDeclaredOnMultipleDestinationSubtypesAreAmbiguous() {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "OwnerBase"),
            SchemaDescriptor.Entity(
                name: "OwnerChild",
                relationships: [
                    SchemaDescriptor.Relationship(
                        name: "target", destination: "TargetBase", inverse: "owners",
                        declaringEntityName: "OwnerChild")
                ],
                superentityName: "OwnerBase"),
            SchemaDescriptor.Entity(name: "TargetBase"),
            SchemaDescriptor.Entity(
                name: "TargetFirst",
                relationships: [
                    SchemaDescriptor.Relationship(name: "owners", destination: "OwnerChild", isToMany: true)
                ],
                superentityName: "TargetBase"),
            SchemaDescriptor.Entity(
                name: "TargetSecond",
                relationships: [
                    SchemaDescriptor.Relationship(name: "owners", destination: "OwnerChild", isToMany: true)
                ],
                superentityName: "TargetBase"),
        ])

        XCTAssertThrowsError(try SchemaBuilder.build(schema)) { error in
            guard case SwiftDataError.unsupportedSchemaProperty = error else {
                return XCTFail("Expected unsupportedSchemaProperty, got \(error)")
            }
        }
    }

    func testHierarchyRootIndexesAndUniqueAttributesEmitOnRootTable() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "RecordBase",
                attributes: [
                    SchemaDescriptor.Attribute(name: "code", type: "String", options: [.unique]),
                    SchemaDescriptor.Attribute(name: "category", type: "String"),
                ],
                indexes: [SchemaDescriptor.Index(properties: ["category"]), SchemaDescriptor.Index(properties: ["code", "category"])]),
            SchemaDescriptor.Entity(
                name: "RecordChild",
                attributes: [
                    SchemaDescriptor.Attribute(name: "code", type: "String", options: [.unique]),
                    SchemaDescriptor.Attribute(name: "category", type: "String"),
                    SchemaDescriptor.Attribute(name: "rank", type: "Int"),
                ],
                indexes: [
                    SchemaDescriptor.Index(properties: ["category"]),
                    SchemaDescriptor.Index(properties: ["code", "category"]),
                ],
                superentityName: "RecordBase"),
        ])

        let built = try SchemaBuilder.build(schema)
        XCTAssertEqual(
            built.statements.filter { $0.contains("INDEX") && $0.contains("ZRECORDBASE") },
            [
                "CREATE UNIQUE INDEX ZRECORDBASE_ZCODE_UNIQUE_INDEX ON ZRECORDBASE (ZCODE);",
                "CREATE INDEX ZRECORDBASE_ZCATEGORY_INDEX ON ZRECORDBASE (ZCATEGORY);",
                "CREATE INDEX ZRECORDBASE_ZCODE_ZCATEGORY_INDEX ON ZRECORDBASE (ZCODE, ZCATEGORY);",
            ])
        XCTAssertFalse(built.statements.contains { $0.contains("ZRECORDCHILD") && $0.contains("INDEX") })
    }

    func testHierarchySubtypeIndexesAndUniqueAttributesUsePartialSubtreeIndexes() throws {
        let rootIndex = SchemaDescriptor.Index(properties: ["rootKey"])
        let childIndex = SchemaDescriptor.Index(properties: ["score"])
        let childCompositeUnique = SchemaDescriptor.Index(properties: ["rootKey", "score"], isUnique: true)
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "Base",
                attributes: [
                    SchemaDescriptor.Attribute(name: "rootKey", type: "String", options: [.unique]),
                    SchemaDescriptor.Attribute(name: "token", type: "String"),
                ],
                indexes: [rootIndex]),
            SchemaDescriptor.Entity(
                name: "Child",
                attributes: [
                    SchemaDescriptor.Attribute(name: "rootKey", type: "String", options: [.unique]),
                    SchemaDescriptor.Attribute(name: "token", type: "String"),
                    SchemaDescriptor.Attribute(name: "score", type: "Int", options: [.unique]),
                ],
                indexes: [rootIndex, childIndex, childCompositeUnique],
                superentityName: "Base"),
            SchemaDescriptor.Entity(
                name: "Grandchild",
                attributes: [
                    SchemaDescriptor.Attribute(name: "rootKey", type: "String", options: [.unique]),
                    SchemaDescriptor.Attribute(name: "token", type: "String"),
                    SchemaDescriptor.Attribute(name: "score", type: "Int", options: [.unique]),
                    SchemaDescriptor.Attribute(name: "rank", type: "Int"),
                ],
                indexes: [rootIndex, childIndex, childCompositeUnique],
                superentityName: "Child"),
            SchemaDescriptor.Entity(
                name: "Sibling",
                attributes: [
                    SchemaDescriptor.Attribute(name: "rootKey", type: "String", options: [.unique]),
                    SchemaDescriptor.Attribute(name: "token", type: "String"),
                    SchemaDescriptor.Attribute(name: "label", type: "String", options: [.unique]),
                ],
                indexes: [rootIndex],
                superentityName: "Base"),
        ])

        let statements = try SchemaBuilder.build(schema).statements
        XCTAssertEqual(
            statements.filter { $0.contains("INDEX") },
            [
                "CREATE UNIQUE INDEX ZBASE_ZROOTKEY_UNIQUE_INDEX ON ZBASE (ZROOTKEY);",
                "CREATE UNIQUE INDEX ZBASE_CHILD_ZSCORE_UNIQUE_INDEX ON ZBASE (ZSCORE) WHERE Z_ENT IN (2, 3);",
                "CREATE UNIQUE INDEX ZBASE_SIBLING_ZLABEL_UNIQUE_INDEX ON ZBASE (ZLABEL) WHERE Z_ENT IN (4);",
                "CREATE INDEX ZBASE_ZROOTKEY_INDEX ON ZBASE (ZROOTKEY);",
                "CREATE INDEX ZBASE_CHILD_ZSCORE_INDEX ON ZBASE (ZSCORE) WHERE Z_ENT IN (2, 3);",
                "CREATE UNIQUE INDEX ZBASE_CHILD_ZROOTKEY_ZSCORE_UNIQUE_INDEX ON ZBASE (ZROOTKEY, ZSCORE) WHERE Z_ENT IN (2, 3);",
            ])
        XCTAssertTrue(
            statements.contains(
                "CREATE INDEX ZBASE_ZROOTKEY_INDEX ON ZBASE (ZROOTKEY);"))
        XCTAssertTrue(
            statements.contains(
                "CREATE UNIQUE INDEX ZBASE_CHILD_ZSCORE_UNIQUE_INDEX ON ZBASE (ZSCORE) WHERE Z_ENT IN (2, 3);"))
        XCTAssertTrue(
            statements.contains(
                "CREATE INDEX ZBASE_CHILD_ZSCORE_INDEX ON ZBASE (ZSCORE) WHERE Z_ENT IN (2, 3);"))
        XCTAssertTrue(
            statements.contains(
                "CREATE UNIQUE INDEX ZBASE_CHILD_ZROOTKEY_ZSCORE_UNIQUE_INDEX ON ZBASE (ZROOTKEY, ZSCORE) WHERE Z_ENT IN (2, 3);"
            ))
        XCTAssertTrue(
            statements.contains(
                "CREATE UNIQUE INDEX ZBASE_SIBLING_ZLABEL_UNIQUE_INDEX ON ZBASE (ZLABEL) WHERE Z_ENT IN (4);"))
        XCTAssertEqual(statements.filter { $0.contains("ZBASE_CHILD_ZSCORE") }.count, 2)
    }

    func testInheritedToManyOwnerAndHierarchicalDestinationUseJoinTable() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base"),
            SchemaDescriptor.Entity(
                name: "Child",
                relationships: [
                    SchemaDescriptor.Relationship(
                        name: "targets", destination: "Target", isToMany: true,
                        declaringEntityName: "Child")
                ],
                superentityName: "Base"),
            SchemaDescriptor.Entity(name: "Target"),
        ])

        let built = try SchemaBuilder.build(schema)
        XCTAssertTrue(
            built.statements.contains("CREATE TABLE Z_CHILD_TARGETS_TARGET (Z_A INTEGER, Z_B INTEGER);"))

        let hierarchyDestination = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base"),
            SchemaDescriptor.Entity(
                name: "Child",
                relationships: [
                    SchemaDescriptor.Relationship(name: "targets", destination: "Target", isToMany: true)
                ],
                superentityName: "Base"),
            SchemaDescriptor.Entity(name: "Target", superentityName: "Base"),
        ])
        let hierarchyBuilt = try SchemaBuilder.build(hierarchyDestination)
        XCTAssertTrue(
            hierarchyBuilt.statements.contains("CREATE TABLE Z_CHILD_TARGETS_TARGET (Z_A INTEGER, Z_B INTEGER);"))

        let oneToOneInverse = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base"),
            SchemaDescriptor.Entity(
                name: "Child",
                relationships: [
                    SchemaDescriptor.Relationship(name: "target", destination: "Target", inverse: "child")
                ],
                superentityName: "Base"),
            SchemaDescriptor.Entity(
                name: "Target",
                relationships: [SchemaDescriptor.Relationship(name: "child", destination: "Child", inverse: "target")]),
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(oneToOneInverse)) { error in
            guard case SwiftDataError.unsupportedSchemaProperty = error else {
                return XCTFail("Expected unsupportedSchemaProperty, got \(error)")
            }
        }
    }

    func testInheritedToManyOwnerCreatesDeclaringEntityJoinTable() throws {
        let base = SchemaDescriptor.Entity(name: "Base")
        let child = SchemaDescriptor.Entity(
            name: "Child",
            relationships: [
                SchemaDescriptor.Relationship(
                    name: "targets", destination: "Target", isToMany: true,
                    declaringEntityName: "Child")
            ],
            superentityName: "Base")
        let grandchild = SchemaDescriptor.Entity(
            name: "Grandchild",
            relationships: [
                SchemaDescriptor.Relationship(
                    name: "targets", destination: "Target", isToMany: true,
                    declaringEntityName: "Child")
            ],
            superentityName: "Child")
        let sibling = SchemaDescriptor.Entity(
            name: "Sibling",
            relationships: [
                SchemaDescriptor.Relationship(
                    name: "targets", destination: "Target", isToMany: true,
                    declaringEntityName: "Sibling")
            ],
            superentityName: "Base")
        let target = SchemaDescriptor.Entity(name: "Target")
        let built = try SchemaBuilder.build(SchemaDescriptor([base, child, grandchild, sibling, target]))

        XCTAssertEqual(
            built.statements.filter { $0.hasSuffix("(Z_A INTEGER, Z_B INTEGER);") },
            [
                "CREATE TABLE Z_CHILD_TARGETS_TARGET (Z_A INTEGER, Z_B INTEGER);",
                "CREATE TABLE Z_SIBLING_TARGETS_TARGET (Z_A INTEGER, Z_B INTEGER);",
            ])
        XCTAssertEqual(built.statements.filter { $0.contains("Z_CHILD_TARGETS_TARGET") }.count, 3)
    }

    func testInheritedManyToManyInverseUsesOneCanonicalJoinTable() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base"),
            SchemaDescriptor.Entity(
                name: "Child",
                relationships: [
                    SchemaDescriptor.Relationship(
                        name: "tags", destination: "Tag", isToMany: true, inverse: "owners",
                        declaringEntityName: "Child")
                ],
                superentityName: "Base"),
            SchemaDescriptor.Entity(
                name: "Grandchild",
                relationships: [
                    SchemaDescriptor.Relationship(
                        name: "tags", destination: "Tag", isToMany: true, inverse: "owners",
                        declaringEntityName: "Child")
                ],
                superentityName: "Child"),
            SchemaDescriptor.Entity(
                name: "Tag",
                relationships: [
                    SchemaDescriptor.Relationship(name: "owners", destination: "Child", isToMany: true, inverse: "tags")
                ]),
        ])

        let built = try SchemaBuilder.build(schema)
        XCTAssertEqual(
            built.statements.filter { $0.hasSuffix("(Z_A INTEGER, Z_B INTEGER);") },
            ["CREATE TABLE Z_CHILD_TAGS_TAG_OWNERS (Z_A INTEGER, Z_B INTEGER);"])
    }

    func testToOneStorageOwnershipFindsInverseDeclaredOnDestinationSubtype() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "OwnerBase"),
            SchemaDescriptor.Entity(
                name: "OwnerChild",
                relationships: [
                    SchemaDescriptor.Relationship(
                        name: "target", destination: "TargetBase", inverse: "owners",
                        declaringEntityName: "OwnerChild")
                ],
                superentityName: "OwnerBase"),
            SchemaDescriptor.Entity(name: "TargetBase"),
            SchemaDescriptor.Entity(
                name: "TargetChild",
                relationships: [
                    SchemaDescriptor.Relationship(
                        name: "owners", destination: "OwnerChild", isToMany: true, inverse: "target")
                ],
                superentityName: "TargetBase"),
        ])

        let owner = try XCTUnwrap(schema.entity(forName: "OwnerChild"))
        let relationship = try XCTUnwrap(owner.relationships.first)

        XCTAssertFalse(SchemaBuilder.isNonOwner(owner, relationship, schema: schema))
        XCTAssertTrue(
            try SchemaBuilder.build(schema).statements.contains(
                "CREATE TABLE ZOWNERBASE (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, "
                    + "ZOWNERCHILD_TARGET INTEGER);"))
    }

    func testInheritanceUsesRootTableAndNullableDescendantColumns() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base", attributes: [SchemaDescriptor.Attribute(name: "name", type: "String")]),
            SchemaDescriptor.Entity(
                name: "Child",
                attributes: [
                    SchemaDescriptor.Attribute(name: "name", type: "String"),
                    SchemaDescriptor.Attribute(name: "age", type: "Int"),
                ],
                superentityName: "Base"),
            SchemaDescriptor.Entity(
                name: "Grandchild",
                attributes: [
                    SchemaDescriptor.Attribute(name: "name", type: "String"),
                    SchemaDescriptor.Attribute(name: "age", type: "Int"),
                    SchemaDescriptor.Attribute(name: "rank", type: "Int"),
                ],
                superentityName: "Child"),
        ])
        let built = try SchemaBuilder.build(schema)
        XCTAssertEqual(
            built.statements.filter { $0.hasPrefix("CREATE TABLE Z") && !$0.hasPrefix("CREATE TABLE Z_PRIMARYKEY") },
            [
                "CREATE TABLE ZBASE (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAGE INTEGER, ZNAME VARCHAR NOT NULL, ZRANK INTEGER);"
            ])
        XCTAssertFalse(built.statements.contains { $0.contains("ZCHILD") || $0.contains("ZGRANDCHILD") })
        XCTAssertEqual(
            built.bootstrapRows,
            [
                SchemaBootstrapRow(entityID: 1, name: "Base"),
                SchemaBootstrapRow(entityID: 2, name: "Child", superEntityID: 1),
                SchemaBootstrapRow(entityID: 3, name: "Grandchild", superEntityID: 2),
            ])
    }

    func testInheritanceRejectsUnsupportedRelationshipsIndexesAndConflictingColumns() throws {
        let related = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base"),
            SchemaDescriptor.Entity(
                name: "Child", relationships: [SchemaDescriptor.Relationship(name: "parent", destination: "Base")],
                superentityName: "Base"),
        ])
        XCTAssertTrue(try SchemaBuilder.build(related).statements.contains { $0.contains("ZCHILD_PARENT") })

        let toMany = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base"),
            SchemaDescriptor.Entity(
                name: "Child",
                relationships: [
                    SchemaDescriptor.Relationship(name: "targets", destination: "Target", isToMany: true)
                ],
                superentityName: "Base"),
            SchemaDescriptor.Entity(name: "Target"),
        ])
        XCTAssertTrue(
            try SchemaBuilder.build(toMany).statements.contains(
                "CREATE TABLE Z_CHILD_TARGETS_TARGET (Z_A INTEGER, Z_B INTEGER);")
        )

        let inverse = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base"),
            SchemaDescriptor.Entity(
                name: "Child",
                relationships: [
                    SchemaDescriptor.Relationship(name: "parent", destination: "Base", inverse: "children")
                ],
                superentityName: "Base"),
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(inverse))

        let indexed = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base"),
            SchemaDescriptor.Entity(name: "Child", indexes: [SchemaDescriptor.Index(properties: ["value"])], superentityName: "Base"),
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(indexed))

        let conflicting = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base", attributes: [SchemaDescriptor.Attribute(name: "value", type: "String")]),
            SchemaDescriptor.Entity(
                name: "Child", attributes: [SchemaDescriptor.Attribute(name: "value", type: "Int")], superentityName: "Base"),
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(conflicting))

        let caseCollision = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base", attributes: [SchemaDescriptor.Attribute(name: "value", type: "String")]),
            SchemaDescriptor.Entity(
                name: "Child", attributes: [SchemaDescriptor.Attribute(name: "VALUE", type: "Int")], superentityName: "Base"),
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(caseCollision))
    }

    func testInheritanceRequiresRootAttributesInEveryDescendant() {
        let missingRootValue = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "Base", attributes: [SchemaDescriptor.Attribute(name: "requiredValue", type: "Int")]),
            SchemaDescriptor.Entity(name: "Child", superentityName: "Base"),
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(missingRootValue))
    }

    func testFlattenedAttributeEmitsScalarLeafColumns() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "Record",
                attributes: [
                    SchemaDescriptor.Attribute(
                        name: "size", type: "Size", options: [.flattened],
                        components: [
                            SchemaDescriptor.Attribute.Component(name: "width", columnName: "size_width", type: "Int"),
                            SchemaDescriptor.Attribute.Component(name: "label", columnName: "size_label", type: "String"),
                        ])
                ])
        ])
        let built = try SchemaBuilder.build(schema)
        XCTAssertTrue(
            built.statements.contains(
                "CREATE TABLE ZRECORD (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, "
                    + "ZSIZE_LABEL VARCHAR, ZSIZE_WIDTH INTEGER);"))
    }

    func testFlattenedComponentColumnCollisionFailsSchemaValidation() {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "Record",
                attributes: [
                    SchemaDescriptor.Attribute(name: "size_width", type: "Int"),
                    SchemaDescriptor.Attribute(
                        name: "size", type: "Size", options: [.flattened],
                        components: [SchemaDescriptor.Attribute.Component(name: "width", columnName: "size_width", type: "Int")]),
                ])
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(schema))
    }

    func testFlattenedCompositeCannotBeIndexedAsWholeAttribute() {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "Record",
                attributes: [
                    SchemaDescriptor.Attribute(
                        name: "size", type: "Size", options: [.flattened],
                        components: [SchemaDescriptor.Attribute.Component(name: "width", columnName: "size_width", type: "Int")])
                ],
                indexes: [SchemaDescriptor.Index(properties: ["size"])])
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(schema))
    }

    func testCompoundUniqueAndIndexDDLPreserveDeclaredColumnOrder() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "Pair",
                attributes: [
                    SchemaDescriptor.Attribute(name: "left", type: "String"),
                    SchemaDescriptor.Attribute(name: "right", type: "String"),
                ],
                indexes: [
                    SchemaDescriptor.Index(properties: ["right", "left"], isUnique: true),
                    SchemaDescriptor.Index(properties: ["left", "right"]),
                ])
        ])
        let statements = try SchemaBuilder.build(schema).statements
        XCTAssertEqual(
            statements.suffix(2),
            [
                "CREATE UNIQUE INDEX ZPAIR_ZRIGHT_ZLEFT_UNIQUE_INDEX ON ZPAIR (ZRIGHT, ZLEFT);",
                "CREATE INDEX ZPAIR_ZLEFT_ZRIGHT_INDEX ON ZPAIR (ZLEFT, ZRIGHT);",
            ])
    }

    func testExactDDLForSingleAndCompoundGeneratedIndexShapes() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "Record",
                attributes: [
                    SchemaDescriptor.Attribute(name: "rank", type: "Int"),
                    SchemaDescriptor.Attribute(name: "label", type: "String"),
                ],
                indexes: [
                    SchemaDescriptor.Index(properties: ["rank"]),
                    SchemaDescriptor.Index(properties: ["label"], isUnique: true),
                    SchemaDescriptor.Index(properties: ["rank", "label"]),
                ])
        ])
        let indexes = try SchemaBuilder.build(schema).statements.filter {
            $0.hasPrefix("CREATE ") && $0.contains("INDEX")
        }
        XCTAssertEqual(
            indexes,
            [
                "CREATE INDEX ZRECORD_ZRANK_INDEX ON ZRECORD (ZRANK);",
                "CREATE UNIQUE INDEX ZRECORD_ZLABEL_UNIQUE_INDEX ON ZRECORD (ZLABEL);",
                "CREATE INDEX ZRECORD_ZRANK_ZLABEL_INDEX ON ZRECORD (ZRANK, ZLABEL);",
            ])
    }

    func testIndexRejectsMissingPropertiesAndCollidingGeneratedNames() {
        let missing = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "Item", attributes: [SchemaDescriptor.Attribute(name: "value", type: "Int")],
                indexes: [SchemaDescriptor.Index(properties: ["absent"])])
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(missing))

        let collision = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "A",
                attributes: [
                    SchemaDescriptor.Attribute(name: "value", type: "Int")
                ],
                relationships: [SchemaDescriptor.Relationship(name: "child", destination: "B")],
                indexes: [
                    SchemaDescriptor.Index(properties: ["child"])
                ]),
            SchemaDescriptor.Entity(name: "B"),
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(collision))

        let ambiguousEncoding = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "Pair",
                attributes: [
                    SchemaDescriptor.Attribute(name: "a_Zb", type: "Int"),
                    SchemaDescriptor.Attribute(name: "a", type: "Int"),
                    SchemaDescriptor.Attribute(name: "b", type: "Int"),
                ],
                indexes: [
                    SchemaDescriptor.Index(properties: ["a_Zb"]),
                    SchemaDescriptor.Index(properties: ["a", "b"]),
                ])
        ])
        XCTAssertThrowsError(try SchemaBuilder.build(ambiguousEncoding))
    }

    func testExactDDLForDocumentedSupportedShapeAndRows() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "Trip",
                attributes: [
                    SchemaDescriptor.Attribute(name: "name", type: "String"),
                    SchemaDescriptor.Attribute(name: "days", type: "Int"),
                    SchemaDescriptor.Attribute(name: "notes", type: "String", isOptional: true),
                ]),
            SchemaDescriptor.Entity(
                name: "Person",
                attributes: [
                    SchemaDescriptor.Attribute(name: "email", type: "String", options: [.unique]),
                    SchemaDescriptor.Attribute(name: "age", type: "Int"),
                ]),
            SchemaDescriptor.Entity(
                name: "Stop",
                attributes: [
                    SchemaDescriptor.Attribute(name: "title", type: "String"),
                    SchemaDescriptor.Attribute(name: "order", type: "Int"),
                ], relationships: [SchemaDescriptor.Relationship(name: "trip", destination: "Trip")]),
        ])
        let built = try SchemaBuilder.build(schema)
        XCTAssertEqual(
            built.statements,
            [
                "CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);",
                "CREATE TABLE _osd_meta (key TEXT PRIMARY KEY, value BLOB);",
                "CREATE TABLE ZPERSON (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAGE INTEGER, ZEMAIL VARCHAR);",
                "CREATE UNIQUE INDEX ZPERSON_ZEMAIL_UNIQUE_INDEX ON ZPERSON (ZEMAIL);",
                "CREATE TABLE ZSTOP (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZORDER INTEGER, ZTITLE VARCHAR, ZTRIP INTEGER);",
                "CREATE INDEX ZSTOP_ZTRIP_INDEX ON ZSTOP (ZTRIP);",
                "CREATE TABLE ZTRIP (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDAYS INTEGER, ZNAME VARCHAR, ZNOTES VARCHAR);",
            ])
        XCTAssertEqual(
            built.bootstrapRows,
            [
                SchemaBootstrapRow(entityID: 1, name: "Person"),
                SchemaBootstrapRow(entityID: 2, name: "Stop"),
                SchemaBootstrapRow(entityID: 3, name: "Trip"),
            ])
        XCTAssertFalse(built.statements.contains { $0.contains("Z_METADATA") })
    }

    func testTransformableAttributesUseBlobColumns() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "Item",
                attributes: [
                    SchemaDescriptor.Attribute(
                        name: "payload", type: "CodablePayload", options: [.transformable(by: "Codec")])
                ])
        ])
        let built = try SchemaBuilder.build(schema)
        XCTAssertTrue(
            built.statements.contains(
                "CREATE TABLE ZITEM (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZPAYLOAD BLOB);"))
    }

    func testDecimalAndURLUseVarcharColumns() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "Item",
                attributes: [
                    SchemaDescriptor.Attribute(name: "amount", type: "Decimal"),
                    SchemaDescriptor.Attribute(name: "url", type: "URL"),
                ])
        ])

        let built = try SchemaBuilder.build(schema)

        XCTAssertTrue(
            built.statements.contains(
                "CREATE TABLE ZITEM (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAMOUNT VARCHAR, ZURL VARCHAR);"
            ))
    }

    func testSupportedTypesAndUnsupportedTypeError() throws {
        let types = ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Bool"]
        for type in types {
            XCTAssertEqual(try SQLColumnType.resolve(type, property: "Item.value"), .integer)
        }
        for type in ["Float", "Double"] {
            XCTAssertEqual(try SQLColumnType.resolve(type, property: "Item.value"), .float)
        }
        XCTAssertEqual(try SQLColumnType.resolve("Date", property: "Item.value"), .timestamp)
        XCTAssertEqual(try SQLColumnType.resolve("String?", property: "Item.value"), .varchar)
        XCTAssertEqual(try SQLColumnType.resolve("Decimal", property: "Item.value"), .varchar)
        XCTAssertEqual(try SQLColumnType.resolve("URL", property: "Item.value"), .varchar)
        for type in ["UUID", "Data"] {
            XCTAssertEqual(try SQLColumnType.resolve(type, property: "Item.value"), .blob)
        }
        XCTAssertEqual(
            try SQLColumnType.resolve(
                "CodablePayload", property: "Item.payload", options: [.transformable(by: "Codec")]),
            .blob)
        for type in ["Opaque", "[String]", "Int??", "Int? ?", "Int ? ?"] {
            XCTAssertThrowsError(try SQLColumnType.resolve(type, property: "Item.value")) { error in
                guard case SwiftDataError.unsupportedSchemaProperty = error else {
                    return XCTFail("Unexpected error: \\(error)")
                }
            }
        }
    }

    func testOptionalTypeWhitespaceAndMalformedMarkers() throws {
        XCTAssertEqual(try SQLColumnType.resolve(" Int ? ", property: "Item.value"), .integer)
        for type in ["Int??", "Int? ?", "Int ? ?", "?Int", "Int ?garbage"] {
            XCTAssertThrowsError(try SQLColumnType.resolve(type, property: "Item.value"))
        }
    }

    func testOneToOneHasOneCanonicalOwnerAcrossInputOrders() throws {
        let alpha = SchemaDescriptor.Entity(
            name: "Alpha",
            relationships: [SchemaDescriptor.Relationship(name: "beta", destination: "Beta", inverse: "alpha")]
        )
        let beta = SchemaDescriptor.Entity(
            name: "Beta",
            relationships: [SchemaDescriptor.Relationship(name: "alpha", destination: "Alpha", inverse: "beta")]
        )
        for entities in [[alpha, beta], [beta, alpha]] {
            let built = try SchemaBuilder.build(SchemaDescriptor(entities))
            XCTAssertTrue(
                built.statements.contains(
                    "CREATE TABLE ZALPHA (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZBETA INTEGER);"))
            XCTAssertTrue(built.statements.contains("CREATE INDEX ZALPHA_ZBETA_INDEX ON ZALPHA (ZBETA);"))
            XCTAssertFalse(built.statements.contains { $0.contains("ZBETA (Z_PK") && $0.contains("ZALPHA INTEGER") })
        }
    }

    func testTripStopsInverseToOneUsesOnlyStopForeignKey() throws {
        let trip = SchemaDescriptor.Entity(
            name: "Trip",
            relationships: [SchemaDescriptor.Relationship(name: "stops", destination: "Stop", isToMany: true, inverse: "trip")]
        )
        let stop = SchemaDescriptor.Entity(
            name: "Stop",
            relationships: [SchemaDescriptor.Relationship(name: "trip", destination: "Trip", inverse: "stops")]
        )
        let built = try SchemaBuilder.build(SchemaDescriptor([trip, stop]))
        XCTAssertTrue(
            built.statements.contains(
                "CREATE TABLE ZSTOP (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZTRIP INTEGER);"))
        XCTAssertTrue(
            built.statements.contains("CREATE INDEX ZSTOP_ZTRIP_INDEX ON ZSTOP (ZTRIP);"))
        XCTAssertFalse(
            built.statements.contains { $0.contains("CREATE TABLE ZTRIP") && $0.contains("ZSTOPS") })
    }

    func testAcceptsAllSupportedInverseCardinalityPairs() throws {
        let schemas: [SchemaDescriptor] = [
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "A",
                    relationships: [SchemaDescriptor.Relationship(name: "b", destination: "B", inverse: "a")]
                ),
                SchemaDescriptor.Entity(
                    name: "B",
                    relationships: [SchemaDescriptor.Relationship(name: "a", destination: "A", inverse: "b")]
                ),
            ]),
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "A",
                    relationships: [SchemaDescriptor.Relationship(name: "bs", destination: "B", isToMany: true, inverse: "a")]
                ),
                SchemaDescriptor.Entity(
                    name: "B",
                    relationships: [SchemaDescriptor.Relationship(name: "a", destination: "A", inverse: "bs")]
                ),
            ]),
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "A",
                    relationships: [SchemaDescriptor.Relationship(name: "b", destination: "B", inverse: "as")]
                ),
                SchemaDescriptor.Entity(
                    name: "B",
                    relationships: [SchemaDescriptor.Relationship(name: "as", destination: "A", isToMany: true, inverse: "b")]
                ),
            ]),
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "A",
                    relationships: [SchemaDescriptor.Relationship(name: "bs", destination: "B", isToMany: true, inverse: "as")]
                ),
                SchemaDescriptor.Entity(
                    name: "B",
                    relationships: [SchemaDescriptor.Relationship(name: "as", destination: "A", isToMany: true, inverse: "bs")]
                ),
            ]),
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "ZParent",
                    relationships: [
                        SchemaDescriptor.Relationship(name: "children", destination: "AChild", isToMany: true, inverse: "parent")
                    ]
                ),
                SchemaDescriptor.Entity(
                    name: "AChild",
                    relationships: [SchemaDescriptor.Relationship(name: "parent", destination: "ZParent", inverse: "children")]
                ),
            ]),
        ]

        for schema in schemas {
            let built = try SchemaBuilder.build(schema)
            if schema.entities.contains(where: { $0.relationships.contains(where: \.isToMany) }) {
                XCTAssertTrue(built.statements.contains { $0.contains("CREATE TABLE Z_") })
            }
        }
    }

    func testRejectsMismatchedReciprocalMetadata() {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(
                name: "Parent",
                relationships: [
                    SchemaDescriptor.Relationship(name: "children", destination: "Child", isToMany: true, inverse: "parent")
                ]
            ),
            SchemaDescriptor.Entity(
                name: "Child",
                relationships: [
                    SchemaDescriptor.Relationship(name: "parent", destination: "Parent", isToMany: true, inverse: "wrongName")
                ]
            ),
        ])

        XCTAssertThrowsError(try SchemaBuilder.build(schema)) { error in
            guard case SwiftDataError.unsupportedSchemaProperty = error else {
                return XCTFail("Unexpected error: \\(error)")
            }
        }
    }

    func testToManyWithoutInverseUsesOwnerJoinTable() throws {
        let entity = SchemaDescriptor.Entity(
            name: "Owner",
            relationships: [SchemaDescriptor.Relationship(name: "items", destination: "Item", isToMany: true)]
        )
        let item = SchemaDescriptor.Entity(name: "Item")

        let built = try SchemaBuilder.build(SchemaDescriptor([item, entity]))
        XCTAssertEqual(
            built.statements.suffix(3),
            [
                "CREATE TABLE Z_OWNER_ITEMS_ITEM (Z_A INTEGER, Z_B INTEGER);",
                "CREATE UNIQUE INDEX Z_OWNER_ITEMS_ITEM_UNIQUE_INDEX ON Z_OWNER_ITEMS_ITEM (Z_A, Z_B);",
                "CREATE INDEX Z_OWNER_ITEMS_ITEM_Z_B_INDEX ON Z_OWNER_ITEMS_ITEM (Z_B);",
            ]
        )
    }

    func testRejectsMalformedRelationshipMetadata() throws {
        var invalidSchemas: [SchemaDescriptor] = [
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "Item",
                    relationships: [SchemaDescriptor.Relationship(name: "owner", destination: "Missing")])
            ]),
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "Item",
                    relationships: [SchemaDescriptor.Relationship(name: "owner", destination: "Owner", inverse: "items")]),
                SchemaDescriptor.Entity(name: "Owner"),
            ]),
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "Item",
                    relationships: [SchemaDescriptor.Relationship(name: "owner", destination: "Owner", inverse: "items")]),
                SchemaDescriptor.Entity(
                    name: "Owner",
                    relationships: [
                        SchemaDescriptor.Relationship(
                            name: "items", destination: "Other", isToMany: true, inverse: "owner")
                    ]
                ),
                SchemaDescriptor.Entity(name: "Other"),
            ]),
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "Item",
                    relationships: [
                        SchemaDescriptor.Relationship(
                            name: "items", destination: "ItemDestination", isToMany: true, inverse: "other")
                    ]
                ),
                SchemaDescriptor.Entity(
                    name: "ItemDestination",
                    relationships: [
                        SchemaDescriptor.Relationship(
                            name: "other", destination: "Item", isToMany: true, inverse: "missing")
                    ]
                ),
            ]),
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "Item",
                    relationships: [
                        SchemaDescriptor.Relationship(
                            name: "items", destination: "Item", minimumModelCount: 2, maximumModelCount: 1)
                    ]
                )
            ]),
        ]

        invalidSchemas.append(
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "Item",
                    relationships: [
                        SchemaDescriptor.Relationship(name: "self", destination: "Item", inverse: "self")
                    ]
                )
            ])
        )

        for (index, schema) in invalidSchemas.enumerated() {
            XCTAssertThrowsError(try SchemaBuilder.build(schema), "invalid relationship case \(index)") { error in
                guard case SwiftDataError.unsupportedSchemaProperty = error else {
                    return XCTFail("Unexpected error: \\(error)")
                }
            }
        }
    }

    func testManyToManyEmitsCanonicalJoinAfterSideAEntity() throws {
        let owner = SchemaDescriptor.Entity(
            name: "Owner",
            relationships: [SchemaDescriptor.Relationship(name: "items", destination: "Item", isToMany: true, inverse: "owners")]
        )
        let item = SchemaDescriptor.Entity(
            name: "Item",
            relationships: [SchemaDescriptor.Relationship(name: "owners", destination: "Owner", isToMany: true, inverse: "items")]
        )

        let built = try SchemaBuilder.build(SchemaDescriptor([item, owner]))
        XCTAssertEqual(
            built.statements,
            [
                "CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);",
                "CREATE TABLE _osd_meta (key TEXT PRIMARY KEY, value BLOB);",
                "CREATE TABLE ZITEM (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER);",
                "CREATE TABLE ZOWNER (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER);",
                "CREATE TABLE Z_ITEM_OWNERS_OWNER_ITEMS (Z_A INTEGER, Z_B INTEGER);",
                "CREATE UNIQUE INDEX Z_ITEM_OWNERS_OWNER_ITEMS_UNIQUE_INDEX ON Z_ITEM_OWNERS_OWNER_ITEMS (Z_A, Z_B);",
                "CREATE INDEX Z_ITEM_OWNERS_OWNER_ITEMS_Z_B_INDEX ON Z_ITEM_OWNERS_OWNER_ITEMS (Z_B);",
            ]
        )
    }

    func testIndexNamesAreUniqueAcrossEntityAndJoinIndexes() {
        let entities = [
            SchemaDescriptor.Entity(
                name: "A",
                attributes: [SchemaDescriptor.Attribute(name: "B_C", type: "Int", options: [.unique])],
                relationships: [SchemaDescriptor.Relationship(name: "b_c", destination: "A")]
            ),
            SchemaDescriptor.Entity(
                name: "A_B",
                relationships: [SchemaDescriptor.Relationship(name: "C_D", destination: "D", isToMany: true)]
            ),
            SchemaDescriptor.Entity(name: "C", relationships: [SchemaDescriptor.Relationship(name: "D", destination: "A_B")]),
            SchemaDescriptor.Entity(name: "D"),
        ]

        XCTAssertThrowsError(try SchemaBuilder.build(SchemaDescriptor(entities))) { error in
            guard case SwiftDataError.unsupportedSchemaProperty = error else {
                return XCTFail("Unexpected error: \\(error)")
            }
        }
    }

    func testRejectsCollidingIdentifiers() {
        let collisions: [SchemaDescriptor] = [
            SchemaDescriptor([SchemaDescriptor.Entity(name: "Thing"), SchemaDescriptor.Entity(name: "thing")]),
            SchemaDescriptor([SchemaDescriptor.Entity(name: "_osd_meta", attributes: [SchemaDescriptor.Attribute(name: "value", type: "Int")])]),
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "Item",
                    attributes: [
                        SchemaDescriptor.Attribute(name: "name", type: "String"),
                        SchemaDescriptor.Attribute(name: "NAME", type: "Int"),
                    ])
            ]),
            SchemaDescriptor([SchemaDescriptor.Entity(name: "Item", attributes: [SchemaDescriptor.Attribute(name: "primarykey", type: "Int")])]),
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "Item",
                    attributes: [SchemaDescriptor.Attribute(name: "id", type: "Int")],
                    relationships: [SchemaDescriptor.Relationship(name: "ID", destination: "Item")]
                )
            ]),
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "A",
                    attributes: [SchemaDescriptor.Attribute(name: "index", type: "Int", options: [.unique])],
                    relationships: [SchemaDescriptor.Relationship(name: "index", destination: "B")]
                ),
                SchemaDescriptor.Entity(name: "B"),
            ]),
            SchemaDescriptor([
                SchemaDescriptor.Entity(
                    name: "A",
                    relationships: [SchemaDescriptor.Relationship(name: "items", destination: "B", isToMany: true)]
                ),
                SchemaDescriptor.Entity(name: "_A_ITEMS_B"),
                SchemaDescriptor.Entity(name: "B"),
            ]),
        ]
        for (index, schema) in collisions.enumerated() {
            XCTAssertThrowsError(try SchemaBuilder.build(schema), "collision case \(index)") { error in
                guard case SwiftDataError.unsupportedSchemaProperty = error else {
                    return XCTFail("Unexpected error: \\(error)")
                }
            }
        }
    }

    func testSortingUsesUTF8ByteOrder() throws {
        let schema = SchemaDescriptor([
            SchemaDescriptor.Entity(name: "é", attributes: [SchemaDescriptor.Attribute(name: "é", type: "String")]),
            SchemaDescriptor.Entity(
                name: "Z",
                attributes: [SchemaDescriptor.Attribute(name: "a", type: "Int"), SchemaDescriptor.Attribute(name: "é", type: "String")]),
        ])
        let built = try SchemaBuilder.build(schema)
        XCTAssertEqual(built.bootstrapRows.map(\.name), ["Z", "é"])
        XCTAssertTrue(
            built.statements.contains(
                "CREATE TABLE ZZ (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZA INTEGER, ZÉ VARCHAR);"
            )
        )
    }
}
