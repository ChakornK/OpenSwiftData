import XCTest
import OSDCore
@testable import OSDStorage

final class PredicateCompilerTests: XCTestCase {
    func testCapturedScalarValuesAreTyped() throws {
        XCTAssertEqual(
            try PredicateIRBuilder.build(.capture(typeName: "Swift.Int", description: "21")), .value(.int(21)))
        XCTAssertEqual(
            try PredicateIRBuilder.build(.capture(typeName: "Swift.String", description: "Ada")),
            .value(.text("Ada")))
    }

    func testResolvesPredicateKeyPathThroughTypedMetadata() throws {
        let predicate = #Predicate<CompilerRow> { $0.age > 4 }
        let keyPath = \CompilerRow.age
        let tree = try PredicateMirrorWalker.walk(predicate.expression) { candidate in
            guard candidate == keyPath else {
                throw SwiftDataError.unsupportedPredicate("unresolved keypath")
            }
            return "age"
        }
        guard case let .expression(_, children) = tree,
            case let .expression(_, lhsChildren)? = children.first(where: { $0.0 == "lhs" })?.1,
            case let .capture(typeName, description)? = lhsChildren.first(where: { $0.0 == "keyPath" })?.1
        else {
            return XCTFail("Expected a resolved key-path capture")
        }
        XCTAssertEqual(typeName, "OpenSwiftData.PropertyReference")
        XCTAssertEqual(description, "age")
    }

    func testCompilesRealPredicateKeyPathAndEqualityNode() throws {
        let predicate = #Predicate<CompilerRow> { $0.age == 7 }
        let tree = try PredicateMirrorWalker.walk(predicate.expression)

        let compiled = try SQLCompiler.compile(tree, entity: "Person")

        XCTAssertEqual(compiled.sql, "(t0.ZAGE = ?)")
        XCTAssertEqual(compiled.arguments, [.int(7)])
    }

    func testCompilesOptionalNilEqualityAsNullCheck() throws {
        let isNil = #Predicate<CompilerRow> { $0.nickname == nil }
        let isNotNil = #Predicate<CompilerRow> { $0.nickname != nil }
        let nilPlan = try SQLCompiler.compile(PredicateMirrorWalker.walk(isNil.expression), entity: "Person")
        let notNilPlan = try SQLCompiler.compile(PredicateMirrorWalker.walk(isNotNil.expression), entity: "Person")

        XCTAssertEqual(nilPlan.sql, "(t0.ZNICKNAME IS NULL)")
        XCTAssertEqual(notNilPlan.sql, "(t0.ZNICKNAME IS NOT NULL)")
        XCTAssertTrue(nilPlan.arguments.isEmpty)
        XCTAssertTrue(notNilPlan.arguments.isEmpty)
    }

    func testNestedToOnePredicateBindsDiscriminatorsInSQLOrder() throws {
        let ir = PredicateIR.comparison(
            .equal,
            .keyPath(["middle", "leaf", "title"]),
            .value(.text("match")))
        let relationships = [
            RuntimePredicateRelationship(
                ownerEntityName: "Root",
                propertyName: "middle",
                destinationEntityName: "Middle",
                destinationRootEntityName: "Middle",
                foreignKeyColumnName: "middle",
                destinationEntityIDs: [11]),
            RuntimePredicateRelationship(
                ownerEntityName: "Middle",
                propertyName: "leaf",
                destinationEntityName: "Leaf",
                destinationRootEntityName: "Leaf",
                foreignKeyColumnName: "leaf",
                destinationEntityIDs: [22]),
        ]

        let compiled = try SQLCompiler.compile(ir, entity: "Root", relationships: relationships)

        XCTAssertEqual(
            compiled.sql,
            "((SELECT (SELECT osd_rel_2.ZTITLE FROM ZLEAF AS osd_rel_2 "
                + "WHERE osd_rel_2.Z_PK = osd_rel_1.ZLEAF AND osd_rel_2.Z_ENT IN (?) LIMIT 1) "
                + "FROM ZMIDDLE AS osd_rel_1 WHERE osd_rel_1.Z_PK = t0.ZMIDDLE AND osd_rel_1.Z_ENT IN (?) LIMIT 1) = ?)"
        )
        XCTAssertEqual(compiled.arguments, [.int(22), .int(11), .text("match")])
    }

