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

    func testOptionalStringEqualityCaptureIsNotLoweredAsNull() throws {
        let node = PredicateMirrorWalker.Node.expression(
            name: "Equal",
            children: [
                ("lhs", .propertyReference("optionalValue")),
                ("rhs", .expression(name: "Value", children: [("value", .typedValue(.text("value")))])),
            ])
        let ir = try PredicateIRBuilder.build(node, attributeTypes: ["optionalValue": "String?"])
        let compiled = try SQLCompiler.compile(ir, entity: "Item")

        XCTAssertEqual(compiled.sql, "(t0.ZOPTIONALVALUE = ?)")
        XCTAssertEqual(compiled.arguments, [.text("value")])
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

    func testCapturedPartialRangeFailsClosedUntilRangeCaptureEncodingExists() {
        let node = PredicateMirrorWalker.Node.expression(
            name: "RangeExpressionContains",
            children: [
                (
                    "range",
                    .expression(
                        name: "Value",
                        children: [
                            ("value", .capture(typeName: "Swift.PartialRangeFrom<Swift.Int>", description: "3..."))
                        ])
                ),
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
