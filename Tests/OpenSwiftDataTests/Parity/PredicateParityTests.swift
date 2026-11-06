import Foundation
import OpenSwiftData
import Testing

@Model final class PredicateParityRow {
    var name: String
    var age: Int
    var nick: String?
    init(_ name: String, _ age: Int, _ nick: String?) {
        self.name = name
        self.age = age
        self.nick = nick
    }
}

/// Predicate evaluation, matching Apple's SwiftData for both pending and saved models.
@MainActor @Suite struct PredicateParityTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: PredicateParityRow.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        for row in [
            PredicateParityRow("a", 1, "x"), PredicateParityRow("b", 2, nil), PredicateParityRow("c", 3, "z"),
            PredicateParityRow("d", 4, "x"),
        ] {
            container.mainContext.insert(row)
        }
    }

    /// Returns the matching names, first with pending models and then after saving.
    private func names(_ predicate: Predicate<PredicateParityRow>) throws -> (pending: [String], saved: [String]) {
        var descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.age)])
        let pending = try context.fetch(descriptor).map(\.name)
        try context.save()
        descriptor.includePendingChanges = false
        return (pending, try context.fetch(descriptor).map(\.name))
    }

    @Test func `membership in a captured array`() throws {
        let wanted = ["a", "c"]
        let result = try names(#Predicate { wanted.contains($0.name) })
        #expect(result.pending == ["a", "c"])
        #expect(result.saved == ["a", "c"])
    }

    @Test func `membership in an array literal`() throws {
        let result = try names(#Predicate { ["b", "d"].contains($0.name) })
        #expect(result.pending == ["b", "d"])
        #expect(result.saved == ["b", "d"])
    }

    @Test func `membership in an empty array matches nothing`() throws {
        let none: [String] = []
        let result = try names(#Predicate { none.contains($0.name) })
        #expect(result.pending.isEmpty)
        #expect(result.saved.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor(predicate: #Predicate<PredicateParityRow> { none.contains($0.name) })) == 0)
    }

    @Test func `negated, integer, and combined membership`() throws {
        let wanted = ["a", "c"]
        let ages = [2, 4, 9]
        #expect(try names(#Predicate { !wanted.contains($0.name) }).saved == ["b", "d"])
        #expect(try names(#Predicate { ages.contains($0.age) }).saved == ["b", "d"])
        #expect(try names(#Predicate { wanted.contains($0.name) || $0.age > 3 }).saved == ["a", "c", "d"])
    }
}
