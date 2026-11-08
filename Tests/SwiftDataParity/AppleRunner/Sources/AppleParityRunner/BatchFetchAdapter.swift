import Foundation
import ParityContracts
import SwiftData

@available(macOS 15, *)
@Model
final class AppleBatchFetchScenarioRow {
    var name: String
    var rank: Int

    init(name: String, rank: Int) {
        self.name = name
        self.rank = rank
    }
}

@MainActor
@available(macOS 15, *)
enum AppleBatchFetchAdapter {
    static func runAll() throws -> [ScenarioResult] {
        try BatchFetchScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    static func runAndValidate(_ specification: BatchFetchSpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard BatchFetchExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: specification.id, observations: result.observations)
        }
        return result
    }

    static func run(_ specification: BatchFetchSpecification) throws -> ScenarioResult {
        let container = try ModelContainer(
            for: AppleBatchFetchScenarioRow.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        var observations: [ParityObservation] = []
        var snapshot: FetchResultsCollection<AppleBatchFetchScenarioRow>?

        for (stepIndex, step) in specification.steps.enumerated() {
            if step.seedRows {
                for row in specification.seedRows {
                    context.insert(AppleBatchFetchScenarioRow(name: row.name, rank: Int(row.rank)))
                }
            }
            if let pendingRow = step.insertPendingRow {
                context.insert(AppleBatchFetchScenarioRow(name: pendingRow.name, rank: Int(pendingRow.rank)))
            }
            let value = try observe(step.operation, context: context, snapshot: &snapshot)
            observations.append(ParityObservation(step: stepIndex, field: step.observationField, value: value))
            if step.save {
                try context.save()
            }
        }
        return ScenarioResult(id: specification.id, observations: observations)
    }

    private static func observe(
        _ operation: BatchFetchSpecification.Operation,
        context: ModelContext,
        snapshot: inout FetchResultsCollection<AppleBatchFetchScenarioRow>?
    ) throws -> ObservedValue {
        switch operation {
        case .expectModelBatchError:
            return .bool(try catchesExpectedError {
                _ = try context.fetch(FetchDescriptor<AppleBatchFetchScenarioRow>(), batchSize: 2)
            } == .includePendingChangesWithBatchSize)
        case .expectIdentifierBatchError:
            return .bool(try catchesExpectedError {
                _ = try context.fetchIdentifiers(FetchDescriptor<AppleBatchFetchScenarioRow>(), batchSize: 2)
            } == .includePendingChangesWithBatchSize)
        case .expectSortedIdentifierError:
            return .bool(try catchesExpectedError {
                _ = try context.fetchIdentifiers(
                    FetchDescriptor<AppleBatchFetchScenarioRow>(sortBy: [SortDescriptor(\.name)]))
            } == .sortingPendingChangesWithIdentifiers)
        case let .savedIdentifierCount(sorted):
            var descriptor = FetchDescriptor<AppleBatchFetchScenarioRow>(
                sortBy: sorted ? [SortDescriptor(\.rank)] : [])
            descriptor.includePendingChanges = false
            return .integer(Int64(try context.fetchIdentifiers(descriptor).count))
        case .randomAccessBatch:
            let results = try context.fetch(sortedDescriptor(), batchSize: 3)
            let descriptor = sortedDescriptor()
            let ranks = results.map(\.rank)
            let ordinaryFirst = try context.fetch(descriptor).first
            let repeatedAccessSameInstance = results[0] === results[0]
            let sameInstanceAsOrdinaryFetch = results[0] === ordinaryFirst
            return .object([
                "count": .integer(Int64(results.count)),
                "startIndex": .integer(Int64(results.startIndex)),
                "endIndex": .integer(Int64(results.endIndex)),
                "ranks": .array(ranks.map { .integer(Int64($0)) }),
                "first": .integer(Int64(results.first?.rank ?? -1)),
                "last": .integer(Int64(results.last?.rank ?? -1)),
                "slice": .array(results[2..<4].map { .integer(Int64($0.rank)) }),
                "reversed": .array(results.reversed().map { .integer(Int64($0.rank)) }),
                "repeatedAccessSameInstance": .bool(repeatedAccessSameInstance),
                "sameInstanceAsOrdinaryFetch": .bool(sameInstanceAsOrdinaryFetch),
            ])
        case .pageBatch:
            var descriptor = sortedDescriptor()
            descriptor.fetchLimit = 4
            descriptor.fetchOffset = 2
            return .array(try context.fetch(descriptor, batchSize: 3).map { .integer(Int64($0.rank)) })
        case .filteredBatch:
            let predicate = #Predicate<AppleBatchFetchScenarioRow> { $0.rank > 3 }
            var descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.rank)])
            descriptor.includePendingChanges = false
            return .array(try context.fetch(descriptor, batchSize: 2).map { .integer(Int64($0.rank)) })
        case let .batchSizeCounts(batchSizes):
            return .array(try batchSizes.map { batchSize in
                .integer(Int64(try context.fetch(sortedDescriptor(), batchSize: batchSize).count))
            })
        case .identifierCount:
            let descriptor = sortedDescriptor()
            let batched = try context.fetchIdentifiers(descriptor, batchSize: 2)
            let unbatched = try context.fetchIdentifiers(descriptor)
            return .bool(Array(batched) == unbatched)
        case .snapshotCounts:
            if snapshot == nil {
                snapshot = try context.fetch(sortedDescriptor(), batchSize: 3)
            }
            guard let snapshot else {
                throw ScenarioExpectationError(
                    id: ScenarioID(suite: "BatchFetchParityTests", test: "missing snapshot"), observations: [])
            }
            return .integer(Int64(snapshot.count))
        }
    }

    private static func catchesExpectedError(_ operation: () throws -> Void) -> SwiftDataError? {
        do {
            try operation()
            return nil
        } catch let error as SwiftDataError {
            return error
        } catch {
            return nil
        }
    }

    private static func sortedDescriptor() -> FetchDescriptor<AppleBatchFetchScenarioRow> {
        FetchDescriptor<AppleBatchFetchScenarioRow>(sortBy: [SortDescriptor(\.rank)], includePendingChanges: false)
    }
}
