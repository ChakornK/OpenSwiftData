import XCTest
@testable import OSDCore

final class SwiftDataErrorTests: XCTestCase {
    func testErrorCasesAndAssociatedValues() {
        XCTAssertEqual(
            SwiftDataError.unsupportedPredicate("unsupported node"),
            .unsupportedPredicate("unsupported node")
        )
        XCTAssertEqual(
            SwiftDataError.migrationUnsupported("relationship changed"),
            .migrationUnsupported("relationship changed")
        )
        XCTAssertEqual(SwiftDataError.optimisticLockConflict, .optimisticLockConflict)
    }

    func testErrorCasesConformToErrorAndSendable() {
        let errors: [any Error] = [
            SwiftDataError.unsupportedPredicate("predicate"),
            SwiftDataError.migrationUnsupported("migration"),
            SwiftDataError.optimisticLockConflict,
        ]
        XCTAssertEqual(errors.count, 3)
    }
}
