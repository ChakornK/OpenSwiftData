import Foundation
import OpenSwiftData
import Testing

@Model final class BatchFetchParityThing {
    var name: String
    var rank: Int
    init(name: String, rank: Int) {
        self.name = name
        self.rank = rank
    }
}

/// Batched fetches and identifier fetches, matching Apple's SwiftData.
@MainActor @Suite struct BatchFetchParityTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var savedByRank: FetchDescriptor<BatchFetchParityThing> {
        var descriptor = FetchDescriptor<BatchFetchParityThing>(sortBy: [SortDescriptor(\.rank)])
        descriptor.includePendingChanges = false
        return descriptor
    }

    init() throws {
        container = try ModelContainer(
            for: BatchFetchParityThing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func seed() throws {
        for index in 0..<7 { context.insert(BatchFetchParityThing(name: "n\(index)", rank: 7 - index)) }
        try context.save()
    }

    @Test func `batched fetches require excluding pending changes`() {
        #expect(throws: SwiftDataError.includePendingChangesWithBatchSize) {
            try context.fetch(FetchDescriptor<BatchFetchParityThing>(), batchSize: 2)
        }
        #expect(throws: SwiftDataError.includePendingChangesWithBatchSize) {
            try context.fetchIdentifiers(FetchDescriptor<BatchFetchParityThing>(), batchSize: 2)
        }
    }

    @Test func `sorted identifier fetches require excluding pending changes`() throws {
        #expect(throws: SwiftDataError.sortingPendingChangesWithIdentifiers) {
            try context.fetchIdentifiers(FetchDescriptor<BatchFetchParityThing>(sortBy: [SortDescriptor(\.name)]))
        }
        try seed()
        #expect(try context.fetchIdentifiers(FetchDescriptor<BatchFetchParityThing>()).count == 7)
        #expect(try context.fetchIdentifiers(savedByRank).count == 7)
    }

    @Test func `batched results are a random access collection in fetch order`() throws {
        try seed()
        let results = try context.fetch(savedByRank, batchSize: 3)
        #expect(results.count == 7)
        #expect(results.startIndex == 0)
        #expect(results.endIndex == 7)
        #expect(results.map(\.rank) == [1, 2, 3, 4, 5, 6, 7])
        #expect(results.first?.rank == 1)
        #expect(results.last?.rank == 7)
        #expect(results[2..<4].map(\.rank) == [3, 4])
        #expect(results.reversed().map(\.rank) == [7, 6, 5, 4, 3, 2, 1])
        #expect(results[0] === results[0])
        #expect(results[0] === (try context.fetch(savedByRank)).first)
    }

    @Test func `batched fetches honor predicates, limits, and offsets`() throws {
        try seed()
        var page = savedByRank
        page.fetchLimit = 4
        page.fetchOffset = 2
        #expect(try context.fetch(page, batchSize: 3).map(\.rank) == [3, 4, 5, 6])
        var filtered = savedByRank
        filtered.predicate = #Predicate { $0.rank > 3 }
        #expect(try context.fetch(filtered, batchSize: 2).map(\.rank) == [4, 5, 6, 7])
    }

    @Test(arguments: [0, -1, 1, 100])
    func `any batch size returns every result`(batchSize: Int) throws {
        try seed()
        #expect(try context.fetch(savedByRank, batchSize: batchSize).count == 7)
    }

    @Test func `batched identifiers match unbatched identifiers`() throws {
        try seed()
        let batched = try context.fetchIdentifiers(savedByRank, batchSize: 2)
        #expect(Array(batched) == (try context.fetchIdentifiers(savedByRank)))
    }

    @Test func `batched results exclude pending insertions and keep their snapshot`() throws {
        try seed()
        context.insert(BatchFetchParityThing(name: "pending", rank: 100))
        let results = try context.fetch(savedByRank, batchSize: 3)
        #expect(results.count == 7)
        try context.save()
        #expect(results.count == 7)
    }
}
