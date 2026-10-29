import Foundation
import OSDStorage
import XCTest

private struct PredicateFixture {
    let count: Int
    let title: String
    let optionalTitle: String?
    let tags: [String]
}

private struct UnknownExpression {
    let child: Int
}

final class PredicateMirrorWalkerTests: XCTestCase {
    func testWalksComparisonAndCapturesBoundValue() throws {
        let predicate = #Predicate<PredicateFixture> { $0.count > 4 }
        let node = try PredicateMirrorWalker.walk(predicate.expression)
        guard case let .expression(name, children) = node else {
            XCTFail("Expected an expression node")
            return
        }
        XCTAssertEqual(name, "Comparison")
        XCTAssertEqual(children.map(\.0), ["op", "lhs", "rhs"])
        guard case .expression("Value", _) = children[2].1 else {
            XCTFail("Expected the comparison value to be captured")
            return
        }
    }

    func testWalksNegationUsingWrappedChild() throws {
        let predicate = #Predicate<PredicateFixture> { !($0.count > 4) }
        let node = try PredicateMirrorWalker.walk(predicate.expression)
        guard case let .expression(name, children) = node else {
            return XCTFail("Expected a negation node")
        }
        XCTAssertEqual(name, "Negation")
        XCTAssertEqual(children.map(\.0), ["wrapped"])

        let compiled = try SQLCompiler.compile(node, entity: "Item")
        XCTAssertTrue(compiled.sql.hasPrefix("(NOT "))
        XCTAssertEqual(compiled.arguments, [.int(4)])
    }

    func testStringAndCollectionContainsUseDistinctPredicateNodes() throws {
        let needle = "e\u{301}"
        let stringPredicate = #Predicate<PredicateFixture> { $0.title.contains(needle) }
        let collectionPredicate = #Predicate<PredicateFixture> { $0.tags.contains(needle) }
        let stringMirror = Mirror(reflecting: stringPredicate.expression)
        let collectionMirror = Mirror(reflecting: collectionPredicate.expression)

        XCTAssertEqual(
            PredicateNodeCatalog.entry(for: String(reflecting: type(of: stringPredicate.expression)))?.name,
            "CollectionContainsCollection")
        XCTAssertEqual(stringMirror.children.compactMap(\.label), ["base", "other"])
        XCTAssertEqual(
            PredicateNodeCatalog.entry(for: String(reflecting: type(of: collectionPredicate.expression)))?.name,
            "SequenceContains")
        XCTAssertEqual(collectionMirror.children.compactMap(\.label), ["sequence", "element"])
    }

    func testStringStartsWithReflectionShape() throws {
        let prefix = "e\u{301}"
        let predicate = #Predicate<PredicateFixture> { $0.title.starts(with: prefix) }
        let mirror = Mirror(reflecting: predicate.expression)
        let typeName = String(reflecting: type(of: predicate.expression))
        XCTAssertNotNil(
            PredicateNodeCatalog.entry(for: typeName), "\(typeName): \(mirror.children.map(\.label))")
    }

    func testArithmeticAndRangePredicateReflectionShapes() throws {
        let lower = 2
        let upper = 8
        let arithmetic = #Predicate<PredicateFixture> { $0.count + 1 > lower }
        let range = #Predicate<PredicateFixture> { (lower...upper).contains($0.count) }
        let halfOpenRange = #Predicate<PredicateFixture> { (lower..<upper).contains($0.count) }
        let fromRange: PartialRangeFrom<Int> = 3...
        let throughRange: PartialRangeThrough<Int> = ...7
        let upToRange: PartialRangeUpTo<Int> = ..<7
        let from = #Predicate<PredicateFixture> { fromRange.contains($0.count) }
        let through = #Predicate<PredicateFixture> { throughRange.contains($0.count) }
        let upTo = #Predicate<PredicateFixture> { upToRange.contains($0.count) }
        func describe(_ value: Any, depth: Int = 0) -> [String] {
            let mirror = Mirror(reflecting: value)
            let name = String(reflecting: type(of: value))
            return ["\(String(repeating: " ", count: depth))\(name): \(mirror.children.compactMap(\.label))"]
                + mirror.children.flatMap { describe($0.value, depth: depth + 1) }
        }
        let arithmeticShape = describe(arithmetic.expression).joined(separator: "\n")
        let rangeShape = describe(range.expression).joined(separator: "\n")
        let halfOpenShape = describe(halfOpenRange.expression).joined(separator: "\n")
        let fromShape = describe(from.expression).joined(separator: "\n")
        let throughShape = describe(through.expression).joined(separator: "\n")
        let upToShape = describe(upTo.expression).joined(separator: "\n")
        XCTAssertTrue(
            arithmeticShape.contains("Arithmetic") && arithmeticShape.contains("ArithmeticOperator"), arithmeticShape)
        XCTAssertTrue(rangeShape.contains("RangeExpressionContains") && rangeShape.contains("ClosedRange"), rangeShape)
        XCTAssertTrue(
            halfOpenShape.contains("RangeExpressionContains") && halfOpenShape.contains("Range<"), halfOpenShape)
        XCTAssertTrue(fromShape.contains("PartialRangeFrom"), fromShape)
        XCTAssertTrue(throughShape.contains("PartialRangeThrough"), throughShape)
        XCTAssertTrue(upToShape.contains("PartialRangeUpTo"), upToShape)
        XCTAssertTrue(fromShape.contains("[\"lowerBound\"]"), fromShape)
        XCTAssertTrue(throughShape.contains("[\"upperBound\"]"), throughShape)
        XCTAssertTrue(upToShape.contains("[\"upperBound\"]"), upToShape)
        let rangeNode = try PredicateMirrorWalker.walk(range.expression)
        guard case let .expression(name, children) = rangeNode else {
            return XCTFail("Expected range containment expression")
        }
        XCTAssertEqual(name, "RangeExpressionContains")
        XCTAssertEqual(children.map(\.0), ["range", "element"])
    }

