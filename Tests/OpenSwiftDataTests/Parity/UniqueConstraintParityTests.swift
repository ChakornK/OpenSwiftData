import Foundation
import OpenSwiftData
import Testing

@Model final class UniqueParityKeyed {
    @Attribute(.unique) var key: String
    var value: Int
    var note: String?
    init(_ key: String, _ value: Int, _ note: String? = nil) {
        self.key = key
        self.value = value
        self.note = note
    }
}

@Model final class UniqueParityComposite {
    #Unique<UniqueParityComposite>([\.a, \.b], [\.c])
    var a: Int
    var b: Int
    var c: String
    var v: Int
    init(_ a: Int, _ b: Int, _ c: String, _ v: Int) {
        self.a = a
        self.b = b
        self.c = c
        self.v = v
    }
}

/// Unique-constraint conflicts upsert instead of failing, as in Apple's SwiftData.
@MainActor @Suite struct UniqueConstraintParityTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: UniqueParityKeyed.self, UniqueParityComposite.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func stored() throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<UniqueParityKeyed>(sortBy: [SortDescriptor(\.key)]))
            .map { "\($0.key)/\($0.value)/\($0.note ?? "nil")" }
    }

    @Test func `inserting a duplicate overwrites the stored row and refreshes the existing instance`() throws {
        let first = UniqueParityKeyed("k", 1, "n1")
        context.insert(first)
        try context.save()

        let duplicate = UniqueParityKeyed("k", 2)
        context.insert(duplicate)
        #expect(try context.fetchCount(FetchDescriptor<UniqueParityKeyed>()) == 2)
        try context.save()

        #expect(try stored() == ["k/2/nil"])
        #expect(first.value == 2)
        #expect(first.note == nil)
        #expect(first.modelContext === context)
        #expect(!first.isDeleted)
        #expect(duplicate.modelContext === context)
        #expect(duplicate.persistentModelID != first.persistentModelID)
        #expect(!duplicate.hasChanges)
        #expect(!context.hasChanges)
        #expect(context.insertedModelsArray.isEmpty)
        let fetched = try context.fetch(FetchDescriptor<UniqueParityKeyed>())
        #expect(fetched.count == 1)
        #expect(fetched.first === first)
    }

    @Test func `edits to a merged duplicate do not reach the store`() throws {
        context.insert(UniqueParityKeyed("k", 1))
        try context.save()
        let duplicate = UniqueParityKeyed("k", 2)
        context.insert(duplicate)
        try context.save()

        duplicate.value = 99
        #expect(context.hasChanges)
        try context.save()
        #expect(try stored() == ["k/2/nil"])
    }

    @Test func `a merged duplicate gets a permanent identifier`() throws {
        context.insert(UniqueParityKeyed("k", 1))
        try context.save()
        let duplicate = UniqueParityKeyed("k", 2)
        context.insert(duplicate)
        try context.save()
        #expect(!duplicate.persistentModelID.isTemporary)
        #expect((context.registeredModel(for: duplicate.persistentModelID) as UniqueParityKeyed?) === duplicate)
        #expect(duplicate.persistentModelID.storeIdentifier != nil)
        #expect(try duplicate.persistentModelID != context.fetch(FetchDescriptor<UniqueParityKeyed>()).first?.persistentModelID)
    }

    @Test func `deleting a merged duplicate leaves the merged row`() throws {
        context.insert(UniqueParityKeyed("k", 1))
        try context.save()
        let duplicate = UniqueParityKeyed("k", 2)
        context.insert(duplicate)
        try context.save()

        context.delete(duplicate)
        try context.save()
        #expect(try stored() == ["k/2/nil"])
    }

    @Test func `duplicates inserted in one save collapse into one row`() throws {
        context.insert(UniqueParityKeyed("z", 1))
        context.insert(UniqueParityKeyed("z", 2))
        try context.save()
        #expect(try stored() == ["z/2/nil"])
    }

    @Test func `updating into a conflict merges the changed values and removes the updated row`() throws {
        context.insert(UniqueParityKeyed("k", 2))
        let moving = UniqueParityKeyed("m", 5, "mm")
        context.insert(moving)
        try context.save()
        let movingID = moving.persistentModelID

        moving.key = "k"
        try context.save()

        #expect(try stored() == ["k/2/nil"])
        #expect(moving.persistentModelID == movingID)
        #expect(moving.modelContext === context)
        #expect(!moving.isDeleted)
        #expect(moving.value == 5)
    }

    @Test func `composite and multiple constraints each merge conflicting inserts`() throws {
        context.insert(UniqueParityComposite(1, 1, "x", 1))
        try context.save()
        context.insert(UniqueParityComposite(1, 1, "y", 2))
        try context.save()
        context.insert(UniqueParityComposite(2, 2, "y", 3))
        try context.save()
        let rows = try ModelContext(container).fetch(FetchDescriptor<UniqueParityComposite>())
        #expect(rows.map { "\($0.a)\($0.b)\($0.c)/\($0.v)" } == ["22y/3"])
    }
}
