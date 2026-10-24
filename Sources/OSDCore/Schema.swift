/// Describes the entities and version metadata in a persistent store.
public struct Schema: Sendable {
    /// Describes a persisted model entity.
    public struct Entity: Sendable, Hashable {
        /// The entity's stable model type name.
        public let name: String
        /// The entity's persisted attributes.
        public let attributes: [Attribute]
        /// The entity's persisted relationships.
        public let relationships: [Relationship]

        /// Creates an entity and preserves property declaration order.
        public init(name: String, attributes: [Attribute] = [], relationships: [Relationship] = []) {
            self.name = name
            self.attributes = attributes
            self.relationships = relationships
        }
    }

    /// Describes a persisted scalar property.
    public struct Attribute: Sendable, Hashable {
        /// Describes an attribute option.
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
            /// Allows cloud encryption.
            case allowsCloudEncryption
            /// Stores values ephemerally.
            case ephemeral
        }

        /// The property name.
        public let name: String
        /// The Swift type name of the property.
        public let type: String
        /// Whether the property accepts nil.
        public let isOptional: Bool
        /// The source representation of its default value, if any.
        public let defaultValue: String?
        /// Options applied to this attribute.
        public let options: Set<Option>
        /// The original property name used for renaming.
        public let originalName: String?

        /// Creates attribute metadata.
        public init(
            name: String,
            type: String,
            isOptional: Bool = false,
            defaultValue: String? = nil,
            options: Set<Option> = [],
            originalName: String? = nil
        ) {
            self.name = name
            self.type = type
            self.isOptional = isOptional
            self.defaultValue = defaultValue
            self.options = options
            self.originalName = originalName
        }
    }

    /// Describes a persisted model relationship.
    public struct Relationship: Sendable, Hashable {
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

        /// The relationship property name.
        public let name: String
        /// The destination entity name.
        public let destination: String
        /// Whether the relationship contains multiple destinations.
        public let isToMany: Bool
        /// The inverse relationship property name, if known.
        public let inverse: String?
        /// The relationship's delete behavior.
        public let deleteRule: DeleteRule
        /// The minimum allowed relationship count.
        public let minimumModelCount: Int?
        /// The maximum allowed relationship count.
        public let maximumModelCount: Int?
        /// The original relationship name used for renaming.
        public let originalName: String?

        /// Creates relationship metadata.
        public init(
            name: String,
            destination: String,
            isToMany: Bool = false,
            inverse: String? = nil,
            deleteRule: DeleteRule = .nullify,
            minimumModelCount: Int? = nil,
            maximumModelCount: Int? = nil,
            originalName: String? = nil
        ) {
            self.name = name
            self.destination = destination
            self.isToMany = isToMany
            self.inverse = inverse
            self.deleteRule = deleteRule
            self.minimumModelCount = minimumModelCount
            self.maximumModelCount = maximumModelCount
            self.originalName = originalName
        }
    }

    /// Identifies a schema version for migration planning.
    public struct Version: Sendable, Hashable {
        /// The version's components.
        public let version: [Int]
        /// A stable identifier for the version.
        public let identifier: String

        /// Creates version metadata.
        public init(version: [Int], identifier: String) {
            self.version = version
            self.identifier = identifier
        }
    }

    /// Describes metadata for one persisted model property.
    public struct PropertyMetadata: Sendable, Hashable {
        /// The property name.
        public let name: String
        /// Whether the property is a relationship.
        public let isRelationship: Bool
        /// A textual default value, if provided.
        public let defaultValue: String?
        /// Property-specific options.
        public let options: [String]

        /// Creates property metadata.
        public init(name: String, isRelationship: Bool = false, defaultValue: String? = nil, options: [String] = []) {
            self.name = name
            self.isRelationship = isRelationship
            self.defaultValue = defaultValue
            self.options = options
        }
    }

    /// The schema's entities in deterministic name order.
    public let entities: [Entity]
    /// The optional schema version.
    public let version: Version?

    /// Creates a schema with entities sorted by name.
    public init(_ entities: [Entity], version: Version? = nil) {
        self.entities = entities.sorted { $0.name < $1.name }
        self.version = version
    }

    /// Finds an entity by its stable name.
    public func entity(forName name: String) -> Entity? {
        entities.first { $0.name == name }
    }
}
