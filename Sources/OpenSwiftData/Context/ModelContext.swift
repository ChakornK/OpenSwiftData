import Foundation
import OSDCore
import Dispatch

package enum ModelContextAffinity: @unchecked Sendable {
    case mainActor
    case unchecked
}

package struct ModelContextQueryExecutor: @unchecked Sendable {
    private let affinity: ModelContextAffinity
    private let token: ModelExecutorAffinityToken?

    package init(affinity: ModelContextAffinity, token: ModelExecutorAffinityToken?) {
        self.affinity = affinity
        self.token = token
    }

    package func assertCurrent() {
        if let token {
            token.checkIsolated()
            return
        }
        switch affinity {
        case .mainActor:
            MainActor.preconditionIsolated("Query refresh called outside the context's MainActor")
        case .unchecked:
            break
        }
    }
}

#if canImport(ObjectiveC)
    /// The superclass of `ModelContext`; it adds no behavior.
    open class _ModelContextBase {
        /// Creates the base object.
        public init() {}
    }
#else
    /// The superclass of `ModelContext`. Swift Foundation's `NotificationCenter` on Linux only matches
    /// `object:` filters against `NSObject` senders, so contexts derive from it there.
    public typealias _ModelContextBase = NSObject
#endif

/// A synchronous unit of work for inserting, fetching, and saving persistent models.
public final class ModelContext: _ModelContextBase {
    /// The container that owns this context.
    ///
    /// Traps for a context created with `init()`, which has no container.
    public var container: ModelContainer {
        assertAffinity()
        guard let containerStorage else { preconditionFailure("This model context has no model container.") }
        return containerStorage
    }

    /// The owning container, or `nil` for a context created with `init()`.
    package var optionalContainer: ModelContainer? {
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
    private var dataStoreTemporaryIdentifiers: [ObjectIdentifier: PersistentIdentifier] = [:]
    private var dataStoreOriginalIdentifiers: [ObjectIdentifier: PersistentIdentifier] = [:]
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

    /// The author recorded with history transactions created by this context.
    public var author: String? {
        get { historyAuthor }
        set { historyAuthor = newValue }
    }

    /// This context's editing state, whose identifier is stable for the context's lifetime.
    ///
    /// Setting the state updates `author`; the identifier cannot change.
    public var editingState: EditingState {
        get { EditingState(id: editingStateID, author: author) }
        set { author = newValue.author }
    }
    private let editingStateID = UUID()
    /// The undo manager associated with this context.
    public var undoManager: UndoManager? {
        get {
            assertAffinity()
            return undoManagerStorage
        }
        set {
            assertAffinity()
            guard undoManagerStorage !== newValue else { return }
            undoManagerStorage = newValue
            undoRegisteredModels.removeAll()
            currentUndoGroup = nil
            undoManagerGeneration &+= 1
        }
    }
    private var undoManagerStorage: UndoManager?
    private var undoRegisteredModels = Set<ObjectIdentifier>()
    private var currentUndoGroup: UndoGroupOperation?
    private var isApplyingUndoGroup = false
    package private(set) var undoManagerGeneration: UInt64 = 0

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
    /// Permanent identifiers given to inserted models whose values a unique-constraint conflict merged into an
    /// existing row. These identifiers have no stored row, so later saves never write them.
    private var mergedDuplicateIdentifiers: Set<PersistentIdentifier> = []
    private var relationshipLoadVisited = Set<EntityPrimaryKey>()

    private func relationshipResolver() throws -> RelationshipFaultResolver? {
        assertAffinity()
        guard let container = optionalContainer, container.store != nil else { return nil }
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

    package func queryChangeSource() throws -> (
        storeIdentifier: ObjectIdentifier, changes: ChangeInbox, executor: ModelContextQueryExecutor
    ) {
        assertAffinity()
        guard let storeIdentifier = storeHubStoreIdentifier else {
            throw SwiftDataError.unsupportedStore("Query change streams require a SQLite-backed context.")
        }
        return (
            storeIdentifier, changeInbox,
            ModelContextQueryExecutor(affinity: affinity, token: affinityToken)
        )
    }

    deinit {
        changeInbox.finish()
        if let storeHubSubscription {
            storeHub?.unsubscribe(storeHubSubscription)
        }
    }

    private struct PersistedModel {
        let model: any PersistentModel
        let entityName: String
        let primaryKey: Int64
        let version: Int
        /// The registered instance of the row a unique-constraint conflict merged into, if any.
        let replacedModel: (any PersistentModel)?
        /// Whether a unique-constraint conflict merged this model's values into another row, leaving the model
        /// without a stored row of its own.
        var mergedIntoExistingRow = false
        /// The unused primary key that identifies an inserted model merged into an existing row.
        var mergedDuplicatePrimaryKey: Int64?
    }

    private struct IdentifierQueryRow {
        let identifier: PersistentIdentifier
        let sortValues: [RuntimeValue]
    }

    /// Creates a context for a model container with autosave enabled.
    public convenience init(_ container: ModelContainer) {
        self.init(container: container, autosaveEnabled: true)
    }

    /// Creates a context not associated with a model container.
    public override convenience init() {
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
            storeIdentifier: container?.storeIdentifier ?? "default",
            entityIDsByName: container?.schema.entityIDsByName ?? [:],
            entitiesByName: Dictionary(uniqueKeysWithValues: (container?.schema.entities ?? []).map { ($0.name, $0) }),
            onLocalChange: { [autosaveHandle] in autosaveHandle.changed() })
        autosaveEnabledStorage = autosaveEnabled
        allowsSave = container?.configurationList.first?.allowsSave ?? true
        testSaveHook = nil
        super.init()
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
            storeIdentifier: container?.storeIdentifier ?? "default",
            entityIDsByName: container?.schema.entityIDsByName ?? [:],
            entitiesByName: Dictionary(uniqueKeysWithValues: (container?.schema.entities ?? []).map { ($0.name, $0) }))
        autosaveEnabledStorage = false
        allowsSave = true
        testSaveHook = hook
        super.init()
        autosaveContextReference.set(self)
        subscribeToStoreChanges()
    }

    /// Models inserted into this context and not yet saved, including inserted models deleted before saving.
    public var insertedModelsArray: [any PersistentModel] {
        assertAffinity()
        return state.insertedModels + deletedInsertions
    }
    /// Models changed in this context and not yet saved.
    public var changedModelsArray: [any PersistentModel] {
        assertAffinity()
        return state.changedModels
    }
    /// Models deleted in this context and not yet saved, including inserted models deleted before saving.
    public var deletedModelsArray: [any PersistentModel] {
        assertAffinity()
        return state.deletedModels + deletedInsertions
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
        return state.hasChanges || !deletedInsertions.isEmpty
    }

    /// Inserted models deleted before saving.
    ///
    /// They stay attached and marked deleted until a save or rollback detaches them, and are never persisted.
    private var deletedInsertions: [any PersistentModel] = []

