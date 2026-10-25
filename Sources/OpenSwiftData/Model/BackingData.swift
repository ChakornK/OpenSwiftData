import Foundation

/// Captures a model's stored values and lifecycle state.
public struct BackingDataSnapshot {
    let values: [AnyKeyPath: Any]
    let context: ModelContext?
    let identifier: PersistentIdentifier
    let isDeleted: Bool
    let hasChanges: Bool
    let savedValues: [AnyKeyPath: Any]?
    let primaryKey: Int64?
    let entityID: Int?
    let optimisticLockVersion: Int
}

/// Stores the values and lifecycle state backing a persistent model.
///
/// Implementations supply typed property storage and lifecycle transitions for one model type.
public protocol BackingData<Model>: AnyObject {
    /// The concrete model type stored by this backing data.
    associatedtype Model: AnyObject
    /// The identifier used to locate this model in its store, or its temporary identifier before persistence.
    ///
    /// - Returns: The model's current persistent identifier.
    var persistentModelID: PersistentIdentifier { get }
    /// The context managing the model, or `nil` when the model is detached.
    ///
    /// - Returns: The managing context, if attached.
    var modelContext: ModelContext? { get }
    /// Whether the model is marked for deletion.
    ///
    /// - Returns: `true` when deletion is pending.
    var isDeleted: Bool { get }
    /// Whether the model has changes pending save.
    ///
    /// - Returns: `true` when changes are pending.
    var hasChanges: Bool { get }
    /// Returns the stored value for a property, or its unassigned default when supported.
    ///
    /// - Parameter keyPath: The property to read.
    /// - Returns: The stored or default property value.
    func getValue<Value>(forKey keyPath: KeyPath<Model, Value>) -> Value
    /// Stores a property value and marks it changed when attached to a context.
    ///
    /// - Parameters:
    ///   - keyPath: The property to update.
    ///   - value: The value to store.
    func setValue<Value>(forKey keyPath: KeyPath<Model, Value>, to value: Value)
    /// Notifies the managing context that a model mutation is about to occur.
    ///
    /// Detached models receive no context notification.
    func willMutate()
    /// Notifies the managing context that a model mutation has occurred.
    ///
    /// Detached models receive no context notification.
    func recordMutation()
    /// Captures property values and lifecycle state for later restoration.
    ///
    /// - Returns: A snapshot of the current backing state.
    func snapshot() -> BackingDataSnapshot
    /// Restores property values, context, identifier, and lifecycle flags from a snapshot.
    ///
    /// - Parameter snapshot: The state to restore.
    func restore(_ snapshot: BackingDataSnapshot)
    /// Restores property values without changing context or lifecycle state.
    ///
    /// - Parameter snapshot: The property values to restore.
    func restoreValues(_ snapshot: BackingDataSnapshot)
    /// Restores property values, then detaches and resets lifecycle state to detached.
    ///
    /// - Parameter snapshot: The property values to restore.
    func restoreValuesAndDetach(_ snapshot: BackingDataSnapshot)
    /// Detaches the model and resets its lifecycle state while preserving current property values.
    func restoreValuesAndDetach()
    /// Restores snapshot state and detaches the model.
    ///
    /// - Parameter snapshot: The state whose values are restored before detaching.
    func restoreLifecycleAndDetach(_ snapshot: BackingDataSnapshot)
    /// Restores snapshot property values, then detaches and clears insertion lifecycle state.
    ///
    /// - Parameter snapshot: The property values to restore.
    func cancelInsertion(restoring snapshot: BackingDataSnapshot)
    /// Assigns the permanent store identity and clears changed and deleted flags.
    ///
    /// - Parameters:
    ///   - storeIdentifier: The identifier of the backing store.
    ///   - entityID: The store's entity identifier.
    ///   - primaryKey: The permanent row key.
    ///   - version: The committed row version.
    func markPersisted(storeIdentifier: String, entityID: Int, primaryKey: Int64, version: Int)
    /// Clears deletion and marks the model as changed after restoring an insertion.
    func restoreInsertionState()
    /// Associates the model with a context and assigns a context-scoped identifier.
    ///
    /// - Parameters:
    ///   - context: The context to associate with the model.
    ///   - model: The model managed by the backing data.
    func attach(to context: ModelContext, model: Model)
    /// Marks the model deleted and changed.
    func markDeleted()
    /// Detaches the model and resets its lifecycle state to detached.
    func cancelInsertion()
    /// Clears the changed flag and clears deletion when the model remains attached.
    func markSaved()
    /// Removes the context association and resets the identifier and lifecycle flags.
    func detach()
    /// Removes the context association while preserving the deleted state and identifier.
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
            storeIdentifier: "OSD.Detached", entityName: String(describing: Model.self), temporaryIdentifier: UUID())
        identifier = detachedID
        detachedIdentifier = detachedID
        for property in metadata {
            guard let keyPath = property.keypath, let defaultValue = property.runtimeDefaultValue else { continue }
            values[keyPath] = defaultValue
        }
    }

    /// The model's persistent or temporary identifier.
    public var persistentModelID: PersistentIdentifier { lock.lock(); defer { lock.unlock() }; return identifier }
    /// The managing context, or `nil` when detached.
    public var modelContext: ModelContext? { lock.lock(); defer { lock.unlock() }; return context }
    /// Whether deletion is pending.
    public var isDeleted: Bool { lock.lock(); defer { lock.unlock() }; return deleted }
    /// Whether changes are pending save.
    public var hasChanges: Bool { lock.lock(); defer { lock.unlock() }; return changed }

    /// Returns the stored value, or an unassigned default when supported.
    public func getValue<Value>(forKey keyPath: KeyPath<Model, Value>) -> Value {
        lock.lock(); let stored = values[keyPath]; lock.unlock()
        if let value = stored as? Value { return value }
        return unassignedValue(for: keyPath)
    }
    /// Notifies the managing context before mutation; detached models receive no notification.
    public func willMutate() {
        lock.lock(); let context = self.context; let model = self.model; lock.unlock()
        guard let context, let model else { return }
        MainActor.assumeIsolated { context.willMutate(model) }
    }
    /// Stores a value and marks the model changed when attached to a context.
    public func setValue<Value>(forKey keyPath: KeyPath<Model, Value>, to value: Value) {
        lock.lock(); values[keyPath] = value; if context != nil { changed = true }; lock.unlock()
    }
    /// Notifies the managing context after mutation; detached models receive no notification.
    public func recordMutation() {
        lock.lock(); let context = self.context; let model = self.model; lock.unlock()
        guard let context, let model else { return }
        MainActor.assumeIsolated { context.recordMutation(model) }
    }
    func setChangeHandler(_ handler: @escaping () -> Void) { lock.lock(); onChange = handler; lock.unlock() }
    func notifyChange() { lock.lock(); let handler = onChange; lock.unlock(); handler?() }

    /// Captures property values and lifecycle state for later restoration.
    public func snapshot() -> BackingDataSnapshot {
        lock.lock(); defer { lock.unlock() }
        return BackingDataSnapshot(
            values: values, context: context, identifier: identifier, isDeleted: deleted, hasChanges: changed,
            savedValues: nil, primaryKey: identifier.primaryKey, entityID: nil, optimisticLockVersion: 0)
    }
    /// Restores property values, context, identifier, and lifecycle flags from a snapshot.
    public func restore(_ snapshot: BackingDataSnapshot) {
        lock.lock(); values = snapshot.values; context = snapshot.context; identifier = snapshot.identifier
        deleted = snapshot.isDeleted; changed = snapshot.hasChanges; lock.unlock()
    }
    /// Restores property values without changing context or lifecycle state.
    public func restoreValues(_ snapshot: BackingDataSnapshot) { lock.lock(); values = snapshot.values; lock.unlock() }
    /// Restores snapshot values and detaches with detached lifecycle flags.
    public func restoreValuesAndDetach(_ snapshot: BackingDataSnapshot) {
        lock.lock(); values = snapshot.values; context = nil; onChange = nil; identifier = detachedIdentifier;
        deleted = false; changed = false; lock.unlock()
    }
    /// Detaches while preserving current values and resets detached lifecycle flags.
    public func restoreValuesAndDetach() { detach() }
    /// Restores snapshot values and identifier, then detaches and clears deletion and change flags.
    public func restoreLifecycleAndDetach(_ snapshot: BackingDataSnapshot) { restoreValuesAndDetach(snapshot) }
    /// Restores snapshot values, then detaches and clears insertion lifecycle flags.
    public func cancelInsertion(restoring snapshot: BackingDataSnapshot) { restoreValuesAndDetach(snapshot) }
    /// Assigns committed row identity and version, folding changes into the baseline.
    public func markPersisted(storeIdentifier: String, entityID: Int, primaryKey: Int64, version: Int) {
        lock.lock();
        identifier = PersistentIdentifier(
            storeIdentifier: storeIdentifier, entityName: String(describing: Model.self), primaryKey: primaryKey);
        changed = false; deleted = false; lock.unlock()
    }
    /// Associates the model with a context and assigns its context-scoped identifier.
    public func attach(to context: ModelContext, model: Model) {
        lock.lock(); self.context = context; self.model = model; onChange = nil
        identifier = PersistentIdentifier(
            storeIdentifier: "OSD.InMemory.\(ObjectIdentifier(context))", entityName: String(describing: Model.self),
            temporaryIdentifier: identifier.temporaryIdentifier ?? UUID())
        deleted = false; lock.unlock()
    }
    /// Marks the model deleted and changed.
    public func markDeleted() { lock.lock(); deleted = true; changed = true; lock.unlock() }
    /// Clears deletion and marks the model changed after restoring an insertion.
    public func restoreInsertionState() { lock.lock(); deleted = false; changed = true; lock.unlock() }
    /// Detaches the model and resets its identifier and lifecycle flags.
    public func cancelInsertion() { detach() }
    /// Folds current values into the baseline and clears change and deletion flags.
    public func markSaved() { lock.lock(); if context != nil { deleted = false }; changed = false; lock.unlock() }
    /// Removes the context association and resets identifier and lifecycle flags.
    public func detach() {
        lock.lock(); context = nil; onChange = nil; identifier = detachedIdentifier; changed = false; deleted = false;
        lock.unlock()
    }
    /// Removes the context association while retaining identifier, values, and deletion state.
    public func detachDeleted() { lock.lock(); context = nil; onChange = nil; lock.unlock() }

    private func unassignedValue<Value>(for keyPath: KeyPath<Model, Value>) -> Value {
        if let optional = Value.self as? any _OptionalType.Type, let nilValue = optional.nilValue as? Value {
            return nilValue
        }
        let name = metadata.first { $0.keypath == keyPath }?.name ?? "unknown"
        fatalError("OSD: property '\(name)' of \(Model.self) was read before assignment")
    }
}

protocol _OptionalType { static var nilValue: Any { get } }
extension Optional: _OptionalType { static var nilValue: Any { Self.none as Any } }

public extension PersistentModel {
    /// Creates detached backing data initialized from schema defaults.
    static func createBackingData() -> DetachedBackingData<Self> { DetachedBackingData(metadata: schemaMetadata()) }
}

extension PersistentModel {
    var backingData: DetachedBackingData<Self>? { persistentBackingData as? DetachedBackingData<Self> }
}
