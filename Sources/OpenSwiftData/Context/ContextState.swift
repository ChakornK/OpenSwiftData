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
    private var inserted: [any PersistentModel] = []
    private var changed: [any PersistentModel] = []
    private var deleted: [any PersistentModel] = []
    private var snapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)] = [:]
    private var baselineSnapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)] = [:]
    private var transactionFrames: [TransactionFrame] = []
    private var relationshipMutationEvents: [RelationshipMutationEvent] = []

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

    func insert(_ model: any PersistentModel, snapshot: BackingDataSnapshot) {
        locked {
            let identifier = ObjectIdentifier(model)
            for index in transactionFrames.indices where transactionFrames[index].snapshots[identifier] == nil {
                transactionFrames[index].snapshots[identifier] = (model, snapshot)
            }
            for index in transactionFrames.indices where transactionFrames[index].modelSnapshots[identifier] == nil {
                transactionFrames[index].modelSnapshots[identifier] = (model, snapshot)
            }
            snapshots[identifier] = (model, snapshot)
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
        for index in transactionFrames.indices where transactionFrames[index].modelSnapshots[identifier] == nil {
            transactionFrames[index].modelSnapshots[identifier] = (model, current)
        }
        if snapshots[identifier] == nil {
            snapshots[identifier] = (model, baselineSnapshots[identifier]?.1 ?? current)
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
