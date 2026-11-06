import Foundation
import OpenSwiftData
import Testing

/// Model names that collide with identifiers the macros generate must still compile, as they do with SwiftData.
@Model final class Root {
    var name: String
    @Relationship(inverse: \Leaf.root) var leaves: [Leaf] = []
    init(name: String) { self.name = name }
}

@Model final class Leaf {
    var root: Root?
    init() {}
}

@MainActor @Suite struct MacroNamingParityTests {
    @Test func `a model named Root persists and relates`() throws {
        let container = try ModelContainer(
            for: Root.self, Leaf.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let root = Root(name: "r")
        let leaf = Leaf()
        container.mainContext.insert(root)
        container.mainContext.insert(leaf)
        root.leaves.append(leaf)
        try container.mainContext.save()
        #expect(leaf.root === root)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Root>()).map(\.name) == ["r"])
    }
}
