import Foundation

struct EntityPrimaryKey: Hashable {
    let entityName: String
    let primaryKey: Int64
}

@MainActor
final class IdentityMap {
    private var models: [EntityPrimaryKey: WeakModel] = [:]

    func model<Model: PersistentModel>(for key: EntityPrimaryKey, as type: Model.Type) -> Model? {
        guard let model = models[key]?.value as? Model else {
            models.removeValue(forKey: key)
            return nil
        }
        return model
    }

    func register<Model: PersistentModel>(_ model: Model, for key: EntityPrimaryKey) {
        models[key] = WeakModel(model)
        if models.count > 128 { models = models.filter { $0.value.value != nil } }
    }

    func remove(_ key: EntityPrimaryKey) { models.removeValue(forKey: key) }

    private final class WeakModel {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }
}
