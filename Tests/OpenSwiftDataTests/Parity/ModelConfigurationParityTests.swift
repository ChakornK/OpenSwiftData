import Foundation
import OpenSwiftData
import Testing

@Model final class ConfigurationParityThing {
    var name: String
    init(name: String) { self.name = name }
}

@Model final class ConfigurationParityOther {
    var value: Int
    init(value: Int) { self.value = value }
}

/// `ModelConfiguration` values and validation, matching Apple's SwiftData.
@Suite struct ModelConfigurationParityTests {
    private var applicationSupport: URL {
        get throws {
            try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        }
    }

    @Test func `the default configuration stores default.store in Application Support`() throws {
        let configuration = ModelConfiguration()
        #expect(configuration.name == "default")
        #expect(configuration.url == (try applicationSupport).appendingPathComponent("default.store"))
        #expect(configuration.id == configuration.url)
        #expect(!configuration.isStoredInMemoryOnly)
        #expect(configuration.allowsSave)
        #expect(configuration.schema == nil)
        #expect(configuration.groupAppContainerIdentifier == nil)
        #expect(configuration.cloudKitContainerIdentifier == nil)
    }

    @Test func `in-memory configurations use dev null`() {
        #expect(ModelConfiguration(isStoredInMemoryOnly: true).url.path == "/dev/null")
        #expect(ModelConfiguration("Named", isStoredInMemoryOnly: true).url.path == "/dev/null")
        #expect(ModelConfiguration("Named", isStoredInMemoryOnly: true).name == "Named")
    }

    @Test func `named configurations use the name as the file stem`() throws {
        #expect(ModelConfiguration("Named").url == (try applicationSupport).appendingPathComponent("Named.store"))
        #expect(ModelConfiguration(nil).name == "default")
        #expect(ModelConfiguration("a/b").url.lastPathComponent == "b.store")
    }

    @Test func `explicit URLs are kept and the name defaults`() {
        let url = URL(fileURLWithPath: "/tmp/a/b.sqlite")
        #expect(ModelConfiguration(url: url).url == url)
        #expect(ModelConfiguration(url: url).name == "default")
        #expect(ModelConfiguration("X", url: url).name == "X")
    }

    @Test func `type-scoped configurations carry a schema`() {
        let configuration = ModelConfiguration(for: ConfigurationParityThing.self, isStoredInMemoryOnly: true)
        #expect(configuration.schema?.entities.map(\.name) == ["ConfigurationParityThing"])
        #expect(configuration.name == "default")
        #expect(configuration.isStoredInMemoryOnly)

        var mutable = ModelConfiguration("M")
        mutable.schema = SchemaDescriptor([ConfigurationParityThing.self])
        #expect(mutable.schema?.entities.count == 1)
    }

    @Test func `cloud and group selections are reported`() {
        let configuration = ModelConfiguration(
            "P", isStoredInMemoryOnly: true, groupContainer: .identifier("group.x"),
            cloudKitDatabase: .private("iCloud.x"))
        #expect(configuration.cloudKitContainerIdentifier == "iCloud.x")
        #expect(configuration.groupContainer == .identifier("group.x"))
        #expect(configuration.cloudKitDatabase == .private("iCloud.x"))
        #expect(ModelConfiguration().groupContainer == .automatic)
        #expect(ModelConfiguration().cloudKitDatabase == .automatic)
    }

