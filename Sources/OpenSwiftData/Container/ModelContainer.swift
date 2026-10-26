import Foundation

/// Owns a schema and its associated model contexts.
public final class ModelContainer: Sendable {
    /// The schema managed by this container.
    public let schema: Schema
    /// The main context associated with this container.
    @MainActor
    public lazy var mainContext = ModelContext(container: self, autosaveEnabled: true)
    /// The configurations used by the container.
    public let configurations: [ModelConfiguration]
    package let store: (any RuntimeStore)?
    private let relationshipAdapterTable: [ObjectIdentifier: [any AnyRelationshipAdapterBox]]

    /// Creates a container for the schema inferred from model types.
    public convenience init(for types: any PersistentModel.Type..., configurations: ModelConfiguration...) throws {
        try self.init(for: types, configurations: configurations)
    }

    /// Creates a container for the schema inferred from model types and configurations.
    public init(for types: [any PersistentModel.Type], configurations: [ModelConfiguration] = []) throws {
        let entityNames = types.map { Self.unqualifiedTypeName(String(describing: $0)) }
        var uniqueEntityNames = Set<String>()
        for entityName in entityNames where !uniqueEntityNames.insert(entityName).inserted {
            throw SwiftDataError.duplicateEntityName(
                "Multiple model types resolve to the entity name '\(entityName)'; provide distinct model names."
            )
        }
        let modelNames = Set(entityNames)
        var propertiesByEntity: [String: [(Schema.PropertyMetadata, AnyKeyPath)]] = [:]
        for (modelType, entityName) in zip(types, entityNames) {
            propertiesByEntity[entityName] = modelType.schemaMetadata().compactMap { metadata in
                metadata.keypath.map { (metadata, $0) }
            }
        }
        let entities = try types.map { modelType in
            let properties = propertiesByEntity[Self.unqualifiedTypeName(String(describing: modelType))] ?? []
            let schemaProperties = try properties.map {
                metadata, keypath -> (Schema.PropertyMetadata, String, Bool) in
                let rawType = String(reflecting: type(of: keypath).valueType)
                let (normalizedType, isOptional) = Self.normalizedPropertyType(rawType)
                let parsedType = Self.parseType(normalizedType)
                let elementTypeName = parsedType.collectionElement.map(Self.unqualifiedTypeName)
                guard !parsedType.collectionElementIsOptional || elementTypeName.map(modelNames.contains) != true else {
                    throw SwiftDataError.unsupportedRelationshipElement(
                        "Property '\(Self.unqualifiedTypeName(String(describing: modelType))).\(metadata.name)' "
                            + "uses a relationship collection with optional model elements."
                    )
                }
                return (metadata, normalizedType, isOptional)
            }
            let attributes = schemaProperties.compactMap { metadata, propertyType, isOptional -> Schema.Attribute? in
                let typedRelationship = metadata.metadata?.base as? Schema.Relationship
                let isModelType = modelNames.contains(Self.unqualifiedTypeName(propertyType))
                guard !metadata.isRelationship, typedRelationship == nil, !isModelType else { return nil }
                let typedAttribute = metadata.metadata?.base as? Schema.Attribute
                let options = typedAttribute?.options ?? Set(metadata.options.compactMap(Self.attributeOption))
                return Schema.Attribute(
                    name: metadata.name,
                    type: propertyType,
                    isOptional: isOptional,
                    defaultValue: metadata.defaultValue,
                    options: options,
                    originalName: typedAttribute?.originalName
                )
            }
            let relationships = try schemaProperties.compactMap {
                metadata, propertyType, isOptional -> Schema.Relationship? in
                let parsedType = Self.parseType(propertyType)
                let isToMany = parsedType.collectionElement != nil
                let destination = parsedType.collectionElement ?? parsedType.name
                let typedRelationship = metadata.metadata?.base as? Schema.Relationship
                let destinationName = Self.unqualifiedTypeName(destination)
                let isExplicitRelationship = metadata.isRelationship || typedRelationship != nil
                guard isExplicitRelationship || modelNames.contains(destinationName) else {
                    return nil
                }
                if isExplicitRelationship {
                    guard modelNames.contains(destinationName) else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Relationship '\(Self.unqualifiedTypeName(String(describing: modelType))).\(metadata.name)' "
                                + "targets missing model '\(destinationName)'."
                        )
                    }
                }
                let destinationRelationships =
                    propertiesByEntity[destinationName]?.compactMap {
                        candidate -> (Schema.PropertyMetadata, Schema.Relationship)? in
                        guard let destinationRelationship = candidate.0.metadata?.base as? Schema.Relationship else {
                            return nil
                        }
                        return (candidate.0, destinationRelationship)
                    } ?? []
                let explicitInverseName = typedRelationship?.inverse
                let hasExplicitInverse = explicitInverseName != nil
                let explicitInverse: String?
                if let explicitInverseName {
                    guard modelNames.contains(destinationName) else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Relationship '\(Self.unqualifiedTypeName(String(describing: modelType))).\(metadata.name)' "
                                + "declares inverse '\(explicitInverseName)' but destination model '\(destinationName)' is missing."
                        )
                    }
                    guard
                        let inverseMetadata = propertiesByEntity[destinationName]?.first(where: {
                            $0.0.name == explicitInverseName
                        })
                    else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Relationship '\(Self.unqualifiedTypeName(String(describing: modelType))).\(metadata.name)' "
                                + "declares inverse '\(destinationName).\(explicitInverseName)', but that property does not exist."
                        )
                    }
                    guard inverseMetadata.0.isRelationship
                    else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Relationship inverse '\(destinationName).\(explicitInverseName)' must be a relationship property."
                        )
                    }
                    let inverseType = String(reflecting: type(of: inverseMetadata.1).valueType)
                    let (inversePropertyType, _) = Self.normalizedPropertyType(inverseType)
                    let parsedInverseType = Self.parseType(inversePropertyType)
                    let inverseDestination = Self.unqualifiedTypeName(
                        parsedInverseType.collectionElement ?? parsedInverseType.name
                    )
                    guard
                        inverseDestination
                            == Self.unqualifiedTypeName(
                                String(describing: modelType)
                            )
                    else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Relationship inverse '\(destinationName).\(explicitInverseName)' does not point back to "
                                + "'\(Self.unqualifiedTypeName(String(describing: modelType)))'."
                        )
                    }
                    explicitInverse = explicitInverseName
                } else {
                    explicitInverse = nil
                }
                if let explicitInverseName,
                    let reciprocalInverse = destinationRelationships.first(where: {
                        $0.0.name == explicitInverseName
                    })?.1.inverse,
                    reciprocalInverse != metadata.name
                {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Relationship inverse '\(destinationName).\(explicitInverseName)' declares inverse "
                            + "'\(reciprocalInverse)' instead of '\(Self.unqualifiedTypeName(String(describing: modelType))).\(metadata.name)'."
                    )
                }
                let explicitReciprocals = destinationRelationships.filter { $0.1.inverse == metadata.name }
                let inferredInverse: String?
                if !hasExplicitInverse, explicitReciprocals.count == 1 {
                    inferredInverse = explicitReciprocals[0].0.name
                } else if !hasExplicitInverse, explicitReciprocals.isEmpty,
                    destinationRelationships.count == 1, typedRelationship == nil
                {
                    inferredInverse = destinationRelationships[0].0.name
                } else {
                    inferredInverse = nil
                }
                let inverse = hasExplicitInverse ? explicitInverse : inferredInverse
                return Schema.Relationship(
                    name: metadata.name,
                    destination: destinationName,
                    isToMany: isToMany,
                    inverse: inverse,
                    deleteRule: typedRelationship?.deleteRule ?? .nullify,
                    minimumModelCount: typedRelationship?.minimumModelCount,
                    maximumModelCount: typedRelationship?.maximumModelCount,
                    originalName: typedRelationship?.originalName
                )
            }
            return Schema.Entity(
                name: Self.unqualifiedTypeName(String(describing: modelType)),
                attributes: attributes,
                relationships: relationships
            )
        }
        let explicitInverseDeclarations = Set(
            types.flatMap { modelType in
                let entityName = Self.unqualifiedTypeName(String(describing: modelType))
                return modelType.schemaMetadata().compactMap { metadata -> String? in
                    guard let relationship = metadata.metadata?.base as? Schema.Relationship,
                        relationship.inverse != nil
                    else { return nil }
                    return "\(entityName).\(metadata.name)"
                }
            })
        let inferredEntities = entities.map { entity in
            Schema.Entity(
                name: entity.name,
                attributes: entity.attributes,
                relationships: entity.relationships.map { relationship in
                    guard relationship.inverse == nil,
                        !explicitInverseDeclarations.contains("\(entity.name).\(relationship.name)")
                    else { return relationship }
                    let explicitReciprocalCount =
                        propertiesByEntity[relationship.destination]?.filter { candidate, _ in
                            (candidate.metadata?.base as? Schema.Relationship)?.inverse == relationship.name
                        }.count ?? 0
                    guard explicitReciprocalCount <= 1 else { return relationship }
                    let destinationRelationships =
                        propertiesByEntity[relationship.destination]?.filter {
                            $0.0.metadata?.base is Schema.Relationship
                        } ?? []
                    let inverseCandidates = destinationRelationships.filter { metadata, _ in
                        guard let inverseRelationship = metadata.metadata?.base as? Schema.Relationship else {
                            return false
                        }
                        return inverseRelationship.inverse == relationship.name
                            || (relationship.inverse == metadata.name && inverseRelationship.inverse == nil)
                    }
                    let matchingInverse: String
                    if inverseCandidates.count == 1 {
                        matchingInverse = inverseCandidates[0].0.name
                    } else if inverseCandidates.isEmpty,
                        destinationRelationships.count == 1,
                        relationship.inverse == nil
                    {
                        matchingInverse = destinationRelationships[0].0.name
                    } else {
                        return relationship
                    }
                    return Schema.Relationship(
                        name: relationship.name,
                        destination: relationship.destination,
                        isToMany: relationship.isToMany,
                        inverse: matchingInverse,
                        deleteRule: relationship.deleteRule,
                        minimumModelCount: relationship.minimumModelCount,
                        maximumModelCount: relationship.maximumModelCount,
                        originalName: relationship.originalName
                    )
                }
            )
        }
        schema = Schema(inferredEntities)
        self.configurations = configurations
        store = try Self.openStore(schema: schema, configurations: configurations)
        var adaptersByModel: [ObjectIdentifier: [any AnyRelationshipAdapterBox]] = [:]
        for modelType in types {
            adaptersByModel[ObjectIdentifier(modelType)] = try Self.bindRelationshipAdapters(
                for: modelType,
                schema: schema
            )
        }
        relationshipAdapterTable = adaptersByModel
    }

    /// Creates a container for an existing schema.
    public init(for schema: Schema, configurations: [ModelConfiguration] = []) throws {
        self.schema = schema
        self.configurations = configurations
        store = try Self.openStore(schema: schema, configurations: configurations)
        relationshipAdapterTable = [:]
    }

    /// Creates a container for a manually supplied schema and typed model implementations.
    package init(
        for types: [any PersistentModel.Type],
        schema: Schema,
        configurations: [ModelConfiguration] = []
    ) throws {
        self.schema = schema
        self.configurations = configurations
        store = try Self.openStore(schema: schema, configurations: configurations)
        var adaptersByModel: [ObjectIdentifier: [any AnyRelationshipAdapterBox]] = [:]
        for modelType in types {
            adaptersByModel[ObjectIdentifier(modelType)] = try Self.bindRelationshipAdapters(
                for: modelType,
                schema: schema
            )
        }
        relationshipAdapterTable = adaptersByModel
    }

    /// Creates a container using a migration plan.
    public convenience init<Plan>(
        for types: any PersistentModel.Type...,
        migrationPlan: Plan.Type,
        configurations: ModelConfiguration...
    ) throws {
        _ = migrationPlan
        try self.init(for: types, configurations: configurations)
    }

    /// Returns the resolved relationship adapters registered for a model type.
    func relationshipAdapters<Model: PersistentModel>(for modelType: Model.Type)
        -> [any AnyRelationshipAdapterBox]
    {
        relationshipAdapterTable[ObjectIdentifier(modelType)] ?? []
    }

    private static func bindRelationshipAdapters<Model: PersistentModel>(
        for modelType: Model.Type,
        schema: Schema
    ) throws -> [any AnyRelationshipAdapterBox] {
        let entityName = unqualifiedTypeName(String(describing: modelType))
        let relationships = schema.entity(forName: entityName)?.relationships ?? []
        let candidates: [any AnyRelationshipAdapterBox]
        if let relationshipModelType = modelType as? any RelationshipModel.Type {
            candidates =
                relationshipModelType.relationshipAdapterCandidates()
                + relationshipModelType.inferredRelationshipAdapterCandidates()
        } else {
            candidates = []
        }
        let metadata = Model.schemaMetadata()
        var resolvedNames = Set<String>()
        var adapters: [any AnyRelationshipAdapterBox] = []
        for relationship in relationships {
            guard !candidates.isEmpty else { continue }
            let matches = candidates.filter {
                $0.ownerType == ObjectIdentifier(modelType)
                    && $0.name == relationship.name
                    && unqualifiedTypeName(String(describing: $0.destinationType)) == relationship.destination
                    && $0.isToMany == relationship.isToMany
            }
            guard matches.count == 1, let candidate = matches.first else {
                let detail =
                    matches.isEmpty ? "no compatible typed adapter exists" : "multiple compatible typed adapters exist"
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Relationship '\(entityName).\(relationship.name)' targets '\(relationship.destination)' "
                        + "with \(relationship.isToMany ? "to-many" : "to-one") cardinality, but \(detail)."
                )
            }
            resolvedNames.insert(relationship.name)
            adapters.append(candidate.resolved(with: relationship))
        }
        for property in metadata {
            guard let keyPath = property.keypath else { continue }
            let rawType = String(reflecting: type(of: keyPath).valueType)
            let destination = Self.relationshipDestination(rawType)
            guard property.isRelationship || property.metadata?.base is Schema.Relationship else { continue }
            guard let destination else { continue }
            guard !resolvedNames.contains(property.name) else { continue }
            let destinationName = unqualifiedTypeName(destination)
            throw SwiftDataError.unsupportedSchemaProperty(
                "Explicit relationship '\(entityName).\(property.name)' targets missing model '\(destinationName)' or is absent from the supplied schema."
            )
        }
        return adapters
    }

    /// Creates a context associated with this container.
    @MainActor
    public func makeContext() -> ModelContext {
        ModelContext(container: self, autosaveEnabled: false)
    }

    /// Deletes all persistent data owned by this container.
    public func deleteAllData() throws {
        guard store != nil else {
            throw SwiftDataError.unsupportedStore("Deleting all data is unavailable without a persistent store.")
        }
        throw SwiftDataError.unsupportedStore("Deleting all data is not implemented.")
    }

    /// Erases this container's store.
    public func erase() throws {
        guard store != nil else {
            throw SwiftDataError.unsupportedStore("Erasing the store is unavailable without a persistent store.")
        }
        throw SwiftDataError.unsupportedStore("Erasing the store is not implemented.")
    }

    private static func openStore(schema: Schema, configurations: [ModelConfiguration]) throws -> (any RuntimeStore)? {
        guard !configurations.isEmpty else { return nil }
        guard configurations.count == 1, let configuration = configurations.first else {
            throw SwiftDataError.unsupportedStore("Exactly one store configuration is supported.")
        }
        guard configuration.cloudKitDatabase == .none else {
            throw SwiftDataError.unsupportedStore("CloudKit stores are not supported.")
        }
        guard case .none = configuration.groupContainer else {
            throw SwiftDataError.unsupportedStore("App-group store locations are not supported.")
        }
        guard let factory = configuration.storeFactory else {
            throw SwiftDataError.unsupportedStore("The configured store backend/provider is unavailable.")
        }
        let location: RuntimeStoreLocation
        if configuration.isStoredInMemoryOnly {
            location = .memory(name: configuration.name)
        } else if let url = configuration.url {
            location = .file(url)
        } else {
            guard Self.isSafeStoreName(configuration.name) else {
                throw SwiftDataError.unsupportedStore("The store name must be a single safe path component.")
            }
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("\(configuration.name).sqlite")
            location = .file(url)
        }
        return try factory(location, schema)
    }

    private static func relationshipDestination(_ type: String) -> String? {
        let normalized = type.replacingOccurrences(of: "Swift.", with: "")
            .replacingOccurrences(of: "?", with: "")
        guard let opening = normalized.firstIndex(of: "<"), normalized.last == ">" else {
            return unqualifiedTypeName(normalized)
        }
        let container = unqualifiedTypeName(String(normalized[..<opening]))
        guard container == "Array" || container == "Set" else { return nil }
        let argument = normalized[normalized.index(after: opening)..<normalized.index(before: normalized.endIndex)]
        return unqualifiedTypeName(String(argument).replacingOccurrences(of: "?", with: ""))
    }

    private static func isSafeStoreName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
            && !name.contains(":")
    }

    private static func unqualifiedTypeName(_ type: String) -> String {
        type.split(separator: ".").last.map(String.init) ?? type
    }

    private static func normalizedTypeName(_ type: String) -> String {
        type.replacingOccurrences(of: "Swift.", with: "")
    }

    private static func normalizedPropertyType(_ type: String) -> (String, Bool) {
        let normalized = normalizedTypeName(type).trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix("?") {
            let (wrappedType, _) = normalizedPropertyType(String(normalized.dropLast()))
            return (wrappedType, true)
        }
        guard let openingDelimiter = normalized.firstIndex(of: "<"), normalized.last == ">" else {
            return (unqualifiedTypeName(normalized), false)
        }
        let container = String(normalized[..<openingDelimiter])
        if unqualifiedTypeName(container) == "Optional" {
            let arguments = String(
                normalized[normalized.index(after: openingDelimiter)..<normalized.index(before: normalized.endIndex)])
            guard let argument = splitGenericArguments(arguments).first else {
                return (unqualifiedTypeName(normalized), false)
            }
            let (wrappedType, _) = normalizedPropertyType(argument)
            return (wrappedType, true)
        }
        let arguments = String(
            normalized[normalized.index(after: openingDelimiter)..<normalized.index(before: normalized.endIndex)])
        let components = splitGenericArguments(arguments)
        guard components.count == 1, let argument = components.first else {
            return (unqualifiedTypeName(normalized), false)
        }
        let (_, isOptional) = normalizedPropertyType(argument)
        return ("\(unqualifiedTypeName(container))<\(argument)>", isOptional)
    }

    private static func parseType(_ type: String) -> (
        name: String,
        collectionElement: String?,
        collectionElementIsOptional: Bool
    ) {
        guard let openingDelimiter = type.firstIndex(of: "<"), type.last == ">" else {
            return (type, nil, false)
        }
        let container = unqualifiedTypeName(String(type[..<openingDelimiter]))
        guard container == "Array" || container == "Set" else { return (type, nil, false) }
        let arguments = String(type[type.index(after: openingDelimiter)..<type.index(before: type.endIndex)])
        guard let element = splitGenericArguments(arguments).first else { return (type, nil, false) }
        let (elementName, isOptional) = normalizedPropertyType(element)
        return (elementName, elementName, isOptional)
    }

    private static func splitGenericArguments(_ arguments: String) -> [String] {
        var depth = 0
        var start = arguments.startIndex
        var components: [String] = []
        for index in arguments.indices {
            switch arguments[index] {
            case "<": depth += 1
            case ">": depth -= 1
            case "," where depth == 0:
                components.append(String(arguments[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                start = arguments.index(after: index)
            default: break
            }
        }
        components.append(String(arguments[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        return components
    }

    private static func attributeOption(_ option: String) -> Schema.Attribute.Option? {
        switch option {
        case "unique": .unique
        case "externalStorage": .externalStorage
        case "encrypt": .encrypt
        case "preserveValueOnDeletion": .preserveValueOnDeletion
        case "spotlight": .spotlight
        case "allowsCloudEncryption": .allowsCloudEncryption
        case "ephemeral": .ephemeral
        default: nil
        }
    }
}