    func testUnsignedCollectionOrderingCompilesInSQLCompiler() throws {
        let ir = PredicateIR.collectionAllCompare(
            "values", "UInt64", .greaterThan, .value(.int(1)))
        let compiled = try SQLCompiler.compile(ir, entity: "Owner")
        XCTAssertEqual(
            compiled.sql,
            "osd_json_array_all_compare(t0.ZVALUES, ?, ?, ?)"
        )
        XCTAssertEqual(compiled.arguments, [.int(1), .text("UInt64"), .text("greaterThan")])
    }

    func testArithmeticRejectsFloatUntilFloatFunctionsAreAvailable() throws {
        let node = PredicateMirrorWalker.Node.expression(
            name: "Arithmetic",
            children: [
                ("lhs", .propertyReference("score")),
                ("rhs", .typedValue(.double(2.0))),
                ("op", .capture(typeName: "PredicateExpressions.ArithmeticOperator", description: "add")),
            ])
        XCTAssertThrowsError(
            try PredicateIRBuilder.build(node, attributeTypes: ["score": "Float"])
        ) { error in
            guard case SwiftDataError.unsupportedPredicate = error else {
                return XCTFail("Expected unsupported Float arithmetic, got \(error)")
            }
        }
    }

    func testArithmeticRejectsDoubleRemainder() throws {
        let node = PredicateMirrorWalker.Node.expression(
            name: "Arithmetic",
            children: [
                ("lhs", .propertyReference("score")),
                ("rhs", .typedValue(.double(2.0))),
                ("op", .capture(typeName: "PredicateExpressions.ArithmeticOperator", description: "remainder")),
            ])
        XCTAssertThrowsError(try PredicateIRBuilder.build(node, attributeTypes: ["score": "Double"]))
    }

    func testArithmeticRejectsMixedAndUnsignedOperands() throws {
        let lhs = PredicateMirrorWalker.Node.propertyReference("score")
        let rhs = PredicateMirrorWalker.Node.typedValue(.int(1))
        let mixed = PredicateMirrorWalker.Node.expression(
            name: "Arithmetic",
            children: [
                ("lhs", lhs),
                ("rhs", rhs),
                ("op", .capture(typeName: "PredicateExpressions.ArithmeticOperator", description: "add")),
            ])
        XCTAssertThrowsError(
            try PredicateIRBuilder.build(mixed, attributeTypes: ["score": "Double"]))

        let unsigned = PredicateMirrorWalker.Node.expression(
            name: "Arithmetic",
            children: [
                ("lhs", .propertyReference("count")),
                ("rhs", rhs),
                ("op", .capture(typeName: "PredicateExpressions.ArithmeticOperator", description: "add")),
            ])
        XCTAssertThrowsError(try PredicateIRBuilder.build(unsigned, attributeTypes: ["count": "UInt64"]))
    }

    func testArithmeticAcceptsQualifiedIntegerPathsAndCoalescing() throws {
        let keyPath = PredicateMirrorWalker.Node.propertyReference("owner.count")
        let coalesced = PredicateMirrorWalker.Node.expression(
            name: "NilCoalesce",
            children: [("lhs", keyPath), ("rhs", .typedValue(.int(0)))])
        let arithmetic = PredicateMirrorWalker.Node.expression(
            name: "Arithmetic",
            children: [
                ("lhs", coalesced),
                ("rhs", .typedValue(.int(1))),
                ("op", .capture(typeName: "PredicateExpressions.ArithmeticOperator", description: "add")),
            ])
        XCTAssertNoThrow(
            try PredicateIRBuilder.build(
                arithmetic,
                attributeTypes: ["owner.count": "Int?"]))
    }

