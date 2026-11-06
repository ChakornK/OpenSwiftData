import OSDCore
import Testing

/// `SwiftDataError` matches the shape of Apple's: a hashable struct of static constants.
@Suite struct SwiftDataErrorParityTests {
    static let appleCodes: [SwiftDataError] = [
        .includePendingChangesWithBatchSize, .unsupportedPredicate, .unsupportedKeyPath,
        .sortingPendingChangesWithIdentifiers, .unsupportedSortDescriptor, .duplicateConfiguration,
        .configurationFileNameTooLong, .configurationFileNameContainsInvalidCharacters,
        .configurationSchemaNotFoundInContainerSchema, .loadIssueModelContainer, .modelValidationFailure,
        .missingModelContext, .backwardMigration, .unknownSchema, .historyTokenExpired,
        .invalidTransactionFetchRequest,
    ]

    @Test func `every SwiftData error constant is distinct`() {
        #expect(Set(Self.appleCodes).count == Self.appleCodes.count)
    }

    @Test func `errors with explanations equal their constant`() {
        let detailed = SwiftDataError.unsupportedPredicate("detail")
        #expect(detailed == .unsupportedPredicate)
        #expect(detailed.hashValue == SwiftDataError.unsupportedPredicate.hashValue)
        #expect(detailed != .unsupportedKeyPath)
    }

    @Test func `the match operator accepts any error`() {
        let thrown: any Error = SwiftDataError.unsupportedStore("detail")
        #expect(SwiftDataError.unsupportedStore ~= thrown)
        #expect(!(SwiftDataError.unsupportedPredicate ~= thrown))
        struct Other: Error {}
        #expect(!(SwiftDataError.unsupportedStore ~= Other()))
    }

    @Test func `catch clauses match constants`() {
        func fail() throws { throw SwiftDataError.unsupportedPredicate("detail") }
        var matched = false
        do {
            try fail()
        } catch SwiftDataError.unsupportedPredicate {
            matched = true
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(matched)
    }
}
