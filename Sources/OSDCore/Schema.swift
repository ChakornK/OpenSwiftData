import Foundation

/// Describes schema version metadata without changing the runtime store.
public enum RuntimeSchemaVersionState: Sendable {
    /// The store does not yet contain a schema.
    case empty
    /// The store contains a recognized version.
    case version(Schema.Version)
    /// The store has schema data but no recognized version identifier.
    case unversioned
    /// A custom stage changed the schema but has not completed its destination callback.
    case pending(destinationIdentifier: String)
}

/// Describes the entities and version metadata in a persistent store.
public struct Schema: Sendable {
    /// An ordered index over entity attributes.
    public struct Index: Sendable, Hashable {
        /// The indexed properties in SQL column order.
        public let properties: [String]
        /// Whether the index enforces uniqueness.
        public let isUnique: Bool

        /// Creates index metadata.
        public init(properties: [String], isUnique: Bool = false) {
            self.properties = properties
            self.isUnique = isUnique
        }
    }

    /// Describes a persisted model entity.
    public struct Entity: Hashable, Sendable {
        /// The entity's stable model type name.
        public let name: String
        /// The entity's persisted attributes.
        public let attributes: [Attribute]
        /// The entity's persisted relationships.
        public let relationships: [Relationship]
        /// Entity-level indexes.
        public let indexes: [Index]

        /// Creates an entity and preserves property declaration order.
        public init(
            name: String, attributes: [Attribute] = [], relationships: [Relationship] = [], indexes: [Index] = []
        ) {
            self.name = name
            self.attributes = attributes
            self.relationships = relationships
            self.indexes = indexes
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
            /// Stores values using the named value transformer type.
            case transformable(by: String)
            /// Allows cloud encryption.
            case allowsCloudEncryption
            /// Stores values ephemerally.
            case ephemeral
            /// Stores a non-scalar Codable value as a JSON blob.
            case codable
            /// Stores a required Codable composite using declared scalar columns.
            case flattened
        }

        /// A scalar leaf persisted as a separate SQL column.
        public struct Component: Codable, Sendable, Hashable {
            /// The leaf name inside the composite value.
            public let name: String
            /// The physical column name that stores the leaf.
            public let columnName: String
            /// The Swift scalar type name for the leaf.
            public let type: String

            /// Creates flattened component metadata.
            public init(name: String, columnName: String, type: String) {
                self.name = name
                self.columnName = columnName
                self.type = type
            }
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
        /// Flattened scalar components, when `.flattened` is enabled.
        public let components: [Component]

        /// Creates metadata describing attribute options without property details.
        public init(_ options: Option...) {
            self.name = ""
            self.type = ""
            self.isOptional = false
            self.defaultValue = nil
            self.options = Set(options)
            self.originalName = nil
            components = []
        }

        /// Creates attribute metadata.
        public init(
            name: String,
            type: String,
            isOptional: Bool = false,
            defaultValue: String? = nil,
            options: Set<Option> = [],
            originalName: String? = nil,
            components: [Component] = []
        ) {
            self.name = name
            self.type = type
            self.isOptional = isOptional
            self.defaultValue = defaultValue
            self.options = options
            self.originalName = originalName
            self.components = components.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        }
    }

    /// Describes a persisted model relationship.
    public struct Relationship: Hashable, Sendable {
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

        /// Creates metadata describing relationship options without property details.
        public init(
            deleteRule: DeleteRule = .nullify,
            minimumModelCount: Int? = nil,
            maximumModelCount: Int? = nil,
            inverse: AnyKeyPath? = nil,
            inverseName: String? = nil,
            originalName: String? = nil
        ) {
            self.name = ""
            self.destination = ""
            self.isToMany = false
            self.inverse = inverseName ?? inverse.flatMap(Self.inversePropertyName)
            self.deleteRule = deleteRule
            self.minimumModelCount = minimumModelCount
            self.maximumModelCount = maximumModelCount
            self.originalName = originalName
        }

