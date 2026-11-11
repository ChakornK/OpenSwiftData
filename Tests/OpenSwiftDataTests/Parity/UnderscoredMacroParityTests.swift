import Foundation
import OpenSwiftData
import Testing

/// A `@Model` class that carries `@_PersistedProperty` explicitly, for
/// API-surface coverage. Requires the `@Model` macro patch that skips
/// `memberAttribute` generation for properties with an existing
/// `@_PersistedProperty` attribute.
@Model final class UnderscoredPersistedThing {
    @_PersistedProperty(slot: 0) var name: String
    init(name: String) { self.name = name }
}

/// A non-`@Model` class that carries `@_TransformablePersistedProperty` purely
/// for API-surface coverage. The macro expands to no accessors (the
/// `TransformablePersistedPropertyMacro` returns `[]`), so the property is a
/// plain stored property.
final class UnderscoredTransformableThing {
    @_TransformablePersistedProperty var blob: Data
    init(blob: Data) { self.blob = blob }
}

/// Underscored SwiftData macros (`@_PersistedProperty`, `@_TransformablePersistedProperty`),
/// referenced for parity API coverage.
@MainActor struct UnderscoredMacroParityTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: UnderscoredPersistedThing.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func `at PersistedProperty persists a model property`() throws {
        let thing = UnderscoredPersistedThing(name: "alpha")
        context.insert(thing)
        try context.save()
        #expect(thing.name == "alpha")
    }

    @Test func `at TransformablePersistedProperty attaches to a stored property`() throws {
        let thing = UnderscoredTransformableThing(blob: Data([0x01, 0x02]))
        #expect(thing.blob == Data([0x01, 0x02]))
    }
}
