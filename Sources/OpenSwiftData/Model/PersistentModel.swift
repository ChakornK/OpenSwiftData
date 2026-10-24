import Observation

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
        persistentBackingData.willMutate()
        persistentBackingData.setValue(forKey: keyPath, to: value)
        persistentBackingData.recordMutation()
    }

    func snapshotLifecycle() -> BackingDataSnapshot { persistentBackingData.snapshot() }
    func markSavedLifecycle() { persistentBackingData.markSaved() }
    func restoreLifecycle(_ snapshot: BackingDataSnapshot) { persistentBackingData.restore(snapshot) }
    func restoreValuesLifecycle(_ snapshot: BackingDataSnapshot) { persistentBackingData.restoreValues(snapshot) }
    func restoreValuesAndDetachLifecycle(_ snapshot: BackingDataSnapshot) {
        persistentBackingData.restoreValuesAndDetach(snapshot)
    }
    func detachLifecycle() { persistentBackingData.detach() }
    func detachDeletedLifecycle() { persistentBackingData.detachDeleted() }
}
