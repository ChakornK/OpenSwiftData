import Foundation
import OpenSwiftData
import Testing

@Model final class RollbackParityOwner {
    var name: String
    var age: Int
    var tag: String?
    var tags: [String] = []
    @Relationship(inverse: \RollbackParityItem.owner) var items: [RollbackParityItem] = []
    init(name: String, age: Int) {
        self.name = name
        self.age = age
    }
}

@Model final class RollbackParityItem {
    var value: Int
    var owner: RollbackParityOwner?
    init(value: Int) { self.value = value }
}

/// `rollback()` semantics observed from Apple's SwiftData.
@MainActor @Suite struct RollbackParityTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var saved: FetchDescriptor<RollbackParityOwner> {
        var descriptor = FetchDescriptor<RollbackParityOwner>()
        descriptor.includePendingChanges = false
        return descriptor
    }

    init() throws {
        container = try ModelContainer(
            for: RollbackParityOwner.self, RollbackParityItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func `rollback restores committed values immediately and clears change tracking`() throws {
        let owner = RollbackParityOwner(name: "a", age: 1)
        context.insert(owner)
        try context.save()

        owner.age = 2
        owner.name = "a2"
        owner.tag = "t"
        owner.tags = ["x"]
        context.rollback()
        // Apple semantics: rollback clears pending state but keeps the in-memory edits until a
        // fetch refreshes the registered instance from the stored row.
        #expect(owner.age == 2)
        #expect(owner.name == "a2")
        #expect(owner.tag == "t")
        #expect(owner.tags == ["x"])
        #expect(!owner.hasChanges)
        #expect(!context.hasChanges)
        #expect(owner.modelContext === context)
        // The store keeps the saved values.
        #expect(try ModelContext(container).fetch(saved).map(\.age) == [1])

        // A fetch after rollback reverts in-memory edits to the stored row, as in Apple's SwiftData.
        let fetched = try context.fetch(saved)
        #expect(fetched.first === owner)
        #expect(owner.age == 1)
        #expect(owner.name == "a")
        #expect(owner.tag == nil)
        #expect(owner.tags.isEmpty)
    }

    @Test func `rollback restores committed relationship edits`() throws {
        let owner = RollbackParityOwner(name: "a", age: 1)
        let item = RollbackParityItem(value: 1)
        context.insert(owner)
        context.insert(item)
        try context.save()

        owner.items.append(item)
        context.rollback()
        // Apple semantics: the in-memory relationship stays as mutated until the next fetch.
        #expect(owner.items.count == 1)
        #expect(item.owner === owner)
        #expect(!context.hasChanges)
        // The store keeps the saved graph.
        #expect(try ModelContext(container).fetch(saved).first?.items.isEmpty == true)
    }

    @Test func `rollback detaches related insertions and restores saved graph`() throws {
        let owner = RollbackParityOwner(name: "a", age: 1)
        context.insert(owner)
        try context.save()

        let item = RollbackParityItem(value: 2)
        owner.items.append(item)
        #expect(item.modelContext === context)
        #expect(item.owner === owner)

        context.rollback()

        // The saved owner keeps the in-memory relationship; the unsaved item detaches from the
        // store but keeps its in-memory inverse, as in Apple's SwiftData.
        #expect(owner.items.count == 1)
        #expect(item.modelContext == nil)
        #expect(item.owner === owner)
        #expect(!owner.hasChanges)
        #expect(!context.hasChanges)
        #expect(try context.fetchCount(FetchDescriptor<RollbackParityItem>()) == 0)
    }

    @Test func `rollback restores first committed values after repeated edits`() throws {
        let owner = RollbackParityOwner(name: "a", age: 1)
        context.insert(owner)
        try context.save()

        owner.age = 2
        owner.age = 3
        context.rollback()

        #expect(owner.age == 3)
        #expect(!owner.hasChanges)

        owner.age = 4
        #expect(owner.hasChanges)
        context.rollback()
        #expect(owner.age == 4)
        #expect(!owner.hasChanges)
    }

    @Test func `rollback restores values when an edited model is deleted`() throws {
        let owner = RollbackParityOwner(name: "a", age: 1)
        context.insert(owner)
        try context.save()

        owner.age = 2
        context.delete(owner)
        context.rollback()

        #expect(owner.age == 2)
        #expect(!owner.isDeleted)
        #expect(owner.modelContext === context)
        #expect(!context.hasChanges)
    }

    @Test func `rollback detaches insertions and restores deletions`() throws {
        let inserted = RollbackParityOwner(name: "b", age: 5)
        context.insert(inserted)
        context.rollback()
        #expect(inserted.modelContext == nil)
        #expect(!inserted.isDeleted)
        #expect(context.insertedModelsArray.isEmpty)
        #expect(inserted.name == "b")

        let owner = RollbackParityOwner(name: "a", age: 1)
        context.insert(owner)
        try context.save()
        context.delete(owner)
        #expect(owner.isDeleted)
        context.rollback()
        #expect(!owner.isDeleted)
        #expect(owner.modelContext === context)
        #expect(try context.fetchCount(FetchDescriptor<RollbackParityOwner>()) == 1)
    }
}

@MainActor @Suite struct RollbackRelationshipParityTests {
    @Test func `rolled back relationship edits are not saved`() throws {
        let container = try ModelContainer(
            for: RollbackParityOwner.self, RollbackParityItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let owner = RollbackParityOwner(name: "a", age: 1)
        let item = RollbackParityItem(value: 1)
        context.insert(owner)
        context.insert(item)
        try context.save()

        owner.items.append(item)
        context.rollback()
        #expect(context.changedModelsArray.isEmpty)
        try context.save()
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<RollbackParityOwner>()).first)
        #expect(stored.items.isEmpty)
    }
}
