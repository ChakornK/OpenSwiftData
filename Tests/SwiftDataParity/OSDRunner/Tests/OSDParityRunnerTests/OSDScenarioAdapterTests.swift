import OSDParityRuntime
import ParityContracts
import Testing

@Suite struct OSDScenarioAdapterTests {
    @MainActor
    @Test func predicateMembershipMatchesSharedExpectations() throws {
        let results = try OSDScenarioAdapter.runAll()
        #expect(results.map(\.id) == ParityScenarioCatalog.all.map(\.id))
    }
}
