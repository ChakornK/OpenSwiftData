import Foundation
import OpenSwiftData
import Testing

@Model final class SortingParityThing {
    var name: String
    var optionalName: String?
    var rank: Double
    init(name: String, optionalName: String?, rank: Double) {
        self.name = name
        self.optionalName = optionalName
        self.rank = rank
    }
}

/// Sorting uses Foundation's `SortDescriptor` and matches Apple's SwiftData string orderings.
@MainActor @Suite struct SortingParityTests {
    static let names = ["b", "B", "a", "A", "item10", "item2", "é", "e", "Z", "_x", "10", "9", "ä"]
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: SortingParityThing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        for (index, name) in Self.names.enumerated() {
            container.mainContext.insert(
                SortingParityThing(name: name, optionalName: index % 3 == 0 ? nil : name, rank: Double(index) - 5.5))
        }
    }

    private func names(_ sort: [Foundation.SortDescriptor<SortingParityThing>]) throws -> (pending: [String], saved: [String]) {
        var descriptor = FetchDescriptor<SortingParityThing>(sortBy: sort + [SortDescriptor(\.rank)])
        let pending = try context.fetch(descriptor).map(\.name)
        try context.save()
        descriptor.includePendingChanges = false
        return (pending, try context.fetch(descriptor).map(\.name))
    }

    typealias Case = (sort: Foundation.SortDescriptor<SortingParityThing>, expected: [String])
    nonisolated static let cases: [Case] = [
        (SortDescriptor(\.name), ["_x", "9", "10", "a", "A", "ä", "b", "B", "e", "é", "item2", "item10", "Z"]),
        (SortDescriptor(\.name, order: .reverse), ["Z", "item10", "item2", "é", "e", "B", "b", "ä", "A", "a", "10", "9", "_x"]),
        (SortDescriptor(\.name, comparator: .localizedStandard), ["_x", "9", "10", "a", "A", "ä", "b", "B", "e", "é", "item2", "item10", "Z"]),
        (SortDescriptor(\.name, comparator: .localized), ["_x", "10", "9", "a", "A", "ä", "b", "B", "e", "é", "item10", "item2", "Z"]),
        (SortDescriptor(\.name, comparator: .lexical), ["10", "9", "A", "B", "Z", "_x", "a", "b", "e", "item10", "item2", "ä", "é"]),
        (SortDescriptor(\.optionalName), ["b", "A", "é", "_x", "ä", "9", "10", "a", "B", "e", "item2", "item10", "Z"]),
        (SortDescriptor(\.optionalName, order: .reverse), ["Z", "item10", "item2", "e", "B", "a", "10", "9", "b", "A", "é", "_x", "ä"]),
        (SortDescriptor(\.rank, order: .reverse), ["ä", "9", "10", "_x", "Z", "e", "é", "item2", "item10", "A", "a", "B", "b"]),
    ]

    @Test(arguments: cases)
    func `string and numeric orderings match for pending and saved models`(_ testCase: Case) throws {
        let (pending, saved) = try names([testCase.sort])
        #expect(pending == testCase.expected)
        #expect(saved == testCase.expected)
    }

    @Test func `fetch descriptors accept Foundation sort descriptors and sort orders`() {
        let order: Foundation.SortOrder = .reverse
        let sort: [Foundation.SortDescriptor<SortingParityThing>] = [SortDescriptor(\.name, order: order)]
        let descriptor = FetchDescriptor<SortingParityThing>(sortBy: sort)
        #expect(descriptor.sortBy.first?.order == .reverse)
    }
}
