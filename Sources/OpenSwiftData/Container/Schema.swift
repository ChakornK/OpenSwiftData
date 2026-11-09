import Foundation
import OSDCore

/// Describes the models and properties stored by a model container.
public final class Schema: @unchecked Sendable {
    public typealias Version = SchemaDescriptor.Version

    public struct PropertyMetadata {
        public let name: String
        public let keypath: AnyKeyPath?
        public let metadata: AnyHashable?
        public let isRelationship: Bool
        public let isExplicitRelationship: Bool
        public let isInferredRelationship: Bool
        public let isExplicitAttribute: Bool
        public let options: [String]
        public let defaultValue: String?
        public let flattenedComponents: [SchemaDescriptor.Attribute.Component]
        public let modelType: Any.Type?

        public init<Value>(
            name: String,
            keypath: KeyPath<some Any, Value>,
            defaultValue: Value? = nil,
            metadata: AnyHashable? = nil,
            isExplicitRelationship: Bool = false,
            isInferredRelationship: Bool = false,
            isExplicitAttribute: Bool = false,
            options: [String] = [],
            flattenedComponents: [SchemaDescriptor.Attribute.Component] = []
        ) {
            self.name = name
            self.keypath = keypath
            self.metadata = metadata
            self.isRelationship = isExplicitRelationship || isInferredRelationship
            self.isExplicitRelationship = isExplicitRelationship
            self.isInferredRelationship = isInferredRelationship
            self.isExplicitAttribute = isExplicitAttribute
            self.options = options
            self.defaultValue = defaultValue.map(String.init(describing:))
            self.flattenedComponents = flattenedComponents
            modelType = Value.self
        }

        fileprivate init(_ value: SchemaDescriptor.PropertyMetadata) {
            name = value.name
            keypath = value.keypath
            metadata = value.metadata
            isRelationship = value.isRelationship
            isExplicitRelationship = value.isExplicitRelationship
            isInferredRelationship = value.isInferredRelationship
            isExplicitAttribute = value.isExplicitAttribute
            options = value.options
            defaultValue = value.defaultValue
            flattenedComponents = value.flattenedComponents
            modelType = nil
        }

    }

    /// Describes a composite property and its recursively nested attributes.
    public struct CompositeAttribute: Hashable {
        public let name: String
        public let valueType: Any.Type
        public let attributes: [Attribute]

        public init(name: String, valueType: Any.Type, attributes: [Attribute]) {
            self.name = name
            self.valueType = valueType
            self.attributes = attributes
        }

        public static func == (lhs: CompositeAttribute, rhs: CompositeAttribute) -> Bool {
            lhs.name == rhs.name && ObjectIdentifier(lhs.valueType) == ObjectIdentifier(rhs.valueType)
                && lhs.attributes == rhs.attributes
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(ObjectIdentifier(valueType))
            hasher.combine(attributes)
        }
    }

    public struct Index: Hashable {
        public let properties: [String]
        public let isUnique: Bool

        public init(properties: [String], isUnique: Bool = false) {
            self.properties = properties
            self.isUnique = isUnique
        }

        fileprivate var descriptor: SchemaDescriptor.Index {
            SchemaDescriptor.Index(properties: properties, isUnique: isUnique)
        }

        fileprivate init(_ descriptor: SchemaDescriptor.Index) {
            properties = descriptor.properties
            isUnique = descriptor.isUnique
        }
    }

    /// Describes an entity in the schema.
    public final class Entity: Hashable {
        public let name: String
        public let attributes: Set<Attribute>
        public let relationships: Set<Relationship>
        public let indexes: Set<Index>
        public let superentityName: String?
        fileprivate let orderedAttributes: [Attribute]
        fileprivate let orderedRelationships: [Relationship]
        private let sourceDescriptorEntity: SchemaDescriptor.Entity?
        public var properties: [any SchemaProperty] { orderedAttributes + orderedRelationships }
        public var attributesByName: [String: Attribute] { Dictionary(uniqueKeysWithValues: attributes.map { ($0.name, $0) }) }
        public var relationshipsByName: [String: Relationship] { Dictionary(uniqueKeysWithValues: relationships.map { ($0.name, $0) }) }
        public var uniquenessConstraints: [[String]] { attributes.filter { $0.options.contains(.unique) }.map { [$0.name] } }
        public var indices: [[String]] { indexes.filter { !$0.isUnique }.map(\.properties) }

