import Foundation
import OpenSwiftData
import ParityContracts

@Model
final class ConfigurationContainerParityThing {
    var name: String
    init(name: String) { self.name = name }
}

@MainActor
public enum OSDModelConfigurationContainerAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        let invalidNameResult = rejectsInvalidName()
        let independentStoresResult = try independentInMemoryStores()
        let nestedFileStoreResult = try nestedFileStore()
        return [invalidNameResult, independentStoresResult, nestedFileStoreResult]
            .sorted { $0.id.description < $1.id.description }
    }

    private static func rejectsInvalidName() -> ScenarioResult {
        let rejected: Bool
        do {
            _ = try ModelContainer(
                for: ConfigurationContainerParityThing.self,
                configurations: ModelConfiguration("a/b", isStoredInMemoryOnly: true))
            rejected = false
        } catch {
            rejected = true
        }
        return makeResult(
            ModelConfigurationContainerScenarioCatalog.invalidName.id,
            ["invalidName.containerRejected": .bool(rejected)])
    }

    private static func independentInMemoryStores() throws -> ScenarioResult {
        let first = try ModelContainer(
            for: ConfigurationContainerParityThing.self,
            configurations: ModelConfiguration("Same", isStoredInMemoryOnly: true))
        first.mainContext.insert(ConfigurationContainerParityThing(name: "x"))
        try first.mainContext.save()
        let second = try ModelContainer(
            for: ConfigurationContainerParityThing.self,
            configurations: ModelConfiguration("Same", isStoredInMemoryOnly: true))
        let count = try second.mainContext.fetchCount(FetchDescriptor<ConfigurationContainerParityThing>())
        return makeResult(
            ModelConfigurationContainerScenarioCatalog.independentInMemoryStores.id,
            ["secondStore.fetchCount": .integer(Int64(count))])
    }

    private static func nestedFileStore() throws -> ScenarioResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osd-parity-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/store.sqlite")
        let container = try ModelContainer(
            for: ConfigurationContainerParityThing.self, configurations: ModelConfiguration(url: url))
        container.mainContext.insert(ConfigurationContainerParityThing(name: "x"))
        try container.mainContext.save()
        let fetchedNames = try container.mainContext.fetch(FetchDescriptor<ConfigurationContainerParityThing>())
            .map(\.name)
        return makeResult(
            ModelConfigurationContainerScenarioCatalog.nestedFileStore.id,
            [
                "saved.fileExists": .bool(FileManager.default.fileExists(atPath: url.path)),
                "saved.fetchNames": .array(fetchedNames.map(ObservedValue.string)),
            ])
    }

    private static func makeResult(_ id: ScenarioID, _ values: [String: ObservedValue]) -> ScenarioResult {
        ScenarioResult(
            id: id,
            observations: values.sorted { $0.key < $1.key }.enumerated().map { step, pair in
                ParityObservation(step: step, field: pair.key, value: pair.value)
            })
    }
}
