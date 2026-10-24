import Foundation

/// Captures a model's stored values and lifecycle state.
public struct BackingDataSnapshot {
    let values: [AnyKeyPath: Any]
    let context: ModelContext?
    let identifier: PersistentIdentifier
    let isDeleted: Bool
    let hasChanges: Bool
}

/// Stores the values and lifecycle state backing a persistent model.
public protocol BackingData<Model>: AnyObject {
    /// The concrete model type stored by this backing data.
    associatedtype Model: AnyObject
    /// The model's persistent identifier.
    var persistentModelID: PersistentIdentifier { get }
    /// The context managing the model, if any.
    var modelContext: ModelContext? { get }
    /// Whether the model has been deleted.
    var isDeleted: Bool { get }
    /// Whether the model has unsaved changes.
    var hasChanges: Bool { get }
    /// Reads a property value from backing storage.
    func getValue<Value>(forKey keyPath: KeyPath<Model, Value>) -> Value
    /// Writes a property value to backing storage.
    func setValue<Value>(forKey keyPath: KeyPath<Model, Value>, to value: Value)
    /// Captures the current model state before a mutation.
    func willMutate()
    /// Records a mutation in the owning context.
    func recordMutation()
    /// Returns a snapshot of stored property values.
    func snapshot() -> BackingDataSnapshot
    /// Restores property values from a snapshot.
    func restore(_ snapshot: BackingDataSnapshot)
    /// Restores property values while retaining current lifecycle state.
    func restoreValues(_ snapshot: BackingDataSnapshot)
    func restoreValuesAndDetach(_ snapshot: BackingDataSnapshot)
    /// Restores the model to its detached lifecycle without changing its values.
    func restoreValuesAndDetach()
    /// Restores values and lifecycle state from a snapshot, then detaches the model.
    func restoreLifecycleAndDetach(_ snapshot: BackingDataSnapshot)
    /// Restores a snapshot and detaches a canceled insertion.
    func cancelInsertion(restoring snapshot: BackingDataSnapshot)
    /// Associates this model with a context and changes its identity to that context's store.
    func attach(to context: ModelContext, model: Model)
    /// Marks this model as deleted.
    func markDeleted()
    /// Detaches a newly inserted model canceled before saving.
    func cancelInsertion()
    /// Resets lifecycle state after a successful save.
    func markSaved()
    /// Removes the context association and restores detached identity.
    func detach()
    /// Removes the context association while retaining deletion state and property values.
    func detachDeleted()
}

/// Creates and owns the initial values for a model that is not in a context.
public final class DetachedBackingData<Model: PersistentModel>: BackingData, @unchecked Sendable {
    private var values: [AnyKeyPath: Any] = [:]
    private let lock = NSRecursiveLock()
    private var identifier: PersistentIdentifier
    private let detachedIdentifier: PersistentIdentifier
    private let metadata: [Schema.PropertyMetadata]
    private weak var context: ModelContext?
    private weak var model: Model?
    private var deleted = false
    private var changed = false
    private var onChange: (() -> Void)?

    /// Creates detached storage for a model's schema.
    public init(metadata: [Schema.PropertyMetadata]) {
        self.metadata = metadata
        let detachedID = PersistentIdentifier(
            storeIdentifier: "OSD.Detached",
            entityName: String(describing: Model.self),
            temporaryIdentifier: UUID()
        )
        identifier = detachedID
        detachedIdentifier = detachedID
        for property in metadata {
            guard let keyPath = property.keypath else { continue }
            guard let defaultValue = property.runtimeDefaultValue else { continue }
            values[keyPath] = defaultValue
        }
    }

