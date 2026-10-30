import Foundation
import OSDCore

// Registrations hold immutable model metatypes and factories; model instances are created per request.
struct ModelTypeRegistration: @unchecked Sendable {
    let type: any PersistentModel.Type
    private let materializeBody:
        (
            ModelContext, Schema.Entity, [Schema.Attribute], [RuntimeValue], String, Int, Int64, Int
        ) throws -> any PersistentModel
    private let relationshipFaultBody: (any PersistentModel, Schema.Entity, RelationshipFaultResolver) -> Void
    private let valueStateBody: (any PersistentModel, AnyKeyPath) -> ManagedValueState?
    private let setMaterializedValueBody: (any PersistentModel, AnyKeyPath, Any) -> Void
    private let materializeDataStoreBody: (ModelContext, Schema.Entity, DataStoreSnapshot) throws -> any PersistentModel
    private let assignDataStoreRelationshipsBody: (any PersistentModel, [String: [any PersistentModel]]) throws -> Void
    private let applyDataStoreValuesBody: (any PersistentModel, Schema.Entity, DataStoreSnapshot) throws -> Void

    init<Model: PersistentModel>(type: Model.Type) {
        self.type = type
        materializeBody = { context, entity, attributes, row, storeIdentifier, entityID, primaryKey, version in
            let backing = ManagedBackingData<Model.Model>(
                metadata: Model.schemaMetadata(), values: [:], context: context,
                storeIdentifier: storeIdentifier, entityID: entityID, primaryKey: primaryKey, version: version,
                identifier: PersistentIdentifier(
                    storeIdentifier: storeIdentifier, entityName: entity.name, primaryKey: primaryKey))
            let model = Model(backingData: backing)
            let adapters = Model.erasedPersistenceAdapters()
            var selectedValues: [String: StoredValue] = [:]
            var columnIndex = 2
            for attribute in attributes {
                if attribute.options.contains(.flattened) {
                    for component in attribute.components {
                        guard columnIndex < row.count else { break }
                        selectedValues[component.columnName] = storedValue(row[columnIndex])
                        columnIndex += 1
                    }
                } else if columnIndex < row.count {
                    selectedValues[attribute.name] = storedValue(row[columnIndex])
                    columnIndex += 1
                } else {
                    break
                }
            }
            for metadata in Model.schemaMetadata() where attributes.contains(where: { $0.name == metadata.name }) {
                if let attribute = attributes.first(where: { $0.name == metadata.name }),
                    attribute.options.contains(.flattened)
                {
                    let flattened = Model.flattenedPropertyAdapters().filter { $0.propertyName == attribute.name }
                        .sorted { $0.componentName.utf8.lexicographicallyPrecedes($1.componentName.utf8) }
                    guard let first = flattened.first else { continue }
                    var composite = try first.makeEmptyComposite()
                    for component in flattened {
                        guard let value = selectedValues[component.columnName] else { continue }
                        composite = try component.decoded(value, into: composite)
                    }
                    try first.assign(composite, to: model)
                } else if let adapter = adapters.first(where: { $0.name == metadata.name }),
                    let value = selectedValues[metadata.name]
                {
                    try adapter.decode(value, into: model)
                }
            }
            backing.markSaved()
            backing.attach(to: context, model: model)
            return model
        }
        materializeDataStoreBody = { context, entity, snapshot in
            let metadata = Model.schemaMetadata()
            var values: [AnyKeyPath: Any] = [:]
            let propertyAdapters = Model.erasedPersistenceAdapters()
            for attribute in entity.attributes where !attribute.options.contains(.flattened) {
                guard let keyPath = metadata.first(where: { $0.name == attribute.name })?.keypath,
                    let value = snapshot.values[attribute.name],
                    let adapter = propertyAdapters.first(where: { $0.name == attribute.name })
                else {
                    throw SwiftDataError.unsupportedStore(
                        "DataStore snapshot is missing value for \(entity.name).\(attribute.name).")
                }
                values[keyPath] = try adapter.decoded(value)
            }
            let flattenedAdapters = Model.flattenedPropertyAdapters()
            for attribute in entity.attributes where attribute.options.contains(.flattened) {
                let components = flattenedAdapters.filter { $0.propertyName == attribute.name }
                    .sorted { $0.componentName.utf8.lexicographicallyPrecedes($1.componentName.utf8) }
                guard let first = components.first,
                    let keyPath = metadata.first(where: { $0.name == attribute.name })?.keypath
                else {
                    throw SwiftDataError.unsupportedStore(
                        "DataStore has no flattened adapters for \(entity.name).\(attribute.name).")
                }
                var composite = try first.makeEmptyComposite()
                for component in components {
                    guard let value = snapshot.values[component.columnName] else {
                        throw SwiftDataError.unsupportedStore(
                            "DataStore snapshot is missing flattened value \(entity.name).\(component.columnName).")
                    }
                    composite = try component.decoded(value, into: composite)
                }
                values[keyPath] = composite
            }
            let identifier = snapshot.persistentIdentifier
            let backing = ManagedBackingData<Model.Model>(
                metadata: metadata, values: values, context: context,
                storeIdentifier: identifier.storeIdentifier,
                entityID: context.container?.schema.entityIDsByName[entity.name] ?? 0,
                primaryKey: identifier.primaryKey, version: 0, identifier: identifier)
            let model = Model(backingData: backing)
            backing.markSaved()
            backing.attach(to: context, model: model)
            return model
        }
        assignDataStoreRelationshipsBody = { model, relationships in
            guard let model = model as? Model else {
                throw SwiftDataError.unsupportedStore("DataStore relationship owner type mismatch.")
            }
            for adapter in relationshipAdapters(for: Model.self) {
                guard let endpoints = relationships[adapter.name] else {
                    throw SwiftDataError.unsupportedStore("DataStore snapshot is missing relationship \(adapter.name).")
                }
                try adapter.assign(try adapter.makeValue(endpoints), to: model)
            }
        }
        applyDataStoreValuesBody = { model, entity, snapshot in
            guard let model = model as? Model else {
                throw SwiftDataError.unsupportedStore("DataStore snapshot model type mismatch.")
            }
            let backing = model.anyBackingData
            let metadata = Model.schemaMetadata()
            let adapters = Model.erasedPersistenceAdapters()
            for attribute in entity.attributes where !attribute.options.contains(.flattened) {
                guard let keyPath = metadata.first(where: { $0.name == attribute.name })?.keypath,
                    let value = snapshot.values[attribute.name],
                    let adapter = adapters.first(where: { $0.name == attribute.name })
                else {
                    throw SwiftDataError.unsupportedStore(
                        "DataStore snapshot is missing value for \(entity.name).\(attribute.name).")
                }
                backing.setMaterializedValueIfNoOverlay(forKeyPath: keyPath, to: try adapter.decoded(value))
            }
            let flattened = Model.flattenedPropertyAdapters()
            for attribute in entity.attributes where attribute.options.contains(.flattened) {
                let components = flattened.filter { $0.propertyName == attribute.name }
                    .sorted { $0.componentName.utf8.lexicographicallyPrecedes($1.componentName.utf8) }
                guard let first = components.first,
                    let keyPath = metadata.first(where: { $0.name == attribute.name })?.keypath
                else {
                    throw SwiftDataError.unsupportedStore("DataStore lacks flattened adapters for \(attribute.name).")
                }
                var composite = try first.makeEmptyComposite()
                for component in components {
                    guard let value = snapshot.values[component.columnName] else {
                        throw SwiftDataError.unsupportedStore(
                            "DataStore snapshot lacks component \(component.columnName).")
                    }
                    composite = try component.decoded(value, into: composite)
                }
                backing.setMaterializedValueIfNoOverlay(forKeyPath: keyPath, to: composite)
            }
            model.persistentBackingData.markSaved()
        }
        relationshipFaultBody = { model, entity, resolver in
            guard let model = model as? Model,
                let backing = model.persistentBackingData as? ManagedBackingData<Model.Model>
            else { return }
            let keyPaths = Set(
                Model.schemaMetadata().compactMap { metadata in
                    entity.relationships.contains(where: { $0.name == metadata.name }) && metadata.isRelationship
                        ? metadata.keypath : nil
                })
            backing.installRelationshipFaults(keyPaths) { [weak model, weak resolver] keyPath in
                guard let model, let resolver else {
                    throw SwiftDataError.unsupportedStore("Relationship fault resolver is no longer available")
                }
                return try resolver.resolve(owner: model, keyPath: keyPath)
            }
        }
        valueStateBody = { model, keyPath in
            guard let model = model as? Model,
                let backing = model.persistentBackingData as? ManagedBackingData<Model.Model>
            else { return nil }
            return backing.valueState(forKey: keyPath)
        }
        setMaterializedValueBody = { model, keyPath, value in
            guard let model = model as? Model,
                let backing = model.persistentBackingData as? ManagedBackingData<Model.Model>
            else { return }
            backing.setMaterializedValueIfNoOverlay(forKey: keyPath, to: value)
        }
    }

