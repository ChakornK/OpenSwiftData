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
    /// Reads a value through its generated property slot when supported.
    /// Reads a property from its generated slot, falling back to its key path by default.
    func getValue<Value>(at slot: Int, forKey keyPath: KeyPath<Model, Value>) -> Value
    /// Stores a property value and marks it changed when attached to a context.
    ///
    /// - Parameters:
    ///   - keyPath: The property to update.
    ///   - value: The value to store.
    func setValue<Value>(forKey keyPath: KeyPath<Model, Value>, to value: Value)
    /// Stores a value through its generated property slot when supported.
    /// Stores a property in its generated slot, falling back to its key path by default.
    func setValue<Value>(at slot: Int, forKey keyPath: KeyPath<Model, Value>, to value: Value)
    /// Notifies the managing context that a model mutation is about to occur.
    ///
    /// Detached models receive no context notification.
    func willMutate()
    /// Performs a value write atomically with context mutation tracking.
    ///
    /// - Parameter write: The value write to perform.
    func withMutation(_ write: () -> Void)
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

/// Type-erased model storage used when inherited models expose properties rooted at a subclass type.
public protocol AnyBackingData: AnyObject {
    /// Reads a stored value through generated type-erased access closures.
    func getValue<Value>(at slot: Int, keyPath: AnyKeyPath, as type: Value.Type) -> Value?
    /// Writes a value through a generated type-erased access closure.
    func setValue<Value>(at slot: Int, keyPath: AnyKeyPath, to value: Value) -> Bool
    /// Performs a property write with the backing's context mutation tracking.
    func withMutation(_ write: () -> Void)
    /// Indicates whether this storage can access key paths rooted at subclass types.
    var supportsSubclassKeyPaths: Bool { get }
    /// Captures the storage's lifecycle and property values.
    func snapshot() -> BackingDataSnapshot
    /// Associates the storage with its context and model object.
    func attach(to context: ModelContext, model: any PersistentModel)
    /// Replaces the model identifier's entity name after a concrete hierarchy entity is persisted.
    func setConcreteEntityName(_ entityName: String)
}

public extension AnyBackingData {
    func setConcreteEntityName(_ entityName: String) { _ = entityName }
}

private final class ErasedBackingData<Model: PersistentModel>: AnyBackingData {
    let backing: any BackingData<Model>

    init(_ backing: any BackingData<Model>) {
        self.backing = backing
    }

    func getValue<Value>(at slot: Int, keyPath: AnyKeyPath, as type: Value.Type) -> Value? {
        guard let keyPath = keyPath as? KeyPath<Model, Value> else { return nil }
        return backing.getValue(at: slot, forKey: keyPath)
    }

    func setValue<Value>(at slot: Int, keyPath: AnyKeyPath, to value: Value) -> Bool {
        guard let keyPath = keyPath as? KeyPath<Model, Value> else { return false }
        backing.setValue(at: slot, forKey: keyPath, to: value)
        return true
    }

    func snapshot() -> BackingDataSnapshot { backing.snapshot() }

    func withMutation(_ write: () -> Void) {
        backing.withMutation(write)
    }

    func attach(to context: ModelContext, model: any PersistentModel) {
        guard let model = model as? Model else { return }
        backing.attach(to: context, model: model)
    }

    func setConcreteEntityName(_ entityName: String) { _ = entityName }

    var supportsSubclassKeyPaths: Bool { false }
}

public extension BackingData {
    func getValue<Value>(at slot: Int, forKey keyPath: KeyPath<Model, Value>) -> Value {
        getValue(forKey: keyPath)
    }

    func setValue<Value>(at slot: Int, forKey keyPath: KeyPath<Model, Value>, to value: Value) {
        setValue(forKey: keyPath, to: value)
    }

    /// Performs a property write with mutation notifications for conformers without atomic support.
    func withMutation(_ write: () -> Void) {
        willMutate()
        write()
        recordMutation()
    }
}

/// Creates and owns the initial values for a model that is not in a context.
public final class DetachedBackingData<Model: PersistentModel>: BackingData, AnyBackingData, @unchecked Sendable {
    private var values: [AnyKeyPath: Any] = [:]
    private var slotValues: [Any?]
    private let lock = NSRecursiveLock()
    private var identifier: PersistentIdentifier
    private let detachedIdentifier: PersistentIdentifier
    private let metadata: [Schema.PropertyMetadata]
    private weak var context: ModelContext?
    private weak var model: Model?
    private var contextState: ContextState?
    private var deleted = false
    private var changed = false
    private var onChange: (() -> Void)?