        public init(
            name: String,
            attributes: Set<Attribute> = [],
            relationships: Set<Relationship> = [],
            indexes: Set<Index> = [],
            superentity: Entity? = nil
        ) {
            self.name = name
            self.attributes = attributes
            self.relationships = relationships
            orderedAttributes = Array(attributes)
            orderedRelationships = Array(relationships)
            sourceDescriptorEntity = nil
            self.indexes = indexes
            superentityName = superentity?.name
        }

        fileprivate init(
            _ entity: SchemaDescriptor.Entity,
            runtimeTypes: [String: Any.Type] = [:],
            compositeTypes: [String: [String: Any.Type]] = [:]
        ) {
            name = entity.name
            let orderedAttributes = entity.attributes.map { attribute in
                let runtimeType = runtimeTypes[attribute.name]
                let composite: CompositeAttribute?
                if attribute.options.contains(.flattened), let runtimeType {
                    let children = attribute.components.map { component in
                        let childType = compositeTypes[attribute.name]?[component.name]
                            ?? Attribute.descriptorRuntimeType(component.type)
                        let nestedComposite: CompositeAttribute? = childType is any FlattenedCompositeMetadataProviding.Type
                            ? CompositeAttribute(
                                name: component.name,
                                valueType: childType,
                                attributes: ((childType as? any FlattenedCompositeMetadataProviding.Type)?
                                    .flattenedComponentTypesForSchema ?? []).map { Attribute($0.0, valueType: $0.1) })
                            : nil
                        return Attribute(component.name, valueType: childType, compositeAttribute: nestedComposite)
                    }
                    composite = CompositeAttribute(name: attribute.name, valueType: runtimeType, attributes: children)
                } else {
                    composite = nil
                }
                return Attribute(attribute, runtimeType: runtimeType, compositeAttribute: composite)
            }
            let orderedRelationships = entity.relationships.map(Relationship.init)
            attributes = Set(orderedAttributes)
            relationships = Set(orderedRelationships)
            self.orderedAttributes = orderedAttributes
            self.orderedRelationships = orderedRelationships
            sourceDescriptorEntity = entity
            indexes = Set(entity.indexes.map(Index.init))
            superentityName = entity.superentityName
        }

        public static func == (lhs: Entity, rhs: Entity) -> Bool {
            lhs.name == rhs.name && lhs.attributes == rhs.attributes && lhs.relationships == rhs.relationships
                && lhs.indexes == rhs.indexes && lhs.superentityName == rhs.superentityName
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(attributes)
            hasher.combine(relationships)
            hasher.combine(indexes)
            hasher.combine(superentityName)
        }

        fileprivate var descriptor: SchemaDescriptor.Entity {
            if let sourceDescriptorEntity { return sourceDescriptorEntity }
            return SchemaDescriptor.Entity(
                name: name,
                attributes: orderedAttributes.map(\.descriptor),
                relationships: orderedRelationships.map(\.descriptor),
                indexes: indexes.map(\.descriptor),
                superentityName: superentityName)
        }
    }

    /// Describes a persisted attribute.
    public final class Attribute: Hashable, SchemaProperty {
        public let compositeAttribute: CompositeAttribute?
        public typealias Component = SchemaDescriptor.Attribute.Component

        public enum Option: Hashable, Sendable {
            public struct Transformer: Hashable, Sendable {
                let identifier: ObjectIdentifier
                let name: String

                init(_ type: Any.Type) {
                    identifier = ObjectIdentifier(type)
                    name = String(reflecting: type)
                }
            }

            case unique
            case externalStorage
            case encrypt
            case preserveValueOnDeletion
            case spotlight
            case transformable(by: Transformer)

            public static func transformable(by type: Any.Type) -> Self {
                .transformable(by: Transformer(type))
            }

            case allowsCloudEncryption
            case ephemeral
            case codable
            case flattened
        }

        public let name: String
        public let valueType: Any.Type
        package var type: String { String(reflecting: valueType) }
        public let isOptional: Bool
        public let options: Set<Option>
        public let originalName: String?
        public let hashModifier: String?
        public let components: [SchemaDescriptor.Attribute.Component]
        public let defaultValue: String?
        public var isAttribute: Bool { true }
        public var isRelationship: Bool { false }
        public var isTransient: Bool { false }
        public var isUnique: Bool { options.contains(.unique) }
        public var isTransformable: Bool { options.contains { if case .transformable = $0 { true } else { false } } }
        public var composite: CompositeAttribute? { compositeAttribute }