    func materialize(
        context: ModelContext,
        entity: Schema.Entity,
        attributes: [Schema.Attribute],
        row: [RuntimeValue],
        storeIdentifier: String,
        entityID: Int,
        primaryKey: Int64,
        version: Int
    ) throws -> any PersistentModel {
        try materializeBody(context, entity, attributes, row, storeIdentifier, entityID, primaryKey, version)
    }

    func materializeDataStore(
        context: ModelContext, entity: Schema.Entity, snapshot: DataStoreSnapshot
    ) throws -> any PersistentModel {
        try materializeDataStoreBody(context, entity, snapshot)
    }

    func assignDataStoreRelationships(
        on model: any PersistentModel, relationships: [String: [any PersistentModel]]
    ) throws {
        try assignDataStoreRelationshipsBody(model, relationships)
    }

    func applyDataStoreValues(
        on model: any PersistentModel, entity: Schema.Entity, snapshot: DataStoreSnapshot
    ) throws {
        try applyDataStoreValuesBody(model, entity, snapshot)
    }

    func installRelationshipFaults(
        on model: any PersistentModel,
        entity: Schema.Entity,
        resolver: RelationshipFaultResolver
    ) {
        relationshipFaultBody(model, entity, resolver)
    }

    func valueState(on model: any PersistentModel, keyPath: AnyKeyPath) -> ManagedValueState? {
        valueStateBody(model, keyPath)
    }

    func setMaterializedValue(on model: any PersistentModel, keyPath: AnyKeyPath, value: Any) {
        setMaterializedValueBody(model, keyPath, value)
    }
}

private func relationshipAdapters<Model: PersistentModel>(for type: Model.Type) -> [any AnyRelationshipAdapterBox] {
    guard let modelType = type as? any RelationshipModel.Type else { return [] }
    return modelType.relationshipAdapterCandidates() + modelType.inferredRelationshipAdapterCandidates()
}

private func storedValue(_ value: RuntimeValue) -> StoredValue {
    switch value {
    case .null: .null
    case let .int(value): .int(value)
    case let .double(value): .double(value)
    case let .text(value): .text(value)
    case let .blob(value): .blob(value)
    }
}
