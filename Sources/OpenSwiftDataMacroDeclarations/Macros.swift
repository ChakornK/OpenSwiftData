@attached(peer)
public macro _PersistedProperty() =
    #externalMacro(
        module: "OpenSwiftDataMacros",
        type: "PersistedPropertyMacro"
    )

/// Marks a class as a persistent model.
@attached(member, names: arbitrary)
@attached(memberAttribute)
@attached(extension, conformances: Sendable)
public macro Model() = #externalMacro(module: "OpenSwiftDataMacros", type: "ModelMacro")

/// Describes persistence behavior for a model property.
public enum Attribute {
    /// Describes an attribute persistence option.
    public enum Option: Sendable, Hashable {
        /// Marks the attribute as unique.
        case unique
        /// Stores large values outside the database row.
        case externalStorage
        /// Requests encrypted storage when supported.
        case encrypt
        /// Preserves the value when the model is deleted.
        case preserveValueOnDeletion
        /// Enables Spotlight indexing.
        case spotlight
        /// Stores values using the named value transformer type.
        case transformable(by: String)
        /// Allows cloud encryption.
        case allowsCloudEncryption
        /// Stores values ephemerally.
        case ephemeral
    }
}

@attached(peer)
public macro Attribute(_ options: Attribute.Option...) =
    #externalMacro(module: "OpenSwiftDataMacros", type: "AttributeMacro")

/// Describes a model relationship.
public enum Relationship {
    /// Describes relationship delete behavior.
    public enum DeleteRule: Sendable, Hashable {
        /// Removes the relationship reference when its destination is deleted.
        case nullify
        /// Deletes related models with the source model.
        case cascade
        /// Rejects deletion while related models remain.
        case deny
        /// Leaves related models unchanged.
        case noAction
    }
}

@attached(peer)
public macro Relationship(
    deleteRule: Relationship.DeleteRule = .nullify,
    minimumModelCount: Int? = nil,
    maximumModelCount: Int? = nil,
    originalName: String? = nil,
    inverse: AnyKeyPath? = nil
) = #externalMacro(module: "OpenSwiftDataMacros", type: "RelationshipMacro")

/// Excludes a property from persistence.
@attached(peer)
public macro Transient() = #externalMacro(module: "OpenSwiftDataMacros", type: "TransientMacro")

/// Declares a uniqueness constraint for a model.
@freestanding(declaration, names: named(Unique))
public macro Unique<Model>(_ keyPaths: PartialKeyPath<Model>...) =
    #externalMacro(
        module: "OpenSwiftDataMacros",
        type: "UniqueMacro"
    )

/// Declares an index for a model.
@freestanding(declaration, names: named(Index))
public macro Index<Model>(_ keyPaths: PartialKeyPath<Model>...) =
    #externalMacro(
        module: "OpenSwiftDataMacros",
        type: "IndexMacro"
    )

/// Adds model context access to an actor.
@attached(member, names: arbitrary)
@attached(extension, conformances: Sendable)
public macro ModelActor() = #externalMacro(module: "OpenSwiftDataMacros", type: "ModelActorMacro")
