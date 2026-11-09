import Foundation
import ParityContracts
import ParityCompareRuntime
import ParitySourceDiscovery
import Testing

@Suite struct ParityToolTests {
    @Test func comparatorAcceptsIdenticalBehaviorFromExpectedRunners() throws {
        let id = ParityScenarioCatalog.predicateMembership.id
        let result = ScenarioResult(
            id: id, observations: [ParityObservation(step: 0, field: "names", value: .array([.string("a")]))])
        let osd = makeOutput("openswiftdata", [result])
        let apple = makeOutput("apple-swiftdata", [result])
        let comparison = try compare(osd: osd, apple: apple)
        #expect(!comparison.hasUnexpectedDifferences)
        #expect(comparison.differences.isEmpty)
    }

    @Test func comparisonRuntimeRejectsStructurallyValidButIncompleteCoverage() throws {
        let specification = ParityScenarioCatalog.predicateMembership
        let pendingID = "FixtureSuite/unmapped declaration"
        let result = ScenarioResult(
            id: specification.id,
            observations: [
                ParityObservation(step: 0, field: "pending.names", value: .array([.string("a")])),
                ParityObservation(step: 1, field: "saved.names", value: .array([.string("a")])),
            ])
        let entry = CoverageMatrixEntry(
            sourceCase: specification.id.description,
            scenarioIDs: [specification.id.description],
            outcomes: [specification.id.description: "compared"],
            observations: [specification.id.description: ["pending.names", "saved.names"]])
        let report = CoverageValidationReport(
            discoveredCaseCount: 2,
            coverageValid: true,
            mappedSourceCaseCount: 1,
            declaredComparedSourceCaseCount: 1,
            declaredDivergentSourceCaseCount: 0,
            declaredNonComparableSourceCaseCount: 0,
            declaredComparedScenarioCount: 1,
            declaredDivergentScenarioCount: 0,
            declaredNonComparableScenarioCount: 0,
            discoveredCases: [specification.id.description, pendingID],
            pendingCases: [pendingID],
            validationIssues: [])
        let inputs = ComparisonInputs(
            osd: makeOutput("openswiftdata", [result]),
            apple: makeOutput("apple-swiftdata", [result]),
            allowlist: [],
            matrixSchemaVersion: CoverageMatrixValidator.supportedSchemaVersion,
            matrixEntries: [entry],
            coverage: report)

        #expect(throws: ComparisonInputError.incompleteSourceCoverage([pendingID])) {
            try ParityComparisonRuntime.compare(inputs)
        }
    }

    @Test func comparatorRejectsMissingAppleScenario() throws {
        let id = ParityScenarioCatalog.predicateMembership.id
        let osd = makeOutput("openswiftdata", [ScenarioResult(id: id, observations: [])])
        let apple = makeOutput("apple-swiftdata", [])
        #expect(throws: ComparisonError.dispositionScenarioMismatch("Apple")) {
            try compare(osd: osd, apple: apple)
        }
    }

    @Test func comparatorRejectsOSDArtifactMasqueradingAsApple() throws {
        let id = ParityScenarioCatalog.predicateMembership.id
        let output = makeOutput("openswiftdata", [ScenarioResult(id: id, observations: [])])
        #expect(throws: ComparisonError.unexpectedImplementation("apple", "openswiftdata")) {
            try compare(osd: output, apple: output)
        }
    }

    @Test func comparatorRejectsManifestResultCoverageMismatch() throws {
        let id = ParityScenarioCatalog.predicateMembership.id
        let osd = RunnerOutput(
            manifest: RunnerManifest(implementation: "openswiftdata", gitSHA: "fixture", scenarios: []),
            results: [ScenarioResult(id: id, observations: [])])
        let apple = makeOutput("apple-swiftdata", [])
        #expect(throws: ComparisonError.manifestScenarioMismatch("OSD")) {
            try compare(osd: osd, apple: apple)
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

        let comparison = try compare(osd: osd, apple: apple, allowedDifferences: allowlist)
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
            try compare(osd: osd, apple: apple, allowedDifferences: stale)
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
            try compare(osd: osd, apple: apple, allowedDifferences: expired)
        }
    }

    @Test func runnerInventoryIncludesMixedRowsButOmitsShimOnlyRows() throws {
        let comparableID = ParityScenarioCatalog.predicateMembership.id
        let nonComparableID = ScenarioID(suite: "FixtureSuite", test: "unavailable selection")
        let shimOnlyID = ScenarioID(suite: "FixtureSuite", test: "shim-only validation")
        let mixedEntry = CoverageMatrixEntry(
            sourceCase: "FixtureSuite/mixed",
            scenarioIDs: [comparableID.description, nonComparableID.description],
            outcomes: [comparableID.description: "compared", nonComparableID.description: "non-comparable"],
            observations: [comparableID.description: ["names"]],
            reasonCategory: "shim-only-api",
            rationale: "Apple exposes no public selection discriminator.")
        let shimOnlyEntry = CoverageMatrixEntry(
            sourceCase: "FixtureSuite/validation",
            scenarioIDs: [shimOnlyID.description],
            outcomes: [shimOnlyID.description: "non-comparable"],
            observations: [:],
            reasonCategory: "shim-only-api",
            rationale: "Validation is an OpenSwiftData-only API.")
        let scenarioIDs = CoverageMatrixValidator.runnerScenarioIDs(in: [mixedEntry, shimOnlyEntry])

        #expect(scenarioIDs == [comparableID.description, nonComparableID.description])
        #expect(!scenarioIDs.contains(shimOnlyID.description))
    }

    @Test func comparisonInputLoaderReportsMissingRunnerArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "parity-comparison-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let osdURL = root.appending(path: "osd.json")

        let error = #expect(throws: ComparisonInputError.self) {
            try ComparisonInputLoader.load(
                osdURL: osdURL,
                appleURL: osdURL,
                allowlistURL: osdURL,
                matrixURL: osdURL,
                coverageURL: osdURL)
        }
        if case let .missingArtifact(url) = error {
            #expect(url == osdURL)
        } else {
            Issue.record("Expected a missing-artifact error")
        }
    }

    @Test func sourceDiscoveryFindsNestedParameterizedAndRawNamedTests() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "parity-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let nested = root.appending(path: "Nested", directoryHint: .isDirectory)
        let external = root.deletingLastPathComponent()
            .appending(path: "parity-discovery-external-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: external) }

        try """
        @Suite struct RawNameSuite {
            @Test(arguments: [1, 2]) func `handles raw names`() {}
        }
        @Suite struct OrdinarySuite {
            @Test func ordinaryName() {}
        }
        """.write(to: nested.appending(path: "NestedTests.swift"), atomically: true, encoding: .utf8)
        try "not Swift source".write(to: root.appending(path: "ignored.txt"), atomically: true, encoding: .utf8)
        try """
        @Suite struct OutsideSuite {
            @Test func mustNotBeFollowed() {}
        }
        """.write(to: external.appending(path: "OutsideTests.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: nested.appending(path: "Linked"),
            withDestinationURL: external)

        let discovered = try ParitySourceDiscovery.discover(in: root)
        #expect(discovered == [
            "RawNameSuite/handles raw names",
            "OrdinarySuite/ordinaryName",
        ], "Discovered identities: \(discovered.sorted())")
    }

    @Test func sourceDiscoveryRejectsDuplicateTestIdentitiesAcrossNestedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "parity-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let nested = root.appending(path: "Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = """
        @Suite struct DuplicateSuite {
            @Test func duplicate() {}
        }
        """
        try source.write(to: root.appending(path: "First.swift"), atomically: true, encoding: .utf8)
        try source.write(to: nested.appending(path: "Second.swift"), atomically: true, encoding: .utf8)

        let error = #expect(throws: ParitySourceDiscovery.DiscoveryError.self) {
            try ParitySourceDiscovery.discover(in: root)
        }
        if case let .duplicateIdentity(identity, file) = error {
            #expect(identity == "DuplicateSuite/duplicate")
            #expect(file.hasSuffix("Nested/Second.swift"))
        } else {
            Issue.record("Expected a duplicate identity error")
        }
    }

    @Test func sourceDiscoveryRejectsDuplicateTestIdentitiesWithinAFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "parity-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        @Suite struct DuplicateSuite {
            @Test func duplicate() {}
            @Test func duplicate() {}
        }
        """.write(to: root.appending(path: "DuplicateTests.swift"), atomically: true, encoding: .utf8)

        let error = #expect(throws: ParitySourceDiscovery.DiscoveryError.self) {
            try ParitySourceDiscovery.discover(in: root)
        }
        if case let .duplicateIdentity(identity, file) = error {
            #expect(identity == "DuplicateSuite/duplicate")
            #expect(file.hasSuffix("DuplicateTests.swift"))
        } else {
            Issue.record("Expected a duplicate identity error")
        }
    }

    @Test func sourceDiscoveryRejectsMalformedSwiftFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "parity-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "@Suite struct BrokenSuite { @Test func broken( }"
            .write(to: root.appending(path: "BrokenTests.swift"), atomically: true, encoding: .utf8)

        let error = #expect(throws: ParitySourceDiscovery.DiscoveryError.self) {
            try ParitySourceDiscovery.discover(in: root)
        }
        if case let .malformedSource(file, diagnostics) = error {
            #expect(file.hasSuffix("BrokenTests.swift"))
            #expect(!diagnostics.isEmpty)
        } else {
            Issue.record("Expected a malformed source error")
        }
    }

    private func makeOutput(_ implementation: String, _ results: [ScenarioResult]) -> RunnerOutput {
        RunnerOutput(
            manifest: RunnerManifest(implementation: implementation, gitSHA: "fixture", scenarios: results.map(\.id)),
            results: results)
    }

    private func compare(
        osd: RunnerOutput,
        apple: RunnerOutput,
        expectedDispositions explicit: [ScenarioID: ScenarioDisposition] = [:],
        allowedDifferences: [AllowedDifference] = []
    ) throws -> ParityComparison {
        let ids = Set(osd.results.map(\.id)).union(apple.results.map(\.id))
        let dispositions = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, explicit[id] ?? .observed)
        })
        return try ParityComparator.compare(
            osd: osd, apple: apple, expectedDispositions: dispositions, allowedDifferences: allowedDifferences)
    }
}
