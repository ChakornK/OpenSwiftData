import Foundation

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

    init<Model: PersistentModel>(type: Model.Type) {
        self.type = type
        materializeBody = { context, entity, attributes, row, storeIdentifier, entityID, primaryKey, version in
            let backing = ManagedBackingData<Model>(
                metadata: Model.schemaMetadata(), values: [:], context: context,
                storeIdentifier: storeIdentifier, entityID: entityID, primaryKey: primaryKey, version: version,
                identifier: PersistentIdentifier(
                    storeIdentifier: storeIdentifier, entityName: entity.name, primaryKey: primaryKey))
            let model = Model(backingData: backing)
            let adapters = Model.persistenceAdapters()
            var columnIndex = 2
            for attribute in attributes {
                if attribute.options.contains(.flattened) {
                    let flattened = Model.flattenedPropertyAdapters().filter { $0.propertyName == attribute.name }
                        .sorted { $0.componentName.utf8.lexicographicallyPrecedes($1.componentName.utf8) }
                    guard let first = flattened.first else { continue }
                    var composite = try first.makeEmptyComposite()
                    for component in flattened {
                        guard columnIndex < row.count else { break }
                        composite = try component.decoded(storedValue(row[columnIndex]), into: composite)
                        columnIndex += 1
                    }
                    try first.assign(composite, to: model)
                } else if columnIndex < row.count,
                    let adapter = adapters.first(where: { $0.name == attribute.name })
                {
                    try adapter.decode(storedValue(row[columnIndex]), into: model)
                    columnIndex += 1
                } else {
                    columnIndex += 1
                }
            }
            backing.markSaved()
            backing.attach(to: context, model: model)
            return model
        }
        relationshipFaultBody = { model, entity, resolver in
            guard let model = model as? Model,
                let backing = model.persistentBackingData as? ManagedBackingData<Model>
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
                let backing = model.persistentBackingData as? ManagedBackingData<Model>
            else { return nil }
            return backing.valueState(forKey: keyPath)
        }
        setMaterializedValueBody = { model, keyPath, value in
            guard let model = model as? Model,
                let backing = model.persistentBackingData as? ManagedBackingData<Model>
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

private func storedValue(_ value: RuntimeValue) -> StoredValue {
    switch value {
    case .null: .null
    case let .int(value): .int(value)
    case let .double(value): .double(value)
    case let .text(value): .text(value)
    case let .blob(value): .blob(value)
    }
}
