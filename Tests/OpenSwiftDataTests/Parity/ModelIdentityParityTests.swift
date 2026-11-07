import Foundation
import OpenSwiftData
import Testing

@Model final class IdentityParityThing {
    var name: String
    init(name: String) { self.name = name }
}

@Model final class IdentityParityCustomID {
    var id: UUID
    var name: String
    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Model equality, hashing, and identity, matching Apple's SwiftData.
@MainActor @Suite struct ModelIdentityParityTests {
    let container: ModelContainer

    init() throws {
        container = try ModelContainer(
            for: IdentityParityThing.self, IdentityParityCustomID.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func `models compare by instance identity`() throws {
        let first = IdentityParityThing(name: "a")
        let second = IdentityParityThing(name: "a")
        #expect(first == first)
        #expect(first != second)
        #expect(first.hashValue != second.hashValue)

        let context = container.mainContext
        context.insert(first)
        context.insert(second)
        try context.save()
        #expect(first != second)
    }

    @Test func `the id is the persistent identifier`() throws {
        let model = IdentityParityThing(name: "a")
        #expect(model.id == model.persistentModelID)
        container.mainContext.insert(model)
        try container.mainContext.save()
        #expect(model.id == model.persistentModelID)
    }

    @Test func `saving replaces the temporary identifier`() throws {
        let model = IdentityParityThing(name: "a")
        container.mainContext.insert(model)
        let temporary = model.persistentModelID
        #expect(temporary.storeIdentifier == nil)
        try container.mainContext.save()
        #expect(model.persistentModelID != temporary)
        #expect(model.persistentModelID.storeIdentifier != nil)
    }

    @Test func `instances of one row in two contexts hash equally but compare unequal`() throws {
        let model = IdentityParityThing(name: "a")
        container.mainContext.insert(model)
        try container.mainContext.save()

        let other = ModelContext(container)
        let copy = try #require(try other.fetch(FetchDescriptor<IdentityParityThing>()).first)
        #expect(copy !== model)
        #expect(copy != model)
        #expect(copy.hashValue == model.hashValue)
        #expect(Set([model, copy]).count == 2)
    }

    @Test func `a declared id property replaces the identifier id`() {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let model = IdentityParityCustomID(id: uuid, name: "w")
        #expect(model.id == uuid)
        let _: UUID = model.id
    }

    @Test func `models are Identifiable and Observable`() {
        func requiresIdentifiable<T: Identifiable>(_: T) {}
        func requiresObservable<T: Observable>(_: T) {}
        let model = IdentityParityThing(name: "a")
        requiresIdentifiable(model)
        requiresObservable(model)
    }
}

@MainActor @Suite struct ModelContextInitParityTests {
    @Test func `a context made from a container enables autosave and references the container`() throws {
        let container = try ModelContainer(
            for: IdentityParityThing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        #expect(context.autosaveEnabled)
        #expect(context.container === container)
        #expect(context.undoManager == nil)
        #expect(!context.hasChanges)
        #expect(container.mainContext.autosaveEnabled)
    }
}
