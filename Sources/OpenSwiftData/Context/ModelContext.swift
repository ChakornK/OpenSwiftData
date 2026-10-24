import Foundation

/// A synchronous unit of work for inserting, fetching, and saving persistent models.
@MainActor
public final class ModelContext {
    /// The container that owns this context, when it was created by a container.
    public internal(set) var container: ModelContainer?
    /// Whether this context saves changes automatically.
    public var autosaveEnabled: Bool
    /// The undo manager associated with this context.
    public var undoManager: UndoManager?

    private struct PendingState {
        var inserted: [any PersistentModel]
        var changed: [any PersistentModel]
        var deleted: [any PersistentModel]
        var snapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)]
    }

    private struct TransactionFrame {
        var pending: PendingState
        var snapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)]
        var baselineSnapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)]
        var modelSnapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)]
    }

    private var insertedModelsStorage: [any PersistentModel] = []
    private var changedModelsStorage: [any PersistentModel] = []
    private var deletedModelsStorage: [any PersistentModel] = []
    private var snapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)] = [:]
    private var baselineSnapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)] = [:]
    private var transactionFrames: [TransactionFrame] = []
    private let testSaveHook: (() throws -> Void)?

    /// Creates a context not associated with a model container.
    public convenience init() {
        self.init(container: nil, autosaveEnabled: false)
    }

    package init(container: ModelContainer?, autosaveEnabled: Bool) {
        self.container = container
        self.autosaveEnabled = autosaveEnabled
        testSaveHook = nil
    }

    internal init(testSave hook: @escaping () throws -> Void) {
        container = nil
        autosaveEnabled = false
        testSaveHook = hook
    }

    /// Models inserted into this context and not yet saved.
    public var insertedModelsArray: [any PersistentModel] { insertedModelsStorage }
    /// Models changed in this context and not yet saved.
    public var changedModelsArray: [any PersistentModel] { changedModelsStorage }
    /// Models deleted in this context and not yet saved.
    public var deletedModelsArray: [any PersistentModel] { deletedModelsStorage }
    /// Compatibility alias for inserted models.
    public var insertedModels: [any PersistentModel] { insertedModelsArray }
    /// Compatibility alias for changed models.
    public var changedModels: [any PersistentModel] { changedModelsArray }
    /// Compatibility alias for deleted models.
    public var deletedModels: [any PersistentModel] { deletedModelsArray }
    /// Whether this context currently has unsaved changes.
    public var hasChanges: Bool {
        !insertedModelsStorage.isEmpty || !changedModelsStorage.isEmpty || !deletedModelsStorage.isEmpty
    }
    /// Sort descriptors used by this context.
    public var sortDescriptors: [NSSortDescriptor] = []

    /// Inserts a detached model into this context.
    public func insert<Model: PersistentModel>(_ model: Model) {
        guard model.modelContext == nil else { return }
        let identifier = ObjectIdentifier(model)
        let snapshot = model.snapshotLifecycle()
        for index in transactionFrames.indices where transactionFrames[index].snapshots[identifier] == nil {
            transactionFrames[index].snapshots[identifier] = (model, snapshot)
        }
        for index in transactionFrames.indices where transactionFrames[index].modelSnapshots[identifier] == nil {
            transactionFrames[index].modelSnapshots[identifier] = (model, snapshot)
        }
        model.persistentBackingData.attach(to: self, model: model)
        snapshots[identifier] = (model, snapshot)
        appendUnique(model, to: &insertedModelsStorage)
    }

    /// Deletes a model or cancels its pending insertion.
    public func delete<Model: PersistentModel>(_ model: Model) {
        guard model.modelContext === self else { return }
        let identifier = ObjectIdentifier(model)
        if contains(model, in: insertedModelsStorage) {
            model.restoreValuesAndDetachLifecycle(snapshots[identifier]?.1 ?? model.snapshotLifecycle())
            remove(model, from: &insertedModelsStorage)
            remove(model, from: &changedModelsStorage)
            snapshots.removeValue(forKey: identifier)
            return
        }
        guard !contains(model, in: deletedModelsStorage) else { return }
        capture(model)
        model.persistentBackingData.markDeleted()
        remove(model, from: &changedModelsStorage)
        appendUnique(model, to: &deletedModelsStorage)
    }

    /// Deletes models matching a predicate, which requires a persistent store.
    public func delete<Model: PersistentModel>(
        model: Model.Type,
        where predicate: Predicate<Model>,
        includeSubclasses: Bool = true
    ) throws {
        _ = (model, predicate, includeSubclasses)
        throw unsupportedStore("Predicate-based delete")
    }

    /// Fetches models matching a descriptor, which requires a persistent store.
    public func fetch<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) throws -> [Model] {
        _ = descriptor
        throw unsupportedStore("Fetch")
    }

    /// Counts models matching a descriptor, which requires a persistent store.
    public func fetchCount<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) throws -> Int {
        _ = descriptor
        throw unsupportedStore("Fetch count")
    }

    /// Fetches identifiers matching a descriptor, which requires a persistent store.
    public func fetchIdentifiers<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>
    ) throws -> [PersistentIdentifier] {
        _ = descriptor
        throw unsupportedStore("Identifier fetch")
    }

    /// Enumerates models matching a descriptor, which requires a persistent store.
    public func enumerate<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>,
        batchSize: Int = 500,
        allowEscapingMutations: Bool = false,
        block: (Model) throws -> Void
    ) throws {
        _ = (descriptor, batchSize, allowEscapingMutations, block)
        throw unsupportedStore("Enumeration")
    }

    /// Finds a model by its persistent identifier, which requires a persistent store.
    public func model<Model: PersistentModel>(for identifier: PersistentIdentifier) throws -> Model? {
        _ = identifier
        throw unsupportedStore("Model lookup")
    }

    /// Returns a registered model by its persistent identifier, if present.
    public func registeredModel<Model: PersistentModel>(for identifier: PersistentIdentifier) -> Model? {
        _ = identifier
        return nil
    }

    /// Saves pending changes when a supported store is available.
    public func save() throws {
        guard transactionFrames.isEmpty else { return }
        guard let testSaveHook else { throw unsupportedStore("Saving") }
        try testSaveHook()
        finalizePendingChanges()
    }

    /// Discards pending changes and restores values to their prior saved state.
    public func rollback() {
        let pendingInsertions = insertedModelsStorage
        for (model, snapshot) in snapshots.values {
            if contains(model, in: pendingInsertions) {
                model.restoreValuesAndDetachLifecycle(snapshot)
            } else {
                model.restoreLifecycle(snapshot)
            }
        }
        for model in pendingInsertions where snapshots[ObjectIdentifier(model)] == nil {
            cancelInsertion(model)
        }
        insertedModelsStorage.removeAll()
        changedModelsStorage.removeAll()
        deletedModelsStorage.removeAll()
        snapshots.removeAll()
    }

    /// Runs a block as an atomic unit of context work and saves on success.
    public func transaction<T>(block: () throws -> T) throws -> T {
        let pending = pendingState()
        let entrySnapshots = Dictionary(
            uniqueKeysWithValues: (pending.inserted + pending.changed + pending.deleted).map {
                (ObjectIdentifier($0), ($0, snapshot(of: $0)))
            }
        )
        transactionFrames.append(
            TransactionFrame(
                pending: pending,
                snapshots: [:],
                baselineSnapshots: baselineSnapshots,
                modelSnapshots: entrySnapshots
            ))
        do {
            let result = try block()
            if transactionFrames.count == 1 {
                guard let testSaveHook else { throw unsupportedStore("Saving") }
                try testSaveHook()
                finalizePendingChanges()
            }
            transactionFrames.removeLast()
            return result
        } catch {
            rollbackCurrentTransaction()
            throw error
        }
    }

    /// Captures a model before a property write so rollback can restore its prior values.
    package func willMutate<Model: PersistentModel>(_ model: Model) {
        guard model.modelContext === self else { return }
        capture(model)
    }

    /// Records a property write as a pending change.
    package func recordMutation<Model: PersistentModel>(_ model: Model) {
        guard model.modelContext === self,
            !contains(model, in: insertedModelsStorage),
            !contains(model, in: deletedModelsStorage)
        else { return }
        appendUnique(model, to: &changedModelsStorage)
    }

    private func unsupportedStore(_ operation: String) -> SwiftDataError {
        .unsupportedStore("\(operation) is unavailable without a persistent store.")
    }

    private func snapshot(of model: any PersistentModel) -> BackingDataSnapshot {
        func snapshotTyped<Model: PersistentModel>(_ model: Model) -> BackingDataSnapshot {
            model.snapshotLifecycle()
        }
        return snapshotTyped(model)
    }

    private func capture<Model: PersistentModel>(_ model: Model) {
        let identifier = ObjectIdentifier(model)
        let current = model.snapshotLifecycle()
        for index in transactionFrames.indices where transactionFrames[index].modelSnapshots[identifier] == nil {
            transactionFrames[index].modelSnapshots[identifier] = (model, current)
        }
        if snapshots[identifier] == nil {
            snapshots[identifier] = (model, baselineSnapshots[identifier]?.1 ?? current)
        }
        for index in transactionFrames.indices where transactionFrames[index].snapshots[identifier] == nil {
            transactionFrames[index].snapshots[identifier] = (model, current)
        }
    }

    private func pendingState() -> PendingState {
        PendingState(
            inserted: insertedModelsStorage,
            changed: changedModelsStorage,
            deleted: deletedModelsStorage,
            snapshots: snapshots
        )
    }

    private func restorePendingState(_ state: PendingState) {
        insertedModelsStorage = state.inserted
        changedModelsStorage = state.changed
        deletedModelsStorage = state.deleted
        snapshots = state.snapshots
    }

    private func rollbackCurrentTransaction() {
        guard let frame = transactionFrames.popLast() else { return }
        let currentModels = insertedModelsStorage + changedModelsStorage + deletedModelsStorage
        let frameInsertions = frame.pending.inserted
        for (model, snapshot) in frame.modelSnapshots.values {
            if contains(model, in: frameInsertions) {
                model.restoreLifecycle(snapshot)
            } else {
                model.restoreValuesAndDetachLifecycle(snapshot)
            }
        }
        for model in currentModels
        where !contains(model, in: frame.pending.inserted)
            && !contains(model, in: frame.pending.changed)
            && !contains(model, in: frame.pending.deleted)
        {
            let identifier = ObjectIdentifier(model)
            if contains(model, in: insertedModelsStorage), let insertionSnapshot = snapshots[identifier] {
                model.restoreValuesAndDetachLifecycle(insertionSnapshot.1)
            } else if let entry = frame.snapshots[identifier] {
                model.restoreLifecycle(entry.1)
            } else if model.modelContext === self {
                detachModel(model)
            }
        }
        restorePendingState(frame.pending)
        baselineSnapshots = frame.baselineSnapshots
    }

    private func finalizePendingChanges() {
        for model in insertedModelsStorage + changedModelsStorage {
            model.markSavedLifecycle()
            baselineSnapshots[ObjectIdentifier(model)] = (model, model.snapshotLifecycle())
        }
        for model in deletedModelsStorage {
            model.detachDeletedLifecycle()
            model.markSavedLifecycle()
            baselineSnapshots.removeValue(forKey: ObjectIdentifier(model))
        }
        insertedModelsStorage.removeAll()
        changedModelsStorage.removeAll()
        deletedModelsStorage.removeAll()
        snapshots.removeAll()
    }

    private func cancelInsertion<Model: PersistentModel>(_ model: Model) {
        model.persistentBackingData.cancelInsertion()
    }

    private func detachModel(_ model: any PersistentModel) {
        func detachTyped<Model: PersistentModel>(_ model: Model) {
            model.detachLifecycle()
        }
        detachTyped(model)
    }

    private func contains<Model: PersistentModel>(_ model: Model, in models: [any PersistentModel]) -> Bool {
        models.contains { $0 === model }
    }

    private func appendUnique<Model: PersistentModel>(_ model: Model, to models: inout [any PersistentModel]) {
        if !contains(model, in: models) { models.append(model) }
    }

    private func remove<Model: PersistentModel>(_ model: Model, from models: inout [any PersistentModel]) {
        models.removeAll { $0 === model }
    }
}

/// Describes a model fetch request.
