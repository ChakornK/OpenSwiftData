import Foundation
import OpenSwiftData
import ParityContracts

@Model
final class ContainerParityThing {
    var name: String
    init(name: String) { self.name = name }
}

@MainActor
public enum OSDModelContainerParityAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        try ModelContainerParityScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    public static func runAndValidate(_ specification: ModelContainerParitySpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard ModelContainerParityExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: result.id, observations: result.observations)
        }
        return result
    }

    private static func run(_ specification: ModelContainerParitySpecification) throws -> ScenarioResult {
        let values: [String: ObservedValue]
        switch specification.query {
        case .configurationsAndIdentity:
            let configuration = ModelConfiguration("A", isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: ContainerParityThing.self, configurations: configuration)
            let other = try ModelContainer(for: ContainerParityThing.self, configurations: configuration)
            values = [
                "configurationSetMatches": .bool(Set(container.configurations) == [configuration]),
                "containerEqualsSelf": .bool(container == container),
                "differentContainersUnequal": .bool(container != other),
                "schemaEntityNames": .stringSet(container.schema.entities.map(\.name)),
            ]
        case .eraseKeepsStoreUsable:
            values = try eraseKeepsStoreUsable()
        case .eraseClearsHistory:
            values = try eraseClearsHistory()
        }

        return ScenarioResult(
            id: specification.id,
            observations: values.keys.sorted().map { field in
                ParityObservation(step: 0, field: field, value: values[field]!)
            })
    }

    private static func eraseKeepsStoreUsable() throws -> [String: ObservedValue] {
        let url = FileManager.default.temporaryDirectory.appending(path: "parity-erase-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let container = try ModelContainer(
            for: ContainerParityThing.self, configurations: ModelConfiguration(url: url))
        let context = container.mainContext
        let saved = ContainerParityThing(name: "a")
        context.insert(saved)
        try context.save()
        context.insert(ContainerParityThing(name: "pending"))

        var lastCompletedStep = 0
        var eraseReturned = true
        do {
            try container.erase()
            lastCompletedStep = 1
        } catch {
            eraseReturned = false
        }
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let hasChanges = context.hasChanges
        let savedAttached = saved.modelContext === context
        var fetchCountReturned = false
        var storedCount = -1
        var stored = FetchDescriptor<ContainerParityThing>()
        stored.includePendingChanges = false
        if eraseReturned {
            do {
                storedCount = try ModelContext(container).fetchCount(stored)
                fetchCountReturned = true
                lastCompletedStep = 2
            } catch {
                fetchCountReturned = false
            }
        }
        var pendingSaveReturned = false
        if fetchCountReturned {
            // Mirror the Apple adapter: save and fetch the pending row through a fresh context. The
            // pending insertion left in the stale mainContext is intentionally abandoned; the
            // contextHasChangesAfterErase observation above already captured that the stale context
            // still holds the pending change.
            let pendingContext = ModelContext(container)
            pendingContext.insert(ContainerParityThing(name: "pending"))
            do {
                try pendingContext.save()
                pendingSaveReturned = true
                lastCompletedStep = 3
            } catch {
                pendingSaveReturned = false
            }
        }
        var pendingFetchReturned = false
        var pendingNames: [String] = []
        if pendingSaveReturned {
            do {
                pendingNames = try ModelContext(container).fetch(stored).map(\.name)
                pendingFetchReturned = true
                lastCompletedStep = 4
            } catch {
                pendingFetchReturned = false
            }
        }
        return [
            "eraseReturned": .bool(eraseReturned), "fileExistsAfterErase": .bool(fileExists),
            "contextHasChangesAfterErase": .bool(hasChanges), "savedObjectAttachedAfterErase": .bool(savedAttached),
            "fetchCountReturned": .bool(fetchCountReturned), "storedCountAfterErase": .integer(Int64(storedCount)),
            "pendingSaveReturned": .bool(pendingSaveReturned), "pendingFetchReturned": .bool(pendingFetchReturned),
            "pendingNamesAfterSave": .array(pendingNames.map(ObservedValue.string)),
            "lastCompletedStep": .integer(Int64(lastCompletedStep)),
        ]
    }

    private static func eraseClearsHistory() throws -> [String: ObservedValue] {
        let container = try ModelContainer(
            for: ContainerParityThing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.insert(ContainerParityThing(name: "a"))
        try container.mainContext.save()
        var lastCompletedStep = 0
        var eraseReturned = true
        do {
            try container.erase()
            lastCompletedStep = 1
        } catch {
            eraseReturned = false
        }
        var historyFetchReturned = false
        var historyEmpty = false
        if eraseReturned {
            do {
                historyEmpty = try container.mainContext.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).isEmpty
                historyFetchReturned = true
                lastCompletedStep = 2
            } catch {
                historyFetchReturned = false
            }
        }
        return [
            "eraseReturned": .bool(eraseReturned), "historyFetchReturned": .bool(historyFetchReturned),
            "historyEmpty": .bool(historyEmpty), "lastCompletedStep": .integer(Int64(lastCompletedStep)),
        ]
    }
}
