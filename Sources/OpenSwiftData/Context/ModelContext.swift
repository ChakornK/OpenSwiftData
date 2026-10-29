import Foundation
import OSDCore
import Dispatch

package enum ModelContextAffinity: @unchecked Sendable {
    case mainActor
    case unchecked
}

/// A synchronous unit of work for inserting, fetching, and saving persistent models.
public final class ModelContext {
    /// The container that owns this context, when it was created by a container.
    public internal(set) var container: ModelContainer? {
        get {
            assertAffinity()
            return containerStorage
        }
        set {
            assertAffinity()
            containerStorage = newValue
        }
    }
    private var containerStorage: ModelContainer?
    private var autosaveEnabledStorage = false
    private var historyAuthorStorage: String?
    /// Whether this context saves changes automatically after a coalesced delay.
    public var autosaveEnabled: Bool {
        get {
            assertAffinity()
            return autosaveEnabledStorage
        }
        set {
            assertAffinity()
            autosaveEnabledStorage = newValue
            autosaveHandle.setEnabled(newValue)
        }
    }
    /// The optional author recorded with history transactions created by this context.
    public var historyAuthor: String? {
        get { assertAffinity(); return historyAuthorStorage }
        set { assertAffinity(); historyAuthorStorage = newValue }
    }
    /// The undo manager associated with this context.
    public var undoManager: UndoManager? {
        get {
            assertAffinity()
            return undoManagerStorage
        }
        set {
            assertAffinity()
            undoManagerStorage = newValue
        }
    }
    private var undoManagerStorage: UndoManager?

    package nonisolated let state: ContextState
    private let affinity: ModelContextAffinity
    package let affinityToken: ModelExecutorAffinityToken?
    private let testSaveHook: (() throws -> Void)?
    private var allowsSave = true
    private let identityMap = IdentityMap()
    private var relationshipFaultResolver: RelationshipFaultResolver?
    private let changeInbox = ChangeInbox()
    private var storeHub: StoreHub?
    private var storeHubSubscription: UUID?
    private var storeHubStoreIdentifier: ObjectIdentifier?
    private var lastObservedDataVersion: Int64?
    private let autosaveTrigger: AutosaveTrigger
    private let autosaveHandle: AutosaveHandle
    private let autosaveContextReference: AutosaveContextReference
    private var temporaryIdentifiers: [PersistentIdentifier: PersistentIdentifier] = [:]
    private var relationshipLoadVisited = Set<EntityPrimaryKey>()

    private func relationshipResolver() throws -> RelationshipFaultResolver? {
        assertAffinity()
        guard let container, container.store != nil else { return nil }
        if let relationshipFaultResolver { return relationshipFaultResolver }
        let resolver = try RelationshipFaultResolver(
            context: self, container: container, state: state, identityMap: identityMap)
        relationshipFaultResolver = resolver
        return resolver
    }

    private func subscribeToStoreChanges() {
        guard containerStorage?.store != nil, let container = containerStorage else { return }
        let hub = StoreHubRegistry.hub()
        storeHub = hub
        storeHubStoreIdentifier = ObjectIdentifier(container.storeIdentityHandle)
        storeHubSubscription = hub.subscribe(changeInbox)
    }

    deinit {
        if let storeHubSubscription {
            storeHub?.unsubscribe(storeHubSubscription)
        }
    }

    private struct PersistedModel {
        let model: any PersistentModel
        let primaryKey: Int64
        let version: Int
        let replacedModel: (any PersistentModel)?
    }

    private struct IdentifierQueryRow {
        let identifier: PersistentIdentifier
        let sortValues: [RuntimeValue]
    }

    /// Creates a context not associated with a model container.
    public convenience init() {
        self.init(container: nil, autosaveEnabled: false)
    }

    package init(
        container: ModelContainer?,
        autosaveEnabled: Bool,
        autosaveScheduler: any AutosaveScheduler = DispatchAutosaveScheduler(),
        affinity: ModelContextAffinity = .unchecked,
        affinityToken: ModelExecutorAffinityToken? = nil
    ) {
        containerStorage = container
        self.affinity = affinityToken == nil ? affinity : .unchecked
        self.affinityToken = affinityToken
        autosaveTrigger = AutosaveTrigger(scheduler: autosaveScheduler)
        autosaveContextReference = AutosaveContextReference()
        autosaveHandle = AutosaveHandle(trigger: autosaveTrigger, enabled: autosaveEnabled) {
            [autosaveContextReference] in
            Task { @MainActor in
                autosaveContextReference.withContext { context in
                    guard context.affinityToken == nil else { return }
                    guard context.autosaveEnabled, context.hasChanges else { return }
                    do {
                        try context.save()
                    } catch {
                        OSDLog.debug("Autosave failed: \(error)")
                    }
                }
            }
        }
        state = ContextState(
            relationshipAdaptersByModel: container?.relationshipAdapterTable ?? [:],
            storeIdentifier: container?.configurations.first?.name ?? "default",
            entityIDsByName: Dictionary(
                uniqueKeysWithValues: (container?.schema.entities ?? []).enumerated().map { ($1.name, $0 + 1) }),
            entitiesByName: Dictionary(uniqueKeysWithValues: (container?.schema.entities ?? []).map { ($0.name, $0) }),
            onLocalChange: { [autosaveHandle] in autosaveHandle.changed() })
        autosaveEnabledStorage = autosaveEnabled
        allowsSave = container?.configurations.first?.allowsSave ?? true
        testSaveHook = nil
        autosaveContextReference.set(self)
        subscribeToStoreChanges()
    }

    internal init(testSave hook: @escaping () throws -> Void, container: ModelContainer? = nil) {
        containerStorage = container
        affinity = .unchecked
        affinityToken = nil
        autosaveTrigger = AutosaveTrigger(scheduler: DispatchAutosaveScheduler())
        autosaveContextReference = AutosaveContextReference()
        autosaveHandle = AutosaveHandle(trigger: autosaveTrigger, enabled: false, schedule: {})
        state = ContextState(
            relationshipAdaptersByModel: container?.relationshipAdapterTable ?? [:],
            storeIdentifier: container?.configurations.first?.name ?? "default",
            entityIDsByName: Dictionary(
                uniqueKeysWithValues: (container?.schema.entities ?? []).enumerated().map { ($1.name, $0 + 1) }),
            entitiesByName: Dictionary(uniqueKeysWithValues: (container?.schema.entities ?? []).map { ($0.name, $0) }))
        autosaveEnabledStorage = false
        allowsSave = true
        testSaveHook = hook
        autosaveContextReference.set(self)
        subscribeToStoreChanges()
    }

    /// Models inserted into this context and not yet saved.
    public var insertedModelsArray: [any PersistentModel] {
        assertAffinity()
        return state.insertedModels
    }
    /// Models changed in this context and not yet saved.
    public var changedModelsArray: [any PersistentModel] {
        assertAffinity()
        return state.changedModels
    }
    /// Models deleted in this context and not yet saved.
    public var deletedModelsArray: [any PersistentModel] {
        assertAffinity()
        return state.deletedModels
    }
    /// Compatibility alias for inserted models.
    public var insertedModels: [any PersistentModel] { insertedModelsArray }
    /// Compatibility alias for changed models.
    public var changedModels: [any PersistentModel] { changedModelsArray }
    /// Compatibility alias for deleted models.
    public var deletedModels: [any PersistentModel] { deletedModelsArray }
    /// Whether this context currently has unsaved changes.
    public var hasChanges: Bool {
        assertAffinity()
        return state.hasChanges
    }
    /// Sort descriptors used by this context.
    private var sortDescriptorsStorage: [NSSortDescriptor] = []
    /// Sort descriptors used by this context.
    public var sortDescriptors: [NSSortDescriptor] {
        get {
            assertAffinity()
            return sortDescriptorsStorage
        }
        set {
            assertAffinity()
            sortDescriptorsStorage = newValue
        }
    }

    /// Inserts a detached model into this context.
    public func insert<Model: PersistentModel>(_ model: Model) {
        assertAffinity()
        state.withExclusiveOperation {
            guard model.modelContext == nil else { return }
            insertRelationshipDestination(model, snapshot: model.snapshotLifecycle())
        }
    }

    func insertRelationshipDestination(_ model: any PersistentModel, snapshot: BackingDataSnapshot) {
        assertAffinity()
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
        func attach<Model: PersistentModel>(_ model: Model) {
            guard container?.store != nil else {
                model.persistentBackingData.attach(to: self, model: model)
                model.setInsertionChanged()
                state.setBaseline(model, snapshot: model.snapshotLifecycle())
                return
            }
            let managed = Model.createManagedBackingData(
                values: insertionSnapshot.values, context: self,
                storeIdentifier: storeIdentifier, entityID: entityID(for: String(describing: Model.self)),
                identifier: insertionSnapshot.identifier)
            model.persistentBackingData = managed
            model.persistentBackingData.attach(to: self, model: model)
            model.setInsertionChanged()
            state.setBaseline(model, snapshot: model.snapshotLifecycle())
        }
        state.insert(model, snapshot: insertionSnapshot)
        attach(model)
    }

    /// Deletes a model or cancels its pending insertion.
    public func delete<Model: PersistentModel>(_ model: Model) {
        assertAffinity()
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

        let scheduledRoots = roots
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
            roots: scheduledRoots, cascadeScheduled: cascadeScheduled,
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
        assertAffinity()
        try state.withExclusiveOperation { try processPendingChangesLocked() }
    }

