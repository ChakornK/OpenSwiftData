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

    @Test func expectationErrorCarriesScenarioAndObservations() throws {
        let id = ScenarioID(suite: "FixtureSuite", test: "unexpected result")
        let observations = [ParityObservation(step: 1, field: "names", value: .array([.string("wrong")]))]
        let error = ScenarioExpectationError(id: id, observations: observations)

        #expect(error.id == id)
        #expect(error.observations == observations)
        #expect(error.description.contains("FixtureSuite/unexpected result"))
    }

    @Test func stringSetsIgnoreOrderAndDuplicatesButArraysKeepOrder() throws {
        let left = ObservedValue.stringSet(["Gamma", "Alpha", "Alpha"])
        let right = ObservedValue.stringSet(["Alpha", "Gamma"])

        #expect(left == right)
        #expect(
            try JSONDecoder().decode(
                ObservedValue.self,
                from: CanonicalJSON.encode(ObservedValue.stringSet(["Gamma", "Alpha"])))
                == .stringSet(["Alpha", "Gamma"]))
        #expect(ObservedValue.array([.string("Gamma"), .string("Alpha")]) != .array([.string("Alpha"), .string("Gamma")]))
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

    @Test func comparatorCanonicalizesSetsWithoutReorderingArrays() throws {
        let id = ScenarioID(suite: "FixtureSuite", test: "set and array semantics")
        let osd = makeOutput("openswiftdata", [
            ScenarioResult(id: id, observations: [
                ParityObservation(step: 0, field: "set", value: .stringSet(["Gamma", "Alpha"])),
                ParityObservation(step: 1, field: "array", value: .array([.string("Gamma"), .string("Alpha")]))
            ])
        ])
        let apple = makeOutput("apple-swiftdata", [
            ScenarioResult(id: id, observations: [
                ParityObservation(step: 0, field: "set", value: .stringSet(["Alpha", "Gamma"])),
                ParityObservation(step: 1, field: "array", value: .array([.string("Alpha"), .string("Gamma")]))
            ])
        ])

        let comparison = try ParityComparator.compare(osd: osd, apple: apple)

        #expect(comparison.differences.map(\.field) == ["array"])
        #expect(comparison.hasUnexpectedDifferences)
    }

    @Test func expectationValidatorUsesSetSemanticsWithoutChangingArraySemantics() throws {
        let specification = PredicateMembershipSpecification(
            id: ScenarioID(suite: "FixtureSuite", test: "set normalization"),
            rows: [],
            capturedNames: [],
            sortField: .name,
            expectedObservations: [
                "set": .stringSet(["Alpha", "Gamma"]),
                "array": .array([.string("Alpha"), .string("Gamma")]),
            ],
            operations: [])
        let matching = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: 0, field: "set", value: .stringSet(["Gamma", "Alpha", "Alpha"])),
            ParityObservation(step: 1, field: "array", value: .array([.string("Alpha"), .string("Gamma")])),
        ])
        let reorderedArray = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: 0, field: "set", value: .stringSet(["Gamma", "Alpha"])),
            ParityObservation(step: 1, field: "array", value: .array([.string("Gamma"), .string("Alpha")])),
        ])

        #expect(ScenarioExpectationValidator.validate(matching, against: specification))
        #expect(!ScenarioExpectationValidator.validate(reorderedArray, against: specification))
    }

    @Test func expectationValidatorRejectsDuplicateObservationFields() throws {
        let specification = ParityScenarioCatalog.predicateMembership
        let result = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: 0, field: "pending.names", value: .array([.string("a"), .string("c")])),
            ParityObservation(step: 1, field: "pending.names", value: .array([.string("a"), .string("c")])),
        ])

        #expect(!ScenarioExpectationValidator.validate(result, against: specification))
    }

    @Test func schemaIntrospectionContractsExposeExpectedFieldsAndValidateObservations() throws {
        let specification = SchemaIntrospectionScenarioCatalog.entitiesByModelType
        let result = ScenarioResult(
            id: specification.id,
            observations: specification.expectedObservations.map { field, value in
                ParityObservation(step: 0, field: field, value: value)
            })

        #expect(SchemaIntrospectionExpectationValidator.validate(result, against: specification))
        #expect(SchemaIntrospectionScenarioCatalog.contractsByID[specification.id.description]
            == specification.contract)
        #expect(Set(ParityScenarioCatalog.contractsByID.keys)
            .intersection(SchemaIntrospectionScenarioCatalog.contractsByID.keys).isEmpty)
        #expect(Set(ParityScenarioCatalog.allContractsByID.keys)
            == Set(ParityScenarioCatalog.contractsByID.keys)
                .union(SchemaIntrospectionScenarioCatalog.contractsByID.keys)
                .union(SchemaModelTypesScenarioCatalog.contractsByID.keys)
                .union(StoreIdentifierScenarioCatalog.contractsByID.keys)
                .union(ModelIdentityScenarioCatalog.contractsByID.keys))
    }

    @Test func schemaIntrospectionExpectationValidatorRejectsMissingAndDuplicateFields() throws {
        let specification = SchemaIntrospectionScenarioCatalog.constraintsAndIndices
        let fields = specification.expectedObservations.sorted { $0.key < $1.key }
        let missing = ScenarioResult(
            id: specification.id,
            observations: [ParityObservation(step: 0, field: fields[0].key, value: fields[0].value)])
        let duplicate = ScenarioResult(
            id: specification.id,
            observations: [
                ParityObservation(step: 0, field: fields[0].key, value: fields[0].value),
                ParityObservation(step: 1, field: fields[0].key, value: fields[0].value),
                ParityObservation(step: 2, field: fields[1].key, value: fields[1].value),
            ])

        #expect(!SchemaIntrospectionExpectationValidator.validate(missing, against: specification))
        #expect(!SchemaIntrospectionExpectationValidator.validate(duplicate, against: specification))
    }

    @Test func schemaIntrospectionMatrixEntriesMatchCombinedScenarioRegistry() throws {
        let entries = SchemaIntrospectionScenarioCatalog.all.map { specification in
            CoverageMatrixEntry(
                sourceCase: specification.id.description,
                scenarioIDs: [specification.id.description],
                outcomes: [specification.id.description: "compared"],
                observations: [specification.id.description: specification.expectedObservations.keys.sorted()])
        }
        let discovered = Set(entries.map(\.sourceCase))

        #expect(CoverageMatrixValidator.validate(
            discovered: discovered,
            entries: entries,
            registry: ParityScenarioCatalog.allContractsByID).isEmpty)
    }

    @Test func schemaIntrospectionContractsCaptureObservedAppleDivergences() throws {
        #expect(SchemaIntrospectionScenarioCatalog.propertyFlags.expectedObservations["author.books.flags"]
            == .object([
                "relationship": .bool(false), "attribute": .bool(false), "toOne": .bool(false),
                "inverse": .string("author"), "deleteRule": .string("cascade"),
            ]))
        #expect(SchemaIntrospectionScenarioCatalog.constraintsAndIndices.expectedObservations["book.indices"]
            == .array([.array([.string("binary"), .string("title")])]))
        #expect(SchemaIntrospectionScenarioCatalog.schemaRoundTrip.expectedObservations["roundTrip.book.indices"]
            == .array([]))
    }

    @Test func schemaModelTypesContractsRegisterAllFourDeclarations() throws {
        let entries = SchemaModelTypesScenarioCatalog.all.map { specification in
            CoverageMatrixEntry(
                sourceCase: specification.id.description,
                scenarioIDs: [specification.id.description],
                outcomes: [specification.id.description: "compared"],
                observations: [specification.id.description: specification.expectedObservations.keys.sorted()])
        }

        #expect(SchemaModelTypesScenarioCatalog.all.count == 5)
        #expect(CoverageMatrixValidator.validate(
            discovered: Set(entries.map(\.sourceCase)),
            entries: entries,
            registry: ParityScenarioCatalog.allContractsByID).isEmpty)
        #expect(Set(SchemaModelTypesScenarioCatalog.contractsByID.keys).count == 5)
    }

    @Test func schemaModelTypesMatrixEntriesMatchCombinedScenarioRegistry() throws {
        let entries = SchemaModelTypesScenarioCatalog.all.map { specification in
            CoverageMatrixEntry(
                sourceCase: specification.id.description,
                scenarioIDs: [specification.id.description],
                outcomes: [specification.id.description: "compared"],
                observations: [specification.id.description: specification.expectedObservations.keys.sorted()])
        }

        #expect(CoverageMatrixValidator.validate(
            discovered: Set(entries.map(\.sourceCase)),
            entries: entries,
            registry: ParityScenarioCatalog.allContractsByID).isEmpty)
    }

    @Test func storeIdentifierMatrixEntriesMatchCombinedScenarioRegistry() throws {
        let entries = StoreIdentifierScenarioCatalog.all.map { specification in
            CoverageMatrixEntry(
                sourceCase: specification.id.description,
                scenarioIDs: [specification.id.description],
                outcomes: [specification.id.description: "compared"],
                observations: [specification.id.description: specification.expectedObservationFields.sorted()])
        }

        #expect(CoverageMatrixValidator.validate(
            discovered: Set(entries.map(\.sourceCase)),
            entries: entries,
            registry: ParityScenarioCatalog.allContractsByID).isEmpty)
    }

    @Test func storeIdentifierReopenContractCapturesObservedAppleDifferences() throws {
        let specification = StoreIdentifierScenarioCatalog.identifierSurvivesReopen
        #expect(specification.expectedObservationFields == [
            "reopened.identifierEqual", "reopened.storeIdentifierEqual", "reopened.fetchName", "reopened.registeredName",
        ])
        let appleResult = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: 0, field: "reopened.identifierEqual", value: .bool(false)),
            ParityObservation(step: 1, field: "reopened.storeIdentifierEqual", value: .bool(true)),
            ParityObservation(step: 2, field: "reopened.fetchName", value: .array([.string("a")])),
            ParityObservation(step: 3, field: "reopened.registeredName", value: .string("missing")),
        ])
        #expect(appleResult.observations.count == 4)
        #expect(appleResult.observations.first { $0.field == "reopened.identifierEqual" }?.value == .bool(false))
        #expect(appleResult.observations.first { $0.field == "reopened.registeredName" }?.value == .string("missing"))
    }

    @Test func modelIdentityMatrixEntriesMatchCombinedScenarioRegistry() throws {
        let entries = ModelIdentityScenarioCatalog.all.map { specification in
            CoverageMatrixEntry(
                sourceCase: specification.id.description,
                scenarioIDs: [specification.id.description],
                outcomes: [specification.id.description: "compared"],
                observations: [specification.id.description: specification.expectedObservationFields.sorted()])
        }

        #expect(ModelIdentityScenarioCatalog.all.count == 6)
        #expect(CoverageMatrixValidator.validate(
            discovered: Set(entries.map(\.sourceCase)),
            entries: entries,
            registry: ParityScenarioCatalog.allContractsByID).isEmpty)
    }

    @Test func coverageMatrixValidatorAcceptsScenarioSpecificFieldsForParameterizedCases() throws {
        let pending = ParityScenarioCatalog.stringIsEmptyPending
        let saved = ParityScenarioCatalog.stringIsEmptySaved
        let sourceCase = "StringPredicateParityTests/string isEmpty"
        let entry = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: [pending.id.description, saved.id.description],
            outcomes: [pending.id.description: "compared", saved.id.description: "compared"],
            observations: [
                pending.id.description: Array(pending.expectedObservations.keys),
                saved.id.description: Array(saved.expectedObservations.keys),
            ])

        let errors = CoverageMatrixValidator.validate(
            discovered: [sourceCase], entries: [entry], registry: ParityScenarioCatalog.contractsByID)

        #expect(errors.isEmpty)
        #expect(entry.sourceStatus == "compared")
        #expect(CoverageMatrixValidator.outcomeCounts(in: [entry]) == ["compared": 2])
        #expect(CoverageMatrixValidator.sourceCaseCounts(in: [entry]) == ["compared": 1])
    }

    @Test func coverageMatrixCountsMixedScenarioOutcomesWithoutDuplicatingSourceCase() throws {
        let pending = ParityScenarioCatalog.optionalFlatMapPending
        let saved = ParityScenarioCatalog.optionalFlatMapSaved
        let sourceCase = "StringPredicateParityTests/optional flatMap over a string"
        let entry = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: [pending.id.description, saved.id.description],
            outcomes: [pending.id.description: "compared", saved.id.description: "divergent"],
            observations: [
                pending.id.description: Array(pending.expectedObservations.keys),
                saved.id.description: Array(saved.expectedObservations.keys),
            ])

        let errors = CoverageMatrixValidator.validate(
            discovered: [sourceCase], entries: [entry], registry: ParityScenarioCatalog.contractsByID)

        #expect(errors.isEmpty)
        #expect(entry.sourceStatus == "divergent")
        #expect(CoverageMatrixValidator.sourceCaseCounts(in: [entry]) == ["divergent": 1])
        #expect(CoverageMatrixValidator.outcomeCounts(in: [entry]) == ["compared": 1, "divergent": 1])
    }

    @Test func coverageMatrixValidatorChecksDivergentFieldsAndMappingCompleteness() throws {
        let pending = ParityScenarioCatalog.stringCountPending
        let saved = ParityScenarioCatalog.stringCountSaved
        let sourceCase = "StringPredicateParityTests/string count counts characters"
        let validEntry = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: [pending.id.description, saved.id.description],
            outcomes: [pending.id.description: "compared", saved.id.description: "divergent"],
            observations: [
                pending.id.description: Array(pending.expectedObservations.keys),
                saved.id.description: Array(saved.expectedObservations.keys),
            ])
        let invalidFieldsEntry = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: validEntry.scenarioIDs,
            outcomes: validEntry.outcomes,
            observations: [pending.id.description: ["wrong.field"], saved.id.description: ["length.4"]])
        let incompleteEntry = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: validEntry.scenarioIDs,
            outcomes: validEntry.outcomes,
            observations: [pending.id.description: Array(pending.expectedObservations.keys)])
        let duplicateFieldEntry = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: validEntry.scenarioIDs,
            outcomes: validEntry.outcomes,
            observations: [
                pending.id.description: ["length.4", "length.4", "length.5", "length.gt5"],
                saved.id.description: Array(saved.expectedObservations.keys),
            ])
        let registry = ParityScenarioCatalog.contractsByID

        #expect(CoverageMatrixValidator.validate(discovered: [sourceCase], entries: [validEntry], registry: registry).isEmpty)
        #expect(validEntry.sourceStatus == "divergent")
        #expect(CoverageMatrixValidator.sourceCaseCounts(in: [validEntry]) == ["divergent": 1])
        #expect(CoverageMatrixValidator.outcomeCounts(in: [validEntry]) == ["compared": 1, "divergent": 1])
        #expect(CoverageMatrixValidator.validate(discovered: [sourceCase], entries: [invalidFieldsEntry], registry: registry)
            == ["\(sourceCase): matrix observation fields do not match shared scenario contract"])
        #expect(CoverageMatrixValidator.validate(discovered: [sourceCase], entries: [incompleteEntry], registry: registry)
            == ["\(sourceCase): observation mappings must cover comparable scenarios exactly once"])
        #expect(CoverageMatrixValidator.validate(discovered: [sourceCase], entries: [duplicateFieldEntry], registry: registry)
            == ["\(sourceCase): matrix observation fields do not match shared scenario contract"])
    }

    @Test func coverageMatrixValidatorRequiresRationaleForNonComparableScenarios() throws {
        let sourceCase = "StringPredicateParityTests/unavailable"
        let validEntry = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: ["Scenario/unavailable"],
            outcomes: ["Scenario/unavailable": "non-comparable"],
            observations: [:],
            reasonCategory: "shim-only-api",
            rationale: "The source case exercises an OpenSwiftData-only API.")
        let invalidEntry = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: ["Scenario/unavailable"],
            outcomes: ["Scenario/unavailable": "non-comparable"],
            observations: [:],
            reasonCategory: "unsupported",
            rationale: "No supported reason category.")

        #expect(CoverageMatrixValidator.validate(discovered: [sourceCase], entries: [validEntry], registry: [:]).isEmpty)
        #expect(validEntry.sourceStatus == "non-comparable")
        #expect(CoverageMatrixValidator.validate(discovered: [sourceCase], entries: [invalidEntry], registry: [:])
            == ["\(sourceCase): non-comparable outcome needs a valid reason and rationale"])
    }

    @Test func coverageMatrixSupportsMixedComparableAndNonComparableScenarios() throws {
        let comparable = ParityScenarioCatalog.stringIsEmptyPending
        let nonComparableID = "StringPredicateParityTests/string isEmpty/unsupported-platform"
        let sourceCase = "StringPredicateParityTests/string isEmpty"
        let entry = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: [comparable.id.description, nonComparableID],
            outcomes: [comparable.id.description: "compared", nonComparableID: "non-comparable"],
            observations: [comparable.id.description: Array(comparable.expectedObservations.keys)],
            reasonCategory: "unsupported-platform-or-version",
            rationale: "The additional argument scenario requires an unavailable system API.")

        #expect(CoverageMatrixValidator.validate(
            discovered: [sourceCase], entries: [entry], registry: ParityScenarioCatalog.contractsByID).isEmpty)
        #expect(CoverageMatrixValidator.sourceCaseCounts(in: [entry]) == ["compared": 1])
        #expect(CoverageMatrixValidator.outcomeCounts(in: [entry]) == ["compared": 1, "non-comparable": 1])
    }

    @Test func coverageMatrixValidatorRejectsOutcomeKeysAndValuesThatDoNotMatchScenarios() throws {
        let scenario = ParityScenarioCatalog.stringIsEmptyPending
        let sourceCase = "StringPredicateParityTests/string isEmpty"
        let missingOutcome = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: [scenario.id.description],
            outcomes: [:],
            observations: [scenario.id.description: Array(scenario.expectedObservations.keys)])
        let invalidOutcome = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: [scenario.id.description],
            outcomes: [scenario.id.description: "pending"],
            observations: [scenario.id.description: Array(scenario.expectedObservations.keys)])

        #expect(CoverageMatrixValidator.validate(
            discovered: [sourceCase], entries: [missingOutcome], registry: ParityScenarioCatalog.contractsByID)
            == ["\(sourceCase): outcome mappings must cover each scenario exactly once"])
        #expect(CoverageMatrixValidator.validate(
            discovered: [sourceCase], entries: [invalidOutcome], registry: ParityScenarioCatalog.contractsByID)
            == ["\(sourceCase): contains an invalid scenario outcome"])
    }

    @Test func coverageMatrixValidatorRejectsDuplicateScenarioIDsAndEmptySourceIdentity() throws {
        let scenario = ParityScenarioCatalog.stringIsEmptyPending
        let sourceCase = "StringPredicateParityTests/string isEmpty"
        let duplicateScenario = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: [scenario.id.description, scenario.id.description],
            outcomes: [scenario.id.description: "compared"],
            observations: [scenario.id.description: Array(scenario.expectedObservations.keys)])
        let emptySource = CoverageMatrixEntry(
            sourceCase: "",
            scenarioIDs: [scenario.id.description],
            outcomes: [scenario.id.description: "compared"],
            observations: [scenario.id.description: Array(scenario.expectedObservations.keys)])

        #expect(CoverageMatrixValidator.validate(
            discovered: [sourceCase], entries: [duplicateScenario], registry: ParityScenarioCatalog.contractsByID)
            == ["\(sourceCase): scenarioIDs must be unique"])
        #expect(CoverageMatrixValidator.validate(
            discovered: [""], entries: [emptySource], registry: ParityScenarioCatalog.contractsByID)
            == ["matrix sourceCase must not be empty"])
    }

    @Test func coverageMatrixValidatorRejectsUnsupportedSchemaVersion() throws {
        let sourceCase = "StringPredicateParityTests/string isEmpty"

        let unsupportedVersion = CoverageMatrixValidator.supportedSchemaVersion + 1
        #expect(CoverageMatrixValidator.validate(
            schemaVersion: unsupportedVersion,
            discovered: [sourceCase],
            entries: [],
            registry: [:])
            == ["unsupported coverage matrix schema version \(unsupportedVersion)"])
    }

    @Test func coverageReportCountsSourceCasesAndScenarioOutcomesSeparately() throws {
        let pending = ParityScenarioCatalog.stringCountPending
        let saved = ParityScenarioCatalog.stringCountSaved
        let entry = CoverageMatrixEntry(
            sourceCase: "StringPredicateParityTests/string count counts characters",
            scenarioIDs: [pending.id.description, saved.id.description],
            outcomes: [pending.id.description: "compared", saved.id.description: "divergent"],
            observations: [
                pending.id.description: Array(pending.expectedObservations.keys),
                saved.id.description: Array(saved.expectedObservations.keys),
            ])

        #expect(CoverageMatrixValidator.sourceCaseCounts(in: [entry]) == ["divergent": 1])
        #expect(CoverageMatrixValidator.outcomeCounts(in: [entry]) == ["compared": 1, "divergent": 1])
        #expect(entry.sourceStatus == "divergent")
    }

    @Test func coverageSourceCountsDeduplicateAndOmitConflictingDuplicateRows() throws {
        let scenario = ParityScenarioCatalog.stringIsEmptyPending
        let sourceCase = "StringPredicateParityTests/string isEmpty"
        let compared = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: [scenario.id.description],
            outcomes: [scenario.id.description: "compared"],
            observations: [scenario.id.description: Array(scenario.expectedObservations.keys)])
        let duplicate = compared
        let conflicting = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: [scenario.id.description],
            outcomes: [scenario.id.description: "divergent"],
            observations: [scenario.id.description: Array(scenario.expectedObservations.keys)])

        #expect(CoverageMatrixValidator.sourceCaseCounts(in: [compared, duplicate]) == ["compared": 1])
        #expect(CoverageMatrixValidator.sourceCaseCounts(in: [compared, conflicting]).isEmpty)
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
            osdExpected: .null,
            appleExpected: .string("unused"),
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
            osdExpected: .string("a"),
            appleExpected: .string("b"),
            reason: "expired fixture",
            issueURL: URL(string: "https://example.invalid/issues/2")!,
            expiration: "2000-01-01")
        #expect(throws: ComparisonError.expiredAllowlist("FixtureSuite/fixture#value", "2000-01-01")) {
            try ParityComparator.compare(osd: osd, apple: apple, allowedDifferences: [expired])
        }
    }

    @Test func comparatorAllowsOnlyTheExpectedValuesForAnAllowedField() throws {
        let id = ScenarioID(suite: "FixtureSuite", test: "expected divergence")
        let osdValue = ObservedValue.array([.string("beta")])
        let appleValue = ObservedValue.array([])
        let osd = makeOutput("openswiftdata", [
            ScenarioResult(id: id, observations: [ParityObservation(step: 0, field: "saved.names", value: osdValue)])
        ])
        let apple = makeOutput("apple-swiftdata", [
            ScenarioResult(id: id, observations: [ParityObservation(step: 0, field: "saved.names", value: appleValue)])
        ])
        let allowance = AllowedDifference(
            scenarioID: id,
            field: "saved.names",
            osdExpected: osdValue,
            appleExpected: appleValue,
            reason: "System SwiftData returns a different saved string-count result.",
            issueURL: URL(string: "https://example.invalid/issues/4")!,
            expiration: "2099-01-01")

        let comparison = try ParityComparator.compare(osd: osd, apple: apple, allowedDifferences: [allowance])
        #expect(!comparison.hasUnexpectedDifferences)
        #expect(comparison.differences.map(\.isAllowed) == [true])

        let changedOSD = makeOutput("openswiftdata", [
            ScenarioResult(
                id: id,
                observations: [ParityObservation(step: 0, field: "saved.names", value: .array([.string("alpha")]))])
        ])
        let changedOSDComparison = try ParityComparator.compare(
            osd: changedOSD, apple: apple, allowedDifferences: [allowance])
        #expect(changedOSDComparison.hasUnexpectedDifferences)
        #expect(changedOSDComparison.differences.map(\.isAllowed) == [false])

        let changedApple = makeOutput("apple-swiftdata", [
            ScenarioResult(
                id: id,
                observations: [ParityObservation(step: 0, field: "saved.names", value: .array([.string("gamma")]))])
        ])
        let changedAppleComparison = try ParityComparator.compare(
            osd: osd, apple: changedApple, allowedDifferences: [allowance])
        #expect(changedAppleComparison.hasUnexpectedDifferences)
        #expect(changedAppleComparison.differences.map(\.isAllowed) == [false])

        let equalValues = makeOutput("openswiftdata", [
            ScenarioResult(id: id, observations: [ParityObservation(step: 0, field: "saved.names", value: appleValue)])
        ])
        #expect(throws: ComparisonError.unreferencedAllowlist(["FixtureSuite/expected divergence#saved.names"])) {
            try ParityComparator.compare(osd: equalValues, apple: apple, allowedDifferences: [allowance])
        }
    }

    @Test func comparatorRejectsAllowanceWithIdenticalExpectedValues() throws {
        let id = ScenarioID(suite: "FixtureSuite", test: "identical allowance values")
        let allowance = AllowedDifference(
            scenarioID: id,
            field: "value",
            osdExpected: .string("same"),
            appleExpected: .string("same"),
            reason: "No difference is expected.",
            issueURL: URL(string: "https://example.invalid/issues/5")!,
            expiration: "2099-01-01")

        #expect(throws: ComparisonError.invalidAllowlist("\(id)#value")) {
            try ParityComparator.compare(
                osd: makeOutput("openswiftdata", [ScenarioResult(id: id, observations: [])]),
                apple: makeOutput("apple-swiftdata", [ScenarioResult(id: id, observations: [])]),
                allowedDifferences: [allowance])
        }
    }

    private func makeOutput(_ implementation: String, _ results: [ScenarioResult]) -> RunnerOutput {
        RunnerOutput(
            manifest: RunnerManifest(implementation: implementation, gitSHA: "fixture", scenarios: results.map(\.id)),
            results: results)
    }
}
