import Foundation
import ParityContracts
import Testing

@Suite struct ParityToolTests {
    @Test func comparatorAcceptsIdenticalBehaviorFromExpectedRunners() throws {
        let id = ParityScenarioCatalog.predicateMembership.id
        let result = ScenarioResult(
            id: id, observations: [ParityObservation(step: 0, field: "names", value: .array([.string("a")]))])
        let osd = makeOutput("openswiftdata", [result])
        let apple = makeOutput("apple-swiftdata", [result])
        let comparison = try ParityComparator.compare(osd: osd, apple: apple)
        #expect(!comparison.hasUnexpectedDifferences)
        #expect(comparison.differences.isEmpty)
    }

    @Test func comparatorRejectsMissingAppleScenario() throws {
        let id = ParityScenarioCatalog.predicateMembership.id
        let osd = makeOutput("openswiftdata", [ScenarioResult(id: id, observations: [])])
        let apple = makeOutput("apple-swiftdata", [])
        let comparison = try ParityComparator.compare(osd: osd, apple: apple)
        #expect(comparison.missingAppleScenarios == [id])
        #expect(comparison.hasUnexpectedDifferences)
    }

    @Test func comparatorRejectsOSDArtifactMasqueradingAsApple() throws {
        let id = ParityScenarioCatalog.predicateMembership.id
        let output = makeOutput("openswiftdata", [ScenarioResult(id: id, observations: [])])
        #expect(throws: ComparisonError.unexpectedImplementation("apple", "openswiftdata")) {
            try ParityComparator.compare(osd: output, apple: output)
        }
    }

    @Test func comparatorRejectsManifestResultCoverageMismatch() throws {
        let id = ParityScenarioCatalog.predicateMembership.id
        let osd = RunnerOutput(
            manifest: RunnerManifest(implementation: "openswiftdata", gitSHA: "fixture", scenarios: []),
            results: [ScenarioResult(id: id, observations: [])])
        let apple = makeOutput("apple-swiftdata", [])
        #expect(throws: ComparisonError.manifestScenarioMismatch("OSD")) {
            try ParityComparator.compare(osd: osd, apple: apple)
        }
    }

    @Test func comparatorAllowsOnlyTheListedFieldDifference() throws {
        let id = ParityScenarioCatalog.predicateMembership.id
        let osd = makeOutput("openswiftdata", [
            ScenarioResult(id: id, observations: [ParityObservation(step: 0, field: "names", value: .string("a"))])
        ])
        let apple = makeOutput("apple-swiftdata", [
            ScenarioResult(id: id, observations: [ParityObservation(step: 0, field: "names", value: .string("b"))])
        ])
        let allowlist = [AllowedDifference(
            scenarioID: id,
            field: "names",
            osdExpected: .string("a"),
            appleExpected: .string("b"),
            reason: "Intentional test divergence",
            issueURL: URL(string: "https://example.invalid/issues/1")!,
            expiration: "2099-01-01")]

        let comparison = try ParityComparator.compare(osd: osd, apple: apple, allowedDifferences: allowlist)
        #expect(!comparison.hasUnexpectedDifferences)
        #expect(comparison.differences.map(\.isAllowed) == [true])

        let stale = allowlist + [AllowedDifference(
            scenarioID: id,
            field: "unused",
            osdExpected: .null,
            appleExpected: .string("unused"),
            reason: "Stale allowance",
            issueURL: URL(string: "https://example.invalid/issues/2")!,
            expiration: "2099-01-01")]
        #expect(throws: ComparisonError.unreferencedAllowlist(["\(id)#unused"])) {
            try ParityComparator.compare(osd: osd, apple: apple, allowedDifferences: stale)
        }
    }

    @Test func comparatorRejectsExpiredAllowlistEntries() throws {
        let id = ParityScenarioCatalog.predicateMembership.id
        let osd = makeOutput("openswiftdata", [
            ScenarioResult(id: id, observations: [ParityObservation(step: 0, field: "names", value: .string("a"))])
        ])
        let apple = makeOutput("apple-swiftdata", [
            ScenarioResult(id: id, observations: [ParityObservation(step: 0, field: "names", value: .string("b"))])
        ])
        let expired = [AllowedDifference(
            scenarioID: id,
            field: "names",
            osdExpected: .string("a"),
            appleExpected: .string("b"),
            reason: "Expired test divergence",
            issueURL: URL(string: "https://example.invalid/issues/3")!,
            expiration: "2000-01-01")]
        #expect(throws: ComparisonError.expiredAllowlist("\(id)#names", "2000-01-01")) {
            try ParityComparator.compare(osd: osd, apple: apple, allowedDifferences: expired)
        }
    }

    private func makeOutput(_ implementation: String, _ results: [ScenarioResult]) -> RunnerOutput {
        RunnerOutput(
            manifest: RunnerManifest(implementation: implementation, gitSHA: "fixture", scenarios: results.map(\.id)),
            results: results)
    }
}
