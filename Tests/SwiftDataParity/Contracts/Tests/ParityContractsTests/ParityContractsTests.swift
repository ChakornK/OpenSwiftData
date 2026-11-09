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

        let comparison = try compare(osd: osd, apple: apple)

        #expect(!comparison.hasUnexpectedDifferences)
        #expect(comparison.differences.isEmpty)
    }

    @Test func comparatorReportsExplicitNonComparableScenariosWithoutComparingThem() throws {
        let id = ScenarioID(suite: "FixtureSuite", test: "unobservable selection")
        let disposition = ScenarioDisposition.nonComparable(
            reasonCategory: "shim-only-api", rationale: "The Apple wrapper exposes no public selection discriminator.")
        let result = ScenarioResult(id: id, observations: [], disposition: disposition)
        let comparison = try compare(
            osd: makeOutput("openswiftdata", [result]), apple: makeOutput("apple-swiftdata", [result]),
            expectedDispositions: [id: disposition])

        #expect(comparison.nonComparableScenarios == [id])
        #expect(comparison.differences.isEmpty)
        #expect(!comparison.hasUnexpectedDifferences)
    }

    @Test func comparatorRejectsMismatchedNonComparableDisposition() throws {
        let id = ScenarioID(suite: "FixtureSuite", test: "unobservable selection")
        let osdResult = ScenarioResult(
            id: id, observations: [],
            disposition: .nonComparable(reasonCategory: "shim-only-api", rationale: "No public discriminator."))
        let appleResult = ScenarioResult(id: id, observations: [])

        #expect(throws: ComparisonError.dispositionMismatch(id)) {
            try compare(
                osd: makeOutput("openswiftdata", [osdResult]),
                apple: makeOutput("apple-swiftdata", [appleResult]),
                expectedDispositions: [id: osdResult.disposition])
        }
    }

    @Test func comparatorRejectsNonComparableResultsWithObservationsOrNoRationale() throws {
        let id = ScenarioID(suite: "FixtureSuite", test: "invalid non-comparable")
        let osdResult = ScenarioResult(
            id: id,
            observations: [ParityObservation(step: 0, field: "value", value: .bool(true))],
            disposition: .nonComparable(reasonCategory: "shim-only-api", rationale: "No public discriminator."))
        let appleResult = ScenarioResult(id: id, observations: [], disposition: osdResult.disposition)
        #expect(throws: ComparisonError.invalidNonComparableResult(id)) {
            try compare(
                osd: makeOutput("openswiftdata", [osdResult]),
                apple: makeOutput("apple-swiftdata", [appleResult]),
                expectedDispositions: [id: osdResult.disposition])
        }

        let emptyReason = ScenarioResult(
            id: id, observations: [], disposition: .nonComparable(reasonCategory: "", rationale: " "))
        #expect(throws: ComparisonError.invalidNonComparableResult(id)) {
            try compare(
                osd: makeOutput("openswiftdata", [emptyReason]),
                apple: makeOutput("apple-swiftdata", [emptyReason]),
                expectedDispositions: [id: emptyReason.disposition])
        }
    }

    @Test func comparatorRejectsUnsupportedRunnerSchemaVersion() throws {
        let results: [ScenarioResult] = []
        let osd = RunnerOutput(
            manifest: RunnerManifest(schemaVersion: 1, implementation: "openswiftdata", gitSHA: "fixture", scenarios: []),
            results: results)
        let apple = RunnerOutput(
            manifest: RunnerManifest(schemaVersion: 1, implementation: "apple-swiftdata", gitSHA: "fixture", scenarios: []),
            results: results)
        #expect(throws: ComparisonError.unsupportedRunnerSchemaVersion(1)) {
            try ParityComparator.compare(osd: osd, apple: apple, expectedDispositions: [:])
        }
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

        let comparison = try compare(osd: osd, apple: apple)

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

    @Test func pendingFetchContractsRegisterFourScalarDeclarations() throws {
        let specifications = PendingFetchScenarioCatalog.all
        let contracts = PendingFetchScenarioCatalog.contractsByID
        let expectedIDs = [
            "PendingFetchParityTests/a zero fetch limit means no limit",
            "PendingFetchParityTests/stored rows paginate before pending changes merge",
            "PendingFetchParityTests/changed models are re-evaluated against the predicate in memory",
            "PendingFetchParityTests/excluding pending changes returns only stored rows",
        ]

        #expect(specifications.map(\.id.description) == expectedIDs)
        #expect(Set(contracts.keys) == Set(expectedIDs))
        let combinedContractIDs = Set(ParityScenarioCatalog.allContractsByID.keys)
        #expect(combinedContractIDs.isSuperset(of: contracts.keys))
        #expect(specifications.allSatisfy { $0.hasValidObservationSchedule })
        #expect(
            PendingFetchScenarioCatalog.zeroLimit.steps.compactMap(\.query).last?.sort
                == PendingFetchSpecification.Sort.none)
        #expect(
            PendingFetchScenarioCatalog.zeroLimit.expectedObservations.first { $0.field == "identifierCount" }?.value
                == .integer(4))
        #expect(PendingFetchScenarioCatalog.storedPaginationBeforePendingMerge.steps.prefix(3).compactMap(\.pendingChange)
            == [.insert(.init(name: "p1", age: 20)), .updateAge(name: "s1", age: 60), .delete(name: "s2")])
    }

    @Test func pendingFetchExpectationValidatorRejectsMissingAndDuplicateObservations() throws {
        let specification = PendingFetchScenarioCatalog.storedPaginationBeforePendingMerge
        let observations = specification.expectedObservations.map { observation in
            ParityObservation(step: observation.step, field: observation.field, value: observation.value)
        }
        let matching = ScenarioResult(id: specification.id, observations: observations)
        let missing = ScenarioResult(id: specification.id, observations: Array(observations.dropLast()))
        let duplicate = ScenarioResult(id: specification.id, observations: observations + [observations[0]])
        let wrongScenario = ScenarioResult(
            id: ScenarioID(suite: "OtherSuite", test: "wrong scenario"), observations: observations)

        #expect(PendingFetchExpectationValidator.validate(matching, against: specification))
        #expect(!PendingFetchExpectationValidator.validate(missing, against: specification))
        #expect(!PendingFetchExpectationValidator.validate(duplicate, against: specification))
        #expect(!PendingFetchExpectationValidator.validate(wrongScenario, against: specification))
    }

    @Test func pendingFetchExpectationValidatorRejectsWrongOperationStepAndValue() throws {
        let specification = PendingFetchScenarioCatalog.zeroLimit
        let correct = specification.expectedObservations.map {
            ParityObservation(step: $0.step, field: $0.field, value: $0.value)
        }
        let wrongStep = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: 99, field: correct[0].field, value: correct[0].value),
        ] + Array(correct.dropFirst()))
        let wrongValue = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: correct[0].step, field: correct[0].field, value: .integer(999)),
        ] + Array(correct.dropFirst()))

        #expect(!PendingFetchExpectationValidator.validate(wrongStep, against: specification))
        #expect(!PendingFetchExpectationValidator.validate(wrongValue, against: specification))
    }

    @Test func pendingFetchExpectationValidatorRejectsInvalidObservationSchedules() throws {
        let specification = PendingFetchScenarioCatalog.zeroLimit
        let invalid = PendingFetchSpecification(
            id: specification.id,
            seedRows: specification.seedRows,
            steps: Array(specification.steps.dropLast()),
            expectedObservations: specification.expectedObservations)
        let result = ScenarioResult(id: invalid.id, observations: specification.expectedObservations.map {
            ParityObservation(step: $0.step, field: $0.field, value: $0.value)
        })

        #expect(!invalid.hasValidObservationSchedule)
        #expect(!PendingFetchExpectationValidator.validate(result, against: invalid))
    }

    @Test func pendingFetchMatrixEntriesMatchSharedScenarioContracts() throws {
        let expectedStatuses = Dictionary(uniqueKeysWithValues: PendingFetchScenarioCatalog.all.map {
            ($0.id.description, "compared")
        })
        let entries = PendingFetchScenarioCatalog.all.map { specification in
            CoverageMatrixEntry(
                sourceCase: specification.id.description,
                scenarioIDs: [specification.id.description],
                outcomes: [specification.id.description: "compared"],
                observations: [specification.id.description: specification.expectedObservations.map(\.field)])
        }

        #expect(CoverageMatrixValidator.validate(
            discovered: Set(expectedStatuses.keys),
            entries: entries,
            registry: ParityScenarioCatalog.allContractsByID).isEmpty)
        #expect(CoverageMatrixValidator.runnerScenarioIDs(in: entries) == Set(expectedStatuses.keys))
        #expect(CoverageMatrixValidator.sourceCaseCounts(in: entries) == ["compared": 4])
        #expect(CoverageMatrixValidator.outcomeCounts(in: entries) == ["compared": 4])
    }

    @Test func batchFetchContractsRegisterAllScenariosAndArguments() throws {
        let specifications = BatchFetchScenarioCatalog.all
        let ids = specifications.map(\.id.description)
        #expect(ids.count == 10)
        #expect(ids.filter { $0.contains("any batch size returns every result/") }.count == 4)
        #expect(Set(ids).count == ids.count)
        #expect(specifications.allSatisfy { $0.hasValidObservationSchedule })
        #expect(Set(ParityScenarioCatalog.allContractsByID.keys).isSuperset(of: ids))
        #expect(BatchFetchScenarioCatalog.batchedResultsExcludePendingInsertionsAndKeepSnapshot.expectedObservations
            .map(\.value) == [.integer(7), .integer(7), .integer(7)])
    }

    @Test func batchFetchExpectationValidatorRejectsMissingAndWrongObservations() throws {
        let specification = BatchFetchScenarioCatalog.randomAccessFetchOrder
        let matching = ScenarioResult(id: specification.id, observations: specification.expectedObservations.map {
            ParityObservation(step: $0.step, field: $0.field, value: $0.value)
        })
        let missing = ScenarioResult(id: specification.id, observations: [])
        let wrong = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: 0, field: "collection.values", value: .array([.integer(0)])),
        ])
        #expect(BatchFetchExpectationValidator.validate(matching, against: specification))
        #expect(!BatchFetchExpectationValidator.validate(missing, against: specification))
        #expect(!BatchFetchExpectationValidator.validate(wrong, against: specification))
    }

    @Test func batchFetchMatrixEntriesMatchSharedScenarioContracts() throws {
        let grouped = Dictionary(grouping: BatchFetchScenarioCatalog.all) { specification in
            specification.id.test.hasPrefix("any batch size returns every result/")
                ? "BatchFetchParityTests/any batch size returns every result"
                : specification.id.description
        }
        let entries = grouped.map { sourceCase, specifications in
            let scenarioIDs = specifications.map { $0.id.description }
            return CoverageMatrixEntry(
                sourceCase: sourceCase,
                scenarioIDs: scenarioIDs,
                outcomes: Dictionary(uniqueKeysWithValues: scenarioIDs.map { ($0, "compared") }),
                observations: Dictionary(uniqueKeysWithValues: specifications.map {
                    ($0.id.description, $0.expectedObservations.map(\.field))
                }))
        }
        #expect(CoverageMatrixValidator.validate(
            discovered: Set(entries.map(\.sourceCase)),
            entries: entries,
            registry: ParityScenarioCatalog.allContractsByID).isEmpty)
    }

    @Test func batchDeleteContractsRegisterSixDeclarations() throws {
        let specifications = BatchDeleteScenarioCatalog.all
        let expectedIDs = [
            "BatchDeleteParityTests/batch deletes leave pending changes and registered instances alone",
            "BatchDeleteParityTests/batch deletes apply cascade rules",
            "BatchDeleteParityTests/batch deletes post no save notifications",
            "BatchDeleteParityTests/deny rules make batch deletes throw without deleting",
            "BatchDeleteParityTests/batch deletes inside a failed transaction stay applied",
            "BatchDeleteParityTests/batch deletes with no matches change nothing",
        ]
        #expect(specifications.map(\.id.description) == expectedIDs)
        #expect(specifications.allSatisfy { $0.hasValidObservationSchedule })
        #expect(Set(ParityScenarioCatalog.allContractsByID.keys).isSuperset(of: expectedIDs))
        #expect(BatchDeleteScenarioCatalog.denyRuleError.expectedObservations[0].value == .object([
            "threw": .bool(true), "domain": .string("NSCocoaErrorDomain"), "code": .integer(134060),
            "relationship": .string("BatchParityKeeper.toys"),
            "reason": .string("Delete rule is not supported for batch deletes"),
            "remainingKeepers": .integer(1), "toyStillLinked": .bool(true),
        ]))
        let divergent = try #require(BatchDeleteScenarioCatalog.pendingAndRegisteredState.expectedOSDObservations?.first)
        #expect(divergent.value == .object([
            "hasChanges": .bool(true), "insertedCount": .integer(1), "deletedCount": .integer(0),
            "savedADeleted": .bool(true), "savedARegistered": .bool(false), "pendingCRegistered": .bool(true),
            "otherContextNames": .array([.string("b")]), "mainContextNames": .array([.string("b"), .string("c")]),
            "afterSaveNames": .array([.string("b"), .string("c")]),
        ]))
    }

    @Test func batchDeleteExpectationValidatorRejectsMissingAndWrongObservations() throws {
        let specification = BatchDeleteScenarioCatalog.cascadeRules
        let matching = ScenarioResult(id: specification.id, observations: specification.expectedObservations.map {
            ParityObservation(step: $0.step, field: $0.field, value: $0.value)
        })
        let missing = ScenarioResult(id: specification.id, observations: [])
        let wrong = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: 0, field: "cascade.petCount", value: .integer(1)),
        ])
        #expect(BatchDeleteExpectationValidator.validate(matching, against: specification))
        #expect(!BatchDeleteExpectationValidator.validate(missing, against: specification))
        #expect(!BatchDeleteExpectationValidator.validate(wrong, against: specification))
    }

    @Test func batchDeleteMatrixEntriesMatchSharedContracts() throws {
        let entries = BatchDeleteScenarioCatalog.all.map { specification in
            let isDivergent = specification.id == BatchDeleteScenarioCatalog.pendingAndRegisteredState.id
            return CoverageMatrixEntry(
                sourceCase: specification.id.description,
                scenarioIDs: [specification.id.description],
                outcomes: [specification.id.description: isDivergent ? "divergent" : "compared"],
                observations: [specification.id.description: specification.expectedObservations.map(\.field)])
        }
        #expect(CoverageMatrixValidator.validate(
            discovered: Set(entries.map(\.sourceCase)),
            entries: entries,
            registry: ParityScenarioCatalog.allContractsByID).isEmpty)
    }

    @Test func codableParityContractsRegisterSevenDeclarationsAndTwelveScenarios() throws {
        let specs = CodableParityScenarioCatalog.all
        #expect(specs.count == 12)
        #expect(CodableParityScenarioCatalog.memberPredicates.count == 10)
        #expect(Set(CodableParityScenarioCatalog.contractsByID.keys).isDisjoint(with: ParityScenarioCatalog.contractsByID.keys))
        #expect(Set(ParityScenarioCatalog.allContractsByID.keys).isSuperset(of: specs.map { $0.id.description }))
        #expect(specs.allSatisfy { $0.expectedObservations.count > 0 })
    }

    @Test func codableParityExpectationValidatorRejectsMissingAndWrongValues() throws {
        let specification = CodableParityScenarioCatalog.memberPredicates[0]
        let matching = ScenarioResult(id: specification.id, observations: specification.expectedObservations.map {
            ParityObservation(step: 0, field: $0.key, value: $0.value)
        })
        let missing = ScenarioResult(id: specification.id, observations: [])
        let wrong = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: 0, field: "names", value: .array([.string("wrong")])),
        ])
        #expect(CodableParityExpectationValidator.validate(matching, against: specification))
        #expect(!CodableParityExpectationValidator.validate(missing, against: specification))
        #expect(!CodableParityExpectationValidator.validate(wrong, against: specification))
    }

    @Test func contextNotificationParityContractsRegisterAllThreeDeclarations() {
        #expect(ContextNotificationScenarioCatalog.all.count == 3)
        #expect(ContextNotificationScenarioCatalog.contractsByID.count == 3)
        #expect(ContextNotificationScenarioCatalog.all.allSatisfy {
            $0.contract.expectedObservationFields == Set($0.expectedObservations.keys)
        })
    }

    @Test func rollbackParityContractsRegisterSevenDeclarations() {
        #expect(RollbackParityScenarioCatalog.all.count == 7)
        #expect(RollbackParityScenarioCatalog.contractsByID.count == 7)
        #expect(RollbackParityScenarioCatalog.all.allSatisfy {
            $0.contract.expectedObservationFields == Set($0.expectedObservations.keys)
        })
    }

    @Test func modelContextParityContractsRegisterTenScenarios() {
        #expect(ModelContextParityScenarioCatalog.all.count == 10)
        #expect(ModelContextParityScenarioCatalog.contractsByID.count == 10)
        #expect(ModelContextParityScenarioCatalog.all.allSatisfy {
            $0.contract.expectedObservationFields == Set($0.expectedObservations.keys)
        })
    }

    @Test func historyParityContractsRegisterFourDeclarations() {
        #expect(HistoryParityScenarioCatalog.all.count == 4)
        #expect(HistoryParityScenarioCatalog.contractsByID.count == 4)
        #expect(HistoryParityScenarioCatalog.all.allSatisfy {
            $0.contract.expectedObservationFields == Set($0.expectedObservations.keys)
        })
    }

    @Test func uniqueConstraintParityContractsRegisterSevenDeclarations() {
        #expect(UniqueConstraintScenarioCatalog.all.count == 7)
        #expect(UniqueConstraintScenarioCatalog.contractsByID.count == 7)
        #expect(Set(ParityScenarioCatalog.allContractsByID.keys).isSuperset(
            of: UniqueConstraintScenarioCatalog.contractsByID.keys))
    }

    @Test func migrationPlanParityContractsRegisterFiveDeclarations() {
        #expect(MigrationPlanScenarioCatalog.all.count == 5)
        #expect(MigrationPlanScenarioCatalog.contractsByID.count == 5)
        #expect(Set(ParityScenarioCatalog.allContractsByID.keys).isSuperset(
            of: MigrationPlanScenarioCatalog.contractsByID.keys))
    }

    @Test func modelContainerParityContractsRegisterThreeDeclarations() {
        #expect(ModelContainerParityScenarioCatalog.all.count == 3)
        #expect(ModelContainerParityScenarioCatalog.contractsByID.count == 3)
        #expect(Set(ParityScenarioCatalog.allContractsByID.keys).isSuperset(
            of: ModelContainerParityScenarioCatalog.contractsByID.keys))
    }


    @Test func deletedInsertionRollbackUsesExactPerImplementationExpectations() {
        let specification = ModelContextParityScenarioCatalog.rollbackDeletedInsertion
        let apple = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: 0, field: "detached", value: .bool(true)),
            ParityObservation(step: 0, field: "notDeleted", value: .bool(true)),
            ParityObservation(step: 0, field: "hasChanges", value: .bool(true)),
        ])
        let osd = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: 0, field: "detached", value: .bool(true)),
            ParityObservation(step: 0, field: "notDeleted", value: .bool(true)),
            ParityObservation(step: 0, field: "hasChanges", value: .bool(false)),
        ])

        #expect(ModelContextParityExpectationValidator.validate(apple, against: specification))
        #expect(ModelContextParityExpectationValidator.validate(osd, against: specification, implementation: "openswiftdata"))
    }

    @Test func fetchDescriptorDefaultsDivergenceUsesExactPerImplementationValues() {
        let specification = ModelContextParityScenarioCatalog.fetchDescriptorDefaults
        let appleValues: [String: ObservedValue] = [
            "predicateAbsent": .bool(true), "sortEmpty": .bool(true), "fetchLimitAbsent": .bool(true),
            "fetchOffsetAbsent": .bool(false), "includePendingChanges": .bool(true),
            "propertiesToFetchEmpty": .bool(true), "prefetchRelationshipsEmpty": .bool(true),
        ]
        let osdValues: [String: ObservedValue] = [
            "predicateAbsent": .bool(true), "sortEmpty": .bool(true), "fetchLimitAbsent": .bool(true),
            "fetchOffsetAbsent": .bool(true), "includePendingChanges": .bool(true),
            "propertiesToFetchEmpty": .bool(true), "prefetchRelationshipsEmpty": .bool(true),
        ]
        let apple = ScenarioResult(id: specification.id, observations: appleValues.map { field, value in
            ParityObservation(step: 0, field: field, value: value)
        })
        let osd = ScenarioResult(id: specification.id, observations: osdValues.map { field, value in
            ParityObservation(step: 0, field: field, value: value)
        })

        #expect(ModelContextParityExpectationValidator.validate(apple, against: specification))
        #expect(ModelContextParityExpectationValidator.validate(osd, against: specification, implementation: "openswiftdata"))
    }

    @Test func fetchDescriptorEqualityDivergenceUsesExactPerImplementationValues() {
        let specification = ModelContextParityScenarioCatalog.fetchDescriptorEquality
        let appleValues: [String: ObservedValue] = [
            "samePredicateAndSortEqual": .bool(false), "differentPredicateUnequal": .bool(true),
            "differentLimitUnequal": .bool(true), "differentPendingOptionUnequal": .bool(true),
        ]
        let osdValues: [String: ObservedValue] = [
            "samePredicateAndSortEqual": .bool(true), "differentPredicateUnequal": .bool(true),
            "differentLimitUnequal": .bool(true), "differentPendingOptionUnequal": .bool(true),
        ]
        let apple = ScenarioResult(id: specification.id, observations: appleValues.map { field, value in
            ParityObservation(step: 0, field: field, value: value)
        })
        let osd = ScenarioResult(id: specification.id, observations: osdValues.map { field, value in
            ParityObservation(step: 0, field: field, value: value)
        })

        #expect(ModelContextParityExpectationValidator.validate(apple, against: specification))
        #expect(ModelContextParityExpectationValidator.validate(osd, against: specification, implementation: "openswiftdata"))
    }

    @Test func deletedInsertionRollbackDivergenceUsesExactPerImplementationValues() {
        let specification = ModelContextParityScenarioCatalog.rollbackDeletedInsertion
        let apple = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: 0, field: "detached", value: .bool(true)),
            ParityObservation(step: 0, field: "notDeleted", value: .bool(true)),
            ParityObservation(step: 0, field: "hasChanges", value: .bool(true)),
        ])
        let osd = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: 0, field: "detached", value: .bool(true)),
            ParityObservation(step: 0, field: "notDeleted", value: .bool(true)),
            ParityObservation(step: 0, field: "hasChanges", value: .bool(false)),
        ])

        #expect(ModelContextParityExpectationValidator.validate(apple, against: specification))
        #expect(ModelContextParityExpectationValidator.validate(osd, against: specification, implementation: "openswiftdata"))
    }

    @Test func rollbackRelationshipDivergenceAcceptsExactPerImplementationValues() {
        let specification = RollbackParityScenarioCatalog.committedRelationship
        let apple = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: 0, field: "ownerItemCount", value: .integer(1)),
            ParityObservation(step: 0, field: "itemOwnerAbsent", value: .bool(false)),
            ParityObservation(step: 0, field: "contextHasChanges", value: .bool(false)),
        ])
        let osd = ScenarioResult(id: specification.id, observations: [
            ParityObservation(step: 0, field: "ownerItemCount", value: .integer(0)),
            ParityObservation(step: 0, field: "itemOwnerAbsent", value: .bool(true)),
            ParityObservation(step: 0, field: "contextHasChanges", value: .bool(false)),
        ])

        #expect(RollbackParityExpectationValidator.validate(apple, against: specification))
        #expect(RollbackParityExpectationValidator.validate(
            osd, against: specification, implementation: "openswiftdata"))
        #expect(!RollbackParityExpectationValidator.validate(osd, against: specification))

        let relatedInsertion = RollbackParityScenarioCatalog.relatedInsertion
        let appleInsertion = ScenarioResult(id: relatedInsertion.id, observations: [
            ParityObservation(step: 0, field: "ownerItemCount", value: .integer(1)),
            ParityObservation(step: 0, field: "itemDetached", value: .bool(true)),
            ParityObservation(step: 0, field: "itemOwnerAbsent", value: .bool(false)),
            ParityObservation(step: 0, field: "ownerHasChanges", value: .bool(false)),
            ParityObservation(step: 0, field: "contextHasChanges", value: .bool(false)),
            ParityObservation(step: 0, field: "storedItemCount", value: .integer(0)),
        ])
        let osdInsertion = ScenarioResult(id: relatedInsertion.id, observations: [
            ParityObservation(step: 0, field: "ownerItemCount", value: .integer(0)),
            ParityObservation(step: 0, field: "itemDetached", value: .bool(true)),
            ParityObservation(step: 0, field: "itemOwnerAbsent", value: .bool(true)),
            ParityObservation(step: 0, field: "ownerHasChanges", value: .bool(false)),
            ParityObservation(step: 0, field: "contextHasChanges", value: .bool(false)),
            ParityObservation(step: 0, field: "storedItemCount", value: .integer(0)),
        ])
        #expect(RollbackParityExpectationValidator.validate(appleInsertion, against: relatedInsertion))
        #expect(RollbackParityExpectationValidator.validate(
            osdInsertion, against: relatedInsertion, implementation: "openswiftdata"))

        let repeatedEdits = RollbackParityScenarioCatalog.repeatedEdits
        let appleRepeatedEdits = ScenarioResult(id: repeatedEdits.id, observations: [
            ParityObservation(step: 0, field: "ageAfterFirstRollback", value: .integer(3)),
            ParityObservation(step: 0, field: "unchangedAfterFirstRollback", value: .bool(true)),
            ParityObservation(step: 0, field: "hasChangesAfterSecondEdit", value: .bool(true)),
            ParityObservation(step: 0, field: "ageAfterSecondRollback", value: .integer(4)),
            ParityObservation(step: 0, field: "unchangedAfterSecondRollback", value: .bool(true)),
        ])
        let osdRepeatedEdits = ScenarioResult(id: repeatedEdits.id, observations: [
            ParityObservation(step: 0, field: "ageAfterFirstRollback", value: .integer(1)),
            ParityObservation(step: 0, field: "unchangedAfterFirstRollback", value: .bool(true)),
            ParityObservation(step: 0, field: "hasChangesAfterSecondEdit", value: .bool(true)),
            ParityObservation(step: 0, field: "ageAfterSecondRollback", value: .integer(1)),
            ParityObservation(step: 0, field: "unchangedAfterSecondRollback", value: .bool(true)),
        ])
        #expect(RollbackParityExpectationValidator.validate(appleRepeatedEdits, against: repeatedEdits))
        #expect(RollbackParityExpectationValidator.validate(
            osdRepeatedEdits, against: repeatedEdits, implementation: "openswiftdata"))

        let editedDeletion = RollbackParityScenarioCatalog.editedDeletion
        let appleEditedDeletion = ScenarioResult(id: editedDeletion.id, observations: [
            ParityObservation(step: 0, field: "age", value: .integer(2)),
            ParityObservation(step: 0, field: "notDeleted", value: .bool(true)),
            ParityObservation(step: 0, field: "modelRemainsAttached", value: .bool(true)),
            ParityObservation(step: 0, field: "contextHasChanges", value: .bool(false)),
        ])
        let osdEditedDeletion = ScenarioResult(id: editedDeletion.id, observations: [
            ParityObservation(step: 0, field: "age", value: .integer(1)),
            ParityObservation(step: 0, field: "notDeleted", value: .bool(true)),
            ParityObservation(step: 0, field: "modelRemainsAttached", value: .bool(true)),
            ParityObservation(step: 0, field: "contextHasChanges", value: .bool(false)),
        ])
        #expect(RollbackParityExpectationValidator.validate(appleEditedDeletion, against: editedDeletion))
        #expect(RollbackParityExpectationValidator.validate(
            osdEditedDeletion, against: editedDeletion, implementation: "openswiftdata"))
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
                .union(ModelIdentityScenarioCatalog.contractsByID.keys)
                .union(ModelConfigurationScenarioCatalog.contractsByID.keys)
                .union(ModelConfigurationContainerScenarioCatalog.contractsByID.keys)
                .union(PendingFetchScenarioCatalog.contractsByID.keys)
                .union(BatchFetchScenarioCatalog.contractsByID.keys)
                .union(BatchDeleteScenarioCatalog.contractsByID.keys)
                .union(CodableParityScenarioCatalog.contractsByID.keys)
                .union(ContextNotificationScenarioCatalog.contractsByID.keys)
                .union(RollbackParityScenarioCatalog.contractsByID.keys)
                .union(ModelContextParityScenarioCatalog.contractsByID.keys)
                .union(HistoryParityScenarioCatalog.contractsByID.keys)
                .union(UniqueConstraintScenarioCatalog.contractsByID.keys)
                .union(MigrationPlanScenarioCatalog.contractsByID.keys)
                .union(ModelContainerParityScenarioCatalog.contractsByID.keys))
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

    @Test func modelConfigurationMatrixEntriesMatchCombinedScenarioRegistry() throws {
        let regularEntries = ModelConfigurationScenarioCatalog.all.map { specification in
            CoverageMatrixEntry(
                sourceCase: specification.id.description,
                scenarioIDs: [specification.id.description],
                outcomes: [specification.id.description: "compared"],
                observations: [specification.id.description: specification.expectedObservations.keys.sorted()])
        }
        let containerEntries = ModelConfigurationContainerScenarioCatalog.all.map { specification in
            CoverageMatrixEntry(
                sourceCase: specification.id.description,
                scenarioIDs: [specification.id.description],
                outcomes: [specification.id.description: "compared"],
                observations: [specification.id.description: specification.expectedObservations.keys.sorted()])
        }
        let validationEntries = [
            CoverageMatrixEntry(
                sourceCase: "ModelConfigurationParityTests/names up to 255 characters validate",
                scenarioIDs: ["ModelConfigurationParityTests/names up to 255 characters validate"],
                outcomes: ["ModelConfigurationParityTests/names up to 255 characters validate": "non-comparable"],
                observations: [:],
                reasonCategory: "shim-only-api",
                rationale: "OpenSwiftData exposes ModelConfiguration.validate(); Apple SwiftData has no public equivalent."),
            CoverageMatrixEntry(
                sourceCase: "ModelConfigurationParityTests/reserved characters fail validation",
                scenarioIDs: ["/", ":", "\\", "*", "?", "<", ">", "|", "\""].map {
                    "ModelConfigurationParityTests/reserved characters fail validation/\($0.debugDescription)"
                },
                outcomes: Dictionary(uniqueKeysWithValues: ["/", ":", "\\", "*", "?", "<", ">", "|", "\""].map {
                    let id = "ModelConfigurationParityTests/reserved characters fail validation/\($0.debugDescription)"
                    return (id, "non-comparable")
                }),
                observations: [:],
                reasonCategory: "shim-only-api",
                rationale: "OpenSwiftData exposes ModelConfiguration.validate(); Apple SwiftData has no public equivalent."),
            CoverageMatrixEntry(
                sourceCase: "ModelConfigurationParityTests/other names validate",
                scenarioIDs: ["a\0b", "a\nb", "a b", "a~b", "a.b", "a..b", ".", "..", ""].map {
                    "ModelConfigurationParityTests/other names validate/\($0.debugDescription)"
                },
                outcomes: Dictionary(uniqueKeysWithValues: ["a\0b", "a\nb", "a b", "a~b", "a.b", "a..b", ".", "..", ""].map {
                    let id = "ModelConfigurationParityTests/other names validate/\($0.debugDescription)"
                    return (id, "non-comparable")
                }),
                observations: [:],
                reasonCategory: "shim-only-api",
                rationale: "OpenSwiftData exposes ModelConfiguration.validate(); Apple SwiftData has no public equivalent."),
            CoverageMatrixEntry(
                sourceCase: "ModelConfigurationParityTests/explicit URL configurations still validate their names",
                scenarioIDs: ["ModelConfigurationParityTests/explicit URL configurations still validate their names"],
                outcomes: ["ModelConfigurationParityTests/explicit URL configurations still validate their names": "non-comparable"],
                observations: [:],
                reasonCategory: "shim-only-api",
                rationale: "OpenSwiftData exposes ModelConfiguration.validate(); Apple SwiftData has no public equivalent."),
        ]
        let selectionSource = ModelConfigurationScenarioCatalog.cloudAndGroupSelections.id.description
        let selectionIDs = ModelConfigurationScenarioCatalog.nonComparableSelectionIDStrings
        let selectionEntry = CoverageMatrixEntry(
            sourceCase: selectionSource,
            scenarioIDs: [ModelConfigurationScenarioCatalog.cloudAndGroupSelections.id.description] + selectionIDs,
            outcomes: Dictionary(uniqueKeysWithValues: [(selectionSource, "compared")] + selectionIDs.map {
                ($0, "non-comparable")
            }),
            observations: [
                ModelConfigurationScenarioCatalog.cloudAndGroupSelections.id.description:
                    ModelConfigurationScenarioCatalog.cloudAndGroupSelections.expectedObservations.keys.sorted()
            ],
            reasonCategory: "shim-only-api",
            rationale: ModelConfigurationScenarioCatalog.nonComparableSelectionReason)
        let entries = regularEntries.filter { $0.sourceCase != selectionSource }
            + [selectionEntry] + containerEntries + validationEntries
        let discoveredSourceCases = Set(
            ModelConfigurationScenarioCatalog.all.map(\.id.description)
                + [
                    "ModelConfigurationParityTests/names up to 255 characters validate",
                    "ModelConfigurationParityTests/reserved characters fail validation",
                    "ModelConfigurationParityTests/other names validate",
                    "ModelConfigurationParityTests/explicit URL configurations still validate their names",
                ]
                + ModelConfigurationContainerScenarioCatalog.all.map(\.id.description))

        #expect(CoverageMatrixValidator.validate(
            discovered: discoveredSourceCases,
            entries: entries,
            registry: ParityScenarioCatalog.allContractsByID).isEmpty)
    }

    @Test func modelConfigurationSelectionCasesAreNotCountedAsComparisons() throws {
        let ids = ModelConfigurationScenarioCatalog.nonComparableSelectionIDs
        #expect(ids.count == 1)
        #expect(ids == [ModelConfigurationScenarioCatalog.groupSelectionKind])
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { ParityScenarioCatalog.allContractsByID[$0.description] == nil })
        let sourceCase = ModelConfigurationScenarioCatalog.cloudAndGroupSelections.id.description
        let expectedScenarioIDs = [sourceCase] + ids.map(\.description)
        let entry = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: expectedScenarioIDs,
            outcomes: Dictionary(uniqueKeysWithValues: [(sourceCase, "compared")] + ids.map {
                ($0.description, "non-comparable")
            }),
            observations: [sourceCase: ModelConfigurationScenarioCatalog.cloudAndGroupSelections.contract.expectedObservationFields.sorted()],
            reasonCategory: "shim-only-api",
            rationale: ModelConfigurationScenarioCatalog.nonComparableSelectionReason)
        #expect(CoverageMatrixValidator.validate(
            discovered: [sourceCase], entries: [entry], registry: ParityScenarioCatalog.allContractsByID)
            .isEmpty)
        #expect(CoverageMatrixValidator.outcomeCounts(in: [entry]) == ["compared": 1, "non-comparable": 1])
        #expect(CoverageMatrixValidator.runnerScenarioIDs(in: [entry]) == Set(expectedScenarioIDs))
        #expect(entry.rationale == ModelConfigurationScenarioCatalog.nonComparableSelectionReason)
    }

    @Test func modelConfigurationSelectionMatrixMatchesRunnerDisposition() throws {
        let matrixURL = try #require(locateParityMatrix())
        let matrix = try JSONDecoder().decode(CoverageMatrixFixture.self, from: Data(contentsOf: matrixURL))
        let sourceCase = ModelConfigurationScenarioCatalog.cloudAndGroupSelections.id.description
        let entry = try #require(matrix.cases.first { $0.sourceCase == sourceCase })

        #expect(entry.rationale == ModelConfigurationScenarioCatalog.nonComparableSelectionReason)
        #expect(entry.scenarioIDs == [sourceCase] + ModelConfigurationScenarioCatalog.nonComparableSelectionIDStrings)
        #expect(entry.outcomes == [
            sourceCase: "compared",
            ModelConfigurationScenarioCatalog.groupSelectionKind.description: "non-comparable",
        ])
        #expect(entry.observations[sourceCase] == ["selected.cloudIdentifierMatches"])
    }

    private func locateParityMatrix() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().standardizedFileURL
        while directory.path != "/" {
            let candidate = directory.appending(path: "parity-matrix.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    @Test func modelConfigurationContainerMatrixEntriesMatchCombinedScenarioRegistry() throws {
        let entries = ModelConfigurationContainerScenarioCatalog.all.map { specification in
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

    @Test func modelConfigurationValidationCasesAreExplicitlyNonComparable() throws {
        let rationale = "OpenSwiftData exposes ModelConfiguration.validate(); Apple SwiftData has no public equivalent."
        let cases = [
            CoverageMatrixEntry(
                sourceCase: "ModelConfigurationParityTests/names up to 255 characters validate",
                scenarioIDs: ["ModelConfigurationParityTests/names up to 255 characters validate"],
                outcomes: ["ModelConfigurationParityTests/names up to 255 characters validate": "non-comparable"],
                observations: [:], reasonCategory: "shim-only-api", rationale: rationale),
            CoverageMatrixEntry(
                sourceCase: "ModelConfigurationParityTests/reserved characters fail validation",
                scenarioIDs: ["/", ":", "\\", "*", "?", "<", ">", "|", "\""].map {
                    "ModelConfigurationParityTests/reserved characters fail validation/\($0.debugDescription)"
                },
                outcomes: Dictionary(uniqueKeysWithValues: ["/", ":", "\\", "*", "?", "<", ">", "|", "\""].map {
                    let id = "ModelConfigurationParityTests/reserved characters fail validation/\($0.debugDescription)"
                    return (id, "non-comparable")
                }),
                observations: [:], reasonCategory: "shim-only-api", rationale: rationale),
            CoverageMatrixEntry(
                sourceCase: "ModelConfigurationParityTests/other names validate",
                scenarioIDs: ["a\0b", "a\nb", "a b", "a~b", "a.b", "a..b", ".", "..", ""].map {
                    "ModelConfigurationParityTests/other names validate/\($0.debugDescription)"
                },
                outcomes: Dictionary(uniqueKeysWithValues: ["a\0b", "a\nb", "a b", "a~b", "a.b", "a..b", ".", "..", ""].map {
                    let id = "ModelConfigurationParityTests/other names validate/\($0.debugDescription)"
                    return (id, "non-comparable")
                }),
                observations: [:], reasonCategory: "shim-only-api", rationale: rationale),
            CoverageMatrixEntry(
                sourceCase: "ModelConfigurationParityTests/explicit URL configurations still validate their names",
                scenarioIDs: ["ModelConfigurationParityTests/explicit URL configurations still validate their names"],
                outcomes: ["ModelConfigurationParityTests/explicit URL configurations still validate their names": "non-comparable"],
                observations: [:], reasonCategory: "shim-only-api", rationale: rationale),
        ]

        #expect(CoverageMatrixValidator.validate(
            discovered: Set(cases.map(\.sourceCase)), entries: cases, registry: ParityScenarioCatalog.allContractsByID).isEmpty)
        #expect(CoverageMatrixValidator.outcomeCounts(in: cases)["non-comparable"] == 20)
        #expect(CoverageMatrixValidator.runnerScenarioIDs(in: cases).isEmpty)
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

    @Test func coverageMatrixAcceptsDeferredBehaviorGapsAsNonComparable() throws {
        let sourceCase = "PredicateParityTests/apple behavior intentionally deferred"
        let entry = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: ["PredicateParityTests/apple behavior intentionally deferred"],
            outcomes: ["PredicateParityTests/apple behavior intentionally deferred": "non-comparable"],
            observations: [:],
            reasonCategory: "deferred-behavior-gap",
            rationale: "The README documents this Apple behavior as intentionally unmatched for now.")

        #expect(CoverageMatrixValidator.validate(discovered: [sourceCase], entries: [entry], registry: [:]).isEmpty)
        #expect(entry.sourceStatus == "non-comparable")
        #expect(CoverageMatrixValidator.runnerScenarioIDs(in: [entry]).isEmpty)
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

    @Test func coverageMatrixValidatorRejectsMalformedScenarioIDsAndAllowsNestedTestNames() throws {
        let sourceCase = "FixtureSuite/nested case"
        let malformedIDs = ["missing-separator", "/empty-suite", "FixtureSuite/"]
        for malformedID in malformedIDs {
            let entry = CoverageMatrixEntry(
                sourceCase: sourceCase,
                scenarioIDs: [malformedID],
                outcomes: [malformedID: "non-comparable"],
                observations: [:],
                reasonCategory: "shim-only-api",
                rationale: "The scenario cannot be compared.")
            #expect(CoverageMatrixValidator.validate(
                discovered: [sourceCase], entries: [entry], registry: [:])
                == ["\(sourceCase): contains a malformed scenario ID"])
        }

        let nestedID = "FixtureSuite/nested/test case"
        let entry = CoverageMatrixEntry(
            sourceCase: sourceCase,
            scenarioIDs: [nestedID],
            outcomes: [nestedID: "non-comparable"],
            observations: [:],
            reasonCategory: "shim-only-api",
            rationale: "The scenario cannot be compared.")
        #expect(CoverageMatrixValidator.validate(
            discovered: [sourceCase], entries: [entry], registry: [:]).isEmpty)
        #expect(ScenarioID(description: nestedID) == ScenarioID(suite: "FixtureSuite", test: "nested/test case"))
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

    @Test func partialCoverageKeepsMappedOutcomesSeparateFromPendingSourceCases() throws {
        let scenario = ParityScenarioCatalog.stringIsEmptyPending
        let mappedSourceCase = "StringPredicateParityTests/string isEmpty"
        let pendingSourceCase = "StringPredicateParityTests/unmapped declaration"
        let entry = CoverageMatrixEntry(
            sourceCase: mappedSourceCase,
            scenarioIDs: [scenario.id.description],
            outcomes: [scenario.id.description: "compared"],
            observations: [scenario.id.description: Array(scenario.expectedObservations.keys)])
        let discovered = Set([mappedSourceCase, pendingSourceCase])
        let report = CoverageValidationReport(
            discoveredCaseCount: discovered.count,
            coverageValid: true,
            mappedSourceCaseCount: 1,
            declaredComparedSourceCaseCount: 1,
            declaredDivergentSourceCaseCount: 0,
            declaredNonComparableSourceCaseCount: 0,
            declaredComparedScenarioCount: 1,
            declaredDivergentScenarioCount: 0,
            declaredNonComparableScenarioCount: 0,
            discoveredCases: discovered.sorted(),
            pendingCases: [pendingSourceCase],
            validationIssues: [])

        #expect(CoverageMatrixValidator.validate(
            discovered: [mappedSourceCase], entries: [entry], registry: ParityScenarioCatalog.contractsByID).isEmpty)
        #expect(CoverageMatrixValidator.sourceCaseCounts(in: [entry]) == ["compared": 1])
        #expect(CoverageMatrixValidator.outcomeCounts(in: [entry]) == ["compared": 1])
        #expect(discovered.subtracting([entry.sourceCase]).sorted() == [pendingSourceCase])
        #expect(report.isConsistent(with: [entry]))
        #expect(!report.hasCompleteCoverage)
        #expect(report.hasValidMatrix(
            entries: [entry], registry: ParityScenarioCatalog.allContractsByID))
        let encodedReport = try CanonicalJSON.encode(report)
        #expect(try JSONDecoder().decode(CoverageValidationReport.self, from: encodedReport) == report)
        #expect(CoverageMatrixValidator.validate(
            discovered: discovered, entries: [entry], registry: ParityScenarioCatalog.contractsByID)
            == ["\(pendingSourceCase): expected exactly one matrix record"])

        let inconsistentReport = CoverageValidationReport(
            discoveredCaseCount: report.discoveredCaseCount,
            coverageValid: report.coverageValid,
            mappedSourceCaseCount: report.mappedSourceCaseCount,
            declaredComparedSourceCaseCount: report.declaredComparedSourceCaseCount,
            declaredDivergentSourceCaseCount: report.declaredDivergentSourceCaseCount,
            declaredNonComparableSourceCaseCount: report.declaredNonComparableSourceCaseCount,
            declaredComparedScenarioCount: 2,
            declaredDivergentScenarioCount: 0,
            declaredNonComparableScenarioCount: 0,
            discoveredCases: report.discoveredCases,
            pendingCases: report.pendingCases,
            validationIssues: report.validationIssues)
        #expect(!inconsistentReport.isConsistent(with: [entry]))

        let invalidEntry = CoverageMatrixEntry(
            sourceCase: mappedSourceCase,
            scenarioIDs: [scenario.id.description],
            outcomes: [scenario.id.description: "compared"],
            observations: [scenario.id.description: ["unexpected.field"]])
        let structuralIssues = CoverageMatrixValidator.validate(
            discovered: [mappedSourceCase],
            entries: [invalidEntry],
            registry: ParityScenarioCatalog.allContractsByID)
        let invalidReport = CoverageValidationReport(
            discoveredCaseCount: 1,
            coverageValid: false,
            mappedSourceCaseCount: 1,
            declaredComparedSourceCaseCount: 1,
            declaredDivergentSourceCaseCount: 0,
            declaredNonComparableSourceCaseCount: 0,
            declaredComparedScenarioCount: 1,
            declaredDivergentScenarioCount: 0,
            declaredNonComparableScenarioCount: 0,
            discoveredCases: [mappedSourceCase],
            pendingCases: [],
            validationIssues: structuralIssues)
        #expect(invalidReport.isConsistent(with: [invalidEntry]))
        #expect(!invalidReport.hasValidMatrix(
            entries: [invalidEntry], registry: ParityScenarioCatalog.allContractsByID))
        #expect(try JSONDecoder().decode(
            CoverageValidationReport.self,
            from: CanonicalJSON.encode(invalidReport)) == invalidReport)
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
            try compare(osd: output, apple: output)
        }
    }

    @Test func comparatorRejectsMissingScenariosAndStaleAllowlist() throws {
        let id = ScenarioID(suite: "FixtureSuite", test: "fixture")
        let osd = makeOutput("openswiftdata", [ScenarioResult(id: id, observations: [])])
        let apple = makeOutput("apple-swiftdata", [])
        #expect(throws: ComparisonError.dispositionScenarioMismatch("Apple")) {
            try compare(osd: osd, apple: apple)
        }

        let unusedEntry = AllowedDifference(
            scenarioID: id,
            field: "unused",
            osdExpected: .null,
            appleExpected: .string("unused"),
            reason: "stale fixture",
            issueURL: URL(string: "https://example.invalid/issues/1")!,
            expiration: "2099-01-01")
        let completeApple = makeOutput("apple-swiftdata", [ScenarioResult(id: id, observations: [])])
        #expect(throws: ComparisonError.unreferencedAllowlist(["FixtureSuite/fixture#unused"])) {
            try compare(osd: osd, apple: completeApple, allowedDifferences: [unusedEntry])
        }
    }

    @Test func comparatorRejectsUnexpectedRunnerScenarios() throws {
        let expectedID = ScenarioID(suite: "FixtureSuite", test: "expected")
        let extraID = ScenarioID(suite: "FixtureSuite", test: "unexpected")
        let osd = makeOutput("openswiftdata", [
            ScenarioResult(id: expectedID, observations: []),
            ScenarioResult(id: extraID, observations: []),
        ])
        let apple = makeOutput("apple-swiftdata", [
            ScenarioResult(id: expectedID, observations: []),
            ScenarioResult(id: extraID, observations: []),
        ])

        #expect(throws: ComparisonError.dispositionScenarioMismatch("OSD")) {
            try ParityComparator.compare(
                osd: osd,
                apple: apple,
                expectedDispositions: [expectedID: .observed])
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
            try compare(osd: osd, apple: apple, allowedDifferences: [expired])
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

        let comparison = try compare(osd: osd, apple: apple, allowedDifferences: [allowance])
        #expect(!comparison.hasUnexpectedDifferences)
        #expect(comparison.differences.map(\.isAllowed) == [true])

        let changedOSD = makeOutput("openswiftdata", [
            ScenarioResult(
                id: id,
                observations: [ParityObservation(step: 0, field: "saved.names", value: .array([.string("alpha")]))])
        ])
        let changedOSDComparison = try compare(
            osd: changedOSD, apple: apple, allowedDifferences: [allowance])
        #expect(changedOSDComparison.hasUnexpectedDifferences)
        #expect(changedOSDComparison.differences.map(\.isAllowed) == [false])

        let changedApple = makeOutput("apple-swiftdata", [
            ScenarioResult(
                id: id,
                observations: [ParityObservation(step: 0, field: "saved.names", value: .array([.string("gamma")]))])
        ])
        let changedAppleComparison = try compare(
            osd: osd, apple: changedApple, allowedDifferences: [allowance])
        #expect(changedAppleComparison.hasUnexpectedDifferences)
        #expect(changedAppleComparison.differences.map(\.isAllowed) == [false])

        let equalValues = makeOutput("openswiftdata", [
            ScenarioResult(id: id, observations: [ParityObservation(step: 0, field: "saved.names", value: appleValue)])
        ])
        #expect(throws: ComparisonError.unreferencedAllowlist(["FixtureSuite/expected divergence#saved.names"])) {
            try compare(osd: equalValues, apple: apple, allowedDifferences: [allowance])
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
            try compare(
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

private struct CoverageMatrixFixture: Decodable {
    let cases: [CoverageMatrixEntry]
}
