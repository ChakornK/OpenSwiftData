import OpenSwiftData
import Testing

@Model
private final class AppleSchemaFacadeModel {
    @Attribute(.unique) var title: String
    init(title: String) { self.title = title }
}

@Suite struct AppleSchemaFacadeTests {
    @Test func modelTypeInitializationPreservesModelsAndProperties() throws {
        let schema = Schema([AppleSchemaFacadeModel.self])
        let entity = try #require(schema.entity(for: AppleSchemaFacadeModel.self))
        let title = try #require(entity.attributes.first { $0.name == "title" })

        #expect(schema.models.count == 1)
        #expect(entity.attributes.contains(title))
        #expect(ObjectIdentifier(title.valueType) == ObjectIdentifier(String.self))
        #expect(title.options.contains(.unique))
    }

    @Test func descriptorConversionPreservesStorageSchema() throws {
        let descriptor = try ModelContainer.inferredSchema(for: [AppleSchemaFacadeModel.self])
        let facade = Schema(descriptor: descriptor)

        #expect(facade.descriptor == descriptor)
        #expect(facade.version == descriptor.version)
        #expect(facade.entities.map(\.name) == descriptor.entities.map(\.name))
    }

    @MainActor @Test func containerAcceptsFacadeSchemaAndKeepsDescriptorExecution() throws {
        let schema = Schema([AppleSchemaFacadeModel.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        context.insert(AppleSchemaFacadeModel(title: "facade"))
        try context.save()

        #expect(try context.fetch(FetchDescriptor<AppleSchemaFacadeModel>()).map(\.title) == ["facade"])
    }
}