    func testTernaryAndOptionalFlatMapReflectionShapes() {
        let threshold = 5
        let optionalName = "target"
        let ternary = #Predicate<PredicateFixture> {
            $0.count > threshold ? $0.title == "target" : $0.title == "other"
        }
        let optional = #Predicate<PredicateFixture> { $0.optionalTitle?.contains(optionalName) ?? false }
        func describe(_ value: Any) -> [String] {
            let mirror = Mirror(reflecting: value)
            let name = String(reflecting: type(of: value))
            return ["\(name): \(mirror.children.compactMap(\.label))"]
                + mirror.children.flatMap { describe($0.value) }
        }
        let ternaryShape = describe(ternary.expression).joined(separator: "\n")
        let optionalShape = describe(optional.expression).joined(separator: "\n")
        XCTAssertTrue(ternaryShape.contains("PredicateExpressions.Conditional"), ternaryShape)
        XCTAssertTrue(optionalShape.contains("PredicateExpressions.NilCoalesce"), optionalShape)
    }

    func testWalksBooleanAndCollectionNodes() throws {
        let predicate = #Predicate<PredicateFixture> { $0.count > 4 && $0.tags.contains("swift") }
        let node = try PredicateMirrorWalker.walk(predicate.expression)
        guard case let .expression(name, children) = node else {
            XCTFail("Expected an expression node")
            return
        }
        XCTAssertEqual(name, "Conjunction")
        XCTAssertEqual(children.map(\.0), ["lhs", "rhs"])
        guard case let .expression(collectionName, _) = children[1].1 else {
            XCTFail("Expected a collection expression")
            return
        }
        XCTAssertEqual(collectionName, "SequenceContains")
    }

    func testRejectsUnknownNodesAndMissingFields() {
        XCTAssertThrowsError(try PredicateMirrorWalker.walk(UnknownExpression(child: 1))) { error in
            XCTAssertEqual(
                error as? PredicateCatalogError, .unsupportedNode(String(reflecting: UnknownExpression.self)))
        }
    }

    func testCatalogRecognizesQualifiedGenericAndNongenericNames() {
        XCTAssertEqual(
            PredicateNodeCatalog.entry(
                for: "FoundationEssentials.PredicateExpressions.Comparison<Swift.Int, Swift.String>"
            )?.name,
            "Comparison")
        XCTAssertEqual(
            PredicateNodeCatalog.entry(for: "FoundationEssentials.PredicateExpressions.VariableID")?.name,
            "VariableID")
        XCTAssertNil(PredicateNodeCatalog.entry(for: "FoundationEssentials.PredicateExpressions.Unknown<Swift.Int>"))
        XCTAssertNil(PredicateNodeCatalog.entry(for: "Example.UnrelatedKeyPath"))
        XCTAssertNil(PredicateNodeCatalog.entry(for: "Example.Value"))
        XCTAssertEqual(PredicateNodeCatalog.entry(for: "Comparison")?.name, "Comparison")
        XCTAssertEqual(
            PredicateNodeCatalog.entry(for: "Swift.ReferenceWritableKeyPath<Example.Model, Swift.Int>")?.name,
            "Swift.KeyPath")
        XCTAssertEqual(
            PredicateNodeCatalog.entry(for: "Foundation.PredicateExpressions.Comparison<Swift.Int, Swift.Int>")?.name,
            "Comparison")
    }
}
