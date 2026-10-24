import Observation

/// Represents the context managing persistent models.
public final class ModelContext: @unchecked Sendable {
    /// Creates an empty model context.
    public init() {}
}

/// A model whose properties are stored in OpenSwiftData backing data.
public protocol PersistentModel: AnyObject {
    associatedtype Model: PersistentModel = Self
    var persistentModelID: PersistentIdentifier { get }
    var modelContext: ModelContext? { get }
    var isDeleted: Bool { get }
    var hasChanges: Bool { get }
    var persistentBackingData: any BackingData<Self> { get set }
    init(backingData: any BackingData<Self>)
    static func schemaMetadata() -> [Schema.PropertyMetadata]
    static func createBackingData() -> DetachedBackingData<Self>
    func getValue<Value>(forKey keyPath: KeyPath<Self, Value>) -> Value
    func setValue<Value>(forKey keyPath: KeyPath<Self, Value>, to value: Value)
}

public extension PersistentModel {
    var persistentModelID: PersistentIdentifier { persistentBackingData.persistentModelID }
    var modelContext: ModelContext? { persistentBackingData.modelContext }
    var isDeleted: Bool { persistentBackingData.isDeleted }
    var hasChanges: Bool { persistentBackingData.hasChanges }
    func getValue<Value>(forKey keyPath: KeyPath<Self, Value>) -> Value {
        persistentBackingData.getValue(forKey: keyPath)
    }

    func setValue<Value>(forKey keyPath: KeyPath<Self, Value>, to value: Value) {
        persistentBackingData.setValue(forKey: keyPath, to: value)
    }
}
