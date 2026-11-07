import Foundation

/// Owns a schema and its associated model contexts.
public final class ModelContainer: Sendable {
    /// The schema managed by this container.
    public let schema: SchemaDescriptor
    /// The main context associated with this container, created on first access.
    @MainActor
    public var mainContext: ModelContext {
        if let context = mainContextStorage.context { return context }
        let context = ModelContext(container: self, autosaveEnabled: true, affinity: .mainActor)
        mainContextStorage.context = context
        return context
    }
    private let mainContextStorage = MainContextStorage()
    /// The configurations used by the container.
    public var configurations: Set<ModelConfiguration> { Set(configurationList) }
    /// The configurations in the order the container received them.
    package let configurationList: [ModelConfiguration]
    /// The migration plan the container ran when it opened, if any.
    public var migrationPlan: (any SchemaMigrationPlan.Type)? { migrationPlanStorage.plan }
    private let migrationPlanStorage = MigrationPlanStorage()
    package let store: (any RuntimeStore)?
    /// The store identifier recorded in persistent identifiers: a UUID string saved with the store, as in
    /// Apple's SwiftData, falling back to the configuration name for stores that don't provide one.
    package var storeIdentifier: String {
        dataStore?.identifier ?? store?.persistentStoreIdentifier ?? configurationList.first?.name ?? "default"
    }
    package let dataStore: (any DataStore)?
    let storeIdentityHandle = StoreIdentityHandle()
    let relationshipAdapterTable: [ObjectIdentifier: [any AnyRelationshipAdapterBox]]
    let modelTypesByEntityName: [String: ModelTypeRegistration]
    let modelTypesByEntityID: [Int: ModelTypeRegistration]

    func modelType(forEntityName name: String) -> (any PersistentModel.Type)? {
        modelTypesByEntityName[name]?.type
    }

    func modelRegistration(forEntityName name: String) -> ModelTypeRegistration? {
        modelTypesByEntityName[name]
    }

    func modelRegistration(forEntityID identifier: Int) -> ModelTypeRegistration? {
        modelTypesByEntityID[identifier]
    }

    /// Creates a container for the schema inferred from model types, migrating the store first when a plan is given.
    ///
    /// Omitting `configurations` opens the implicit default store, a SQLite file named
    /// `default.store` in the Application Support directory.
    public convenience init(
        for types: any PersistentModel.Type...,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
        configurations: ModelConfiguration...
    ) throws {
        let configurations = try Self.configurationsOrDefault(configurations)
        if let migrationPlan {
            try self.init(migrating: types, plan: migrationPlan, configurations: configurations)
        } else {
            try self.init(for: types, configurations: configurations)
        }
        migrationPlanStorage.plan = migrationPlan
    }

    /// Creates a container for the schema inferred from model types, backed by the implicit default store.
    ///
    /// The default store is a SQLite file named `default.store` in the Application Support directory.
    public convenience init(for types: [any PersistentModel.Type]) throws {
        try self.init(for: types, configurations: [ModelConfiguration.implicitDefault()])
    }

    /// Creates a container for the schema inferred from model types and configurations.
    ///
    /// An empty `configurations` array creates a schema-only container without a persistent store.
    public convenience init(for types: [any PersistentModel.Type], configurations: [ModelConfiguration]) throws {
        try self.init(inferredSchema: Self.inferredSchema(for: types), configurations: configurations)
    }