        private static func inversePropertyName(_ keyPath: AnyKeyPath) -> String? {
            let description = String(describing: keyPath)
            guard description.hasPrefix("\\"), let propertyStart = description.lastIndex(of: ".") else {
                return nil
            }
            let name = String(description[description.index(after: propertyStart)...])
            guard !name.isEmpty, !name.contains(" "), !name.contains("("), !name.contains(")") else {
                return nil
            }
            return name.first == "`" && name.last == "`" ? String(name.dropFirst().dropLast()) : name
        }

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
    public struct Version: Sendable, Hashable, Codable {
        /// The version's components.
        public let version: [Int]
        /// A stable identifier for the version.
        public let identifier: String

        /// Creates version metadata.
        public init(version: [Int], identifier: String) {
            self.version = version
            self.identifier = identifier
        }

        package func encoded() throws -> [UInt8] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return Array(try encoder.encode(self))
        }

        package static func decode(_ identifier: String) throws -> Self {
            guard let data = identifier.data(using: .utf8) else {
                throw SwiftDataError.migrationUnsupported("Invalid stored schema version.")
            }
            do {
                return try JSONDecoder().decode(Self.self, from: data)
            } catch {
                throw SwiftDataError.migrationUnsupported("Invalid stored schema version.")
            }
        }
    }

    /// Describes metadata for one persisted model property.
    public struct PropertyMetadata: Hashable {
        /// The property name.
        public let name: String
        /// The typed key path to the property, when available.
        public let keypath: AnyKeyPath?
        /// Schema-level attribute or relationship metadata.
        public let metadata: AnyHashable?
        /// Whether the property is a relationship.
        public let isRelationship: Bool
        /// Whether the relationship annotation was explicitly declared.
        public let isExplicitRelationship: Bool
        /// A textual default value, if provided.
        public let defaultValue: String?
        /// Property-specific options.
        public let options: [String]
        /// Flattened components declared by the property value type.
        public let flattenedComponents: [Schema.Attribute.Component]
        package let runtimeDefaultValue: Any?

        /// Compares schema-facing metadata, excluding the runtime default value.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name && lhs.keypath == rhs.keypath && lhs.metadata == rhs.metadata
                && lhs.isRelationship == rhs.isRelationship
                && lhs.isExplicitRelationship == rhs.isExplicitRelationship
                && lhs.defaultValue == rhs.defaultValue
                && lhs.options == rhs.options
                && lhs.flattenedComponents == rhs.flattenedComponents
        }

        /// Hashes schema-facing metadata, excluding the runtime default value.
        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(keypath)
            hasher.combine(metadata)
            hasher.combine(isRelationship)
            hasher.combine(isExplicitRelationship)
            hasher.combine(defaultValue)
            hasher.combine(options)
            hasher.combine(flattenedComponents)
        }

        /// Creates property metadata using the model macro contract.
        public init<Value>(
            name: String,
            keypath: KeyPath<some Any, Value>,
            defaultValue: Value? = nil,
            metadata: AnyHashable? = nil,
            isExplicitRelationship: Bool = false,
            options: [String] = [],
            flattenedComponents: [Schema.Attribute.Component] = []
        ) {
            self.name = name
            self.keypath = keypath
            self.metadata = metadata
            self.isRelationship = metadata?.base is Schema.Relationship || isExplicitRelationship
            self.isExplicitRelationship = isExplicitRelationship
            self.defaultValue = defaultValue.map { String(describing: $0) }
            self.options = options
            self.flattenedComponents = flattenedComponents
            if let defaultValue {
                runtimeDefaultValue = defaultValue
            } else {
                runtimeDefaultValue = nil
            }
        }

        /// Creates property metadata.
        public init(name: String, isRelationship: Bool = false, defaultValue: String? = nil, options: [String] = []) {
            self.name = name
            self.keypath = nil
            self.metadata = nil
            self.isRelationship = isRelationship
            self.isExplicitRelationship = isRelationship
            self.defaultValue = defaultValue
            self.options = options
            flattenedComponents = []
            self.runtimeDefaultValue = nil
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
