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
            let storage = relationshipStorageLocation(ownerEntity, relationship)
            return try store.read { connection in
                guard
                    let row = try connection.rows(
                        "SELECT Z\(storage.columnName) FROM Z\(storage.tableName) WHERE Z_PK = ?",
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
            let storage = relationshipStorageLocation(destination, inverse)
            let destinationIDs = descendantEntityIDs(for: destination)
            return try store.read { connection in
                try connection.rows(
                    "SELECT Z_PK FROM Z\(storage.tableName) WHERE Z\(storage.columnName) = ? "
                        + "AND Z_ENT IN (\(Array(repeating: "?", count: destinationIDs.count).joined(separator: ", "))) "
                        + "ORDER BY Z_PK ASC",
                    arguments: [.int(ownerPrimaryKey)] + destinationIDs.map { .int(Int64($0)) }
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
        guard let inverseName = relationship.inverse,
            let inverse = destination.relationships.first(where: { $0.name == inverseName })
        else { return [] }
        let storage = relationshipStorageLocation(destination, inverse)
        return try store.read { connection in
            try connection.rows(
                "SELECT Z_PK FROM Z\(storage.tableName) WHERE Z\(storage.columnName) = ? ORDER BY Z_PK ASC",
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
            let hierarchyRoot = rootEntity(for: entity)
            let hasHierarchy =
                hierarchyRoot.name != entity.name
                || schema.entities.contains(where: { $0.superentityName == entity.name })
            let key =
                hasHierarchy
                ? EntityPrimaryKey(entityName: hierarchyRoot.name, primaryKey: primaryKey)
                : EntityPrimaryKey(entityName: entityName, primaryKey: primaryKey)
            if let existing = identityMap.model(for: key, as: Model.self) { return existing }
            let attributes =
                hasHierarchy
                ? hierarchyAttributes(for: entity)
                : entity.attributes.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
            let columns = attributes.flatMap { attribute in
                attribute.options.contains(.flattened)
                    ? attribute.components.map(\.columnName) : [attribute.name]
            }.map { "Z\($0.uppercased())" }.joined(separator: ", ")
            let selected =
                (["Z_PK", "Z_OPT"] + (hasHierarchy ? ["Z_ENT"] : [])
                + (columns.isEmpty ? [] : [columns])).joined(separator: ", ")
            let hierarchyIDs = hasHierarchy ? descendantEntityIDs(for: entity) : []
            let entityFilter =
                hasHierarchy
                ? " AND Z_ENT IN (\(Array(repeating: "?", count: hierarchyIDs.count).joined(separator: ", ")))"
                : ""
            guard
                let row = try store.read({ connection in
                    try connection.rows(
                        "SELECT \(selected) FROM Z\(hierarchyRoot.name.uppercased()) WHERE Z_PK = ?\(entityFilter)",
                        arguments: [.int(primaryKey)] + hierarchyIDs.map { .int(Int64($0)) })
                }).first
            else { return nil }
            let candidate: any PersistentModel
            let concreteRegistration: ModelTypeRegistration
            let concreteEntity: Schema.Entity
            let version = runtimeInt(row[1])
            if hasHierarchy {
                guard row.count >= 3, case let .int(rawEntityID) = row[2],
                    let concreteID = Int(exactly: rawEntityID),
                    let registered = container.modelRegistration(forEntityID: concreteID),
                    registered.type is Model.Type,
                    let resolvedEntity = schema.entities.first(where: {
                        schema.entityIDsByName[$0.name] == concreteID
                    })
                else { return nil }
                concreteRegistration = registered
                concreteEntity = resolvedEntity
                candidate = try registered.materialize(
                    context: context, entity: resolvedEntity, attributes: attributes,
                    row: [row[0], row[1]] + row.dropFirst(3), storeIdentifier: storeIdentifier,
                    entityID: concreteID, primaryKey: primaryKey, version: version)
            } else {
                concreteRegistration = registration
                concreteEntity = entity
                candidate = try registration.materialize(
                    context: context, entity: entity, attributes: attributes, row: row,
                    storeIdentifier: storeIdentifier, entityID: entityID(for: entityName),
                    primaryKey: primaryKey, version: version)
            }
            concreteRegistration.installRelationshipFaults(on: candidate, entity: concreteEntity, resolver: self)
            return identityMap.canonicalHandle(for: key, candidate: candidate).model as? Model
        }
        return try load(registration.type)
    }

    private func rootEntity(for entity: Schema.Entity) -> Schema.Entity {
        var current = entity
        var visited: Set<String> = []
        while let parentName = current.superentityName,
            visited.insert(current.name).inserted,
            let parent = schema.entity(forName: parentName)
        {
            current = parent
        }
        return current
    }

    private func hierarchyAttributes(for entity: Schema.Entity) -> [Schema.Attribute] {
        let identifiers = Set(descendantEntityIDs(for: entity))
        var attributesByName: [String: Schema.Attribute] = [:]
        for candidate in schema.entities
        where schema.entityIDsByName[candidate.name].map(identifiers.contains) == true {
            for attribute in candidate.attributes { attributesByName[attribute.name.uppercased()] = attribute }
        }
        return attributesByName.values.sorted {
            $0.name.uppercased().utf8.lexicographicallyPrecedes($1.name.uppercased().utf8)
        }
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

    private func descendantEntityIDs(for entity: Schema.Entity) -> [Int] {
        schema.entities.compactMap { candidate in
            var current: Schema.Entity? = candidate
            var visited: Set<String> = []
            while let value = current, visited.insert(value.name).inserted {
                if value.name == entity.name { return schema.entityIDsByName[candidate.name] }
                current = value.superentityName.flatMap { schema.entity(forName: $0) }
            }
            return nil
        }.sorted()
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
        return "\(logicalOwnerName(entity, relationship)).\(relationship.name)".utf8.lexicographicallyPrecedes(
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
        return "\(logicalOwnerName(entity, relationship)).\(relationship.name)".utf8.lexicographicallyPrecedes(
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
        let ownerName = logicalOwnerName(entity, relationship)
        let mapping = schema.relationshipStorageMapping(
            modelEntityName: entity.name, relationshipName: relationship.name)
        let destinationName = mapping?.destinationEntityName ?? relationship.destination
        guard let inverseName = relationship.inverse,
            let inverse = destination.relationships.first(where: { $0.name == inverseName })
        else {
            return relationship.inverse == nil
                ? "Z_\(ownerName.uppercased())_\(relationship.name.uppercased())_\(destinationName.uppercased())"
                : nil
        }
        guard inverse.isToMany else { return nil }
        let current = "\(ownerName).\(relationship.name)"
        let other = "\(destination.name).\(inverse.name)"
        let ordered =
            current.utf8.lexicographicallyPrecedes(other.utf8)
            ? [(ownerName, relationship.name), (destination.name, inverse.name)]
            : [(destination.name, inverse.name), (ownerName, relationship.name)]
        return
            "Z_\(ordered[0].0.uppercased())_\(ordered[0].1.uppercased())_\(ordered[1].0.uppercased())_\(ordered[1].1.uppercased())"
    }

    private func logicalOwnerName(_ entity: Schema.Entity, _ relationship: Schema.Relationship) -> String {
        schema.relationshipStorageMapping(
            modelEntityName: entity.name, relationshipName: relationship.name)?.declaringEntityName ?? entity.name
    }

    private func relationshipStorageLocation(
        _ entity: Schema.Entity, _ relationship: Schema.Relationship
    ) -> (tableName: String, columnName: String) {
        let mapping = schema.relationshipStorageMapping(
            modelEntityName: entity.name, relationshipName: relationship.name)
        return (
            mapping?.ownerRootEntityName.uppercased() ?? entity.name.uppercased(),
            mapping?.storageColumnName.uppercased() ?? relationship.name.uppercased()
        )
    }
}