    func testArithmeticSelectsDoubleIRForDoubleOperands() throws {
        let node = PredicateMirrorWalker.Node.expression(
            name: "Arithmetic",
            children: [
                ("lhs", .propertyReference("score")),
                ("rhs", .typedValue(.double(1.5))),
                ("op", .capture(typeName: "PredicateExpressions.ArithmeticOperator", description: "add")),
            ])
        XCTAssertEqual(
            try PredicateIRBuilder.build(node, attributeTypes: ["score": "Double"]),
            .realArithmetic(.add, .keyPath(["score"]), .value(.double(1.5))))

        let division = PredicateMirrorWalker.Node.expression(
            name: "FloatDivision",
            children: [
                ("lhs", .propertyReference("score")),
                ("rhs", .typedValue(.double(2.0))),
            ])
        XCTAssertEqual(
            try PredicateIRBuilder.build(division, attributeTypes: ["score": "Double"]),
            .realArithmetic(.divide, .keyPath(["score"]), .value(.double(2.0))))

        let nested = PredicateMirrorWalker.Node.expression(
            name: "Arithmetic",
            children: [
                (
                    "lhs",
                    .expression(
                        name: "Arithmetic",
                        children: [
                            ("lhs", .propertyReference("score")),
                            ("rhs", .typedValue(.double(2.0))),
                            (
                                "op",
                                .capture(typeName: "PredicateExpressions.ArithmeticOperator", description: "multiply")
                            ),
                        ])
                ),
                ("rhs", .typedValue(.double(1.0))),
                ("op", .capture(typeName: "PredicateExpressions.ArithmeticOperator", description: "add")),
            ])
        XCTAssertEqual(
            try PredicateIRBuilder.build(nested, attributeTypes: ["score": "Double"]),
            .realArithmetic(
                .add,
                .realArithmetic(.multiply, .keyPath(["score"]), .value(.double(2.0))),
                .value(.double(1.0))))

        let qualified = PredicateMirrorWalker.Node.expression(
            name: "Arithmetic",
            children: [
                ("lhs", .propertyReference("amount")),
                ("rhs", .typedValue(.double(1.0))),
                ("op", .capture(typeName: "PredicateExpressions.ArithmeticOperator", description: "add")),
            ])
        XCTAssertNoThrow(
            try PredicateIRBuilder.build(qualified, attributeTypes: ["owner.amount": "Double"]))
    }

    func testPartialIntegerRangeNodesLowerWithCorrectBoundSemantics() throws {
        let cases: [(String, String, Int64, PredicateIR.ComparisonOperator)] = [
            ("PartialRangeFrom", "lowerBound", 3, .greaterThanOrEqual),
            ("PartialRangeThrough", "upperBound", 7, .lessThanOrEqual),
            ("PartialRangeUpTo", "upperBound", 7, .lessThan),
        ]
        for (name, boundName, bound, operation) in cases {
            let range = PredicateMirrorWalker.Node.expression(
                name: name, children: [(boundName, .typedValue(.int(bound)))])
            let node = PredicateMirrorWalker.Node.expression(
                name: "RangeExpressionContains",
                children: [
                    ("range", range),
                    ("element", .propertyReference("age")),
                ])
            XCTAssertEqual(
                try PredicateIRBuilder.build(node, attributeTypes: ["age": "Int"]),
                .comparison(operation, .keyPath(["age"]), .value(.int(bound))))
        }
    }

    func testPartialIntegerRangeRejectsNonIntegerBound() throws {
        let range = PredicateMirrorWalker.Node.expression(
            name: "PartialRangeFrom",
            children: [("lowerBound", .typedValue(.double(3.5)))])
        let node = PredicateMirrorWalker.Node.expression(
            name: "RangeExpressionContains",
            children: [
                ("range", range),
                ("element", .propertyReference("age")),
            ])
        XCTAssertThrowsError(try PredicateIRBuilder.build(node, attributeTypes: ["age": "Int"]))
    }

