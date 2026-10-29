import Foundation
import Synchronization

struct EntityPrimaryKey: Hashable {
    let entityName: String
    let primaryKey: Int64
}

final class IdentityMap: Sendable {
    private let models = Mutex<[EntityPrimaryKey: WeakModel]>([:])

    final class ModelHandle: @unchecked Sendable {
        // The immutable reference is transferred under the identity-map mutex; model state remains backing-locked.
        let model: any PersistentModel

        init(_ model: any PersistentModel) {
            self.model = model
        }
    }

    func model<Model: PersistentModel>(for key: EntityPrimaryKey, as type: Model.Type) -> Model? {
        models.withLock { models in
            guard let model = models[key]?.value as? Model else {
                models.removeValue(forKey: key)
                return nil
            }
            return model
        }
    }

    func register<Model: PersistentModel>(_ model: Model, for key: EntityPrimaryKey) {
        models.withLock { models in
            models[key] = WeakModel(model)
            if models.count > 128 { models = models.filter { $0.value.value != nil } }
        }
    }

    func canonicalHandle<Model: PersistentModel>(
        for key: EntityPrimaryKey,
        candidate: Model
    ) -> ModelHandle {
        models.withLock { models in
            if let existing = models[key]?.value as? any PersistentModel { return ModelHandle(existing) }
            models[key] = WeakModel(candidate)
            if models.count > 128 { models = models.filter { $0.value.value != nil } }
            return ModelHandle(candidate)
        }
    }

    func remove(_ key: EntityPrimaryKey) {
        models.withLock { _ = $0.removeValue(forKey: key) }
    }

    func liveModels() -> [(EntityPrimaryKey, any PersistentModel)] {
        models.withLock { models in
            var live: [(EntityPrimaryKey, any PersistentModel)] = []
            models = models.filter { key, box in
                guard let model = box.value as? any PersistentModel else { return false }
                live.append((key, model))
                return true
            }
            return live
        }
    }

    private final class WeakModel: @unchecked Sendable {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }
}
