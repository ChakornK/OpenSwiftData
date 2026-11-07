import Foundation
import OpenSwiftData
import Testing

@Model final class MacroArgumentsOwner {
    @Attribute(.unique, originalName: "legacyKey", hashModifier: "v2") var key: String
    @Attribute(.externalStorage) var blob: Data?
    @Attribute(.spotlight, .preserveValueOnDeletion) var note: String?
    @Attribute(.allowsCloudEncryption, hashModifier: "h") var secret: String = ""
    @Transient var cache: Int = 0
    @Relationship(
        deleteRule: .cascade, minimumModelCount: 0, maximumModelCount: 10, originalName: "kids",
        inverse: \MacroArgumentsChild.owner, hashModifier: "h")
    var children: [MacroArgumentsChild] = []
    init(key: String) { self.key = key }
}

@Model final class MacroArgumentsChild {
    var owner: MacroArgumentsOwner?
    @Relationship(.unique) var partner: MacroArgumentsPartner?
    init() {}
}

@Model final class MacroArgumentsPartner {
    var name: String = ""
    init() {}
}

enum RenameSchemaV1 {
    @Model final class RenamedItem {
        var title: String
        init(title: String) { self.title = title }
    }
}

enum RenameSchemaV2 {
    @Model final class RenamedItem {
        @Attribute(originalName: "title") var name: String
        init(name: String) { self.name = name }
    }
}

/// `@Attribute` and `@Relationship` accept SwiftData's arguments and record them in the schema.
@MainActor @Suite struct MacroArgumentsParityTests {
    @Test func `attribute and relationship arguments reach the schema`() throws {
        let schema = Schema([MacroArgumentsOwner.self, MacroArgumentsChild.self, MacroArgumentsPartner.self])
        let owner = try #require(schema.entity(for: MacroArgumentsOwner.self))
        let key = try #require(owner.attributes.first { $0.name == "key" })
        #expect(key.originalName == "legacyKey")
        #expect(key.options.contains(.unique))
        #expect(!owner.attributes.contains { $0.name == "cache" })
        let children = try #require(owner.relationships.first { $0.name == "children" })
        #expect(children.deleteRule == .cascade)
        #expect(children.maximumModelCount == 10)
        #expect(children.originalName == "kids")
        #expect(children.inverse == "owner")
    }

    @Test func `delete rules use SwiftData's raw values`() {
        let rules: [Schema.Relationship.DeleteRule] = [.noAction, .nullify, .cascade, .deny]
        #expect(rules.map(\.rawValue) == ["noAction", "nullify", "cascade", "deny"])
        #expect(Schema.Relationship.DeleteRule(rawValue: "cascade") == .cascade)
    }

    @Test func `an original name migrates a renamed attribute`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("osd-rename-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let container = try ModelContainer(
                for: RenameSchemaV1.RenamedItem.self, configurations: ModelConfiguration(url: url))
            container.mainContext.insert(RenameSchemaV1.RenamedItem(title: "kept"))
            try container.mainContext.save()
        }
        let container = try ModelContainer(
            for: RenameSchemaV2.RenamedItem.self, configurations: ModelConfiguration(url: url))
        let items = try container.mainContext.fetch(FetchDescriptor<RenameSchemaV2.RenamedItem>())
        #expect(items.map(\.name) == ["kept"])
    }
}
