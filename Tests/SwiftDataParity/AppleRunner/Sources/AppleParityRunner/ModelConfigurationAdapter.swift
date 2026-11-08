import Foundation
import ParityContracts
import SwiftData

@available(macOS 15, *)
@Model
final class ConfigurationParityThing {
    var name: String
    init(name: String) { self.name = name }
}

@available(macOS 15, *)
@Model
final class ConfigurationParityOther {
    var value: Int
    init(value: Int) { self.value = value }
}

@MainActor
@available(macOS 15, *)
enum AppleModelConfigurationAdapter {
    static func runAll() -> [ScenarioResult] {
        let comparableResults = ModelConfigurationScenarioCatalog.all.map(run)
        let nonComparableResults = ModelConfigurationScenarioCatalog.nonComparableSelectionIDs.map { id in
            return ScenarioResult(
                id: id,
                observations: [],
                disposition: .nonComparable(
                    reasonCategory: "shim-only-api",
                    rationale: ModelConfigurationScenarioCatalog.nonComparableSelectionReason))
        }
        return (comparableResults + nonComparableResults).sorted { $0.id.description < $1.id.description }
    }

    private static func run(_ specification: ModelConfigurationSpecification) -> ScenarioResult {
        let observations: [String: ObservedValue]
        switch specification.id {
        case ModelConfigurationScenarioCatalog.defaultConfiguration.id:
            let configuration = ModelConfiguration()
            observations = [
                "name": .string(configuration.name),
                "url.fileName": .string(configuration.url.lastPathComponent),
                "url.parent": .string(configuration.url.deletingLastPathComponent().lastPathComponent),
                "idMatchesURL": .bool(configuration.id == configuration.url),
                "inMemory": .bool(configuration.isStoredInMemoryOnly),
                "allowsSave": .bool(configuration.allowsSave),
                "hasSchema": .bool(configuration.schema != nil),
                "hasGroupIdentifier": .bool(configuration.groupAppContainerIdentifier != nil),
                "hasCloudIdentifier": .bool(configuration.cloudKitContainerIdentifier != nil),
            ]
        case ModelConfigurationScenarioCatalog.inMemoryConfiguration.id:
            let defaultConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)
            let namedConfiguration = ModelConfiguration("Named", isStoredInMemoryOnly: true)
            observations = [
                "default.inMemory": .bool(defaultConfiguration.isStoredInMemoryOnly),
                "default.url": .string(defaultConfiguration.url.path),
                "named.inMemory": .bool(namedConfiguration.isStoredInMemoryOnly),
                "named.url": .string(namedConfiguration.url.path),
                "named.name": .string(namedConfiguration.name),
            ]
        case ModelConfigurationScenarioCatalog.namedConfiguration.id:
            let named = ModelConfiguration("Named")
            let defaulted = ModelConfiguration(nil)
            let slashName = ModelConfiguration("a/b")
            observations = [
                "named.url.fileName": .string(named.url.lastPathComponent),
                "named.url.parent": .string(named.url.deletingLastPathComponent().lastPathComponent),
                "nilName.defaults": .string(defaulted.name),
                "slashName.fileName": .string(slashName.url.lastPathComponent),
            ]
        case ModelConfigurationScenarioCatalog.explicitURLConfiguration.id:
            let url = URL(fileURLWithPath: "/tmp/a/b.sqlite")
            let defaulted = ModelConfiguration(url: url)
            let named = ModelConfiguration("X", url: url)
            observations = [
                "url.kept": .bool(defaulted.url == url && named.url == url),
                "defaultName": .string(defaulted.name),
                "explicitName": .string(named.name),
            ]
        case ModelConfigurationScenarioCatalog.typeScopedSchema.id:
            let typed = ModelConfiguration(for: ConfigurationParityThing.self, isStoredInMemoryOnly: true)
            var mutable = ModelConfiguration("M")
            mutable.schema = Schema([ConfigurationParityThing.self])
            observations = [
                "typed.entities": .unorderedStrings(typed.schema?.entities.map(\.name) ?? []),
                "typed.name": .string(typed.name), "typed.inMemory": .bool(typed.isStoredInMemoryOnly),
                "mutable.schemaEntityCount": .integer(Int64(mutable.schema?.entities.count ?? 0)),
            ]
        case ModelConfigurationScenarioCatalog.cloudAndGroupSelections.id:
            let selected = ModelConfiguration(
                "P", isStoredInMemoryOnly: true, groupContainer: .identifier("group.x"),
                cloudKitDatabase: .private("iCloud.x"))
            observations = ["selected.cloudIdentifierMatches": .bool(selected.cloudKitContainerIdentifier == "iCloud.x")]
        case ModelConfigurationScenarioCatalog.equalityIncludesCoreFields.id:
            let schemaA = Schema([ConfigurationParityThing.self])
            let schemaB = Schema([ConfigurationParityOther.self])
            let url = URL(fileURLWithPath: "/tmp/q.store")
            observations = [
                "equality.defaults": .bool(ModelConfiguration() == ModelConfiguration()),
                "equality.memoryDefaults": .bool(
                    ModelConfiguration(isStoredInMemoryOnly: true) == ModelConfiguration(isStoredInMemoryOnly: true)),
                "equality.nameDifference": .bool(ModelConfiguration("A") == ModelConfiguration("B")),
                "equality.saveDifference": .bool(ModelConfiguration("A") == ModelConfiguration("A", allowsSave: false)),
                "equality.memoryNameDifference": .bool(
                    ModelConfiguration("A", isStoredInMemoryOnly: true)
                        == ModelConfiguration("B", isStoredInMemoryOnly: true)),
                "equality.sameURLDifferentName": .bool(
                    ModelConfiguration(url: url) == ModelConfiguration("Z", url: url)),
                "equality.differentSchemas": .bool(
                    ModelConfiguration(schema: schemaA) == ModelConfiguration(schema: schemaB)),
                "equality.schemaPresence": .bool(ModelConfiguration() == ModelConfiguration(schema: schemaA)),
            ]
        case ModelConfigurationScenarioCatalog.cloudAndGroupExcludedFromEquality.id:
            observations = [
                "equality.cloudSelection": .bool(
                    ModelConfiguration("A", cloudKitDatabase: .none)
                        == ModelConfiguration("A", cloudKitDatabase: .automatic)),
                "equality.groupSelection": .bool(
                    ModelConfiguration("A", groupContainer: .none)
                        == ModelConfiguration("A", groupContainer: .automatic)),
            ]
        case ModelConfigurationScenarioCatalog.hashIgnoresSchema.id:
            observations = [
                "hash.sameConfiguration": .bool(ModelConfiguration().hashValue == ModelConfiguration().hashValue),
                "hash.differentSchema": .bool(
                    ModelConfiguration(schema: Schema([ConfigurationParityThing.self])).hashValue
                        == ModelConfiguration(schema: Schema([ConfigurationParityOther.self])).hashValue),
            ]
        case ModelConfigurationScenarioCatalog.debugDescription.id:
            let defaults = ModelConfiguration("D", isStoredInMemoryOnly: true).debugDescription
            let custom = ModelConfiguration(
                "P", isStoredInMemoryOnly: true, groupContainer: .none, cloudKitDatabase: .private("iCloud.x"))
                .debugDescription
            observations = [
                "debug.defaultFieldsPresent": .bool(
                    defaults.contains("name:") && defaults.contains("url:") && defaults.contains("allowsSave:")
                        && defaults.contains("isStoredInMemoryOnly:") && defaults.contains("cloudKitDatabase:")
                        && defaults.contains("groupContainer:")),
                "debug.customFieldsPresent": .bool(
                    custom.contains("iCloud.x") && custom.contains("groupContainer:")),
            ]
        default:
            observations = [:]
        }
        return makeResult(id: specification.id, observations: observations)
    }

    private static func makeResult(id: ScenarioID, observations: [String: ObservedValue]) -> ScenarioResult {
        ScenarioResult(
            id: id,
            observations: observations.sorted { $0.key < $1.key }.enumerated().map { step, pair in
                ParityObservation(step: step, field: pair.key, value: pair.value)
            })
    }
}
