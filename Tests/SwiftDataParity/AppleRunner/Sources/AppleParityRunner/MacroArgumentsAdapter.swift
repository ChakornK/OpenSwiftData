import Foundation
import ParityContracts
import SwiftData

@Model
final class AppleParityMacroOwner {
    @Attribute(.unique, originalName: "legacyKey", hashModifier: "v2") var key: String
    @Attribute(.externalStorage) var blob: Data?
    @Attribute(.spotlight, .preserveValueOnDeletion) var note: String?
    @Attribute(.allowsCloudEncryption, hashModifier: "h") var secret: String = ""
    @Transient var cache: Int = 0
    @Relationship(
        deleteRule: .cascade, minimumModelCount: 0, maximumModelCount: 10, originalName: "kids",
        inverse: \AppleParityMacroChild.owner, hashModifier: "h")
    var children: [AppleParityMacroChild] = []
    init(key: String) { self.key = key }
}

@Model
final class AppleParityMacroChild {
    var owner: AppleParityMacroOwner?
    @Relationship(.unique) var partner: AppleParityMacroPartner?
    init() {}
}

@Model
final class AppleParityMacroPartner {
    var name: String = ""
    init() {}
}

enum AppleParityRenameV1 {
    @Model final class Item {
        var title: String
        init(title: String) { self.title = title }
    }
}

enum AppleParityRenameV2 {
    @Model final class Item {
        @Attribute(originalName: "title") var name: String
        init(name: String) { self.name = name }
    }
}

enum AppleParityRootNaming {
    @available(macOS 26, *)
    @Model final class Root {
        var name: String
        @Relationship(inverse: \Leaf.root) var leaves: [Leaf] = []
        init(name: String) { self.name = name }
    }

    @available(macOS 26, *)
    @Model final class Leaf {
        var root: Root?
        init() {}
    }
}

@MainActor
enum AppleMacroArgumentsAdapter {
    static func runAll() throws -> [ScenarioResult] {
        try MacroArgumentsScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    static func runAndValidate(_ specification: MacroArgumentsSpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard MacroArgumentsExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: result.id, observations: result.observations)
        }
        return result
    }

    private static func run(_ specification: MacroArgumentsSpecification) throws -> ScenarioResult {
        let values: [String: ObservedValue]
        switch specification.query {
        case .argumentsReachSchema:
            let schema = Schema([AppleParityMacroOwner.self, AppleParityMacroChild.self, AppleParityMacroPartner.self])
            let owner = try require(schema.entity(for: AppleParityMacroOwner.self), scenarioID: specification.id)
            let key = try require(owner.attributes.first { $0.name == "key" }, scenarioID: specification.id)
            let children = try require(owner.relationships.first { $0.name == "children" }, scenarioID: specification.id)
            let macroOwner = AppleParityMacroOwner(key: "k")
            let macroChild = AppleParityMacroChild()
            macroOwner.children.append(macroChild)
            values = [
                "key.originalName": .string(key.originalName),
                "key.unique": .bool(key.options.contains(.unique)),
                "cacheAbsent": .bool(!owner.attributes.contains { $0.name == "cache" }),
                "children.deleteRuleCascade": .bool(children.deleteRule == .cascade),
                "children.maximumCount": children.maximumModelCount.map { .integer(Int64($0)) } ?? .null,
                "children.originalName": .string(children.originalName),
                "children.inverseConnected": .bool(macroChild.owner === macroOwner),
            ]
        case .deleteRuleRawValues:
            let rules: [Schema.Relationship.DeleteRule] = [.noAction, .nullify, .cascade, .deny]
            values = [
                "deleteRuleRawValues": .array(rules.map { .string($0.rawValue) }),
                "cascadeRawValueRoundTrip": .bool(Schema.Relationship.DeleteRule(rawValue: "cascade") == .cascade),
            ]
        case .originalNameMigration:
            let url = FileManager.default.temporaryDirectory
                .appending(path: "apple-parity-rename-\(UUID().uuidString).store")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let old = try ModelContainer(
                    for: AppleParityRenameV1.Item.self, configurations: ModelConfiguration(url: url))
                old.mainContext.insert(AppleParityRenameV1.Item(title: "kept"))
                try old.mainContext.save()
            }
            let upgraded = try ModelContainer(
                for: AppleParityRenameV2.Item.self, configurations: ModelConfiguration(url: url))
            values = [
                "renamedValues": .array(try upgraded.mainContext.fetch(FetchDescriptor<AppleParityRenameV2.Item>())
                    .map { .string($0.name) }),
            ]
        case .rootModelNamePersistsAndRelates:
            if #available(macOS 26, *) {
                return try rootModelNameValues(for: specification)
            }
            throw NSError(domain: "AppleMacroArgumentsAdapter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Root model-name parity requires macOS 26 or newer.",
            ])
        }
        return ScenarioResult(
            id: specification.id,
            observations: values.keys.sorted().map { field in
                ParityObservation(step: 0, field: field, value: values[field]!)
            })
    }

    private static func require<Value>(_ value: Value?, scenarioID: ScenarioID) throws -> Value {
        guard let value else { throw ScenarioExpectationError(id: scenarioID, observations: []) }
        return value
    }

    @available(macOS 26, *)
    private static func rootModelNameValues(for specification: MacroArgumentsSpecification) throws -> ScenarioResult {
        let container = try ModelContainer(
            for: AppleParityRootNaming.Root.self, AppleParityRootNaming.Leaf.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let root = AppleParityRootNaming.Root(name: "r")
        let leaf = AppleParityRootNaming.Leaf()
        container.mainContext.insert(root)
        container.mainContext.insert(leaf)
        root.leaves.append(leaf)
        try container.mainContext.save()
        let schema = Schema([AppleParityRootNaming.Root.self, AppleParityRootNaming.Leaf.self])
        let values: [String: ObservedValue] = [
            "inverseMatches": .bool(leaf.root === root),
            "rootEntityName": .string(schema.entities.first { $0.name == "Root" }?.name ?? ""),
            "storedRootNames": .array(try ModelContext(container).fetch(FetchDescriptor<AppleParityRootNaming.Root>()).map { .string($0.name) }),
        ]
        return ScenarioResult(
            id: specification.id,
            observations: values.keys.sorted().map { ParityObservation(step: 0, field: $0, value: values[$0]!) })
    }
}
