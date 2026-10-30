import Foundation

struct UndoGroupMember {
    weak var model: (any PersistentModel)?
    var retainedModel: (any PersistentModel)?
    var restoresDeletedRow: Bool = false
    var snapshot: BackingDataSnapshot
    var relationshipEndpoints: [String: [any PersistentModel]] = [:]

    var resolvedModel: (any PersistentModel)? { model ?? retainedModel }
}

final class UndoGroupOperation {
    weak var context: ModelContext?
    private let managerGeneration: UInt64
    private(set) var members: [UndoGroupMember] = []
    private var memberIDs = Set<ObjectIdentifier>()

    init(context: ModelContext, managerGeneration: UInt64) {
        self.context = context
        self.managerGeneration = managerGeneration
    }

    func append(
        model: any PersistentModel,
        snapshot: BackingDataSnapshot,
        retainModel: Bool = false,
        restoresDeletedRow: Bool = false
    ) {
        guard memberIDs.insert(ObjectIdentifier(model)).inserted else { return }
        members.append(
            UndoGroupMember(
                model: model,
                retainedModel: retainModel ? model : nil,
                restoresDeletedRow: restoresDeletedRow,
                snapshot: Self.detachedSnapshot(snapshot),
                relationshipEndpoints: Self.currentRelationshipEndpoints(model)))
    }

    func replaceSnapshot(
        for model: any PersistentModel,
        with snapshot: BackingDataSnapshot,
        relationships: [String: [any PersistentModel]] = [:]
    ) {
        guard let index = members.firstIndex(where: { $0.resolvedModel === model }) else { return }
        members[index].snapshot = Self.detachedSnapshot(snapshot)
        members[index].relationshipEndpoints = relationships
    }

    func setRelationshipEndpoints(
        for model: any PersistentModel, relationships: [String: [any PersistentModel]]
    ) {
        guard let index = members.firstIndex(where: { $0.resolvedModel === model }) else { return }
        members[index].relationshipEndpoints = relationships
    }

    func perform() {
        guard let context, context.undoManagerGeneration == managerGeneration else { return }
        let current = members.compactMap { member -> UndoGroupMember? in
            guard let model = member.resolvedModel else { return nil }
            let currentSnapshot = model.snapshotLifecycle()
            let inverseSnapshot = BackingDataSnapshot(
                values: currentSnapshot.values,
                context: currentSnapshot.context,
                identifier: currentSnapshot.identifier,
                isDeleted: member.restoresDeletedRow || currentSnapshot.isDeleted,
                hasChanges: currentSnapshot.hasChanges,
                savedValues: currentSnapshot.savedValues,
                primaryKey: currentSnapshot.primaryKey,
                entityID: currentSnapshot.entityID,
                optimisticLockVersion: currentSnapshot.optimisticLockVersion)
            return UndoGroupMember(
                model: model,
                retainedModel: member.retainedModel != nil || model.isDeleted ? model : nil,
                restoresDeletedRow: member.restoresDeletedRow && !member.snapshot.isDeleted,
                snapshot: Self.detachedSnapshot(inverseSnapshot),
                relationshipEndpoints: Self.currentRelationshipEndpoints(model))
        }
        _ = context.applyUndoGroup(members)
        members = current
        memberIDs = Set(members.compactMap { $0.resolvedModel.map(ObjectIdentifier.init) })
        context.endCurrentUndoGroup()
        context.registerUndoOperation(self)
    }

    private static func currentRelationshipEndpoints(_ model: any PersistentModel) -> [String: [any PersistentModel]] {
        let adapters: [any AnyRelationshipAdapterBox]
        if let modelType = type(of: model) as? any RelationshipModel.Type {
            adapters = modelType.relationshipAdapterCandidates() + modelType.inferredRelationshipAdapterCandidates()
        } else {
            adapters = []
        }
        return Dictionary(
            uniqueKeysWithValues: adapters.compactMap { adapter in
                adapter.read(model).map { (adapter.name, $0) }
            })
    }

    static func detachedSnapshot(_ snapshot: BackingDataSnapshot) -> BackingDataSnapshot {
        BackingDataSnapshot(
            values: snapshot.values, context: nil, identifier: snapshot.identifier,
            isDeleted: snapshot.isDeleted, hasChanges: snapshot.hasChanges, savedValues: snapshot.savedValues,
            primaryKey: snapshot.primaryKey, entityID: snapshot.entityID,
            optimisticLockVersion: snapshot.optimisticLockVersion)
    }
}
