import Foundation

package final class ContextState: @unchecked Sendable {
    struct PendingState {
        var inserted: [any PersistentModel]
        var changed: [any PersistentModel]
        var deleted: [any PersistentModel]
        var snapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)]
        var relationshipMutationEvents: [RelationshipMutationEvent]
    }

    struct TransactionFrame {
        var pending: PendingState
        var snapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)]
        var baselineSnapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)]
        var modelSnapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)]
    }

    package struct RelationshipMutationEvent {
        package let owner: any PersistentModel
        package let property: String
        package let relationship: Schema.Relationship
        package let oldEndpointIDs: [PersistentIdentifier]
        package let oldEndpoints: [any PersistentModel]
        package let newEndpointIDs: [PersistentIdentifier]
        package let newEndpoints: [any PersistentModel]
    }

    private let lock = NSRecursiveLock()
    private let relationshipAdaptersByModel: [ObjectIdentifier: [any AnyRelationshipAdapterBox]]
    private var inserted: [any PersistentModel] = []
    private var changed: [any PersistentModel] = []
    private var deleted: [any PersistentModel] = []
    private var snapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)] = [:]
    private var baselineSnapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)] = [:]
    private var transactionFrames: [TransactionFrame] = []
    private var relationshipMutationEvents: [RelationshipMutationEvent] = []

    init(
        relationshipAdaptersByModel: [ObjectIdentifier: [any AnyRelationshipAdapterBox]] = [:]
    ) {
        self.relationshipAdaptersByModel = relationshipAdaptersByModel
    }

    var insertedModels: [any PersistentModel] { locked { inserted } }
    var changedModels: [any PersistentModel] { locked { changed } }
    var deletedModels: [any PersistentModel] { locked { deleted } }
    var hasChanges: Bool {
        locked { !inserted.isEmpty || !changed.isEmpty || !deleted.isEmpty || !relationshipMutationEvents.isEmpty }
    }
    var hasTransaction: Bool { locked { !transactionFrames.isEmpty } }
    var transactionDepth: Int { locked { transactionFrames.count } }
    package var relationshipMutations: [RelationshipMutationEvent] { locked { relationshipMutationEvents } }
    func withExclusiveOperation<T>(_ body: () throws -> T) rethrows -> T {
        try locked(body)
    }

    func mutateRelationship<Model: PersistentModel, Value>(
        model: Model,
        keyPath: KeyPath<Model, Value>,
        value: Value,
        adapters: [any AnyRelationshipAdapterBox]
    ) -> Bool {
        let matches = adapters.filter {
            $0.ownerType == ObjectIdentifier(Model.self) && $0.keyPath == keyPath
        }
        guard matches.count == 1, let adapter = matches.first else { return false }
        _ = adapter.mutate(value, on: model, keyPath: keyPath) { owner, box, input in
            try self.mutateRelationship(owner: owner as! Model, adapter: box, value: input)
        }
        return true
    }

    func setRelationship<Model: PersistentModel, Value>(
        model: Model,
        keyPath: KeyPath<Model, Value>,
        value: Value,
        autoInsertDestinations: Bool = false
    ) -> Bool {
        guard let adapter = relationshipAdapters(for: Model.self).first(where: { $0.keyPath == keyPath }) else {
            return false
        }
        do {
            if autoInsertDestinations {
                try insertDestinations(in: value, owner: model, adapter: adapter) {
                    try self.mutateRelationship(
                        owner: $0, adapter: adapter, value: value)
                }
            } else {
                try mutateRelationship(owner: model, adapter: adapter, value: value)
            }
        } catch {
            return true
        }
        return true
    }

    private func insertDestinations<Owner: PersistentModel>(
        in value: Any,
        owner: Owner,
        adapter: any AnyRelationshipAdapterBox,
        mutation: (Owner) throws -> Void
    ) throws {
        guard let context = owner.modelContext, context.state === self else {
            throw SwiftDataError.unsupportedSchemaProperty("Relationship owner is not managed by this context.")
        }
        let endpoints = try adapter.endpoints(in: value)
        try validateCardinality(endpoints, adapter: adapter)
        for endpoint in endpoints where endpoint.modelContext != nil && endpoint.modelContext !== context {
            throw SwiftDataError.relationshipContextMismatch
        }

        let detachedEndpoints = endpoints.filter { $0.modelContext == nil }
        let stateBefore = PendingState(
            inserted: inserted, changed: changed, deleted: deleted, snapshots: snapshots,
            relationshipMutationEvents: relationshipMutationEvents)
        let baselinesBefore = baselineSnapshots
        let ownerSnapshot =
            snapshots[ObjectIdentifier(owner)]?.1
            ?? baselineSnapshots[ObjectIdentifier(owner)]?.1
            ?? owner.snapshotLifecycle()
        let mutationSnapshots: [(any PersistentModel, BackingDataSnapshot)] =
            [(owner, ownerSnapshot)] + detachedEndpoints.map { ($0, $0.snapshotLifecycle()) }
        for (model, snapshot) in mutationSnapshots {
            capture(model, current: snapshot)
        }
        for endpoint in detachedEndpoints {
            attachRelationshipDestination(endpoint, to: context)
        }
        do {
            try mutation(owner)
        } catch {
            for (endpoint, snapshot) in mutationSnapshots where endpoint !== owner {
                endpoint.restoreValuesAndDetachLifecycle(snapshot)
            }
            owner.restoreLifecycle(ownerSnapshot)
            inserted = stateBefore.inserted
            changed = stateBefore.changed
            deleted = stateBefore.deleted
            snapshots = stateBefore.snapshots
            relationshipMutationEvents = stateBefore.relationshipMutationEvents
            baselineSnapshots = baselinesBefore
            throw error
        }
    }

    private func attachRelationshipDestination<Model: PersistentModel>(_ model: Model, to context: ModelContext) {
        let snapshot = model.snapshotLifecycle()
        model.persistentBackingData.attach(to: context, model: model)
        model.setInsertionChanged()
        insert(model, snapshot: snapshot)
    }

    private func validateCardinality(
        _ endpoints: [any PersistentModel],
        adapter: any AnyRelationshipAdapterBox,
        requireMinimum: Bool = true
    ) throws {
        guard let metadata = adapter.metadata else {
            throw SwiftDataError.unsupportedSchemaProperty(
                "Relationship adapter '\(adapter.name)' is unresolved.")
        }
        let uniqueEndpoints = unique(endpoints)
        guard metadata.isToMany == adapter.isToMany else {
            throw SwiftDataError.unsupportedSchemaProperty(
                "Relationship adapter '\(adapter.name)' has incompatible cardinality metadata.")
        }
        guard metadata.isToMany || uniqueEndpoints.count <= 1 else {
            throw SwiftDataError.relationshipGraphConflict(
                "To-one relationship '\(adapter.name)' has multiple endpoints.")
        }
        let minimumCount = metadata.minimumModelCount ?? 0
        guard (!requireMinimum || uniqueEndpoints.count >= minimumCount),
            metadata.maximumModelCount.map({ uniqueEndpoints.count <= $0 }) ?? true
        else {
            throw SwiftDataError.relationshipGraphConflict(
                "Relationship '\(adapter.name)' violates its configured cardinality.")
        }
    }

    func validateCurrentRelationships(for model: any PersistentModel) throws {
        try locked {
            for adapter in relationshipAdapters(for: model) {
                guard let endpoints = adapter.read(model) else {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Relationship adapter '\(adapter.name)' cannot read its owner.")
                }
                try validateCardinality(endpoints, adapter: adapter)
            }
        }
    }

    func relationshipAdapters<Model: PersistentModel>(for modelType: Model.Type) -> [any AnyRelationshipAdapterBox] {
        relationshipAdaptersByModel[ObjectIdentifier(modelType)] ?? []
    }

    func relationshipAdapters(for model: any PersistentModel) -> [any AnyRelationshipAdapterBox] {
        relationshipAdaptersByModel[ObjectIdentifier(type(of: model))] ?? []
    }

    func mutateRelationship<Model: PersistentModel, Value>(
        model: Model,
        keyPath: KeyPath<Model, Value>,
        value: Value
    ) -> Bool {
        mutateRelationship(
            model: model, keyPath: keyPath, value: value,
            adapters: relationshipAdapters(for: Model.self))
    }

    func insert(_ model: any PersistentModel, snapshot: BackingDataSnapshot) {
        locked {
            let identifier = ObjectIdentifier(model)
            for index in transactionFrames.indices where transactionFrames[index].snapshots[identifier] == nil {
                transactionFrames[index].snapshots[identifier] = (model, snapshot)
            }
            for index in transactionFrames.indices {
                transactionFrames[index].modelSnapshots[identifier] = (model, snapshot)
            }
            if snapshots[identifier] == nil { snapshots[identifier] = (model, snapshot) }
            appendUnique(model, to: &inserted)
        }
    }

    func cancelInsertion(_ model: any PersistentModel) -> BackingDataSnapshot? {
        locked {
            let identifier = ObjectIdentifier(model)
            let snapshot = snapshots.removeValue(forKey: identifier)?.1
            remove(model, from: &inserted)
            remove(model, from: &changed)
            return snapshot
        }
    }

    func containsInserted(_ model: any PersistentModel) -> Bool { locked { contains(model, in: inserted) } }
    func containsDeleted(_ model: any PersistentModel) -> Bool { locked { contains(model, in: deleted) } }
    func markDeleted(_ model: any PersistentModel) {
        locked {
            remove(model, from: &changed)
            appendUnique(model, to: &deleted)
        }
    }

    func mutate(_ model: any PersistentModel, snapshot: () -> BackingDataSnapshot?, write: () -> Void) -> Bool {
        locked {
            guard let current = snapshot(), current.context?.state === self else { return false }
            capture(model, current: current)
            write()
            guard !contains(model, in: inserted), !contains(model, in: deleted) else { return true }
            appendUnique(model, to: &changed)
            return true
        }
    }

    func willMutate(_ model: any PersistentModel, snapshot: BackingDataSnapshot) {
        locked { capture(model, current: snapshot) }
    }

    func recordRelationshipMutation(
        owner: any PersistentModel,
        property: String,
        relationship: Schema.Relationship,
        oldValues: [any PersistentModel],
        newValues: [any PersistentModel]
    ) {
        locked {
            capture(owner, current: owner.snapshotLifecycle())
            if !contains(owner, in: inserted), !contains(owner, in: deleted) {
                appendUnique(owner, to: &changed)
            }
            relationshipMutationEvents.append(
                RelationshipMutationEvent(
                    owner: owner,
                    property: property,
                    relationship: relationship,
                    oldEndpointIDs: oldValues.map(\.persistentModelID),
                    oldEndpoints: oldValues,
                    newEndpointIDs: newValues.map(\.persistentModelID),
                    newEndpoints: newValues))
        }
    }

    func mutateRelationship<Owner: PersistentModel>(
        owner: Owner,
        adapter: any AnyRelationshipAdapterBox,
        value: Any
    ) throws {
        try locked {
            guard let context = owner.modelContext, context.state === self else {
                throw SwiftDataError.unsupportedSchemaProperty("Relationship owner is not managed by this context.")
            }
            let inputEndpoints = try adapter.endpoints(in: value)
            guard let metadata = adapter.metadata else {
                throw SwiftDataError.unsupportedSchemaProperty("Relationship adapter '\(adapter.name)' is unresolved.")
            }
            let mutations = try relationshipPlan(
                owner: owner, adapter: adapter, value: value, endpoints: inputEndpoints,
                metadata: metadata, context: context)
            guard !mutations.isEmpty else { return }
            let pendingBefore = PendingState(
                inserted: inserted, changed: changed, deleted: deleted, snapshots: self.snapshots,
                relationshipMutationEvents: relationshipMutationEvents)
            let baselineBefore = baselineSnapshots
            var snapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)] = [:]
            for mutation in mutations {
                let id = ObjectIdentifier(mutation.owner)
                if snapshots[id] == nil { snapshots[id] = (mutation.owner, mutation.owner.snapshotLifecycle()) }
            }
            for (model, snapshot) in snapshots.values { capture(model, current: snapshot) }
            do {
                for mutation in mutations {
                    try mutation.adapter.assign(mutation.value, to: mutation.owner)
                }
            } catch {
                for (model, snapshot) in snapshots.values { model.restoreLifecycle(snapshot) }
                inserted = pendingBefore.inserted
                changed = pendingBefore.changed
                deleted = pendingBefore.deleted
                self.snapshots = pendingBefore.snapshots
                relationshipMutationEvents = pendingBefore.relationshipMutationEvents
                baselineSnapshots = baselineBefore
                throw error
            }
            for mutation in mutations {
                if !contains(mutation.owner, in: inserted), !contains(mutation.owner, in: deleted) {
                    appendUnique(mutation.owner, to: &changed)
                }
                relationshipMutationEvents.append(
                    RelationshipMutationEvent(
                        owner: mutation.owner, property: mutation.adapter.name,
                        relationship: mutation.metadata, oldEndpointIDs: mutation.oldEndpoints.map(\.persistentModelID),
                        oldEndpoints: mutation.oldEndpoints,
                        newEndpointIDs: mutation.newEndpoints.map(\.persistentModelID),
                        newEndpoints: mutation.newEndpoints))
            }
        }
    }

    private struct PlannedRelationshipMutation {
        let owner: any PersistentModel
        let adapter: any AnyRelationshipAdapterBox
        let metadata: Schema.Relationship
        let oldEndpoints: [any PersistentModel]
        let newEndpoints: [any PersistentModel]
        let value: Any
    }

    private func relationshipPlan<Owner: PersistentModel>(
        owner: Owner,
        adapter: any AnyRelationshipAdapterBox,
        value: Any,
        endpoints: [any PersistentModel],
        metadata: Schema.Relationship,
        context: ModelContext
    ) throws -> [PlannedRelationshipMutation] {
        var plans: [RelationshipKey: RelationshipIntent] = [:]
        var order: [RelationshipKey] = []
        let initialKey = RelationshipKey(owner: owner, property: adapter.name)
        try validateContext(owner, context: context)
        for endpoint in endpoints { try validateContext(endpoint, context: context) }
        let initialList = unique(endpoints)
        try validateCardinality(initialList, adapter: adapter, requireMinimum: false)
        let initialMetadata = metadata
        let initialBox = adapter.resolved(with: initialMetadata)
        let initialCurrent = unique(initialBox.read(owner) ?? [])
        let initialPlan = RelationshipIntent(
            adapter: initialBox, original: initialCurrent, isInitial: true,
            replacement: initialList)
        plans[initialKey] = initialPlan
        order.append(initialKey)

        if let inverseName = initialMetadata.inverse {
            let removed = initialCurrent.filter { endpoint in !initialList.contains { $0 === endpoint } }
            let added = initialList.filter { endpoint in !initialCurrent.contains { $0 === endpoint } }
            var inverseEndpointOrder: [any PersistentModel] = []
            for endpoint in added + removed where !inverseEndpointOrder.contains(where: { $0 === endpoint }) {
                inverseEndpointOrder.append(endpoint)
            }
            for endpoint in inverseEndpointOrder {
                guard let inverse = relationshipAdapter(for: endpoint, property: inverseName),
                    let inverseCurrent = inverse.read(endpoint)
                else {
                    throw SwiftDataError.unsupportedSchemaProperty(
                        "Resolved inverse '\(inverseName)' has no typed adapter.")
                }
                let inverseKey = RelationshipKey(owner: endpoint, property: inverseName)
                let inversePlan = try relationshipIntent(
                    inverseKey, adapter: inverse, original: unique(inverseCurrent), plans: &plans, order: &order)
                if removed.contains(where: { $0 === endpoint }) {
                    inversePlan.remove(owner)
                } else if inverse.isToMany {
                    inversePlan.add(owner)
                } else {
                    for displaced in inverseCurrent where displaced !== owner {
                        guard let displacedAdapter = relationshipAdapter(for: displaced, property: adapter.name),
                            let displacedCurrent = displacedAdapter.read(displaced)
                        else {
                            throw SwiftDataError.unsupportedSchemaProperty(
                                "Displaced inverse owner has no typed adapter.")
                        }
                        let displacedKey = RelationshipKey(owner: displaced, property: adapter.name)
                        let displacedPlan = try relationshipIntent(
                            displacedKey, adapter: displacedAdapter, original: unique(displacedCurrent),
                            plans: &plans, order: &order)
                        displacedPlan.remove(endpoint)
                    }
                    try inversePlan.assignToOne(owner)
                }
            }
        }

        var planned: [PlannedRelationshipMutation] = []
        for key in order {
            guard let plan = plans[key], let oldValues = plan.adapter.read(key.model) else {
                throw SwiftDataError.unsupportedSchemaProperty("Relationship graph contains an invalid endpoint.")
            }
            let old = unique(oldValues)
            let list = plan.finalEndpoints
            try validateCardinality(list, adapter: plan.adapter)
            try validateContext(key.model, context: context)
            for endpoint in old + list { try validateContext(endpoint, context: context) }
            let oldIDs = old.map(ObjectIdentifier.init)
            let newIDs = list.map(ObjectIdentifier.init)
            guard oldIDs != newIDs else { continue }

            guard let metadata = plan.adapter.metadata else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Relationship adapter '\(plan.adapter.name)' is unresolved.")
            }
            let built: Any
            if plan.isInitial {
                built = try plan.adapter.makeValue(list)
            } else {
                do {
                    built = try plan.adapter.makeInverseValue(list)
                } catch {
                    if !plan.adapter.isToMany && list.isEmpty {
                        throw SwiftDataError.relationshipGraphConflict(
                            "Cannot clear nonoptional relationship '\(plan.adapter.name)'.")
                    }
                    throw error
                }
            }
            planned.append(
                PlannedRelationshipMutation(
                    owner: key.model, adapter: plan.adapter, metadata: metadata, oldEndpoints: old,
                    newEndpoints: list, value: built))
        }
        return planned
    }

    private struct RelationshipKey: Hashable {
        let identifier: ObjectIdentifier
        let property: String
        let model: any PersistentModel

        init(owner: any PersistentModel, property: String) {
            identifier = ObjectIdentifier(owner)
            self.property = property
            model = owner
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.identifier == rhs.identifier && lhs.property == rhs.property
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(identifier)
            hasher.combine(property)
        }
    }

    private func validateContext(_ model: any PersistentModel, context: ModelContext) throws {
        guard model.modelContext == nil || model.modelContext === context else {
            throw SwiftDataError.relationshipContextMismatch
        }
    }

    func relationships(
        ownedBy model: any PersistentModel
    ) -> [(any AnyRelationshipAdapterBox, [any PersistentModel])] {
        relationshipAdaptersByModel[ObjectIdentifier(type(of: model))]?.compactMap { adapter in
            adapter.read(model).map { (adapter, $0) }
        } ?? []
    }

    func validateRelationshipCardinality(
        _ endpoints: [any PersistentModel],
        using adapter: any AnyRelationshipAdapterBox
    ) throws {
        try validateCardinality(endpoints, adapter: adapter)
    }

    private final class RelationshipIntent {
        let adapter: any AnyRelationshipAdapterBox
        let original: [any PersistentModel]
        let isInitial: Bool
        private var replacement: [any PersistentModel]?
        private var additions: [any PersistentModel] = []
        private var removals: [ObjectIdentifier: any PersistentModel] = [:]
        private var toOneAssignment: (any PersistentModel)?

        var finalEndpoints: [any PersistentModel] {
            var result = replacement ?? original
            result.removeAll { removals[ObjectIdentifier($0)] != nil }
            for endpoint in additions where !result.contains(where: { $0 === endpoint }) {
                result.append(endpoint)
            }
            return result
        }

        init(
            adapter: any AnyRelationshipAdapterBox,
            original: [any PersistentModel],
            isInitial: Bool = false,
            replacement: [any PersistentModel]? = nil
        ) {
            self.adapter = adapter
            self.original = original
            self.isInitial = isInitial
            self.replacement = replacement
        }

        func assignToOne(_ endpoint: any PersistentModel) throws {
            if let toOneAssignment, toOneAssignment !== endpoint {
                throw SwiftDataError.relationshipGraphConflict(
                    "Conflicting assignments for '\(adapter.name)'.")
            }
            toOneAssignment = endpoint
            replacement = [endpoint]
            additions.removeAll()
            removals.removeAll()
        }

        func add(_ endpoint: any PersistentModel) {
            let identifier = ObjectIdentifier(endpoint)
            removals.removeValue(forKey: identifier)
            if !(replacement ?? original).contains(where: { $0 === endpoint }),
                !additions.contains(where: { $0 === endpoint })
            {
                additions.append(endpoint)
            }
        }

        func remove(_ endpoint: any PersistentModel) {
            let identifier = ObjectIdentifier(endpoint)
            additions.removeAll { $0 === endpoint }
            removals[identifier] = endpoint
        }
    }

    private func relationshipIntent(
        _ key: RelationshipKey,
        adapter: any AnyRelationshipAdapterBox,
        original: [any PersistentModel],
        plans: inout [RelationshipKey: RelationshipIntent],
        order: inout [RelationshipKey]
    ) throws -> RelationshipIntent {
        if let existing = plans[key] {
            try validateCardinality(existing.finalEndpoints, adapter: adapter)
            return existing
        }
        try validateCardinality(original, adapter: adapter, requireMinimum: false)
        let intent = RelationshipIntent(adapter: adapter, original: unique(original))
        plans[key] = intent
        order.append(key)
        return intent
    }

    func relationshipAdapter(for model: any PersistentModel, property: String) -> (
        any AnyRelationshipAdapterBox
    )? {
        guard
            let adapter = relationshipAdaptersByModel[ObjectIdentifier(type(of: model))]?.first(where: {
                $0.name == property
            })
        else {
            return nil
        }
        return adapter
    }

    private func relationshipMetadata(
        for adapter: any AnyRelationshipAdapterBox,
        owner: any PersistentModel
    ) -> Schema.Relationship {
        if let metadata = adapter.metadata { return metadata }
        _ = owner
        let destinationName =
            String(describing: adapter.destinationType).split(separator: ".").last.map(String.init) ?? ""
        return Schema.Relationship(name: adapter.name, destination: destinationName, isToMany: adapter.isToMany)
    }

    private func unique(_ models: [any PersistentModel]) -> [any PersistentModel] {
        var seen = Set<ObjectIdentifier>()
        return models.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    func recordMutation(_ model: any PersistentModel) {
        locked {
            guard !contains(model, in: inserted), !contains(model, in: deleted) else { return }
            appendUnique(model, to: &changed)
        }
    }

    func snapshotIdentifier(for model: any PersistentModel) -> PersistentIdentifier? {
        locked { snapshots[ObjectIdentifier(model)]?.1.identifier }
    }

    func beginTransaction(entrySnapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)]) {
        locked {
            let pending = PendingState(
                inserted: inserted, changed: changed, deleted: deleted, snapshots: snapshots,
                relationshipMutationEvents: relationshipMutationEvents)
            transactionFrames.append(
                TransactionFrame(
                    pending: pending, snapshots: [:], baselineSnapshots: baselineSnapshots,
                    modelSnapshots: entrySnapshots))
        }
    }

    func contains(_ model: any PersistentModel, in models: [any PersistentModel]) -> Bool {
        locked { models.contains { $0 === model } }
    }

    func popTransaction() { locked { _ = transactionFrames.popLast() } }

    func popTransactionSnapshot() -> TransactionFrame? { locked { transactionFrames.popLast() } }

    func pendingState() -> PendingState {
        locked {
            PendingState(
                inserted: inserted, changed: changed, deleted: deleted, snapshots: snapshots,
                relationshipMutationEvents: relationshipMutationEvents)
        }
    }

    func baselineSnapshotState() -> [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)] {
        locked { baselineSnapshots }
    }

    func setBaseline(_ model: any PersistentModel, snapshot: BackingDataSnapshot) {
        locked { baselineSnapshots[ObjectIdentifier(model)] = (model, snapshot) }
    }

    func removeBaseline(for model: any PersistentModel) {
        locked { _ = baselineSnapshots.removeValue(forKey: ObjectIdentifier(model)) }
    }

    func clearPending() {
        locked {
            inserted.removeAll()
            changed.removeAll()
            deleted.removeAll()
            snapshots.removeAll()
        }
    }

    func clearRelationshipMutationEvents() {
        locked { relationshipMutationEvents.removeAll() }
    }

    func restorePendingState(_ state: PendingState) {
        locked {
            inserted = state.inserted
            changed = state.changed
            deleted = state.deleted
            snapshots = state.snapshots
            relationshipMutationEvents = state.relationshipMutationEvents
        }
    }

    func restoreBaselineSnapshots(_ state: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)]) {
        locked { baselineSnapshots = state }
    }

    private func capture(_ model: any PersistentModel, current: BackingDataSnapshot) {
        let identifier = ObjectIdentifier(model)
        let firstTransactionSnapshot = !transactionFrames.contains {
            $0.modelSnapshots[identifier] != nil
        }
        if firstTransactionSnapshot {
            for index in transactionFrames.indices {
                transactionFrames[index].modelSnapshots[identifier] = (model, current)
            }
        }
        if snapshots[identifier] == nil {
            let baseline = baselineSnapshots[identifier]?.1
            let original = baseline?.identifier == current.identifier ? baseline : current
            snapshots[identifier] = (model, original ?? current)
        }
        for index in transactionFrames.indices where transactionFrames[index].snapshots[identifier] == nil {
            transactionFrames[index].snapshots[identifier] = (model, current)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }

    private func appendUnique(_ model: any PersistentModel, to models: inout [any PersistentModel]) {
        if !contains(model, in: models) { models.append(model) }
    }

    private func remove(_ model: any PersistentModel, from models: inout [any PersistentModel]) {
        models.removeAll { $0 === model }
    }
}
