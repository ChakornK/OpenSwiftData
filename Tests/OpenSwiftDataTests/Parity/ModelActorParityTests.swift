import Foundation
import OpenSwiftData
import Testing

@Model final class ActorParityThing {
    var name: String
    init(name: String) { self.name = name }
}

@ModelActor actor ActorParityWorker {
    func insert(_ name: String) throws -> PersistentIdentifier {
        let thing = ActorParityThing(name: name)
        modelContext.insert(thing)
        try modelContext.save()
        return thing.persistentModelID
    }

    func name(of id: PersistentIdentifier) -> String? { self[id, as: ActorParityThing.self]?.name }

    func count() throws -> Int { try modelContext.fetchCount(FetchDescriptor<ActorParityThing>()) }
}

/// `@ModelActor` and executors, matching Apple's SwiftData API.
@Suite struct ModelActorParityTests {
    @Test func `a model actor works with its own context`() async throws {
        let container = try ModelContainer(
            for: ActorParityThing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let worker = ActorParityWorker(modelContainer: container)
        #expect(worker.modelContainer === container)
        let _: any ModelExecutor = worker.modelExecutor
        let id = try await worker.insert("a")
        #expect(try await worker.count() == 1)
        #expect(await worker.name(of: id) == "a")
        let missing = try PersistentIdentifier.identifier(for: "x", entityName: "ActorParityThing", primaryKey: 99)
        #expect(await worker.name(of: missing) == nil)
    }

    @Test func `executors can wrap an existing context`() throws {
        let container = try ModelContainer(
            for: ActorParityThing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let executor = DefaultSerialModelExecutor(modelContext: context)
        #expect(executor.modelContext === context)
        let _: any SerialModelExecutor = executor
    }
}
