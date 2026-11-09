import OpenSwiftData
import ParityContracts

@Model
final class BatchFetchScenarioRow {
    var name: String
    var rank: Int

    init(name: String, rank: Int) {
        self.name = name
        self.rank = rank
    }
}

@MainActor
public enum OSDBatchFetchAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        var results: [ScenarioResult] = []
        for specification in BatchFetchScenarioCatalog.all {
            results.append(try runAndValidate(specification))
        }
        return results.sorted { $0.id.description < $1.id.description }
    }

    public static func runAndValidate(_ specification: BatchFetchSpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard BatchFetchExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: specification.id, observations: result.observations)
        }
        return result
    }

    public static func run(_ specification: BatchFetchSpecification) throws -> ScenarioResult {
        let container = try ModelContainer(
            for: BatchFetchScenarioRow.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        var observations: [ParityObservation] = []
        var snapshot: FetchResultsCollection<BatchFetchScenarioRow>?

        for (stepIndex, step) in specification.steps.enumerated() {
            if step.seedRows {
                insert(specification.seedRows, into: context)
            }
            if let pendingRow = step.insertPendingRow {
                context.insert(BatchFetchScenarioRow(name: pendingRow.name, rank: Int(pendingRow.rank)))
            }
            if step.saveBeforeObservation {
                try context.save()
            }
            let value = try observe(step.operation, context: context, snapshot: &snapshot)
            observations.append(ParityObservation(step: stepIndex, field: step.observationField, value: value))
            if step.save {
                try context.save()
            }
        }
        return ScenarioResult(id: specification.id, observations: observations)
    }

    private static func insert(_ rows: [BatchFetchSpecification.Row], into context: ModelContext) {
        for row in rows {
            context.insert(BatchFetchScenarioRow(name: row.name, rank: Int(row.rank)))
        }
    }

    private static func observe(
        _ operation: BatchFetchSpecification.Operation,
        context: ModelContext,
        snapshot: inout FetchResultsCollection<BatchFetchScenarioRow>?
    ) throws -> ObservedValue {
        switch operation {
        case .expectModelBatchError:
            return .bool(catchesExpectedError {
                _ = try context.fetch(FetchDescriptor<BatchFetchScenarioRow>(), batchSize: 2)
            } == .includePendingChangesWithBatchSize)
        case .expectIdentifierBatchError:
            return .bool(catchesExpectedError {
                _ = try context.fetchIdentifiers(FetchDescriptor<BatchFetchScenarioRow>(), batchSize: 2)
            } == .includePendingChangesWithBatchSize)
        case .expectSortedIdentifierError:
            return .bool(catchesExpectedError {
                _ = try context.fetchIdentifiers(
                    FetchDescriptor<BatchFetchScenarioRow>(sortBy: [SortDescriptor(\.name)]))
            } == .sortingPendingChangesWithIdentifiers)
        case .saveSeed:
            return .null
        case let .savedIdentifierCount(sorted):
            var descriptor = FetchDescriptor<BatchFetchScenarioRow>(
                sortBy: sorted ? [SortDescriptor(\.rank)] : [])
            descriptor.includePendingChanges = false
            return .integer(Int64(try context.fetchIdentifiers(descriptor).count))
        case .randomAccessBatch:
            let descriptor = sortedDescriptor()
            let results = try context.fetch(descriptor, batchSize: 3)
            let ranks = results.map(\.rank)
            let ordinaryFirst = try context.fetch(descriptor).first
            let repeatedAccessSameInstance = results[0] === results[0]
            let sameInstanceAsOrdinaryFetch = results[0] === ordinaryFirst
            let slice: [ObservedValue] = results[2..<4].map { .integer(Int64($0.rank)) }
            let reversed: [ObservedValue] = results.reversed().map { .integer(Int64($0.rank)) }
            return .object([
                "count": .integer(Int64(results.count)),
                "startIndex": .integer(Int64(results.startIndex)),
                "endIndex": .integer(Int64(results.endIndex)),
                "ranks": .array(ranks.map { .integer(Int64($0)) }),
                "first": .integer(Int64(results.first?.rank ?? -1)),
                "last": .integer(Int64(results.last?.rank ?? -1)),
                "slice": .array(slice),
                "reversed": .array(reversed),
                "repeatedAccessSameInstance": .bool(repeatedAccessSameInstance),
                "sameInstanceAsOrdinaryFetch": .bool(sameInstanceAsOrdinaryFetch),
            ])
        case .pageBatch:
            return .array(try context.fetch(makeDescriptor(limit: 4, offset: 2), batchSize: 3)
                .map { .integer(Int64($0.rank)) })
        case .filteredBatch:
            let predicate = #Predicate<BatchFetchScenarioRow> { $0.rank > 3 }
            var descriptor = FetchDescriptor<BatchFetchScenarioRow>(
                predicate: predicate, sortBy: [SortDescriptor(\.rank)])
            descriptor.includePendingChanges = false
            return .array(try context.fetch(descriptor, batchSize: 2).map { .integer(Int64($0.rank)) })
        case let .batchSizeCount(batchSize):
            return .integer(Int64(try context.fetch(sortedDescriptor(), batchSize: batchSize).count))
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

    private static func sortedDescriptor() -> FetchDescriptor<BatchFetchScenarioRow> {
        FetchDescriptor<BatchFetchScenarioRow>(sortBy: [SortDescriptor(\.rank)], includePendingChanges: false)
    }

    private static func makeDescriptor(
        limit: Int? = nil,
        offset: Int? = nil,
        rankGreaterThan: Int? = nil
    ) -> FetchDescriptor<BatchFetchScenarioRow> {
        let predicate: Predicate<BatchFetchScenarioRow>?
        if let rankGreaterThan {
            predicate = #Predicate { $0.rank > rankGreaterThan }
        } else {
            predicate = nil
        }
        var descriptor = FetchDescriptor<BatchFetchScenarioRow>(
            predicate: predicate, sortBy: [SortDescriptor(\.rank)])
        descriptor.includePendingChanges = false
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        return descriptor
    }

}
