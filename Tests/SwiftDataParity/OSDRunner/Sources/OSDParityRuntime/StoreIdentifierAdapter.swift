import Foundation
import OpenSwiftData
import ParityContracts

@Model
final class StoreIdentifierItem {
    var name: String
    init(name: String) { self.name = name }
}

@MainActor
public enum OSDStoreIdentifierAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        try NonComparableScenarios.apply(StoreIdentifierScenarioCatalog.all.map(run))
            .sorted { $0.id.description < $1.id.description }
    }

    private static func run(_ specification: StoreIdentifierSpecification) throws -> ScenarioResult {
        let observations: [String: ObservedValue]
        switch specification.id {
        case StoreIdentifierScenarioCatalog.savedIdentifierIsUUID.id:
            let container = try makeMemoryContainer()
            let item = StoreIdentifierItem(name: "a")
            container.mainContext.insert(item)
            let temporaryIdentifierIsAbsent = item.persistentModelID.storeIdentifier == nil
            try container.mainContext.save()
            let storeIdentifier = item.persistentModelID.storeIdentifier
            observations = [
                "temporary.storeIdentifierAbsent": .bool(temporaryIdentifierIsAbsent),
                "saved.storeIdentifierPresent": .bool(storeIdentifier != nil),
                "saved.storeIdentifierIsUUID": .bool(storeIdentifier.flatMap(UUID.init(uuidString:)) != nil),
            ]
        case StoreIdentifierScenarioCatalog.identifierSurvivesReopen.id:
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "parity-store-identifier-\(UUID().uuidString)", directoryHint: .isDirectory)
            let url = directory.appending(path: "default.store")
            // Mirror the Apple adapter: pre-create the parent directory so the store path exists before
            // ModelContainer(url:) is opened, even though OpenSwiftData does not emit CoreData noise.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let identifier: PersistentIdentifier
            do {
                let container = try ModelContainer(
                    for: StoreIdentifierItem.self, configurations: ModelConfiguration(url: url))
                let item = StoreIdentifierItem(name: "a")
                container.mainContext.insert(item)
                try container.mainContext.save()
                identifier = item.persistentModelID
            }
            let reopened = try ModelContainer(
                for: StoreIdentifierItem.self, configurations: ModelConfiguration(url: url))
            let fetched = try reopened.mainContext.fetch(FetchDescriptor<StoreIdentifierItem>())
            let resolved: StoreIdentifierItem? = reopened.mainContext.registeredModel(for: identifier)
            observations = [
                "reopened.identifierEqual": .bool(fetched.first?.persistentModelID == identifier),
                "reopened.storeIdentifierEqual": .bool(
                    fetched.first?.persistentModelID.storeIdentifier == identifier.storeIdentifier),
                "reopened.fetchName": .array(fetched.map { .string($0.name) }),
                "reopened.registeredName": .string(resolved?.name ?? "missing"),
            ]
        case StoreIdentifierScenarioCatalog.separateStoresDiffer.id:
            let first = try savedStoreIdentifier()
            let second = try savedStoreIdentifier()
            observations = ["stores.identifiersDiffer": .bool(first != second)]
        default:
            throw ScenarioExpectationError(id: specification.id, observations: [])
        }
        return ScenarioResult(
            id: specification.id,
            observations: observations.sorted { $0.key < $1.key }.enumerated().map { step, pair in
                ParityObservation(step: step, field: pair.key, value: pair.value)
            })
    }

    private static func makeMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: StoreIdentifierItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private static func savedStoreIdentifier() throws -> String? {
        let container = try makeMemoryContainer()
        let item = StoreIdentifierItem(name: "a")
        container.mainContext.insert(item)
        try container.mainContext.save()
        return item.persistentModelID.storeIdentifier
    }
}
