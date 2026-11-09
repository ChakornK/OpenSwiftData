import Foundation
import OpenSwiftData
import ParityContracts

@Model
final class ParityMacroOwner {
    @Attribute(.unique, originalName: "legacyKey", hashModifier: "v2") var key: String
    @Attribute(.externalStorage) var blob: Data?
    @Attribute(.spotlight, .preserveValueOnDeletion) var note: String?
    @Attribute(.allowsCloudEncryption, hashModifier: "h") var secret: String = ""
    @Transient var cache: Int = 0
    @Relationship(
        deleteRule: .cascade, minimumModelCount: 0, maximumModelCount: 10, originalName: "kids",
        inverse: \ParityMacroChild.owner, hashModifier: "h")
    var children: [ParityMacroChild] = []
    init(key: String) { self.key = key }
}

@Model
final class ParityMacroChild {
    var owner: ParityMacroOwner?
    @Relationship(.unique) var partner: ParityMacroPartner?
    init() {}
}

@Model
final class ParityMacroPartner {
    var name: String = ""
    init() {}
}

enum ParityRenameV1 {
    @Model final class Item {
        var title: String
        init(title: String) { self.title = title }
    }
}

enum ParityRenameV2 {
    @Model final class Item {
        @Attribute(originalName: "title") var name: String
        init(name: String) { self.name = name }
    }
}

@Model
final class Root {
    var name: String
    @Relationship(inverse: \Leaf.root) var leaves: [Leaf] = []
    init(name: String) { self.name = name }
}

@Model
final class Leaf {
    var root: Root?
    init() {}
}

@MainActor
public enum OSDMacroArgumentsAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        try MacroArgumentsScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    public static func runAndValidate(_ specification: MacroArgumentsSpecification) throws -> ScenarioResult {
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
            let schema = Schema([ParityMacroOwner.self, ParityMacroChild.self, ParityMacroPartner.self])
            let owner = try require(schema.entity(for: ParityMacroOwner.self), scenarioID: specification.id)
            let key = try require(owner.attributes.first { $0.name == "key" }, scenarioID: specification.id)
            let children = try require(owner.relationships.first { $0.name == "children" }, scenarioID: specification.id)
            let macroOwner = ParityMacroOwner(key: "k")
            let macroChild = ParityMacroChild()
            macroOwner.children.append(macroChild)
            values = [
                "key.originalName": .string(key.originalName ?? ""),
                "key.unique": .bool(key.options.contains(.unique)),
                "cacheAbsent": .bool(!owner.attributes.contains { $0.name == "cache" }),
                "children.deleteRuleCascade": .bool(children.deleteRule == .cascade),
                "children.maximumCount": children.maximumModelCount.map { .integer(Int64($0)) } ?? .null,
                "children.originalName": .string(children.originalName ?? ""),
                "children.inverseConnected": .bool(macroChild.owner === macroOwner),
            ]
        case .deleteRuleRawValues:
            let rules: [SchemaDescriptor.Relationship.DeleteRule] = [.noAction, .nullify, .cascade, .deny]
            values = [
                "deleteRuleRawValues": .array(rules.map { .string($0.rawValue) }),
                "cascadeRawValueRoundTrip": .bool(SchemaDescriptor.Relationship.DeleteRule(rawValue: "cascade") == .cascade),
            ]
        case .originalNameMigration:
            let url = FileManager.default.temporaryDirectory
                .appending(path: "osd-parity-rename-\(UUID().uuidString).store")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let old = try ModelContainer(
                    for: ParityRenameV1.Item.self, configurations: ModelConfiguration(url: url))
                old.mainContext.insert(ParityRenameV1.Item(title: "kept"))
                try old.mainContext.save()
            }
            let upgraded = try ModelContainer(
                for: ParityRenameV2.Item.self, configurations: ModelConfiguration(url: url))
            values = [
                "renamedValues": .array(try upgraded.mainContext.fetch(FetchDescriptor<ParityRenameV2.Item>())
                    .map { .string($0.name) }),
            ]
        case .rootModelNamePersistsAndRelates:
            let container = try ModelContainer(
                for: Root.self, Leaf.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let root = Root(name: "r")
            let leaf = Leaf()
            container.mainContext.insert(root)
            container.mainContext.insert(leaf)
            root.leaves.append(leaf)
            try container.mainContext.save()
            values = [
                "inverseMatches": .bool(leaf.root === root),
                "rootEntityName": .string(Schema([Root.self, Leaf.self]).entities.first { $0.name == "Root" }?.name ?? ""),
                "storedRootNames": .array(try ModelContext(container).fetch(FetchDescriptor<Root>()).map { .string($0.name) }),
            ]
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
}
