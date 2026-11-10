import Foundation

struct EntityPrimaryKey: Hashable {
    let entityName: String
    let primaryKey: Int64
}

final class IdentityMap: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [EntityPrimaryKey: WeakModel] = [:]

    final class ModelHandle: @unchecked Sendable {
        // The immutable reference is transferred under the identity-map lock; model state remains backing-locked.
        let model: any PersistentModel

        init(_ model: any PersistentModel) {
            self.model = model
        }
    }

    func model<Model: PersistentModel>(for key: EntityPrimaryKey, as type: Model.Type) -> Model? {
        lock.lock()
        defer { lock.unlock() }
        guard let box = models[key], let value = box.value else {
            models.removeValue(forKey: key)
            return nil
        }
        return value as? Model
    }

    func register<Model: PersistentModel>(_ model: Model, for key: EntityPrimaryKey) {
        lock.lock()
        defer { lock.unlock() }
        models[key] = WeakModel(model)
        if models.count > 128 { models = models.filter { $0.value.value != nil } }
    }

    func canonicalHandle<Model: PersistentModel>(
        for key: EntityPrimaryKey,
        candidate: Model
    ) -> ModelHandle {
        lock.lock()
        defer { lock.unlock() }
        if let existing = models[key]?.value as? any PersistentModel { return ModelHandle(existing) }
        models[key] = WeakModel(candidate)
        if models.count > 128 { models = models.filter { $0.value.value != nil } }
        return ModelHandle(candidate)
    }

    func remove(_ key: EntityPrimaryKey) {
        lock.lock()
        defer { lock.unlock() }
        models.removeValue(forKey: key)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        models.removeAll()
    }

    /// Removes entries whose registered model is marked deleted, keeping live registrations.
    func clearDeleted() {
        lock.lock()
        defer { lock.unlock() }
        models = models.filter { _, box in
            guard let model = box.value as? any PersistentModel else { return false }
            return !model.isDeleted
        }
    }

    func liveModels() -> [(EntityPrimaryKey, any PersistentModel)] {
        lock.lock()
        defer { lock.unlock() }
        var live: [(EntityPrimaryKey, any PersistentModel)] = []
        models = models.filter { key, box in
            guard let model = box.value as? any PersistentModel else { return false }
            live.append((key, model))
            return true
        }
        return live
    }

    private final class WeakModel: @unchecked Sendable {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }
}
