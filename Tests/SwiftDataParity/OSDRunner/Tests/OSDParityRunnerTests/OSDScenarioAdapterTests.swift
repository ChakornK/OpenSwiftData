import OSDParityRuntime
import ParityContracts
import Testing

@Suite struct OSDScenarioAdapterTests {
    @MainActor
    @Test func predicateMembershipMatchesSharedExpectations() throws {
        let results = try OSDScenarioAdapter.runAll()
        let expectedIDs = (ParityScenarioCatalog.all.map(\.id) + SchemaIntrospectionScenarioCatalog.all.map(\.id)
            + SchemaModelTypesScenarioCatalog.all.map(\.id) + StoreIdentifierScenarioCatalog.all.map(\.id)
            + ModelIdentityScenarioCatalog.all.map(\.id) + ModelConfigurationScenarioCatalog.all.map(\.id)
            + ModelConfigurationContainerScenarioCatalog.all.map(\.id)
            + ModelConfigurationScenarioCatalog.nonComparableSelectionIDs)
            .sorted { $0.description < $1.description }
        #expect(results.map(\.id) == expectedIDs)
        for specification in SchemaIntrospectionScenarioCatalog.all {
            let result = try #require(results.first { $0.id == specification.id })
            #expect(SchemaIntrospectionExpectationValidator.validate(result, against: specification))
        }
        for specification in SchemaModelTypesScenarioCatalog.all {
            let result = try #require(results.first { $0.id == specification.id })
            #expect(SchemaModelTypesExpectationValidator.validate(result, against: specification))
        }
        for specification in StoreIdentifierScenarioCatalog.all {
            let result = try #require(results.first { $0.id == specification.id })
            #expect(Set(result.observations.map(\.field)) == specification.expectedObservationFields)
        }
        for specification in ModelIdentityScenarioCatalog.all {
            let result = try #require(results.first { $0.id == specification.id })
            #expect(Set(result.observations.map(\.field)) == specification.expectedObservationFields)
        }
        for specification in ModelConfigurationScenarioCatalog.all {
            let result = try #require(results.first { $0.id == specification.id })
            #expect(Set(result.observations.map(\.field)) == specification.contract.expectedObservationFields)
        }
        for specification in ModelConfigurationContainerScenarioCatalog.all {
            let result = try #require(results.first { $0.id == specification.id })
            #expect(Set(result.observations.map(\.field)) == specification.contract.expectedObservationFields)
        }
        for id in ModelConfigurationScenarioCatalog.nonComparableSelectionIDs {
            let result = try #require(results.first { $0.id == id })
            #expect(result.disposition == .nonComparable(
                reasonCategory: "shim-only-api",
                rationale: "Apple's SwiftData selection wrappers expose no public selection discriminator."))
            #expect(result.observations.isEmpty)
        }
    }
}