    private func processPendingChangesLocked() throws {
        assertAffinity()
        try mergeStoreChanges()
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

    private func mergeStoreChanges() throws {
        assertAffinity()
        guard let store = container?.store else {
            _ = changeInbox.drain()
            return
        }
        let changes = changeInbox.drain()
        guard !changes.isEmpty else { return }
        guard let storeHubStoreIdentifier else { return }
        let relevantChanges = changes.filter {
            $0.storeIdentifier == storeHubStoreIdentifier && $0.sourceSubscription != storeHubSubscription
        }
        let hasWildcardChange = relevantChanges.contains(where: \.allEntitiesChanged)
        let changedKeys = relevantChanges.reduce(into: Set<StoreEntityKey>()) { keys, change in
            keys.formUnion(change.inserted)
            keys.formUnion(change.updated)
            keys.formUnion(change.deleted)
        }
        if hasWildcardChange {
            for (key, model) in identityMap.liveModels() where !model.hasChanges {
                guard let entity = container?.schema.entity(forName: key.entityName) else { continue }
                try refreshRegisteredModel(type(of: model), entity: entity, primaryKey: key.primaryKey, store: store)
            }
        }
        for key in changedKeys {
            guard let entity = container?.schema.entity(forName: key.entityName),
                let type = container?.modelType(forEntityName: key.entityName)
            else { continue }
            invalidateRelationships(on: type, entity: entity, primaryKey: key.primaryKey)
            try refreshRegisteredModel(type, entity: entity, primaryKey: key.primaryKey, store: store)
        }
    }

    /// Checks for commits made outside this process when the backend supports data-version polling.
    /// The first call records a baseline. Polling is explicit and disabled unless the caller invokes this method.
    public func pollForExternalChanges() throws {
        assertAffinity()
        guard let store = container?.store, let storeHubStoreIdentifier,
            let version = try store.dataVersion()
        else { return }
        guard let previous = lastObservedDataVersion else {
            lastObservedDataVersion = version
            return
        }
        guard previous != version else { return }
        lastObservedDataVersion = version
        storeHub?.publish(
            storeIdentifier: storeHubStoreIdentifier,
            sourceSubscription: UUID(),
            allEntitiesChanged: true,
            inserted: [], updated: [], deleted: [])
        try processPendingChanges()
    }

    private func invalidateRelationships(
        on type: any PersistentModel.Type,
        entity: Schema.Entity,
        primaryKey: Int64
    ) {
        func invalidate<Model: PersistentModel>(_ type: Model.Type) {
            let key = EntityPrimaryKey(entityName: entity.name, primaryKey: primaryKey)
            guard let model = identityMap.model(for: key, as: Model.self), !model.hasChanges,
                let backing = model.persistentBackingData as? ManagedBackingData<Model>
            else { return }
            let relationships = Set(entity.relationships.map(\.name))
            let keyPaths = Set(
                Model.schemaMetadata().compactMap { metadata in
                    relationships.contains(metadata.name) && metadata.isRelationship ? metadata.keypath : nil
                })
            backing.invalidateRelationshipValues(keyPaths)
        }
        invalidate(type)
    }

    private func refreshRegisteredModel(
        _ type: any PersistentModel.Type,
        entity: Schema.Entity,
        primaryKey: Int64,
        store: any RuntimeStore
    ) throws {
        func refresh<Model: PersistentModel>(_ type: Model.Type) throws {
            let key = EntityPrimaryKey(entityName: entity.name, primaryKey: primaryKey)
            guard let model = identityMap.model(for: key, as: Model.self), !model.hasChanges else { return }
            let attributes = canonicalAttributes(for: entity)
            let columns = storedColumnNames(for: attributes).map { "Z\($0.uppercased())" }.joined(separator: ", ")
            let selectedColumns = columns.isEmpty ? "Z_PK, Z_OPT" : "Z_PK, Z_OPT, \(columns)"
            guard
                let row = try store.read({ connection in
                    try connection.rows(
                        "SELECT \(selectedColumns) FROM Z\(entity.name.uppercased()) WHERE Z_PK = ?",
                        arguments: [.int(primaryKey)])
                }).first
            else {
                identityMap.remove(key)
                state.removeBaseline(for: model)
                model.persistentBackingData.markDeleted()
                model.detachDeletedLifecycle()
                return
            }
            try refreshAttributes(model, entity: entity, attributes: attributes, row: row)
            refreshVersion(model, version: row.count > 1 ? runtimeInt(row[1]) : 0)
        }
        try refresh(type)
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
        assertAffinity()
        _ = (model, predicate, includeSubclasses)
        throw unsupportedStore("Predicate-based delete")
    }

    /// Fetches models matching a descriptor, which requires a persistent store.
    public func fetch<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) throws -> [Model] {
        assertAffinity()
        try processPendingChanges()
        guard let store = container?.store else { throw unsupportedStore("Fetch") }
        guard let entity = container?.schema.entity(forName: String(describing: Model.self)) else { return [] }
        let allAttributes = canonicalAttributes(for: entity)
        let requestedProperties = try selectedAttributes(descriptor.propertiesToFetch, entity: entity, type: Model.self)
        let selectedAttributesForMaterialization = allAttributes.filter { requestedProperties.contains($0.name) }
        let selectedColumns = storedColumnNames(for: selectedAttributesForMaterialization)
        let requestedRelationships = try selectedRelationships(
            descriptor.relationshipKeyPathsForPrefetching, entity: entity, type: Model.self)
        if let limit = descriptor.fetchLimit, limit < 0 {
            throw SwiftDataError.unsupportedPredicate("Negative fetch limit")
        }
        if let offset = descriptor.fetchOffset, offset < 0 {
            throw SwiftDataError.unsupportedPredicate("Negative fetch offset")
        }
        let fetchedLimit: Int?
        if descriptor.includePendingChanges {
            fetchedLimit = nil
        } else {
            fetchedLimit = descriptor.fetchLimit
        }
        let orderSQL = try sortSQL(descriptor.sortBy, entity: entity, type: Model.self)
        let compiled: RuntimeCompiledPredicate?
        if let predicate = descriptor.predicate {
            compiled = try compilePredicate(
                predicate, modelType: Model.self, entity: entity, store: store,
                ordering: descriptor.sortBy.compactMap(\.propertyName))
        } else {
            compiled = nil
        }
        if descriptor.includePendingChanges, descriptor.predicate != nil, compiled?.evaluatorPlan == nil,
            !(state.insertedModels + state.changedModels + state.deletedModels).isEmpty
        {
            throw SwiftDataError.unsupportedPredicate(
                "The store cannot evaluate this predicate against pending models.")
        }
        let query = FetchSQLBuilder.build(
            FetchSQLInput(
                table: "Z\(entity.name.uppercased())",
                columns: selectedColumns.map { "Z\($0.uppercased())" },
                predicateSQL: compiled?.sql,
                predicateArguments: compiled?.arguments ?? [],
                orderSQL: orderSQL,
                limit: fetchedLimit,
                offset: descriptor.includePendingChanges ? nil : descriptor.fetchOffset))
        let rows = try store.read { connection in
            try connection.rows(query.sql, arguments: query.arguments)
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
                    try refreshAttributes(
                        existing, entity: entity, attributes: selectedAttributesForMaterialization, row: row)
                }
                refreshVersion(existing, version: Int(version))
            } else {
                let candidate = try materialize(
                    Model.self, entity: entity, attributes: selectedAttributesForMaterialization, row: row,
                    storeIdentifier: storeIdentifier,
                    primaryKey: pk, version: Int(version))
                model = identityMap.canonicalHandle(for: key, candidate: candidate).model as? Model ?? candidate
            }
            if let backing = model.persistentBackingData as? ManagedBackingData<Model> {
                installPropertyFaults(
                    on: backing, type: Model.self, entity: entity, loadedAttributes: requestedProperties,
                    primaryKey: pk, store: store)
            }
            primaryKeys.append(pk)
            models.append(model)
        }
        relationshipLoadVisited.removeAll()
        var visited = relationshipLoadVisited
        try materializeRelationships(
            models, entity: entity, primaryKeys: primaryKeys, store: store,
            requested: Set(requestedRelationships),
            visited: &visited)
        relationshipLoadVisited = visited
        return try mergePending(
            models, descriptor: descriptor, entity: entity, evaluatorPlan: compiled?.evaluatorPlan)
    }

    /// Counts models matching a descriptor, which requires a persistent store.
    public func fetchCount<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) throws -> Int {
        assertAffinity()
        try processPendingChanges()
        if !descriptor.includePendingChanges {
            guard let store = container?.store,
                let entity = container?.schema.entity(forName: String(describing: Model.self))
            else { throw unsupportedStore("Fetch count") }
            if let limit = descriptor.fetchLimit, limit < 0 {
                throw SwiftDataError.unsupportedPredicate("Negative fetch limit")
            }
            if let offset = descriptor.fetchOffset, offset < 0 {
                throw SwiftDataError.unsupportedPredicate("Negative fetch offset")
            }
            let compiled = try compilePredicate(
                descriptor.predicate, modelType: Model.self, entity: entity, store: store,
                ordering: descriptor.sortBy.compactMap(\.propertyName))
            let whereSQL = compiled.map { " WHERE \($0.sql)" } ?? ""
            let countSQL = "SELECT COUNT(*) FROM Z\(entity.name.uppercased()) AS t0\(whereSQL)"
            let total = try store.read { connection -> Int in
                guard let row = try connection.rows(countSQL, arguments: compiled?.arguments ?? []).first,
                    case let .int(value)? = row.first
                else { return 0 }
                return Int(clamping: value)
            }
            let offset = descriptor.fetchOffset ?? 0
            guard offset < total else { return 0 }
            let remaining = total - offset
            return min(remaining, descriptor.fetchLimit ?? Int.max)
        }
        return try fetchIdentifiers(descriptor).count
    }

    /// Fetches identifiers matching a descriptor, which requires a persistent store.
    public func fetchIdentifiers<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>
    ) throws -> [PersistentIdentifier] {
        assertAffinity()
        try processPendingChanges()
        guard let store = container?.store,
            let entity = container?.schema.entity(forName: String(describing: Model.self))
        else { throw unsupportedStore("Identifier fetch") }
        if let fetchLimit = descriptor.fetchLimit, fetchLimit < 0 {
            throw SwiftDataError.unsupportedPredicate("Negative fetch limit")
        }
        if let fetchOffset = descriptor.fetchOffset, fetchOffset < 0 {
            throw SwiftDataError.unsupportedPredicate("Negative fetch offset")
        }
        let compiled = try compilePredicate(
            descriptor.predicate, modelType: Model.self, entity: entity, store: store,
            ordering: descriptor.sortBy.compactMap(\.propertyName))
        if descriptor.includePendingChanges, descriptor.predicate != nil, compiled?.evaluatorPlan == nil,
            !(state.insertedModels + state.changedModels + state.deletedModels).isEmpty
        {
            throw SwiftDataError.unsupportedPredicate(
                "The store cannot evaluate this predicate against pending models.")
        }
        let sortProperties = try sortProperties(descriptor.sortBy, entity: entity, type: Model.self)
        let orderSQL = try sortSQL(descriptor.sortBy, entity: entity, type: Model.self)
        let selectedColumns = (["t0.Z_PK"] + sortProperties.map { "t0.Z\($0.uppercased())" }).joined(separator: ", ")
        var sql = "SELECT \(selectedColumns) FROM Z\(entity.name.uppercased()) AS t0"
        if let compiled { sql += " WHERE \(compiled.sql)" }
        sql += " ORDER BY \(orderSQL), t0.Z_PK ASC"
        if !descriptor.includePendingChanges {
            if let limit = descriptor.fetchLimit {
                sql += " LIMIT \(limit)"
                if let offset = descriptor.fetchOffset { sql += " OFFSET \(offset)" }
            } else if let offset = descriptor.fetchOffset {
                sql += " LIMIT -1 OFFSET \(offset)"
            }
        }
        let rows = try store.read { try $0.rows(sql, arguments: compiled?.arguments ?? []) }
        var queryRows = rows.compactMap { row -> IdentifierQueryRow? in
            guard case let .int(primaryKey)? = row.first else { return nil }
            return IdentifierQueryRow(
                identifier: PersistentIdentifier(
                    storeIdentifier: storeIdentifier, entityName: entity.name, primaryKey: primaryKey),
                sortValues: Array(row.dropFirst()))
        }
        if descriptor.includePendingChanges {
            let pending = (state.insertedModels + state.changedModels).compactMap { $0 as? Model }.filter {
                !$0.isDeleted
            }
            let pendingIDs = Set(pending.map(\.persistentModelID))
            queryRows.removeAll { pendingIDs.contains($0.identifier) }
            let deletedIDs = Set(state.deletedModels.map(\.persistentModelID))
            queryRows.removeAll { deletedIDs.contains($0.identifier) }
            let propertyNames = Set(sortProperties)
            for model in pending {
                if let plan = compiled?.evaluatorPlan, try !pendingModel(model, matches: plan) { continue }
                let values = try runtimeValues(for: model, selecting: propertyNames)
                queryRows.append(
                    IdentifierQueryRow(
                        identifier: model.persistentModelID,
                        sortValues: sortProperties.map { values[$0] ?? .null }))
            }
        }
        if descriptor.includePendingChanges, !descriptor.sortBy.isEmpty {
            queryRows = queryRows.enumerated().sorted { lhs, rhs in
                for (index, descriptor) in descriptor.sortBy.enumerated() {
                    let comparison = compareSortValues(lhs.element.sortValues[index], rhs.element.sortValues[index])
                    if comparison != .orderedSame {
                        return descriptor.isAscending
                            ? comparison == .orderedAscending : comparison == .orderedDescending
                    }
                }
                let lhsPK = lhs.element.identifier.primaryKey ?? Int64.max
                let rhsPK = rhs.element.identifier.primaryKey ?? Int64.max
                if lhsPK != rhsPK { return lhsPK < rhsPK }
                return lhs.offset < rhs.offset
            }.map(\.element)
        } else if descriptor.includePendingChanges {
            queryRows = queryRows.enumerated().sorted { lhs, rhs in
                let lhsPK = lhs.element.identifier.primaryKey ?? Int64.max
                let rhsPK = rhs.element.identifier.primaryKey ?? Int64.max
                if lhsPK != rhsPK { return lhsPK < rhsPK }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
        var identifiers = queryRows.map(\.identifier)
        if descriptor.includePendingChanges {
            let offset = max(0, descriptor.fetchOffset ?? 0)
            guard offset < identifiers.count else { return [] }
            identifiers = Array(identifiers.dropFirst(offset))
            if let limit = descriptor.fetchLimit { identifiers = Array(identifiers.prefix(max(0, limit))) }
        }
        return identifiers
    }

    /// Enumerates models matching a descriptor, which requires a persistent store.
    public func enumerate<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>,
        batchSize: Int = 500,
        allowEscapingMutations: Bool = false,
        block: (Model) throws -> Void
    ) throws {
        assertAffinity()
        guard batchSize > 0 else { throw SwiftDataError.unsupportedPredicate("Batch size must be positive") }
        let identifiers = try fetchIdentifiers(descriptor)
        for start in stride(from: 0, to: identifiers.count, by: batchSize) {
            let end = min(start + batchSize, identifiers.count)
            for identifier in identifiers[start..<end] {
                guard let model: Model = try model(for: identifier) else { continue }
                if allowEscapingMutations {
                    try block(model)
                } else {
                    let snapshot = model.snapshotLifecycle()
                    let before = try modelValues(model)
                    do {
                        try block(model)
                    } catch {
                        model.restoreLifecycle(snapshot)
                        throw error
                    }
                    if try modelValues(model) != before {
                        model.restoreLifecycle(snapshot)
                        throw SwiftDataError.unsupportedStore("Enumeration mutations are not allowed")
                    }
                }
            }
        }
    }

    /// Finds a model by its persistent identifier, which requires a persistent store.
    public func model<Model: PersistentModel>(for identifier: PersistentIdentifier) throws -> Model? {
        assertAffinity()
        if state.deletedModels.contains(where: { $0.persistentModelID == identifier }) { return nil }
        if let pending = (state.insertedModels + state.changedModels).first(where: {
            $0.persistentModelID == identifier
        }) as? Model {
            return pending.isDeleted ? nil : pending
        }
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
            let columns = storedColumnNames(for: attributes).map { "Z\($0.uppercased())" }
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
                [registered], entity: entity, primaryKeys: [key], store: store, requested: nil, visited: &visited)
            relationshipLoadVisited = visited
            return registered
        }
        let attributes = canonicalAttributes(for: entity)
        let columns = storedColumnNames(for: attributes).map { "Z\($0.uppercased())" }.joined(separator: ", ")
        let selectedColumns = columns.isEmpty ? "Z_PK, Z_OPT" : "Z_PK, Z_OPT, \(columns)"
        let rows = try store.read {
            try $0.rows(
                "SELECT \(selectedColumns) FROM Z\(entity.name.uppercased()) WHERE Z_PK = ?",
                arguments: [.int(key)])
        }
        guard let row = rows.first else { return nil }
        let candidate = try materialize(
            Model.self, entity: entity, attributes: attributes, row: row, storeIdentifier: identifier.storeIdentifier,
            primaryKey: key, version: row.count > 1 ? runtimeInt(row[1]) : 0)
        let model =
            identityMap.canonicalHandle(
                for: EntityPrimaryKey(entityName: entity.name, primaryKey: key), candidate: candidate
            ).model as? Model
            ?? candidate
        relationshipLoadVisited.removeAll()
        var visited = relationshipLoadVisited
        try materializeRelationships(
            [model], entity: entity, primaryKeys: [key], store: store, requested: nil, visited: &visited)
        relationshipLoadVisited = visited
        return model
    }

    /// Returns a registered model by its persistent identifier, if present.
    public func registeredModel<Model: PersistentModel>(for identifier: PersistentIdentifier) -> Model? {
        assertAffinity()
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
        assertAffinity()
        try state.withExclusiveOperation {
            try processPendingChangesLocked()
            guard !state.hasTransaction else { return }
            try saveChanges()
        }
    }

    /// Fetches committed store history after the requested token.
    public func fetchHistory(_ descriptor: HistoryDescriptor = HistoryDescriptor()) throws -> [HistoryTransaction] {
        assertAffinity()
        guard let store = container?.store as? any RuntimeHistoryStore else {
            throw unsupportedStore("History is unavailable for the configured store.")
        }
        return try store.fetchHistory(descriptor)
    }

    /// Deletes history transactions through the supplied token and returns the number deleted.
    @discardableResult
    public func deleteHistory(before token: HistoryToken) throws -> Int {
        assertAffinity()
        guard let store = container?.store as? any RuntimeHistoryStore else {
            throw unsupportedStore("History is unavailable for the configured store.")
        }
        return try store.deleteHistory(before: token)
    }

    private func saveChanges() throws {
        assertAffinity()
        guard state.hasChanges else { return }
        guard allowsSave else { throw unsupportedStore("Saving is disabled") }
        let before = state.pendingState()
        let insertedModels = before.inserted
        let originalInsertedIDs = insertedModels.map { ($0, $0.persistentModelID) }
        let willInfo = saveNotificationInfo(
            inserted: before.inserted.map(\.persistentModelID),
            updated: before.changed.map(\.persistentModelID),
            deleted: before.deleted.map(\.persistentModelID))
        NotificationCenter.default.post(name: Self.willSave, object: self, userInfo: willInfo)

        if let testSaveHook {
            try testSaveHook()
            let savedIDs = saveNotificationIdentifiers(before: before, insertedModels: originalInsertedIDs)
            finalizePendingChanges()
            state.clearRelationshipMutationEvents()
            NotificationCenter.default.post(name: Self.didSave, object: self, userInfo: savedIDs)
            return
        }
        guard let store = container?.store else { throw unsupportedStore("Saving") }
        try persistPendingChanges(to: store)
        let savedIDs = saveNotificationIdentifiers(before: before, insertedModels: originalInsertedIDs)
        NotificationCenter.default.post(name: Self.didSave, object: self, userInfo: savedIDs)
    }

    private func saveNotificationIdentifiers(
        before: ContextState.PendingState,
        insertedModels: [(any PersistentModel, PersistentIdentifier)]
    ) -> [AnyHashable: Any] {
        let inserted = insertedModels.map { model, originalIdentifier in
            model.persistentModelID.primaryKey == nil
                ? temporaryIdentifiers[originalIdentifier] ?? originalIdentifier
                : model.persistentModelID
        }
        return saveNotificationInfo(
            inserted: inserted,
            updated: before.changed.map(\.persistentModelID),
            deleted: before.deleted.map(\.persistentModelID))
    }

    private func saveNotificationInfo(
        inserted: [PersistentIdentifier],
        updated: [PersistentIdentifier],
        deleted: [PersistentIdentifier]
    ) -> [AnyHashable: Any] {
        [
            Self.NotificationKey.insertedIdentifiers.rawValue: inserted,
            Self.NotificationKey.updatedIdentifiers.rawValue: updated,
            Self.NotificationKey.deletedIdentifiers.rawValue: deleted,
        ]
    }

    /// Discards pending changes and restores values to their prior saved state.
    public func rollback() {
        assertAffinity()
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
            autosaveTrigger.cancel()
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
        assertAffinity()
        return try state.withExclusiveOperation {
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
                    try saveChanges()
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
        assertAffinity()
        guard model.modelContext === self else { return }
        state.willMutate(model, snapshot: model.snapshotLifecycle())
    }

    /// Records a property write as a pending change.
    package func recordMutation<Model: PersistentModel>(_ model: Model) {
        assertAffinity()
        guard model.modelContext === self else { return }
        state.recordMutation(model)
    }

    private var storeIdentifier: String { container?.configurations.first?.name ?? "default" }

    private func canonicalAttributes(for entity: Schema.Entity) -> [Schema.Attribute] {
        entity.attributes.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }

    private func storedColumns(for attribute: Schema.Attribute) -> [String] {
        if attribute.options.contains(.flattened) {
            return attribute.components.map(\.columnName)
        }
        return [attribute.name]
    }

    private func storedColumnNames(for attributes: [Schema.Attribute]) -> [String] {
        attributes.flatMap(storedColumns(for:))
    }

    private func isBlobFlattenedColumn(_ property: String, in entity: Schema.Entity) -> Bool {
        guard let component = entity.attributes.lazy.flatMap(\.components).first(where: { $0.columnName == property })
        else { return false }
        return component.type == "Data" || component.type == "UUID"
    }

    private func flattenedAdapters<Model: PersistentModel>(
        for property: String, type: Model.Type
    ) -> [any AnyFlattenedPropertyAdapter] {
        type.flattenedPropertyAdapters().filter { $0.propertyName == property }
            .sorted { $0.componentName.utf8.lexicographicallyPrecedes($1.componentName.utf8) }
    }

    private func selectedAttributes<Model: PersistentModel>(
        _ keyPaths: [PartialKeyPath<Model>]?,
        entity: Schema.Entity,
        type: Model.Type
    ) throws -> [String] {
        guard let keyPaths else { return canonicalAttributes(for: entity).map(\.name) }
        let names = try keyPaths.map { keyPath -> String in
            if let metadata = type.schemaMetadata().first(where: { $0.keypath == keyPath }),
                !metadata.isRelationship,
                entity.attributes.contains(where: { $0.name == metadata.name })
            {
                return metadata.name
            }
            if let component = type.flattenedPropertyAdapters().first(where: {
                $0.componentKeyPath == keyPath || $0.localComponentKeyPath == keyPath
            }),
                entity.attributes.first(where: { $0.name == component.propertyName })?.options.contains(.flattened)
                    == true
            {
                return component.propertyName
            }
            throw SwiftDataError.unsupportedSchemaProperty("propertiesToFetch contains a non-attribute key path")
        }
        let available = Set(names)
        return canonicalAttributes(for: entity).map(\.name).filter { available.contains($0) }
    }

    private func selectedRelationships<Model: PersistentModel>(
        _ keyPaths: [PartialKeyPath<Model>],
        entity: Schema.Entity,
        type: Model.Type
    ) throws -> [String] {
        try keyPaths.map { keyPath in
            guard let property = type.schemaMetadata().first(where: { $0.keypath == keyPath }),
                property.isRelationship,
                entity.relationships.contains(where: { $0.name == property.name })
            else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "relationshipKeyPathsForPrefetching contains a non-relationship key path")
            }
            return property.name
        }
    }

    private func runtimePredicateTree<Model: PersistentModel>(
        _ value: Any,
        modelType: Model.Type,
        entity: Schema.Entity
    ) throws -> PredicateRuntimeTreeBuilder.Result {
        try PredicateRuntimeTreeBuilder.build(value, modelType: modelType, entity: entity)
    }

    private func compilePredicate<Model: PersistentModel>(
        _ predicate: Predicate<Model>?,
        modelType: Model.Type,
        entity: Schema.Entity,
        store: any RuntimeStore,
        ordering: [String]
    ) throws -> RuntimeCompiledPredicate? {
        guard let predicate else { return nil }
        guard let compiler = store as? any RuntimeQueryStore else {
            throw SwiftDataError.unsupportedPredicate("The configured store does not compile predicates.")
        }
        let tree = try runtimePredicateTree(predicate.expression, modelType: modelType, entity: entity)
        let flattenedAttributes = entity.attributes.flatMap { attribute in
            attribute.components.map { ($0.columnName, $0.type) }
        }
        let attributeTypes = Dictionary(
            uniqueKeysWithValues: entity.attributes.map { ($0.name, $0.type) } + flattenedAttributes)
        return try compiler.compile(
            RuntimePredicateRequest(
                entityName: entity.name,
                root: tree.root,
                ordering: ordering,
                typedCaptures: tree.captures,
                captureEncoding: .typed,
                attributeNames: Set(entity.attributes.map(\.name)).union(flattenedAttributes.map(\.0)),
                attributeTypes: attributeTypes))
    }

    private func sortSQL<Model: PersistentModel>(
        _ descriptors: [SortDescriptor<Model>],
        entity: Schema.Entity,
        type: Model.Type
    ) throws -> String {
        let columns = try descriptors.map { descriptor -> String in
            guard
                let property = resolvedPropertyName(
                    keyPath: descriptor.keyPath, fallback: descriptor.propertyName, entity: entity, type: type),
                !isBlobFlattenedColumn(property, in: entity),
                property.utf8.allSatisfy({
                    ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95
                })
            else {
                throw SwiftDataError.unsupportedPredicate("Sort key must be a direct persisted attribute")
            }
            return
                "t0.Z\(property.uppercased()) COLLATE swiftLocalizedStandardCompare \(descriptor.isAscending ? "ASC" : "DESC")"
        }
        return columns.isEmpty ? "t0.Z_PK ASC" : columns.joined(separator: ", ")
    }

    private func mergePending<Model: PersistentModel>(
        _ fetched: [Model],
        descriptor: FetchDescriptor<Model>,
        entity: Schema.Entity,
        evaluatorPlan: PredicatePlan?
    ) throws -> [Model] {
        guard descriptor.includePendingChanges else { return fetched }
        var merged = fetched.filter { model in !state.containsDeleted(model) }
        var present = Set(merged.map(ObjectIdentifier.init))
        let pending = (state.insertedModels + state.changedModels).compactMap { $0 as? Model }
        for model in pending where !model.isDeleted && !state.containsDeleted(model) {
            let identifier = ObjectIdentifier(model)
            let matches: Bool
            if let evaluatorPlan {
                matches = try pendingModel(model, matches: evaluatorPlan)
            } else {
                matches = true
            }
            if matches, !present.contains(identifier) {
                merged.append(model)
                present.insert(identifier)
            } else if !matches, present.contains(identifier) {
                merged.removeAll { $0 === model }
                present.remove(identifier)
            }
        }
        if !descriptor.sortBy.isEmpty {
            let sortNames = try sortProperties(descriptor.sortBy, entity: entity, type: Model.self)
            let sortValues = try Dictionary(
                uniqueKeysWithValues: merged.map { model in
                    let encoded = try runtimeValues(for: model, selecting: Set(sortNames))
                    return (ObjectIdentifier(model), sortNames.map { encoded[$0] ?? .null })
                })
            merged = merged.enumerated().sorted { lhs, rhs in
                for (index, descriptor) in descriptor.sortBy.enumerated() {
                    let result = compareSortValues(
                        sortValues[ObjectIdentifier(lhs.element)]?[index] ?? .null,
                        sortValues[ObjectIdentifier(rhs.element)]?[index] ?? .null)
                    if result != .orderedSame {
                        return descriptor.isAscending ? result == .orderedAscending : result == .orderedDescending
                    }
                }
                let lhsPK = lhs.element.persistentModelID.primaryKey ?? Int64.max
                let rhsPK = rhs.element.persistentModelID.primaryKey ?? Int64.max
                if lhsPK != rhsPK { return lhsPK < rhsPK }
                return lhs.offset < rhs.offset
            }.map(\.element)
        } else {
            merged = merged.enumerated().sorted { lhs, rhs in
                let lhsPK = lhs.element.persistentModelID.primaryKey ?? Int64.max
                let rhsPK = rhs.element.persistentModelID.primaryKey ?? Int64.max
                if lhsPK != rhsPK { return lhsPK < rhsPK }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
        let offset = descriptor.includePendingChanges ? max(0, descriptor.fetchOffset ?? 0) : 0
        guard offset < merged.count else { return [] }
        merged = Array(merged.dropFirst(offset))
        if descriptor.includePendingChanges, let limit = descriptor.fetchLimit {
            merged = Array(merged.prefix(max(0, limit)))
        }
        return merged
    }

    private func pendingModel<Model: PersistentModel>(
        _ model: Model,
        matches plan: PredicatePlan
    ) throws -> Bool {
        let propertyNames = RuntimePredicateEvaluator.referencedProperties(in: plan)
        let values = try runtimeValues(for: model, selecting: propertyNames)
        return try RuntimePredicateEvaluator.matches(plan, values: values)
    }

    private func runtimeValues<Model: PersistentModel>(
        for model: Model,
        selecting names: Set<String>? = nil
    ) throws -> [String: RuntimeValue] {
        var values: [String: RuntimeValue] = [:]
        for adapter in Model.persistenceAdapters() where names == nil || names!.contains(adapter.name) {
            values[adapter.name] = runtimeValue(try adapter.encoded(model))
        }
        for adapter in Model.flattenedPropertyAdapters() where names == nil || names!.contains(adapter.columnName) {
            values[adapter.columnName] = runtimeValue(try adapter.encoded(model))
        }
        return values
    }

    private func modelValues<Model: PersistentModel>(_ model: Model) throws -> [String: StoredValue] {
        var values = try Model.persistenceAdapters().reduce(into: [String: StoredValue]()) { values, adapter in
            values[adapter.name] = try adapter.encoded(model)
        }
        for adapter in Model.flattenedPropertyAdapters() {
            values[adapter.columnName] = try adapter.encoded(model)
        }
        return values
    }

    private func sortProperties<Model: PersistentModel>(
        _ descriptors: [SortDescriptor<Model>],
        entity: Schema.Entity,
        type: Model.Type
    ) throws -> [String] {
        try descriptors.map { descriptor in
            guard
                let property = resolvedPropertyName(
                    keyPath: descriptor.keyPath, fallback: descriptor.propertyName, entity: entity, type: type),
                !isBlobFlattenedColumn(property, in: entity)
            else {
                throw SwiftDataError.unsupportedPredicate("Sort key must be a direct persisted attribute")
            }
            return property
        }
    }

    private func resolvedPropertyName<Model: PersistentModel>(
        keyPath: PartialKeyPath<Model>, fallback: String?, entity: Schema.Entity, type: Model.Type
    ) -> String? {
        if let property = type.schemaMetadata().first(where: { $0.keypath == keyPath })?.name,
            entity.attributes.contains(where: { $0.name == property }),
            entity.attributes.first(where: { $0.name == property })?.options.contains(.flattened) != true
        {
            return property
        }
        if let adapter = type.flattenedPropertyAdapters().first(where: { $0.componentKeyPath == keyPath }),
            entity.attributes.first(where: { $0.name == adapter.propertyName })?.options.contains(.flattened) == true
        {
            return adapter.columnName
        }
        guard let fallback, entity.attributes.contains(where: { $0.name == fallback }) else { return nil }
        return fallback
    }

    package func compareSortValues(_ lhs: RuntimeValue, _ rhs: RuntimeValue) -> ComparisonResult {
        assertAffinity()
        if case let .double(value) = lhs, value.isNaN {
            return compareSortValues(.null, rhs)
        }
        if case let .double(value) = rhs, value.isNaN {
            return compareSortValues(lhs, .null)
        }
        if lhs == .null { return rhs == .null ? .orderedSame : .orderedAscending }
        if rhs == .null { return .orderedDescending }
        if storageClassRank(lhs) != storageClassRank(rhs) {
            return storageClassRank(lhs) < storageClassRank(rhs) ? .orderedAscending : .orderedDescending
        }
        switch (lhs, rhs) {
        case let (.int(lhs), .int(rhs)):
            return ordering(lhs, rhs)
        case let (.int(lhs), .double(rhs)):
            return compareIntegerAndDouble(lhs, rhs)
        case let (.double(lhs), .int(rhs)):
            switch compareIntegerAndDouble(rhs, lhs) {
            case .orderedAscending: return .orderedDescending
            case .orderedSame: return .orderedSame
            case .orderedDescending: return .orderedAscending
            @unknown default: return .orderedSame
            }
        case let (.double(lhs), .double(rhs)):
            return ordering(lhs, rhs)
        case let (.text(lhs), .text(rhs)):
            return lhs.localizedStandardCompare(rhs)
        case let (.blob(lhs), .blob(rhs)):
            if lhs == rhs { return .orderedSame }
            return lhs.lexicographicallyPrecedes(rhs) ? .orderedAscending : .orderedDescending
        default:
            return .orderedSame
        }
    }

    private func compareIntegerAndDouble(_ integer: Int64, _ real: Double) -> ComparisonResult {
        if real < -0x1p63 { return .orderedDescending }
        if real >= 0x1p63 { return .orderedAscending }
        let truncated = Int64(real)
        if integer < truncated { return .orderedAscending }
        if integer > truncated { return .orderedDescending }
        let exactInteger = Double(integer)
        if exactInteger < real { return .orderedAscending }
        if exactInteger > real { return .orderedDescending }
        return .orderedSame
    }

    private func ordering<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
        lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private func storageClassRank(_ value: RuntimeValue) -> Int {
        switch value {
        case .null: 0
        case .int, .double: 1
        case .text: 2
        case .blob: 3
        }
    }

    private func materialize<Model: PersistentModel>(
        _ type: Model.Type, entity: Schema.Entity, attributes: [Schema.Attribute], row: [RuntimeValue],
        storeIdentifier: String, primaryKey: Int64, version: Int
    ) throws -> Model {
        let managedValues =
            containerStorage?.relationshipAdapterTable[ObjectIdentifier(Model.self)] == nil
            ? defaultRelationshipValues(for: Model.self)
            : [:]
        let backing = ManagedBackingData<Model>(
            metadata: Model.schemaMetadata(), values: managedValues, context: self,
            storeIdentifier: storeIdentifier, entityID: entityID(for: entity.name), primaryKey: primaryKey,
            version: version,
            identifier: PersistentIdentifier(
                storeIdentifier: storeIdentifier, entityName: entity.name, primaryKey: primaryKey))
        let model = Model(backingData: backing)
        let adapters = Model.persistenceAdapters()
        var columnIndex = 2
        for attribute in attributes {
            if attribute.options.contains(.flattened) {
                let adapters = flattenedAdapters(for: attribute.name, type: Model.self)
                guard !adapters.isEmpty else { continue }
                var composite = try adapters[0].makeEmptyComposite()
                for adapter in adapters {
                    guard columnIndex < row.count else { break }
                    composite = try adapter.decoded(storedValue(row[columnIndex]), into: composite)
                    columnIndex += 1
                }
                try adapters[0].assign(composite, to: model)
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
        backing.attach(to: self, model: model)
        if let resolver = try relationshipResolver() {
            resolver.install(on: model, entity: entity)
        }
        return model
    }

    private func installPropertyFaults<Model: PersistentModel>(
        on backing: ManagedBackingData<Model>,
        type: Model.Type,
        entity: Schema.Entity,
        loadedAttributes: [String],
        primaryKey: Int64,
        store: any RuntimeStore
    ) {
        let loaded = Set(loadedAttributes)
        let omitted = canonicalAttributes(for: entity).map(\.name).filter { !loaded.contains($0) }
        guard !omitted.isEmpty else { return }
        let table = "Z\(entity.name.uppercased())"
        let propertyNames = Set(omitted)
        backing.installFaultLoader(
            faultedProperties: Set(
                type.schemaMetadata().compactMap { metadata in
                    guard propertyNames.contains(metadata.name), let keyPath = metadata.keypath else { return nil }
                    return keyPath
                })
        ) { requestedKeyPaths in
            let metadata = type.schemaMetadata().filter { propertyNames.contains($0.name) }
            let requested = metadata.filter { item in
                guard let keyPath = item.keypath else { return false }
                return requestedKeyPaths.contains(keyPath)
            }
            guard !requested.isEmpty else { return [:] }
            let flattenedAdapters = Dictionary(grouping: type.flattenedPropertyAdapters(), by: \.propertyName)
                .mapValues { $0.sorted { $0.componentName.utf8.lexicographicallyPrecedes($1.componentName.utf8) } }
            let selections: [(Schema.PropertyMetadata, String, AnyFlattenedPropertyAdapter?)] = try requested.flatMap {
                property -> [(Schema.PropertyMetadata, String, AnyFlattenedPropertyAdapter?)] in
                guard let attribute = entity.attributes.first(where: { $0.name == property.name })
                else { return [] }
                if attribute.options.contains(.flattened) {
                    let components = flattenedAdapters[property.name] ?? []
                    guard components.count == attribute.components.count else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Flattened adapter count does not match schema for '\(entity.name).\(property.name)'.")
                    }
                    return components.map { (property, $0.columnName, Optional($0)) }
                }
                guard type.persistenceAdapters().contains(where: { $0.name == property.name }) else { return [] }
                return [(property, property.name, nil)]
            }
            let columns = selections.map { "Z\($0.1.uppercased())" }.joined(separator: ", ")
            guard
                let row = try store.read({ connection in
                    try connection.rows(
                        "SELECT \(columns) FROM \(table) WHERE Z_PK = ?", arguments: [.int(primaryKey)])
                }).first
            else {
                throw SwiftDataError.unsupportedStore("A faulted model row no longer exists")
            }
            var result: [AnyKeyPath: Any] = [:]
            let scalarAdapters = type.persistenceAdapters()
            var decodedFlattened: [String: [String: StoredValue]] = [:]
            for (index, selection) in selections.enumerated() {
                guard index < row.count, let keyPath = selection.0.keypath else { continue }
                let stored: StoredValue
                switch row[index] {
                case .null: stored = .null
                case let .int(value): stored = .int(value)
                case let .double(value): stored = .double(value)
                case let .text(value): stored = .text(value)
                case let .blob(value): stored = .blob(value)
                }
                if let flattened = selection.2 {
                    decodedFlattened[flattened.propertyName, default: [:]][flattened.componentName] = stored
                } else if let adapter = scalarAdapters.first(where: { $0.name == selection.0.name }) {
                    result[keyPath] = try adapter.decoded(stored)
                }
            }
            for property in requested {
                guard let keyPath = property.keypath,
                    entity.attributes.first(where: { $0.name == property.name })?.options.contains(.flattened) == true,
                    let firstAdapter = flattenedAdapters[property.name]?.first
                else { continue }
                let flattened = flattenedAdapters[property.name] ?? []
                guard !flattened.isEmpty else { continue }
                var value = try firstAdapter.makeEmptyComposite()
                for component in flattened {
                    guard let stored = decodedFlattened[property.name]?[component.componentName] else { continue }
                    value = try component.decoded(stored, into: value)
                }
                result[keyPath] = value
            }
            return result
        }
    }

    private func defaultRelationshipValues<Model: PersistentModel>(for type: Model.Type) -> [AnyKeyPath: Any] {
        var values: [AnyKeyPath: Any] = [:]
        for adapter in containerStorage?.relationshipAdapterTable[ObjectIdentifier(type)] ?? [] {
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
        let flattenedAdapters = Dictionary(grouping: Model.flattenedPropertyAdapters(), by: \.propertyName)
            .mapValues { $0.sorted { $0.componentName.utf8.lexicographicallyPrecedes($1.componentName.utf8) } }
        let metadata = Model.schemaMetadata()
        var columnIndex = 2
        for attribute in attributes {
            guard let keyPath = metadata.first(where: { $0.name == attribute.name })?.keypath else {
                columnIndex += storedColumns(for: attribute).count
                continue
            }
            if attribute.options.contains(.flattened) {
                let components = flattenedAdapters[attribute.name] ?? []
                guard let first = components.first else { continue }
                var composite = try first.makeEmptyComposite()
                for component in components {
                    guard columnIndex < row.count else { break }
                    composite = try component.decoded(storedValue(row[columnIndex]), into: composite)
                    columnIndex += 1
                }
                backing.setMaterializedValue(forKey: keyPath, to: composite)
            } else if columnIndex < row.count,
                let adapter = adapters.first(where: { $0.name == attribute.name })
            {
                backing.setMaterializedValue(forKey: keyPath, to: try adapter.decoded(storedValue(row[columnIndex])))
                columnIndex += 1
            } else {
                columnIndex += 1
            }
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
        for model: any PersistentModel, container: ModelContainer, connection: any RuntimeConnection
    ) throws {
        guard let primaryKey = model.persistentModelID.primaryKey else { return }
        for entity in container.schema.entities {
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
                    let destination = container.schema.entity(forName: relationship.destination),
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
        for ownerEntity in container.schema.entities {
            for relationship in canonicalRelationships(for: ownerEntity) where !relationship.isToMany {
                guard relationship.destination == model.persistentModelID.entityName,
                    let inverseName = relationship.inverse,
                    let deletedEntity = container.schema.entity(forName: relationship.destination),
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
        requested: Set<String>?,
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
        let primaryKeyBatches = stride(from: 0, to: primaryKeys.count, by: 100).map { start in
            Array(primaryKeys[start..<min(start + 100, primaryKeys.count)])
        }
        for relationship in canonicalRelationships(for: entity) {
            guard requested == nil || requested?.contains(relationship.name) == true else { continue }
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
                    let rootColumn = requestedSideIsStorageOwner ? "Z_A" : "Z_B"
                    let endpointColumn = requestedSideIsStorageOwner ? "Z_B" : "Z_A"
                    var result: [[RuntimeValue]] = []
                    for batch in primaryKeyBatches {
                        let placeholders = batch.map { _ in "?" }.joined(separator: ", ")
                        result += try connection.rows(
                            "SELECT \(rootColumn), \(endpointColumn) FROM \(table) "
                                + "WHERE \(rootColumn) IN (\(placeholders)) "
                                + "ORDER BY \(rootColumn) ASC, \(endpointColumn) ASC",
                            arguments: batch.map(RuntimeValue.int))
                    }
                    return result
                }
            } else if relationship.isToMany, relationship.inverse == nil {
                guard let table = joinTableName(for: entity, relationship) else { continue }
                destinationType = adapter.destinationType
                rootColumnFirst = true
                rows = try store.read { connection in
                    var result: [[RuntimeValue]] = []
                    for batch in primaryKeyBatches {
                        let placeholders = batch.map { _ in "?" }.joined(separator: ", ")
                        result += try connection.rows(
                            "SELECT Z_A, Z_B FROM \(table) WHERE Z_A IN (\(placeholders)) "
                                + "ORDER BY Z_A ASC, Z_B ASC",
                            arguments: batch.map(RuntimeValue.int))
                    }
                    return result
                }
            } else if relationship.isToMany,
                let inverseName = relationship.inverse,
                let destinationEntity = container?.schema.entity(forName: relationship.destination),
                destinationEntity.relationships.first(where: { $0.name == inverseName })?.isToMany == false
            {
                destinationType = adapter.destinationType
                rootColumnFirst = true
                rows = try store.read { connection in
                    var result: [[RuntimeValue]] = []
                    for batch in primaryKeyBatches {
                        let placeholders = batch.map { _ in "?" }.joined(separator: ", ")
                        result += try connection.rows(
                            "SELECT Z\(inverseName.uppercased()), Z_PK FROM Z\(destinationEntity.name.uppercased()) "
                                + "WHERE Z\(inverseName.uppercased()) IN (\(placeholders)) ORDER BY Z_PK ASC",
                            arguments: batch.map(RuntimeValue.int))
                    }
                    return result
                }
            } else if isToOneStorageOwner(entity, relationship) {
                destinationType = adapter.destinationType
                rootColumnFirst = true
                rows = try store.read { connection in
                    var result: [[RuntimeValue]] = []
                    for batch in primaryKeyBatches {
                        let placeholders = batch.map { _ in "?" }.joined(separator: ", ")
                        result += try connection.rows(
                            "SELECT Z_PK, Z\(relationship.name.uppercased()) FROM Z\(entity.name.uppercased()) "
                                + "WHERE Z_PK IN (\(placeholders)) ORDER BY Z_PK ASC",
                            arguments: batch.map(RuntimeValue.int))
                    }
                    return result
                }
            } else {
                guard let inverseName = relationship.inverse,
                    let destinationEntity = container?.schema.entity(forName: relationship.destination)
                else { continue }
                destinationType = adapter.destinationType
                rootColumnFirst = true
                rows = try store.read { connection in
                    var result: [[RuntimeValue]] = []
                    for batch in primaryKeyBatches {
                        let placeholders = batch.map { _ in "?" }.joined(separator: ", ")
                        result += try connection.rows(
                            "SELECT Z\(inverseName.uppercased()), Z_PK FROM Z\(destinationEntity.name.uppercased()) "
                                + "WHERE Z\(inverseName.uppercased()) IN (\(placeholders)) ORDER BY Z_PK ASC",
                            arguments: batch.map(RuntimeValue.int))
                    }
                    return result
                }
            }

            let destinationEntity = container?.schema.entity(forName: relationship.destination)
            var destinationModels: [Int64: any PersistentModel] = [:]
            if let destinationEntity {
                let destinationKeys = Set(
                    rows.compactMap { row -> Int64? in
                        guard row.count == 2,
                            case let .int(firstPK) = row[0], case let .int(secondPK) = row[1]
                        else { return nil }
                        let ownerPK = rootColumnFirst ? firstPK : secondPK
                        let destinationPK = rootColumnFirst ? secondPK : firstPK
                        return byPK[ownerPK] == nil ? nil : destinationPK
                    })
                let uncachedKeys = destinationKeys.filter { key in
                    identityMap.model(
                        for: EntityPrimaryKey(entityName: destinationEntity.name, primaryKey: key),
                        as: destinationType)
                        == nil
                }
                let destinationAttributes = canonicalAttributes(for: destinationEntity)
                let selectedColumns =
                    (["Z_PK", "Z_OPT"]
                    + storedColumnNames(for: destinationAttributes).map {
                        "Z\($0.uppercased())"
                    }).joined(separator: ", ")
                let uncachedBatches = stride(from: 0, to: uncachedKeys.count, by: 100).map { start in
                    Array(uncachedKeys.sorted()[start..<min(start + 100, uncachedKeys.count)])
                }
                var destinationRows: [[RuntimeValue]] = []
                for batch in uncachedBatches {
                    let placeholders = batch.map { _ in "?" }.joined(separator: ", ")
                    destinationRows += try store.read { connection in
                        try connection.rows(
                            "SELECT \(selectedColumns) FROM Z\(destinationEntity.name.uppercased()) "
                                + "WHERE Z_PK IN (\(placeholders)) ORDER BY Z_PK ASC",
                            arguments: batch.map(RuntimeValue.int))
                    }
                }
                for row in destinationRows {
                    guard row.count >= 2, case let .int(primaryKey) = row[0] else { continue }
                    let candidate = try materialize(
                        destinationType, entity: destinationEntity, attributes: destinationAttributes, row: row,
                        storeIdentifier: storeIdentifier, primaryKey: primaryKey,
                        version: runtimeInt(row[1]))
                    let key = EntityPrimaryKey(entityName: destinationEntity.name, primaryKey: primaryKey)
                    destinationModels[primaryKey] =
                        identityMap.canonicalHandle(for: key, candidate: candidate)
                        .model
                }
            }

            for row in rows {
                guard row.count == 2, case let .int(firstPK) = row[0], case let .int(secondPK) = row[1] else {
                    continue
                }
                let ownerPK = rootColumnFirst ? firstPK : secondPK
                let destinationPK = rootColumnFirst ? secondPK : firstPK
                guard byPK[ownerPK] != nil else { continue }
                let destination =
                    destinationModels[destinationPK]
                    ?? identityMap.model(
                        for: EntityPrimaryKey(
                            entityName: relationship.destination, primaryKey: destinationPK),
                        as: destinationType)
                guard let destination
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
                let columns = storedColumnNames(for: attributes).map { "Z\($0.uppercased())" }
                let selected = (["Z_PK", "Z_OPT"] + columns).joined(separator: ", ")
                guard
                    let row = try store.read({ connection in
                        try connection.rows(
                            "SELECT \(selected) FROM Z\(entity.name.uppercased()) WHERE Z_PK = ?",
                            arguments: [.int(primaryKey)])
                    }).first
                else { return nil }
                let candidate = try materialize(
                    Model.self, entity: entity, attributes: attributes, row: row, storeIdentifier: storeIdentifier,
                    primaryKey: primaryKey, version: row.count > 1 ? runtimeInt(row[1]) : 0)
                let model = identityMap.canonicalHandle(for: key, candidate: candidate).model as? Model ?? candidate
                return model
            }
            defer { visited.remove(key) }
            if let existing = identityMap.model(for: key, as: Model.self) {
                if !existing.hasChanges, materializeRelations {
                    try refreshStoredAttributes(existing, entity: entity, key: primaryKey, store: store)
                    try materializeRelationships(
                        [existing], entity: entity, primaryKeys: [primaryKey], store: store,
                        requested: nil,
                        visited: &visited)
                }
                return existing
            }
            let attributes = canonicalAttributes(for: entity)
            let columns = storedColumnNames(for: attributes).map { "Z\($0.uppercased())" }
            let selected = (["Z_PK", "Z_OPT"] + columns).joined(separator: ", ")
            let row = try store.read { connection in
                try connection.rows(
                    "SELECT \(selected) FROM Z\(entity.name.uppercased()) WHERE Z_PK = ?", arguments: [.int(primaryKey)]
                )
            }.first
            guard let row else { return nil }
            let candidate = try materialize(
                Model.self, entity: entity, attributes: attributes, row: row, storeIdentifier: storeIdentifier,
                primaryKey: primaryKey, version: row.count > 1 ? runtimeInt(row[1]) : 0)
            let model = identityMap.canonicalHandle(for: key, candidate: candidate).model as? Model ?? candidate
            if materializeRelations {
                try materializeRelationships(
                    [model], entity: entity, primaryKeys: [primaryKey], store: store,
                    requested: nil,
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
        let columns = storedColumnNames(for: attributes).map { "Z\($0.uppercased())" }
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

    private static func historyKeyLess(_ lhs: StoreEntityKey, _ rhs: StoreEntityKey) -> Bool {
        if lhs.entityName != rhs.entityName { return lhs.entityName < rhs.entityName }
        return lhs.primaryKey < rhs.primaryKey
    }

    private func persistPendingChanges(to store: any RuntimeStore) throws {
        let pending = state.pendingState()
        guard let container = containerStorage else { throw unsupportedStore("Saving") }
        let entityIDs = Dictionary(
            uniqueKeysWithValues: container.schema.entities.enumerated().map { ($1.name, $0 + 1) })
        let models = pending.inserted + pending.changed
        let insertedIDs = Set(pending.inserted.map(ObjectIdentifier.init))
        var updatedKeys = Set(
            pending.changed.compactMap { model -> StoreEntityKey? in
                guard let primaryKey = model.persistentModelID.primaryKey else { return nil }
                return StoreEntityKey(entityName: model.persistentModelID.entityName, primaryKey: primaryKey)
            })
        var relationshipAffectedInsertions = Set<ObjectIdentifier>()
        for event in pending.relationshipMutationEvents {
            let affectedModels = [event.owner] + event.oldEndpoints + event.newEndpoints
            for model in affectedModels {
                let objectID = ObjectIdentifier(model)
                if insertedIDs.contains(objectID) {
                    relationshipAffectedInsertions.insert(objectID)
                    continue
                }
                guard let primaryKey = model.persistentModelID.primaryKey
                else { continue }
                updatedKeys.insert(
                    StoreEntityKey(entityName: model.persistentModelID.entityName, primaryKey: primaryKey))
            }
        }
        let deletedKeys = Set(
            pending.deleted.compactMap { model -> StoreEntityKey? in
                guard let primaryKey = model.persistentModelID.primaryKey else { return nil }
                return StoreEntityKey(entityName: model.persistentModelID.entityName, primaryKey: primaryKey)
            })
        updatedKeys.subtract(deletedKeys)
        let orderedModels = relationshipOrderedEntities(models)
        let externalDataColumns = Self.externalDataColumns(in: container.schema)
        let persisted: [PersistedModel] = try store.writeWithExternalData { connection, externalDataSession in
            var results: [PersistedModel] = []
            for model in orderedModels {
                let snapshot = model.snapshotLifecycle()
                try persistModel(
                    model, inserted: insertedIDs.contains(ObjectIdentifier(model)),
                    connection: connection, snapshot: snapshot, container: container,
                    entityIDs: entityIDs, append: &results,
                    externalDataColumns: externalDataColumns,
                    externalDataSession: externalDataSession)
            }
            let assignedIDs = Dictionary(
                uniqueKeysWithValues: results.map { (ObjectIdentifier($0.model), $0.primaryKey) })
            for owner in models {
                guard let entity = container.schema.entity(forName: String(describing: type(of: owner))),
                    let adapters = container.relationshipAdapterTable[ObjectIdentifier(type(of: owner))],
                    let ownerPK = assignedIDs[ObjectIdentifier(owner)]
                else { continue }
                for relationship in canonicalRelationships(for: entity)
                where !relationship.isToMany && isToOneStorageOwner(entity, relationship) {
                    guard let adapter = adapters.first(where: { $0.name == relationship.name }) else { continue }
                    guard let endpoint = adapter.read(owner)?.first,
                        endpoint.persistentModelID.primaryKey == nil,
                        let destinationPK = assignedIDs[ObjectIdentifier(endpoint)]
                    else { continue }
                    try connection.execute(
                        "UPDATE Z\(entity.name.uppercased()) SET Z\(relationship.name.uppercased()) = ? WHERE Z_PK = ?",
                        arguments: [.int(destinationPK), .int(ownerPK)])
                }
            }
            for event in pending.relationshipMutationEvents where !insertedIDs.contains(ObjectIdentifier(event.owner)) {
                guard !event.relationship.isToMany,
                    let entity = container.schema.entity(forName: String(describing: type(of: event.owner))),
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
                assignedIDs: assignedIDs, container: container, connection: connection)
            for model in pending.deleted {
                try cleanupRelationships(for: model, container: container, connection: connection)
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
            var historyChanges: [RuntimeHistoryChange] = []
            var historyTypesByKey: [StoreEntityKey: HistoryChangeType] = [:]
            for result in results where insertedIDs.contains(ObjectIdentifier(result.model)) {
                let key = StoreEntityKey(
                    entityName: result.model.persistentModelID.entityName, primaryKey: result.primaryKey)
                historyTypesByKey[key] = result.replacedModel == nil ? .insert : .update
            }
            for result in results where relationshipAffectedInsertions.contains(ObjectIdentifier(result.model)) {
                guard result.replacedModel != nil else { continue }
                let key = StoreEntityKey(
                    entityName: result.model.persistentModelID.entityName, primaryKey: result.primaryKey)
                historyTypesByKey[key] = .update
            }
            for key in updatedKeys where !deletedKeys.contains(key) {
                historyTypesByKey[key] = .update
            }
            for key in deletedKeys { historyTypesByKey[key] = .delete }
            for key in historyTypesByKey.keys.sorted(by: Self.historyKeyLess) {
                guard let type = historyTypesByKey[key] else { continue }
                historyChanges.append(
                    RuntimeHistoryChange(type: type, entityName: key.entityName, primaryKey: key.primaryKey))
            }
            if !historyChanges.isEmpty {
                try connection.recordHistory(historyChanges, timestamp: Date(), author: historyAuthorStorage)
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
        for result in persisted {
            let model = result.model
            let entityName = model.persistentModelID.entityName
            let originalIdentifier = state.snapshotIdentifier(for: model)
            if let replacedModel = result.replacedModel {
                identityMap.remove(EntityPrimaryKey(entityName: entityName, primaryKey: result.primaryKey))
                detachModel(replacedModel)
            }
            model.markPersistedLifecycle(
                storeIdentifier: storeIdentifier, entityID: entityID(for: entityName),
                primaryKey: result.primaryKey, version: result.version)
            state.setBaseline(model, snapshot: model.snapshotLifecycle())
            identityMap.register(
                model, for: EntityPrimaryKey(entityName: entityName, primaryKey: result.primaryKey))
            if let old = originalIdentifier, old.isTemporary {
                temporaryIdentifiers[old] = model.persistentModelID
            }
        }
        finalizePendingChanges()
        state.clearRelationshipMutationEvents()
        let insertedKeys = Set(
            persisted.filter { result in
                insertedIDs.contains(ObjectIdentifier(result.model))
            }.map { StoreEntityKey(entityName: $0.model.persistentModelID.entityName, primaryKey: $0.primaryKey) })
        if let storeHubStoreIdentifier {
            storeHub?.publish(
                storeIdentifier: storeHubStoreIdentifier,
                sourceSubscription: storeHubSubscription ?? UUID(),
                inserted: insertedKeys,
                updated: updatedKeys,
                deleted: deletedKeys)
        }
    }

    private func persistModel(
        _ model: any PersistentModel, inserted: Bool, connection: any RuntimeConnection,
        snapshot: BackingDataSnapshot, container: ModelContainer, entityIDs: [String: Int],
        append: inout [PersistedModel], externalDataColumns: Set<String>,
        externalDataSession: ExternalDataWriteSession
    ) throws {
        func typed<Model: PersistentModel>(_ model: Model) throws {
            guard let entity = container.schema.entity(forName: String(describing: Model.self)) else { return }
            let adapters = Model.persistenceAdapters()
            let flattenedAdapters = Dictionary(grouping: Model.flattenedPropertyAdapters(), by: \.propertyName)
                .mapValues { $0.sorted { $0.componentName.utf8.lexicographicallyPrecedes($1.componentName.utf8) } }
            var columns: [String] = []
            var values: [RuntimeValue] = []
            let savedValues = snapshot.savedValues
            let metadata = Model.schemaMetadata()
            for attribute in canonicalAttributes(for: entity) {
                let flattened = attribute.options.contains(.flattened)
                guard let keyPath = metadata.first(where: { $0.name == attribute.name })?.keypath else { continue }
                if !inserted {
                    guard let current = snapshot.values[keyPath],
                        let saved = savedValues?[keyPath], !Self.persistenceValuesEqual(current, saved)
                    else { continue }
                }
                if flattened {
                    let components = flattenedAdapters[attribute.name] ?? []
                    guard components.count == attribute.components.count else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Flattened adapter count does not match schema for '\(entity.name).\(attribute.name)'.")
                    }
                    for component in components {
                        columns.append("Z\(component.columnName.uppercased())")
                        values.append(runtimeValue(try component.encoded(model)))
                    }
                } else {
                    guard let adapter = adapters.first(where: { $0.name == attribute.name }) else { continue }
                    columns.append("Z\(attribute.name.uppercased())")
                    var value = try adapter.encoded(model)
                    if attribute.options.contains(.externalStorage), case let .blob(bytes) = value {
                        value = try externalDataSession.externalizedValue(bytes)
                    }
                    values.append(runtimeValue(value))
                }
            }
            for relationship in canonicalRelationships(for: entity)
            where !relationship.isToMany && isToOneStorageOwner(entity, relationship) {
                guard inserted || model.persistentModelID.primaryKey != nil else { continue }
                guard
                    let relationshipAdapter = container.relationshipAdapterTable[ObjectIdentifier(Model.self)]?
                        .first(where: { $0.name == relationship.name })
                else { continue }
                if !inserted {
                    guard let keyPath = metadata.first(where: { $0.name == relationship.name })?.keypath,
                        let current = snapshot.values[keyPath],
                        let saved = savedValues?[keyPath], !Self.persistenceValuesEqual(current, saved)
                    else { continue }
                }
                columns.append("Z\(relationship.name.uppercased())")
                values.append(
                    relationshipAdapter.read(model)?.first?.persistentModelID.primaryKey
                        .map(RuntimeValue.int) ?? .null)
            }
            let table = "Z\(entity.name.uppercased())"
            if inserted {
                if let match = try uniqueMatch(
                    entity: entity, columns: columns, values: values, connection: connection)
                {
                    let assignments = columns.map { "\($0) = ?" }.joined(separator: ", ")
                    let version = match.version + 1
                    if columns.isEmpty {
                        try connection.execute(
                            "UPDATE \(table) SET Z_OPT = ? WHERE Z_PK = ? AND Z_OPT = ?",
                            arguments: [.int(Int64(version)), .int(match.primaryKey), .int(Int64(match.version))])
                    } else {
                        try connection.execute(
                            "UPDATE \(table) SET \(assignments), Z_OPT = ? WHERE Z_PK = ? AND Z_OPT = ?",
                            arguments: values + [
                                .int(Int64(version)), .int(match.primaryKey), .int(Int64(match.version)),
                            ])
                    }
                    guard connection.changesCount() == 1 else { throw SwiftDataError.optimisticLockConflict }
                    let replaced = identityMap.model(
                        for: EntityPrimaryKey(entityName: entity.name, primaryKey: match.primaryKey),
                        as: type(of: model))
                    append.append(
                        PersistedModel(
                            model: model, primaryKey: match.primaryKey, version: version,
                            replacedModel: replaced === model ? nil : replaced))
                    return
                }
                let names = (["Z_ENT", "Z_OPT"] + columns).joined(separator: ", ")
                let placeholders = Array(repeating: "?", count: columns.count + 2).joined(separator: ", ")
                try connection.execute(
                    "INSERT INTO \(table) (\(names)) VALUES (\(placeholders))",
                    arguments: [.int(Int64(entityIDs[entity.name] ?? 1)), .int(1)] + values)
                append.append(
                    PersistedModel(
                        model: model, primaryKey: connection.lastInsertRowID(), version: 1,
                        replacedModel: nil))
            } else if let pk = model.persistentModelID.primaryKey {
                let expectedVersion = snapshot.optimisticLockVersion
                let version = expectedVersion + 1
                let assignments = columns.map { "\($0) = ?" }.joined(separator: ", ")
                if columns.isEmpty {
                    try connection.execute(
                        "UPDATE \(table) SET Z_OPT = ? WHERE Z_PK = ? AND Z_OPT = ?",
                        arguments: [.int(Int64(version)), .int(pk), .int(Int64(expectedVersion))])
                } else {
                    try connection.execute(
                        "UPDATE \(table) SET \(assignments), Z_OPT = ? WHERE Z_PK = ? AND Z_OPT = ?",
                        arguments: values + [.int(Int64(version)), .int(pk), .int(Int64(expectedVersion))])
                }
                guard connection.changesCount() == 1 else {
                    throw SwiftDataError.optimisticLockConflict
                }
                append.append(PersistedModel(model: model, primaryKey: pk, version: version, replacedModel: nil))
            }
        }
        func dispatch<Model: PersistentModel>(_ model: Model) throws { try typed(model) }
        try dispatch(model)
    }

    private static func externalDataColumns(in schema: Schema) -> Set<String> {
        Set(
            schema.entities.flatMap { entity in
                entity.attributes.compactMap { attribute in
                    guard attribute.options.contains(.externalStorage) else { return nil }
                    return "Z\(entity.name.uppercased()).Z\(attribute.name.uppercased())"
                }
            })
    }

    private func uniqueMatch(
        entity: Schema.Entity, columns: [String], values: [RuntimeValue], connection: any RuntimeConnection
    ) throws -> (primaryKey: Int64, version: Int)? {
        let attributes = canonicalAttributes(for: entity)
        let constraints =
            attributes.filter { $0.options.contains(.unique) }.map { [$0.name] }
            + entity.indexes.filter(\.isUnique).map(\.properties)
        var match: (primaryKey: Int64, version: Int)?
        for properties in constraints {
            guard !properties.isEmpty else { continue }
            var predicates: [String] = []
            var arguments: [RuntimeValue] = []
            for property in properties {
                let column = "Z\(property.uppercased())"
                guard let index = columns.firstIndex(of: column) else { continue }
                let value = values[index]
                guard value != .null else { continue }
                predicates.append("\(column) = ?")
                arguments.append(value)
            }
            guard predicates.count == properties.count else { continue }
            let sql =
                "SELECT Z_PK, Z_OPT FROM Z\(entity.name.uppercased()) WHERE \(predicates.joined(separator: " AND ")) ORDER BY Z_PK LIMIT 1"
            if let row = try connection.rows(sql, arguments: arguments).first, row.count >= 2 {
                guard case let .int(primaryKey) = row[0] else { continue }
                let current = (primaryKey, runtimeInt(row[1]))
                if let match, match.primaryKey != current.0 {
                    throw SwiftDataError.unsupportedStore(
                        "Unique constraints matched different rows for entity '\(entity.name)'.")
                }
                match = current
            }
        }
        return match
    }

    private static func persistenceValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if let lhs = lhs as? AnyHashable, let rhs = rhs as? AnyHashable {
            return lhs == rhs
        }
        return String(reflecting: type(of: lhs)) == String(reflecting: type(of: rhs))
            && String(describing: lhs) == String(describing: rhs)
    }

    private func persistRelationships(
        _ events: [ContextState.RelationshipMutationEvent], insertedModels: [any PersistentModel],
        insertionSnapshots _: [ObjectIdentifier: BackingDataSnapshot],
        assignedIDs: [ObjectIdentifier: Int64], container: ModelContainer, connection: any RuntimeConnection
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
            guard let entity = container.schema.entity(forName: String(describing: type(of: owner))),
                let adapters = container.relationshipAdapterTable[ObjectIdentifier(type(of: owner))]
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
            guard let entity = container.schema.entity(forName: String(describing: type(of: owner))),
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
                    let destination = container.schema.entity(forName: relationship.destination),
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

    package func assertAffinity(_ function: StaticString = #function) {
        #if DEBUG
            if let affinityToken {
                guard affinityToken.isCurrentExecutor else {
                    assertionFailure("ModelContext.\(function) called outside its creating executor")
                    return
                }
                return
            }
            switch affinity {
            case .mainActor:
                MainActor.preconditionIsolated("ModelContext.\(function) called outside MainActor")
            case .unchecked:
                break
            }
        #endif
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
        assertAffinity()
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
        autosaveTrigger.cancel()
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
