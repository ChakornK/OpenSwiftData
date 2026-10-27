import Foundation
import OSDCore

/// A synchronous unit of work for inserting, fetching, and saving persistent models.
@MainActor
public final class ModelContext {
    /// The container that owns this context, when it was created by a container.
    public internal(set) var container: ModelContainer?
    /// Whether this context saves changes automatically.
    public var autosaveEnabled: Bool
    /// The undo manager associated with this context.
    public var undoManager: UndoManager?

    package nonisolated let state: ContextState
    private let testSaveHook: (() throws -> Void)?
    private var allowsSave = true
    private let identityMap = IdentityMap()
    private var temporaryIdentifiers: [PersistentIdentifier: PersistentIdentifier] = [:]
    private var relationshipLoadVisited = Set<EntityPrimaryKey>()

    /// Creates a context not associated with a model container.
    public convenience init() {
        self.init(container: nil, autosaveEnabled: false)
    }

    package init(container: ModelContainer?, autosaveEnabled: Bool) {
        self.container = container
        state = ContextState(relationshipAdaptersByModel: container?.relationshipAdapterTable ?? [:])
        self.autosaveEnabled = autosaveEnabled
        allowsSave = container?.configurations.first?.allowsSave ?? true
        testSaveHook = nil
    }

    internal init(testSave hook: @escaping () throws -> Void, container: ModelContainer? = nil) {
        self.container = container
        state = ContextState(relationshipAdaptersByModel: container?.relationshipAdapterTable ?? [:])
        autosaveEnabled = false
        allowsSave = true
        testSaveHook = hook
    }

    /// Models inserted into this context and not yet saved.
    public var insertedModelsArray: [any PersistentModel] { state.insertedModels }
    /// Models changed in this context and not yet saved.
    public var changedModelsArray: [any PersistentModel] { state.changedModels }
    /// Models deleted in this context and not yet saved.
    public var deletedModelsArray: [any PersistentModel] { state.deletedModels }
    /// Compatibility alias for inserted models.
    public var insertedModels: [any PersistentModel] { insertedModelsArray }
    /// Compatibility alias for changed models.
    public var changedModels: [any PersistentModel] { changedModelsArray }
    /// Compatibility alias for deleted models.
    public var deletedModels: [any PersistentModel] { deletedModelsArray }
    /// Whether this context currently has unsaved changes.
    public var hasChanges: Bool {
        state.hasChanges
    }
    /// Sort descriptors used by this context.
    public var sortDescriptors: [NSSortDescriptor] = []

    /// Inserts a detached model into this context.
    public func insert<Model: PersistentModel>(_ model: Model) {
        state.withExclusiveOperation {
            guard model.modelContext == nil else { return }
            insertRelationshipDestination(model, snapshot: model.snapshotLifecycle())
        }
    }

    func insertRelationshipDestination(_ model: any PersistentModel, snapshot: BackingDataSnapshot) {
        guard model.modelContext == nil else { return }
        var insertionSnapshot = snapshot
        for adapter in container?.relationshipAdapterTable[ObjectIdentifier(type(of: model))] ?? [] {
            guard snapshot.values[adapter.keyPath] == nil,
                let value = try? adapter.makeValue([]),
                let metadata = type(of: model).schemaMetadata().first(where: { $0.name == adapter.name }),
                let keyPath = metadata.keypath
            else { continue }
            func setRelationshipDefault<Model: PersistentModel>(_ model: Model) {
                (model.persistentBackingData as? ManagedBackingData<Model>)?.setMaterializedValue(
                    forKey: keyPath, to: value)
            }
            setRelationshipDefault(model)
            let values = insertionSnapshot.values.merging([keyPath: value]) { _, new in new }
            insertionSnapshot = BackingDataSnapshot(
                values: values, context: insertionSnapshot.context, identifier: insertionSnapshot.identifier,
                isDeleted: insertionSnapshot.isDeleted, hasChanges: insertionSnapshot.hasChanges,
                savedValues: insertionSnapshot.savedValues, primaryKey: insertionSnapshot.primaryKey,
                entityID: insertionSnapshot.entityID,
                optimisticLockVersion: insertionSnapshot.optimisticLockVersion)
        }
        state.insert(model, snapshot: insertionSnapshot)
        func attach<Model: PersistentModel>(_ model: Model) {
            model.persistentBackingData.attach(to: self, model: model)
            model.setInsertionChanged()
            state.setBaseline(model, snapshot: model.snapshotLifecycle())
        }
        attach(model)
    }

    /// Deletes a model or cancels its pending insertion.
    public func delete<Model: PersistentModel>(_ model: Model) {
        state.withExclusiveOperation {
            guard model.modelContext === self else { return }
            if state.containsInserted(model) {
                model.restoreValuesAndDetachLifecycle(state.cancelInsertion(model) ?? model.snapshotLifecycle())
                state.removeBaseline(for: model)
                return
            }
            guard !state.containsDeleted(model) else { return }
            do {
                try validateDeleteRules(for: model)
            } catch {
                OSDLog.debug("Delete rejected: \(error)")
                return
            }
            capture(model)
            markDeletedTyped(model)
            state.markDeleted(model)
        }
    }

    private func planAndApplyDelete(roots: [any PersistentModel]) throws {
        var relationshipSnapshots: [ObjectIdentifier: [(any AnyRelationshipAdapterBox, [any PersistentModel])]] = [:]
        let roots = roots.filter { state.containsDeleted($0) }
        guard !roots.isEmpty else { return }
        for root in roots {
            relationshipSnapshots[ObjectIdentifier(root)] = state.relationships(ownedBy: root)
        }

        var scheduled = roots
        var scheduledIDs = Set(scheduled.map(ObjectIdentifier.init))
        var cascadeScheduled: [any PersistentModel] = []
        var denyEdges = Set<String>()
        while let source = scheduled.first {
            scheduled.removeFirst()
            let outgoing = relationshipSnapshots[ObjectIdentifier(source)] ?? state.relationships(ownedBy: source)
            relationshipSnapshots[ObjectIdentifier(source)] = outgoing
            for (adapter, endpoints) in outgoing {
                guard let metadata = adapter.metadata else {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Relationship adapter '\(adapter.name)' is unresolved during delete processing.")
                }
                switch metadata.deleteRule {
                case .deny:
                    for endpoint in endpoints where !scheduledIDs.contains(ObjectIdentifier(endpoint)) {
                        let edge = "\(ObjectIdentifier(source)):\(adapter.name):\(ObjectIdentifier(endpoint))"
                        guard denyEdges.insert(edge).inserted else { continue }
                        throw SwiftDataError.relationshipGraphConflict(
                            "Cannot delete model while relationship '\(adapter.name)' has related models.")
                    }
                case .cascade:
                    for endpoint in endpoints where scheduledIDs.insert(ObjectIdentifier(endpoint)).inserted {
                        cascadeScheduled.append(endpoint)
                        scheduled.append(endpoint)
                        relationshipSnapshots[ObjectIdentifier(endpoint)] = state.relationships(ownedBy: endpoint)
                    }
                case .nullify, .noAction:
                    break
                }
            }
        }
        try applyDeletePlan(
            roots: scheduled, cascadeScheduled: cascadeScheduled,
            relationshipSnapshots: relationshipSnapshots)
    }