    func testRealArithmeticSQLAndPlanUseMatchingExpression() throws {
        let ir = PredicateIR.comparison(
            .greaterThan,
            .realArithmetic(.multiply, .value(.double(3.0)), .value(.double(2.0))),
            .value(.double(5.0)))
        let compiled = try SQLCompiler.compile(ir, entity: "DoubleOwner")
        XCTAssertEqual(compiled.sql, "(osd_real_multiply(?, ?) > ?)")
        XCTAssertEqual(compiled.arguments, [.double(3.0), .double(2.0), .double(5.0)])

        XCTAssertNotNil(PredicatePlanBuilder.build(ir))
    }

    func testOptionalStringEqualityCaptureIsNotLoweredAsNull() throws {
        let node = PredicateMirrorWalker.Node.expression(
            name: "Equal",
            children: [
                ("lhs", .propertyReference("optionalValue")),
                ("rhs", .expression(name: "Value", children: [("value", .typedValue(.text("value")))])),
            ])
        let ir = try PredicateIRBuilder.build(node, attributeTypes: ["optionalValue": "String?"])
        let compiled = try SQLCompiler.compile(ir, entity: "Item")

        XCTAssertEqual(compiled.sql, "(t0.ZOPTIONALVALUE IS ?)")
        XCTAssertEqual(compiled.arguments, [.text("value")])
    }

    func testStringContainsAcceptsOptionalStringAndRejectsOptionalInteger() throws {
        let node = PredicateMirrorWalker.Node.expression(
            name: "CollectionContainsCollection",
            children: [
                ("base", .propertyReference("optionalValue")),
                ("other", .typedValue(.text("term"))),
            ])
        XCTAssertNoThrow(try PredicateIRBuilder.build(node, attributeTypes: ["optionalValue": "String?"]))
        XCTAssertThrowsError(try PredicateIRBuilder.build(node, attributeTypes: ["optionalValue": "Int?"]))
    }

    func testOptionalInequalityRewritesNilAsNotEqualToCapturedValue() throws {
        let node = PredicateMirrorWalker.Node.expression(
            name: "NotEqual",
            children: [
                ("lhs", .propertyReference("optionalValue")),
                ("rhs", .typedValue(.text("value"))),
            ])
        let ir = try PredicateIRBuilder.build(
            node,
            attributeTypes: ["optionalValue": "String"],
            optionalAttributeNames: ["optionalValue"])
        guard case .optionalComparison(.notEqual, .keyPath(["optionalValue"]), .value(.text("value")), false) = ir
        else {
            return XCTFail("Expected optional inequality to retain a null-safe comparison node")
        }
    }

    func testOptionalOrderingGuardsNullOperandsWhileRequiredOrderingStaysNative() throws {
        let node = PredicateMirrorWalker.Node.expression(
            name: "Comparison",
            children: [
                ("op", .capture(typeName: "ComparisonOperator", description: "lessThan")),
                ("lhs", .propertyReference("optionalCount")),
                ("rhs", .typedValue(.int(5))),
            ])
        let optionalIR = try PredicateIRBuilder.build(
            node,
            attributeTypes: ["optionalCount": "Int"],
            optionalAttributeNames: ["optionalCount"])
        guard case .optionalComparison(.lessThan, .keyPath(["optionalCount"]), .value(.int(5)), false) = optionalIR
        else {
            return XCTFail("Expected optional ordering to retain its nullability marker")
        }

        let requiredIR = try PredicateIRBuilder.build(node, attributeTypes: ["optionalCount": "Int"])
        XCTAssertEqual(requiredIR, .comparison(.lessThan, .keyPath(["optionalCount"]), .value(.int(5))))
    }