        public init(
            _ name: String,
            valueType: Any.Type,
            options: Set<Option> = [],
            isOptional: Bool = false,
            originalName: String? = nil,
            hashModifier: String? = nil,
            components: [SchemaDescriptor.Attribute.Component] = [],
            compositeAttribute: CompositeAttribute? = nil,
            defaultValue: String? = nil
        ) {
            self.name = name
            self.valueType = valueType
            self.options = options
            self.isOptional = isOptional
            self.originalName = originalName
            self.hashModifier = hashModifier
            self.components = components
            self.compositeAttribute = compositeAttribute
            self.defaultValue = defaultValue
        }

        fileprivate convenience init(_ attribute: SchemaDescriptor.Attribute) {
            self.init(attribute, runtimeType: nil, compositeAttribute: nil)
        }

        fileprivate convenience init(
            _ attribute: SchemaDescriptor.Attribute,
            runtimeType: Any.Type?,
            compositeAttribute: CompositeAttribute? = nil
        ) {
            self.init(attribute.name, valueType: runtimeType ?? Self.resolveType(attribute.type),
                options: Set(attribute.options.compactMap(\.schemaOption)), isOptional: attribute.isOptional,
                originalName: attribute.originalName, hashModifier: attribute.hashModifier,
                components: attribute.components, compositeAttribute: compositeAttribute,
                defaultValue: attribute.defaultValue)
        }

        fileprivate var descriptor: SchemaDescriptor.Attribute {
            SchemaDescriptor.Attribute(
                name: name,
                type: Self.descriptorTypeName(valueType),
                isOptional: isOptional,
                defaultValue: defaultValue,
                options: Set(options.compactMap(\.descriptorOption)),
                originalName: originalName,
                components: components,
                hashModifier: hashModifier)
        }


        public static func == (lhs: Attribute, rhs: Attribute) -> Bool {
            lhs.name == rhs.name && ObjectIdentifier(lhs.valueType) == ObjectIdentifier(rhs.valueType)
                && lhs.isOptional == rhs.isOptional && lhs.options == rhs.options && lhs.originalName == rhs.originalName
                && lhs.hashModifier == rhs.hashModifier
        }

        public static func transformable(by type: Any.Type) -> Option { .transformable(by: type) }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(ObjectIdentifier(valueType))
            hasher.combine(isOptional)
            hasher.combine(options)
            hasher.combine(originalName)
            hasher.combine(hashModifier)
        }

        private static func resolveType(_ name: String) -> Any.Type {
            switch name {
            case "Bool": Bool.self
            case "Int", "Int64": Int64.self
            case "Int8": Int8.self
            case "Int16": Int16.self
            case "Int32": Int32.self
            case "UInt", "UInt64": UInt64.self
            case "UInt8": UInt8.self
            case "UInt16": UInt16.self
            case "UInt32": UInt32.self
            case "Float": Float.self
            case "Double": Double.self
            case "String", "Swift.String", "Foundation.String": String.self
            case "Array<Optional<String>>", "Swift.Array<Swift.Optional<Swift.String>>": [String?].self
            case "Array<Optional<Int>>": [Int?].self
            case "Array<Optional<Bool>>": [Bool?].self
            case "Array<String>": [String].self
            case "Array<Int>": [Int].self
            case "Array<Bool>": [Bool].self
            case "Data", "Foundation.Data": Data.self
            case "Date", "Foundation.Date": Date.self
            case "UUID", "Foundation.UUID": UUID.self
            case "Decimal", "Foundation.Decimal": Decimal.self
            default: Any.self
            }
        }

        fileprivate static func descriptorRuntimeType(_ name: String) -> Any.Type { resolveType(name) }

