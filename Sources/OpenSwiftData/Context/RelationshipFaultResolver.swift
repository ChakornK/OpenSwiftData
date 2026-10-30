import Foundation
import OSDCore

final class WeakModelContext: @unchecked Sendable {
    private let lock = NSLock()
    weak var value: ModelContext?

    init(_ value: ModelContext) {
        self.value = value
    }

    func load() -> ModelContext? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class RelationshipFaultResolver: @unchecked Sendable {
    private let context: WeakModelContext
    private let container: ModelContainer
    private let state: ContextState
    private let identityMap: IdentityMap
    private let store: any RuntimeStore
    private let schema: Schema
    private let storeIdentifier: String

    init(context: ModelContext, container: ModelContainer, state: ContextState, identityMap: IdentityMap) throws {
        guard let store = container.store else { throw SwiftDataError.unsupportedStore("Relationship fault") }
        self.context = WeakModelContext(context)
        self.container = container
        self.state = state
        self.identityMap = identityMap
        self.store = store
        schema = container.schema
        storeIdentifier = container.configurations.first?.name ?? "default"
    }

    func install<Model: PersistentModel>(on model: Model, entity: Schema.Entity) {
        guard let backing = model.persistentBackingData as? ManagedBackingData<Model> else { return }
        let adapterNames = Set(container.relationshipAdapterTable[ObjectIdentifier(Model.self)]?.map(\.name) ?? [])
        let names = Set(entity.relationships.map(\.name)).intersection(adapterNames)
        let keyPaths = Set(
            Model.schemaMetadata().compactMap { metadata in
                names.contains(metadata.name) && metadata.isRelationship ? metadata.keypath : nil
            })
        backing.installRelationshipFaults(keyPaths) { [weak self, weak model] keyPath in
            guard let self, let model else {
                throw SwiftDataError.unsupportedStore("Relationship fault owner or resolver no longer exists")
            }
            return try self.resolve(owner: model, keyPath: keyPath)
        }
    }

    func resolve<Model: PersistentModel>(owner: Model, keyPath: AnyKeyPath) throws -> Any {
        guard let entity = schema.entity(forName: String(describing: Model.self)),
            let metadata = Model.schemaMetadata().first(where: { $0.keypath == keyPath }),
            let relationship = entity.relationships.first(where: { $0.name == metadata.name }),
            let adapter = container.relationshipAdapterTable[ObjectIdentifier(Model.self)]?.first(where: {
                $0.name == relationship.name
            })
        else {
            throw SwiftDataError.unsupportedSchemaProperty("Unable to resolve lazy relationship metadata")
        }

        let ownerID = owner.persistentModelID
        let persistedIDs =
            try ownerID.primaryKey.map { ownerPK in
                try persistedEndpointIDs(
                    ownerEntity: entity, relationship: relationship, ownerPrimaryKey: ownerPK
                )
                .map {
                    PersistentIdentifier(
                        storeIdentifier: storeIdentifier, entityName: relationship.destination, primaryKey: $0)
                }
            } ?? []
        var endpointIDs = persistedIDs

        let pending = state.pendingState()
        let deletedIDs = Set(pending.deleted.map(\.persistentModelID))
        for event in pending.relationshipMutationEvents {
            if event.owner.persistentModelID == ownerID, event.property == relationship.name {
                endpointIDs = event.newEndpointIDs
            } else if let inverseName = relationship.inverse,
                event.property == inverseName,
                event.relationship.inverse == relationship.name
            {
                let touchesOwner = event.oldEndpointIDs.contains(ownerID) || event.newEndpointIDs.contains(ownerID)
                guard touchesOwner else { continue }
                let otherID = event.owner.persistentModelID
                let wasRelated = event.oldEndpointIDs.contains(ownerID)
                let isRelated = event.newEndpointIDs.contains(ownerID)
                if wasRelated && !isRelated {
                    endpointIDs.removeAll { $0 == otherID }
                } else if isRelated && !wasRelated {
                    if !endpointIDs.contains(otherID) { endpointIDs.append(otherID) }
                }
            }
        }
        endpointIDs.removeAll { deletedIDs.contains($0) }

        let pendingModels = pending.inserted + pending.changed
        var endpointModels: [any PersistentModel] = []
        for identifier in endpointIDs {
            if let pendingModel = pendingModels.first(where: { $0.persistentModelID == identifier }) {
                endpointModels.append(pendingModel)
                continue
            }
            guard let primaryKey = identifier.primaryKey,
                let model = try loadModel(entityName: relationship.destination, primaryKey: primaryKey)
            else {
                throw SwiftDataError.unsupportedStore(
                    "Relationship '\(entity.name).\(relationship.name)' references missing destination \(identifier).")
            }
            endpointModels.append(model)
        }
        let value = try adapter.makeValue(endpointModels)
        assign(value, keyPath: keyPath, to: owner)

        if let inverseName = relationship.inverse {
            let finalIDs = Set(endpointIDs)
            let affectedIDs = Set(persistedIDs + endpointIDs)
            let deletedModelIDs = Set(pending.deleted.map(ObjectIdentifier.init))
            for identifier in affectedIDs where !deletedIDs.contains(identifier) {
                let endpoint: any PersistentModel
                if let pendingModel = pendingModels.first(where: { $0.persistentModelID == identifier }) {
                    endpoint = pendingModel
                } else if let primaryKey = identifier.primaryKey,
                    let loaded = try loadModel(entityName: relationship.destination, primaryKey: primaryKey)
                {
                    endpoint = loaded
                } else {
                    continue
                }
                guard !deletedModelIDs.contains(ObjectIdentifier(endpoint)) else { continue }
                guard
                    let inverseKeyPath = type(of: endpoint).schemaMetadata().first(where: { $0.name == inverseName })?
                        .keypath,
                    let inverseAdapter = container.relationshipAdapterTable[ObjectIdentifier(type(of: endpoint))]?
                        .first(where: {
                            $0.name == inverseName
                        })
                else { continue }
                guard let registration = container.modelRegistration(forEntityName: relationship.destination),
                    case let .baseline(existingValue)? = registration.valueState(on: endpoint, keyPath: inverseKeyPath)
                else { continue }
                let existing = try inverseAdapter.endpoints(in: existingValue)
                let isRelated = finalIDs.contains(identifier)
                let related: [any PersistentModel]
                if inverseAdapter.isToMany {
                    if isRelated {
                        related =
                            existing.contains(where: { $0.persistentModelID == ownerID })
                            ? existing : existing + [owner]
                    } else {
                        related = existing.filter { $0.persistentModelID != ownerID }
                    }
                } else if isRelated {
                    related =
                        existing.isEmpty || existing.contains(where: { $0.persistentModelID == ownerID })
                        ? [owner] : existing
                } else {
                    related = existing.filter { $0.persistentModelID != ownerID }
                }
                let inverseValue = try inverseAdapter.makeValue(related)
                registration.setMaterializedValue(on: endpoint, keyPath: inverseKeyPath, value: inverseValue)
            }
        }
        return value
    }

    private func persistedEndpointIDs(
        ownerEntity: Schema.Entity,
        relationship: Schema.Relationship,
        ownerPrimaryKey: Int64
    ) throws -> [Int64] {
        guard let destination = schema.entity(forName: relationship.destination) else {
            throw SwiftDataError.unsupportedSchemaProperty("Missing relationship destination entity")
        }
        if !relationship.isToMany, isToOneStorageOwner(ownerEntity, relationship, destination: destination) {
            return try store.read { connection in
                guard
                    let row = try connection.rows(
                        "SELECT Z\(relationship.name.uppercased()) FROM Z\(ownerEntity.name.uppercased()) WHERE Z_PK = ?",
                        arguments: [.int(ownerPrimaryKey)]
                    ).first,
                    case let .int(primaryKey)? = row.first
                else { return [] }
                return [primaryKey]
            }
        }
        if relationship.isToMany, let inverseName = relationship.inverse,
            let inverse = destination.relationships.first(where: { $0.name == inverseName }), !inverse.isToMany
        {
            return try store.read { connection in
                try connection.rows(
                    "SELECT Z_PK FROM Z\(destination.name.uppercased()) WHERE Z\(inverseName.uppercased()) = ? ORDER BY Z_PK ASC",
                    arguments: [.int(ownerPrimaryKey)]
                ).compactMap { row in
                    guard case let .int(primaryKey)? = row.first else { return nil }
                    return primaryKey
                }
            }
        }
        if relationship.isToMany, let table = joinTableName(ownerEntity, relationship, destination: destination) {
            let sideAOwner = joinSideAOwner(ownerEntity, relationship, destination: destination)
            let ownerColumn = sideAOwner ? "Z_A" : "Z_B"
            let endpointColumn = sideAOwner ? "Z_B" : "Z_A"
            return try store.read { connection in
                try connection.rows(
                    "SELECT \(endpointColumn) FROM \(table) WHERE \(ownerColumn) = ? ORDER BY \(endpointColumn) ASC",
                    arguments: [.int(ownerPrimaryKey)]
                ).compactMap { row in
                    guard case let .int(primaryKey)? = row.first else { return nil }
                    return primaryKey
                }
            }
        }
        guard let inverseName = relationship.inverse else { return [] }
        return try store.read { connection in
            try connection.rows(
                "SELECT Z_PK FROM Z\(destination.name.uppercased()) WHERE Z\(inverseName.uppercased()) = ? ORDER BY Z_PK ASC",
                arguments: [.int(ownerPrimaryKey)]
            ).compactMap { row in
                guard case let .int(primaryKey)? = row.first else { return nil }
                return primaryKey
            }
        }
    }

    private func loadModel(entityName: String, primaryKey: Int64) throws -> (any PersistentModel)? {
        guard let entity = schema.entity(forName: entityName),
            let registration = container.modelRegistration(forEntityName: entityName),
            let context = context.load()
        else { return nil }
        func load<Model: PersistentModel>(_ type: Model.Type) throws -> Model? {
            let key = EntityPrimaryKey(entityName: entityName, primaryKey: primaryKey)
            if let existing = identityMap.model(for: key, as: Model.self) { return existing }
            let attributes = entity.attributes.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
            let columns = attributes.flatMap { attribute in
                attribute.options.contains(.flattened)
                    ? attribute.components.map(\.columnName) : [attribute.name]
            }.map { "Z\($0.uppercased())" }.joined(separator: ", ")
            let selected = (["Z_PK", "Z_OPT"] + (columns.isEmpty ? [] : [columns])).joined(separator: ", ")
            guard
                let row = try store.read({ connection in
                    try connection.rows(
                        "SELECT \(selected) FROM Z\(entityName.uppercased()) WHERE Z_PK = ?",
                        arguments: [.int(primaryKey)])
                }).first
            else { return nil }
            let candidate =
                try registration.materialize(
                    context: context, entity: entity, attributes: attributes, row: row,
                    storeIdentifier: storeIdentifier, entityID: entityID(for: entityName),
                    primaryKey: primaryKey, version: row.count > 1 ? runtimeInt(row[1]) : 0) as? Model
            guard let candidate else { return nil }
            registration.installRelationshipFaults(on: candidate, entity: entity, resolver: self)
            return identityMap.canonicalHandle(for: key, candidate: candidate).model as? Model
        }
        return try load(registration.type)
    }

    private func installFaultsOnRelatedModel(_ model: any PersistentModel, entity: Schema.Entity) {
        guard let registration = container.modelRegistration(forEntityName: entity.name) else { return }
        registration.installRelationshipFaults(on: model, entity: entity, resolver: self)
    }

    private func assign(_ value: Any, keyPath: AnyKeyPath, to model: any PersistentModel) {
        func assign<Model: PersistentModel>(_ model: Model) {
            guard let backing = model.persistentBackingData as? ManagedBackingData<Model> else { return }
            backing.setMaterializedValue(forKey: keyPath, to: value)
        }
        assign(model)
    }

    private func entityID(for name: String) -> Int {
        schema.entityIDsByName[name] ?? 0
    }

    private func runtimeInt(_ value: RuntimeValue) -> Int {
        if case let .int(number) = value { return Int(number) }
        return 0
    }

    private func isToOneStorageOwner(
        _ entity: Schema.Entity,
        _ relationship: Schema.Relationship,
        destination: Schema.Entity
    ) -> Bool {
        guard let inverseName = relationship.inverse,
            let inverse = destination.relationships.first(where: { $0.name == inverseName }), !inverse.isToMany
        else { return true }
        return "\(entity.name).\(relationship.name)".utf8.lexicographicallyPrecedes(
            "\(destination.name).\(inverse.name)".utf8)
    }

    private func isCanonicalSideA(
        _ entity: Schema.Entity,
        _ relationship: Schema.Relationship,
        destination: Schema.Entity
    ) -> Bool {
        guard let inverseName = relationship.inverse,
            let inverse = destination.relationships.first(where: { $0.name == inverseName })
        else { return relationship.inverse == nil }
        return "\(entity.name).\(relationship.name)".utf8.lexicographicallyPrecedes(
            "\(destination.name).\(inverse.name)".utf8)
    }

    private func joinSideAOwner(
        _ entity: Schema.Entity,
        _ relationship: Schema.Relationship,
        destination: Schema.Entity
    ) -> Bool {
        guard let inverseName = relationship.inverse,
            let inverse = destination.relationships.first(where: { $0.name == inverseName })
        else { return relationship.inverse == nil }
        return inverse.isToMany && isCanonicalSideA(entity, relationship, destination: destination)
    }

    private func joinTableName(
        _ entity: Schema.Entity,
        _ relationship: Schema.Relationship,
        destination: Schema.Entity
    ) -> String? {
        guard relationship.isToMany else { return nil }
        guard let inverseName = relationship.inverse,
            let inverse = destination.relationships.first(where: { $0.name == inverseName })
        else {
            return relationship.inverse == nil
                ? "Z_\(entity.name.uppercased())_\(relationship.name.uppercased())_\(relationship.destination.uppercased())"
                : nil
        }
        guard inverse.isToMany else { return nil }
        let current = "\(entity.name).\(relationship.name)"
        let other = "\(destination.name).\(inverse.name)"
        let ordered =
            current.utf8.lexicographicallyPrecedes(other.utf8)
            ? [(entity.name, relationship.name), (destination.name, inverse.name)]
            : [(destination.name, inverse.name), (entity.name, relationship.name)]
        return
            "Z_\(ordered[0].0.uppercased())_\(ordered[0].1.uppercased())_\(ordered[1].0.uppercased())_\(ordered[1].1.uppercased())"
    }
}