    /// The temporary identifier for this detached model.
    public var persistentModelID: PersistentIdentifier {
        lock.lock()
        defer { lock.unlock() }
        return identifier
    }
    /// The context managing this model, if any.
    public var modelContext: ModelContext? {
        lock.lock()
        defer { lock.unlock() }
        return context
    }
    /// Whether this model has been deleted.
    public var isDeleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deleted
    }
    /// Whether this model has unsaved changes.
    public var hasChanges: Bool {
        lock.lock()
        defer { lock.unlock() }
        return changed
    }

    /// Reads a stored value for the given property key path.
    public func getValue<Value>(forKey keyPath: KeyPath<Model, Value>) -> Value {
        lock.lock()
        let storedValue = values[keyPath]
        lock.unlock()
        if let value = storedValue as? Value { return value }
        return unassignedValue(for: keyPath)
    }

    /// Captures the current model state before a mutation.
    public func willMutate() {
        lock.lock()
        let context = self.context
        let model = self.model
        lock.unlock()
        guard let context, let model else { return }
        MainActor.assumeIsolated {
            context.willMutate(model)
        }
    }

    /// Stores a value for the given property key path.
    public func setValue<Value>(forKey keyPath: KeyPath<Model, Value>, to value: Value) {
        lock.lock()
        values[keyPath] = value
        if context != nil { changed = true }
        lock.unlock()
    }

    /// Notifies the context that this model was mutated.
    public func recordMutation() {
        lock.lock()
        let context = self.context
        let model = self.model
        lock.unlock()
        guard let context, let model else { return }
        MainActor.assumeIsolated {
            context.recordMutation(model)
        }
    }

    func setChangeHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        onChange = handler
        lock.unlock()
    }

    func notifyChange() {
        lock.lock()
        let onChange = self.onChange
        lock.unlock()
        onChange?()
    }

    /// Returns a copy of this model's stored property values.
    public func snapshot() -> BackingDataSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return BackingDataSnapshot(
            values: values,
            context: context,
            identifier: identifier,
            isDeleted: deleted,
            hasChanges: changed
        )
    }

    /// Restores the stored values and lifecycle state from a prior snapshot.
    public func restore(_ snapshot: BackingDataSnapshot) {
        lock.lock()
        values = snapshot.values
        context = snapshot.context
        identifier = snapshot.identifier
        deleted = snapshot.isDeleted
        changed = snapshot.hasChanges
        lock.unlock()
    }

    /// Restores property values without changing lifecycle flags.
    public func restoreValues(_ snapshot: BackingDataSnapshot) {
        lock.lock()
        values = snapshot.values
        lock.unlock()
    }

    /// Restores values and resets a canceled insertion to its detached lifecycle.
    public func restoreValuesAndDetach(_ snapshot: BackingDataSnapshot) {
        lock.lock()
        values = snapshot.values
        context = nil
        onChange = nil
        identifier = detachedIdentifier
        deleted = false
        changed = false
        lock.unlock()
    }

    /// Restores the model to its detached lifecycle without changing its values.
    public func restoreValuesAndDetach() {
        lock.lock()
        context = nil
        onChange = nil
        identifier = detachedIdentifier
        deleted = false
        changed = false
        lock.unlock()
    }

    /// Restores values and lifecycle state from a snapshot, then detaches the model.
    public func restoreLifecycleAndDetach(_ snapshot: BackingDataSnapshot) {
        lock.lock()
        values = snapshot.values
        context = nil
        onChange = nil
        identifier = detachedIdentifier
        deleted = false
        changed = false
        lock.unlock()
    }

    /// Restores a snapshot and detaches a canceled insertion.
    public func cancelInsertion(restoring snapshot: BackingDataSnapshot) {
        lock.lock()
        values = snapshot.values
        context = nil
        onChange = nil
        identifier = detachedIdentifier
        deleted = false
        changed = false
        lock.unlock()
    }

    /// Attaches this model to the supplied context.
    public func attach(to context: ModelContext, model: Model) {
        lock.lock()
        self.context = context
        self.model = model
        onChange = nil
        identifier = PersistentIdentifier(
            storeIdentifier: "OSD.InMemory.\(ObjectIdentifier(context))",
            entityName: String(describing: Model.self),
            temporaryIdentifier: identifier.temporaryIdentifier ?? UUID()
        )
        deleted = false
        lock.unlock()
    }

    /// Detaches an insertion canceled before saving.
    public func cancelInsertion() {
        detach()
    }

    /// Marks this model as deleted.
    public func markDeleted() {
        lock.lock()
        deleted = true
        changed = true
        lock.unlock()
    }

    /// Clears pending lifecycle flags after a successful save.
    public func markSaved() {
        lock.lock()
        if context != nil {
            deleted = false
        }
        changed = false
        lock.unlock()
    }

    /// Detaches this model and restores its original identifier.
    public func detach() {
        lock.lock()
        context = nil
        onChange = nil
        identifier = detachedIdentifier
        changed = false
        deleted = false
        lock.unlock()
    }

    /// Detaches a successfully deleted model without clearing its deletion state or values.
    public func detachDeleted() {
        lock.lock()
        context = nil
        onChange = nil
        identifier = detachedIdentifier
        lock.unlock()
    }

    private func unassignedValue<Value>(for keyPath: KeyPath<Model, Value>) -> Value {
        if let optionalType = Value.self as? any _OptionalType.Type,
            let nilValue = optionalType.nilValue as? Value
        {
            return nilValue
        }
        let propertyName = metadata.first { $0.keypath == keyPath }?.name ?? "unknown"
        fatalError("OSD: property '\(propertyName)' of \(Model.self) was read before assignment")
    }
}

private protocol _OptionalType { static var nilValue: Any { get } }
extension Optional: _OptionalType { static var nilValue: Any { Self.none as Any } }

public extension PersistentModel {
    /// Creates detached backing data initialized from schema defaults.
    static func createBackingData() -> DetachedBackingData<Self> {
        DetachedBackingData(metadata: schemaMetadata())
    }
}

extension PersistentModel {
    var backingData: DetachedBackingData<Self>? {
        persistentBackingData as? DetachedBackingData<Self>
    }
}
