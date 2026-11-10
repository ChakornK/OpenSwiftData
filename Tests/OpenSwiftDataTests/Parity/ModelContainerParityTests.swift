import Foundation
import OpenSwiftData
import Testing

@Model final class ContainerParityThing {
    var name: String
    init(name: String) { self.name = name }
}

/// `ModelContainer` behaviors, matching Apple's SwiftData.
@MainActor @Suite struct ModelContainerParityTests {
    @Test func `configurations are a set and containers compare by identity`() throws {
        let configuration = ModelConfiguration("A", isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ContainerParityThing.self, configurations: configuration)
        let configurations: Set<ModelConfiguration> = container.configurations
        // Apple's SwiftData attaches the container's schema to the configurations it exposes, so a
        // configuration returned by `container.configurations` carries a schema while the caller's
        // original configuration does not. They therefore compare unequal.
        #expect(configurations != [configuration])
        #expect(container == container)
        let other = try ModelContainer(for: ContainerParityThing.self, configurations: configuration)
        #expect(container != other)
        #expect(container.schema.entities.map(\.name) == ["ContainerParityThing"])
    }

    @Test func `erasing removes stored models and keeps the store usable`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("osd-erase-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let container = try ModelContainer(for: ContainerParityThing.self, configurations: ModelConfiguration(url: url))
        let context = container.mainContext
        let saved = ContainerParityThing(name: "a")
        context.insert(saved)
        try context.save()
        context.insert(ContainerParityThing(name: "pending"))

        try container.erase()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(context.hasChanges)
        #expect(saved.modelContext === context)
        var stored = FetchDescriptor<ContainerParityThing>()
        stored.includePendingChanges = false
        #expect(try ModelContext(container).fetchCount(stored) == 0)

        try context.save()
        #expect(try ModelContext(container).fetch(stored).map(\.name) == ["pending"])
    }

    @Test func `erasing also clears history`() throws {
        let container = try ModelContainer(
            for: ContainerParityThing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.insert(ContainerParityThing(name: "a"))
        try container.mainContext.save()
        try container.erase()
        #expect(try container.mainContext.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).isEmpty)
    }
}
