import Observation
import OSDCore

@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_))
public macro _PersistedProperty(
    slot: Int, relationship: Bool = false, inherited: Bool = false, modelName: String = ""
) =
    #externalMacro(module: "OpenSwiftDataMacros", type: "PersistedPropertyMacro")

/// Marks a class as a persistent model.
/// Set `protocolConformancesOnly` to true when inherited types are protocols; leave it false for model subclasses.
/// The macro cannot distinguish protocols from a model superclass from syntax alone.
/// The argument must be the `true` or `false` Boolean literal.
@attached(
    member,
    names: arbitrary, named(createBackingData), named(persistentBackingData), named(schemaMetadata),
    named(_$backingData), named(_$observationRegistrar), named(_SwiftDataNoType),
    named(persistenceAdapters), named(flattenedPropertyAdapters), named(relationshipAdapterCandidates),
    named(inferredRelationshipAdapterCandidates), named(schemaIndexes)
)
@attached(memberAttribute)
@attached(extension, conformances: PersistentModel, RelationshipModel, Observation.Observable, Sendable)
public macro Model(protocolConformancesOnly: Bool = false) =
    #externalMacro(module: "OpenSwiftDataMacros", type: "ModelMacro")

/// Customizes how a property is persisted.
///
/// `originalName` names the property in the previous schema version for migration. `hashModifier` forces a new
/// schema version hash when the property's stored representation changes without a visible declaration change.
@attached(peer)
public macro Attribute(
    _ options: SchemaDescriptor.Attribute.Option..., originalName: String? = nil, hashModifier: String? = nil
) = #externalMacro(module: "OpenSwiftDataMacros", type: "AttributeMacro")

/// Customizes how a relationship is persisted.
@attached(peer)
public macro Relationship(
    _ options: SchemaDescriptor.Relationship.Option...,
    deleteRule: SchemaDescriptor.Relationship.DeleteRule = .nullify,
    minimumModelCount: Int? = 0,
    maximumModelCount: Int? = 0,
    originalName: String? = nil,
    inverse: AnyKeyPath? = nil,
    hashModifier: String? = nil
) = #externalMacro(module: "OpenSwiftDataMacros", type: "RelationshipMacro")
@attached(peer)
public macro Transient() = #externalMacro(module: "OpenSwiftDataMacros", type: "TransientMacro")
/// Declares uniqueness constraints; each array names properties whose combined values must be unique.
@freestanding(declaration)
public macro Unique<T: PersistentModel>(_ constraints: [PartialKeyPath<T>]...) =
    #externalMacro(module: "OpenSwiftDataMacros", type: "UniqueMacro")
/// Declares indexes; each array names the properties of one index, in column order.
@freestanding(declaration)
public macro Index<T: PersistentModel>(_ indices: [PartialKeyPath<T>]...) =
    #externalMacro(module: "OpenSwiftDataMacros", type: "IndexMacro")
@attached(member, names: arbitrary)
@attached(extension, conformances: ModelActor)
public macro ModelActor() = #externalMacro(module: "OpenSwiftDataMacros", type: "ModelActorMacro")