    func testCollectionPredicateAcceptsQualifiedScalarAndRejectsBlobOrCodableTypes() throws {
        func node(for property: String) -> PredicateMirrorWalker.Node {
            .expression(
                name: "OSDSequenceContainsWhere",
                children: [
                    ("sequence", .propertyReference("items")),
                    (
                        "test",
                        .expression(
                            name: "Equal",
                            children: [
                                ("lhs", .propertyReference("items[].\(property)")),
                                ("rhs", .typedValue(.text("value"))),
                            ])
                    ),
                ])
        }

        XCTAssertNoThrow(
            try PredicateIRBuilder.build(
                node(for: "rank"), attributeTypes: ["items[].rank": "Swift.Int?"]))

        for type in ["Data", "UUID", "Payload"] {
            XCTAssertThrowsError(
                try PredicateIRBuilder.build(node(for: "payload"), attributeTypes: ["items[].payload": type])
            ) {
                guard case SwiftDataError.unsupportedPredicate = $0 else {
                    return XCTFail("Expected unsupportedPredicate, got \($0)")
                }
            }
        }
    }

    func testCollectionStringPredicateRejectsNonStringElementAttribute() throws {
        let node = PredicateMirrorWalker.Node.expression(
            name: "OSDSequenceContainsWhere",
            children: [
                ("sequence", .propertyReference("items")),
                (
                    "test",
                    .expression(
                        name: "CollectionContainsCollection",
                        children: [
                            ("base", .propertyReference("items[].rank")),
                            ("other", .typedValue(.text("1"))),
                        ])
                ),
            ])

        XCTAssertThrowsError(
            try PredicateIRBuilder.build(node, attributeTypes: ["items[].rank": "Int"])
        ) { error in
            guard case SwiftDataError.unsupportedPredicate = error else {
                return XCTFail("Expected unsupportedPredicate, got \(error)")
            }
        }

    }

    func testDecimalOrderingPredicateUsesExactCollation() throws {
        let node = PredicateMirrorWalker.Node.expression(
            name: "Comparison",
            children: [
                ("op", .capture(typeName: "ComparisonOperator", description: "lessThan")),
                ("lhs", .propertyReference("amount")),
                ("rhs", .typedValue(.text("10"))),
            ])

        let ir = try PredicateIRBuilder.build(node, attributeTypes: ["amount": "Decimal"])
        guard case .decimalComparison(.lessThan, .keyPath(["amount"]), .value(.text("10"))) = ir else {
            return XCTFail("Expected exact Decimal ordering IR")
        }
        let compiled = try SQLCompiler.compile(ir, entity: "Item")
        XCTAssertEqual(compiled.sql, "(t0.ZAMOUNT COLLATE OSD_DECIMAL < ?)")
        XCTAssertEqual(compiled.arguments, [.text("10")])

        let coalesced = PredicateMirrorWalker.Node.expression(
            name: "Comparison",
            children: [
                ("op", .capture(typeName: "ComparisonOperator", description: "lessThan")),
                (
                    "lhs",
                    .expression(
                        name: "NilCoalesce",
                        children: [
                            ("lhs", .propertyReference("amount")),
                            ("rhs", .typedValue(.text("0"))),
                        ])
                ),
                ("rhs", .typedValue(.text("10"))),
            ])
        let coalescedIR = try PredicateIRBuilder.build(coalesced, attributeTypes: ["amount": "Foundation.Decimal"])
        guard case .decimalComparison(.lessThan, .nilCoalesce, .value(.text("10"))) = coalescedIR else {
            return XCTFail("Expected coalesced Decimal ordering IR")
        }
    }

    func testCompilesComparisonAndRebindsStructuralCache() throws {
        let first = #Predicate<CompilerRow> { $0.age > 18 }
        let second = #Predicate<CompilerRow> { $0.age > 65 }
        let firstPlan = try SQLCompiler.compile(PredicateMirrorWalker.walk(first.expression), entity: "Person")
        let secondPlan = try SQLCompiler.compile(PredicateMirrorWalker.walk(second.expression), entity: "Person")

        XCTAssertEqual(firstPlan.sql, "(t0.ZAGE > ?)")
        XCTAssertEqual(firstPlan.cacheKey, secondPlan.cacheKey)
        XCTAssertEqual(firstPlan.arguments, [.int(18)])
        XCTAssertEqual(secondPlan.arguments, [.int(65)])
    }

