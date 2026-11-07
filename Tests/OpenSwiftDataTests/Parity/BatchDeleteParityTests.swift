import Foundation
import OpenSwiftData
import Testing

@Model final class BatchParityOwner {
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \BatchParityPet.owner) var pets: [BatchParityPet] = []
    init(name: String) { self.name = name }
}

@Model final class BatchParityPet {
    var name: String
    var owner: BatchParityOwner?
    init(name: String) { self.name = name }
}

@Model final class BatchParityKeeper {
    var name: String
    @Relationship(deleteRule: .deny, inverse: \BatchParityToy.keeper) var toys: [BatchParityToy] = []
    init(name: String) { self.name = name }
}

@Model final class BatchParityToy {
    var name: String
    var keeper: BatchParityKeeper?
    init(name: String) { self.name = name }
}

/// `delete(model:where:includeSubclasses:)` works directly against the store, as in Apple's SwiftData.
@MainActor @Suite struct BatchDeleteParityTests {
    let container: ModelContainer
    var saved: FetchDescriptor<BatchParityOwner> {
        var descriptor = FetchDescriptor<BatchParityOwner>(sortBy: [SortDescriptor(\.name)])
        descriptor.includePendingChanges = false
        return descriptor
    }

    init() throws {
        container = try ModelContainer(
            for: BatchParityOwner.self, BatchParityPet.self, BatchParityKeeper.self, BatchParityToy.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func `batch deletes leave pending changes and registered instances alone`() throws {
        let context = container.mainContext
        let a = BatchParityOwner(name: "a")
        let b = BatchParityOwner(name: "b")
        context.insert(a)
        context.insert(b)
        try context.save()
        let c = BatchParityOwner(name: "c")
        context.insert(c)

        try context.delete(model: BatchParityOwner.self, where: #Predicate { $0.name == "a" || $0.name == "c" })

        #expect(context.hasChanges)
        #expect(context.insertedModelsArray.count == 1)
        #expect(context.deletedModelsArray.isEmpty)
        #expect(!a.isDeleted)
        #expect(a.modelContext === context)
        #expect(c.modelContext === context)
        #expect(try ModelContext(container).fetch(saved).map(\.name) == ["b"])
        #expect(
            try context.fetch(FetchDescriptor<BatchParityOwner>(sortBy: [SortDescriptor(\.name)])).map(\.name) == [
                "b", "c",
            ])
        try context.save()
        #expect(try ModelContext(container).fetch(saved).map(\.name) == ["b", "c"])
    }

    @Test func `batch deletes apply cascade rules`() throws {
        let context = container.mainContext
        let owner = BatchParityOwner(name: "a")
        let pet = BatchParityPet(name: "p")
        context.insert(owner)
        context.insert(pet)
        owner.pets.append(pet)
        try context.save()

        try context.delete(model: BatchParityOwner.self)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<BatchParityPet>()) == 0)
    }

    @Test func `batch deletes post no save notifications`() throws {
        let context = container.mainContext
        context.insert(BatchParityOwner(name: "a"))
        try context.save()
        nonisolated(unsafe) var posted = 0
        let container = container
        let observers = [ModelContext.willSave, ModelContext.didSave].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { notification in
                guard let source = notification.object as? ModelContext, source.container === container else {
                    return
                }
                posted += 1
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        try context.delete(model: BatchParityOwner.self)
        #expect(posted == 0)
    }

    @Test func `deny rules make batch deletes throw without deleting`() throws {
        let context = container.mainContext
        let keeper = BatchParityKeeper(name: "k")
        let toy = BatchParityToy(name: "t")
        context.insert(keeper)
        context.insert(toy)
        keeper.toys.append(toy)
        try context.save()

        let error = #expect(throws: NSError.self) { try context.delete(model: BatchParityKeeper.self) }
        #expect(error?.domain == NSCocoaErrorDomain)
        #expect(error?.code == 134060)
        #expect(error?.userInfo["Relationship"] as? String == "BatchParityKeeper.toys")
        #expect(error?.userInfo["Reason"] as? String == "Delete rule is not supported for batch deletes")
        #expect(try context.fetchCount(FetchDescriptor<BatchParityKeeper>()) == 1)
        #expect(toy.keeper === keeper)
    }

    @Test func `batch deletes inside a failed transaction stay applied`() throws {
        struct Boom: Error {}
        let context = container.mainContext
        context.insert(BatchParityOwner(name: "a"))
        try context.save()
        #expect(throws: Boom.self) {
            try context.transaction {
                try context.delete(model: BatchParityOwner.self)
                throw Boom()
            }
        }
        #expect(try ModelContext(container).fetchCount(saved) == 0)
    }

    @Test func `batch deletes with no matches change nothing`() throws {
        let context = container.mainContext
        context.insert(BatchParityOwner(name: "a"))
        try context.save()
        try context.delete(model: BatchParityOwner.self, where: #Predicate { $0.name == "zzz" })
        #expect(!context.hasChanges)
        #expect(try context.fetchCount(saved) == 1)
    }
}
