import Foundation
import OpenSwiftData
import Testing

@Model final class BackingDataApiThing {
    var name: String
    init(name: String) { self.name = name }
}

/// `BackingData` underscored SPI, referenced for parity API coverage. The
/// methods return fresh detached backing data in OpenSwiftData's stub.
@MainActor @Suite struct BackingDataApiParityTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: BackingDataApiThing.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func `_generateCurrentClassBackingData returns a backing data`() throws {
        let thing = BackingDataApiThing(name: "alpha")
        context.insert(thing)
        try context.save()
        let backing = thing.persistentBackingData
        let _: any BackingData<BackingDataApiThing> = backing._generateCurrentClassBackingData()
        #expect(true)
    }

    @Test func `_superClassBackingData returns a backing data`() throws {
        let thing = BackingDataApiThing(name: "beta")
        context.insert(thing)
        try context.save()
        let backing = thing.persistentBackingData
        let _: any BackingData<BackingDataApiThing> = backing._superClassBackingData(of: BackingDataApiThing.self)
        #expect(true)
    }
}