    func testConditionalPredicateCompilesToCaseExpression() throws {
        let conditional = PredicateMirrorWalker.Node.expression(
            name: "Conditional",
            children: [
                (
                    "test",
                    .expression(
                        name: "Comparison",
                        children: [
                            ("op", .capture(typeName: "ComparisonOperator", description: "greaterThan")),
                            ("lhs", .propertyReference("count")),
                            ("rhs", .typedValue(.int(5))),
                        ])
                ),
                (
                    "trueBranch",
                    .expression(
                        name: "Equal",
                        children: [("lhs", .propertyReference("title")), ("rhs", .typedValue(.text("yes")))])
                ),
                (
                    "falseBranch",
                    .expression(
                        name: "Equal",
                        children: [("lhs", .propertyReference("title")), ("rhs", .typedValue(.text("no")))])
                ),
            ])

        let ir = try PredicateIRBuilder.build(conditional, attributeTypes: ["count": "Int", "title": "String"])
        let compiled = try SQLCompiler.compile(ir, entity: "Item")

        XCTAssertEqual(
            compiled.sql,
            "(CASE WHEN (t0.ZCOUNT > ?) THEN (t0.ZTITLE = ?) ELSE (t0.ZTITLE = ?) END)")
        XCTAssertEqual(compiled.arguments, [.int(5), .text("yes"), .text("no")])
    }

    func testCompilesOptionalEqualityAndCoalescing() throws {
        let predicate = #Predicate<CompilerRow> { ($0.nickname ?? "") == "Ada" }
        let compiled = try SQLCompiler.compile(PredicateMirrorWalker.walk(predicate.expression), entity: "Person")

        XCTAssertTrue(compiled.sql.contains("COALESCE"))
        XCTAssertTrue(compiled.sql.contains(" = "))
        XCTAssertEqual(compiled.arguments, [.text(""), .text("Ada")])
    }

    func testUnknownCollectionMappingThrowsUnsupportedPredicate() throws {
        let predicate = #Predicate<CompilerRow> { $0.tags.contains("swift") }
        let tree = try PredicateMirrorWalker.walk(predicate.expression)

        XCTAssertThrowsError(try SQLCompiler.compile(tree, entity: "Person")) { error in
            guard case SwiftDataError.unsupportedPredicate = error else {
                XCTFail("Expected unsupportedPredicate, got \(error)")
                return
            }
        }
    }

    func testIRRejectsDuplicateAndUnexpectedChildLabels() {
        let duplicate = PredicateMirrorWalker.Node.expression(
            name: "Equal",
            children: [
                ("lhs", .capture(typeName: "Swift.Int", description: "1")),
                ("lhs", .capture(typeName: "Swift.Int", description: "2")),
                ("rhs", .capture(typeName: "Swift.Int", description: "3")),
            ])
        let extra = PredicateMirrorWalker.Node.expression(
            name: "Equal",
            children: [
                ("lhs", .capture(typeName: "Swift.Int", description: "1")),
                ("rhs", .capture(typeName: "Swift.Int", description: "2")),
                ("other", .capture(typeName: "Swift.Int", description: "3")),
            ])

        XCTAssertThrowsError(try PredicateIRBuilder.build(duplicate))
        XCTAssertThrowsError(try PredicateIRBuilder.build(extra))
    }

    func testCataloguedButUnloweredCollectionNodeFailsClosed() {
        let node = PredicateMirrorWalker.Node.expression(
            name: "CollectionContainsCollection",
            children: [
                ("base", .capture(typeName: "Swift.Array<Swift.String>", description: "[]")),
                ("other", .capture(typeName: "Swift.Array<Swift.String>", description: "[]")),
            ])

        XCTAssertThrowsError(try PredicateIRBuilder.build(node)) { error in
            guard case SwiftDataError.unsupportedPredicate = error else {
                return XCTFail("Expected unsupportedPredicate, got \(error)")
            }
        }
    }

