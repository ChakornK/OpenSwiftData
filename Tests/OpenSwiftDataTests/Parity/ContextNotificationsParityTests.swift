import Foundation
import OpenSwiftData
import Testing

@Model final class NotificationParityThing {
    var name: String
    init(name: String) { self.name = name }
}

private final class NotificationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(name: Notification.Name, info: [AnyHashable: Any]?)] = []
    var entries: [(name: Notification.Name, info: [AnyHashable: Any]?)] { lock.withLock { storage } }
    func append(_ notification: Notification) {
        lock.withLock { storage.append((notification.name, notification.userInfo)) }
    }
}

/// Save notifications, matching Apple's SwiftData.
@MainActor @Suite struct ContextNotificationsParityTests {
    @Test func `notification names and keys use SwiftData's raw values`() {
        #expect(ModelContext.willSave.rawValue == "ModelContextWillSave")
        #expect(ModelContext.didSave.rawValue == "ModelContextDidSave")
        let keys: [ModelContext.NotificationKey] = [
            .queryGeneration, .invalidatedAllIdentifiers, .insertedIdentifiers, .updatedIdentifiers,
            .deletedIdentifiers,
        ]
        #expect(keys.map(\.rawValue) == ["newQueryGeneration", "invalidatedAll", "inserted", "updated", "deleted"])
        #expect(ModelContext.NotificationKey(rawValue: "inserted") == .insertedIdentifiers)
    }

    @Test func `saves post willSave without info and didSave only when changes commit`() throws {
        let container = try ModelContainer(
            for: NotificationParityThing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let log = NotificationLog()
        let observers = [ModelContext.willSave, ModelContext.didSave].map { name in
            NotificationCenter.default.addObserver(forName: name, object: context, queue: nil) { log.append($0) }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }

        let first = NotificationParityThing(name: "a")
        let second = NotificationParityThing(name: "b")
        context.insert(first)
        context.insert(second)
        try context.save()
        first.name = "a2"
        context.delete(second)
        try context.save()
        try context.save()

        let entries = log.entries
        #expect(entries.map(\.name) == [
            ModelContext.willSave, ModelContext.didSave, ModelContext.willSave, ModelContext.didSave,
            ModelContext.willSave,
        ])
        #expect(entries.filter { $0.name == ModelContext.willSave }.allSatisfy { ($0.info ?? [:]).isEmpty })
        func identifiers(_ index: Int, _ key: ModelContext.NotificationKey) -> [PersistentIdentifier]? {
            entries[index].info?[key.rawValue] as? [PersistentIdentifier]
        }
        #expect(identifiers(1, .insertedIdentifiers)?.count == 2)
        #expect(identifiers(1, .updatedIdentifiers)?.count == 0)
        #expect(identifiers(1, .deletedIdentifiers)?.count == 0)
        #expect(identifiers(3, .insertedIdentifiers)?.count == 0)
        #expect(identifiers(3, .updatedIdentifiers) == [first.persistentModelID])
        #expect(identifiers(3, .deletedIdentifiers)?.count == 1)
    }

    @Test func `contexts expose author and a stable editing state`() throws {
        let container = try ModelContainer(
            for: NotificationParityThing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let other = ModelContext(container)
        #expect(context.author == nil)
        #expect(context.editingState.author == nil)
        #expect(context.editingState.id == context.editingState.id)
        #expect(context.editingState.id != other.editingState.id)
        context.author = "me"
        #expect(context.editingState.author == "me")
        #expect(context == context)
        #expect(context != other)
    }
}
