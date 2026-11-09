import OSDParityRuntime
import ParityContracts
import Testing

@Suite struct OSDScenarioAdapterTests {
    @MainActor
    @Test func uniqueConstraintScenariosMatchSharedContracts() throws {
        let results = try OSDUniqueConstraintAdapter.runAll()
        #expect(results.map(\.id) == UniqueConstraintScenarioCatalog.all.map(\.id).sorted {
            $0.description < $1.description
        })
        for specification in UniqueConstraintScenarioCatalog.all {
            let result = try #require(results.first { $0.id == specification.id })
            #expect(UniqueConstraintExpectationValidator.validate(result, against: specification))
        }
    }

    @MainActor
    @Test func historyScenariosMatchSharedExpectations() throws {
        let results = try OSDHistoryParityAdapter.runAll()
        #expect(results.map(\.id) == HistoryParityScenarioCatalog.all.map(\.id).sorted {
            $0.description < $1.description
        })
        for specification in HistoryParityScenarioCatalog.all {
            let result = try #require(results.first { $0.id == specification.id })
            #expect(HistoryParityExpectationValidator.validate(result, against: specification))
        }
    }

    @MainActor
    @Test func predicateMembershipMatchesSharedExpectations() throws {
        let results = try OSDScenarioAdapter.runAll()
        let pendingFetchResults = try OSDPendingFetchAdapter.runAll()
        let batchFetchResults = try OSDBatchFetchAdapter.runAll()
        let batchDeleteResults = try OSDBatchDeleteAdapter.runAll()
        let codableResults = try OSDCodableParityAdapter.runAll()
        let contextNotificationResults = try OSDContextNotificationAdapter.runAll()
        let rollbackResults = try OSDRollbackAdapter.runAll()
        let modelContextResults = try OSDModelContextParityAdapter.runAll()
        let historyResults = try OSDHistoryParityAdapter.runAll()
        let uniqueConstraintResults = try OSDUniqueConstraintAdapter.runAll()
        let expectedIDs = (ParityScenarioCatalog.all.map(\.id) + SchemaIntrospectionScenarioCatalog.all.map(\.id)
            + SchemaModelTypesScenarioCatalog.all.map(\.id) + StoreIdentifierScenarioCatalog.all.map(\.id)
            + ModelIdentityScenarioCatalog.all.map(\.id) + ModelConfigurationScenarioCatalog.all.map(\.id)
            + ModelConfigurationContainerScenarioCatalog.all.map(\.id)
            + PendingFetchScenarioCatalog.all.map(\.id)
            + BatchFetchScenarioCatalog.all.map(\.id)
            + BatchDeleteScenarioCatalog.all.map(\.id)
            + CodableParityScenarioCatalog.all.map(\.id)
            + ContextNotificationScenarioCatalog.all.map(\.id)
            + RollbackParityScenarioCatalog.all.map(\.id)
            + ModelContextParityScenarioCatalog.all.map(\.id)
            + HistoryParityScenarioCatalog.all.map(\.id)
            + UniqueConstraintScenarioCatalog.all.map(\.id)
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
        let selectionID = ModelConfigurationScenarioCatalog.cloudAndGroupSelections.id
        let selectionResult = try #require(results.first { $0.id == selectionID })
        #expect(Set(selectionResult.observations.map(\.field)) == ["selected.cloudIdentifierMatches"])
        for specification in ModelConfigurationContainerScenarioCatalog.all {
            let result = try #require(results.first { $0.id == specification.id })
            #expect(Set(result.observations.map(\.field)) == specification.contract.expectedObservationFields)
        }
        for specification in PendingFetchScenarioCatalog.all {
            let result = try #require(results.first { $0.id == specification.id })
            #expect(PendingFetchExpectationValidator.validate(result, against: specification))
            #expect(result.observations.map(\.field) == specification.expectedObservations.map(\.field))
            let directResult = try #require(pendingFetchResults.first { $0.id == specification.id })
            #expect(directResult == result)
        }
        #expect(batchFetchResults.map(\.id) == BatchFetchScenarioCatalog.all.map(\.id).sorted {
            $0.description < $1.description
        })
        for specification in BatchFetchScenarioCatalog.all {
            let result = try #require(batchFetchResults.first { $0.id == specification.id })
            #expect(BatchFetchExpectationValidator.validate(result, against: specification))
        }
        #expect(batchDeleteResults.map(\.id) == BatchDeleteScenarioCatalog.all.map(\.id).sorted {
            $0.description < $1.description
        })
        for specification in BatchDeleteScenarioCatalog.all {
            let result = try #require(batchDeleteResults.first { $0.id == specification.id })
            #expect(BatchDeleteExpectationValidator.validate(result, against: specification))
        }
        #expect(codableResults.map(\.id) == CodableParityScenarioCatalog.all.map(\.id).sorted {
            $0.description < $1.description
        })
        for specification in CodableParityScenarioCatalog.all {
            let result = try #require(codableResults.first { $0.id == specification.id })
            #expect(CodableParityExpectationValidator.validate(result, against: specification))
        }
        #expect(contextNotificationResults.map(\.id) == ContextNotificationScenarioCatalog.all.map(\.id).sorted {
            $0.description < $1.description
        })
        for specification in ContextNotificationScenarioCatalog.all {
            let result = try #require(contextNotificationResults.first { $0.id == specification.id })
            #expect(ContextNotificationExpectationValidator.validate(result, against: specification))
        }
        #expect(rollbackResults.map(\.id) == RollbackParityScenarioCatalog.all.map(\.id).sorted {
            $0.description < $1.description
        })
        for specification in RollbackParityScenarioCatalog.all {
            let result = try #require(rollbackResults.first { $0.id == specification.id })
            #expect(RollbackParityExpectationValidator.validate(
                result, against: specification, implementation: "openswiftdata"))
        }
        #expect(modelContextResults.map(\.id) == ModelContextParityScenarioCatalog.all.map(\.id).sorted {
            $0.description < $1.description
        })
        for specification in ModelContextParityScenarioCatalog.all {
            let result = try #require(modelContextResults.first { $0.id == specification.id })
            #expect(ModelContextParityExpectationValidator.validate(
                result, against: specification, implementation: "openswiftdata"))
        }
        #expect(historyResults.map(\.id) == HistoryParityScenarioCatalog.all.map(\.id).sorted {
            $0.description < $1.description
        })
        for specification in HistoryParityScenarioCatalog.all {
            let result = try #require(historyResults.first { $0.id == specification.id })
            #expect(HistoryParityExpectationValidator.validate(result, against: specification))
        }
        #expect(uniqueConstraintResults.map(\.id) == UniqueConstraintScenarioCatalog.all.map(\.id).sorted {
            $0.description < $1.description
        })
        for specification in UniqueConstraintScenarioCatalog.all {
            let result = try #require(uniqueConstraintResults.first { $0.id == specification.id })
            #expect(UniqueConstraintExpectationValidator.validate(result, against: specification))
        }
        for id in ModelConfigurationScenarioCatalog.nonComparableSelectionIDs {
            let result = try #require(results.first { $0.id == id })
            #expect(result.disposition == .nonComparable(
                reasonCategory: "shim-only-api",
                rationale: ModelConfigurationScenarioCatalog.nonComparableSelectionReason))
            #expect(result.observations.isEmpty)
        }
    }
}
