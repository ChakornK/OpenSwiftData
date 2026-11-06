import Foundation
import OpenSwiftData
import Testing

@Model final class PendingFetchPerson {
    var name: String
    var age: Int
    init(name: String, age: Int) {
        self.name = name
        self.age = age
    }
}

@Model final class PendingFetchRoot {
    var name: String
    @Relationship(inverse: \PendingFetchLeaf.root) var leaves: [PendingFetchLeaf] = []
    var partner: PendingFetchLeaf?
    init(name: String) { self.name = name }
}

@Model final class PendingFetchLeaf {
    var flag: Bool
    var root: PendingFetchRoot?
    init(flag: Bool) { self.flag = flag }
}

/// How fetches that include pending changes combine stored rows with unsaved edits, matching Apple's SwiftData.
///
/// The store applies the predicate, sort, offset, and limit to stored values. Pending deletions are dropped,
/// changed models are re-evaluated in memory, matching changed and inserted models merge in, and only the
/// limit is applied again.
@MainActor @Suite struct PendingFetchParityTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try ModelContainer(
            for: PendingFetchPerson.self, PendingFetchRoot.self, PendingFetchLeaf.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let seed = ModelContext(container)
        for (name, age) in [("s1", 10), ("s2", 30), ("s3", 50), ("s4", 70)] {
            seed.insert(PendingFetchPerson(name: name, age: age))
        }
        try seed.save()
        context = ModelContext(container)
    }

    private func names(
        limit: Int? = nil, offset: Int? = nil, pending: Bool = true, predicate: Predicate<PendingFetchPerson>? = nil
    ) throws -> [String] {
        var descriptor = FetchDescriptor<PendingFetchPerson>(predicate: predicate, sortBy: [SortDescriptor(\.age)])
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        descriptor.includePendingChanges = pending
        return try context.fetch(descriptor).map(\.name)
    }

    private func count(limit: Int?, offset: Int? = nil) throws -> Int {
        var descriptor = FetchDescriptor<PendingFetchPerson>(sortBy: [SortDescriptor(\.age)])
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        return try context.fetchCount(descriptor)
    }

    /// Inserts p1 (20), changes s1 to 60, and deletes s2.
    private func makePendingChanges() throws {
        context.insert(PendingFetchPerson(name: "p1", age: 20))
        let byName = { (name: String) in
            try #require(try context.fetch(FetchDescriptor<PendingFetchPerson>(predicate: #Predicate { $0.name == name })).first)
        }
        try byName("s1").age = 60
        context.delete(try byName("s2"))
    }

    @Test func `a zero fetch limit means no limit`() throws {
        #expect(try names(limit: 0, pending: false) == ["s1", "s2", "s3", "s4"])
        #expect(try names(limit: 0, offset: 1, pending: false) == ["s2", "s3", "s4"])
        #expect(try count(limit: 0) == 4)
        var descriptor = FetchDescriptor<PendingFetchPerson>()
        descriptor.fetchLimit = 0
        descriptor.includePendingChanges = false
        #expect(try context.fetchIdentifiers(descriptor).count == 4)
    }

    @Test func `stored rows paginate before pending changes merge`() throws {
        try makePendingChanges()
        #expect(try names() == ["p1", "s3", "s1", "s4"])
        #expect(try names(limit: 2) == ["p1", "s1"])
        #expect(try names(offset: 1) == ["p1", "s3", "s1", "s4"])
        #expect(try names(limit: 2, offset: 1) == ["p1", "s3"])
        #expect(try names(limit: 0, offset: 2) == ["p1", "s3", "s1", "s4"])
        #expect(try count(limit: nil) == 4)
        #expect(try count(limit: 2) == 2)
        #expect(try count(limit: 2, offset: 1) == 2)
    }

    @Test func `changed models are re-evaluated against the predicate in memory`() throws {
        try makePendingChanges()
        #expect(try names(predicate: #Predicate { $0.age < 40 }) == ["p1"])
        #expect(try names(limit: 1, predicate: #Predicate { $0.age < 40 }) == ["p1"])
        #expect(try names(offset: 1, predicate: #Predicate { $0.age > 55 }) == ["s1"])
    }

    @Test func `excluding pending changes returns only stored rows`() throws {
        try makePendingChanges()
        #expect(try names(pending: false) == ["s1", "s2", "s3", "s4"])
    }

    @Test func `edits to related models do not affect unchanged owners until saved`() throws {
        let r1 = PendingFetchRoot(name: "r1")
        let r2 = PendingFetchRoot(name: "r2")
        let l1 = PendingFetchLeaf(flag: false)
        let l2 = PendingFetchLeaf(flag: true)
        let partner = PendingFetchLeaf(flag: false)
        [r1, r2].forEach(context.insert)
        [l1, l2, partner].forEach(context.insert)
        r1.leaves = [l1]
        r2.leaves = [l2]
        r1.partner = partner
        try context.save()

        let containsFlag = FetchDescriptor<PendingFetchRoot>(
            predicate: #Predicate { $0.leaves.contains { $0.flag } }, sortBy: [SortDescriptor(\.name)])
        let partnerUnflagged = FetchDescriptor<PendingFetchRoot>(predicate: #Predicate { $0.partner?.flag == false })

        l1.flag = true
        #expect(!r1.hasChanges)
        #expect(try context.fetch(containsFlag).map(\.name) == ["r2"])
        partner.flag = true
        #expect(try context.fetch(partnerUnflagged).map(\.name) == ["r1"])
        l2.flag = false
        #expect(try context.fetch(containsFlag).map(\.name) == ["r2"])

        try context.save()
        #expect(try context.fetch(containsFlag).map(\.name) == ["r1"])
        #expect(try context.fetch(partnerUnflagged).isEmpty)
    }

    @Test func `relationship membership changes re-evaluate the owner`() throws {
        let r1 = PendingFetchRoot(name: "r1")
        context.insert(r1)
        try context.save()
        let leaf = PendingFetchLeaf(flag: true)
        context.insert(leaf)
        r1.leaves.append(leaf)
        #expect(r1.hasChanges)
        let descriptor = FetchDescriptor<PendingFetchRoot>(predicate: #Predicate { $0.leaves.contains { $0.flag } })
        #expect(try context.fetch(descriptor).map(\.name) == ["r1"])
    }

    @Test func `assigning a relationship on a detached model updates the managed inverse`() throws {
        let root = PendingFetchRoot(name: "r")
        context.insert(root)
        try context.save()
        let leaf = PendingFetchLeaf(flag: true)
        leaf.root = root
        #expect(leaf.modelContext === context)
        #expect(root.hasChanges)
        #expect(root.leaves.count == 1)
    }
}
