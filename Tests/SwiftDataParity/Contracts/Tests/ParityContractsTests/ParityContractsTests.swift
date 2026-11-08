import Foundation
import ParityContracts
import Testing

@Suite struct ParityContractsTests {
    @Test func canonicalEncodingRoundTripsAndSortsKeys() throws {
        let value = ObservedValue.object(["z": .integer(2), "a": .string("one")])
        let first = try CanonicalJSON.encode(value)
        let second = try CanonicalJSON.encode(value)
        #expect(first == second)
        #expect(try JSONDecoder().decode(ObservedValue.self, from: first) == value)
        #expect(String(decoding: first, as: UTF8.self).contains("\"object\":{\"a\":"))
    }

    @Test func comparatorAcceptsEqualObservationOutputs() throws {
        let id = ScenarioID(suite: "FixtureSuite", test: "fixture")
        let result = ScenarioResult(
            id: id,
            observations: [ParityObservation(step: 0, field: "value", value: .string("same"))])
        let osd = makeOutput("openswiftdata", [result])
        let apple = makeOutput("apple-swiftdata", [result])

        let comparison = try ParityComparator.compare(osd: osd, apple: apple)

        #expect(!comparison.hasUnexpectedDifferences)
        #expect(comparison.differences.isEmpty)
    }

    @Test func comparatorRejectsOSDOutputUsedForAppleRunner() throws {
        let id = ScenarioID(suite: "FixtureSuite", test: "fixture")
        let output = makeOutput("openswiftdata", [ScenarioResult(id: id, observations: [])])
        #expect(throws: ComparisonError.unexpectedImplementation("apple", "openswiftdata")) {
            try ParityComparator.compare(osd: output, apple: output)
        }
    }

    @Test func comparatorRejectsMissingScenariosAndStaleAllowlist() throws {
        let id = ScenarioID(suite: "FixtureSuite", test: "fixture")
        let osd = makeOutput("openswiftdata", [ScenarioResult(id: id, observations: [])])
        let apple = makeOutput("apple-swiftdata", [])
        let comparison = try ParityComparator.compare(osd: osd, apple: apple)
        #expect(comparison.missingAppleScenarios == [id])
        #expect(comparison.hasUnexpectedDifferences)

        let unusedEntry = AllowedDifference(
            scenarioID: id,
            field: "unused",
            reason: "stale fixture",
            issueURL: URL(string: "https://example.invalid/issues/1")!,
            expiration: "2099-01-01")
        #expect(throws: ComparisonError.unreferencedAllowlist(["FixtureSuite/fixture#unused"])) {
            try ParityComparator.compare(osd: osd, apple: apple, allowedDifferences: [unusedEntry])
        }
    }

    @Test func comparatorRejectsExpiredAllowlist() throws {
        let id = ScenarioID(suite: "FixtureSuite", test: "fixture")
        let osd = makeOutput("openswiftdata", [
            ScenarioResult(id: id, observations: [ParityObservation(step: 0, field: "value", value: .string("a"))])
        ])
        let apple = makeOutput("apple-swiftdata", [
            ScenarioResult(id: id, observations: [ParityObservation(step: 0, field: "value", value: .string("b"))])
        ])
        let expired = AllowedDifference(
            scenarioID: id,
            field: "value",
            reason: "expired fixture",
            issueURL: URL(string: "https://example.invalid/issues/2")!,
            expiration: "2000-01-01")
        #expect(throws: ComparisonError.expiredAllowlist("FixtureSuite/fixture#value", "2000-01-01")) {
            try ParityComparator.compare(osd: osd, apple: apple, allowedDifferences: [expired])
        }
    }

    private func makeOutput(_ implementation: String, _ results: [ScenarioResult]) -> RunnerOutput {
        RunnerOutput(
            manifest: RunnerManifest(implementation: implementation, gitSHA: "fixture", scenarios: results.map(\.id)),
            results: results)
    }
}
