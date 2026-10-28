import Foundation
import OSDStorage
import XCTest

private struct PredicateFixture {
    let count: Int
    let title: String
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
    }
}