    /// Infers a schema from model types and their ancestors, capturing the types for materialization.
    package static func inferredSchema(
        for types: [any PersistentModel.Type], version: SchemaDescriptor.Version? = nil
    ) throws -> SchemaDescriptor {
        let types = Self.modelTypesIncludingAncestors(of: types)
        let entityNames = types.map { Self.unqualifiedTypeName(String(describing: $0)) }
        var uniqueEntityNames = Set<String>()
        for entityName in entityNames where !uniqueEntityNames.insert(entityName).inserted {
            throw SwiftDataError.duplicateEntityName(
                "Multiple model types resolve to the entity name '\(entityName)'; provide distinct model names."
            )
        }
        let modelNames = Set(entityNames)
        let relationshipModelNames = Set(
            zip(types, entityNames).compactMap { modelType, entityName in
                (modelType is any RelationshipModel.Type) ? entityName : nil
            })
        var propertiesByEntity: [String: [(SchemaDescriptor.PropertyMetadata, AnyKeyPath)]] = [:]
        for (modelType, entityName) in zip(types, entityNames) {
            propertiesByEntity[entityName] = modelType.schemaMetadata().compactMap { metadata in
                metadata.keypath.map { (metadata, $0) }
            }
        }
        let effectivePropertiesByEntity = propertiesByEntity.mapValues(Self.effectiveProperties)
        let entities = try types.map { modelType in
            let properties = propertiesByEntity[Self.unqualifiedTypeName(String(describing: modelType))] ?? []
            let schemaProperties = try properties.map {
                metadata, keypath -> (SchemaDescriptor.PropertyMetadata, String, Bool, Any.Type) in
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
                return (metadata, normalizedType, isOptional, type(of: keypath).valueType)
            }
            let attributes = try schemaProperties.compactMap {
                metadata, propertyType, isOptional, valueType -> SchemaDescriptor.Attribute? in
                let typedRelationship = metadata.metadata?.base as? SchemaDescriptor.Relationship
                let parsedType = Self.parseType(propertyType)
                let destinationType = Self.unqualifiedTypeName(parsedType.collectionElement ?? parsedType.name)
                let isInferredModelType = metadata.isInferredRelationship && modelNames.contains(destinationType)
                let isLegacyExplicitCollection =
                    metadata.isExplicitRelationship && parsedType.collectionElement != nil
                    && modelNames.contains(destinationType) && !relationshipModelNames.contains(destinationType)
                let isModelType = modelNames.contains(Self.unqualifiedTypeName(propertyType))
                guard
                    (!metadata.isRelationship || isLegacyExplicitCollection || metadata.isExplicitAttribute
                        || (metadata.isInferredRelationship && !isInferredModelType)),
                    typedRelationship == nil,
                    !isModelType || isLegacyExplicitCollection || metadata.isExplicitAttribute,
                    !isInferredModelType || metadata.isExplicitAttribute
                else {
                    return nil
                }
                let typedAttribute = metadata.metadata?.base as? SchemaDescriptor.Attribute
                let options = (typedAttribute?.options ?? []).union(
                    metadata.options.compactMap(Self.attributeOption))
                if options.contains(.externalStorage), Self.unqualifiedTypeName(parsedType.name) != "Data" {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "External storage is supported only for Data properties ('\(metadata.name)').")
                }
                let flattenedComponents: [SchemaDescriptor.Attribute.Component]
                if options.contains(.flattened) {
                    guard !isOptional else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Flattened composite '\(metadata.name)' cannot be optional.")
                    }
                    guard valueType is any FlattenableComposite.Type else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "A property marked `.flattened` must conform to FlattenableComposite.")
                    }
                    guard let compositeType = valueType as? any FlattenedCompositeMetadataProviding.Type,
                        compositeType.flattenedComponentsForSchema.map({ ($0.0, $0.1) })
                            .elementsEqual(metadata.flattenedComponents.map({ ($0.name, $0.type) }), by: ==)
                    else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Flattened schema metadata for '\(metadata.name)' does not match its component adapters.")
                    }
                    flattenedComponents = try metadata.flattenedComponents.map { component in
                        guard
                            component.name.utf8.allSatisfy({
                                ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95
                            })
                        else {
                            throw SwiftDataError.unsupportedSchemaProperty(
                                "Flattened component '\(component.name)' is not a valid property identifier.")
                        }
                        let componentType = component.type.split(separator: ".").last.map(String.init) ?? component.type
                        guard
                            [
                                "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32",
                                "UInt64", "Float", "Double", "Bool", "String", "Date", "UUID", "URL", "Data",
                                "Decimal",
                            ].contains(componentType)
                        else {
                            throw SwiftDataError.unsupportedSchemaProperty(
                                "Unsupported flattened scalar type '\(component.type)' for '\(metadata.name).\(component.name)'."
                            )
                        }
                        return SchemaDescriptor.Attribute.Component(
                            name: component.name,
                            columnName: "\(metadata.name)_\(component.name)",
                            type: componentType)
                    }
                    guard Set(flattenedComponents.map { $0.name.uppercased() }).count == flattenedComponents.count
                    else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Flattened composite '\(metadata.name)' declares colliding component names.")
                    }
                    guard !flattenedComponents.isEmpty else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Flattened composite '\(metadata.name)' must declare at least one scalar component.")
                    }
                } else {
                    flattenedComponents = []
                }
                return SchemaDescriptor.Attribute(
                    name: metadata.name,
                    type: propertyType,
                    isOptional: isOptional,
                    defaultValue: metadata.defaultValue,
                    options: options,
                    originalName: typedAttribute?.originalName,
                    components: flattenedComponents
                )
            }
            let relationships = try schemaProperties.compactMap {
                metadata, propertyType, isOptional, _ -> SchemaDescriptor.Relationship? in
                let parsedType = Self.parseType(propertyType)
                let isToMany = parsedType.collectionElement != nil
                let destination = parsedType.collectionElement ?? parsedType.name
                let typedRelationship = metadata.metadata?.base as? SchemaDescriptor.Relationship
                let destinationName = Self.unqualifiedTypeName(destination)
                let declaringEntityName = Self.relationshipDeclaringEntityName(
                    modelType: modelType, metadata: metadata)
                let logicalOwnerName =
                    declaringEntityName
                    ?? Self.unqualifiedTypeName(String(describing: modelType))
                let isInferredModelCollection =
                    !metadata.isExplicitRelationship && !metadata.isExplicitAttribute && isToMany
                    && parsedType.collectionElement.map { modelNames.contains(Self.unqualifiedTypeName($0)) } == true
                guard
                    typedRelationship != nil || isInferredModelCollection
                        || (!metadata.isExplicitAttribute && modelNames.contains(Self.unqualifiedTypeName(destination)))
                else {
                    return nil
                }
                if typedRelationship != nil {
                    guard modelNames.contains(destinationName) else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Relationship '\(Self.unqualifiedTypeName(String(describing: modelType))).\(metadata.name)' "
                                + "targets missing model '\(destinationName)'."
                        )
                    }
                }
                let destinationRelationships =
                    Self.relationshipProperties(
                        entityName: destinationName,
                        among: types,
                        effectivePropertiesByEntity: effectivePropertiesByEntity)
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
                    let rawInverseCandidates = Self.properties(
                        named: explicitInverseName,
                        onOrBelow: destinationName,
                        among: types,
                        effectivePropertiesByEntity: effectivePropertiesByEntity)
                    let inverseCandidates = Dictionary(
                        rawInverseCandidates.map { (AnyHashable($0.1), $0) },
                        uniquingKeysWith: { first, _ in first }
                    ).map(\.value)
                    guard inverseCandidates.count == 1,
                        let inverseMetadata = inverseCandidates.first
                    else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Relationship '\(Self.unqualifiedTypeName(String(describing: modelType))).\(metadata.name)' "
                                + "declares inverse '\(destinationName).\(explicitInverseName)', but that property is missing or ambiguous."
                        )
                    }
                    let inversePropertyRawType =
                        inverseMetadata.0.keypath.map {
                            String(reflecting: type(of: $0).valueType)
                        } ?? ""
                    let (normalizedInversePropertyType, _) = Self.normalizedPropertyType(inversePropertyRawType)
                    guard
                        inverseMetadata.0.isRelationship || inverseMetadata.0.metadata?.base is SchemaDescriptor.Relationship
                            || (Self.relationshipDestination(normalizedInversePropertyType).map {
                                modelNames.contains(Self.unqualifiedTypeName($0))
                            } ?? false)
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
                        Self.relationshipDestination(
                            inverseDestination, matchesLogicalOwner: logicalOwnerName, among: types)
                    else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Relationship inverse '\(destinationName).\(explicitInverseName)' does not point back to "
                                + "'\(logicalOwnerName)'."
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
                let explicitReciprocals = destinationRelationships.filter { inverseMetadata, inverseRelationship in
                    guard inverseRelationship.inverse == metadata.name else { return false }
                    let rawType = inverseMetadata.keypath.map { String(reflecting: type(of: $0).valueType) } ?? ""
                    let (normalizedType, _) = Self.normalizedPropertyType(rawType)
                    let parsedType = Self.parseType(normalizedType)
                    let inverseDestination = Self.unqualifiedTypeName(
                        parsedType.collectionElement ?? parsedType.name)
                    return Self.relationshipDestination(
                        inverseDestination, matchesLogicalOwner: logicalOwnerName, among: types)
                }
                let inferredInverse: String?
                if !hasExplicitInverse, explicitReciprocals.count == 1 {
                    inferredInverse = explicitReciprocals[0].0.name
                } else {
                    inferredInverse = nil
                }
                let inverse = hasExplicitInverse ? explicitInverse : inferredInverse
                return SchemaDescriptor.Relationship(
                    name: metadata.name,
                    destination: destinationName,
                    isToMany: isToMany,
                    isOptional: isToMany || isOptional,
                    inverse: inverse,
                    deleteRule: typedRelationship?.deleteRule ?? .nullify,
                    minimumModelCount: typedRelationship?.minimumModelCount,
                    maximumModelCount: typedRelationship?.maximumModelCount,
                    originalName: typedRelationship?.originalName,
                    declaringEntityName: declaringEntityName
                )
            }
            var relationshipNames = Set<String>()
            for relationship in relationships where !relationshipNames.insert(relationship.name).inserted {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Relationship property '\(Self.unqualifiedTypeName(String(describing: modelType))).\(relationship.name)' is declared more than once in the inheritance hierarchy."
                )
            }
            let indexes =
                modelType.schemaIndexes().filter { index in
                    !(index.isUnique && index.properties.count == 1
                        && attributes.first(where: { $0.name == index.properties[0] })?.options.contains(.unique)
                            == true)
                }
                + attributes.compactMap { attribute in
                    attribute.options.contains(.unique)
                        ? SchemaDescriptor.Index(properties: [attribute.name], isUnique: true) : nil
                }
            var seenIndexes = Set<SchemaDescriptor.Index>()
            return SchemaDescriptor.Entity(
                name: Self.unqualifiedTypeName(String(describing: modelType)),
                attributes: attributes,
                relationships: relationships,
                indexes: indexes.filter { seenIndexes.insert($0).inserted },
                superentityName: modelType.parentModel.map { Self.unqualifiedTypeName(String(describing: $0)) }
            )
        }
        let inferredEntities = try entities.map { entity in
            let relationships = try entity.relationships.map { relationship in
                let logicalOwnerName = relationship.declaringEntityName ?? entity.name
                guard relationship.inverse == nil else { return relationship }
                let matchingInverse = try Self.inferredInverseName(
                    relationshipName: relationship.name,
                    destinationName: relationship.destination,
                    logicalOwnerName: logicalOwnerName,
                    among: types,
                    effectivePropertiesByEntity: effectivePropertiesByEntity)
                guard let matchingInverse else { return relationship }
                return SchemaDescriptor.Relationship(
                    name: relationship.name,
                    destination: relationship.destination,
                    isToMany: relationship.isToMany,
                    isOptional: relationship.isOptional,
                    inverse: matchingInverse,
                    deleteRule: relationship.deleteRule,
                    minimumModelCount: relationship.minimumModelCount,
                    maximumModelCount: relationship.maximumModelCount,
                    originalName: relationship.originalName,
                    declaringEntityName: relationship.declaringEntityName
                )
            }
            return SchemaDescriptor.Entity(
                name: entity.name, attributes: entity.attributes, relationships: relationships,
                indexes: entity.indexes, superentityName: entity.superentityName)
        }
        var schema = SchemaDescriptor(inferredEntities, version: version)
        try schema.validateRelationshipStorageMappings()
        schema.modelTypes = SchemaDescriptor.ModelTypes(types: types)
        return schema
    }

    /// Creates a container for a schema produced by `inferredSchema(for:version:)`.
    private init(inferredSchema schema: SchemaDescriptor, configurations: [ModelConfiguration]) throws {
        if let error = schema.modelTypes.inferenceError { throw error }
        let types = schema.modelTypes.types.compactMap { $0 as? any PersistentModel.Type }
        let entityNames = types.map { Self.unqualifiedTypeName(String(describing: $0)) }
        let openedDataStore = try Self.openDataStore(
            schema: schema, migrationPlan: migrationPlanStorage.plan, configurations: configurations)
        let openedStore = try Self.openStore(schema: schema, configurations: configurations)
        let runtimeSchema: SchemaDescriptor
        let registrations: [String: ModelTypeRegistration]
        let registrationsByID: [Int: ModelTypeRegistration]
        let adaptersByModel: [ObjectIdentifier: [any AnyRelationshipAdapterBox]]
        do {
            runtimeSchema = try Self.runtimeSchema(requested: schema, store: openedStore)
            try runtimeSchema.validateRelationshipStorageMappings()
            try Self.validateDataStoreInheritanceSupport(schema: runtimeSchema, dataStore: openedDataStore)
            var resolvedRegistrations: [String: ModelTypeRegistration] = [:]
            var resolvedRegistrationsByID: [Int: ModelTypeRegistration] = [:]
            for (modelType, entityName) in zip(types, entityNames) {
                let registration = ModelTypeRegistration(type: modelType)
                resolvedRegistrations[entityName] = registration
                if let entityID = runtimeSchema.entityIDsByName[entityName] {
                    resolvedRegistrationsByID[entityID] = registration
                }
            }
            registrations = resolvedRegistrations
            registrationsByID = resolvedRegistrationsByID
            var resolvedAdapters: [ObjectIdentifier: [any AnyRelationshipAdapterBox]] = [:]
            for modelType in types {
                resolvedAdapters[ObjectIdentifier(modelType)] = try Self.bindRelationshipAdapters(
                    for: modelType, schema: runtimeSchema)
            }
            adaptersByModel = resolvedAdapters
        } catch {
            try? openedStore?.close()
            throw error
        }
        self.schema = runtimeSchema
        configurationList = configurations
        dataStore = openedDataStore
        store = openedStore
        modelTypesByEntityName = registrations
        modelTypesByEntityID = registrationsByID
        relationshipAdapterTable = adaptersByModel
    }

    /// Creates a container for an existing schema, migrating the store first when a plan is given.
    ///
    /// Omitting `configurations` opens the implicit default store, a SQLite file named
    /// `default.store` in the Application Support directory.
    public convenience init(
        for schema: SchemaDescriptor,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
        configurations: ModelConfiguration...
    ) throws {
        try self.init(
            for: schema, migrationPlan: migrationPlan, configurations: Self.configurationsOrDefault(configurations))
    }

    /// Creates a container for an existing schema, migrating the store first when a plan is given.
    ///
    /// An empty `configurations` array creates a schema-only container without a persistent store.
    public convenience init(
        for schema: SchemaDescriptor,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
        configurations: [ModelConfiguration]
    ) throws {
        if let migrationPlan {
            let types = schema.modelTypes.types.compactMap { $0 as? any PersistentModel.Type }
            try self.init(migrating: types, plan: migrationPlan, configurations: configurations)
            migrationPlanStorage.plan = migrationPlan
        } else {
            try self.init(schemaOnly: schema, configurations: configurations)
        }
    }

    private convenience init(schemaOnly schema: SchemaDescriptor, configurations: [ModelConfiguration]) throws {
        if !schema.modelTypes.types.isEmpty || schema.modelTypes.inferenceError != nil {
            try self.init(inferredSchema: schema, configurations: configurations)
        } else {
            try self.init(descriptionOnly: schema, configurations: configurations)
        }
    }

    /// Creates a container for a hand-built schema that names no model types.
    private init(descriptionOnly schema: SchemaDescriptor, configurations: [ModelConfiguration]) throws {
        try schema.validateRelationshipStorageMappings()
        let openedDataStore = try Self.openDataStore(
            schema: schema, migrationPlan: migrationPlanStorage.plan, configurations: configurations)
        let openedStore = try Self.openStore(schema: schema, configurations: configurations)
        let runtimeSchema: SchemaDescriptor
        do {
            runtimeSchema = try Self.runtimeSchema(requested: schema, store: openedStore)
            try runtimeSchema.validateRelationshipStorageMappings()
            try Self.validateDataStoreInheritanceSupport(schema: runtimeSchema, dataStore: openedDataStore)
        } catch {
            try? openedStore?.close()
            throw error
        }
        self.schema = runtimeSchema
        configurationList = configurations
        dataStore = openedDataStore
        store = openedStore
        modelTypesByEntityName = [:]
        modelTypesByEntityID = [:]
        relationshipAdapterTable = [:]
    }

    /// Creates a container for a manually supplied schema and typed model implementations.
    ///
    /// An empty `configurations` array creates a schema-only container without a persistent store.
    package init(
        for types: [any PersistentModel.Type],
        schema: SchemaDescriptor,
        configurations: [ModelConfiguration]
    ) throws {
        try schema.validateRelationshipStorageMappings()
        let openedDataStore = try Self.openDataStore(
            schema: schema, migrationPlan: migrationPlanStorage.plan, configurations: configurations)
        let openedStore = try Self.openStore(schema: schema, configurations: configurations)
        let runtimeSchema: SchemaDescriptor
        let registrations: [String: ModelTypeRegistration]
        let registrationsByID: [Int: ModelTypeRegistration]
        let adaptersByModel: [ObjectIdentifier: [any AnyRelationshipAdapterBox]]
        do {
            runtimeSchema = try Self.runtimeSchema(requested: schema, store: openedStore)
            try runtimeSchema.validateRelationshipStorageMappings()
            try Self.validateDataStoreInheritanceSupport(schema: runtimeSchema, dataStore: openedDataStore)
            var resolvedRegistrations: [String: ModelTypeRegistration] = [:]
            for modelType in types {
                let name = Self.unqualifiedTypeName(String(describing: modelType))
                if runtimeSchema.entities.contains(where: { $0.name == name }) {
                    resolvedRegistrations[name] = ModelTypeRegistration(type: modelType)
                }
            }
            registrations = resolvedRegistrations
            var resolvedRegistrationsByID: [Int: ModelTypeRegistration] = [:]
            for (name, registration) in registrations {
                if let entityID = runtimeSchema.entityIDsByName[name] {
                    resolvedRegistrationsByID[entityID] = registration
                }
            }
            registrationsByID = resolvedRegistrationsByID
            var resolvedAdapters: [ObjectIdentifier: [any AnyRelationshipAdapterBox]] = [:]
            for modelType in types {
                resolvedAdapters[ObjectIdentifier(modelType)] = try Self.bindRelationshipAdapters(
                    for: modelType, schema: runtimeSchema, requiresCompatibleCandidates: true)
            }
            adaptersByModel = resolvedAdapters
        } catch {
            try? openedStore?.close()
            throw error
        }
        self.schema = runtimeSchema
        configurationList = configurations
        dataStore = openedDataStore
        store = openedStore
        modelTypesByEntityName = registrations
        modelTypesByEntityID = registrationsByID
        relationshipAdapterTable = adaptersByModel
    }

    /// Migrates the configured stores through a plan, then opens them with the plan's latest schema.
    private convenience init(
        migrating types: [any PersistentModel.Type],
        plan migrationPlan: any SchemaMigrationPlan.Type,
        configurations: [ModelConfiguration]
    ) throws {
        let descriptor = try MigrationPlanDescriptor(migrationPlan)
        guard let destination = descriptor.schemas.last else {
            throw SwiftDataError.migrationUnsupported("Migration plan contains no schemas.")
        }
        let requestedModels = Set(types.map { Self.unqualifiedTypeName(String(describing: $0)) })
        let plannedModels = Set(destination.models.map { Self.unqualifiedTypeName(String(describing: $0)) })
        guard requestedModels == plannedModels else {
            throw SwiftDataError.migrationUnsupported(
                "The container model types must match the latest migration-plan schema.")
        }
        let pendingMigration = try Self.runMigrationPlan(descriptor, configurations: configurations)
        try self.init(for: destination.models, schema: destination.schema, configurations: configurations)
        if pendingMigration != nil {
            try Self.setPendingMigration(nil, store: self.store)
        }
    }

    /// Returns `configurations`, or the implicit default configuration when it is empty.
    private static func configurationsOrDefault(
        _ configurations: [ModelConfiguration]
    ) throws -> [ModelConfiguration] {
        configurations.isEmpty ? [try ModelConfiguration.implicitDefault()] : configurations
    }

    private static func runMigrationPlan(
        _ plan: MigrationPlanDescriptor,
        configurations: [ModelConfiguration]
    ) throws -> String? {
        guard !configurations.isEmpty else { return nil }
        guard configurations.count == 1, let configuration = configurations.first else {
            throw SwiftDataError.migrationUnsupported(
                "Versioned migration plans require exactly one store configuration.")
        }
        guard !configuration.isStoredInMemoryOnly else { return nil }
        guard let versionReader = configuration.schemaVersionReader else {
            throw SwiftDataError.migrationUnsupported("The configured store cannot report its stored schema version.")
        }
        let versionState = try versionReader(Self.storeLocation(for: configuration))
        var finalPendingMigration: String?
        let startIndex: Int
        switch versionState {
        case let .pending(destinationIdentifier):
            guard
                let destinationIndex = plan.schemas.firstIndex(where: {
                    $0.version.identifier == destinationIdentifier
                }), destinationIndex > 0
            else {
                throw SwiftDataError.migrationUnsupported("Pending migration stage is not present in the plan.")
            }
            let destination = plan.schemas[destinationIndex]
            if let verifyStoredSchema = configuration.schemaCompatibilityReader,
                try !verifyStoredSchema(Self.storeLocation(for: configuration), destination.schema)
            {
                throw SwiftDataError.migrationUnsupported(
                    "Stored schema does not match pending destination version '\(destinationIdentifier)'.")
            }
            let stage = plan.stages[destinationIndex - 1]
            let destinationContainer = try ModelContainer(
                for: destination.models, schema: destination.schema, configurations: configurations)
            defer { try? destinationContainer.store?.close() }
            if let didMigrate = stage.didMigrate {
                let context = ModelContext(
                    container: destinationContainer, autosaveEnabled: false, affinity: .unchecked)
                try context.transaction { try didMigrate(context) }
            }
            startIndex = destinationIndex
            if destinationIndex == plan.schemas.count - 1 {
                finalPendingMigration = destinationIdentifier
            } else {
                try setPendingMigration(nil, store: destinationContainer.store)
            }
        default:
            if case let .version(version) = versionState,
                let storedIndex = plan.schemas.firstIndex(where: { $0.version == version }),
                let verifyStoredSchema = configuration.schemaCompatibilityReader,
                try !verifyStoredSchema(
                    Self.storeLocation(for: configuration), plan.schemas[storedIndex].schema)
            {
                throw SwiftDataError.migrationUnsupported(
                    "Stored schema does not match recorded version '\(version.identifier)'.")
            }
            var resolvedState = versionState
            // A store created without a plan records no version; identify it by matching its stored layout
            // against the plan's schemas, preferring the newest match.
            if case .unversioned = versionState, let verifyStoredSchema = configuration.schemaCompatibilityReader,
                let index = try plan.schemas.indices.reversed().first(where: {
                    try verifyStoredSchema(Self.storeLocation(for: configuration), plan.schemas[$0].schema)
                })
            {
                resolvedState = .version(plan.schemas[index].version)
            }
            startIndex = try migrationStartIndex(for: resolvedState, in: plan)
        }

        guard startIndex < plan.schemas.count - 1 else { return finalPendingMigration }
        if case .empty = versionState, let first = plan.schemas.first {
            let initial = try ModelContainer(for: first.models, schema: first.schema, configurations: configurations)
            try initial.store?.close()
        }

        for index in startIndex..<plan.schemas.count - 1 {
            let source = plan.schemas[index]
            let destination = plan.schemas[index + 1]
            let stage = plan.stages[index]
            let sourceContainer = try ModelContainer(
                for: source.models, schema: source.schema, configurations: configurations)
            defer { try? sourceContainer.store?.close() }
            if let willMigrate = stage.willMigrate {
                let context = ModelContext(container: sourceContainer, autosaveEnabled: false, affinity: .unchecked)
                try context.transaction { try willMigrate(context) }
            }
            try setPendingMigration(destination.version.identifier, store: sourceContainer.store)

            let destinationContainer = try ModelContainer(
                for: destination.models, schema: destination.schema, configurations: configurations)
            defer { try? destinationContainer.store?.close() }
            if let didMigrate = stage.didMigrate {
                let context = ModelContext(
                    container: destinationContainer, autosaveEnabled: false, affinity: .unchecked)
                try context.transaction { try didMigrate(context) }
            }
            if index + 1 == plan.schemas.count - 1 {
                finalPendingMigration = destination.version.identifier
            } else {
                try setPendingMigration(nil, store: destinationContainer.store)
            }
        }
        return finalPendingMigration
    }

    private static func migrationStartIndex(
        for state: RuntimeSchemaVersionState, in plan: MigrationPlanDescriptor
    ) throws -> Int {
        switch state {
        case let .version(version):
            guard let index = plan.schemas.firstIndex(where: { $0.version == version }) else {
                throw SwiftDataError.migrationUnsupported(
                    "Stored schema version '\(version.identifier)' is not present in the migration plan.")
            }
            return index
        case .empty:
            return 0
        case .unversioned:
            throw SwiftDataError.migrationUnsupported(
                "The existing store has no version identifier for the migration plan.")
        case .pending:
            throw SwiftDataError.migrationUnsupported("Pending migration state was not resolved.")
        }
    }

    private static func setPendingMigration(_ identifier: String?, store: (any RuntimeStore)?) throws {
        guard let store else {
            throw SwiftDataError.migrationUnsupported("Migration stages require a persistent runtime store.")
        }
        try store.write { connection in
            if identifier == nil {
                try connection.execute(
                    "DELETE FROM _osd_meta WHERE key = ?", arguments: [.text("schema.migration.pending.v1")])
            } else if let identifier {
                try connection.execute(
                    "INSERT INTO _osd_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [.text("schema.migration.pending.v1"), .blob(Array(identifier.utf8))])
            }
        }
    }

    private static func storeLocation(for configuration: ModelConfiguration) -> RuntimeStoreLocation {
        configuration.isStoredInMemoryOnly ? .memory(name: configuration.name) : .file(configuration.url)
    }

    /// Returns the resolved relationship adapters registered for a model type.
    func relationshipAdapters<Model: PersistentModel>(for modelType: Model.Type)
        -> [any AnyRelationshipAdapterBox]
    {
        relationshipAdapterTable[ObjectIdentifier(modelType)] ?? []
    }

    private static func bindRelationshipAdapters<Model: PersistentModel>(
        for modelType: Model.Type,
        schema: SchemaDescriptor,
        requiresCompatibleCandidates: Bool = false
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
        let metadata = modelType.schemaMetadata()
        var compatibleOwnerTypes: Set<ObjectIdentifier> = []
        var currentOwner: (any PersistentModel.Type)? = modelType
        while let owner = currentOwner, compatibleOwnerTypes.insert(ObjectIdentifier(owner)).inserted {
            currentOwner = owner.parentModel
        }
        var resolvedNames = Set<String>()
        var adapters: [any AnyRelationshipAdapterBox] = []
        var schemaRelationshipsByName = Dictionary(uniqueKeysWithValues: relationships.map { ($0.name, $0) })
        for property in metadata where property.metadata?.base is SchemaDescriptor.Relationship {
            guard schemaRelationshipsByName[property.name] == nil,
                let keyPath = property.keypath
            else { continue }
            let rawType = String(reflecting: type(of: keyPath).valueType)
            guard let destination = Self.relationshipDestination(rawType) else { continue }
            schemaRelationshipsByName[property.name] = SchemaDescriptor.Relationship(
                name: property.name,
                destination: unqualifiedTypeName(destination),
                isToMany: rawType.contains("Array<") || rawType.contains("Set<"),
                isOptional: rawType.contains("Array<") || rawType.contains("Set<")
                    || Self.normalizedPropertyType(rawType).1,
                inverse: (property.metadata?.base as? SchemaDescriptor.Relationship)?.inverse,
                declaringEntityName: Self.relationshipDeclaringEntityName(
                    modelType: modelType, metadata: property))
        }
        let bindingRelationships = Array(schemaRelationshipsByName.values).sorted { $0.name < $1.name }
        for relationship in bindingRelationships {
            guard !candidates.isEmpty else { continue }
            let propertyMetadata = metadata.first(where: { $0.name == relationship.name })
            if propertyMetadata?.isExplicitRelationship == true,
                !(propertyMetadata?.metadata?.base is SchemaDescriptor.Relationship),
                let destinationType = candidates.first(where: { $0.name == relationship.name })?.destinationType,
                !(destinationType is any RelationshipModel.Type)
            {
                continue
            }
            let matches = candidates.filter {
                compatibleOwnerTypes.contains($0.ownerType)
                    && $0.name == relationship.name
                    && unqualifiedTypeName(String(describing: $0.destinationType)) == relationship.destination
                    && $0.isToMany == relationship.isToMany
            }
            guard matches.count == 1, let candidate = matches.first else {
                let hasTypedSchemaMetadata = propertyMetadata?.metadata?.base is SchemaDescriptor.Relationship
                let hasRelationshipRefinement = modelType is any RelationshipModel.Type
                if matches.isEmpty, !hasTypedSchemaMetadata,
                    !requiresCompatibleCandidates, !hasRelationshipRefinement
                {
                    continue
                }
                let detail =
                    matches.isEmpty ? "no compatible typed adapter exists" : "multiple compatible typed adapters exist"
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Relationship '\(entityName).\(relationship.name)' targets '\(relationship.destination)' "
                        + "with \(relationship.isToMany ? "to-many" : "to-one") cardinality, but \(detail)."
                )
            }
            resolvedNames.insert(relationship.name)
            let resolved: any AnyRelationshipAdapterBox
            if let inverse = relationship.inverse,
                candidate.explicitInverseKeyPath == nil,
                metadata.first(where: { $0.name == relationship.name })?.metadata?.base is SchemaDescriptor.Relationship
            {
                resolved = candidate.resolved(
                    with: SchemaDescriptor.Relationship(
                        name: relationship.name, destination: relationship.destination,
                        isToMany: relationship.isToMany, isOptional: relationship.isOptional, inverse: inverse,
                        deleteRule: relationship.deleteRule,
                        minimumModelCount: relationship.minimumModelCount,
                        maximumModelCount: relationship.maximumModelCount,
                        originalName: relationship.originalName,
                        declaringEntityName: relationship.declaringEntityName))
            } else {
                resolved = candidate.resolved(with: relationship)
            }
            adapters.append(
                candidate.ownerType == ObjectIdentifier(modelType)
                    ? resolved
                    : ReownedRelationshipAdapterBox(resolved, ownerType: ObjectIdentifier(modelType)))
        }
        for property in metadata {
            guard let keyPath = property.keypath else { continue }
            let rawType = String(reflecting: type(of: keyPath).valueType)
            let destination = Self.relationshipDestination(rawType)
            guard property.metadata?.base is SchemaDescriptor.Relationship else { continue }
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

    /// Deletes all persistent data owned by this container, ignoring failures.
    @available(*, deprecated, renamed: "erase", message: "deleteAllData has been replaced by `erase`.")
    public func deleteAllData() {
        try? erase()
    }

    /// Removes every model, relationship, and history record from the container's store.
    ///
    /// The store file remains and stays open, and contexts keep their pending changes. Primary keys continue
    /// from where they were, so identifiers held from before the erase never match new models.
    public func erase() throws {
        guard let store else {
            throw SwiftDataError.unsupportedStore("Erasing the store is unavailable without a persistent store.")
        }
        let preserved: Set<String> = ["_osd_meta", "_osd_primary_keys"]
        try store.write { connection in
            let tables = try connection.rows(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'", arguments: [])
            for row in tables {
                guard case let .text(name)? = row.first, !preserved.contains(name) else { continue }
                try connection.execute("DELETE FROM \"\(name)\"", arguments: [])
            }
        }
    }

    private static func openStore(schema: SchemaDescriptor, configurations: [ModelConfiguration]) throws -> (any RuntimeStore)? {
        guard !configurations.isEmpty else { return nil }
        guard configurations.count == 1, let configuration = configurations.first else {
            throw SwiftDataError.unsupportedStore("Exactly one store configuration is supported.")
        }
        try configuration.validate()
        guard configuration.cloudKitDatabase.privateDatabaseName == nil else {
            throw SwiftDataError.unsupportedStore("CloudKit stores are not supported.")
        }
        if configuration.dataStoreConfiguration != nil || configuration.appleDataStoreConfiguration != nil { return nil }
        guard let factory = configuration.storeFactory else {
            throw SwiftDataError.unsupportedStore("The configured store backend/provider is unavailable.")
        }
        if !configuration.isStoredInMemoryOnly {
            try FileManager.default.createDirectory(
                at: configuration.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        return try factory(storeLocation(for: configuration), schema)
    }

    private static func validateDataStoreInheritanceSupport(
        schema: SchemaDescriptor, dataStore: (any DataStore)?
    ) throws {
        guard schema.entities.contains(where: { $0.superentityName != nil }),
            let dataStore,
            !dataStore.supportsInheritance
        else { return }
        throw SwiftDataError.unsupportedStore(
            "The configured DataStore does not support model inheritance.")
    }

    private static func runtimeSchema(requested: SchemaDescriptor, store: (any RuntimeStore)?) throws -> SchemaDescriptor {
        guard let provider = store as? any RuntimeSchemaProvidingStore else { return requested }
        let resolved = provider.runtimeSchema
        guard resolved.entities == requested.entities, resolved.version == requested.version
        else {
            throw SwiftDataError.unsupportedStore(
                "The runtime store returned a schema incompatible with the requested model types.")
        }
        return resolved
    }

    private static func openDataStore(
        schema: SchemaDescriptor,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
        configurations: [ModelConfiguration]
    ) throws -> (any DataStore)? {
        guard configurations.contains(where: {
            $0.dataStoreConfiguration != nil || $0.appleDataStoreConfiguration != nil
        }) else { return nil }
        guard configurations.count == 1, let configuration = configurations.first else {
            throw SwiftDataError.unsupportedStore("Exactly one custom DataStore configuration is supported.")
        }
        if let appleConfiguration = configuration.appleDataStoreConfiguration {
            guard configuration.dataStoreConfiguration == nil,
                configuration.cloudKitDatabase.privateDatabaseName == nil,
                configuration.storeFactory == nil,
                configuration.schemaVersionReader == nil,
                !configuration.isStoredInMemoryOnly
            else {
                throw SwiftDataError.unsupportedStore(
                    "AppleDataStore configurations cannot be combined with another backend.")
            }
            try appleConfiguration.validate()
            let store = try appleConfiguration.makeStore(
                schema: configuration.schema ?? schema, migrationPlan: migrationPlan)
            guard store.schema == configuration.schema ?? schema else {
                throw SwiftDataError.unsupportedStore("AppleDataStore schema does not match the configured schema.")
            }
            guard let bridge = store as? any AppleDataStoreBackendProviding else {
                throw SwiftDataError.unsupportedStore(
                    "The configured AppleDataStore does not provide the OpenSwiftData backend bridge.")
            }
            return try bridge.makeBackend(schema: schema, migrationPlan: migrationPlan)
        }
        guard let dataStoreConfiguration = configuration.dataStoreConfiguration else { return nil }
        guard configuration.cloudKitDatabase.privateDatabaseName == nil,
            configuration.storeFactory == nil, configuration.schemaVersionReader == nil,
            !configuration.isStoredInMemoryOnly
        else {
            throw SwiftDataError.unsupportedStore(
                "Custom DataStore configurations cannot be combined with another backend.")
        }
        return try dataStoreConfiguration.makeStore(schema: schema)
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

    private static func relationshipDeclaringEntityName(
        modelType: any PersistentModel.Type, metadata: SchemaDescriptor.PropertyMetadata
    ) -> String? {
        guard let keyPath = metadata.keypath else { return nil }
        var declaringType = modelType
        var visited: Set<ObjectIdentifier> = [ObjectIdentifier(modelType)]
        while let parent = declaringType.parentModel,
            visited.insert(ObjectIdentifier(parent)).inserted,
            parent.schemaMetadata().contains(where: { $0.name == metadata.name && $0.keypath == keyPath })
        {
            declaringType = parent
        }
        guard ObjectIdentifier(declaringType) != ObjectIdentifier(modelType) else { return nil }
        return unqualifiedTypeName(String(describing: declaringType))
    }

    private static func effectiveProperties(
        _ properties: [(SchemaDescriptor.PropertyMetadata, AnyKeyPath)]
    ) -> [(SchemaDescriptor.PropertyMetadata, AnyKeyPath)] {
        var lastIndexByName: [String: Int] = [:]
        for (index, property) in properties.enumerated() { lastIndexByName[property.0.name] = index }
        return properties.enumerated().compactMap { index, property in
            lastIndexByName[property.0.name] == index ? property : nil
        }
    }

    private static func effectiveRelationships(_ relationships: [SchemaDescriptor.Relationship]) -> [SchemaDescriptor.Relationship] {
        var lastIndexByName: [String: Int] = [:]
        for (index, relationship) in relationships.enumerated() { lastIndexByName[relationship.name] = index }
        return relationships.enumerated().compactMap { index, relationship in
            lastIndexByName[relationship.name] == index ? relationship : nil
        }
    }

    private static func relationshipProperties(
        entityName: String,
        among types: [any PersistentModel.Type],
        effectivePropertiesByEntity: [String: [(SchemaDescriptor.PropertyMetadata, AnyKeyPath)]]
    ) -> [(SchemaDescriptor.PropertyMetadata, SchemaDescriptor.Relationship)] {
        types
            .filter { candidate in
                let candidateName = unqualifiedTypeName(String(describing: candidate))
                return candidateName == entityName
                    || isAncestorModel(entityName, of: candidateName, among: types)
            }
            .flatMap { candidate in
                effectivePropertiesByEntity[unqualifiedTypeName(String(describing: candidate))] ?? []
            }
            .compactMap { property, _ in
                guard let relationship = property.metadata?.base as? SchemaDescriptor.Relationship else { return nil }
                return (property, relationship)
            }
    }

    package static func relationshipProperties(
        entityName: String, among types: [any PersistentModel.Type]
    ) -> [(SchemaDescriptor.PropertyMetadata, SchemaDescriptor.Relationship)] {
        let effectivePropertiesByEntity = Dictionary(
            uniqueKeysWithValues: types.map { modelType in
                let name = unqualifiedTypeName(String(describing: modelType))
                let properties = modelType.schemaMetadata().compactMap { metadata in
                    metadata.keypath.map { (metadata, $0) }
                }
                return (name, effectiveProperties(properties))
            })
        return relationshipProperties(
            entityName: entityName,
            among: types,
            effectivePropertiesByEntity: effectivePropertiesByEntity)
    }

    package static func inferredInverseName(
        relationshipName: String,
        destinationName: String,
        logicalOwnerName: String,
        among types: [any PersistentModel.Type],
        effectivePropertiesByEntity: [String: [(SchemaDescriptor.PropertyMetadata, AnyKeyPath)]]
    ) throws -> String? {
        let candidateProperties = relationshipProperties(
            entityName: destinationName,
            among: types,
            effectivePropertiesByEntity: effectivePropertiesByEntity)
        var inverseNamesByDeclaration: [String: String] = [:]
        for (property, relationship) in candidateProperties where relationship.inverse == relationshipName {
            let rawType = property.keypath.map { String(reflecting: type(of: $0).valueType) } ?? ""
            let (normalizedType, _) = normalizedPropertyType(rawType)
            let parsedType = parseType(normalizedType)
            let inverseDestination = unqualifiedTypeName(
                parsedType.collectionElement ?? parsedType.name)
            guard
                relationshipDestination(
                    inverseDestination, matchesLogicalOwner: logicalOwnerName, among: types)
            else { continue }
            let declarationName = relationship.declaringEntityName ?? destinationName
            inverseNamesByDeclaration["\(declarationName).\(property.name)"] = property.name
        }
        guard inverseNamesByDeclaration.count <= 1 else {
            throw SwiftDataError.unsupportedSchemaProperty(
                "Relationship '\(logicalOwnerName).\(relationshipName)' has ambiguous inverse candidates.")
        }
        return inverseNamesByDeclaration.values.first
    }

    package static func inferredInverseName(
        relationshipName: String,
        destinationName: String,
        logicalOwnerName: String,
        among types: [any PersistentModel.Type]
    ) throws -> String? {
        let effectivePropertiesByEntity = Dictionary(
            uniqueKeysWithValues: types.map { modelType in
                let entityName = unqualifiedTypeName(String(describing: modelType))
                let properties = modelType.schemaMetadata().compactMap { metadata in
                    metadata.keypath.map { (metadata, $0) }
                }
                return (entityName, effectiveProperties(properties))
            })
        return try inferredInverseName(
            relationshipName: relationshipName,
            destinationName: destinationName,
            logicalOwnerName: logicalOwnerName,
            among: types,
            effectivePropertiesByEntity: effectivePropertiesByEntity)
    }

    private static func properties(
        named propertyName: String,
        onOrBelow entityName: String,
        among types: [any PersistentModel.Type],
        effectivePropertiesByEntity: [String: [(SchemaDescriptor.PropertyMetadata, AnyKeyPath)]]
    ) -> [(SchemaDescriptor.PropertyMetadata, AnyKeyPath)] {
        types
            .filter { candidate in
                let candidateName = unqualifiedTypeName(String(describing: candidate))
                return candidateName == entityName
                    || isAncestorModel(entityName, of: candidateName, among: types)
            }
            .compactMap { candidate in
                effectivePropertiesByEntity[unqualifiedTypeName(String(describing: candidate))]?.first {
                    $0.0.name == propertyName
                }
            }
    }

    private static func isAncestorModel(
        _ ancestorName: String, of modelName: String, among types: [any PersistentModel.Type]
    ) -> Bool {
        let typesByName = Dictionary(
            uniqueKeysWithValues: types.map { (unqualifiedTypeName(String(describing: $0)), $0) })
        var current = typesByName[modelName]
        var visited = Set<String>()
        while let model = current, let parent = model.parentModel {
            let parentName = unqualifiedTypeName(String(describing: parent))
            guard visited.insert(parentName).inserted else { return false }
            if parentName == ancestorName { return true }
            current = typesByName[parentName]
        }
        return false
    }

    package static func relationshipDestination(
        _ destinationName: String, matchesLogicalOwner ownerName: String,
        among types: [any PersistentModel.Type]
    ) -> Bool {
        destinationName == ownerName || isAncestorModel(destinationName, of: ownerName, among: types)
    }

    private static func modelTypesIncludingAncestors(
        of requestedTypes: [any PersistentModel.Type]
    ) -> [any PersistentModel.Type] {
        var ordered: [any PersistentModel.Type] = []
        var visited = Set<ObjectIdentifier>()
        func append(_ type: any PersistentModel.Type) {
            guard visited.insert(ObjectIdentifier(type)).inserted else { return }
            if let parent = type.parentModel { append(parent) }
            ordered.append(type)
        }
        for type in requestedTypes { append(type) }
        return ordered
    }

    private static func unqualifiedTypeName(_ type: String) -> String {
        type.split(separator: ".").last.map(String.init) ?? type
    }

    private static func normalizedTypeName(_ type: String) -> String {
        // Newer Apple SDKs bridge `Decimal` to the imported C struct `NSDecimal` at runtime.
        type.replacingOccurrences(of: "Swift.", with: "")
            .replacingOccurrences(of: "__C.NSDecimal", with: "Decimal")
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

    private static func attributeOption(_ option: String) -> SchemaDescriptor.Attribute.Option? {
        switch option {
        case "unique": .unique
        case "externalStorage": .externalStorage
        case "encrypt": .encrypt
        case "preserveValueOnDeletion": .preserveValueOnDeletion
        case "spotlight": .spotlight
        case "allowsCloudEncryption": .allowsCloudEncryption
        case "ephemeral": .ephemeral
        case "codable": .codable
        case "flattened": .flattened
        default: nil
        }
    }

}

/// Holds a container's lazily created main context on the main actor.
@MainActor
private final class MainContextStorage {
    var context: ModelContext?

    nonisolated init() {}
}

/// Holds a container's migration plan, written once while the container initializes.
private final class MigrationPlanStorage: @unchecked Sendable {
    var plan: (any SchemaMigrationPlan.Type)?
}

extension ModelContainer: Equatable {
    /// Returns whether both operands are the same container instance.
    public static func == (lhs: ModelContainer, rhs: ModelContainer) -> Bool { lhs === rhs }
}
