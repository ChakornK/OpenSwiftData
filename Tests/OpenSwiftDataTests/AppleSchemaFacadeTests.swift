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

@Suite struct AppleCompositeAttributeTests {
    @Test func compositeAttributeIsAnAttributeWithProperties() {
        let composite = Schema.CompositeAttribute(
            name: "dimensions", valueType: String.self,
            defaultValue: "fallback")

        #expect(composite.isAttribute)
        #expect(!composite.isRelationship)
        #expect(composite.name == "dimensions")
        #expect(!composite.isOptional)
        #expect(composite.properties.isEmpty)

        let configured = Schema.CompositeAttribute(
            name: "nested", valueType: String.self)
        #expect(configured.isOptional)
        let attributed = Schema.Attribute(
            name: "title", originalName: nil, options: [.unique], valueType: String.self)
        #expect(attributed.isUnique)
    }

    @Test func inferredCompositeAttributeExposesProperties() throws {
        let descriptor = try ModelContainer.inferredSchema(for: [FlattenedCompositeFixture.self])
        let schema = Schema(descriptor: descriptor)
        let entity = try #require(schema.entity(for: FlattenedCompositeFixture.self))
        let composite = try #require(
            entity.attributes.first { $0.name == "dimensions" } as? Schema.CompositeAttribute)

        #expect(composite.isAttribute)
        #expect(Set(composite.properties.map(\.name)) == ["width", "label"])
        #expect(composite.properties.allSatisfy { !$0.isRelationship })
    }
}
