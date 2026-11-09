import Foundation
import ParityContracts
import SwiftData

@available(macOS 15, *)
@Model
final class AppleBatchFetchProbeRow {
    var name: String
    var rank: Int

    init(name: String, rank: Int) {
        self.name = name
        self.rank = rank
    }
}

@MainActor
@available(macOS 15, *)
enum AppleBatchFetchProbe {
    static func run() throws -> [ParityObservation] {
        let container = try ModelContainer(
            for: AppleBatchFetchProbeRow.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        var observations: [ParityObservation] = []
        observations.append(observeError(
            field: "pending.modelBatch",
            step: 0,
            operation: {
                _ = try context.fetch(FetchDescriptor<AppleBatchFetchProbeRow>(), batchSize: 2)
            },
            expected: SwiftDataError.includePendingChangesWithBatchSize))
        observations.append(observeError(
            field: "pending.identifierBatch",
            step: 1,
            operation: {
                _ = try context.fetchIdentifiers(FetchDescriptor<AppleBatchFetchProbeRow>(), batchSize: 2)
            },
            expected: SwiftDataError.includePendingChangesWithBatchSize))
        let sortedIdentifiersDescriptor = FetchDescriptor<AppleBatchFetchProbeRow>(
            sortBy: [SortDescriptor(\.name)])
        observations.append(observeError(
            field: "pending.sortedIdentifiers",
            step: 2,
            operation: {
                _ = try context.fetchIdentifiers(sortedIdentifiersDescriptor)
            },
            expected: SwiftDataError.sortingPendingChangesWithIdentifiers))
        for index in 0..<7 {
            context.insert(AppleBatchFetchProbeRow(name: "n\(index)", rank: 7 - index))
        }
        try context.save()
        observations.append(ParityObservation(
            step: 3,
            field: "saved.defaultIdentifierCount",
            value: .integer(Int64(try context.fetchIdentifiers(FetchDescriptor<AppleBatchFetchProbeRow>()).count))))
        var sortedByRank = FetchDescriptor<AppleBatchFetchProbeRow>(sortBy: [SortDescriptor(\.rank)])
        sortedByRank.includePendingChanges = false
        observations.append(ParityObservation(
            step: 4,
            field: "saved.sortedIdentifierCount",
            value: .integer(Int64(try context.fetchIdentifiers(sortedByRank).count))))

        return observations
    }

    private static func observeError(
        field: String,
        step: Int,
        operation: () throws -> Void,
        expected: SwiftDataError
    ) -> ParityObservation {
        do {
            try operation()
            return ParityObservation(
                step: step,
                field: field,
                value: .object(["threwExpectedError": .bool(false)]))
        } catch {
            return ParityObservation(
                step: step,
                field: field,
                value: .object(["threwExpectedError": .bool(expected ~= error)]))
        }
    }
}
