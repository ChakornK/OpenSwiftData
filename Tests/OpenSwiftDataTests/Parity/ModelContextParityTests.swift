import Foundation
import OpenSwiftData
import Testing

@Model final class ContextParityThing {
    var name: String
    init(name: String) { self.name = name }
}

/// `ModelContext` behaviors observed from Apple's SwiftData.
@MainActor @Suite struct ModelContextParityTests {
    let container: ModelContainer

    init() throws {
        container = try ModelContainer(
            for: ContextParityThing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func `model(for:) returns the registered instance, including for temporary identifiers`() throws {
        let context = container.mainContext
        let model = ContextParityThing(name: "a")
        context.insert(model)
        #expect(context.model(for: model.persistentModelID) === model)
        try context.save()
        #expect(context.model(for: model.persistentModelID) === model)
    }

    @Test func `model(for:) loads and registers saved models in another context`() throws {
        let model = ContextParityThing(name: "a")
        container.mainContext.insert(model)
        try container.mainContext.save()

        let other = ModelContext(container)
        let loaded = other.model(for: model.persistentModelID)
        let thing = try #require(loaded as? ContextParityThing)
        #expect(thing.name == "a")
        #expect(thing.modelContext === other)
        #expect(!thing.hasChanges)
        #expect(!thing.isDeleted)
        #expect(other.model(for: model.persistentModelID) === loaded)
        #expect((other.registeredModel(for: model.persistentModelID) as ContextParityThing?) === thing)
    }

    @Test func `processing pending changes keeps them pending`() {
        let context = container.mainContext
        context.insert(ContextParityThing(name: "b"))
        context.processPendingChanges()
        #expect(context.hasChanges)
        #expect(context.insertedModelsArray.count == 1)
    }

    @Test func `a transaction saves changes made before and inside it`() throws {
        let context = container.mainContext
        context.insert(ContextParityThing(name: "before"))
        try context.transaction { context.insert(ContextParityThing(name: "inside")) }
        #expect(!context.hasChanges)
        var saved = FetchDescriptor<ContextParityThing>()
        saved.includePendingChanges = false
        #expect(try context.fetchCount(saved) == 2)
    }
}

/// Deleting a model that was inserted but not saved, matching Apple's SwiftData.
@MainActor @Suite struct DeletedInsertionParityTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: ContextParityThing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func `a deleted insertion is reported as inserted and deleted until saved`() throws {
        let model = ContextParityThing(name: "p")
        context.insert(model)
        context.delete(model)
        #expect(model.isDeleted)
        #expect(model.modelContext === context)
        #expect(context.hasChanges)
        #expect(context.insertedModelsArray.count == 1)
        #expect(context.deletedModelsArray.count == 1)
        #expect(try context.fetch(FetchDescriptor<ContextParityThing>()).isEmpty)

        try context.save()
        #expect(model.modelContext == nil)
        #expect(!model.isDeleted)
        #expect(!context.hasChanges)
        #expect(context.insertedModelsArray.isEmpty)
        #expect(context.deletedModelsArray.isEmpty)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<ContextParityThing>()) == 0)
    }

    @Test func `inserting a deleted insertion again does nothing`() {
        let model = ContextParityThing(name: "p")
        context.insert(model)
        context.delete(model)
        context.insert(model)
        #expect(model.isDeleted)
        #expect(context.insertedModelsArray.count == 1)
        #expect(context.deletedModelsArray.count == 1)
    }

    @Test func `rolling back detaches a deleted insertion`() {
        let model = ContextParityThing(name: "p")
        context.insert(model)
        context.delete(model)
        context.rollback()
        #expect(model.modelContext == nil)
        #expect(!model.isDeleted)
        #expect(!context.hasChanges)
    }
}
