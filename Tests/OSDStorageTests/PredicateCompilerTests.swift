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

    func testCompilesRealPredicateKeyPathAndEqualityNode() throws {
        let predicate = #Predicate<CompilerRow> { $0.age == 7 }
        let tree = try PredicateMirrorWalker.walk(predicate.expression)

        let compiled = try SQLCompiler.compile(tree, entity: "Person")

        XCTAssertEqual(compiled.sql, "(t0.ZAGE = ?)")
        XCTAssertEqual(compiled.arguments, [.int(7)])
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
}

private struct CompilerRow {
    let age: Int
    let nickname: String?
    let tags: [String]
}
