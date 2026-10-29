import Foundation

struct UndoGroupMember {
    weak var model: (any PersistentModel)?
    var snapshot: BackingDataSnapshot
    var relationshipEndpoints: [String: [any PersistentModel]] = [:]
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

    func append(model: any PersistentModel, snapshot: BackingDataSnapshot) {
        guard memberIDs.insert(ObjectIdentifier(model)).inserted else { return }
        members.append(
            UndoGroupMember(
                model: model,
                snapshot: Self.detachedSnapshot(snapshot),
                relationshipEndpoints: Self.currentRelationshipEndpoints(model)))
    }

    func replaceSnapshot(
        for model: any PersistentModel,
        with snapshot: BackingDataSnapshot,
        relationships: [String: [any PersistentModel]] = [:]
    ) {
        guard let index = members.firstIndex(where: { $0.model === model }) else { return }
        members[index].snapshot = Self.detachedSnapshot(snapshot)
        members[index].relationshipEndpoints = relationships
    }

    func setRelationshipEndpoints(
        for model: any PersistentModel, relationships: [String: [any PersistentModel]]
    ) {
        guard let index = members.firstIndex(where: { $0.model === model }) else { return }
        members[index].relationshipEndpoints = relationships
    }

    func perform() {
        guard let context, context.undoManagerGeneration == managerGeneration else { return }
        let current = members.compactMap { member -> UndoGroupMember? in
            guard let model = member.model else { return nil }
            return UndoGroupMember(
                model: model,
                snapshot: Self.detachedSnapshot(model.snapshotLifecycle()),
                relationshipEndpoints: Self.currentRelationshipEndpoints(model))
        }
        _ = context.applyUndoGroup(members)
        members = current
        memberIDs = Set(members.compactMap { $0.model.map(ObjectIdentifier.init) })
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