        fileprivate static func descriptorTypeName(_ type: Any.Type) -> String {
            let name = String(reflecting: type)
            return name
                .replacingOccurrences(of: "Swift.Array<", with: "Array<")
                .replacingOccurrences(of: "Swift.Optional<", with: "Optional<")
                .replacingOccurrences(of: "Swift.String", with: "String")
                .replacingOccurrences(of: "Swift.Int", with: "Int")
                .replacingOccurrences(of: "Swift.Bool", with: "Bool")
        }
    }

    /// Describes a persisted relationship.
    public final class Relationship: Hashable, SchemaProperty {
        public enum DeleteRule: Int, Sendable {
            case noAction = 0
            case nullify = 1
            case cascade = 2
            case deny = 3

        }

        public enum Option: Hashable, Sendable {
            case unique
        }

        public let name: String
        public let destination: String
        public let inverseName: String?
        public let isToMany: Bool
        public let isOptional: Bool
        public let deleteRule: DeleteRule
        public let minimumModelCount: Int?
        public let maximumModelCount: Int?
        public let options: Set<Option>
        public let originalName: String?
        public let hashModifier: String?
        private let inverseKeyPathStorage: String?
        public var inverseKeyPath: AnyKeyPath? { nil }
        public var inverse: String? { inverseName }
        public var isAttribute: Bool { false }
        public var isRelationship: Bool { true }
        public var isTransient: Bool { false }
        public var isUnique: Bool { options.contains(.unique) }
        public var isToOneRelationship: Bool { !isToMany }

        public init(
            _ name: String,
            destination: String,
            inverse: String? = nil,
            deleteRule: DeleteRule = .nullify,
            minimumModelCount: Int? = nil,
            maximumModelCount: Int? = nil,
            isToMany: Bool = false,
            isOptional: Bool = true,
            options: Set<Option> = [],
            originalName: String? = nil,
            hashModifier: String? = nil,
            inverseKeyPath: AnyKeyPath? = nil
        ) {
            self.name = name
            self.destination = destination
            inverseName = inverse
            self.deleteRule = deleteRule
            self.minimumModelCount = minimumModelCount
            self.maximumModelCount = maximumModelCount
            self.isToMany = isToMany
            self.isOptional = isOptional
            self.options = options
            self.originalName = originalName
            self.hashModifier = hashModifier
            inverseKeyPathStorage = inverseKeyPath.map(String.init(describing:))
        }

        fileprivate convenience init(_ relationship: SchemaDescriptor.Relationship) {
            self.init(
                relationship.name,
                destination: relationship.destination,
                inverse: relationship.inverse,
                deleteRule: Self.deleteRule(from: relationship.deleteRule),
                minimumModelCount: relationship.minimumModelCount,
                maximumModelCount: relationship.maximumModelCount,
                isToMany: relationship.isToMany,
                isOptional: relationship.isOptional,
                options: Set(relationship.options.compactMap(\.schemaOption)),
                originalName: relationship.originalName,
                hashModifier: relationship.hashModifier,
                inverseKeyPath: nil)
        }

        fileprivate var descriptor: SchemaDescriptor.Relationship {
            var result = SchemaDescriptor.Relationship(
                name: name,
                destination: destination,
                isToMany: isToMany,
                isOptional: isOptional,
                inverse: inverseName,
                deleteRule: Self.descriptorDeleteRule(from: deleteRule),
                minimumModelCount: minimumModelCount,
                maximumModelCount: maximumModelCount,
                originalName: originalName)
            result.options = options.map(\.descriptorOption)
            return result
        }

        public static func == (lhs: Relationship, rhs: Relationship) -> Bool {
            lhs.name == rhs.name && lhs.destination == rhs.destination && lhs.inverseName == rhs.inverseName
                && lhs.isToMany == rhs.isToMany && lhs.isOptional == rhs.isOptional && lhs.deleteRule == rhs.deleteRule
                && lhs.minimumModelCount == rhs.minimumModelCount && lhs.maximumModelCount == rhs.maximumModelCount
                && lhs.options == rhs.options && lhs.originalName == rhs.originalName
                && lhs.hashModifier == rhs.hashModifier
                && String(describing: lhs.inverseKeyPath) == String(describing: rhs.inverseKeyPath)
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(destination)
            hasher.combine(inverseName)
            hasher.combine(isToMany)
            hasher.combine(isOptional)
            hasher.combine(deleteRule)
            hasher.combine(minimumModelCount)
            hasher.combine(maximumModelCount)
            hasher.combine(options)
            hasher.combine(originalName)
            hasher.combine(hashModifier)
            hasher.combine(String(describing: inverseKeyPath))
        }

        private static func deleteRule(from rule: SchemaDescriptor.Relationship.DeleteRule) -> DeleteRule {
            switch rule {
            case .noAction: .noAction
            case .nullify: .nullify
            case .cascade: .cascade
            case .deny: .deny
            }
        }

    private static func descriptorDeleteRule(from rule: DeleteRule) -> SchemaDescriptor.Relationship.DeleteRule {
            switch rule {
            case .noAction: .noAction
            case .nullify: .nullify
            case .cascade: .cascade
            case .deny: .deny
            }
        }
    }

    public let entities: [Entity]
    public let version: Version
    package var declaredVersion: Version? { version }
    public let models: [any PersistentModel.Type]
    package let modelTypes: [any PersistentModel.Type]
    package let inferenceError: (any Error)?
    private let sourceDescriptor: SchemaDescriptor?
    private let preservesEntityIDs: Bool
    private let runtimeTypes: SchemaDescriptor.RuntimePropertyTypes

    public var propertyMetadata: [PropertyMetadata] {
        models.flatMap { $0.schemaMetadata().map(PropertyMetadata.init) }
    }


    public init(_ entities: Set<Entity>, version: Version = Version(1, 0, 0)) {
        self.entities = entities.sorted { $0.name < $1.name }
        self.version = version
        models = []
        modelTypes = []
        inferenceError = nil
        sourceDescriptor = nil
        preservesEntityIDs = false
        runtimeTypes = .init()
    }

    public convenience init(_ entities: Entity..., version: Version = Version(1, 0, 0)) {
        self.init(Set(entities), version: version)
    }

    public convenience init(_ types: [any PersistentModel.Type], version: Version? = nil) {
        do {
            let descriptor = try ModelContainer.inferredSchema(for: types, version: version)
            self.init(descriptor: descriptor)
        } catch {
            self.init(Set<Entity>(), version: version ?? Version(1, 0, 0), modelTypes: types, inferenceError: error)
        }
    }

    public convenience init(_ types: any PersistentModel.Type...) {
        self.init(types)
    }

    public convenience init() { self.init(Set<Entity>()) }

    public convenience init(versionedSchema: any VersionedSchema.Type) {
        self.init(versionedSchema.models, version: versionedSchema.versionIdentifier)
    }

    public convenience init(versionedSchema schema: SchemaDescriptor) {
        self.init(descriptor: schema)
    }

    public convenience init(descriptor: SchemaDescriptor) {
        let entities = Set(descriptor.entities.map { entity in
            Entity(
                entity,
                runtimeTypes: descriptor.runtimePropertyTypes.values[entity.name] ?? [:],
                compositeTypes: descriptor.runtimePropertyTypes.compositeValues[entity.name] ?? [:])
        })
        self.init(descriptor: descriptor, entities: entities)
    }

    private init(
        _ entities: Set<Entity>,
        version: Version,
        modelTypes: [any PersistentModel.Type],
        inferenceError: (any Error)?
    ) {
        self.entities = entities.sorted { $0.name < $1.name }
        self.version = version
        models = modelTypes
        self.modelTypes = modelTypes
        self.inferenceError = inferenceError
        sourceDescriptor = nil
        preservesEntityIDs = false
        runtimeTypes = .init()
    }

    private init(descriptor: SchemaDescriptor, entities: Set<Entity>) {
        self.entities = descriptor.entities.compactMap { descriptorEntity in entities.first { $0.name == descriptorEntity.name } }
        version = descriptor.version
        models = descriptor.modelTypes.types.compactMap { $0 as? any PersistentModel.Type }
        modelTypes = models
        inferenceError = descriptor.modelTypes.inferenceError
        sourceDescriptor = descriptor
        preservesEntityIDs = true
        runtimeTypes = descriptor.runtimePropertyTypes
    }

    package var descriptor: SchemaDescriptor {
        if let sourceDescriptor { return sourceDescriptor }
        var result = SchemaDescriptor(
            entities.map(\.descriptor),
            version: version)
        result.modelTypes = SchemaDescriptor.ModelTypes(types: modelTypes, inferenceError: inferenceError)
        return result
    }

    public func entity(for name: String) -> Entity? {
        entity(forName: name)
    }

    public func entity(forName name: String) -> Entity? {
        entities.first { $0.name == name }
    }

    public func entity(for type: Any.Type) -> Entity? {
        entity(forName: Self.entityName(for: type))
    }

    public func entity(for type: any PersistentModel.Type) -> Entity? {
        entity(forName: Self.entityName(for: type))
    }

    public func property(for keyPath: AnyKeyPath) -> (any SchemaProperty)? {
        for entity in entities {
            if let attribute = entity.attributes.first(where: { $0.name == String(describing: keyPath).split(separator: ".").last.map(String.init) }) {
                return attribute
            }
            if let relationship = entity.relationships.first(where: { $0.name == String(describing: keyPath).split(separator: ".").last.map(String.init) }) {
                return relationship
            }
        }
        return nil
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(descriptor).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> Schema {
        let descriptor = try JSONDecoder().decode(SchemaDescriptor.self, from: Data(contentsOf: url))
        return Schema(descriptor: descriptor)
    }

    func entity(forID identifier: Int) -> Entity? {
        descriptor.entity(forID: identifier).flatMap { entity(forName: $0.name) }
    }

    var entityIDsByName: [String: Int] {
        if preservesEntityIDs { return descriptor.entityIDsByName }
        return Dictionary(uniqueKeysWithValues: entities.enumerated().map { ($0.element.name, $0.offset + 1) })
    }

    public static func entityName<T: PersistentModel>(for type: T.Type) -> String {
        String(describing: type).split(separator: ".").last.map(String.init) ?? String(describing: type)
    }

    public static func entityName(for type: Any.Type) -> String {
        String(describing: type).split(separator: ".").last.map(String.init) ?? String(describing: type)
    }

    public static func entityName(for type: any PersistentModel.Type) -> String {
        String(describing: type).split(separator: ".").last.map(String.init) ?? String(describing: type)
    }

    public static func attributeName(for keyPath: AnyKeyPath) -> String? {
        String(describing: keyPath).split(separator: ".").last.map(String.init)
    }

    func subentities(of entity: Entity) -> [Entity] {
        entities.filter { $0.superentityName == entity.name }
    }

    func superentity(of entity: Entity) -> Entity? {
        entity.superentityName.flatMap(self.entity(forName:))
    }

    package func relationshipStorageMapping(
        modelEntityName: String, relationshipName: String
    ) -> SchemaDescriptor.RelationshipStorageMapping? {
        descriptor.relationshipStorageMapping(modelEntityName: modelEntityName, relationshipName: relationshipName)
    }

    package func isAncestorEntity(_ ancestorName: String, of candidateName: String) -> Bool {
        guard let candidate = entity(forName: candidateName) else { return false }
        var current: Entity? = candidate
        var visited = Set<String>()
        while let entity = current, visited.insert(entity.name).inserted {
            if entity.name == ancestorName { return true }
            current = entity.superentityName.flatMap(entity(forName:))
        }
        return false
    }

    package func relationshipDeclaration(named name: String, onOrBelow entityName: String) -> (entityName: String, relationship: SchemaDescriptor.Relationship)? {
        descriptor.relationshipDeclaration(named: name, onOrBelow: entityName)
    }

    package func relationship(named name: String, onOrBelow entityName: String) -> SchemaDescriptor.Relationship? {
        descriptor.relationship(named: name, onOrBelow: entityName)
    }

    package func validateRelationshipStorageMappings() throws {
        try descriptor.validateRelationshipStorageMappings()
    }
}

