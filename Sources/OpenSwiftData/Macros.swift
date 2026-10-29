import Observation
import OSDCore

@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_))
public macro _PersistedProperty(relationship: Bool = false) =
    #externalMacro(module: "OpenSwiftDataMacros", type: "PersistedPropertyMacro")

/// Marks a class as a persistent model.
@attached(
    member,
    names: arbitrary, named(createBackingData), named(persistentBackingData), named(schemaMetadata),
    named(_$backingData), named(_$observationRegistrar), named(_SwiftDataNoType),
    named(persistenceAdapters), named(flattenedPropertyAdapters), named(relationshipAdapterCandidates),
    named(inferredRelationshipAdapterCandidates), named(schemaIndexes)
)
@attached(memberAttribute)
@attached(extension, conformances: PersistentModel, RelationshipModel, Observation.Observable, Sendable)
public macro Model() = #externalMacro(module: "OpenSwiftDataMacros", type: "ModelMacro")

/// Describes options for a persisted attribute.
public enum Attribute {
    /// Options that control how an attribute is persisted.
    public enum Option: Sendable, Hashable {
        case unique
        case externalStorage
        case encrypt
        case preserveValueOnDeletion
        case spotlight
        case transformable(by: String)
        case allowsCloudEncryption
        case ephemeral
        case codable
        case flattened
    }
}
@attached(peer)
public macro Attribute(_ options: Attribute.Option...) =
    #externalMacro(module: "OpenSwiftDataMacros", type: "AttributeMacro")

/// Describes options for a persisted relationship.
public enum Relationship {
    /// Behavior applied when deleting a related model.
    public enum DeleteRule: Sendable, Hashable { case nullify, cascade, deny, noAction }
}
@attached(peer)
public macro Relationship(
    deleteRule: Relationship.DeleteRule = .nullify,
    minimumModelCount: Int? = nil,
    maximumModelCount: Int? = nil,
    originalName: String? = nil,
    inverse: AnyKeyPath? = nil
) = #externalMacro(module: "OpenSwiftDataMacros", type: "RelationshipMacro")
@attached(peer)
public macro Transient() = #externalMacro(module: "OpenSwiftDataMacros", type: "TransientMacro")
@freestanding(declaration)
public macro Unique<Model>(_ keyPaths: PartialKeyPath<Model>...) =
    #externalMacro(module: "OpenSwiftDataMacros", type: "UniqueMacro")
@freestanding(declaration)
public macro Index<Model>(_ keyPaths: PartialKeyPath<Model>...) =
    #externalMacro(module: "OpenSwiftDataMacros", type: "IndexMacro")
@attached(member, names: arbitrary)
@attached(extension, conformances: ModelActor)
public macro ModelActor() = #externalMacro(module: "OpenSwiftDataMacros", type: "ModelActorMacro")
