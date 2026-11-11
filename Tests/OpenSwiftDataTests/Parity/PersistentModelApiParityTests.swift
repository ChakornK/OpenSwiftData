import Foundation
import OpenSwiftData
import Testing

@Model final class PersistentModelApiThing {
    var name: String
    init(name: String) { self.name = name }
}

/// `PersistentModel` transformable-value accessors, referenced for parity API
/// coverage. The accessors delegate to `getValue`/`setValue` in OpenSwiftData's
/// stub.
@MainActor struct PersistentModelApiParityTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: PersistentModelApiThing.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func `getTransformableValue reads a stored property`() throws {
        let thing = PersistentModelApiThing(name: "alpha")
        context.insert(thing)
        try context.save()
        let name: String = thing.getTransformableValue(forKey: \.name)
        #expect(name == "alpha")
    }

    @Test func `setTransformableValue writes a stored property`() throws {
        let thing = PersistentModelApiThing(name: "beta")
        context.insert(thing)
        thing.setTransformableValue(forKey: \.name, to: "gamma")
        #expect(thing.name == "gamma")
    }
}