private extension Schema.Attribute.Option {
    var descriptorOption: SchemaDescriptor.Attribute.Option? {
        switch self {
        case .unique: .unique
        case .externalStorage: .externalStorage
        case .encrypt: .encrypt
        case .preserveValueOnDeletion: .preserveValueOnDeletion
        case .spotlight: .spotlight
        case .transformable(let transformer): .transformable(by: transformer.name)
        case .allowsCloudEncryption: .allowsCloudEncryption
        case .ephemeral: .ephemeral
        case .codable: .codable
        case .flattened: .flattened
        }
    }
}

private extension SchemaDescriptor.Attribute.Option {
    var schemaOption: Schema.Attribute.Option? {
        switch self {
        case .unique: .unique
        case .externalStorage: .externalStorage
        case .encrypt: .encrypt
        case .preserveValueOnDeletion: .preserveValueOnDeletion
        case .spotlight: .spotlight
        case .transformable(let typeName):
            .transformable(by: typeName == "String" ? String.self : Any.self)
        case .allowsCloudEncryption: .allowsCloudEncryption
        case .ephemeral: .ephemeral
        case .codable: .codable
        case .flattened: .flattened
        }
    }
}

private extension Schema.Relationship.Option {
    var descriptorOption: SchemaDescriptor.Relationship.Option { .unique }
}

private extension SchemaDescriptor.Relationship.Option {
    var schemaOption: Schema.Relationship.Option { .unique }
}