    /// Creates detached storage for a model's schema.
    public init(metadata: [Schema.PropertyMetadata]) {
        self.metadata = metadata
        slotValues = Array(repeating: nil, count: Model.propertyDescriptors.count)
        let detachedID = PersistentIdentifier(
            storeIdentifier: "OSD.Detached", entityName: String(describing: Model.self), temporaryIdentifier: UUID())
        identifier = detachedID
        detachedIdentifier = detachedID
        for property in metadata {
            guard let keyPath = property.keypath, let defaultValue = property.runtimeDefaultValue else { continue }
            values[keyPath] = defaultValue
            if let slot = Model.propertySlot(forKeyPath: keyPath), slotValues.indices.contains(slot) {
                slotValues[slot] = defaultValue
            }
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
        if let slot = Model.propertySlot(forKeyPath: keyPath) {
            return getValue(at: slot, forKey: keyPath)
        }
        lock.lock(); let stored = values[keyPath]; lock.unlock()
        if let value = stored as? Value { return value }
        return unassignedValue(for: keyPath)
    }
    /// Reads a stored value by its generated slot, or by key path when no slot exists.
    public func getValue<Value>(at slot: Int, forKey keyPath: KeyPath<Model, Value>) -> Value {
        lock.lock()
        let stored = (slotValues.indices.contains(slot) ? slotValues[slot] : nil) ?? values[keyPath]
        lock.unlock()
        if let value = stored as? Value { return value }
        return unassignedValue(for: keyPath)
    }
    /// Reads a value by key path without requiring its root to match the backing's model type.
    public func getValue<Value>(at slot: Int, keyPath: AnyKeyPath, as type: Value.Type) -> Value? {
        lock.lock()
        let stored = values[keyPath]
        lock.unlock()
        _ = slot
        return stored as? Value
    }
    /// Notifies the managing context before mutation; detached models receive no notification.
    public func willMutate() {
        lock.lock(); let state = contextState; let model = self.model; lock.unlock()
        guard let state, let model else { return }
        state.willMutate(model, snapshot: snapshot())
    }
    /// Performs a value write atomically with context mutation tracking.
    public func withMutation(_ write: () -> Void) {
        lock.lock(); let state = contextState; let model = self.model; lock.unlock()
        guard let state, let model else { write(); return }
        let didMutate = state.mutate(
            model,
            snapshot: { [weak self] in
                guard let self, self.modelContext?.state === state else { return nil }
                return self.snapshot()
            }, write: write)
        if !didMutate { write() }
    }
    /// Stores a value and marks the model changed when attached to a context.
    public func setValue<Value>(forKey keyPath: KeyPath<Model, Value>, to value: Value) {
        if let slot = Model.propertySlot(forKeyPath: keyPath) {
            setValue(at: slot, forKey: keyPath, to: value)
            return
        }
        lock.lock(); values[keyPath] = value as Any; if context != nil { changed = true }; lock.unlock()
    }
    /// Stores a value by its generated slot and keeps the key-path snapshot synchronized.
    public func setValue<Value>(at slot: Int, forKey keyPath: KeyPath<Model, Value>, to value: Value) {
        lock.lock()
        values[keyPath] = value as Any
        if slotValues.indices.contains(slot) { slotValues[slot] = value as Any }
        if context != nil { changed = true }
        lock.unlock()
    }
    /// Writes a value by key path without requiring its root to match the backing's model type.
    public func setValue<Value>(at slot: Int, keyPath: AnyKeyPath, to value: Value) -> Bool {
        lock.lock()
        values[keyPath] = value as Any
        if context != nil { changed = true }
        lock.unlock()
        _ = slot
        return true
    }
    /// Reports that this backing accepts key paths rooted at subclasses of its model type.
    public var supportsSubclassKeyPaths: Bool { true }
    /// Attaches this backing to any instance compatible with its model root.
    public func attach(to context: ModelContext, model: any PersistentModel) {
        guard let model = model as? Model else { return }
        attach(to: context, model: model)
    }
    /// Routes a relationship write through the context's resolved adapter table.
    public func mutateRelationship<Value>(
        forKey keyPath: KeyPath<Model, Value>,
        to value: Value,
        adapters: [any AnyRelationshipAdapterBox]
    ) -> Bool {
        lock.lock(); let state = contextState; let model = self.model; lock.unlock()
        guard let model else { return false }
        guard let state else {
            guard model.modelContext == nil else { return false }
            let adapter = adapters.first { $0.ownerType == ObjectIdentifier(Model.self) && $0.keyPath == keyPath }
            guard let adapter else { return false }
            do {
                try adapter.write(value, to: model)
            } catch {
                return true
            }
            return true
        }
        return state.mutateRelationship(model: model, keyPath: keyPath, value: value)
    }
    /// Notifies the managing context after mutation; detached models receive no notification.
    public func recordMutation() {
        lock.lock(); let state = contextState; let model = self.model; lock.unlock()
        guard let state, let model else { return }
        state.recordMutation(model)
    }
    func setChangeHandler(_ handler: @escaping () -> Void) { lock.lock(); onChange = handler; lock.unlock() }
    func notifyChange() { lock.lock(); let handler = onChange; lock.unlock(); handler?() }
    func setChangeHandlerForTesting(_ handler: @escaping () -> Void) {
        lock.lock(); onChange = handler; lock.unlock()
    }

    /// Captures property values and lifecycle state for later restoration.
    public func snapshot() -> BackingDataSnapshot {
        lock.lock(); defer { lock.unlock() }
        return BackingDataSnapshot(
            values: values, context: context, identifier: identifier, isDeleted: deleted, hasChanges: changed,
            savedValues: nil, primaryKey: identifier.primaryKey, entityID: nil, optimisticLockVersion: 0)
    }
    /// Restores property values, context, identifier, and lifecycle flags from a snapshot.
    public func restore(_ snapshot: BackingDataSnapshot) {
        lock.lock(); values = snapshot.values; context = snapshot.context; contextState = snapshot.context?.state;
        synchronizeSlots()
        identifier = snapshot.identifier
        deleted = snapshot.isDeleted; changed = snapshot.hasChanges; lock.unlock()
    }
    /// Restores property values without changing context or lifecycle state.
    public func restoreValues(_ snapshot: BackingDataSnapshot) {
        lock.lock(); values = snapshot.values; synchronizeSlots(); lock.unlock()
    }
    /// Restores snapshot values and detaches with detached lifecycle flags.
    public func restoreValuesAndDetach(_ snapshot: BackingDataSnapshot) {
        lock.lock(); values = snapshot.values; context = nil; contextState = nil; onChange = nil;
        synchronizeSlots()
        identifier = detachedIdentifier;
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
        lock.lock(); self.context = context; self.model = model; contextState = context.state; onChange = nil
        identifier = PersistentIdentifier(
            storeIdentifier: "OSD.InMemory.\(ObjectIdentifier(context))", entityName: String(describing: Model.self),
            temporaryIdentifier: identifier.temporaryIdentifier ?? UUID())
        deleted = false; lock.unlock()
    }

    /// Updates the identifier entity name for a model managed by a concrete hierarchy entity.
    public func setConcreteEntityName(_ entityName: String) {
        lock.lock()
        if let primaryKey = identifier.primaryKey {
            identifier = PersistentIdentifier(
                storeIdentifier: identifier.storeIdentifier, entityName: entityName, primaryKey: primaryKey)
        } else if let temporaryIdentifier = identifier.temporaryIdentifier {
            identifier = PersistentIdentifier(
                storeIdentifier: identifier.storeIdentifier,
                entityName: entityName,
                temporaryIdentifier: temporaryIdentifier)
        }
        lock.unlock()
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
        lock.lock(); context = nil; contextState = nil; onChange = nil; identifier = detachedIdentifier;
        changed = false; deleted = false;
        lock.unlock()
    }
    /// Removes the context association while retaining identifier, values, and deletion state.
    public func detachDeleted() { lock.lock(); context = nil; contextState = nil; onChange = nil; lock.unlock() }

    private func unassignedValue<Value>(for keyPath: KeyPath<Model, Value>) -> Value {
        if let optional = Value.self as? any _OptionalType.Type, let nilValue = optional.nilValue as? Value {
            return nilValue
        }
        let name = metadata.first { $0.keypath == keyPath }?.name ?? "unknown"
        fatalError("OSD: property '\(name)' of \(Model.self) was read before assignment")
    }

    private func synchronizeSlots() {
        for descriptor in Model.propertyDescriptors where slotValues.indices.contains(descriptor.slot) {
            slotValues[descriptor.slot] = values[descriptor.keyPath]
        }
    }
}

protocol _OptionalType { static var nilValue: Any { get } }
extension Optional: _OptionalType { static var nilValue: Any { Self.none as Any } }

public extension PersistentModel {
    /// Creates detached backing data initialized from schema defaults.
    static func createBackingData() -> DetachedBackingData<Model> { DetachedBackingData(metadata: schemaMetadata()) }
}

extension BackingData where Model: PersistentModel {
    func erasedBackingData() -> any AnyBackingData {
        ErasedBackingData(self)
    }
}

extension PersistentModel {
    var backingData: DetachedBackingData<Model>? { persistentBackingData as? DetachedBackingData<Model> }
}
