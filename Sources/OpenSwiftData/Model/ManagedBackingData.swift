import Foundation
import OSDCore

/// An immutable database row snapshot with a copy-on-write overlay for edited attributes.
public final class ManagedBackingData<Model: PersistentModel>: BackingData, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let metadata: [Schema.PropertyMetadata]
    private var baseline: [AnyKeyPath: Any]
    private var overlay: [AnyKeyPath: Any] = [:]
    private var context: ModelContext?
    private var contextState: ContextState?
    private weak var model: Model?
    private var identifier: PersistentIdentifier
    private var deleted = false
    private var changed = false
    private var storeIdentifier: String
    private let detachedIdentifier: PersistentIdentifier
    private var entityID: Int
    private var primaryKey: Int64?
    private var version: Int
    /// Creates managed storage for a row snapshot.
    public init(
        metadata: [Schema.PropertyMetadata],
        values: [AnyKeyPath: Any],
        context: ModelContext,
        storeIdentifier: String,
        entityID: Int,
        primaryKey: Int64? = nil,
        version: Int = 0,
        identifier: PersistentIdentifier
    ) {
        self.metadata = metadata
        baseline = values
        self.context = context
        contextState = context.state
        self.storeIdentifier = storeIdentifier
        self.entityID = entityID
        self.primaryKey = primaryKey
        self.version = version
        self.identifier = identifier
        detachedIdentifier = PersistentIdentifier(
            storeIdentifier: "OSD.Detached", entityName: String(describing: Model.self),
            temporaryIdentifier: identifier.temporaryIdentifier ?? UUID())
    }

    /// The model's persistent identifier.
    public var persistentModelID: PersistentIdentifier { locked { identifier } }
    /// The context managing this model, if any.
    public var modelContext: ModelContext? { locked { context } }
    /// Whether the model has been deleted.
    public var isDeleted: Bool { locked { deleted } }
    /// Whether the model has unsaved changes.
    public var hasChanges: Bool { locked { changed } }

    /// Reads the current value from the dirty overlay or immutable row snapshot.
    public func getValue<Value>(forKey keyPath: KeyPath<Model, Value>) -> Value {
        lock.lock()
        let value = overlay[keyPath] ?? baseline[keyPath]
        lock.unlock()
        if let value = value as? Value { return value }
        if let optional = Value.self as? any _OptionalType.Type, let nilValue = optional.nilValue as? Value {
            return nilValue
        }
        let name = metadata.first { $0.keypath == keyPath }?.name ?? "unknown"
        fatalError("OSD: property '\(name)' of \(Model.self) was read before assignment")
    }

    /// Captures the model before a mutation.
    public func willMutate() {
        guard let state = locked({ contextState }), let model = locked({ model }) else { return }
        state.willMutate(model, snapshot: snapshot())
    }

    /// Performs a value write atomically with context mutation tracking.
    public func withMutation(_ write: () -> Void) {
        guard let state = locked({ contextState }), let model = locked({ model }) else { write(); return }
        let didMutate = state.mutate(
            model,
            snapshot: { [weak self] in
                guard let self, self.modelContext?.state === state else { return nil }
                return self.snapshot()
            }, write: write)
        if !didMutate { write() }
    }

    /// Writes a value into the dirty overlay.
    public func setValue<Value>(forKey keyPath: KeyPath<Model, Value>, to value: Value) {
        locked {
            overlay[keyPath] = value
            changed = true
        }
    }

    func setInitialValue(forKey keyPath: AnyKeyPath, to value: Any) {
        locked { baseline[keyPath] = value }
    }

    /// Records the mutation in the owning context.
    public func recordMutation() {
        guard let state = locked({ contextState }), let model = locked({ model }) else { return }
        state.recordMutation(model)
    }

    /// Captures the current values and lifecycle state.
    public func snapshot() -> BackingDataSnapshot {
        locked {
            BackingDataSnapshot(
                values: mergedValues(), context: context, identifier: identifier,
                isDeleted: deleted, hasChanges: changed, savedValues: baseline,
                primaryKey: primaryKey, entityID: entityID, optimisticLockVersion: version
            )
        }
    }

    /// Restores values and lifecycle state from a snapshot.
    public func restore(_ snapshot: BackingDataSnapshot) {
        locked {
            baseline = snapshot.savedValues ?? snapshot.values
            overlay = snapshot.savedValues == nil ? [:] : Self.difference(snapshot.values, baseline)
            context = snapshot.context
            contextState = snapshot.context?.state
            identifier = snapshot.identifier
            deleted = snapshot.isDeleted
            changed = snapshot.hasChanges
            primaryKey = snapshot.primaryKey
            entityID = snapshot.entityID ?? entityID
            version = snapshot.optimisticLockVersion
        }
    }

    /// Restores values without changing lifecycle flags.
    public func restoreValues(_ snapshot: BackingDataSnapshot) {
        locked { overlay = Self.difference(snapshot.values, baseline) }
    }

    /// Restores values and detaches a canceled insertion.
    public func restoreValuesAndDetach(_ snapshot: BackingDataSnapshot) { restoreLifecycleAndDetach(snapshot) }
    /// Restores this model to its detached lifecycle without changing values.
    public func restoreValuesAndDetach() { detach() }
    /// Restores values and detaches this model.
    public func restoreLifecycleAndDetach(_ snapshot: BackingDataSnapshot) {
        locked {
            baseline = snapshot.values
            overlay.removeAll()
            context = nil
            contextState = nil
            identifier = detachedIdentifier
            deleted = false
            changed = false
            storeIdentifier = detachedIdentifier.storeIdentifier
            primaryKey = nil
            entityID = 0
            version = 0
        }
    }
    /// Restores values and detaches a canceled insertion.
    public func cancelInsertion(restoring snapshot: BackingDataSnapshot) { restoreLifecycleAndDetach(snapshot) }
    /// Replaces the temporary identity with the committed row identity.
    public func markPersisted(storeIdentifier: String, entityID: Int, primaryKey: Int64, version: Int) {
        locked {
            baseline = mergedValues()
            overlay.removeAll()
            self.storeIdentifier = storeIdentifier
            self.entityID = entityID
            self.primaryKey = primaryKey
            self.version = version
            identifier = PersistentIdentifier(
                storeIdentifier: storeIdentifier, entityName: String(describing: Model.self), primaryKey: primaryKey)
            changed = false
            deleted = false
        }
    }
    /// Attaches the backing data to a context and model.
    public func attach(to context: ModelContext, model: Model) {
        locked {
            self.context = context
            contextState = context.state
            self.model = model
            identifier = PersistentIdentifier(
                storeIdentifier: storeIdentifier, entityName: String(describing: Model.self),
                temporaryIdentifier: identifier.temporaryIdentifier ?? UUID())
            deleted = false
        }
    }

    /// Routes a relationship write through the context's resolved adapter table.
    public func mutateRelationship<Value>(
        forKey keyPath: KeyPath<Model, Value>,
        to value: Value,
        adapters: [any AnyRelationshipAdapterBox]
    ) -> Bool {
        let model = locked { self.model }
        guard let model else { return false }
        guard let state = locked({ contextState }) else { return false }
        return state.mutateRelationship(model: model, keyPath: keyPath, value: value)
    }
    /// Marks this model as deleted.
    public func markDeleted() {
        locked {
            deleted = true; changed = true
        }
    }
    /// Marks an insertion as changed without marking it deleted.
    public func restoreInsertionState() {
        locked {
            deleted = false; changed = true
        }
    }
    /// Detaches a canceled insertion.
    public func cancelInsertion() { detach() }
    /// Marks the model saved.
    public func markSaved() {
        locked {
            baseline = mergedValues(); overlay.removeAll(); changed = false; deleted = false
        }
    }
    /// Detaches the model and restores detached identity.
    public func detach() {
        locked {
            context = nil
            contextState = nil
            identifier = detachedIdentifier
            deleted = false
            changed = false
            storeIdentifier = detachedIdentifier.storeIdentifier
            primaryKey = nil
            entityID = 0
            version = 0
        }
    }
    /// Detaches a deleted model while retaining its identity, values, and deletion state.
    public func detachDeleted() {
        locked {
            context = nil; contextState = nil; deleted = true; changed = false
        }
    }

    var persistedValues: [AnyKeyPath: Any] { locked { mergedValues() } }
    var storedPrimaryKey: Int64? { locked { primaryKey } }
    var storedEntityID: Int { locked { entityID } }
    var storedVersion: Int { locked { version } }

    private func mergedValues() -> [AnyKeyPath: Any] { baseline.merging(overlay) { _, new in new } }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private static func difference(_ values: [AnyKeyPath: Any], _ baseline: [AnyKeyPath: Any]) -> [AnyKeyPath: Any] {
        values.filter { key, value in
            guard let old = baseline[key] else { return true }
            return String(reflecting: type(of: value)) != String(reflecting: type(of: old))
                || String(describing: value) != String(describing: old)
        }
    }
}