    private func validateDeleteRules(for model: any PersistentModel) throws {
        for (adapter, endpoints) in state.relationships(ownedBy: model) {
            guard let metadata = adapter.metadata else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Relationship adapter '\(adapter.name)' is unresolved during delete processing.")
            }
            if metadata.deleteRule == .deny, !endpoints.isEmpty {
                throw SwiftDataError.relationshipGraphConflict(
                    "Cannot delete model while relationship '\(adapter.name)' has related models.")
            }
        }
    }

    private func applyDeletePlan(
        roots: [any PersistentModel],
        cascadeScheduled: [any PersistentModel],
        relationshipSnapshots: [ObjectIdentifier: [(any AnyRelationshipAdapterBox, [any PersistentModel])]]
    ) throws {
        let before = state.pendingState()
        let pendingDeletesBeforePlan = before.deleted
        let deletes = (roots + cascadeScheduled).reduce(into: [any PersistentModel]()) { result, model in
            if !result.contains(where: { $0 === model }) {
                result.append(model)
            }
        }
        let nullifications = try planNullifications(for: deletes, relationships: relationshipSnapshots)
        var snapshotsByID: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)] = [:]
        for model in deletes {
            let snapshot = model.snapshotLifecycle()
            snapshotsByID[ObjectIdentifier(model)] = (model, snapshot)
        }
        for nullification in nullifications where snapshotsByID[ObjectIdentifier(nullification.owner)] == nil {
            snapshotsByID[ObjectIdentifier(nullification.owner)] = (nullification.owner, nullification.snapshot)
        }
        for nullification in nullifications {
            capture(nullification.owner)
        }
        let pendingBeforeNullifications = state.pendingState()
        do {
            for nullification in nullifications {
                try nullification.adapter.assign(nullification.value, to: nullification.owner)
            }
        } catch {
            for (model, snapshot) in snapshotsByID.values {
                if snapshot.context === self {
                    model.restoreLifecycle(snapshot)
                } else {
                    model.restoreValuesAndDetachLifecycle(snapshot)
                }
            }
            state.restorePendingState(pendingBeforeNullifications)
            throw error
        }
        for nullification in nullifications {
            state.recordRelationshipMutation(
                owner: nullification.owner,
                property: nullification.adapter.name,
                relationship: nullification.adapter.metadata
                    ?? Schema.Relationship(
                        name: nullification.adapter.name,
                        destination: String(describing: nullification.adapter.destinationType),
                        isToMany: nullification.adapter.isToMany),
                oldValues: nullification.oldEndpoints,
                newValues: nullification.newEndpoints)
        }
        let newlyDeleted = deletes.filter { deleted in
            deleted.modelContext === self && !pendingDeletesBeforePlan.contains(where: { $0 === deleted })
        }
        for deleted in newlyDeleted {
            capture(deleted)
            markDeletedTyped(deleted)
            state.markDeleted(deleted)
        }
    }

    private struct PlannedNullification {
        let owner: any PersistentModel
        let adapter: any AnyRelationshipAdapterBox
        let value: Any
        let oldEndpoints: [any PersistentModel]
        let newEndpoints: [any PersistentModel]
        let snapshot: BackingDataSnapshot
    }

    private func planNullifications(
        for deleting: [any PersistentModel],
        relationships: [ObjectIdentifier: [(any AnyRelationshipAdapterBox, [any PersistentModel])]]
    ) throws -> [PlannedNullification] {
        var planned: [PlannedNullification] = []
        var seen = Set<String>()
        for deleted in deleting {
            for (adapter, endpoints) in relationships[ObjectIdentifier(deleted)] ?? [] {
                guard let metadata = adapter.metadata else {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Relationship adapter '\(adapter.name)' is unresolved during delete processing.")
                }
                guard metadata.deleteRule == .nullify, let inverseName = metadata.inverse else { continue }
                for endpoint in endpoints {
                    guard let inverse = state.relationshipAdapter(for: endpoint, property: inverseName) else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Nullify inverse '\(inverseName)' has no typed relationship adapter.")
                    }
                    let key = "\(ObjectIdentifier(endpoint)):\(inverse.name):\(ObjectIdentifier(deleted))"
                    guard seen.insert(key).inserted else { continue }
                    guard let current = inverse.read(endpoint) else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Nullify inverse '\(inverse.name)' cannot read its endpoint.")
                    }
                    try state.validateRelationshipCardinality(current, using: inverse)
                    let remaining = current.filter { relatedEndpoint in
                        !deleting.contains(where: { $0 === relatedEndpoint })
                    }
                    let value: Any
                    do {
                        value = try inverse.makeInverseValue(remaining)
                    } catch {
                        if !inverse.isToMany && remaining.isEmpty {
                            throw SwiftDataError.relationshipGraphConflict(
                                "Cannot nullify nonoptional relationship '\(inverse.name)'.")
                        }
                        throw error
                    }
                    planned.append(
                        PlannedNullification(
                            owner: endpoint, adapter: inverse, value: value,
                            oldEndpoints: current, newEndpoints: remaining,
                            snapshot: endpoint.snapshotLifecycle()))
                }
            }
        }
        return planned
    }

    /// Processes pending relationship ownership and delete rules synchronously.
    public func processPendingChanges() throws {
        try state.withExclusiveOperation { try processPendingChangesLocked() }
    }

    private func processPendingChangesLocked() throws {
        let pending = state.pendingState()
        let roots = pending.deleted
        guard !roots.isEmpty else { return }
        let rootSnapshots = roots.compactMap { root -> (any PersistentModel, BackingDataSnapshot)? in
            guard let snapshot = pending.snapshots[ObjectIdentifier(root)]?.1 else { return nil }
            return (root, snapshot)
        }
        let baselineBefore = state.baselineSnapshotState()
        do {
            try planAndApplyDelete(roots: roots)
        } catch {
            restoreRejectedDeletes(rootSnapshots, roots: roots, pending: pending)
            state.restoreBaselineSnapshots(baselineBefore)
            throw error
        }
    }

    private func restoreRejectedDeletes(
        _ snapshotsForRoots: [(any PersistentModel, BackingDataSnapshot)],
        roots: [any PersistentModel],
        pending: ContextState.PendingState
    ) {
        let current = state.pendingState()
        var snapshots = pending.snapshots
        for (identifier, value) in current.snapshots {
            snapshots[identifier] = value
        }
        for (root, snapshot) in snapshotsForRoots {
            snapshots[ObjectIdentifier(root)] = (root, snapshot)
        }
        for (model, snapshot) in snapshots.values {
            model.restoreLifecycle(snapshot)
        }
        state.restorePendingState(
            ContextState.PendingState(
                inserted: pending.inserted,
                changed: pending.changed,
                deleted: pending.deleted.filter { deleted in !roots.contains(where: { $0 === deleted }) },
                snapshots: pending.snapshots,
                relationshipMutationEvents: pending.relationshipMutationEvents))
    }

    /// Deletes models matching a predicate, which requires a persistent store.
    public func delete<Model: PersistentModel>(
        model: Model.Type,
        where predicate: Predicate<Model>,
        includeSubclasses: Bool = true
    ) throws {
        _ = (model, predicate, includeSubclasses)
        throw unsupportedStore("Predicate-based delete")
    }

    /// Fetches models matching a descriptor, which requires a persistent store.
    public func fetch<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) throws -> [Model] {
        guard let store = container?.store else { throw unsupportedStore("Fetch") }
        _ = descriptor
        guard let entity = container?.schema.entity(forName: String(describing: Model.self)) else { return [] }
        let attributes = canonicalAttributes(for: entity)
        let columns = attributes.map { "Z\($0.name.uppercased())" }
        let selectColumns = (["Z_PK", "Z_OPT"] + columns).joined(separator: ", ")
        let rows = try store.read { connection in
            try connection.rows(
                "SELECT \(selectColumns) FROM Z\(entity.name.uppercased()) ORDER BY Z_PK ASC", arguments: [])
        }
        var models: [Model] = []
        var primaryKeys: [Int64] = []
        for row in rows {
            guard row.count >= 2, case let .int(pk) = row[0], case let .int(version) = row[1] else { continue }
            let key = EntityPrimaryKey(entityName: entity.name, primaryKey: pk)
            let model: Model
            if let existing = identityMap.model(for: key, as: Model.self) {
                model = existing
                if !existing.hasChanges {
                    try refreshAttributes(existing, entity: entity, attributes: attributes, row: row)
                }
                refreshVersion(existing, version: Int(version))
            } else {
                model = try materialize(
                    Model.self, entity: entity, attributes: attributes, row: row, storeIdentifier: storeIdentifier,
                    primaryKey: pk, version: Int(version))
                identityMap.register(model, for: key)
            }
            primaryKeys.append(pk)
            models.append(model)
        }
        relationshipLoadVisited.removeAll()
        var visited = relationshipLoadVisited
        try materializeRelationships(models, entity: entity, primaryKeys: primaryKeys, store: store, visited: &visited)
        relationshipLoadVisited = visited
        return models
    }

    /// Counts models matching a descriptor, which requires a persistent store.
    public func fetchCount<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) throws -> Int {
        _ = descriptor
        throw unsupportedStore("Fetch count")
    }

    /// Fetches identifiers matching a descriptor, which requires a persistent store.
    public func fetchIdentifiers<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>
    ) throws -> [PersistentIdentifier] {
        _ = descriptor
        throw unsupportedStore("Identifier fetch")
    }

    /// Enumerates models matching a descriptor, which requires a persistent store.
    public func enumerate<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>,
        batchSize: Int = 500,
        allowEscapingMutations: Bool = false,
        block: (Model) throws -> Void
    ) throws {
        _ = (descriptor, batchSize, allowEscapingMutations, block)
        throw unsupportedStore("Enumeration")
    }

    /// Finds a model by its persistent identifier, which requires a persistent store.
    public func model<Model: PersistentModel>(for identifier: PersistentIdentifier) throws -> Model? {
        guard let key = identifier.primaryKey else {
            guard let permanent = temporaryIdentifiers[identifier] else { throw unsupportedStore("Model lookup") }
            return try model(for: permanent)
        }
        guard let container,
            identifier.storeIdentifier == storeIdentifier,
            let entity = container.schema.entity(forName: identifier.entityName),
            identifier.entityName == String(describing: Model.self),
            let modelEntity = container.schema.entity(forName: String(describing: Model.self)),
            modelEntity.name == entity.name
        else { throw unsupportedStore("Model lookup") }
        guard let store = container.store else { throw unsupportedStore("Model lookup") }
        if let registered: Model = registeredModel(for: identifier) {
            let attributes = canonicalAttributes(for: entity)
            let columns = attributes.map { "Z\($0.name.uppercased())" }
            let selectColumns = (["Z_PK", "Z_OPT"] + columns).joined(separator: ", ")
            guard
                let row = try store.read({ connection in
                    try connection.rows(
                        "SELECT \(selectColumns) FROM Z\(entity.name.uppercased()) WHERE Z_PK = ?",
                        arguments: [.int(key)])
                }).first
            else { return nil }
            if !registered.hasChanges {
                try refreshAttributes(registered, entity: entity, attributes: attributes, row: row)
            }
            refreshVersion(registered, version: row.count > 1 ? runtimeInt(row[1]) : 0)
            relationshipLoadVisited.removeAll()
            var visited = relationshipLoadVisited
            try materializeRelationships(
                [registered], entity: entity, primaryKeys: [key], store: store, visited: &visited)
            relationshipLoadVisited = visited
            return registered
        }
        let attributes = canonicalAttributes(for: entity)
        let columns = attributes.map { "Z\($0.name.uppercased())" }.joined(separator: ", ")
        let selectedColumns = columns.isEmpty ? "Z_PK, Z_OPT" : "Z_PK, Z_OPT, \(columns)"
        let rows = try store.read {
            try $0.rows(
                "SELECT \(selectedColumns) FROM Z\(entity.name.uppercased()) WHERE Z_PK = ?",
                arguments: [.int(key)])
        }
        guard let row = rows.first else { return nil }
        let model = try materialize(
            Model.self, entity: entity, attributes: attributes, row: row, storeIdentifier: identifier.storeIdentifier,
            primaryKey: key, version: row.count > 1 ? runtimeInt(row[1]) : 0)
        identityMap.register(model, for: EntityPrimaryKey(entityName: entity.name, primaryKey: key))
        relationshipLoadVisited.removeAll()
        var visited = relationshipLoadVisited
        try materializeRelationships([model], entity: entity, primaryKeys: [key], store: store, visited: &visited)
        relationshipLoadVisited = visited
        return model
    }

    /// Returns a registered model by its persistent identifier, if present.
    public func registeredModel<Model: PersistentModel>(for identifier: PersistentIdentifier) -> Model? {
        guard let container,
            identifier.primaryKey != nil,
            identifier.storeIdentifier == storeIdentifier,
            identifier.entityName == String(describing: Model.self),
            container.schema.entity(forName: identifier.entityName) != nil
        else { return nil }
        guard let key = identifier.primaryKey else { return nil }
        return identityMap.model(
            for: EntityPrimaryKey(entityName: identifier.entityName, primaryKey: key), as: Model.self)
    }

    /// Saves pending changes when a supported store is available.
    public func save() throws {
        try state.withExclusiveOperation {
            try processPendingChangesLocked()
            guard !state.hasTransaction else { return }
            if !allowsSave { throw unsupportedStore("Saving is disabled") }
            if let testSaveHook {
                try testSaveHook()
                finalizePendingChanges()
                return
            }
            guard let store = container?.store else { throw unsupportedStore("Saving") }
            guard allowsSave else { throw unsupportedStore("Saving is disabled") }
            try persistPendingChanges(to: store)
        }
    }

    /// Discards pending changes and restores values to their prior saved state.
    public func rollback() {
        state.withExclusiveOperation {
            let pendingState = state.pendingState()
            let pendingInsertions = pendingState.inserted
            for (model, snapshot) in pendingState.snapshots.values {
                if state.contains(model, in: pendingInsertions) {
                    model.restoreValuesAndDetachLifecycle(snapshot)
                } else {
                    model.restoreLifecycle(snapshot)
                }
            }
            for model in pendingInsertions where pendingState.snapshots[ObjectIdentifier(model)] == nil {
                cancelInsertion(model)
            }
            state.clearPending()
            for (model, snapshot) in pendingState.snapshots.values where !state.contains(model, in: pendingInsertions) {
                state.setBaseline(model, snapshot: snapshot)
            }
            for model in pendingState.deleted {
                state.removeBaseline(for: model)
            }
        }
    }

    /// Runs a block as an atomic unit of context work and saves on success.
    public func transaction<T>(block: () throws -> T) throws -> T {
        try state.withExclusiveOperation {
            let pending = state.pendingState()
            let entrySnapshots = Dictionary(
                uniqueKeysWithValues: (pending.inserted + pending.changed + pending.deleted).map {
                    (ObjectIdentifier($0), ($0, snapshot(of: $0)))
                }
            )
            state.beginTransaction(entrySnapshots: entrySnapshots)
            do {
                let result = try block()
                try processPendingChangesLocked()
                if state.transactionDepth == 1 {
                    if let testSaveHook {
                        try testSaveHook()
                        finalizePendingChanges()
                    } else {
                        guard let store = container?.store else { throw unsupportedStore("Saving") }
                        try persistPendingChanges(to: store)
                    }
                }
                state.popTransaction()
                return result
            } catch {
                rollbackCurrentTransaction()
                throw error
            }
        }
    }

    /// Captures a model before a property write so rollback can restore its prior values.
    package func willMutate<Model: PersistentModel>(_ model: Model) {
        guard model.modelContext === self else { return }
        state.willMutate(model, snapshot: model.snapshotLifecycle())
    }

    /// Records a property write as a pending change.
    package func recordMutation<Model: PersistentModel>(_ model: Model) {
        guard model.modelContext === self else { return }
        state.recordMutation(model)
    }

    private var storeIdentifier: String { container?.configurations.first?.name ?? "default" }

    private func canonicalAttributes(for entity: Schema.Entity) -> [Schema.Attribute] {
        entity.attributes.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }

    private func materialize<Model: PersistentModel>(
        _ type: Model.Type, entity: Schema.Entity, attributes: [Schema.Attribute], row: [RuntimeValue],
        storeIdentifier: String, primaryKey: Int64, version: Int
    ) throws -> Model {
        let backing = ManagedBackingData<Model>(
            metadata: Model.schemaMetadata(), values: defaultRelationshipValues(for: Model.self), context: self,
            storeIdentifier: storeIdentifier, entityID: entityID(for: entity.name), primaryKey: primaryKey,
            version: version,
            identifier: PersistentIdentifier(
                storeIdentifier: storeIdentifier, entityName: entity.name, primaryKey: primaryKey))
        let model = Model(backingData: backing)
        let adapters = Model.persistenceAdapters()
        for (index, attribute) in attributes.enumerated() {
            guard index + 2 < row.count,
                let adapter = adapters.first(where: { $0.name == attribute.name })
            else { continue }
            let stored = storedValue(row[index + 2])
            try adapter.decode(stored, into: model)
        }
        for relationship in entity.relationships {
            if let adapter = container?.relationshipAdapterTable[ObjectIdentifier(Model.self)]?
                .first(where: { $0.name == relationship.name }),
                let keyPath = Model.schemaMetadata().first(where: { $0.name == relationship.name })?.keypath,
                let defaultValue = try? adapter.makeInverseValue([])
            {
                backing.setMaterializedValue(forKey: keyPath, to: defaultValue)
            }
        }
        backing.markSaved()
        backing.attach(to: self, model: model)
        return model
    }

    private func defaultRelationshipValues<Model: PersistentModel>(for type: Model.Type) -> [AnyKeyPath: Any] {
        var values: [AnyKeyPath: Any] = [:]
        for adapter in container?.relationshipAdapterTable[ObjectIdentifier(type)] ?? [] {
            guard let value = try? adapter.makeValue([]),
                let metadata = type.schemaMetadata().first(where: { $0.name == adapter.name }),
                let keyPath = metadata.keypath
            else { continue }
            values[keyPath] = value
        }
        return values
    }

    private func refreshAttributes<Model: PersistentModel>(
        _ model: Model, entity: Schema.Entity, attributes: [Schema.Attribute], row: [RuntimeValue]
    ) throws {
        guard !model.hasChanges,
            let backing = model.persistentBackingData as? ManagedBackingData<Model>
        else { return }
        let adapters = Model.persistenceAdapters()
        let metadata = Model.schemaMetadata()
        for (index, attribute) in attributes.enumerated() {
            guard index + 2 < row.count,
                let adapter = adapters.first(where: { $0.name == attribute.name }),
                let keyPath = metadata.first(where: { $0.name == attribute.name })?.keypath
            else { continue }
            let value = try adapter.decoded(storedValue(row[index + 2]))
            backing.setMaterializedValue(forKey: keyPath, to: value)
        }
        _ = entity
    }

    private func refreshVersion<Model: PersistentModel>(_ model: Model, version: Int) {
        let snapshot = model.snapshotLifecycle()
        if snapshot.optimisticLockVersion != version {
            let updated = BackingDataSnapshot(
                values: snapshot.values, context: snapshot.context, identifier: snapshot.identifier,
                isDeleted: snapshot.isDeleted, hasChanges: snapshot.hasChanges,
                savedValues: snapshot.savedValues, primaryKey: snapshot.primaryKey, entityID: snapshot.entityID,
                optimisticLockVersion: version)
            model.restoreLifecycle(updated)
        }
    }

    private func cleanupRelationships(
        for model: any PersistentModel, connection: any RuntimeConnection
    ) throws {
        guard let primaryKey = model.persistentModelID.primaryKey else { return }
        for entity in container?.schema.entities ?? [] {
            for relationship in canonicalRelationships(for: entity) where relationship.isToMany {
                let table: String
                let sideAEntity: String
                let sideBEntity: String
                if relationship.inverse == nil {
                    guard let joinTable = joinTableName(for: entity, relationship) else { continue }
                    table = joinTable
                    sideAEntity = entity.name
                    sideBEntity = relationship.destination
                } else if isCanonicalSideA(entity, relationship),
                    let inverseName = relationship.inverse,
                    let destination = container?.schema.entity(forName: relationship.destination),
                    destination.relationships.first(where: { $0.name == inverseName })?.isToMany == true,
                    let joinTable = joinTableName(for: entity, relationship)
                {
                    table = joinTable
                    sideAEntity = entity.name
                    sideBEntity = destination.name
                } else {
                    continue
                }
                if model.persistentModelID.entityName == entity.name {
                    try connection.execute("DELETE FROM \(table) WHERE Z_A = ?", arguments: [.int(primaryKey)])
                }
                if model.persistentModelID.entityName == sideBEntity {
                    try connection.execute(
                        "DELETE FROM \(table) WHERE Z_B = ?", arguments: [.int(primaryKey)])
                }
                _ = sideAEntity
            }
        }
        for ownerEntity in container?.schema.entities ?? [] {
            for relationship in canonicalRelationships(for: ownerEntity) where !relationship.isToMany {
                guard relationship.destination == model.persistentModelID.entityName,
                    let inverseName = relationship.inverse,
                    let deletedEntity = container?.schema.entity(forName: relationship.destination),
                    let inverse = deletedEntity.relationships.first(where: { $0.name == inverseName }),
                    inverse.deleteRule == .nullify,
                    isToOneStorageOwner(ownerEntity, relationship)
                else { continue }
                try connection.execute(
                    "UPDATE Z\(ownerEntity.name.uppercased()) SET Z\(relationship.name.uppercased()) = NULL "
                        + "WHERE Z\(relationship.name.uppercased()) = ?",
                    arguments: [.int(primaryKey)])
            }
        }
    }

    private func materializeRelationships<Model: PersistentModel>(
        _ models: [Model], entity: Schema.Entity, primaryKeys: [Int64], store: any RuntimeStore,
        visited: inout Set<EntityPrimaryKey>
    ) throws {
        let rootKeys = primaryKeys.map { EntityPrimaryKey(entityName: entity.name, primaryKey: $0) }
        let newRootKeys = rootKeys.filter { visited.insert($0).inserted }
        defer { newRootKeys.forEach { visited.remove($0) } }
        guard !primaryKeys.isEmpty, !newRootKeys.isEmpty,
            let adapters = container?.relationshipAdapterTable[ObjectIdentifier(Model.self)], !adapters.isEmpty
        else { return }

        let byPK = Dictionary(uniqueKeysWithValues: zip(primaryKeys, models))
        let byName = Dictionary(uniqueKeysWithValues: adapters.map { ($0.name, $0) })
        let placeholders = primaryKeys.map { _ in "?" }.joined(separator: ", ")
        for relationship in canonicalRelationships(for: entity) {
            guard let adapter = byName[relationship.name] else { continue }
            var endpoints: [Int64: [any PersistentModel]] = [:]
            let rows: [[RuntimeValue]]
            let destinationType: any PersistentModel.Type
            let rootColumnFirst: Bool

            if relationship.isToMany,
                let inverseName = relationship.inverse,
                let destinationEntity = container?.schema.entity(forName: relationship.destination),
                let inverse = destinationEntity.relationships.first(where: { $0.name == inverseName }),
                inverse.isToMany
            {
                let storageOwner = relationship.inverse == nil || isCanonicalSideA(entity, relationship)
                let storageEntity = storageOwner ? entity : destinationEntity
                let storageRelationship: Schema.Relationship
                if storageOwner {
                    storageRelationship = relationship
                } else {
                    guard let inverse = destinationEntity.relationships.first(where: { $0.name == inverseName }) else {
                        continue
                    }
                    storageRelationship = inverse
                }
                guard let table = joinTableName(for: storageEntity, storageRelationship) else { continue }
                let requestedSideIsStorageOwner = joinSideAOwner(entity, relationship)
                destinationType = adapter.destinationType
                rootColumnFirst = true
                rows = try store.read { connection in
                    var result: [[RuntimeValue]] = []
                    for primaryKey in primaryKeys {
                        if requestedSideIsStorageOwner {
                            result += try connection.rows(
                                "SELECT Z_A, Z_B FROM \(table) WHERE Z_A = ? ORDER BY Z_B ASC",
                                arguments: [.int(primaryKey)])
                        } else {
                            result += try connection.rows(
                                "SELECT Z_B, Z_A FROM \(table) WHERE Z_B = ? ORDER BY Z_A ASC",
                                arguments: [.int(primaryKey)])
                        }
                    }
                    return result
                }
            } else if relationship.isToMany, relationship.inverse == nil {
                guard let table = joinTableName(for: entity, relationship) else { continue }
                destinationType = adapter.destinationType
                rootColumnFirst = true
                rows = try store.read { connection in
                    try connection.rows(
                        "SELECT Z_A, Z_B FROM \(table) WHERE Z_A IN (\(placeholders)) ORDER BY Z_A ASC, Z_B ASC",
                        arguments: primaryKeys.map(RuntimeValue.int))
                }
            } else if relationship.isToMany,
                let inverseName = relationship.inverse,
                let destinationEntity = container?.schema.entity(forName: relationship.destination),
                destinationEntity.relationships.first(where: { $0.name == inverseName })?.isToMany == false
            {
                destinationType = adapter.destinationType
                rootColumnFirst = true
                rows = try store.read { connection in
                    try connection.rows(
                        "SELECT Z\(inverseName.uppercased()), Z_PK FROM Z\(destinationEntity.name.uppercased()) "
                            + "WHERE Z\(inverseName.uppercased()) IN (\(placeholders)) ORDER BY Z_PK ASC",
                        arguments: primaryKeys.map(RuntimeValue.int))
                }
            } else if isToOneStorageOwner(entity, relationship) {
                destinationType = adapter.destinationType
                rootColumnFirst = true
                rows = try store.read { connection in
                    try connection.rows(
                        "SELECT Z_PK, Z\(relationship.name.uppercased()) FROM Z\(entity.name.uppercased()) "
                            + "WHERE Z_PK IN (\(placeholders)) ORDER BY Z_PK ASC",
                        arguments: primaryKeys.map(RuntimeValue.int))
                }
            } else {
                guard let inverseName = relationship.inverse,
                    let destinationEntity = container?.schema.entity(forName: relationship.destination)
                else { continue }
                destinationType = adapter.destinationType
                rootColumnFirst = true
                rows = try store.read { connection in
                    try connection.rows(
                        "SELECT Z\(inverseName.uppercased()), Z_PK FROM Z\(destinationEntity.name.uppercased()) "
                            + "WHERE Z\(inverseName.uppercased()) IN (\(placeholders)) ORDER BY Z_PK ASC",
                        arguments: primaryKeys.map(RuntimeValue.int))
                }
            }

            for row in rows {
                guard row.count == 2, case let .int(firstPK) = row[0], case let .int(secondPK) = row[1] else {
                    continue
                }
                let ownerPK = rootColumnFirst ? firstPK : secondPK
                let destinationPK = rootColumnFirst ? secondPK : firstPK
                guard byPK[ownerPK] != nil else { continue }
                guard
                    let destination = try loadRelationshipDestination(
                        destinationType, primaryKey: destinationPK, store: store, visited: &visited,
                        materializeRelations: false)
                else {
                    throw SwiftDataError.unsupportedStore(
                        "Relationship '\(entity.name).\(relationship.name)' references missing "
                            + "destination row \(String(describing: destinationType))#\(destinationPK).")
                }
                endpoints[ownerPK, default: []].append(destination)
            }
            for (ownerPK, owner) in byPK {
                guard !owner.hasChanges else { continue }
                let relatedByID = Dictionary(
                    (endpoints[ownerPK] ?? []).map { (ObjectIdentifier($0), $0) },
                    uniquingKeysWith: { first, _ in first })
                let related = relatedByID.values.sorted {
                    ($0.persistentModelID.primaryKey ?? Int64.max) < ($1.persistentModelID.primaryKey ?? Int64.max)
                }
                try assignMaterializedRelationship(adapter, endpoints: related, to: owner)
                if let inverseName = relationship.inverse {
                    for destination in related {
                        guard !destination.hasChanges else { continue }
                        guard let inverse = relationshipAdapter(for: destination, property: inverseName) else {
                            throw SwiftDataError.unsupportedSchemaProperty(
                                "Relationship inverse '\(inverseName)' was not bound for '\(relationship.name)'.")
                        }
                        let current = inverse.read(destination) ?? []
                        let inverseEndpoints = current.contains(where: { $0 === owner }) ? current : current + [owner]
                        try assignMaterializedRelationship(
                            inverse, endpoints: inverseEndpoints, to: destination)
                    }
                }
            }
        }
    }

    private func assignMaterializedRelationship(
        _ adapter: any AnyRelationshipAdapterBox,
        endpoints: [any PersistentModel],
        to model: any PersistentModel
    ) throws {
        let value = try adapter.makeValue(endpoints)
        guard let metadata = type(of: model).schemaMetadata().first(where: { $0.name == adapter.name }),
            let keyPath = metadata.keypath
        else {
            throw SwiftDataError.unsupportedSchemaProperty(
                "Relationship metadata key path was missing for '\(String(describing: type(of: model))).\(adapter.name)'."
            )
        }
        func assign<Model: PersistentModel>(_ model: Model) {
            guard let backing = model.persistentBackingData as? ManagedBackingData<Model> else { return }
            let snapshot = backing.snapshot()
            backing.setMaterializedValue(forKey: keyPath, to: value)
            if snapshot.hasChanges { backing.restore(snapshot) }
        }
        assign(model)
        if let loaded = adapter.read(model),
            loaded.count != endpoints.count || !zip(loaded, endpoints).allSatisfy({ $0 === $1 })
        {
            throw SwiftDataError.unsupportedStore(
                "Materialized relationship '\(adapter.name)' did not retain its loaded endpoints.")
        }
    }

    private func relationshipAdapter(
        for model: any PersistentModel, property: String
    ) -> (any AnyRelationshipAdapterBox)? {
        container?.relationshipAdapterTable[ObjectIdentifier(type(of: model))]?.first { $0.name == property }
    }

    private func canonicalRelationships(for entity: Schema.Entity) -> [Schema.Relationship] {
        entity.relationships.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }

    private func isToOneStorageOwner(_ entity: Schema.Entity, _ relationship: Schema.Relationship) -> Bool {
        guard let inverseName = relationship.inverse,
            let destination = container?.schema.entity(forName: relationship.destination),
            let inverse = destination.relationships.first(where: { $0.name == inverseName }), !inverse.isToMany
        else { return true }
        let current = "\(entity.name).\(relationship.name)"
        let other = "\(destination.name).\(inverse.name)"
        return current.utf8.lexicographicallyPrecedes(other.utf8)
    }

    private func isCanonicalSideA(_ entity: Schema.Entity, _ relationship: Schema.Relationship) -> Bool {
        guard let inverseName = relationship.inverse,
            let destination = container?.schema.entity(forName: relationship.destination),
            let inverse = destination.relationships.first(where: { $0.name == inverseName })
        else { return relationship.inverse == nil }
        let current = "\(entity.name).\(relationship.name)"
        let other = "\(destination.name).\(inverse.name)"
        return current.utf8.lexicographicallyPrecedes(other.utf8)
    }

    private func joinSideAOwner(_ entity: Schema.Entity, _ relationship: Schema.Relationship) -> Bool {
        guard let inverseName = relationship.inverse,
            let destination = container?.schema.entity(forName: relationship.destination),
            let inverse = destination.relationships.first(where: { $0.name == inverseName })
        else { return relationship.inverse == nil }
        guard inverse.isToMany else { return false }
        return isCanonicalSideA(entity, relationship)
    }

    private func isToManyStorageOwner(_ entity: Schema.Entity, _ relationship: Schema.Relationship) -> Bool {
        guard let inverseName = relationship.inverse,
            let destination = container?.schema.entity(forName: relationship.destination),
            let inverse = destination.relationships.first(where: { $0.name == inverseName })
        else { return true }
        return inverse.isToMany && !isCanonicalSideA(entity, relationship)
    }

    private func joinTableName(for entity: Schema.Entity, _ relationship: Schema.Relationship) -> String? {
        guard relationship.isToMany else { return nil }
        guard let inverseName = relationship.inverse,
            let destination = container?.schema.entity(forName: relationship.destination),
            let inverse = destination.relationships.first(where: { $0.name == inverseName })
        else {
            guard relationship.inverse == nil else { return nil }
            return
                "Z_\(entity.name.uppercased())_\(relationship.name.uppercased())_\(relationship.destination.uppercased())"
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

    private func loadRelationshipDestination(
        _ type: any PersistentModel.Type, primaryKey: Int64, store: any RuntimeStore,
        visited: inout Set<EntityPrimaryKey>, materializeRelations: Bool = true
    ) throws -> (any PersistentModel)? {
        func load<Model: PersistentModel>(_ type: Model.Type) throws -> Model? {
            guard let entity = container?.schema.entity(forName: String(describing: Model.self)) else { return nil }
            let key = EntityPrimaryKey(entityName: entity.name, primaryKey: primaryKey)
            guard visited.insert(key).inserted else {
                if let existing = identityMap.model(for: key, as: Model.self) { return existing }
                let attributes = canonicalAttributes(for: entity)
                let columns = attributes.map { "Z\($0.name.uppercased())" }
                let selected = (["Z_PK", "Z_OPT"] + columns).joined(separator: ", ")
                guard
                    let row = try store.read({ connection in
                        try connection.rows(
                            "SELECT \(selected) FROM Z\(entity.name.uppercased()) WHERE Z_PK = ?",
                            arguments: [.int(primaryKey)])
                    }).first
                else { return nil }
                let model = try materialize(
                    Model.self, entity: entity, attributes: attributes, row: row, storeIdentifier: storeIdentifier,
                    primaryKey: primaryKey, version: row.count > 1 ? runtimeInt(row[1]) : 0)
                identityMap.register(model, for: key)
                return model
            }
            defer { visited.remove(key) }
            if let existing = identityMap.model(for: key, as: Model.self) {
                if !existing.hasChanges, materializeRelations {
                    try refreshStoredAttributes(existing, entity: entity, key: primaryKey, store: store)
                    try materializeRelationships(
                        [existing], entity: entity, primaryKeys: [primaryKey], store: store,
                        visited: &visited)
                }
                return existing
            }
            let attributes = canonicalAttributes(for: entity)
            let columns = attributes.map { "Z\($0.name.uppercased())" }
            let selected = (["Z_PK", "Z_OPT"] + columns).joined(separator: ", ")
            let row = try store.read { connection in
                try connection.rows(
                    "SELECT \(selected) FROM Z\(entity.name.uppercased()) WHERE Z_PK = ?", arguments: [.int(primaryKey)]
                )
            }.first
            guard let row else { return nil }
            let model = try materialize(
                Model.self, entity: entity, attributes: attributes, row: row, storeIdentifier: storeIdentifier,
                primaryKey: primaryKey, version: row.count > 1 ? runtimeInt(row[1]) : 0)
            identityMap.register(model, for: key)
            if materializeRelations {
                try materializeRelationships(
                    [model], entity: entity, primaryKeys: [primaryKey], store: store,
                    visited: &visited)
            }
            return model
        }
        return try load(type)
    }

    private func refreshStoredAttributes<Model: PersistentModel>(
        _ model: Model, entity: Schema.Entity, key: Int64, store: any RuntimeStore
    ) throws {
        guard !model.hasChanges else { return }
        let attributes = canonicalAttributes(for: entity)
        let columns = attributes.map { "Z\($0.name.uppercased())" }
        let selectedColumns = (["Z_PK", "Z_OPT"] + columns).joined(separator: ", ")
        guard
            let row = try store.read({ connection in
                try connection.rows(
                    "SELECT \(selectedColumns) FROM Z\(entity.name.uppercased()) WHERE Z_PK = ?",
                    arguments: [.int(key)])
            }).first
        else { return }
        try refreshAttributes(model, entity: entity, attributes: attributes, row: row)
    }

    private func runtimeInt(_ value: RuntimeValue) -> Int {
        if case let .int(number) = value { return Int(number) }
        return 0
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

    private func runtimeValue(_ value: StoredValue) -> RuntimeValue {
        switch value {
        case .null: .null
        case let .int(value): .int(value)
        case let .double(value): .double(value)
        case let .text(value): .text(value)
        case let .blob(value): .blob(value)
        }
    }

    private func entityID(for name: String) -> Int {
        (container?.schema.entities.firstIndex(where: { $0.name == name }) ?? 0) + 1
    }

    private func persistPendingChanges(to store: any RuntimeStore) throws {
        let pending = state.pendingState()
        let models = pending.inserted + pending.changed
        let insertedIDs = Set(pending.inserted.map(ObjectIdentifier.init))
        let persisted: [(any PersistentModel, Int64)] = try store.write { connection in
            var results: [(any PersistentModel, Int64)] = []
            let entitiesToPersist = relationshipOrderedEntities(models)
            for model in entitiesToPersist {
                try persistModel(
                    model, inserted: insertedIDs.contains(ObjectIdentifier(model)),
                    connection: connection, append: &results)
            }
            let assignedIDs = Dictionary(uniqueKeysWithValues: results.map { (ObjectIdentifier($0.0), $0.1) })
            for owner in pending.inserted {
                guard let entity = container?.schema.entity(forName: String(describing: type(of: owner))),
                    let adapters = container?.relationshipAdapterTable[ObjectIdentifier(type(of: owner))],
                    let ownerPK = assignedIDs[ObjectIdentifier(owner)]
                else { continue }
                for relationship in canonicalRelationships(for: entity)
                where !relationship.isToMany && isToOneStorageOwner(entity, relationship) {
                    guard let adapter = adapters.first(where: { $0.name == relationship.name }) else { continue }
                    let destinationPK = adapter.read(owner)?.first.flatMap { endpoint in
                        endpoint.persistentModelID.primaryKey ?? assignedIDs[ObjectIdentifier(endpoint)]
                    }
                    try connection.execute(
                        "UPDATE Z\(entity.name.uppercased()) SET Z\(relationship.name.uppercased()) = ? WHERE Z_PK = ?",
                        arguments: [destinationPK.map(RuntimeValue.int) ?? .null, .int(ownerPK)])
                }
            }
            for event in pending.relationshipMutationEvents where !insertedIDs.contains(ObjectIdentifier(event.owner)) {
                guard !event.relationship.isToMany,
                    let entity = container?.schema.entity(forName: String(describing: type(of: event.owner))),
                    isToOneStorageOwner(entity, event.relationship),
                    let ownerPK = event.owner.persistentModelID.primaryKey
                        ?? assignedIDs[ObjectIdentifier(event.owner)]
                else { continue }
                let destinationPK = event.newEndpoints.first.flatMap { endpoint in
                    endpoint.persistentModelID.primaryKey ?? assignedIDs[ObjectIdentifier(endpoint)]
                }
                try connection.execute(
                    "UPDATE Z\(entity.name.uppercased()) SET Z\(event.property.uppercased()) = ? WHERE Z_PK = ?",
                    arguments: [destinationPK.map(RuntimeValue.int) ?? .null, .int(ownerPK)])
            }
            try persistRelationships(
                pending.relationshipMutationEvents, insertedModels: pending.inserted,
                insertionSnapshots: pending.snapshots.mapValues(\.1),
                assignedIDs: assignedIDs, connection: connection)
            for model in pending.deleted {
                try cleanupRelationships(for: model, connection: connection)
            }
            for model in pending.deleted {
                guard let pk = model.persistentModelID.primaryKey else { continue }
                try connection.execute(
                    "DELETE FROM Z\(model.persistentModelID.entityName.uppercased()) WHERE Z_PK = ?",
                    arguments: [.int(pk)])
                guard connection.changesCount() == 1 else {
                    throw SwiftDataError.unsupportedStore("Delete did not affect exactly one row.")
                }
            }
            return results
        }
        for model in pending.deleted {
            if let pk = model.persistentModelID.primaryKey {
                identityMap.remove(EntityPrimaryKey(entityName: model.persistentModelID.entityName, primaryKey: pk))
            }
            state.removeBaseline(for: model)
            model.detachDeletedLifecycle()
        }
        for (model, pk) in persisted {
            let entityName = model.persistentModelID.entityName
            let originalIdentifier = state.snapshotIdentifier(for: model)
            model.markPersistedLifecycle(
                storeIdentifier: storeIdentifier, entityID: entityID(for: entityName), primaryKey: pk, version: 1)
            identityMap.register(model, for: EntityPrimaryKey(entityName: entityName, primaryKey: pk))
            if let old = originalIdentifier, old.isTemporary {
                temporaryIdentifiers[old] = model.persistentModelID
            }
        }
        finalizePendingChanges()
    }

    private func persistModel(
        _ model: any PersistentModel, inserted: Bool, connection: any RuntimeConnection,
        append: inout [(any PersistentModel, Int64)]
    ) throws {
        func typed<Model: PersistentModel>(_ model: Model) throws {
            guard let entity = container?.schema.entity(forName: String(describing: Model.self)) else { return }
            let adapters = Model.persistenceAdapters()
            var columns: [String] = []
            var values: [RuntimeValue] = []
            for attribute in canonicalAttributes(for: entity) {
                guard let adapter = adapters.first(where: { $0.name == attribute.name }) else { continue }
                columns.append("Z\(attribute.name.uppercased())")
                values.append(runtimeValue(try adapter.encoded(model)))
            }
            for relationship in canonicalRelationships(for: entity)
            where !relationship.isToMany && isToOneStorageOwner(entity, relationship) {
                guard inserted || model.persistentModelID.primaryKey != nil else { continue }
                guard
                    let relationshipAdapter = container?.relationshipAdapterTable[ObjectIdentifier(Model.self)]?
                        .first(where: { $0.name == relationship.name })
                else { continue }
                columns.append("Z\(relationship.name.uppercased())")
                values.append(
                    relationshipAdapter.read(model)?.first?.persistentModelID.primaryKey
                        .map(RuntimeValue.int) ?? .null)
            }
            let table = "Z\(entity.name.uppercased())"
            if inserted {
                let names = (["Z_ENT", "Z_OPT"] + columns).joined(separator: ", ")
                let placeholders = Array(repeating: "?", count: columns.count + 2).joined(separator: ", ")
                try connection.execute(
                    "INSERT INTO \(table) (\(names)) VALUES (\(placeholders))",
                    arguments: [.int(Int64(entityID(for: entity.name))), .int(1)] + values)
                append.append((model, connection.lastInsertRowID()))
            } else if let pk = model.persistentModelID.primaryKey, !columns.isEmpty {
                let assignments = columns.map { "\($0) = ?" }.joined(separator: ", ")
                try connection.execute(
                    "UPDATE \(table) SET \(assignments), Z_OPT = Z_OPT + 1 WHERE Z_PK = ?",
                    arguments: values + [.int(pk)])
                guard connection.changesCount() == 1 else {
                    throw SwiftDataError.unsupportedStore("Update did not affect exactly one row.")
                }
                append.append((model, pk))
            }
        }
        func dispatch<Model: PersistentModel>(_ model: Model) throws { try typed(model) }
        try dispatch(model)
    }

    private func persistRelationships(
        _ events: [ContextState.RelationshipMutationEvent], insertedModels: [any PersistentModel],
        insertionSnapshots _: [ObjectIdentifier: BackingDataSnapshot],
        assignedIDs: [ObjectIdentifier: Int64], connection: any RuntimeConnection
    ) throws {
        func primaryKey(for model: any PersistentModel) -> Int64? {
            model.persistentModelID.primaryKey ?? assignedIDs[ObjectIdentifier(model)]
        }
        var relationships: [String: (any PersistentModel, Schema.Relationship, [any PersistentModel])] = [:]
        let insertedIDs = Set(insertedModels.map(ObjectIdentifier.init))
        for event in events where !insertedIDs.contains(ObjectIdentifier(event.owner)) {
            relationships[relationshipValueKey(event.owner, event.property)] =
                (event.owner, event.relationship, event.newEndpoints)
        }
        for owner in insertedModels {
            guard let entity = container?.schema.entity(forName: String(describing: type(of: owner))),
                let adapters = container?.relationshipAdapterTable[ObjectIdentifier(type(of: owner))]
            else { continue }
            for relationship in canonicalRelationships(for: entity) {
                guard let adapter = adapters.first(where: { $0.name == relationship.name }),
                    relationship.isToMany,
                    let endpoints = adapter.read(owner)
                else { continue }
                relationships[relationshipValueKey(owner, relationship.name)] =
                    (owner, relationship, endpoints)
            }
        }

        var toOneValues: [String: (Schema.Entity, Schema.Relationship, Int64, Int64?)] = [:]
        var replacedRows: [String: (Set<Int64>, Set<Int64>)] = [:]
        var pairs: [String: [String: (Int64, Int64)]] = [:]
        for (owner, relationship, endpoints) in relationships.values {
            guard let entity = container?.schema.entity(forName: String(describing: type(of: owner))),
                let ownerPK = primaryKey(for: owner)
            else { throw SwiftDataError.unsupportedStore("Relationship owner has no persistent row identity.") }
            if !relationship.isToMany {
                guard isToOneStorageOwner(entity, relationship) else { continue }
                toOneValues[relationshipValueKey(owner, relationship.name)] = (
                    entity, relationship, ownerPK, endpoints.first.flatMap(primaryKey(for:))
                )
                continue
            }

            let sideA = relationship.inverse == nil || joinSideAOwner(entity, relationship)
            let tableEntity: Schema.Entity
            let tableRelationship: Schema.Relationship
            if sideA {
                tableEntity = entity
                tableRelationship = relationship
            } else {
                guard let inverseName = relationship.inverse,
                    let destination = container?.schema.entity(forName: relationship.destination),
                    let inverse = destination.relationships.first(where: { $0.name == inverseName })
                else { continue }
                tableEntity = destination
                tableRelationship = inverse
            }
            guard let table = joinTableName(for: tableEntity, tableRelationship) else { continue }
            var replaced = replacedRows[table] ?? ([], [])
            if sideA { replaced.0.insert(ownerPK) } else { replaced.1.insert(ownerPK) }
            replacedRows[table] = replaced
            for endpoint in endpoints {
                guard let endpointPK = primaryKey(for: endpoint) else {
                    throw SwiftDataError.unsupportedStore(
                        "Relationship endpoint '\(String(describing: type(of: endpoint)))' has no assigned row identity."
                    )
                }
                if !sideA, insertedIDs.contains(ObjectIdentifier(owner)),
                    let inverseName = relationship.inverse,
                    let inverse = relationshipAdapter(for: endpoint, property: inverseName),
                    (inverse.read(endpoint) ?? []).contains(where: { $0 === owner })
                {
                    continue
                }
                guard String(describing: type(of: endpoint)) == relationship.destination else {
                    throw SwiftDataError.unsupportedStore(
                        "Relationship '\(entity.name).\(relationship.name)' received endpoint type "
                            + "'\(String(describing: type(of: endpoint)))' instead of '\(relationship.destination)'.")
                }
                let pair = sideA ? (ownerPK, endpointPK) : (endpointPK, ownerPK)
                pairs[table, default: [:]]["\(pair.0):\(pair.1)"] = pair
            }
        }

        for (entity, relationship, ownerPK, endpointPK) in toOneValues.values {
            try connection.execute(
                "UPDATE Z\(entity.name.uppercased()) SET Z\(relationship.name.uppercased()) = ? WHERE Z_PK = ?",
                arguments: [endpointPK.map(RuntimeValue.int) ?? .null, .int(ownerPK)])
            guard connection.changesCount() == 1 else {
                throw SwiftDataError.unsupportedStore("Relationship update did not affect exactly one row.")
            }
        }

        for (table, replaced) in replacedRows {
            for ownerPK in replaced.0 {
                try connection.execute("DELETE FROM \(table) WHERE Z_A = ?", arguments: [.int(ownerPK)])
            }
            for ownerPK in replaced.1 {
                try connection.execute(
                    "DELETE FROM \(table) WHERE Z_B = ?", arguments: [.int(ownerPK)])
            }
            for (sideA, sideB) in pairs[table, default: [:]].values.sorted(by: {
                $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
            }) {
                try connection.execute(
                    "INSERT INTO \(table) (Z_A, Z_B) VALUES (?, ?)", arguments: [.int(sideA), .int(sideB)])
            }
        }
    }

    private func relationshipValueKey(_ owner: any PersistentModel, _ property: String) -> String {
        "\(ObjectIdentifier(owner)):\(property)"
    }

    private func orderedForRelationshipPersistence(_ models: [any PersistentModel]) -> [any PersistentModel] {
        var result: [any PersistentModel] = []
        var visiting = Set<ObjectIdentifier>()
        var visited = Set<ObjectIdentifier>()
        func visit(_ model: any PersistentModel) {
            let identifier = ObjectIdentifier(model)
            guard !visited.contains(identifier), visiting.insert(identifier).inserted else { return }
            if let entity = container?.schema.entity(forName: String(describing: type(of: model))),
                let adapters = container?.relationshipAdapterTable[ObjectIdentifier(type(of: model))]
            {
                for relationship in canonicalRelationships(for: entity) where !relationship.isToMany {
                    guard isToOneStorageOwner(entity, relationship),
                        let adapter = adapters.first(where: { $0.name == relationship.name })
                    else { continue }
                    for endpoint in adapter.read(model) ?? [] where models.contains(where: { $0 === endpoint }) {
                        visit(endpoint)
                    }
                }
            }
            visiting.remove(identifier)
            visited.insert(identifier)
            result.append(model)
        }
        for model in models { visit(model) }
        return result
    }

    private func relationshipOrderedEntities(_ models: [any PersistentModel]) -> [any PersistentModel] {
        var rankByModel: [ObjectIdentifier: Int] = [:]
        for (rank, entity) in (container?.schema.entities ?? []).enumerated() {
            for model in models where String(describing: type(of: model)) == entity.name {
                rankByModel[ObjectIdentifier(model)] = rank
            }
        }
        return orderedForRelationshipPersistence(models).sorted { lhs, rhs in
            (rankByModel[ObjectIdentifier(lhs)] ?? Int.max) < (rankByModel[ObjectIdentifier(rhs)] ?? Int.max)
        }
    }

    private func unsupportedStore(_ operation: String) -> SwiftDataError {
        .unsupportedStore("\(operation) is unavailable without a persistent store.")
    }

    private func snapshot(of model: any PersistentModel) -> BackingDataSnapshot {
        func snapshotTyped<Model: PersistentModel>(_ model: Model) -> BackingDataSnapshot {
            model.snapshotLifecycle()
        }
        return snapshotTyped(model)
    }

    private func capture<Model: PersistentModel>(_ model: Model) {
        state.willMutate(model, snapshot: model.snapshotLifecycle())
    }

    private func rollbackCurrentTransaction() {
        guard let frame = state.popTransactionSnapshot() else { return }
        let pending = state.pendingState()
        let currentModels = pending.inserted + pending.changed + pending.deleted
        let frameInsertions = frame.pending.inserted
        for (model, snapshot) in frame.modelSnapshots.values {
            if state.contains(model, in: frameInsertions) || snapshot.context === self {
                model.restoreLifecycle(snapshot)
            } else {
                model.restoreValuesAndDetachLifecycle(snapshot)
            }
        }
        for model in currentModels
        where !state.contains(model, in: frame.pending.inserted)
            && !state.contains(model, in: frame.pending.changed)
            && !state.contains(model, in: frame.pending.deleted)
        {
            let identifier = ObjectIdentifier(model)
            if state.contains(model, in: pending.inserted), let insertionSnapshot = pending.snapshots[identifier] {
                model.restoreValuesAndDetachLifecycle(insertionSnapshot.1)
            } else if let entry = frame.snapshots[identifier] {
                model.restoreLifecycle(entry.1)
            } else if model.modelContext === self {
                detachModel(model)
            }
        }
        state.restorePendingState(frame.pending)
        state.restoreBaselineSnapshots(frame.baselineSnapshots)
    }

    private func finalizePendingChanges() {
        let pending = state.pendingState()
        for model in orderedForRelationshipPersistence(pending.inserted + pending.changed) {
            model.markSavedLifecycle()
            state.setBaseline(model, snapshot: model.snapshotLifecycle())
        }
        for model in pending.deleted {
            state.removeBaseline(for: model)
            model.detachDeletedLifecycle()
            model.markSavedLifecycle()
        }
        state.clearPending()
    }

    private func cancelInsertion(_ model: any PersistentModel) {
        func cancelTyped<Model: PersistentModel>(_ model: Model) {
            model.persistentBackingData.cancelInsertion()
        }
        cancelTyped(model)
    }

    private func detachModel(_ model: any PersistentModel) {
        func detachTyped<Model: PersistentModel>(_ model: Model) {
            model.detachLifecycle()
        }
        detachTyped(model)
    }

    private func markDeletedTyped<Model: PersistentModel>(_ model: Model) {
        model.persistentBackingData.markDeleted()
    }

}

/// Describes a model fetch request.