    /// Detaches inserted models that were deleted before saving.
    private func detachDeletedInsertions() {
        for model in deletedInsertions { model.detachLifecycle() }
        deletedInsertions.removeAll()
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
            model.prepareForPersistence()
            insertRelationshipDestination(model, snapshot: model.snapshotLifecycle())
        }
    }

    func insertRelationshipDestination(_ model: any PersistentModel, snapshot: BackingDataSnapshot) {
        assertAffinity()
        guard model.modelContext == nil else { return }
        model.prepareForPersistence()
        var insertionSnapshot = model.snapshotLifecycle()
        let relationshipAdapters = optionalContainer?.relationshipAdapterTable[ObjectIdentifier(type(of: model))] ?? []
        for adapter in relationshipAdapters {
            guard insertionSnapshot.values[adapter.keyPath] == nil,
                let value = try? adapter.makeValue([]),
                let metadata = type(of: model).schemaMetadata().first(where: { $0.name == adapter.name }),
                let keyPath = metadata.keypath
            else { continue }
            model.setInheritedValue(keyPath: keyPath, to: value)
            let values = insertionSnapshot.values.merging([keyPath: value]) { _, new in new }
            insertionSnapshot = BackingDataSnapshot(
                values: values, context: insertionSnapshot.context, identifier: insertionSnapshot.identifier,
                isDeleted: insertionSnapshot.isDeleted, hasChanges: insertionSnapshot.hasChanges,
                savedValues: insertionSnapshot.savedValues, primaryKey: insertionSnapshot.primaryKey,
                entityID: insertionSnapshot.entityID,
                optimisticLockVersion: insertionSnapshot.optimisticLockVersion)
        }
        let detachedDestinations = relationshipAdapters.flatMap { $0.read(model) ?? [] }
            .filter { $0.modelContext == nil && $0 !== model }
        func attach<Model: PersistentModel>(_ model: Model) {
            guard optionalContainer?.store != nil || optionalContainer?.dataStore != nil else {
                model.anyBackingData.attach(to: self, model: model)
                model.setInsertionChanged()
                state.setBaseline(model, snapshot: model.snapshotLifecycle())
                return
            }
            let managed = Model.createManagedBackingData(
                values: insertionSnapshot.values, context: self,
                storeIdentifier: storeIdentifier,
                entityID: containerStorage?.schema.entityIDsByName[String(describing: Model.self)] ?? 0,
                identifier: insertionSnapshot.identifier)
            model.persistentBackingData = managed
            model.anyBackingData.attach(to: self, model: model)
            model.setInsertionChanged()
            state.setBaseline(model, snapshot: model.snapshotLifecycle())
        }
        state.insert(model, snapshot: insertionSnapshot)
        attach(model)
        // Inserting a model also inserts the detached models it relates to, recursively.
        for destination in detachedDestinations where destination !== model {
            insertRelationshipDestination(destination, snapshot: destination.snapshotLifecycle())
        }
    }

    /// Deletes a model.
    ///
    /// Deleting a pending insertion marks it deleted and reports it as both inserted and deleted until the next
    /// save or rollback, which detaches it without persisting it.
    public func delete<Model: PersistentModel>(_ model: Model) {
        assertAffinity()
        state.withExclusiveOperation {
            guard model.modelContext === self else { return }
            guard !deletedInsertions.contains(where: { $0 === model }) else { return }
            if state.containsInserted(model) {
                _ = state.cancelInsertion(model)
                state.removeBaseline(for: model)
                markDeletedTyped(model)
                deletedInsertions.append(model)
                autosaveHandle.changed()
                return
            }
            guard !state.containsDeleted(model) else { return }
            do {
                try validateDeleteRules(for: model)
            } catch {
                OSDLog.debug("Delete rejected: \(error)")
                return
            }
            let snapshot = model.snapshotLifecycle()
            registerUndoIfNeeded(
                model, snapshot: snapshot, retainModel: true, restoresDeletedRow: snapshot.primaryKey != nil)
            state.willMutate(model, snapshot: snapshot)
            markDeletedTyped(model)
            state.markDeleted(model)
            // SwiftData marks cascade destinations deleted immediately, recursively.
            for (adapter, endpoints) in state.relationships(ownedBy: model)
            where adapter.metadata?.deleteRule == .cascade {
                for endpoint in endpoints where endpoint.modelContext === self && !endpoint.isDeleted {
                    func cascade<Endpoint: PersistentModel>(_ endpoint: Endpoint) { delete(endpoint) }
                    cascade(endpoint)
                }
            }
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
                case .cascade:
                    for endpoint in endpoints where scheduledIDs.insert(ObjectIdentifier(endpoint)).inserted {
                        cascadeScheduled.append(endpoint)
                        scheduled.append(endpoint)
                        relationshipSnapshots[ObjectIdentifier(endpoint)] = state.relationships(ownedBy: endpoint)
                    }
                case .nullify, .noAction, .deny:
                    // SwiftData does not enforce `deny`; related models are nullified like `nullify`.
                    break
                }
            }
        }
        try applyDeletePlan(
            roots: scheduledRoots, cascadeScheduled: cascadeScheduled,
            relationshipSnapshots: relationshipSnapshots)
    }

    private func validateDeleteRules(for model: any PersistentModel) throws {
        for (adapter, _) in state.relationships(ownedBy: model) where adapter.metadata == nil {
            throw SwiftDataError.unsupportedSchemaProperty(
                "Relationship adapter '\(adapter.name)' is unresolved during delete processing.")
        }
        let owners = identityMap.liveModels().map(\.1) + state.insertedModels + state.changedModels
        var visited = Set<ObjectIdentifier>()
        for owner in owners where owner !== model && visited.insert(ObjectIdentifier(owner)).inserted {
            for adapter in containerStorage?.relationshipAdapterTable[ObjectIdentifier(type(of: owner))] ?? []
            where adapter.metadata?.isOptional == false {
                guard let endpoints = adapter.read(owner) else { continue }
                if endpoints.contains(where: { $0 === model }) {
                    throw SwiftDataError.relationshipGraphConflict(
                        "Cannot delete a model that is required by relationship '\(adapter.name)'.")
                }
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
            let snapshot = before.snapshots[ObjectIdentifier(model)]?.1 ?? model.snapshotLifecycle()
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
        registerUndoGroup(
            from: snapshotsByID,
            retaining: Set(deletes.map(ObjectIdentifier.init)))
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
                guard metadata.deleteRule == .nullify || metadata.deleteRule == .deny,
                    let inverseName = metadata.inverse
                else { continue }
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
    public func processPendingChanges() {
        do {
            try processPendingChangesThrowing()
        } catch {
            OSDLog.debug("Processing pending changes failed: \(error)")
        }
    }

    /// Applies pending relationship and lifecycle bookkeeping, reporting failures.
    package func processPendingChangesThrowing() throws {
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
        guard let store = optionalContainer?.store else {
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
                guard let entity = optionalContainer?.schema.entity(forName: key.entityName) else { continue }
                try refreshRegisteredModel(type(of: model), entity: entity, primaryKey: key.primaryKey, store: store)
            }
        }
        for key in changedKeys {
            guard let entity = optionalContainer?.schema.entity(forName: key.entityName),
                let type = optionalContainer?.modelType(forEntityName: key.entityName)
            else { continue }
            invalidateRelationships(on: type, entity: entity, primaryKey: key.primaryKey)
            try refreshRegisteredModel(type, entity: entity, primaryKey: key.primaryKey, store: store)
        }
    }

    /// Checks for commits made outside this process when the backend supports data-version polling.
    /// The first call records a baseline. Polling is explicit and disabled unless the caller invokes this method.
    public func pollForExternalChanges() throws {
        assertAffinity()
        guard let store = optionalContainer?.store, let storeHubStoreIdentifier,
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
        try processPendingChangesThrowing()
    }

    private func invalidateRelationships(
        on type: any PersistentModel.Type,
        entity: Schema.Entity,
        primaryKey: Int64
    ) {
        func invalidate<Model: PersistentModel>(_ type: Model.Type) {
            let key = identityKey(for: entity, primaryKey: primaryKey)
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
            let key = identityKey(for: entity, primaryKey: primaryKey)
            guard let model = identityMap.model(for: key, as: Model.self), !model.hasChanges else { return }
            let attributes = canonicalAttributes(for: entity)
            let hasHierarchy = rootEntity(for: entity).name != entity.name
            let selectedColumns =
                (["Z_PK", "Z_OPT"] + (hasHierarchy ? ["Z_ENT"] : [])
                + storedColumnNames(for: attributes).map { "Z\($0.uppercased())" }).joined(separator: ", ")
            let table = rootEntity(for: entity)
            guard
                let row = try store.read({ connection in
                    try connection.rows(
                        "SELECT \(selectedColumns) FROM Z\(table.name.uppercased()) WHERE Z_PK = ?",
                        arguments: [.int(primaryKey)])
                }).first
            else {
                identityMap.remove(key)
                state.removeBaseline(for: model)
                model.persistentBackingData.markDeleted()
                model.detachDeletedLifecycle()
                return
            }
            if hasHierarchy {
                guard row.count >= 3, case let .int(rawEntityID) = row[2],
                    let entityID = Int(exactly: rawEntityID),
                    containerStorage?.schema.entityIDsByName[entity.name] == entityID
                else { return }
                try refreshAttributes(
                    model, entity: entity, attributes: attributes, row: [row[0], row[1]] + row.dropFirst(3))
            } else {
                try refreshAttributes(model, entity: entity, attributes: attributes, row: row)
            }
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

    /// Deletes saved models matching a predicate directly from the store.
    ///
    /// The deletion bypasses this context: pending changes stay pending, pending insertions are not deleted,
    /// registered instances are not marked deleted, and no save notifications are posted. Cascade rules apply.
    /// Throws a Core Data–domain error (code 134060) without deleting anything when the entity declares a
    /// relationship with the `deny` rule.
    public func delete<Model: PersistentModel>(
        model: Model.Type,
        where predicate: Predicate<Model>? = nil,
        includeSubclasses: Bool = true
    ) throws {
        assertAffinity()
        guard let container = containerStorage else { throw unsupportedStore("Batch delete") }
        if let entity = container.schema.entity(forName: String(describing: Model.self)),
            let denied = entity.relationships.first(where: { $0.deleteRule == .deny })
        {
            throw NSError(
                domain: NSCocoaErrorDomain, code: 134060,
                userInfo: [
                    "Reason": "Delete rule is not supported for batch deletes",
                    "Relationship": "\(entity.name).\(denied.name)",
                ])
        }
        let scratch = ModelContext(container: container, autosaveEnabled: false)
        scratch.postsSaveNotifications = false
        var descriptor = FetchDescriptor<Model>(predicate: predicate)
        descriptor.includePendingChanges = false
        for match in try scratch.fetch(descriptor)
        where includeSubclasses || ObjectIdentifier(type(of: match)) == ObjectIdentifier(model) {
            scratch.delete(match)
        }
        try scratch.save()
    }

    /// Whether saving posts `willSave` and `didSave`; batch deletes save through a silent scratch context.
    private var postsSaveNotifications = true

    /// Fetches models matching a descriptor, which requires a persistent store.
    public func fetch<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) throws -> [Model] {
        assertAffinity()
        try processPendingChangesThrowing()
        guard let container = containerStorage else { throw unsupportedStore("Fetch") }
        guard let entity = container.schema.entity(forName: String(describing: Model.self)) else { return [] }
        let hasHierarchy =
            entity.superentityName != nil
            || container.schema.entities.contains {
                $0.superentityName == entity.name
            }
        if let dataStore = container.dataStore {
            return try fetchFromDataStore(
                descriptor, dataStore: dataStore, container: container, entity: entity,
                hasHierarchy: hasHierarchy)
        }
        guard let store = container.store else { throw unsupportedStore("Fetch") }
        let allAttributes = canonicalAttributes(for: entity)
        let requestedProperties = try selectedAttributes(
            descriptor.selectedProperties, entity: entity, type: Model.self)
        let selectedAttributesForMaterialization =
            hasHierarchy
            ? try hierarchyAttributes(for: entity)
            : allAttributes.filter { requestedProperties.contains($0.name) }
        let selectedColumns = storedColumnNames(for: selectedAttributesForMaterialization)
        let requestedRelationships = try selectedRelationships(
            descriptor.relationshipKeyPathsForPrefetching, entity: entity, type: Model.self)
        if let limit = descriptor.fetchLimit, limit < 0 {
            throw SwiftDataError.unsupportedPredicate("Negative fetch limit")
        }
        if let offset = descriptor.fetchOffset, offset < 0 {
            throw SwiftDataError.unsupportedPredicate("Negative fetch offset")
        }
        // A limit of zero means no limit. With pending changes, the store applies the offset and limit to stored
        // values and pending models merge in afterward, matching SwiftData.
        let fetchedLimit = descriptor.fetchLimit == 0 ? nil : descriptor.fetchLimit
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
                table: "Z\(rootEntity(for: entity).name.uppercased())",
                columns: selectedColumns.map { "Z\($0.uppercased())" },
                predicateSQL: compiled?.sql,
                predicateArguments: compiled?.arguments ?? [],
                orderSQL: orderSQL,
                limit: fetchedLimit,
                offset: descriptor.fetchOffset,
                entityIDs: hasHierarchy ? descendantEntityIDs(for: entity) : nil))
        let rows = try store.read { connection in
            try connection.rows(query.sql, arguments: query.arguments)
        }
        var models: [Model] = []
        var primaryKeys: [Int64] = []
        for row in rows {
            guard row.count >= 2, case let .int(pk) = row[0], case let .int(version) = row[1] else { continue }
            let concreteEntity: Schema.Entity
            let concreteModel: any PersistentModel
            if hasHierarchy {
                guard row.count >= 3, case let .int(rawEntityID) = row[2],
                    let concreteID = Int(exactly: rawEntityID),
                    let registration = container.modelRegistration(forEntityID: concreteID),
                    let resolvedEntity = container.schema.entity(forID: concreteID),
                    registration.type is Model.Type
                else {
                    throw SwiftDataError.unsupportedStore("Hierarchy row has an unknown or incompatible Z_ENT.")
                }
                concreteEntity = resolvedEntity
                let materializationRow = [row[0], row[1]] + row.dropFirst(3)
                concreteModel = try registration.materialize(
                    context: self,
                    entity: concreteEntity,
                    attributes: selectedAttributesForMaterialization,
                    row: materializationRow,
                    storeIdentifier: storeIdentifier,
                    entityID: concreteID,
                    primaryKey: pk,
                    version: Int(version))
            } else {
                concreteEntity = entity
                concreteModel = try materialize(
                    Model.self, entity: entity, attributes: selectedAttributesForMaterialization,
                    row: row, storeIdentifier: storeIdentifier, primaryKey: pk, version: Int(version))
            }
            let key = identityKey(for: entity, primaryKey: pk)
            let refreshRow = hasHierarchy ? [row[0], row[1]] + row.dropFirst(3) : row
            let model: Model
            if let existing = identityMap.model(for: key, as: Model.self) {
                model = existing
                if !existing.hasChanges {
                    try refreshAttributes(
                        existing, entity: entity, attributes: selectedAttributesForMaterialization, row: refreshRow)
                }
                refreshVersion(existing, version: Int(version))
            } else {
                let canonical = identityMap.canonicalHandle(for: key, candidate: concreteModel).model
                guard let compatible = canonical as? Model else {
                    throw SwiftDataError.unsupportedStore("Materialized model is not query-compatible.")
                }
                model = compatible
            }
            if let backing = model.persistentBackingData as? ManagedBackingData<Model> {
                installPropertyFaults(
                    on: backing, type: Model.self, entity: entity, loadedAttributes: requestedProperties,
                    primaryKey: pk, store: store)
            }
            if hasHierarchy,
                let registration = container.modelRegistration(forEntityName: String(describing: type(of: model))),
                let resolver = try relationshipResolver()
            {
                registration.installRelationshipFaults(on: model, entity: concreteEntity, resolver: resolver)
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

    private func fetchFromDataStore<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>,
        dataStore: any DataStore,
        container: ModelContainer,
        entity: Schema.Entity,
        hasHierarchy: Bool
    ) throws -> [Model] {
        if let limit = descriptor.fetchLimit, limit < 0 {
            throw SwiftDataError.unsupportedPredicate("Negative fetch limit")
        }
        if let offset = descriptor.fetchOffset, offset < 0 {
            throw SwiftDataError.unsupportedPredicate("Negative fetch offset")
        }
        let requestedAttributeNames = try descriptor.selectedProperties.map {
            Set(try selectedAttributes($0, entity: entity, type: Model.self))
        }
        if hasHierarchy, !descriptor.sortBy.isEmpty {
            _ = try sortProperties(descriptor.sortBy, entity: entity, type: Model.self)
        }
        let includedEntityNames = Set(
            container.schema.entities.filter { isEntity($0.name, descendantOf: entity.name) }.map(\.name))
        let requestDescriptor = FetchDescriptor(
            predicate: descriptor.predicate,
            sortBy: descriptor.sortBy,
            fetchLimit: descriptor.fetchLimit == 0 ? nil : descriptor.fetchLimit,
            fetchOffset: descriptor.fetchOffset,
            includePendingChanges: false,
            propertiesToFetch: descriptor.propertiesToFetch,
            relationshipKeyPathsForPrefetching: descriptor.relationshipKeyPathsForPrefetching)
        let result = try dataStore.fetch(
            DataStoreFetchRequest(
                descriptor: requestDescriptor,
                entity: entity,
                includedEntityNames: hasHierarchy ? includedEntityNames : [entity.name]))
        var seenIdentifiers = Set<PersistentIdentifier>()
        var models: [Model] = []
        var materialized: [PersistentIdentifier: any PersistentModel] = [:]
        let includedModels = try result.snapshots.map { snapshot -> (DataStoreSnapshot, Schema.Entity) in
            guard seenIdentifiers.insert(snapshot.persistentIdentifier).inserted else {
                throw SwiftDataError.unsupportedStore(
                    "DataStore returned duplicate snapshot identifier \(snapshot.persistentIdentifier).")
            }
            guard includedEntityNames.contains(snapshot.entityName),
                let concreteEntity = container.schema.entity(forName: snapshot.entityName)
            else {
                throw SwiftDataError.unsupportedStore(
                    "DataStore returned snapshot \(snapshot.entityName) outside the requested entity subtree.")
            }
            return (snapshot, concreteEntity)
        }
        for (snapshot, concreteEntity) in includedModels {
            let resolved = try resolveDataStoreSnapshot(
                snapshot, dataStore: dataStore, container: container, cache: &materialized,
                requestedAttributeNames: requestedAttributeNames)
            guard isEntity(concreteEntity.name, descendantOf: entity.name), let model = resolved as? Model else {
                throw SwiftDataError.unsupportedStore("DataStore returned a snapshot with the wrong model type.")
            }
            models.append(model)
        }
        return try mergePending(models, descriptor: descriptor, entity: entity, evaluatorPlan: nil)
    }

    private func resolveDataStoreSnapshot(
        _ snapshot: DataStoreSnapshot,
        dataStore: any DataStore,
        container: ModelContainer,
        cache: inout [PersistentIdentifier: any PersistentModel],
        requestedAttributeNames: Set<String>? = nil
    ) throws -> any PersistentModel {
        if let cached = cache[snapshot.persistentIdentifier] { return cached }
        guard let entity = container.schema.entity(forName: snapshot.entityName),
            snapshot.persistentIdentifier.entityName == snapshot.entityName
        else {
            throw SwiftDataError.unsupportedStore("DataStore snapshot refers to an unknown entity.")
        }
        _ = try validateDataStoreSnapshot(snapshot, entity: entity, store: dataStore)
        let expectedAttributes = Set(
            entity.attributes.flatMap { attribute in
                attribute.options.contains(.flattened) ? attribute.components.map(\.columnName) : [attribute.name]
            })
        let suppliedAttributes = Set(snapshot.values.keys)
        guard suppliedAttributes.isSubset(of: expectedAttributes),
            Set(snapshot.relationships.keys) == Set(entity.relationships.map(\.name))
        else {
            throw SwiftDataError.unsupportedStore("DataStore returned an incomplete model snapshot for \(entity.name).")
        }
        if let requestedAttributeNames {
            let selectedAttributes = entity.attributes.filter { requestedAttributeNames.contains($0.name) }
            let requiredKeys = Set(
                selectedAttributes.flatMap { attribute in
                    attribute.options.contains(.flattened) ? attribute.components.map(\.columnName) : [attribute.name]
                })
            guard requiredKeys.isSubset(of: suppliedAttributes) else {
                throw SwiftDataError.unsupportedStore(
                    "DataStore omitted a requested property from \(entity.name).")
            }
            for attribute in selectedAttributes where attribute.options.contains(.flattened) {
                let suppliedCount = attribute.components.filter { suppliedAttributes.contains($0.columnName) }.count
                guard suppliedCount == 0 || suppliedCount == attribute.components.count else {
                    throw SwiftDataError.unsupportedStore(
                        "DataStore returned a partial flattened property for \(entity.name).\(attribute.name).")
                }
            }
        } else {
            guard suppliedAttributes == expectedAttributes else {
                throw SwiftDataError.unsupportedStore(
                    "DataStore returned an incomplete model snapshot for \(entity.name).")
            }
        }
        guard let registration = container.modelRegistration(forEntityName: entity.name),
            let primaryKey = snapshot.persistentIdentifier.primaryKey
        else {
            throw SwiftDataError.unsupportedStore("No model type is registered for DataStore entity \(entity.name).")
        }
        let key = identityKey(for: entity, primaryKey: primaryKey)
        let candidate = try registration.materializeDataStore(context: self, entity: entity, snapshot: snapshot)
        let model = identityMap.canonicalHandle(for: key, candidate: candidate).model
        cache[snapshot.persistentIdentifier] = model
        let wasDirty = model.hasChanges
        if !wasDirty, model !== candidate {
            try registration.applyDataStoreValues(on: model, entity: entity, snapshot: snapshot)
        }

        var relationships: [String: [any PersistentModel]] = [:]
        for relationship in entity.relationships {
            var endpoints: [any PersistentModel] = []
            let suppliedIdentifiers = snapshot.relationships[relationship.name] ?? []
            let relatedIdentifiers: [PersistentIdentifier]
            if relationship.isToMany {
                var seen = Set<PersistentIdentifier>()
                relatedIdentifiers = suppliedIdentifiers.filter { seen.insert($0).inserted }
            } else {
                relatedIdentifiers = suppliedIdentifiers
            }
            guard relationship.isToMany || relatedIdentifiers.count <= 1 else {
                throw SwiftDataError.unsupportedStore(
                    "DataStore returned multiple targets for to-one relationship '\(entity.name).\(relationship.name)'."
                )
            }
            for relatedIdentifier in relatedIdentifiers {
                guard let relatedSnapshot = try dataStore.snapshot(for: relatedIdentifier) else {
                    throw SwiftDataError.unsupportedStore("DataStore relationship target snapshot is missing.")
                }
                guard relatedSnapshot.persistentIdentifier == relatedIdentifier,
                    isEntity(relatedSnapshot.entityName, descendantOf: relationship.destination)
                else {
                    throw SwiftDataError.unsupportedStore(
                        "DataStore relationship target does not match the declared destination subtree.")
                }
                let endpoint = try resolveDataStoreSnapshot(
                    relatedSnapshot, dataStore: dataStore, container: container, cache: &cache)
                guard let destinationType = container.modelType(forEntityName: relatedSnapshot.entityName),
                    ObjectIdentifier(type(of: endpoint)) == ObjectIdentifier(destinationType)
                else {
                    throw SwiftDataError.unsupportedStore("DataStore relationship target type is not registered.")
                }
                endpoints.append(endpoint)
            }
            relationships[relationship.name] = endpoints
        }
        if !wasDirty {
            try registration.assignDataStoreRelationships(on: model, relationships: relationships)
            state.setBaseline(model, snapshot: model.snapshotLifecycle())
            let suppliedNames = Set(
                entity.attributes.compactMap { attribute -> String? in
                    if attribute.options.contains(.flattened) {
                        return attribute.components.allSatisfy { suppliedAttributes.contains($0.columnName) }
                            ? attribute.name : nil
                    }
                    return suppliedAttributes.contains(attribute.name) ? attribute.name : nil
                })
            try registration.installDataStoreFaults(
                on: model, entity: entity, dataStore: dataStore, suppliedAttributeNames: suppliedNames)
        }
        return model
    }

    private func validateDataStoreSnapshot(
        _ snapshot: DataStoreSnapshot, entity: Schema.Entity, store: any DataStore
    ) throws -> Int64 {
        guard snapshot.entityName == entity.name,
            snapshot.persistentIdentifier.entityName == entity.name,
            snapshot.persistentIdentifier.resolvedStoreIdentifier == store.identifier,
            let primaryKey = snapshot.persistentIdentifier.primaryKey
        else {
            throw SwiftDataError.unsupportedStore("DataStore returned a snapshot with an incompatible identifier.")
        }
        return primaryKey
    }

    private func dataStoreRow(
        _ snapshot: DataStoreSnapshot, attributes: [Schema.Attribute], type: any PersistentModel.Type,
        primaryKey: Int64
    ) -> [RuntimeValue] {
        var values = [RuntimeValue.int(primaryKey), .int(0)]
        for attribute in attributes {
            if attribute.options.contains(.flattened) {
                let components = type.flattenedPropertyAdapters().filter { $0.propertyName == attribute.name }
                    .sorted { $0.componentName.utf8.lexicographicallyPrecedes($1.componentName.utf8) }
                values.append(contentsOf: components.map { snapshot.values[$0.columnName].map(runtimeValue) ?? .null })
            } else {
                values.append(snapshot.values[attribute.name].map(runtimeValue) ?? .null)
            }
        }
        return values
    }

    /// Counts models matching a descriptor, which requires a persistent store.
    public func fetchCount<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) throws -> Int {
        assertAffinity()
        try processPendingChangesThrowing()
        var descriptor = descriptor
        if descriptor.fetchLimit == 0 { descriptor.fetchLimit = nil }
        if descriptor.includePendingChanges,
            !(state.insertedModels + state.changedModels + state.deletedModels).isEmpty
        {
            return try fetch(descriptor).count
        }
        if optionalContainer?.dataStore != nil { return try fetch(descriptor).count }
        if !descriptor.includePendingChanges {
            guard let container = optionalContainer,
                let store = container.store,
                let entity = container.schema.entity(forName: String(describing: Model.self))
            else { throw unsupportedStore("Fetch count") }
            let hierarchyIDs =
                entity.superentityName != nil
                    || container.schema.entities.contains {
                        $0.superentityName == entity.name
                    } ? descendantEntityIDs(for: entity) : nil
            if let limit = descriptor.fetchLimit, limit < 0 {
                throw SwiftDataError.unsupportedPredicate("Negative fetch limit")
            }
            if let offset = descriptor.fetchOffset, offset < 0 {
                throw SwiftDataError.unsupportedPredicate("Negative fetch offset")
            }
            let compiled = try compilePredicate(
                descriptor.predicate, modelType: Model.self, entity: entity, store: store,
                ordering: descriptor.sortBy.compactMap(\.propertyName))
            var conditions: [String] = []
            var countArguments = compiled?.arguments ?? []
            if let hierarchyIDs, !hierarchyIDs.isEmpty {
                conditions.append(
                    "t0.Z_ENT IN (\(Array(repeating: "?", count: hierarchyIDs.count).joined(separator: ", ")))")
                countArguments = hierarchyIDs.map { .int(Int64($0)) } + countArguments
            }
            if let compiled { conditions.append(compiled.sql) }
            let whereSQL = conditions.isEmpty ? "" : " WHERE \(conditions.map { "(\($0))" }.joined(separator: " AND "))"
            let countSQL = "SELECT COUNT(*) FROM Z\(rootEntity(for: entity).name.uppercased()) AS t0\(whereSQL)"
            let total = try store.read { connection -> Int in
                guard let row = try connection.rows(countSQL, arguments: countArguments).first,
                    case let .int(value)? = row.first
                else { return 0 }
                return Int(clamping: value)
            }
            let offset = descriptor.fetchOffset ?? 0
            guard offset < total else { return 0 }
            let remaining = total - offset
            return min(remaining, descriptor.fetchLimit ?? Int.max)
        }
        return try mergedIdentifiers(descriptor).count
    }

    /// Fetches saved models in batches.
    ///
    /// Throws `includePendingChangesWithBatchSize` unless the descriptor excludes pending changes.
    public func fetch<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>, batchSize: Int
    ) throws -> FetchResultsCollection<Model> {
        assertAffinity()
        guard !descriptor.includePendingChanges else { throw SwiftDataError.includePendingChangesWithBatchSize }
        let identifiers = try mergedIdentifiers(descriptor)
        return FetchResultsCollection(count: identifiers.count, batchSize: batchSize) { [self] range in
            identifiers[range].map { identifier in
                guard let model = model(for: identifier) as? Model else {
                    preconditionFailure("The model for \(identifier) is not a \(Model.self).")
                }
                return model
            }
        }
    }

    /// Fetches the identifiers of saved models in batches.
    ///
    /// Throws `includePendingChangesWithBatchSize` unless the descriptor excludes pending changes.
    public func fetchIdentifiers<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>, batchSize: Int
    ) throws -> FetchResultsCollection<PersistentIdentifier> {
        assertAffinity()
        guard !descriptor.includePendingChanges else { throw SwiftDataError.includePendingChangesWithBatchSize }
        let identifiers = try mergedIdentifiers(descriptor)
        return FetchResultsCollection(count: identifiers.count, batchSize: batchSize) { Array(identifiers[$0]) }
    }

    /// Fetches identifiers matching a descriptor, which requires a persistent store.
    ///
    /// Throws `sortingPendingChangesWithIdentifiers` when the descriptor both sorts and includes pending changes.
    public func fetchIdentifiers<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>
    ) throws -> [PersistentIdentifier] {
        assertAffinity()
        if descriptor.includePendingChanges, !descriptor.sortBy.isEmpty {
            throw SwiftDataError.sortingPendingChangesWithIdentifiers
        }
        return try mergedIdentifiers(descriptor)
    }

    /// Fetches identifiers matching a descriptor, merging and sorting pending changes when requested.
    package func mergedIdentifiers<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>
    ) throws -> [PersistentIdentifier] {
        assertAffinity()
        try processPendingChangesThrowing()
        var descriptor = descriptor
        if descriptor.fetchLimit == 0 { descriptor.fetchLimit = nil }
        if optionalContainer?.dataStore != nil { return try fetch(descriptor).map(\.persistentModelID) }
        if descriptor.includePendingChanges,
            !(state.insertedModels + state.changedModels + state.deletedModels).isEmpty
        {
            return try fetch(descriptor).map(\.persistentModelID)
        }
        guard let container = optionalContainer,
            let store = container.store,
            let entity = container.schema.entity(forName: String(describing: Model.self))
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
        let hasHierarchy =
            entity.superentityName != nil
            || container.schema.entities.contains {
                $0.superentityName == entity.name
            }
        let hierarchyIDs = hasHierarchy ? descendantEntityIDs(for: entity) : nil
        let sortProperties = try sortProperties(descriptor.sortBy, entity: entity, type: Model.self)
        let orderSQL = try sortSQL(descriptor.sortBy, entity: entity, type: Model.self)
        let selectedColumns =
            (["t0.Z_PK"] + (hasHierarchy ? ["t0.Z_ENT"] : [])
            + sortProperties.map { "t0.Z\($0.uppercased())" }).joined(separator: ", ")
        var sql = "SELECT \(selectedColumns) FROM Z\(rootEntity(for: entity).name.uppercased()) AS t0"
        var identifierArguments = compiled?.arguments ?? []
        var filters: [String] = []
        if let hierarchyIDs, !hierarchyIDs.isEmpty {
            filters.append("t0.Z_ENT IN (\(Array(repeating: "?", count: hierarchyIDs.count).joined(separator: ", ")))")
            identifierArguments = hierarchyIDs.map { .int(Int64($0)) } + identifierArguments
        }
        if let compiled { filters.append(compiled.sql) }
        if !filters.isEmpty { sql += " WHERE \(filters.map { "(\($0))" }.joined(separator: " AND "))" }
        sql += " ORDER BY \(orderSQL), t0.Z_PK ASC"
        if !descriptor.includePendingChanges {
            if let limit = descriptor.fetchLimit {
                sql += " LIMIT \(limit)"
                if let offset = descriptor.fetchOffset { sql += " OFFSET \(offset)" }
            } else if let offset = descriptor.fetchOffset {
                sql += " LIMIT -1 OFFSET \(offset)"
            }
        }
        let rows = try store.read { try $0.rows(sql, arguments: identifierArguments) }
        var queryRows = rows.compactMap { row -> IdentifierQueryRow? in
            guard case let .int(primaryKey)? = row.first else { return nil }
            let concreteEntityName: String
            if hasHierarchy {
                guard row.count > 1, case let .int(rawEntityID) = row[1],
                    let concreteID = Int(exactly: rawEntityID),
                    let concreteEntity = container.schema.entity(forID: concreteID)
                else { return nil }
                concreteEntityName = concreteEntity.name
            } else {
                concreteEntityName = entity.name
            }
            return IdentifierQueryRow(
                identifier: PersistentIdentifier(
                    storeIdentifier: storeIdentifier, entityName: concreteEntityName, primaryKey: primaryKey),
                sortValues: Array(row.dropFirst(hasHierarchy ? 2 : 1)))
        }
        if descriptor.includePendingChanges {
            guard
                let pendingRows = try pendingIdentifierRows(
                    queryRows,
                    modelType: Model.self,
                    entity: entity,
                    hasHierarchy: hasHierarchy,
                    sortProperties: sortProperties,
                    evaluatorPlan: compiled?.evaluatorPlan,
                    hasPredicate: descriptor.predicate != nil,
                    container: container)
            else {
                return try fetch(descriptor).map(\.persistentModelID)
            }
            queryRows = pendingRows
        }
        if descriptor.includePendingChanges, !descriptor.sortBy.isEmpty {
            queryRows = queryRows.enumerated().sorted { lhs, rhs in
                for (index, descriptor) in descriptor.sortBy.enumerated() {
                    let comparison = compareSortValues(
                        lhs.element.sortValues[index], rhs.element.sortValues[index],
                        isDecimal: isDecimalAttribute(sortProperties[index], in: entity),
                        stringCollation: descriptor.stringCollation)
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

    private func pendingIdentifierRows<Model: PersistentModel>(
        _ committedRows: [IdentifierQueryRow],
        modelType: Model.Type,
        entity: Schema.Entity,
        hasHierarchy: Bool,
        sortProperties: [String],
        evaluatorPlan: PredicatePlan?,
        hasPredicate: Bool,
        container: ModelContainer
    ) throws -> [IdentifierQueryRow]? {
        guard !hasPredicate || evaluatorPlan != nil else { return nil }
        if let evaluatorPlan, !RuntimePredicateEvaluator.relationshipProperties(in: evaluatorPlan).isEmpty {
            return nil
        }

        let changedModels = state.changedModels
        let insertedModels = state.insertedModels
        let deletedModels = state.deletedModels
        let changedIDs = Set(changedModels.map(\.persistentModelID))
        let deletedIDs = Set(deletedModels.map(\.persistentModelID))
        var rows = committedRows.filter {
            !changedIDs.contains($0.identifier) && !deletedIDs.contains($0.identifier)
        }

        let candidates = insertedModels + changedModels
        var seenIDs = Set<PersistentIdentifier>()
        let deletedObjects = Set(deletedModels.map(ObjectIdentifier.init))
        for candidate in candidates {
            guard let model = candidate as? Model,
                !deletedObjects.contains(ObjectIdentifier(model)),
                !model.isDeleted,
                let concreteEntityName = modelEntityName(of: model),
                container.schema.entity(forName: concreteEntityName) != nil,
                !hasHierarchy || isEntity(concreteEntityName, descendantOf: entity.name)
            else { continue }

            let identifier = model.persistentModelID
            guard seenIDs.insert(identifier).inserted else { continue }
            if let evaluatorPlan, try !pendingModel(model, matches: evaluatorPlan) { continue }
            let values = try runtimeValues(for: model, selecting: Set(sortProperties))
            rows.append(
                IdentifierQueryRow(
                    identifier: identifier,
                    sortValues: sortProperties.map { values[$0] ?? .null }))
        }

        return rows
    }

    /// Enumerates models matching a descriptor, which requires a persistent store.
    public func enumerate<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>,
        batchSize: Int = 5000,
        allowEscapingMutations: Bool = false,
        block: (Model) throws -> Void
    ) throws {
        assertAffinity()
        guard batchSize > 0 else { throw SwiftDataError.unsupportedPredicate("Batch size must be positive") }
        let identifiers = try mergedIdentifiers(descriptor)
        for start in stride(from: 0, to: identifiers.count, by: batchSize) {
            let end = min(start + batchSize, identifiers.count)
            for identifier in identifiers[start..<end] {
                guard let model = try enumeratedModel(for: identifier, descriptor: descriptor) else { continue }
                if allowEscapingMutations {
                    try block(model)
                } else {
                    let before = try modelValues(model)
                    let relationshipState = relationshipMutationValues(model)
                    let pendingBefore = state.pendingState()
                    let frameID = state.beginTransactionFrame()
                    let didMutate: Bool
                    do {
                        try block(model)
                        let changedRelationships =
                            relationshipMutationValues(model) != relationshipState
                            || state.pendingState().relationshipMutationEvents.dropFirst(
                                pendingBefore.relationshipMutationEvents.count
                            ).contains { event in
                                event.owner === model || event.oldEndpoints.contains(where: { $0 === model })
                                    || event.newEndpoints.contains(where: { $0 === model })
                            }
                        didMutate = try modelValues(model) != before || changedRelationships
                    } catch {
                        guard rollbackCurrentTransaction(expectedFrameID: frameID) else {
                            throw SwiftDataError.unsupportedStore("Enumeration transaction frame changed")
                        }
                        throw error
                    }
                    if didMutate {
                        guard rollbackCurrentTransaction(expectedFrameID: frameID) else {
                            throw SwiftDataError.unsupportedStore("Enumeration transaction frame changed")
                        }
                        throw SwiftDataError.unsupportedStore("Enumeration mutations are not allowed")
                    }
                    state.commitTransactionFrame()
                }
            }
        }
    }

    private func enumeratedModel<Model: PersistentModel>(
        for identifier: PersistentIdentifier,
        descriptor: FetchDescriptor<Model>
    ) throws -> Model? {
        if !descriptor.includePendingChanges,
            let deleted = state.deletedModels.first(where: { $0.persistentModelID == identifier }) as? Model
        {
            return deleted
        }
        return try model(for: identifier)
    }

    /// Returns the model for an identifier, loading it from the store when it is not registered.
    ///
    /// When no row exists for the identifier, returns an unattached placeholder of the identifier's model type;
    /// reading its unassigned properties traps. Traps when the container has no model type for the entity.
    public func model(for persistentModelID: PersistentIdentifier) -> any PersistentModel {
        assertAffinity()
        guard let modelType = optionalContainer?.modelType(forEntityName: persistentModelID.entityName) else {
            preconditionFailure("No model type named '\(persistentModelID.entityName)' exists in the container.")
        }
        func resolve<Model: PersistentModel>(_: Model.Type) -> any PersistentModel {
            if let model = try? model(for: persistentModelID) as Model? { return model }
            return Model(backingData: Model.createBackingData())
        }
        return resolve(modelType)
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
            guard let permanent = temporaryIdentifiers[identifier] else {
                throw unsupportedStore("No permanent identifier mapping exists for the requested temporary model ID.")
            }
            return try model(for: permanent)
        }
        if let container = optionalContainer, container.store != nil,
            identifier.resolvedStoreIdentifier == storeIdentifier,
            let requestedEntity = container.schema.entity(forName: String(describing: Model.self)),
            let concreteEntity = container.schema.entity(forName: identifier.entityName),
            requestedEntity.name != concreteEntity.name
                || requestedEntity.superentityName != nil
                || concreteEntity.superentityName != nil,
            rootEntity(for: requestedEntity).name == rootEntity(for: concreteEntity).name,
            requestedEntity.name == concreteEntity.name
                || (container.schema.entityIDsByName[concreteEntity.name].map {
                    descendantEntityIDs(for: requestedEntity).contains($0)
                } == true)
        {
            guard let store = container.store else { throw unsupportedStore("Model lookup") }
            let root = rootEntity(for: concreteEntity)
            let attributes = canonicalAttributes(for: concreteEntity)
            let columns = storedColumnNames(for: attributes).map { "Z\($0.uppercased())" }
            let selectColumns = (["Z_PK", "Z_OPT", "Z_ENT"] + columns).joined(separator: ", ")
            guard
                let row = try store.read({ connection in
                    try connection.rows(
                        "SELECT \(selectColumns) FROM Z\(root.name.uppercased()) WHERE Z_PK = ?",
                        arguments: [.int(key)])
                }).first,
                row.count >= 3,
                case let .int(rawEntityID) = row[2],
                let concreteID = Int(exactly: rawEntityID),
                container.schema.entityIDsByName[concreteEntity.name] == concreteID,
                container.schema.entity(forID: concreteID)?.name == identifier.entityName,
                let registration = container.modelRegistration(forEntityID: concreteID),
                registration.type is Model.Type
            else { return nil }
            let materializationRow = [row[0], row[1]] + row.dropFirst(3)
            let version = runtimeInt(row[1])
            let identity = identityKey(for: concreteEntity, primaryKey: key)
            let model: any PersistentModel
            if let existing = identityMap.model(for: identity, as: Model.self) {
                model = existing
                if !existing.hasChanges {
                    try refreshAttributes(
                        existing, entity: concreteEntity, attributes: attributes, row: materializationRow)
                }
                refreshVersion(existing, version: version)
            } else {
                let candidate = try registration.materialize(
                    context: self,
                    entity: concreteEntity,
                    attributes: attributes,
                    row: materializationRow,
                    storeIdentifier: identifier.resolvedStoreIdentifier,
                    entityID: concreteID,
                    primaryKey: key,
                    version: version)
                model = identityMap.canonicalHandle(for: identity, candidate: candidate).model
            }
            guard let compatible = model as? Model else {
                throw SwiftDataError.unsupportedStore("Materialized model is not query-compatible.")
            }
            if let resolvedRegistration = container.modelRegistration(forEntityName: concreteEntity.name),
                let resolver = try relationshipResolver()
            {
                resolvedRegistration.installRelationshipFaults(
                    on: compatible, entity: concreteEntity, resolver: resolver)
            }
            relationshipLoadVisited.removeAll()
            var visited = relationshipLoadVisited
            try materializeRelationships(
                [compatible], entity: concreteEntity, primaryKeys: [key], store: store, requested: nil,
                visited: &visited)
            relationshipLoadVisited = visited
            return compatible
        }
        guard let container = optionalContainer,
            identifier.resolvedStoreIdentifier == storeIdentifier,
            let entity = container.schema.entity(forName: identifier.entityName),
            let modelEntity = container.schema.entity(forName: String(describing: Model.self)),
            isEntity(entity.name, descendantOf: modelEntity.name)
        else { throw unsupportedStore("Model lookup") }
        if let dataStore = container.dataStore {
            guard let snapshot = try dataStore.snapshot(for: identifier) else { return nil }
            guard try validateDataStoreSnapshot(snapshot, entity: entity, store: dataStore) == key else {
                throw SwiftDataError.unsupportedStore(
                    "DataStore snapshot identifier does not match the requested model.")
            }
            var cache: [PersistentIdentifier: any PersistentModel] = [:]
            guard
                let model = try resolveDataStoreSnapshot(
                    snapshot, dataStore: dataStore, container: container, cache: &cache) as? Model
            else {
                throw SwiftDataError.unsupportedStore("DataStore snapshot is not compatible with the requested model.")
            }
            return model
        }
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
            Model.self, entity: entity, attributes: attributes, row: row,
            storeIdentifier: identifier.resolvedStoreIdentifier,
            primaryKey: key, version: row.count > 1 ? runtimeInt(row[1]) : 0)
        let model =
            identityMap.canonicalHandle(
                for: identityKey(for: entity, primaryKey: key), candidate: candidate
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
        guard let container = optionalContainer,
            let key = identifier.primaryKey,
            identifier.resolvedStoreIdentifier == storeIdentifier,
            let requestedEntity = container.schema.entity(forName: String(describing: Model.self)),
            let concreteEntity = container.schema.entity(forName: identifier.entityName),
            let concreteEntityID = container.schema.entityIDsByName[concreteEntity.name],
            rootEntity(for: requestedEntity).name == rootEntity(for: concreteEntity).name,
            requestedEntity.name == concreteEntity.name
                || descendantEntityIDs(for: requestedEntity).contains(concreteEntityID)
        else { return nil }
        guard
            let model = identityMap.model(
                for: identityKey(for: concreteEntity, primaryKey: key), as: Model.self),
            model.persistentModelID == identifier
        else { return nil }
        return model
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

    /// Fetches history transactions matching a descriptor.
    ///
    /// Throws `historyTokenExpired` when the predicate refers to a token for a transaction that was deleted, and
    /// `invalidTransactionFetchRequest` for transaction types other than `DefaultHistoryTransaction`.
    public func fetchHistory<T: HistoryTransaction>(_ descriptor: HistoryDescriptor<T>) throws -> [T] {
        assertAffinity()
        var transactions = try matchingHistory(descriptor)
        if !descriptor.sortBy.isEmpty { transactions.sort(using: descriptor.sortBy) }
        if descriptor.fetchLimit > 0 { transactions = Array(transactions.prefix(Int(clamping: descriptor.fetchLimit))) }
        return transactions
    }

    /// Deletes the history transactions matching a descriptor's predicate.
    public func deleteHistory<T: HistoryTransaction>(_ descriptor: HistoryDescriptor<T>) throws {
        assertAffinity()
        guard let store = optionalContainer?.store as? any RuntimeHistoryStore else {
            throw unsupportedStore("History is unavailable for the configured store.")
        }
        let identifiers = try matchingHistory(descriptor).compactMap { ($0 as? DefaultHistoryTransaction)?.id }
        try store.deleteHistory(transactionIDs: identifiers)
    }

    private func matchingHistory<T: HistoryTransaction>(_ descriptor: HistoryDescriptor<T>) throws -> [T] {
        guard T.self == DefaultHistoryTransaction.self else {
            throw SwiftDataError.invalidTransactionFetchRequest
        }
        guard let container = optionalContainer, let store = container.store as? any RuntimeHistoryStore else {
            throw unsupportedStore("History is unavailable for the configured store.")
        }
        let stored = try store.fetchHistory()
        if let predicate = descriptor.predicate {
            let existing = Set(stored.map(\.id))
            let latestIssued = try store.latestIssuedHistoryTransactionID()
            for token in Self.historyTokens(in: predicate) {
                guard let value = token.tokenValue?[storeIdentifier] else { continue }
                if value <= latestIssued, !existing.contains(value) { throw SwiftDataError.historyTokenExpired }
            }
        }
        let transactions = stored.map { transaction in
            DefaultHistoryTransaction(
                timestamp: transaction.timestamp,
                changes: transaction.changes.enumerated().compactMap { ordinal, change in
                    guard let modelType = container.modelType(forEntityName: change.entityName) else { return nil }
                    func make<Model: PersistentModel>(_ type: Model.Type) -> HistoryChange {
                        HistoryChange.make(
                            change, modelType: type, transactionIdentifier: transaction.id, ordinal: ordinal,
                            storeIdentifier: storeIdentifier)
                    }
                    return make(modelType)
                },
                token: DefaultHistoryToken(storeTokens: [storeIdentifier: transaction.id]),
                transactionIdentifier: transaction.id, storeIdentifier: storeIdentifier,
                bundleIdentifier: transaction.bundleIdentifier, processIdentifier: transaction.processIdentifier,
                author: transaction.author)
        }
        let typed = transactions.compactMap { $0 as? T }
        guard let predicate = descriptor.predicate else { return typed }
        return try typed.filter { try predicate.evaluate($0) }
    }

    /// Returns the history tokens captured as constants in a predicate's expression tree.
    private static func historyTokens(in value: Any) -> [DefaultHistoryToken] {
        if let token = value as? DefaultHistoryToken { return [token] }
        return Mirror(reflecting: value).children.flatMap { historyTokens(in: $0.value) }
    }

    /// Posts `willSave` without user info, then commits pending changes and posts `didSave` when any existed.
    private func saveChanges() throws {
        assertAffinity()
        if postsSaveNotifications {
            NotificationCenter.default.post(name: Self.willSave, object: self, userInfo: nil)
        }
        guard state.hasChanges else {
            detachDeletedInsertions()
            return
        }
        guard allowsSave else { throw unsupportedStore("Saving is disabled") }
        let before = state.pendingState()
        let insertedModels = before.inserted
        let originalInsertedIDs = insertedModels.map { ($0, $0.persistentModelID) }

        if let testSaveHook {
            try testSaveHook()
            let savedIDs = saveNotificationIdentifiers(before: before, insertedModels: originalInsertedIDs)
            finalizePendingChanges()
            state.clearRelationshipMutationEvents()
            if postsSaveNotifications {
                NotificationCenter.default.post(name: Self.didSave, object: self, userInfo: savedIDs)
            }
            return
        }
        if let dataStore = optionalContainer?.dataStore {
            try persistPendingChanges(to: dataStore)
        } else if let store = optionalContainer?.store {
            try persistPendingChanges(to: store)
        } else {
            throw unsupportedStore("Saving")
        }
        let savedIDs = saveNotificationIdentifiers(before: before, insertedModels: originalInsertedIDs)
        detachDeletedInsertions()
        if postsSaveNotifications {
            NotificationCenter.default.post(name: Self.didSave, object: self, userInfo: savedIDs)
        }
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

    /// Discards pending changes.
    ///
    /// Pending insertions detach and pending deletions are restored. Changed models stop reporting changes but
    /// keep their current in-memory values, including relationships, until a later fetch refreshes them from
    /// the store; nothing reverts in the store.
    public func rollback() {
        assertAffinity()
        detachDeletedInsertions()
        state.withExclusiveOperation {
            let pendingState = state.pendingState()
            let pendingInsertions = pendingState.inserted
            for (model, snapshot) in pendingState.snapshots.values {
                if state.contains(model, in: pendingInsertions) {
                    model.restoreValuesAndDetachLifecycle(snapshot)
                } else if state.contains(model, in: pendingState.deleted) {
                    model.restoreLifecycle(snapshot)
                } else {
                    let current = model.snapshotLifecycle()
                    model.restoreLifecycle(
                        BackingDataSnapshot(
                            values: current.values, context: snapshot.context, identifier: snapshot.identifier,
                            isDeleted: snapshot.isDeleted, hasChanges: false, savedValues: snapshot.savedValues,
                            primaryKey: snapshot.primaryKey, entityID: snapshot.entityID,
                            optimisticLockVersion: snapshot.optimisticLockVersion))
                }
            }
            for model in pendingInsertions where pendingState.snapshots[ObjectIdentifier(model)] == nil {
                cancelInsertion(model)
            }
            for model in pendingInsertions { clearDataStoreTemporaryIdentifiers(for: model) }
            state.clearPending()
            state.clearRelationshipMutationEvents()
            autosaveTrigger.cancel()
            for (model, snapshot) in pendingState.snapshots.values where !state.contains(model, in: pendingInsertions) {
                state.setBaseline(model, snapshot: snapshot)
            }
            for model in pendingState.deleted {
                state.removeBaseline(for: model)
            }
            undoRegisteredModels.removeAll()
            currentUndoGroup = nil
            undoManagerGeneration &+= 1
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
                    registerUndoGroup(from: entrySnapshots)
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

    package func registerUndoIfNeeded(
        _ model: any PersistentModel, snapshot: BackingDataSnapshot,
        retainModel: Bool = false, restoresDeletedRow: Bool = false
    ) {
        guard undoManagerStorage != nil, !isApplyingUndoGroup else { return }
        assertAffinity()
        guard !state.hasTransaction else { return }
        guard
            model.modelContext === self,
            undoRegisteredModels.insert(ObjectIdentifier(model)).inserted
        else { return }
        let undoSnapshot = snapshotIncludingRelationshipValues(snapshot, for: model)
        let group: UndoGroupOperation
        if let currentUndoGroup {
            group = currentUndoGroup
        } else {
            group = UndoGroupOperation(context: self, managerGeneration: undoManagerGeneration)
            currentUndoGroup = group
            registerUndoOperation(group)
        }
        group.append(
            model: model, snapshot: undoSnapshot, retainModel: retainModel,
            restoresDeletedRow: restoresDeletedRow)
    }

    private func registerUndoGroup(
        from snapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)],
        retaining retainedModels: Set<ObjectIdentifier> = []
    ) {
        guard undoManagerStorage != nil else { return }
        for (model, snapshot) in snapshots.values {
            registerUndoIfNeeded(
                model, snapshot: snapshot,
                retainModel: retainedModels.contains(ObjectIdentifier(model)),
                restoresDeletedRow: retainedModels.contains(ObjectIdentifier(model)))
        }
    }

    private func snapshotIncludingRelationshipValues(
        _ snapshot: BackingDataSnapshot, for model: any PersistentModel
    ) -> BackingDataSnapshot {
        let adapters = containerStorage?.relationshipAdapterTable[ObjectIdentifier(type(of: model))] ?? []
        guard !adapters.isEmpty else { return snapshot }
        var values = snapshot.values
        for adapter in adapters {
            guard let endpoints = adapter.read(model),
                let value = try? adapter.makeValue(endpoints)
            else { continue }
            values[adapter.keyPath] = value
        }
        return BackingDataSnapshot(
            values: values, context: snapshot.context, identifier: snapshot.identifier,
            isDeleted: snapshot.isDeleted, hasChanges: snapshot.hasChanges, savedValues: snapshot.savedValues,
            primaryKey: snapshot.primaryKey, entityID: snapshot.entityID,
            optimisticLockVersion: snapshot.optimisticLockVersion)
    }

    func registerUndoOperation(_ operation: UndoGroupOperation) {
        guard let manager = undoManagerStorage else { return }
        #if canImport(ObjectiveC)
            let handle = UndoOperationHandle(operation)
            MainActor.assumeIsolated {
                // UndoManager does not retain its target, so the handler keeps the handle alive.
                manager.registerUndo(withTarget: manager) { [handle] _ in
                    MainActor.assumeIsolated { handle.perform() }
                }
            }
        #else
            manager.registerUndo(withTarget: operation) { $0.perform() }
        #endif
    }

    func endCurrentUndoGroup() {
        currentUndoGroup = nil
        undoRegisteredModels.removeAll()
    }

    func replaceUndoSnapshotIfRegistered(
        for model: any PersistentModel,
        with snapshot: BackingDataSnapshot,
        relationships: [String: [any PersistentModel]] = [:]
    ) {
        currentUndoGroup?.replaceSnapshot(for: model, with: snapshot, relationships: relationships)
    }

    func setUndoRelationshipEndpoints(
        for model: any PersistentModel, relationships: [String: [any PersistentModel]]
    ) {
        currentUndoGroup?.setRelationshipEndpoints(for: model, relationships: relationships)
    }

    func applyUndoGroup(_ members: [UndoGroupMember]) -> [UndoGroupMember] {
        assertAffinity()
        // The calling operation registers its own inverse, so writes made while restoring must not.
        isApplyingUndoGroup = true
        defer { isApplyingUndoGroup = false }
        var inverse: [UndoGroupMember] = []
        for member in members {
            guard let model = member.resolvedModel else { continue }
            let restoresDeletedRow = member.restoresDeletedRow
            let isPendingDeletion = model.modelContext === self && state.containsDeleted(model)
            let reinsertsDeletedRow = restoresDeletedRow && model.modelContext == nil
            guard model.modelContext === self || reinsertsDeletedRow else { continue }
            let preUndoSnapshot = model.snapshotLifecycle()
            inverse.append(
                UndoGroupMember(
                    model: model,
                    retainedModel: member.restoresDeletedRow || member.snapshot.isDeleted || model.isDeleted
                        ? model : nil,
                    restoresDeletedRow: member.snapshot.isDeleted && member.retainedModel != nil
                        && !isPendingDeletion,
                    snapshot: UndoGroupOperation.detachedSnapshot(preUndoSnapshot)))
            undoRegisteredModels.remove(ObjectIdentifier(model))
            model.restoreLifecycle(
                BackingDataSnapshot(
                    values: member.snapshot.values,
                    context: self,
                    identifier: member.snapshot.identifier,
                    isDeleted: member.snapshot.isDeleted,
                    hasChanges: true,
                    savedValues: preUndoSnapshot.values,
                    primaryKey: member.snapshot.primaryKey,
                    entityID: member.snapshot.entityID,
                    optimisticLockVersion: reinsertsDeletedRow
                        ? member.snapshot.optimisticLockVersion : preUndoSnapshot.optimisticLockVersion))
            model.attachBackingData(to: self)
            if let adapters = containerStorage?.relationshipAdapterTable[ObjectIdentifier(type(of: model))] {
                for adapter in adapters {
                    guard let endpoints = member.relationshipEndpoints[adapter.name],
                        let value = try? adapter.makeValue(endpoints)
                    else { continue }
                    try? adapter.assign(value, to: model)
                }
            }
            model.setInsertionChanged()
            if reinsertsDeletedRow {
                state.restoreDeletedModel(model, asInserted: true, snapshot: preUndoSnapshot)
                if let entity = containerStorage?.schema.entity(forName: model.persistentModelID.entityName),
                    let primaryKey = model.persistentModelID.primaryKey
                {
                    identityMap.register(model, for: identityKey(for: entity, primaryKey: primaryKey))
                }
            } else if member.snapshot.isDeleted && !isPendingDeletion {
                markDeletedTyped(model)
                state.markDeleted(model)
            } else if isPendingDeletion {
                state.restorePendingDeletion(model)
            } else {
                state.recordMutation(model)
            }
            state.recordRestoredRelationshipChanges(model, from: preUndoSnapshot)
        }
        if !inverse.isEmpty { autosaveHandle.changed() }
        return inverse
    }

    private var storeIdentifier: String {
        optionalContainer?.storeIdentifier ?? "default"
    }

    private func canonicalAttributes(for entity: Schema.Entity) -> [Schema.Attribute] {
        entity.attributes.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }

    private func hierarchyAttributes(for entity: Schema.Entity) throws -> [Schema.Attribute] {
        guard let container = optionalContainer else { throw unsupportedStore("Hierarchy schema lookup") }
        let identifiers = Set(descendantEntityIDs(for: entity))
        var attributesByName: [String: Schema.Attribute] = [:]
        for candidate in container.schema.entities
        where container.schema.entityIDsByName[candidate.name].map(
            identifiers.contains) == true
        {
            for attribute in candidate.attributes {
                let key = attribute.name.uppercased()
                if let existing = attributesByName[key], existing != attribute {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Hierarchy query encountered incompatible column declarations for '\(attribute.name)'.")
                }
                attributesByName[key] = attribute
            }
        }
        return attributesByName.values.sorted {
            $0.name.uppercased().utf8.lexicographicallyPrecedes($1.name.uppercased().utf8)
        }
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
            if let name = type.propertyName(forKeyPath: keyPath),
                let metadata = type.schemaMetadata().first(where: { $0.name == name }),
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
            guard let name = type.propertyName(forKeyPath: keyPath),
                let property = type.schemaMetadata().first(where: { $0.name == name }),
                property.isRelationship,
                entity.relationships.contains(where: { $0.name == property.name })
            else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "relationshipKeyPathsForPrefetching contains a non-relationship key path")
            }
            return property.name
        }
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
        let tree = try PredicateRuntimeTreeBuilder.build(
            predicate.expression,
            modelType: modelType,
            entity: entity,
            schema: containerStorage?.schema,
            modelTypeForEntity: { [weak container = containerStorage] entityName in
                container?.modelType(forEntityName: entityName)
            })
        func relationshipDescriptor(
            ownerEntity: Schema.Entity,
            relationship: Schema.Relationship
        ) -> RuntimePredicateRelationship? {
            guard let schema = containerStorage?.schema,
                let destination = schema.entity(forName: relationship.destination)
            else { return nil }
            if relationship.isToMany {
                let inverse = relationship.inverse.flatMap { inverseName in
                    schema.relationshipDeclaration(named: inverseName, onOrBelow: relationship.destination)
                }
                if let inverse, !inverse.relationship.isToMany {
                    guard
                        let mapping = schema.relationshipStorageMapping(
                            modelEntityName: inverse.entityName, relationshipName: inverse.relationship.name)
                    else { return nil }
                    return RuntimePredicateRelationship(
                        ownerEntityName: ownerEntity.name,
                        propertyName: relationship.name,
                        destinationEntityName: relationship.destination,
                        destinationRootEntityName: rootEntity(for: destination).name,
                        foreignKeyColumnName: mapping.storageColumnName,
                        destinationEntityIDs: descendantEntityIDs(for: destination),
                        isToMany: true,
                        storesForeignKeyOnDestination: true)
                }
                guard relationship.inverse == nil || inverse?.relationship.isToMany == true,
                    let joinTable = joinTableName(for: ownerEntity, relationship)
                else { return nil }
                let relationshipIsSideAOwner = joinSideAOwner(ownerEntity, relationship)
                return RuntimePredicateRelationship(
                    ownerEntityName: ownerEntity.name,
                    propertyName: relationship.name,
                    destinationEntityName: relationship.destination,
                    destinationRootEntityName: rootEntity(for: destination).name,
                    foreignKeyColumnName: "",
                    destinationEntityIDs: descendantEntityIDs(for: destination),
                    isToMany: true,
                    joinTableName: joinTable,
                    ownerJoinColumnName: relationshipIsSideAOwner ? "Z_A" : "Z_B",
                    destinationJoinColumnName: relationshipIsSideAOwner ? "Z_B" : "Z_A")
            }
            if isToOneStorageOwner(ownerEntity, relationship),
                let mapping = schema.relationshipStorageMapping(
                    modelEntityName: ownerEntity.name, relationshipName: relationship.name)
            {
                return RuntimePredicateRelationship(
                    ownerEntityName: ownerEntity.name,
                    propertyName: relationship.name,
                    destinationEntityName: relationship.destination,
                    destinationRootEntityName: rootEntity(for: destination).name,
                    foreignKeyColumnName: mapping.storageColumnName,
                    destinationEntityIDs: descendantEntityIDs(for: destination))
            }
            guard let inverseName = relationship.inverse,
                let inverse = schema.relationshipDeclaration(named: inverseName, onOrBelow: relationship.destination),
                !inverse.relationship.isToMany,
                let mapping = schema.relationshipStorageMapping(
                    modelEntityName: inverse.entityName, relationshipName: inverse.relationship.name),
                let inverseOwner = schema.entity(forName: inverse.entityName)
            else { return nil }
            return RuntimePredicateRelationship(
                ownerEntityName: ownerEntity.name,
                propertyName: relationship.name,
                destinationEntityName: relationship.destination,
                destinationRootEntityName: rootEntity(for: destination).name,
                foreignKeyColumnName: mapping.storageColumnName,
                destinationEntityIDs: descendantEntityIDs(for: destination),
                queriesInverseToOne: true,
                inverseOwnerRootEntityName: rootEntity(for: inverseOwner).name,
                inverseOwnerEntityIDs: descendantEntityIDs(for: inverseOwner))
        }
        let relationshipPaths =
            containerStorage?.schema.entities.flatMap { ownerEntity in
                ownerEntity.relationships.compactMap {
                    relationshipDescriptor(ownerEntity: ownerEntity, relationship: $0)
                }
            } ?? []
        let flattenedAttributes = entity.attributes.flatMap { attribute in
            attribute.components.map { ($0.columnName, $0.type) }
        }
        var attributeTypes = Dictionary(
            uniqueKeysWithValues: entity.attributes.map { ($0.name, $0.type) } + flattenedAttributes)
        var attributeNames = Set(entity.attributes.map(\.name)).union(flattenedAttributes.map(\.0))
        var optionalAttributeNames = Set(entity.attributes.filter(\.isOptional).map(\.name))
        func addCollectionPath(
            ownerEntity: Schema.Entity,
            relationship: Schema.Relationship,
            prefix: String,
            depth: Int
        ) {
            guard depth <= OSDQueryLimits.maximumNestedCollectionPredicateDepth,
                relationshipPaths.contains(where: {
                    $0.ownerEntityName == ownerEntity.name && $0.propertyName == relationship.name && $0.isToMany
                }),
                let destination = containerStorage?.schema.entity(forName: relationship.destination)
            else { return }
            let path = prefix.isEmpty ? relationship.name : "\(prefix)[].\(relationship.name)"
            attributeNames.insert(path)
            attributeTypes[path] = "OSDToManyRelationship"
            for attribute in destination.attributes where !attribute.options.contains(.flattened) {
                let elementPath = "\(path)[].\(attribute.name)"
                attributeNames.insert(elementPath)
                attributeTypes[elementPath] = attribute.type
                if attribute.isOptional { optionalAttributeNames.insert(elementPath) }
            }
            guard depth < OSDQueryLimits.maximumNestedCollectionPredicateDepth else { return }
            for nestedRelationship in destination.relationships where nestedRelationship.isToMany {
                addCollectionPath(
                    ownerEntity: destination,
                    relationship: nestedRelationship,
                    prefix: path,
                    depth: depth + 1)
            }
        }
        for relationship in entity.relationships where relationship.isToMany {
            addCollectionPath(ownerEntity: entity, relationship: relationship, prefix: "", depth: 1)
        }
        if let schema = containerStorage?.schema {
            func addRelationshipPaths(
                ownerEntity: Schema.Entity,
                prefix: [String],
                visited: Set<String>,
                hasOptionalPrefix: Bool
            ) {
                guard prefix.count < schema.entities.count else { return }
                for relationship in ownerEntity.relationships where !relationship.isToMany {
                    guard
                        relationshipPaths.contains(where: {
                            $0.ownerEntityName == ownerEntity.name && $0.propertyName == relationship.name
                        }),
                        let destination = schema.entity(forName: relationship.destination)
                    else { continue }
                    let path = prefix + [relationship.name]
                    let relationshipPath = path.joined(separator: ".")
                    attributeNames.insert(relationshipPath)
                    attributeTypes[relationshipPath] = "OSDToOneRelationship"
                    let relationshipMayBeMissing = hasOptionalPrefix || relationship.isOptional
                    if relationshipMayBeMissing { optionalAttributeNames.insert(relationshipPath) }
                    for attribute in destination.attributes where !attribute.options.contains(.flattened) {
                        let scalarPath = "\(relationshipPath).\(attribute.name)"
                        attributeNames.insert(scalarPath)
                        attributeTypes[scalarPath] = attribute.type
                        if relationshipMayBeMissing || attribute.isOptional {
                            optionalAttributeNames.insert(scalarPath)
                        }
                    }
                    for collection in destination.relationships where collection.isToMany {
                        guard
                            relationshipPaths.contains(where: {
                                $0.ownerEntityName == destination.name && $0.propertyName == collection.name
                            }),
                            let collectionDestination = schema.entity(forName: collection.destination)
                        else { continue }
                        let collectionPath = "\(relationshipPath).\(collection.name)"
                        attributeNames.insert(collectionPath)
                        attributeTypes[collectionPath] = "OSDToManyRelationship"
                        for attribute in collectionDestination.attributes where !attribute.options.contains(.flattened)
                        {
                            let elementPath = "\(collectionPath)[].\(attribute.name)"
                            attributeNames.insert(elementPath)
                            attributeTypes[elementPath] = attribute.type
                            if attribute.isOptional { optionalAttributeNames.insert(elementPath) }
                        }
                        for nestedCollection in relationshipPaths
                        where nestedCollection.ownerEntityName == collectionDestination.name
                            && nestedCollection.isToMany
                        {
                            guard
                                let nestedDestination = schema.entity(
                                    forName: nestedCollection.destinationEntityName)
                            else { continue }
                            let nestedPath = "\(collectionPath)[].\(nestedCollection.propertyName)"
                            attributeNames.insert(nestedPath)
                            attributeTypes[nestedPath] = "OSDToManyRelationship"
                            for attribute in nestedDestination.attributes where !attribute.options.contains(.flattened)
                            {
                                let nestedElementPath = "\(nestedPath)[].\(attribute.name)"
                                attributeNames.insert(nestedElementPath)
                                attributeTypes[nestedElementPath] = attribute.type
                                if attribute.isOptional { optionalAttributeNames.insert(nestedElementPath) }
                            }
                        }
                    }
                    guard !visited.contains(destination.name) else { continue }
                    addRelationshipPaths(
                        ownerEntity: destination,
                        prefix: path,
                        visited: visited.union([destination.name]),
                        hasOptionalPrefix: relationshipMayBeMissing)
                }
            }
            addRelationshipPaths(
                ownerEntity: entity,
                prefix: [],
                visited: [entity.name],
                hasOptionalPrefix: false)
        }
        return try compiler.compile(
            RuntimePredicateRequest(
                entityName: entity.name,
                root: tree.root,
                ordering: ordering,
                typedCaptures: tree.captures,
                captureEncoding: .typed,
                attributeNames: attributeNames,
                attributeTypes: attributeTypes,
                optionalAttributeNames: optionalAttributeNames,
                identifierCaptures: tree.identifierCaptures,
                storeIdentifier: storeIdentifier,
                relationships: relationshipPaths))
    }

    private func sortSQL<Model: PersistentModel>(
        _ descriptors: [SortDescriptor<Model>],
        entity: Schema.Entity,
        type: Model.Type
    ) throws -> String {
        let columns = try descriptors.map { descriptor -> String in
            guard let keyPath = descriptor.keyPath else { throw SwiftDataError.unsupportedSortDescriptor }
            guard
                let property = resolvedPropertyName(
                    keyPath: keyPath, fallback: descriptor.propertyName, entity: entity, type: type),
                !isBlobFlattenedColumn(property, in: entity),
                property.utf8.allSatisfy({
                    ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95
                })
            else {
                throw SwiftDataError.unsupportedPredicate("Sort key must be a direct persisted attribute")
            }
            let collation: String?
            if let attribute = entity.attributes.first(where: { $0.name == property }) {
                collation = Self.sortCollation(for: attribute)
            } else if let component = entity.attributes.lazy.flatMap(\.components)
                .first(where: { $0.columnName == property })
            {
                collation = Self.sortCollation(forType: component.type)
            } else {
                throw SwiftDataError.unsupportedPredicate("Sort key is not a persisted attribute")
            }
            let resolvedCollation =
                collation == StringSortCollation.localizedStandard.sqlCollation
                ? descriptor.stringCollation.sqlCollation : collation
            let collationSQL = resolvedCollation.map { " COLLATE \($0)" } ?? ""
            return "t0.Z\(property.uppercased())\(collationSQL) \(descriptor.isAscending ? "ASC" : "DESC")"
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
        if let evaluatorPlan {
            // Unchanged rows matched on stored values; only changed models are re-evaluated in memory.
            let changed = Set(state.changedModels.map(ObjectIdentifier.init))
            merged = try merged.filter {
                try !changed.contains(ObjectIdentifier($0)) || pendingModel($0, matches: evaluatorPlan)
            }
        }
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
                        sortValues[ObjectIdentifier(rhs.element)]?[index] ?? .null,
                        isDecimal: isDecimalAttribute(sortNames[index], in: entity),
                        stringCollation: descriptor.stringCollation)
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
        if let limit = descriptor.fetchLimit, limit > 0 {
            merged = Array(merged.prefix(limit))
        }
        return merged
    }

    private func pendingModel<Model: PersistentModel>(
        _ model: Model,
        matches plan: PredicatePlan
    ) throws -> Bool {
        if !RuntimePredicateEvaluator.nestedRelationshipNames(in: plan).isEmpty {
            func context(
                for model: any PersistentModel,
                evaluating plan: PredicatePlan,
                depth: Int
            ) throws -> RuntimePredicateEvaluator.Context {
                guard depth <= OSDQueryLimits.maximumNestedCollectionPredicateDepth else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Collection predicates support at most \(OSDQueryLimits.maximumNestedCollectionPredicateDepth) levels."
                    )
                }
                let nestedNames = RuntimePredicateEvaluator.nestedRelationshipNames(in: plan)
                let allNames = RuntimePredicateEvaluator.referencedProperties(in: plan)
                let scalarNames = allNames.filter { name in
                    !nestedNames.contains(name) && !name.contains("[].")
                }
                let values = try runtimeValues(for: model, selecting: scalarNames)
                var relationships: [String: [RuntimePredicateEvaluator.Context]] = [:]
                func collect(_ current: PredicatePlan) throws {
                    switch current {
                    case let .relationshipContains(name, body):
                        guard !name.contains("."),
                            let adapter = containerStorage?.relationshipAdapterTable[
                                ObjectIdentifier(type(of: model))
                            ]?.first(where: { $0.name == name && $0.isToMany })
                        else {
                            throw SwiftDataError.unsupportedPredicate(
                                "Nested collection evaluation requires direct to-many relationships.")
                        }
                        let endpoints = try pendingRelationshipEndpoints(adapter, owner: model)
                        relationships[name] = try endpoints.map {
                            try context(for: $0, evaluating: body, depth: depth + 1)
                        }
                    case let .conjunction(lhs, rhs), let .disjunction(lhs, rhs), let .comparison(_, lhs, rhs),
                        let .decimalComparison(_, lhs, rhs), let .arithmetic(_, lhs, rhs),
                        let .boundedArithmetic(_, lhs, rhs, _),
                        let .floatArithmetic(_, lhs, rhs),
                        let .coalesce(lhs, rhs), let .localizedStandardContains(lhs, rhs),
                        let .stringContains(lhs, rhs), let .stringStartsWith(lhs, rhs):
                        try collect(lhs)
                        try collect(rhs)
                    case let .negation(value), let .stringCount(value), let .unaryNegation(value, _),
                        let .floatNegation(value),
                        let .isNull(value, _):
                        try collect(value)
                    case let .conditional(test, yes, no):
                        try collect(test)
                        try collect(yes)
                        try collect(no)
                    case let .collectionContains(_, _, value), let .collectionAllEqual(_, _, value),
                        let .collectionAllCompare(_, _, _, value):
                        try collect(value)
                    case .collectionAllNil:
                        break
                    case .property, .value, .collectionCount, .codableCollectionIsEmpty, .codableCollectionCount,
                        .codableMember:
                        break
                    }
                }
                try collect(plan)
                return RuntimePredicateEvaluator.Context(values: values, relationships: relationships)
            }
            return try RuntimePredicateEvaluator.matches(
                plan, context: context(for: model, evaluating: plan, depth: 0))
        }
        let propertyNames = RuntimePredicateEvaluator.referencedProperties(in: plan)
        let values = try runtimeValues(for: model, selecting: propertyNames)
        let relationshipProperties = RuntimePredicateEvaluator.relationshipProperties(in: plan)
        var evaluatedValues = values
        var relationshipValues: [String: [[String: RuntimeValue]]] = [:]
        for (name, properties) in relationshipProperties {
            let relationshipPath = name.split(separator: ".").map(String.init)
            if relationshipPath.count > 1 {
                let ownerPath = relationshipPath.dropLast()
                var relationshipOwner: any PersistentModel = model
                var ownerIsMissing = false
                for ownerProperty in ownerPath {
                    guard
                        let relationship = containerStorage?.relationshipAdapterTable[
                            ObjectIdentifier(type(of: relationshipOwner))
                        ]?.first(where: { $0.name == ownerProperty && !$0.isToMany }),
                        relationship.metadata != nil
                    else {
                        ownerIsMissing = true
                        break
                    }
                    let endpoints = try pendingRelationshipEndpoints(relationship, owner: relationshipOwner)
                    guard let endpoint = endpoints.first else {
                        ownerIsMissing = true
                        break
                    }
                    relationshipOwner = endpoint
                }
                if ownerIsMissing {
                    relationshipValues[name] = []
                    continue
                }
                let collectionName = relationshipPath[relationshipPath.count - 1]
                guard
                    let collectionAdapter = containerStorage?.relationshipAdapterTable[
                        ObjectIdentifier(type(of: relationshipOwner))
                    ]?.first(where: { $0.name == collectionName && $0.isToMany })
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Pending nested collection relationship '\(name)' has no typed adapter.")
                }
                guard collectionAdapter.metadata?.inverse == nil else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Pending nested collection predicates with inverse storage are unsupported.")
                }
                let endpoints = collectionAdapter.read(relationshipOwner) ?? []
                relationshipValues[name] = try endpoints.map { endpoint in
                    try runtimeValues(for: endpoint, selecting: properties)
                }
                continue
            }
            guard
                let adapter = containerStorage?.relationshipAdapterTable[ObjectIdentifier(type(of: model))]?
                    .first(where: { $0.name == name })
            else {
                throw SwiftDataError.unsupportedPredicate(
                    "Pending predicate relationship '\(name)' has no typed adapter.")
            }
            if !adapter.isToMany {
                guard adapter.metadata != nil else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Pending to-one predicate relationship '\(name)' cannot be resolved.")
                }
                let endpoints = try pendingRelationshipEndpoints(adapter, owner: model)
                if let endpoint = endpoints.first {
                    let endpointValues = try runtimeValues(for: endpoint, selecting: properties)
                    for property in properties {
                        evaluatedValues["\(name).\(property)"] = endpointValues[property] ?? .null
                    }
                } else {
                    for property in properties { evaluatedValues["\(name).\(property)"] = .null }
                }
                continue
            }
            var endpoints = adapter.read(model) ?? []
            if let metadata = adapter.metadata,
                let inverseName = metadata.inverse,
                let schema = containerStorage?.schema,
                let destination = schema.entity(forName: metadata.destination),
                schema.relationshipDeclaration(named: inverseName, onOrBelow: destination.name) != nil
            {
                if let resolver = try relationshipResolver(),
                    let property = type(of: model).schemaMetadata().first(where: { $0.name == name }),
                    let keyPath = property.keypath
                {
                    let resolvedValue = try resolver.resolve(owner: model, keyPath: keyPath)
                    endpoints = try adapter.endpoints(in: resolvedValue)
                }
                var endpointModels = endpoints.reduce(into: [PersistentIdentifier: any PersistentModel]()) {
                    $0[$1.persistentModelID] = $1
                }
                let destinationIDs = Set(descendantEntityIDs(for: destination))
                for pendingOwner in state.insertedModels + state.changedModels {
                    guard let pendingEntityName = modelEntityName(of: pendingOwner),
                        let pendingEntityID = schema.entityIDsByName[pendingEntityName],
                        destinationIDs.contains(pendingEntityID),
                        let inverseAdapter = relationshipAdapter(for: pendingOwner, property: inverseName)
                    else { continue }
                    let isRelated = (inverseAdapter.read(pendingOwner) ?? []).contains { $0 === model }
                    let identifier = pendingOwner.persistentModelID
                    if isRelated {
                        endpointModels[identifier] = pendingOwner
                    } else {
                        endpointModels.removeValue(forKey: identifier)
                    }
                }
                let ownerID = model.persistentModelID
                for event in state.relationshipMutations
                where event.property == inverseName
                    && event.relationship.inverse == name
                {
                    let containsOwner = event.newEndpointIDs.contains(ownerID)
                    let previouslyContainedOwner = event.oldEndpointIDs.contains(ownerID)
                    let identifier = event.owner.persistentModelID
                    if containsOwner {
                        endpointModels[identifier] = event.owner
                    } else if previouslyContainedOwner {
                        endpointModels.removeValue(forKey: identifier)
                    }
                }
                let deleted = Set(state.deletedModels.map(\.persistentModelID))
                for identifier in deleted { endpointModels.removeValue(forKey: identifier) }
                endpoints = Array(endpointModels.values)
            }
            relationshipValues[name] = try endpoints.map { endpoint in
                try runtimeValues(for: endpoint, selecting: properties)
            }
        }
        return try RuntimePredicateEvaluator.matches(
            plan, values: evaluatedValues, relationshipValues: relationshipValues)
    }

    private func runtimeValues<Model: PersistentModel>(
        for model: Model,
        selecting names: Set<String>? = nil
    ) throws -> [String: RuntimeValue] {
        var values: [String: RuntimeValue] = [:]
        for adapter in Model.erasedPersistenceAdapters() where names == nil || names!.contains(adapter.name) {
            values[adapter.name] = runtimeValue(try adapter.encoded(model))
        }
        for adapter in Model.flattenedPropertyAdapters() where names == nil || names!.contains(adapter.columnName) {
            values[adapter.columnName] = runtimeValue(try adapter.encoded(model))
        }
        if let names {
            for relationship in containerStorage?.relationshipAdapterTable[ObjectIdentifier(type(of: model))] ?? []
            where names.contains(relationship.name) && !relationship.isToMany {
                values[relationship.name] =
                    relationship.read(model)?.first?.persistentModelID.primaryKey
                    .map(RuntimeValue.int) ?? .null
            }
        }
        for name in names ?? [] {
            let components = name.split(separator: ".").map(String.init)
            guard components.count >= 2 else { continue }
            values[name] = try runtimeValue(on: model, path: components, fullPath: name)
        }
        if names?.contains(PredicatePlanProperty.persistentIdentifier) == true {
            values[PredicatePlanProperty.persistentIdentifier] = .blob(
                try model.persistentModelID.predicateIdentityBytes())
        }
        return values
    }

    private func pendingRelationshipEndpoints(
        _ adapter: any AnyRelationshipAdapterBox,
        owner: any PersistentModel
    ) throws -> [any PersistentModel] {
        guard !adapter.isToMany, let metadata = adapter.metadata,
            let inverseName = metadata.inverse,
            let schema = containerStorage?.schema,
            let inverse = schema.relationshipDeclaration(named: inverseName, onOrBelow: metadata.destination),
            !inverse.relationship.isToMany,
            schema.relationshipStorageMapping(
                modelEntityName: modelEntityName(of: owner) ?? "",
                relationshipName: adapter.name) == nil
        else {
            return adapter.read(owner) ?? []
        }
        guard let keyPath = type(of: owner).schemaMetadata().first(where: { $0.name == adapter.name })?.keypath,
            let resolver = try relationshipResolver()
        else {
            throw SwiftDataError.unsupportedPredicate(
                "Pending inverse to-one predicate relationship '\(adapter.name)' cannot be resolved.")
        }
        return try adapter.endpoints(in: resolver.resolve(owner: owner, keyPath: keyPath))
    }

    private func runtimeValue(
        on model: any PersistentModel,
        path: [String],
        fullPath: String
    ) throws -> RuntimeValue {
        guard let first = path.first else { return .null }
        if path.count == 1 {
            if first == PredicatePlanProperty.persistentIdentifier {
                return .blob(try model.persistentModelID.predicateIdentityBytes())
            }
            if let relationship = containerStorage?.relationshipAdapterTable[ObjectIdentifier(type(of: model))]?
                .first(where: { $0.name == first && !$0.isToMany })
            {
                guard let endpoint = try pendingRelationshipEndpoints(relationship, owner: model).first else {
                    return .null
                }
                return .int(endpoint.persistentModelID.primaryKey ?? Int64.min)
            }
            let property = type(of: model).erasedPersistenceAdapters().first(where: { $0.name == first })
            guard let property else {
                throw SwiftDataError.unsupportedPredicate(
                    "Relationship predicate path references unknown property '\(fullPath)'.")
            }
            return runtimeValue(try property.encoded(model))
        }
        guard
            let relationship = containerStorage?.relationshipAdapterTable[ObjectIdentifier(type(of: model))]?
                .first(where: { $0.name == first && !$0.isToMany })
        else {
            throw SwiftDataError.unsupportedPredicate(
                "Nested predicate path '\(fullPath)' requires owning to-one relationships.")
        }
        guard let endpoint = try pendingRelationshipEndpoints(relationship, owner: model).first else { return .null }
        return try runtimeValue(on: endpoint, path: Array(path.dropFirst()), fullPath: fullPath)
    }

    private func modelValues<Model: PersistentModel>(_ model: Model) throws -> [String: StoredValue] {
        var values = try Model.erasedPersistenceAdapters().reduce(into: [String: StoredValue]()) { values, adapter in
            values[adapter.name] = try adapter.encoded(model)
        }
        for adapter in Model.flattenedPropertyAdapters() {
            values[adapter.columnName] = try adapter.encoded(model)
        }
        return values
    }

    private struct RelationshipMutationValue: Equatable {
        let name: String
        let endpoints: [PersistentIdentifier]
    }

    private func relationshipMutationValues<Model: PersistentModel>(_ model: Model) -> [RelationshipMutationValue] {
        (containerStorage?.relationshipAdapterTable[ObjectIdentifier(type(of: model))] ?? [])
            .sorted { $0.name < $1.name }
            .map { adapter in
                RelationshipMutationValue(
                    name: adapter.name,
                    endpoints: (adapter.read(model) ?? []).map(\.persistentModelID))
            }
    }

    private func sortProperties<Model: PersistentModel>(
        _ descriptors: [SortDescriptor<Model>],
        entity: Schema.Entity,
        type: Model.Type
    ) throws -> [String] {
        try descriptors.map { descriptor in
            guard let keyPath = descriptor.keyPath else { throw SwiftDataError.unsupportedSortDescriptor }
            guard
                let property = resolvedPropertyName(
                    keyPath: keyPath, fallback: descriptor.propertyName, entity: entity, type: type),
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
        if let property = type.propertyName(forKeyPath: keyPath),
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

    package func compareSortValues(
        _ lhs: RuntimeValue,
        _ rhs: RuntimeValue,
        isDecimal: Bool = false,
        stringCollation: StringSortCollation = .localizedStandard
    ) -> ComparisonResult {
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
            if isDecimal { return DecimalText.compare(lhs, rhs) }
            return stringCollation.compare(lhs, rhs)
        case let (.blob(lhs), .blob(rhs)):
            if lhs == rhs { return .orderedSame }
            return lhs.lexicographicallyPrecedes(rhs) ? .orderedAscending : .orderedDescending
        default:
            return .orderedSame
        }
    }

    package static func sortCollation(for attribute: Schema.Attribute) -> String? {
        if attribute.options.contains(.codable)
            || attribute.options.contains(where: { if case .transformable = $0 { true } else { false } })
        {
            return nil
        }
        return sortCollation(forType: attribute.type)
    }

    private static func sortCollation(forType typeName: String) -> String? {
        let type = normalizedSortType(typeName)
        if type == "Decimal" { return "OSD_DECIMAL" }
        switch type {
        case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Bool", "Float", "Double", "Date", "UUID", "Data":
            return nil
        case "String":
            return "swiftLocalizedStandardCompare"
        case "URL":
            return "swiftLocalizedStandardCompare"
        default:
            return nil
        }
    }

    private func isDecimalAttribute(_ property: String, in entity: Schema.Entity) -> Bool {
        guard let attribute = entity.attributes.first(where: { $0.name == property }) else { return false }
        return Self.normalizedSortType(attribute.type) == "Decimal"
    }

    private static func normalizedSortType(_ type: String) -> String {
        var unwrapped = type
        while unwrapped.hasSuffix("?") {
            unwrapped.removeLast()
        }
        return unwrapped.split(separator: ".").last.map(String.init) ?? unwrapped
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
        let backing = ManagedBackingData<Model.Model>(
            metadata: Model.schemaMetadata(), values: managedValues, context: self,
            storeIdentifier: storeIdentifier, entityID: try entityID(for: entity.name), primaryKey: primaryKey,
            version: version,
            identifier: PersistentIdentifier(
                storeIdentifier: storeIdentifier, entityName: entity.name, primaryKey: primaryKey))
        let model = Model(backingData: backing)
        let adapters = Model.erasedPersistenceAdapters()
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
                guard type.erasedPersistenceAdapters().contains(where: { $0.name == property.name }) else { return [] }
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
            let scalarAdapters = type.erasedPersistenceAdapters()
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
        let adapters = Model.erasedPersistenceAdapters()
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
                    let mapping = container.schema.relationshipStorageMapping(
                        modelEntityName: entity.name, relationshipName: relationship.name)
                    sideAEntity = mapping?.declaringEntityName ?? entity.name
                    sideBEntity = mapping?.destinationEntityName ?? relationship.destination
                } else if isCanonicalSideA(entity, relationship),
                    let inverseName = relationship.inverse,
                    let inverse = container.schema.relationshipDeclaration(
                        named: inverseName, onOrBelow: relationship.destination),
                    inverse.relationship.isToMany,
                    let joinTable = joinTableName(for: entity, relationship)
                {
                    table = joinTable
                    sideAEntity = entity.name
                    sideBEntity = inverse.entityName
                } else {
                    continue
                }
                if isEntity(model.persistentModelID.entityName, descendantOf: sideAEntity) {
                    try connection.execute("DELETE FROM \(table) WHERE Z_A = ?", arguments: [.int(primaryKey)])
                }
                if isEntity(model.persistentModelID.entityName, descendantOf: sideBEntity) {
                    try connection.execute(
                        "DELETE FROM \(table) WHERE Z_B = ?", arguments: [.int(primaryKey)])
                }
                _ = sideAEntity
            }
        }
        var nulledColumns = Set<String>()
        for ownerEntity in container.schema.entities {
            for relationship in canonicalRelationships(for: ownerEntity) where !relationship.isToMany {
                guard isEntity(model.persistentModelID.entityName, descendantOf: relationship.destination),
                    isToOneStorageOwner(ownerEntity, relationship)
                else { continue }
                if let inverseName = relationship.inverse,
                    let inverse = container.schema.relationship(
                        named: inverseName, onOrBelow: relationship.destination),
                    inverse.deleteRule != .nullify
                {
                    continue
                }
                let storage = relationshipStorageLocation(ownerEntity: ownerEntity, relationship: relationship)
                let columnKey = "\(storage.tableName).\(storage.columnName)"
                guard nulledColumns.insert(columnKey).inserted else { continue }
                try connection.execute(
                    "UPDATE Z\(storage.tableName) SET Z\(storage.columnName) = NULL "
                        + "WHERE Z\(storage.columnName) = ?",
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
            let adapters = optionalContainer?.relationshipAdapterTable[ObjectIdentifier(Model.self)], !adapters.isEmpty
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
                let destinationEntity = optionalContainer?.schema.entity(forName: relationship.destination),
                let inverse = optionalContainer?.schema.relationshipDeclaration(
                    named: inverseName, onOrBelow: relationship.destination),
                inverse.relationship.isToMany
            {
                let storageOwner = relationship.inverse == nil || isCanonicalSideA(entity, relationship)
                let storageEntity =
                    storageOwner
                    ? entity : (optionalContainer?.schema.entity(forName: inverse.entityName) ?? destinationEntity)
                let storageRelationship: Schema.Relationship
                if storageOwner {
                    storageRelationship = relationship
                } else {
                    storageRelationship = inverse.relationship
                }
                guard let table = joinTableName(for: storageEntity, storageRelationship) else { continue }
                let requestedSideIsStorageOwner = joinSideAOwner(entity, relationship)
                destinationType = adapter.destinationType
                rootColumnFirst = true
                let ownerHasHierarchy =
                    entity.superentityName != nil
                    || optionalContainer?.schema.entities.contains(where: { $0.superentityName == entity.name }) == true
                let ownerRoot = rootEntity(for: entity)
                let ownerIDs = ownerHasHierarchy ? descendantEntityIDs(for: entity) : []
                let destinationHasHierarchy =
                    destinationEntity.superentityName != nil
                    || optionalContainer?.schema.entities.contains(where: {
                        $0.superentityName == destinationEntity.name
                    })
                        == true
                let destinationRoot = rootEntity(for: destinationEntity)
                let destinationIDs = destinationHasHierarchy ? descendantEntityIDs(for: destinationEntity) : []
                rows = try store.read { connection in
                    let rootColumn = requestedSideIsStorageOwner ? "Z_A" : "Z_B"
                    let endpointColumn = requestedSideIsStorageOwner ? "Z_B" : "Z_A"
                    let endpointJoin =
                        destinationHasHierarchy
                        ? " JOIN Z\(destinationRoot.name.uppercased()) AS endpoint ON endpoint.Z_PK = joins.\(endpointColumn)"
                        : ""
                    let ownerJoin =
                        ownerHasHierarchy
                        ? " JOIN Z\(ownerRoot.name.uppercased()) AS owner ON owner.Z_PK = joins.\(rootColumn)"
                        : ""
                    let ownerFilter =
                        ownerHasHierarchy
                        ? " AND owner.Z_ENT IN (\(Array(repeating: "?", count: ownerIDs.count).joined(separator: ", ")))"
                        : ""
                    let destinationFilter =
                        destinationHasHierarchy
                        ? " AND endpoint.Z_ENT IN (\(Array(repeating: "?", count: destinationIDs.count).joined(separator: ", ")))"
                        : ""
                    var result: [[RuntimeValue]] = []
                    for batch in primaryKeyBatches {
                        let placeholders = batch.map { _ in "?" }.joined(separator: ", ")
                        result += try connection.rows(
                            "SELECT joins.\(rootColumn), joins.\(endpointColumn) FROM \(table) AS joins"
                                + endpointJoin + ownerJoin + " WHERE joins.\(rootColumn) IN (\(placeholders))"
                                + ownerFilter + destinationFilter
                                + " ORDER BY joins.\(rootColumn) ASC, joins.\(endpointColumn) ASC",
                            arguments: batch.map(RuntimeValue.int) + ownerIDs.map { .int(Int64($0)) }
                                + destinationIDs.map { .int(Int64($0)) })
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
                let destinationEntity = optionalContainer?.schema.entity(forName: relationship.destination),
                let inverseDeclaration = optionalContainer?.schema.relationshipDeclaration(
                    named: inverseName, onOrBelow: relationship.destination),
                !inverseDeclaration.relationship.isToMany
            {
                destinationType = adapter.destinationType
                rootColumnFirst = true
                let inverseRelationship = inverseDeclaration.relationship
                let inverseStorageEntity =
                    optionalContainer?.schema.entity(forName: inverseDeclaration.entityName) ?? destinationEntity
                let storage = relationshipStorageLocation(
                    ownerEntity: inverseStorageEntity, relationship: inverseRelationship)
                let inverseOwnerIDs = descendantEntityIDs(for: inverseStorageEntity)
                let discriminatorFilter =
                    inverseOwnerIDs.isEmpty
                    ? ""
                    : " AND Z_ENT IN (\(Array(repeating: "?", count: inverseOwnerIDs.count).joined(separator: ", ")))"
                rows = try store.read { connection in
                    var result: [[RuntimeValue]] = []
                    for batch in primaryKeyBatches {
                        let placeholders = batch.map { _ in "?" }.joined(separator: ", ")
                        result += try connection.rows(
                            "SELECT Z\(storage.columnName), Z_PK FROM Z\(storage.tableName) "
                                + "WHERE Z\(storage.columnName) IN (\(placeholders))\(discriminatorFilter) "
                                + "ORDER BY Z_PK ASC",
                            arguments: batch.map(RuntimeValue.int) + inverseOwnerIDs.map { .int(Int64($0)) })
                    }
                    return result
                }
            } else if isToOneStorageOwner(entity, relationship) {
                destinationType = adapter.destinationType
                rootColumnFirst = true
                let storage = relationshipStorageLocation(ownerEntity: entity, relationship: relationship)
                rows = try store.read { connection in
                    var result: [[RuntimeValue]] = []
                    for batch in primaryKeyBatches {
                        let placeholders = batch.map { _ in "?" }.joined(separator: ", ")
                        result += try connection.rows(
                            "SELECT Z_PK, Z\(storage.columnName) FROM Z\(storage.tableName) "
                                + "WHERE Z_PK IN (\(placeholders)) ORDER BY Z_PK ASC",
                            arguments: batch.map(RuntimeValue.int))
                    }
                    return result
                }
            } else {
                guard let inverseName = relationship.inverse,
                    let destinationEntity = optionalContainer?.schema.entity(forName: relationship.destination),
                    let inverseDeclaration = optionalContainer?.schema.relationshipDeclaration(
                        named: inverseName, onOrBelow: relationship.destination)
                else { continue }
                destinationType = adapter.destinationType
                rootColumnFirst = true
                let inverseRelationship = inverseDeclaration.relationship
                let inverseStorageEntity =
                    optionalContainer?.schema.entity(forName: inverseDeclaration.entityName) ?? destinationEntity
                let storage = relationshipStorageLocation(
                    ownerEntity: inverseStorageEntity, relationship: inverseRelationship)
                rows = try store.read { connection in
                    var result: [[RuntimeValue]] = []
                    for batch in primaryKeyBatches {
                        let placeholders = batch.map { _ in "?" }.joined(separator: ", ")
                        result += try connection.rows(
                            "SELECT Z\(storage.columnName), Z_PK FROM Z\(storage.tableName) "
                                + "WHERE Z\(storage.columnName) IN (\(placeholders)) ORDER BY Z_PK ASC",
                            arguments: batch.map(RuntimeValue.int))
                    }
                    return result
                }
            }

            let destinationEntity = optionalContainer?.schema.entity(forName: relationship.destination)
            var destinationModels: [Int64: any PersistentModel] = [:]
            if let destinationEntity {
                let destinationHasHierarchy =
                    destinationEntity.superentityName != nil
                    || optionalContainer?.schema.entities.contains(where: {
                        $0.superentityName == destinationEntity.name
                    })
                        == true
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
                        for: identityKey(for: destinationEntity, primaryKey: key),
                        as: destinationType)
                        == nil
                }
                let destinationAttributes =
                    destinationHasHierarchy
                    ? try hierarchyAttributes(for: destinationEntity)
                    : canonicalAttributes(for: destinationEntity)
                let selectedColumns =
                    (["Z_PK", "Z_OPT"] + (destinationHasHierarchy ? ["Z_ENT"] : [])
                    + storedColumnNames(for: destinationAttributes).map { "Z\($0.uppercased())" }).joined(
                        separator: ", ")
                let uncachedBatches = stride(from: 0, to: uncachedKeys.count, by: 100).map { start in
                    Array(uncachedKeys.sorted()[start..<min(start + 100, uncachedKeys.count)])
                }
                var destinationRows: [[RuntimeValue]] = []
                let destinationRoot = rootEntity(for: destinationEntity)
                let destinationEntityIDs = destinationHasHierarchy ? descendantEntityIDs(for: destinationEntity) : []
                for batch in uncachedBatches {
                    let placeholders = batch.map { _ in "?" }.joined(separator: ", ")
                    let discriminatorFilter =
                        destinationHasHierarchy
                        ? " AND Z_ENT IN (\(Array(repeating: "?", count: destinationEntityIDs.count).joined(separator: ", ")))"
                        : ""
                    destinationRows += try store.read { connection in
                        try connection.rows(
                            "SELECT \(selectedColumns) FROM Z\(destinationRoot.name.uppercased()) "
                                + "WHERE Z_PK IN (\(placeholders))\(discriminatorFilter) ORDER BY Z_PK ASC",
                            arguments: batch.map(RuntimeValue.int)
                                + destinationEntityIDs.map { .int(Int64($0)) })
                    }
                }
                for row in destinationRows {
                    guard row.count >= 2, case let .int(primaryKey) = row[0] else { continue }
                    let candidate: any PersistentModel
                    let key: EntityPrimaryKey
                    if destinationHasHierarchy {
                        guard let container = optionalContainer else {
                            throw unsupportedStore("Relationship destination lookup")
                        }
                        guard row.count >= 3, case let .int(rawEntityID) = row[2],
                            let concreteEntityID = Int(exactly: rawEntityID),
                            let registration = container.modelRegistration(forEntityID: concreteEntityID),
                            let concreteEntity = container.schema.entities.first(where: {
                                container.schema.entityIDsByName[$0.name] == concreteEntityID
                            })
                        else { continue }
                        let materializationRow = [row[0], row[1]] + row.dropFirst(3)
                        candidate = try registration.materialize(
                            context: self,
                            entity: concreteEntity,
                            attributes: destinationAttributes,
                            row: materializationRow,
                            storeIdentifier: storeIdentifier,
                            entityID: concreteEntityID,
                            primaryKey: primaryKey,
                            version: runtimeInt(row[1]))
                        if let resolver = try relationshipResolver() {
                            registration.installRelationshipFaults(
                                on: candidate, entity: concreteEntity, resolver: resolver)
                        }
                        key = identityKey(for: concreteEntity, primaryKey: primaryKey)
                    } else {
                        candidate = try materialize(
                            destinationType, entity: destinationEntity, attributes: destinationAttributes, row: row,
                            storeIdentifier: storeIdentifier, primaryKey: primaryKey,
                            version: runtimeInt(row[1]))
                        key = EntityPrimaryKey(entityName: destinationEntity.name, primaryKey: primaryKey)
                    }
                    destinationModels[primaryKey] =
                        identityMap.canonicalHandle(for: key, candidate: candidate)
                        .model
                }
            }

            guard
                let relationshipDestinationEntity = optionalContainer?.schema.entity(forName: relationship.destination)
            else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Relationship destination '\(relationship.destination)' is missing from the schema.")
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
                        for: identityKey(for: relationshipDestinationEntity, primaryKey: destinationPK),
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
        model.anyBackingData.setMaterializedValueIfNoOverlay(forKeyPath: keyPath, to: value)
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
        optionalContainer?.relationshipAdapterTable[ObjectIdentifier(type(of: model))]?.first { $0.name == property }
    }

    private func canonicalRelationships(for entity: Schema.Entity) -> [Schema.Relationship] {
        entity.relationships.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }

    private func isToOneStorageOwner(_ entity: Schema.Entity, _ relationship: Schema.Relationship) -> Bool {
        guard let inverseName = relationship.inverse,
            let inverse = containerStorage?.schema.relationshipDeclaration(
                named: inverseName, onOrBelow: relationship.destination),
            !inverse.relationship.isToMany
        else { return true }
        let current = "\(relationshipLogicalOwnerName(entity, relationship)).\(relationship.name)"
        let other = "\(inverse.entityName).\(inverse.relationship.name)"
        return current.utf8.lexicographicallyPrecedes(other.utf8)
    }

    private func isCanonicalSideA(_ entity: Schema.Entity, _ relationship: Schema.Relationship) -> Bool {
        guard let inverseName = relationship.inverse,
            let inverse = containerStorage?.schema.relationshipDeclaration(
                named: inverseName, onOrBelow: relationship.destination)
        else { return relationship.inverse == nil }
        let current = "\(relationshipLogicalOwnerName(entity, relationship)).\(relationship.name)"
        let other = "\(inverse.entityName).\(inverse.relationship.name)"
        return current.utf8.lexicographicallyPrecedes(other.utf8)
    }

    private func joinSideAOwner(_ entity: Schema.Entity, _ relationship: Schema.Relationship) -> Bool {
        guard let inverseName = relationship.inverse,
            let inverse = containerStorage?.schema.relationshipDeclaration(
                named: inverseName, onOrBelow: relationship.destination)
        else { return relationship.inverse == nil }
        guard inverse.relationship.isToMany else { return false }
        return isCanonicalSideA(entity, relationship)
    }

    private func isToManyStorageOwner(_ entity: Schema.Entity, _ relationship: Schema.Relationship) -> Bool {
        guard let inverseName = relationship.inverse,
            let inverse = containerStorage?.schema.relationshipDeclaration(
                named: inverseName, onOrBelow: relationship.destination)
        else { return true }
        return inverse.relationship.isToMany && !isCanonicalSideA(entity, relationship)
    }

    private func relationshipLogicalOwnerName(_ entity: Schema.Entity, _ relationship: Schema.Relationship) -> String {
        containerStorage?.schema.relationshipStorageMapping(
            modelEntityName: entity.name, relationshipName: relationship.name)?.declaringEntityName ?? entity.name
    }

    private func modelEntityName(of model: any PersistentModel) -> String? {
        String(describing: type(of: model)).split(separator: ".").last.map(String.init)
    }

    private func joinTableName(for entity: Schema.Entity, _ relationship: Schema.Relationship) -> String? {
        guard relationship.isToMany else { return nil }
        let mapping = containerStorage?.schema.relationshipStorageMapping(
            modelEntityName: entity.name, relationshipName: relationship.name)
        let declaringEntityName = mapping?.declaringEntityName ?? entity.name
        let destinationEntityName = mapping?.destinationEntityName ?? relationship.destination
        guard let inverseName = relationship.inverse,
            let inverse = containerStorage?.schema.relationshipDeclaration(
                named: inverseName, onOrBelow: destinationEntityName)
        else {
            guard relationship.inverse == nil else { return nil }
            return
                "Z_\(declaringEntityName.uppercased())_\(relationship.name.uppercased())_\(destinationEntityName.uppercased())"
        }
        guard inverse.relationship.isToMany else { return nil }
        let current = "\(declaringEntityName).\(relationship.name)"
        let other = "\(inverse.entityName).\(inverse.relationship.name)"
        let ordered =
            current.utf8.lexicographicallyPrecedes(other.utf8)
            ? [(declaringEntityName, relationship.name), (inverse.entityName, inverse.relationship.name)]
            : [(inverse.entityName, inverse.relationship.name), (declaringEntityName, relationship.name)]
        return
            "Z_\(ordered[0].0.uppercased())_\(ordered[0].1.uppercased())_\(ordered[1].0.uppercased())_\(ordered[1].1.uppercased())"
    }

    private func relationshipStorageLocation(
        ownerEntity: Schema.Entity, relationship: Schema.Relationship
    ) -> (tableName: String, columnName: String) {
        let mapping = containerStorage?.schema.relationshipStorageMapping(
            modelEntityName: ownerEntity.name, relationshipName: relationship.name)
        return (
            mapping?.ownerRootEntityName.uppercased() ?? ownerEntity.name.uppercased(),
            mapping?.storageColumnName.uppercased() ?? relationship.name.uppercased()
        )
    }

    private func loadRelationshipDestination(
        _ type: any PersistentModel.Type, primaryKey: Int64, store: any RuntimeStore,
        visited: inout Set<EntityPrimaryKey>, materializeRelations: Bool = true
    ) throws -> (any PersistentModel)? {
        func load<Model: PersistentModel>(_ type: Model.Type) throws -> Model? {
            guard let entity = optionalContainer?.schema.entity(forName: String(describing: Model.self)) else {
                return nil
            }
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

    private func entityID(for name: String) throws -> Int {
        guard let identifier = containerStorage?.schema.entityIDsByName[name] else {
            throw SwiftDataError.unsupportedSchemaProperty("Schema has no entity identifier for '\(name)'.")
        }
        return identifier
    }

    private func rootEntity(for entity: Schema.Entity) -> Schema.Entity {
        guard let entities = containerStorage?.schema.entities else { return entity }
        var current = entity
        var visited: Set<String> = []
        while let parentName = current.superentityName,
            visited.insert(current.name).inserted,
            let parent = entities.first(where: { $0.name == parentName })
        {
            current = parent
        }
        return current
    }

    private func descendantEntityIDs(for entity: Schema.Entity) -> [Int] {
        guard let schema = containerStorage?.schema else { return [] }
        return schema.entities.compactMap { candidate in
            var current: Schema.Entity? = candidate
            var visited = Set<String>()
            while let value = current, visited.insert(value.name).inserted {
                if value.name == entity.name { return schema.entityIDsByName[candidate.name] }
                current = value.superentityName.flatMap { parent in
                    schema.entities.first(where: { $0.name == parent })
                }
            }
            return nil
        }.sorted()
    }

    private func isEntity(_ entityName: String, descendantOf ancestorName: String) -> Bool {
        guard let ancestor = containerStorage?.schema.entity(forName: ancestorName),
            let entityID = containerStorage?.schema.entityIDsByName[entityName]
        else { return entityName == ancestorName }
        return descendantEntityIDs(for: ancestor).contains(entityID)
    }

    private func identityKey(for entity: Schema.Entity, primaryKey: Int64) -> EntityPrimaryKey {
        var root = entity
        var visited = Set<String>()
        while let parentName = root.superentityName,
            visited.insert(root.name).inserted,
            let parent = containerStorage?.schema.entity(forName: parentName)
        {
            root = parent
        }
        return EntityPrimaryKey(entityName: root.name, primaryKey: primaryKey)
    }

    private func identityKey(forEntityName entityName: String, primaryKey: Int64) -> EntityPrimaryKey {
        guard let entity = containerStorage?.schema.entity(forName: entityName) else {
            return EntityPrimaryKey(entityName: entityName, primaryKey: primaryKey)
        }
        return identityKey(for: entity, primaryKey: primaryKey)
    }

    /// Returns the names of a model's properties whose current values differ from their saved values.
    private static func changedPropertyNames(of model: any PersistentModel) -> Set<String> {
        let snapshot = model.snapshotLifecycle()
        guard let saved = snapshot.savedValues else { return [] }
        var names = Set<String>()
        for (keyPath, current) in snapshot.values {
            guard let previous = saved[keyPath], !persistenceValuesEqual(current, previous),
                let name = type(of: model).propertyName(forKeyPath: keyPath)
            else { continue }
            names.insert(name)
        }
        return names
    }

    private static func historyKeyLess(_ lhs: StoreEntityKey, _ rhs: StoreEntityKey) -> Bool {
        if lhs.entityName != rhs.entityName { return lhs.entityName < rhs.entityName }
        return lhs.primaryKey < rhs.primaryKey
    }

    private func persistPendingChanges(to store: any RuntimeStore) throws {
        let pending = state.pendingState()
        guard let container = containerStorage else { throw unsupportedStore("Saving") }
        for model in pending.inserted + pending.changed {
            try state.validateRequiredRelationships(for: model)
        }
        let entityIDs = container.schema.entityIDsByName
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
        var historyAttributes: [StoreEntityKey: Set<String>] = [:]
        for model in pending.changed {
            guard let primaryKey = model.persistentModelID.primaryKey else { continue }
            let key = StoreEntityKey(entityName: model.persistentModelID.entityName, primaryKey: primaryKey)
            historyAttributes[key, default: []].formUnion(Self.changedPropertyNames(of: model))
        }
        for event in pending.relationshipMutationEvents {
            if let primaryKey = event.owner.persistentModelID.primaryKey {
                let key = StoreEntityKey(entityName: event.owner.persistentModelID.entityName, primaryKey: primaryKey)
                historyAttributes[key, default: []].insert(event.property)
            }
            guard let inverse = event.relationship.inverse else { continue }
            for endpoint in event.oldEndpoints + event.newEndpoints {
                guard let primaryKey = endpoint.persistentModelID.primaryKey else { continue }
                let key = StoreEntityKey(entityName: endpoint.persistentModelID.entityName, primaryKey: primaryKey)
                historyAttributes[key, default: []].insert(inverse)
            }
        }
        // Assigning a property its current value is not a change, so it records no history.
        updatedKeys = updatedKeys.filter { !(historyAttributes[$0]?.isEmpty ?? true) }
        var tombstones: [StoreEntityKey: [String: StoredValue]] = [:]
        for model in pending.deleted {
            guard let primaryKey = model.persistentModelID.primaryKey,
                let entity = container.schema.entity(forName: model.persistentModelID.entityName)
            else { continue }
            let preserved = Set(
                entity.attributes.filter { $0.options.contains(.preserveValueOnDeletion) }.map(\.name))
            guard !preserved.isEmpty else { continue }
            var values: [String: StoredValue] = [:]
            for adapter in type(of: model).erasedPersistenceAdapters() where preserved.contains(adapter.name) {
                values[adapter.name] = try adapter.encoded(model)
            }
            tombstones[StoreEntityKey(entityName: model.persistentModelID.entityName, primaryKey: primaryKey)] =
                values
        }
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
                    let storage = relationshipStorageLocation(ownerEntity: entity, relationship: relationship)
                    try connection.execute(
                        "UPDATE Z\(storage.tableName) SET Z\(storage.columnName) = ? WHERE Z_PK = ?",
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
                let storage = relationshipStorageLocation(ownerEntity: entity, relationship: event.relationship)
                try connection.execute(
                    "UPDATE Z\(storage.tableName) SET Z\(storage.columnName) = ? WHERE Z_PK = ?",
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
                // A merged duplicate's identifier has no stored row, so deleting it leaves the store unchanged.
                guard let pk = model.persistentModelID.primaryKey,
                    !mergedDuplicateIdentifiers.contains(model.persistentModelID)
                else { continue }
                guard let entity = container.schema.entity(forName: model.persistentModelID.entityName) else {
                    throw SwiftDataError.unsupportedStore(
                        "No schema entity exists for deleted model '\(model.persistentModelID.entityName)'.")
                }
                try connection.execute(
                    "DELETE FROM Z\(rootEntity(for: entity).name.uppercased()) WHERE Z_PK = ?",
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
                    RuntimeHistoryChange(
                        type: type, entityName: key.entityName, primaryKey: key.primaryKey,
                        updatedAttributes: type == .update ? (historyAttributes[key] ?? []).sorted() : [],
                        tombstone: type == .delete ? tombstones[key] ?? [:] : [:]))
            }
            if !historyChanges.isEmpty {
                try connection.recordHistory(historyChanges, timestamp: Date(), author: historyAuthorStorage)
            }
            return results
        }
        for model in pending.deleted {
            if let pk = model.persistentModelID.primaryKey {
                identityMap.remove(
                    identityKey(
                        forEntityName: model.persistentModelID.entityName,
                        primaryKey: pk))
            }
            state.removeBaseline(for: model)
            model.detachDeletedLifecycle()
        }
        for result in persisted {
            let model = result.model
            let entityName = result.entityName
            let originalIdentifier = state.snapshotIdentifier(for: model)
            if result.mergedIntoExistingRow {
                // SwiftData keeps the existing row's registered instance, refreshed with the merged values, and
                // leaves the conflicting model attached without changes and without a row.
                if let replacedModel = result.replacedModel {
                    let merged = model.snapshotLifecycle()
                    let existing = replacedModel.snapshotLifecycle()
                    replacedModel.restoreLifecycle(
                        BackingDataSnapshot(
                            values: existing.values.merging(merged.values) { _, new in new },
                            context: existing.context, identifier: existing.identifier, isDeleted: false,
                            hasChanges: false, savedValues: nil, primaryKey: existing.primaryKey,
                            entityID: existing.entityID, optimisticLockVersion: existing.optimisticLockVersion))
                    replacedModel.markPersistedLifecycle(
                        storeIdentifier: storeIdentifier, entityName: entityName,
                        entityID: try entityID(for: entityName), primaryKey: result.primaryKey,
                        version: result.version)
                    state.setBaseline(replacedModel, snapshot: replacedModel.snapshotLifecycle())
                }
                if let ghostPrimaryKey = result.mergedDuplicatePrimaryKey {
                    model.markPersistedLifecycle(
                        storeIdentifier: storeIdentifier, entityName: entityName,
                        entityID: try entityID(for: entityName), primaryKey: ghostPrimaryKey, version: 1)
                    mergedDuplicateIdentifiers.insert(model.persistentModelID)
                    identityMap.register(
                        model, for: identityKey(forEntityName: entityName, primaryKey: ghostPrimaryKey))
                    if let old = originalIdentifier, old.isTemporary {
                        temporaryIdentifiers[old] = model.persistentModelID
                    }
                }
                model.markSavedLifecycle()
                state.setBaseline(model, snapshot: model.snapshotLifecycle())
                continue
            }
            if let replacedModel = result.replacedModel {
                identityMap.remove(identityKey(forEntityName: entityName, primaryKey: result.primaryKey))
                detachModel(replacedModel)
            }
            model.markPersistedLifecycle(
                storeIdentifier: storeIdentifier, entityName: entityName, entityID: try entityID(for: entityName),
                primaryKey: result.primaryKey, version: result.version)
            state.setBaseline(model, snapshot: model.snapshotLifecycle())
            identityMap.register(
                model, for: identityKey(forEntityName: entityName, primaryKey: result.primaryKey))
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

    private func persistPendingChanges(to dataStore: any DataStore) throws {
        let pending = state.pendingState()
        guard let container = containerStorage else { throw unsupportedStore("Saving") }
        for model in pending.inserted + pending.changed {
            try state.validateRequiredRelationships(for: model)
        }
        let insertedOriginal = try pending.inserted.map { try dataStoreSnapshot(for: $0, container: container) }
        let updated = try pending.changed.map { try dataStoreSnapshot(for: $0, container: container) }
        let deleted = pending.deleted.map(\.persistentModelID)
        var normalizedIdentifiers: [PersistentIdentifier: PersistentIdentifier] = [:]
        var normalizedByObject: [ObjectIdentifier: PersistentIdentifier] = [:]
        for model in pending.inserted {
            let current = model.persistentModelID
            let concreteEntityName =
                String(describing: type(of: model)).split(separator: ".").last.map(String.init)
                ?? String(describing: type(of: model))
            let old = pending.snapshots[ObjectIdentifier(model)]?.1.identifier
            let objectID = ObjectIdentifier(model)
            let original = dataStoreOriginalIdentifiers[objectID] ?? current
            dataStoreOriginalIdentifiers[objectID] = original
            let normalized =
                dataStoreTemporaryIdentifiers[objectID]
                ?? PersistentIdentifier(
                    storeIdentifier: dataStore.identifier,
                    entityName: concreteEntityName,
                    temporaryIdentifier: original.temporaryIdentifier ?? old?.temporaryIdentifier ?? UUID())
            dataStoreTemporaryIdentifiers[objectID] = normalized
            normalizedByObject[objectID] = normalized
            normalizedIdentifiers[current] = normalized
            normalizedIdentifiers[original] = normalized
            if let old { normalizedIdentifiers[old] = normalized }
        }
        let inserted = zip(pending.inserted, insertedOriginal).map { model, snapshot in
            let identifier = normalizedByObject[ObjectIdentifier(model)] ?? snapshot.persistentIdentifier
            return DataStoreSnapshot(
                persistentIdentifier: identifier,
                entityName: snapshot.entityName,
                values: snapshot.values,
                relationships: snapshot.relationships.mapValues { endpoints in
                    endpoints.map { normalizedIdentifiers[$0] ?? $0 }
                })
        }
        guard
            (inserted + updated).allSatisfy({
                $0.persistentIdentifier.resolvedStoreIdentifier == dataStore.identifier
                    && container.schema.entity(forName: $0.entityName) != nil
            }), deleted.allSatisfy({ $0.resolvedStoreIdentifier == dataStore.identifier })
        else {
            throw SwiftDataError.unsupportedStore("DataStore save request contains identifiers from another store.")
        }
        let reservations = try dataStore.reserveIdentifiers(for: inserted)
        let insertedIdentifiers = Set(inserted.map(\.persistentIdentifier))
        let reservationKeysAreValid = Set(reservations.keys).isSubset(of: insertedIdentifiers)
        let reservationValuesAreUnique = Set(reservations.values).count == reservations.count
        let reservationValidity = reservations.map { source, destination in
            (
                source.isTemporary,
                !destination.isTemporary,
                source.entityName == destination.entityName,
                destination.resolvedStoreIdentifier == dataStore.identifier,
                !insertedIdentifiers.contains(destination)
            )
        }
        let reservationsAreValid = reservationValidity.allSatisfy { $0.0 && $0.1 && $0.2 && $0.3 && $0.4 }
        guard reservationKeysAreValid, reservationValuesAreUnique, reservationsAreValid
        else {
            throw SwiftDataError.unsupportedStore(
                "DataStore returned invalid identifier reservations (keys: \(reservationKeysAreValid), "
                    + "unique: \(reservationValuesAreUnique), valid: \(reservationsAreValid), "
                    + "entries: \(reservationValidity)).")
        }
        let remapRelationships: (DataStoreSnapshot) -> DataStoreSnapshot = { snapshot in
            DataStoreSnapshot(
                persistentIdentifier: snapshot.persistentIdentifier,
                entityName: snapshot.entityName,
                values: snapshot.values,
                relationships: snapshot.relationships.mapValues { endpoints in
                    endpoints.map { identifier in
                        reservations[normalizedIdentifiers[identifier] ?? identifier]
                            ?? normalizedIdentifiers[identifier] ?? identifier
                    }
                })
        }
        let saveRequest = DataStoreSaveRequest(
            inserted: inserted.map { snapshot in
                let relationshipSnapshot = remapRelationships(snapshot)
                let identifier = reservations[snapshot.persistentIdentifier] ?? snapshot.persistentIdentifier
                return DataStoreSnapshot(
                    persistentIdentifier: identifier,
                    entityName: relationshipSnapshot.entityName,
                    values: relationshipSnapshot.values,
                    relationships: relationshipSnapshot.relationships)
            },
            updated: updated.map(remapRelationships),
            deleted: deleted)
        let result = try dataStore.save(saveRequest)

        let updatedIdentifiers = Set(updated.map(\.persistentIdentifier))
        let deletedIdentifiers = Set(deleted)
        let remappedIdentifiers = Array(result.identifierRemappings.values)
        let requiredSaveMappings = insertedIdentifiers.subtracting(reservations.keys)
        let mappingsCoverInserts = Set(result.identifierRemappings.keys) == requiredSaveMappings
        let updatesAcknowledged = result.updatedIdentifiers == updatedIdentifiers
        let deletionsAcknowledged = result.deletedIdentifiers == deletedIdentifiers
        let allPermanentIdentifiers = Array(reservations.values) + remappedIdentifiers
        let mappingsAreUnique = Set(allPermanentIdentifiers).count == allPermanentIdentifiers.count
        let mappingsAreValid = result.identifierRemappings.allSatisfy({ source, destination in
            source.isTemporary && !destination.isTemporary
                && source.resolvedStoreIdentifier == dataStore.identifier
                && source.entityName == destination.entityName
                && destination.resolvedStoreIdentifier == dataStore.identifier
        })
        guard mappingsCoverInserts, updatesAcknowledged, deletionsAcknowledged, mappingsAreUnique,
            mappingsAreValid
        else {
            throw SwiftDataError.unsupportedStore(
                "DataStore returned an invalid save result (insert mappings: \(mappingsCoverInserts), "
                    + "updates: \(updatesAcknowledged), deletes: \(deletionsAcknowledged), "
                    + "unique IDs: \(mappingsAreUnique), valid mappings: \(mappingsAreValid), "
                    + "reserved IDs: \(reservations.count)); invalid results must not commit changes.")
        }

        var insertedKeys = Set<StoreEntityKey>()
        let insertedIDs = Set(pending.inserted.map(ObjectIdentifier.init))
        for model in pending.inserted + pending.changed {
            let originalIdentifier = model.persistentModelID
            let requestIdentifier = normalizedIdentifiers[originalIdentifier] ?? originalIdentifier
            let isInserted = insertedIDs.contains(ObjectIdentifier(model))
            guard
                let identifier = reservations[requestIdentifier]
                    ?? result.identifierRemappings[requestIdentifier]
                    ?? (isInserted ? nil : originalIdentifier),
                let primaryKey = identifier.primaryKey
            else {
                throw SwiftDataError.unsupportedStore("DataStore save did not return a permanent model identifier.")
            }
            if isInserted || reservations[requestIdentifier] != nil
                || result.identifierRemappings[requestIdentifier] != nil
            {
                model.markPersistedLifecycle(
                    storeIdentifier: identifier.resolvedStoreIdentifier, entityName: identifier.entityName,
                    entityID: try entityID(for: identifier.entityName),
                    primaryKey: primaryKey, version: 1)
            } else {
                model.markSavedLifecycle()
            }
            let key = StoreEntityKey(entityName: identifier.entityName, primaryKey: primaryKey)
            if isInserted { insertedKeys.insert(key) }
            identityMap.register(
                model, for: identityKey(forEntityName: key.entityName, primaryKey: key.primaryKey))
            state.setBaseline(model, snapshot: model.snapshotLifecycle())
            if isInserted {
                let objectID = ObjectIdentifier(model)
                let aliases = [
                    originalIdentifier,
                    pending.snapshots[objectID]?.1.identifier,
                    dataStoreOriginalIdentifiers[objectID],
                    dataStoreTemporaryIdentifiers[objectID],
                ].compactMap { $0 }
                for alias in aliases where alias.isTemporary {
                    temporaryIdentifiers[alias] = identifier
                }
            }
            if originalIdentifier.isTemporary {
                temporaryIdentifiers[originalIdentifier] = identifier
            }
        }
        for model in pending.deleted {
            if let primaryKey = model.persistentModelID.primaryKey {
                identityMap.remove(
                    identityKey(
                        forEntityName: model.persistentModelID.entityName,
                        primaryKey: primaryKey))
            }
            state.removeBaseline(for: model)
            model.detachDeletedLifecycle()
        }
        for model in pending.inserted {
            clearDataStoreTemporaryIdentifiers(for: model)
        }
        finalizePendingChanges()
        state.clearRelationshipMutationEvents()
        if let storeHubStoreIdentifier {
            let updated = Set(
                pending.changed.compactMap { model -> StoreEntityKey? in
                    guard let primaryKey = model.persistentModelID.primaryKey else { return nil }
                    return StoreEntityKey(entityName: model.persistentModelID.entityName, primaryKey: primaryKey)
                }
            ).subtracting(insertedKeys)
            let deleted = Set(
                pending.deleted.compactMap { model -> StoreEntityKey? in
                    guard let primaryKey = model.persistentModelID.primaryKey else { return nil }
                    return StoreEntityKey(entityName: model.persistentModelID.entityName, primaryKey: primaryKey)
                })
            storeHub?.publish(
                storeIdentifier: storeHubStoreIdentifier,
                sourceSubscription: storeHubSubscription ?? UUID(),
                inserted: insertedKeys, updated: updated, deleted: deleted)
        }
    }

    private func clearDataStoreTemporaryIdentifiers(for model: any PersistentModel) {
        let objectID = ObjectIdentifier(model)
        dataStoreTemporaryIdentifiers.removeValue(forKey: objectID)
        dataStoreOriginalIdentifiers.removeValue(forKey: objectID)
    }

    private func dataStoreSnapshot(
        for model: any PersistentModel, container: ModelContainer
    ) throws -> DataStoreSnapshot {
        func typed<Model: PersistentModel>(_ model: Model) throws -> DataStoreSnapshot {
            let entityName = String(describing: Model.self)
            guard let entity = container.schema.entity(forName: entityName) else {
                throw SwiftDataError.unsupportedStore("DataStore model is not present in the container schema.")
            }
            var values: [String: StoredValue] = [:]
            let flattened = Model.flattenedPropertyAdapters()
            for attribute in entity.attributes {
                if attribute.options.contains(.flattened) {
                    let components = flattened.filter { $0.propertyName == attribute.name }
                    guard components.count == attribute.components.count else {
                        throw SwiftDataError.unsupportedStore(
                            "DataStore flattened component adapters do not match \(entity.name).\(attribute.name).")
                    }
                    for component in components {
                        values[component.columnName] = try component.encoded(model)
                    }
                } else {
                    guard let adapter = Model.erasedPersistenceAdapters().first(where: { $0.name == attribute.name })
                    else {
                        throw SwiftDataError.unsupportedStore(
                            "DataStore has no encoder for \(entity.name).\(attribute.name).")
                    }
                    values[attribute.name] = try adapter.encoded(model)
                }
            }
            let relationshipAdapters: [any AnyRelationshipAdapterBox]
            if let modelType = Model.self as? any RelationshipModel.Type {
                relationshipAdapters =
                    modelType.relationshipAdapterCandidates()
                    + modelType.inferredRelationshipAdapterCandidates()
            } else {
                relationshipAdapters = []
            }
            var relationships: [String: [PersistentIdentifier]] = [:]
            for relationship in entity.relationships {
                guard let adapter = relationshipAdapters.first(where: { $0.name == relationship.name }) else {
                    throw SwiftDataError.unsupportedStore(
                        "DataStore has no relationship adapter for \(entity.name).\(relationship.name).")
                }
                relationships[relationship.name] = adapter.read(model)?.map(\.persistentModelID) ?? []
            }
            return DataStoreSnapshot(
                persistentIdentifier: model.persistentModelID,
                entityName: entity.name,
                values: values, relationships: relationships)
        }
        func dispatch<Model: PersistentModel>(_ model: Model) throws -> DataStoreSnapshot { try typed(model) }
        return try dispatch(model)
    }

    private func persistModel(
        _ model: any PersistentModel, inserted: Bool, connection: any RuntimeConnection,
        snapshot: BackingDataSnapshot, container: ModelContainer, entityIDs: [String: Int],
        append: inout [PersistedModel], externalDataColumns: Set<String>,
        externalDataSession: ExternalDataWriteSession
    ) throws {
        func typed<Model: PersistentModel>(_ model: Model) throws {
            guard let entity = container.schema.entity(forName: String(describing: Model.self)) else { return }
            let adapters = Model.erasedPersistenceAdapters()
            let flattenedAdapters = Dictionary(grouping: Model.flattenedPropertyAdapters(), by: \.propertyName)
                .mapValues { $0.sorted { $0.componentName.utf8.lexicographicallyPrecedes($1.componentName.utf8) } }
            var columns: [String] = []
            var values: [RuntimeValue] = []
            let savedValues = snapshot.savedValues
            let metadata = Model.schemaMetadata()
            // Current values of unchanged scalar attributes, used to detect unique-constraint conflicts on update.
            var unchangedColumns: [String] = []
            var unchangedValues: [RuntimeValue] = []
            for attribute in canonicalAttributes(for: entity) {
                let flattened = attribute.options.contains(.flattened)
                guard let keyPath = metadata.first(where: { $0.name == attribute.name })?.keypath else { continue }
                if !inserted {
                    guard let current = snapshot.values[keyPath],
                        let saved = savedValues?[keyPath], !Self.persistenceValuesEqual(current, saved)
                    else {
                        if !flattened, !attribute.options.contains(.externalStorage),
                            let adapter = adapters.first(where: { $0.name == attribute.name })
                        {
                            unchangedColumns.append("Z\(attribute.name.uppercased())")
                            unchangedValues.append(runtimeValue(try adapter.encoded(model)))
                        }
                        continue
                    }
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
                let storage = relationshipStorageLocation(ownerEntity: entity, relationship: relationship)
                columns.append("Z\(storage.columnName)")
                values.append(
                    relationshipAdapter.read(model)?.first?.persistentModelID.primaryKey
                        .map(RuntimeValue.int) ?? .null)
            }
            let table = "Z\(rootEntity(for: entity).name.uppercased())"
            if inserted {
                let preservedPrimaryKey = snapshot.primaryKey
                if preservedPrimaryKey == nil,
                    let match = try uniqueMatch(
                        entity: entity, columns: columns, values: values, connection: connection)
                {
                    let assignments = columns.map { "\($0) = ?" }.joined(separator: ", ")
                    let version = match.version + 1
                    let hasDiscriminator = entityIDs[entity.name] != nil
                    let discriminatorAssignment = hasDiscriminator ? "Z_ENT = ?, " : ""
                    let updateValues = hasDiscriminator ? [.int(Int64(entityIDs[entity.name]!))] + values : values
                    let setClause =
                        discriminatorAssignment
                        + (columns.isEmpty ? "" : assignments + ", ") + "Z_OPT = ?"
                    try connection.execute(
                        "UPDATE \(table) SET \(setClause) WHERE Z_PK = ? AND Z_OPT = ?",
                        arguments: updateValues + [
                            .int(Int64(version)), .int(match.primaryKey), .int(Int64(match.version)),
                        ])
                    guard connection.changesCount() == 1 else { throw SwiftDataError.optimisticLockConflict }
                    let rootKey = identityKey(for: entity, primaryKey: match.primaryKey)
                    let replaced = identityMap.liveModels().first(where: { $0.0 == rootKey })?.1
                    // A registered instance of another subclass cannot represent the merged row, so the
                    // conflicting model takes over the row instead.
                    let mergedIntoExistingRow = replaced.map { type(of: $0) == Model.self } ?? true
                    // SwiftData assigns the merged model a permanent identifier that no stored row uses.
                    let mergedDuplicatePrimaryKey =
                        mergedIntoExistingRow ? try Self.allocatePrimaryKey(table: table, connection: connection) : nil
                    append.append(
                        PersistedModel(
                            model: model, entityName: entity.name, primaryKey: match.primaryKey, version: version,
                            replacedModel: replaced === model ? nil : replaced,
                            mergedIntoExistingRow: mergedIntoExistingRow,
                            mergedDuplicatePrimaryKey: mergedDuplicatePrimaryKey))
                    return
                }
                let primaryKey =
                    try preservedPrimaryKey ?? Self.allocatePrimaryKey(table: table, connection: connection)
                let names = (["Z_PK", "Z_ENT", "Z_OPT"] + columns).joined(separator: ", ")
                let placeholders = Array(repeating: "?", count: columns.count + 3).joined(separator: ", ")
                let identityValues: [RuntimeValue] = [
                    .int(primaryKey), .int(Int64(entityIDs[entity.name] ?? 1)), .int(1),
                ]
                try connection.execute(
                    "INSERT INTO \(table) (\(names)) VALUES (\(placeholders))",
                    arguments: identityValues + values)
                append.append(
                    PersistedModel(
                        model: model, entityName: entity.name, primaryKey: primaryKey, version: 1,
                        replacedModel: nil))
            } else if let pk = model.persistentModelID.primaryKey,
                !mergedDuplicateIdentifiers.contains(model.persistentModelID)
            {
                let expectedVersion = snapshot.optimisticLockVersion
                if !columns.isEmpty,
                    let match = try uniqueMatch(
                        entity: entity, columns: columns + unchangedColumns, values: values + unchangedValues,
                        connection: connection),
                    match.primaryKey != pk
                {
                    // SwiftData resolves the conflict by applying the changed values to the existing row and
                    // removing this model's row. Rows that referenced the removed row are not rewritten.
                    let assignments = columns.map { "\($0) = ?" }.joined(separator: ", ")
                    try connection.execute(
                        "UPDATE \(table) SET \(assignments), Z_OPT = ? WHERE Z_PK = ?",
                        arguments: values + [.int(Int64(match.version + 1)), .int(match.primaryKey)])
                    try connection.execute("DELETE FROM \(table) WHERE Z_PK = ?", arguments: [.int(pk)])
                    append.append(
                        PersistedModel(
                            model: model, entityName: entity.name, primaryKey: pk, version: expectedVersion,
                            replacedModel: nil, mergedIntoExistingRow: true))
                    return
                }
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
                append.append(
                    PersistedModel(
                        model: model, entityName: entity.name, primaryKey: pk, version: version, replacedModel: nil))
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
        let storageEntity = rootEntity(for: entity)
        var ancestors: [Schema.Entity] = []
        var current: Schema.Entity? = entity
        var visited = Set<String>()
        while let value = current, visited.insert(value.name).inserted {
            ancestors.append(value)
            current = value.superentityName.flatMap { containerStorage?.schema.entity(forName: $0) }
        }
        let orderedAncestors = ancestors.reversed()
        var constraints: [(properties: [String], owner: Schema.Entity)] = []
        var ancestorAttributes = Set<String>()
        var ancestorIndexes = Set<Schema.Index>()
        for owner in orderedAncestors {
            for attribute in owner.attributes
            where attribute.options.contains(.unique) && !ancestorAttributes.contains(attribute.name) {
                constraints.append(([attribute.name], owner))
            }
            for index in owner.indexes where index.isUnique && !ancestorIndexes.contains(index) {
                constraints.append((index.properties, owner))
            }
            ancestorAttributes.formUnion(owner.attributes.map(\.name))
            ancestorIndexes.formUnion(owner.indexes)
        }
        var seenConstraints = Set<String>()
        constraints = constraints.filter { constraint in
            let key = constraint.owner.name + ":" + constraint.properties.joined(separator: "\u{0}")
            return seenConstraints.insert(key).inserted
        }
        var match: (primaryKey: Int64, version: Int)?
        for constraint in constraints {
            let properties = constraint.properties
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
            let scopeIDs =
                constraint.owner.superentityName == nil
                ? [] : descendantEntityIDs(for: constraint.owner)
            if !scopeIDs.isEmpty {
                predicates.append("Z_ENT IN (\(Array(repeating: "?", count: scopeIDs.count).joined(separator: ", ")))")
                arguments.append(contentsOf: scopeIDs.map { .int(Int64($0)) })
            }
            let sql =
                "SELECT Z_PK, Z_OPT FROM Z\(storageEntity.name.uppercased()) WHERE \(predicates.joined(separator: " AND ")) ORDER BY Z_PK LIMIT 1"
            let rows = try connection.rows(sql, arguments: arguments)
            if let row = rows.first, row.count >= 2 {
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

    /// Returns a primary key for a new row that no earlier row of the table has used.
    ///
    /// Keys only increase, even after rows are deleted, so identifiers of deleted models never match new ones.
    /// The high-water mark lives in `_osd_primary_keys`, which is created on first use.
    private static func allocatePrimaryKey(table: String, connection: any RuntimeConnection) throws -> Int64 {
        try connection.execute(
            "CREATE TABLE IF NOT EXISTS _osd_primary_keys (table_name TEXT PRIMARY KEY, last_key INTEGER NOT NULL)",
            arguments: [])
        let stored = try connection.rows(
            "SELECT last_key FROM _osd_primary_keys WHERE table_name = ?", arguments: [.text(table)])
        let existing = try connection.rows("SELECT MAX(Z_PK) FROM \(table)", arguments: [])
        var last: Int64 = 0
        if case let .int(value)? = stored.first?.first { last = value }
        if case let .int(value)? = existing.first?.first { last = max(last, value) }
        let next = last + 1
        try connection.execute(
            "INSERT INTO _osd_primary_keys (table_name, last_key) VALUES (?, ?) "
                + "ON CONFLICT(table_name) DO UPDATE SET last_key = excluded.last_key",
            arguments: [.text(table), .int(next)])
        return next
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
                    let inverse = container.schema.relationshipDeclaration(
                        named: inverseName, onOrBelow: relationship.destination),
                    let destination = container.schema.entity(forName: inverse.entityName)
                else { continue }
                tableEntity = destination
                tableRelationship = inverse.relationship
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
                guard let endpointEntityName = modelEntityName(of: endpoint),
                    let endpointEntity = container.schema.entity(forName: endpointEntityName),
                    let destinationEntity = container.schema.entity(forName: relationship.destination),
                    let endpointEntityID = container.schema.entityIDsByName[endpointEntity.name],
                    descendantEntityIDs(for: destinationEntity).contains(endpointEntityID)
                else {
                    throw SwiftDataError.unsupportedStore(
                        "Relationship '\(entity.name).\(relationship.name)' received endpoint type "
                            + "'\(String(describing: type(of: endpoint)))' instead of '\(relationship.destination)'.")
                }
                let pair = sideA ? (ownerPK, endpointPK) : (endpointPK, ownerPK)
                pairs[table, default: [:]]["\(pair.0):\(pair.1)"] = pair
            }
        }

        for (entity, relationship, ownerPK, endpointPK) in toOneValues.values {
            let storage = relationshipStorageLocation(ownerEntity: entity, relationship: relationship)
            try connection.execute(
                "UPDATE Z\(storage.tableName) SET Z\(storage.columnName) = ? WHERE Z_PK = ?",
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
            if let entity = optionalContainer?.schema.entity(forName: String(describing: type(of: model))),
                let adapters = optionalContainer?.relationshipAdapterTable[ObjectIdentifier(type(of: model))]
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
        for (rank, entity) in (optionalContainer?.schema.entities ?? []).enumerated() {
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

    @discardableResult
    private func rollbackCurrentTransaction(expectedFrameID: UUID? = nil) -> Bool {
        assertAffinity()
        let frame: ContextState.TransactionFrame?
        if let expectedFrameID {
            frame = state.popTransactionSnapshot(id: expectedFrameID)
        } else {
            frame = state.popTransactionSnapshot()
        }
        guard let frame else { return false }
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
        for model in currentModels
        where state.contains(model, in: pending.inserted)
            && !state.contains(model, in: frame.pending.inserted)
        {
            clearDataStoreTemporaryIdentifiers(for: model)
        }
        state.restorePendingState(frame.pending)
        state.restoreBaselineSnapshots(frame.baselineSnapshots)
        return true
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
        undoRegisteredModels.removeAll()
        currentUndoGroup = nil
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