    @Test func `equality compares name, url, schema, save permission, and storage`() {
        #expect(ModelConfiguration() == ModelConfiguration())
        #expect(ModelConfiguration(isStoredInMemoryOnly: true) == ModelConfiguration(isStoredInMemoryOnly: true))
        #expect(ModelConfiguration("A") == ModelConfiguration("A"))
        #expect(ModelConfiguration("A") != ModelConfiguration("B"))
        #expect(ModelConfiguration("A") != ModelConfiguration("A", allowsSave: false))
        #expect(
            ModelConfiguration("A", isStoredInMemoryOnly: true) != ModelConfiguration("B", isStoredInMemoryOnly: true))
        let url = URL(fileURLWithPath: "/tmp/q.store")
        #expect(ModelConfiguration(url: url) != ModelConfiguration("Z", url: url))
        #expect(
            ModelConfiguration(schema: SchemaDescriptor([ConfigurationParityThing.self]))
                != ModelConfiguration(schema: SchemaDescriptor([ConfigurationParityOther.self])))
        #expect(ModelConfiguration() != ModelConfiguration(schema: SchemaDescriptor([ConfigurationParityThing.self])))
    }

    @Test func `cloud and group selections do not affect equality`() {
        #expect(
            ModelConfiguration("A", cloudKitDatabase: .none) == ModelConfiguration("A", cloudKitDatabase: .automatic))
        #expect(ModelConfiguration("A", groupContainer: .none) == ModelConfiguration("A", groupContainer: .automatic))
    }

    @Test func `hashing ignores the schema`() {
        #expect(ModelConfiguration().hashValue == ModelConfiguration().hashValue)
        #expect(
            ModelConfiguration(schema: SchemaDescriptor([ConfigurationParityThing.self])).hashValue
                == ModelConfiguration(schema: SchemaDescriptor([ConfigurationParityOther.self])).hashValue)
    }

    @Test func `debug description lists every setting`() {
        let expected = """
            ModelConfiguration
            name: D
            url: file:///dev/null
            allowsSave: true
            isStoredInMemoryOnly: true
            cloudKitDatabase: CloudKitDatabase(_automatic: true, _none: false, _privateDBName: nil)
            cloudKitContainerIdentifier: nil
            groupContainer: GroupContainer(_automatic: true, _none: false, _identifier: nil)
            groupAppContainerIdentifier: nil
            """
        #expect(ModelConfiguration("D", isStoredInMemoryOnly: true).debugDescription == expected)

        let custom = ModelConfiguration(
            "P", isStoredInMemoryOnly: true, groupContainer: .none, cloudKitDatabase: .private("iCloud.x"))
        #expect(
            custom.debugDescription.contains(
                "cloudKitDatabase: CloudKitDatabase(_automatic: false, _none: false, _privateDBName: Optional(\"iCloud.x\"))"
            ))
        #expect(custom.debugDescription.contains("cloudKitContainerIdentifier: Optional(\"iCloud.x\")"))
        #expect(custom.debugDescription.contains("GroupContainer(_automatic: false, _none: true, _identifier: nil)"))
    }

    @Test func `names up to 255 characters validate`() throws {
        try ModelConfiguration(String(repeating: "a", count: 255)).validate()
        try ModelConfiguration(String(repeating: "é", count: 255)).validate()
        #expect(throws: SwiftDataError.configurationFileNameTooLong) {
            try ModelConfiguration(String(repeating: "a", count: 256)).validate()
        }
    }

    @Test(arguments: ["/", ":", "\\", "*", "?", "<", ">", "|", "\""])
    func `reserved characters fail validation`(character: String) {
        #expect(throws: SwiftDataError.configurationFileNameContainsInvalidCharacters) {
            try ModelConfiguration("a\(character)b").validate()
        }
    }

    @Test(arguments: ["a\0b", "a\nb", "a b", "a~b", "a.b", "a..b", ".", "..", ""])
    func `other names validate`(name: String) throws {
        try ModelConfiguration(name).validate()
    }

    @Test func `explicit URL configurations still validate their names`() {
        #expect(throws: SwiftDataError.configurationFileNameContainsInvalidCharacters) {
            try ModelConfiguration("a/b", url: URL(fileURLWithPath: "/tmp/x.store")).validate()
        }
    }
}

@MainActor @Suite struct ModelConfigurationContainerParityTests {
    @Test func `containers reject configurations with invalid names`() {
        #expect(throws: SwiftDataError.configurationFileNameContainsInvalidCharacters) {
            try ModelContainer(
                for: ConfigurationParityThing.self,
                configurations: ModelConfiguration("a/b", isStoredInMemoryOnly: true))
        }
    }

    @Test func `in-memory stores with the same name are independent`() throws {
        let first = try ModelContainer(
            for: ConfigurationParityThing.self, configurations: ModelConfiguration("Same", isStoredInMemoryOnly: true))
        first.mainContext.insert(ConfigurationParityThing(name: "x"))
        try first.mainContext.save()
        let second = try ModelContainer(
            for: ConfigurationParityThing.self, configurations: ModelConfiguration("Same", isStoredInMemoryOnly: true))
        #expect(try second.mainContext.fetchCount(FetchDescriptor<ConfigurationParityThing>()) == 0)
    }

    @Test func `file stores create missing parent directories`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osd-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/store.sqlite")
        let container = try ModelContainer(
            for: ConfigurationParityThing.self, configurations: ModelConfiguration(url: url))
        container.mainContext.insert(ConfigurationParityThing(name: "x"))
        try container.mainContext.save()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