    func testCompilesLocalizedStandardContainsToRegisteredFunction() throws {
        let node = PredicateMirrorWalker.Node.expression(
            name: "OSDLocalizedStandardContains",
            children: [
                ("root", .propertyReference("title")),
                ("other", .typedValue(.text("cafe"))),
            ])
        let predicate = try PredicateIRBuilder.build(node, attributeTypes: ["title": "String"])
        let compiled = try SQLCompiler.compile(predicate, entity: "Item")

        XCTAssertEqual(compiled.sql, "osd_localized_standard_contains(t0.ZTITLE, ?)")
        XCTAssertEqual(compiled.arguments, [.text("cafe")])
    }

    func testCompilesStringPrefixToRegisteredFunction() throws {
        let predicate = PredicateIR.stringStartsWith(.keyPath(["title"]), .value(.text("caf")))
        let compiled = try SQLCompiler.compile(predicate, entity: "Item")

        XCTAssertEqual(compiled.sql, "osd_string_starts_with(t0.ZTITLE, ?)")
        XCTAssertEqual(compiled.arguments, [.text("caf")])
    }

    func testCollectionContainsArrayDoesNotLowerAsStringContains() {
        let node = PredicateMirrorWalker.Node.expression(
            name: "CollectionContainsCollection",
            children: [
                ("base", .propertyReference("tags")),
                ("other", .typedValue(.text("swift"))),
            ])

        XCTAssertThrowsError(try PredicateIRBuilder.build(node, attributeTypes: ["tags": "[String]"]))
        XCTAssertThrowsError(try PredicateIRBuilder.build(node))
    }

    func testClosedIntegerRangeLowersToInclusiveComparisons() throws {
        let node = PredicateMirrorWalker.Node.expression(
            name: "RangeExpressionContains",
            children: [
                (
                    "range",
                    .expression(
                        name: "ClosedRange",
                        children: [
                            ("lower", .typedValue(.int(2))),
                            ("upper", .typedValue(.int(7))),
                        ])
                ),
                ("element", .propertyReference("count")),
            ])
        let ir = try PredicateIRBuilder.build(node, attributeTypes: ["count": "Int"])
        let compiled = try SQLCompiler.compile(ir, entity: "Item")

        XCTAssertEqual(compiled.sql, "((t0.ZCOUNT >= ?) AND (t0.ZCOUNT <= ?))")
        XCTAssertEqual(compiled.arguments, [.int(2), .int(7)])
    }

    func testHalfOpenIntegerRangeUsesExclusiveUpperBound() throws {
        let node = PredicateMirrorWalker.Node.expression(
            name: "RangeExpressionContains",
            children: [
                (
                    "range",
                    .expression(
                        name: "Range",
                        children: [
                            ("lower", .typedValue(.int(2))),
                            ("upper", .typedValue(.int(7))),
                        ])
                ),
                ("element", .propertyReference("count")),
            ])

        let ir = try PredicateIRBuilder.build(node, attributeTypes: ["count": "Int"])
        let compiled = try SQLCompiler.compile(ir, entity: "Item")

        XCTAssertEqual(compiled.sql, "((t0.ZCOUNT >= ?) AND (t0.ZCOUNT < ?))")
        XCTAssertEqual(compiled.arguments, [.int(2), .int(7)])
    }

    func testMalformedRangeFailsWithoutDroppingBounds() {
        let node = PredicateMirrorWalker.Node.expression(
            name: "RangeExpressionContains",
            children: [
                ("range", .expression(name: "ClosedRange", children: [("lower", .typedValue(.int(2)))])),
                ("element", .propertyReference("count")),
            ])

        XCTAssertThrowsError(try PredicateIRBuilder.build(node, attributeTypes: ["count": "Int"]))
    }

}

private struct CompilerRow {
    let age: Int
    let nickname: String?
    let tags: [String]
}
