import Foundation
import OpenSwiftData
import ParityContracts

@Model
final class NotificationParityModel {
    var name: String
    init(name: String) { self.name = name }
}

private final class ContextNotificationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(Notification.Name, [AnyHashable: Any]?)] = []

    var entries: [(Notification.Name, [AnyHashable: Any]?)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ notification: Notification) {
        lock.lock()
        defer { lock.unlock() }
        storage.append((notification.name, notification.userInfo))
    }
}

@MainActor
public enum OSDContextNotificationAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        try ContextNotificationScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    public static func runAndValidate(_ specification: ContextNotificationSpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard ContextNotificationExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: result.id, observations: result.observations)
        }
        return result
    }

    private static func run(_ specification: ContextNotificationSpecification) throws -> ScenarioResult {
        let container = try ModelContainer(
            for: NotificationParityModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        var values: [String: ObservedValue]

        switch specification.query {
        case .rawValues:
            let keys: [ModelContext.NotificationKey] = [
                .queryGeneration, .invalidatedAllIdentifiers, .insertedIdentifiers,
                .updatedIdentifiers, .deletedIdentifiers,
            ]
            values = [
                "names": .array([.string(ModelContext.willSave.rawValue), .string(ModelContext.didSave.rawValue)]),
                "keys": .array(keys.map { .string($0.rawValue) }),
                "insertedKeyRoundTrip": .bool(ModelContext.NotificationKey(rawValue: "inserted") == .insertedIdentifiers),
            ]
        case .saveNotifications:
            let log = ContextNotificationLog()
            let observers = [ModelContext.willSave, ModelContext.didSave].map { name in
                NotificationCenter.default.addObserver(forName: name, object: context, queue: nil) { log.append($0) }
            }
            defer { observers.forEach(NotificationCenter.default.removeObserver) }

            let first = NotificationParityModel(name: "a")
            let second = NotificationParityModel(name: "b")
            context.insert(first)
            context.insert(second)
            try context.save()
            first.name = "a2"
            context.delete(second)
            try context.save()
            try context.save()

            let entries = log.entries
            func identifiers(_ index: Int, _ key: ModelContext.NotificationKey) -> [PersistentIdentifier]? {
                entries[index].1?[key.rawValue] as? [PersistentIdentifier]
            }
            values = [
                "names": .array(entries.map { .string($0.0.rawValue) }),
                "willSaveInfoEmpty": .bool(entries.filter { $0.0 == ModelContext.willSave }.allSatisfy { ($0.1 ?? [:]).isEmpty }),
                "firstInsertedCount": .integer(Int64(identifiers(1, .insertedIdentifiers)?.count ?? -1)),
                "firstUpdatedCount": .integer(Int64(identifiers(1, .updatedIdentifiers)?.count ?? -1)),
                "firstDeletedCount": .integer(Int64(identifiers(1, .deletedIdentifiers)?.count ?? -1)),
                "secondInsertedCount": .integer(Int64(identifiers(3, .insertedIdentifiers)?.count ?? -1)),
                "secondUpdatedCount": .integer(Int64(identifiers(3, .updatedIdentifiers)?.count ?? -1)),
                "secondDeletedCount": .integer(Int64(identifiers(3, .deletedIdentifiers)?.count ?? -1)),
            ]
        case .editingState:
            let other = ModelContext(container)
            let initialAuthorsNil = context.author == nil && context.editingState.author == nil
            let sameContextEditingIDStable = context.editingState.id == context.editingState.id
            let differentContextsHaveDifferentEditingIDs = context.editingState.id != other.editingState.id
            context.author = "me"
            values = [
                "initialAuthorsNil": .bool(initialAuthorsNil),
                "sameContextEditingIDStable": .bool(sameContextEditingIDStable),
                "differentContextsHaveDifferentEditingIDs": .bool(differentContextsHaveDifferentEditingIDs),
                "updatedAuthor": .string(context.editingState.author ?? ""),
                "contextsCompareByIdentity": .bool(context == context && context != other),
            ]
        }

        let result = ScenarioResult(
            id: specification.id,
            observations: values.keys.sorted().map {
                ParityObservation(step: 0, field: $0, value: values[$0]!)
            })
        return result
    }
}
