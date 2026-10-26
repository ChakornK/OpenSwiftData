import Foundation
import OSDCore

/// A synchronous unit of work for inserting, fetching, and saving persistent models.
@MainActor
public final class ModelContext {
    /// The container that owns this context, when it was created by a container.
    public internal(set) var container: ModelContainer?
    /// Whether this context saves changes automatically.
    public var autosaveEnabled: Bool
    /// The undo manager associated with this context.
    public var undoManager: UndoManager?

    package nonisolated let state = ContextState()
    private let testSaveHook: (() throws -> Void)?
    private var allowsSave = true
    private let identityMap = IdentityMap()
    private var temporaryIdentifiers: [PersistentIdentifier: PersistentIdentifier] = [:]

    /// Creates a context not associated with a model container.
    public convenience init() {
        self.init(container: nil, autosaveEnabled: false)
    }

    package init(container: ModelContainer?, autosaveEnabled: Bool) {
        self.container = container
        self.autosaveEnabled = autosaveEnabled
        allowsSave = container?.configurations.first?.allowsSave ?? true
        testSaveHook = nil
    }

    internal init(testSave hook: @escaping () throws -> Void) {
        container = nil
        autosaveEnabled = false
        allowsSave = true
        testSaveHook = hook
    }

    /// Models inserted into this context and not yet saved.
    public var insertedModelsArray: [any PersistentModel] { state.insertedModels }
    /// Models changed in this context and not yet saved.
    public var changedModelsArray: [any PersistentModel] { state.changedModels }
    /// Models deleted in this context and not yet saved.
    public var deletedModelsArray: [any PersistentModel] { state.deletedModels }
    /// Compatibility alias for inserted models.
    public var insertedModels: [any PersistentModel] { insertedModelsArray }
    /// Compatibility alias for changed models.
    public var changedModels: [any PersistentModel] { changedModelsArray }
    /// Compatibility alias for deleted models.
    public var deletedModels: [any PersistentModel] { deletedModelsArray }
    /// Whether this context currently has unsaved changes.
    public var hasChanges: Bool {
        state.hasChanges
    }
    /// Sort descriptors used by this context.
    public var sortDescriptors: [NSSortDescriptor] = []

    /// Inserts a detached model into this context.
    public func insert<Model: PersistentModel>(_ model: Model) {
        state.withExclusiveOperation {
            guard model.modelContext == nil else { return }
            let snapshot = model.snapshotLifecycle()
            state.insert(model, snapshot: snapshot)
            model.persistentBackingData.attach(to: self, model: model)
            model.setInsertionChanged()
        }
    }

    /// Deletes a model or cancels its pending insertion.
    public func delete<Model: PersistentModel>(_ model: Model) {
        state.withExclusiveOperation {
            guard model.modelContext === self else { return }
            if state.containsInserted(model) {
                model.restoreValuesAndDetachLifecycle(state.cancelInsertion(model) ?? model.snapshotLifecycle())
                return
            }
            guard !state.containsDeleted(model) else { return }
            capture(model)
            model.persistentBackingData.markDeleted()
            state.markDeleted(model)
        }
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
        guard let store = container?.store else { throw unsupportedStore("Fetch") }
        _ = descriptor
        guard let entity = container?.schema.entity(forName: String(describing: Model.self)) else { return [] }
        let attributes = canonicalAttributes(for: entity)
        let columns = attributes.map { "Z\($0.name.uppercased())" }
        let selectColumns = (["Z_PK", "Z_OPT"] + columns).joined(separator: ", ")
        let rows = try store.read { connection in
            try connection.rows(
                "SELECT \(selectColumns) FROM Z\(entity.name.uppercased()) ORDER BY Z_PK ASC", arguments: [])
        }
        var models: [Model] = []
        for row in rows {
            guard row.count >= 2, case let .int(pk) = row[0], case let .int(version) = row[1] else { continue }
            let key = EntityPrimaryKey(entityName: entity.name, primaryKey: pk)
            if let existing = identityMap.model(for: key, as: Model.self) { models.append(existing); continue }
            let model = try materialize(
                Model.self, entity: entity, attributes: attributes, row: row, storeIdentifier: storeIdentifier,
                primaryKey: pk, version: Int(version))
            identityMap.register(model, for: key)
            models.append(model)
        }
        return models
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
        guard let key = identifier.primaryKey else {
            guard let permanent = temporaryIdentifiers[identifier] else { throw unsupportedStore("Model lookup") }
            return try model(for: permanent)
        }
        guard let container,
            identifier.storeIdentifier == storeIdentifier,
            let entity = container.schema.entity(forName: identifier.entityName),
            identifier.entityName == String(describing: Model.self),
            let modelEntity = container.schema.entity(forName: String(describing: Model.self)),
            modelEntity.name == entity.name
        else { throw unsupportedStore("Model lookup") }
        guard let store = container.store else { throw unsupportedStore("Model lookup") }
        if let registered: Model = registeredModel(for: identifier) { return registered }
        let attributes = canonicalAttributes(for: entity)
        let columns = attributes.map { "Z\($0.name.uppercased())" }.joined(separator: ", ")
        let rows = try store.read {
            try $0.rows(
                "SELECT Z_PK, Z_OPT, \(columns) FROM Z\(entity.name.uppercased()) WHERE Z_PK = ?",
                arguments: [.int(key)])
        }
        guard let row = rows.first else { return nil }
        let model = try materialize(
            Model.self, entity: entity, attributes: attributes, row: row, storeIdentifier: identifier.storeIdentifier,
            primaryKey: key, version: row.count > 1 ? runtimeInt(row[1]) : 0)
        identityMap.register(model, for: EntityPrimaryKey(entityName: entity.name, primaryKey: key))
        return model
    }

    /// Returns a registered model by its persistent identifier, if present.
    public func registeredModel<Model: PersistentModel>(for identifier: PersistentIdentifier) -> Model? {
        guard let container,
            identifier.primaryKey != nil,
            identifier.storeIdentifier == storeIdentifier,
            identifier.entityName == String(describing: Model.self),
            container.schema.entity(forName: identifier.entityName) != nil
        else { return nil }
        guard let key = identifier.primaryKey else { return nil }
        return identityMap.model(
            for: EntityPrimaryKey(entityName: identifier.entityName, primaryKey: key), as: Model.self)
    }

    /// Saves pending changes when a supported store is available.
    public func save() throws {
        try state.withExclusiveOperation {
            guard !state.hasTransaction else { return }
            if !allowsSave { throw unsupportedStore("Saving is disabled") }
            if let testSaveHook {
                try testSaveHook()
                finalizePendingChanges()
                return
            }
            guard let store = container?.store else { throw unsupportedStore("Saving") }
            guard allowsSave else { throw unsupportedStore("Saving is disabled") }
            try persistPendingChanges(to: store)
        }
    }

    /// Discards pending changes and restores values to their prior saved state.
    public func rollback() {
        state.withExclusiveOperation {
            let pendingState = state.pendingState()
            let pendingInsertions = pendingState.inserted
            for (model, snapshot) in pendingState.snapshots.values {
                if state.contains(model, in: pendingInsertions) {
                    model.restoreValuesAndDetachLifecycle(snapshot)
                } else {
                    model.restoreLifecycle(snapshot)
                }
            }
            for model in pendingInsertions where pendingState.snapshots[ObjectIdentifier(model)] == nil {
                cancelInsertion(model)
            }
            state.clearPending()
            for (model, snapshot) in pendingState.snapshots.values where !state.contains(model, in: pendingInsertions) {
                state.setBaseline(model, snapshot: snapshot)
            }
        }
    }

    /// Runs a block as an atomic unit of context work and saves on success.
    public func transaction<T>(block: () throws -> T) throws -> T {
        try state.withExclusiveOperation {
            let pending = state.pendingState()
            let entrySnapshots = Dictionary(
                uniqueKeysWithValues: (pending.inserted + pending.changed + pending.deleted).map {
                    (ObjectIdentifier($0), ($0, snapshot(of: $0)))
                }
            )
            state.beginTransaction(entrySnapshots: entrySnapshots)
            do {
                let result = try block()
                if state.transactionDepth == 1 {
                    if let testSaveHook {
                        try testSaveHook()
                        finalizePendingChanges()
                    } else {
                        guard let store = container?.store else { throw unsupportedStore("Saving") }
                        try persistPendingChanges(to: store)
                    }
                }
                state.popTransaction()
                return result
            } catch {
                rollbackCurrentTransaction()
                throw error
            }
        }
    }

    /// Captures a model before a property write so rollback can restore its prior values.
    package func willMutate<Model: PersistentModel>(_ model: Model) {
        guard model.modelContext === self else { return }
        state.willMutate(model, snapshot: model.snapshotLifecycle())
    }

    /// Records a property write as a pending change.
    package func recordMutation<Model: PersistentModel>(_ model: Model) {
        guard model.modelContext === self else { return }
        state.recordMutation(model)
    }

    private var storeIdentifier: String { container?.configurations.first?.name ?? "default" }

    private func canonicalAttributes(for entity: Schema.Entity) -> [Schema.Attribute] {
        entity.attributes.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }

    private func materialize<Model: PersistentModel>(
        _ type: Model.Type, entity: Schema.Entity, attributes: [Schema.Attribute], row: [RuntimeValue],
        storeIdentifier: String, primaryKey: Int64, version: Int
    ) throws -> Model {
        let backing = ManagedBackingData<Model>(
            metadata: Model.schemaMetadata(), values: [:], context: self,
            storeIdentifier: storeIdentifier, entityID: entityID(for: entity.name), primaryKey: primaryKey,
            version: version,
            identifier: PersistentIdentifier(
                storeIdentifier: storeIdentifier, entityName: entity.name, primaryKey: primaryKey))
        let model = Model(backingData: backing)
        let adapters = Model.persistenceAdapters()
        for (index, attribute) in attributes.enumerated() {
            guard index + 2 < row.count,
                let adapter = adapters.first(where: { $0.name == attribute.name })
            else { continue }
            let stored = storedValue(row[index + 2])
            try adapter.decode(stored, into: model)
        }
        backing.markSaved()
        backing.attach(to: self, model: model)
        return model
    }

    private func runtimeInt(_ value: RuntimeValue) -> Int {
        if case let .int(number) = value { return Int(number) }
        return 0
    }

    private func storedValue(_ value: RuntimeValue) -> StoredValue {
        switch value {
        case .null: .null
        case let .int(value): .int(value)
        case let .double(value): .double(value)
        case let .text(value): .text(value)
        case let .blob(value): .blob(value)
        }
    }

    private func runtimeValue(_ value: StoredValue) -> RuntimeValue {
        switch value {
        case .null: .null
        case let .int(value): .int(value)
        case let .double(value): .double(value)
        case let .text(value): .text(value)
        case let .blob(value): .blob(value)
        }
    }

    private func entityID(for name: String) -> Int {
        (container?.schema.entities.firstIndex(where: { $0.name == name }) ?? 0) + 1
    }

    private func persistPendingChanges(to store: any RuntimeStore) throws {
        let pending = state.pendingState()
        guard pending.relationshipMutationEvents.isEmpty else {
            throw SwiftDataError.unsupportedStore(
                "Saving relationship mutations is unavailable until relationship persistence is implemented."
            )
        }
        let models = pending.inserted + pending.changed
        let insertedIDs = Set(pending.inserted.map(ObjectIdentifier.init))
        let persisted: [(any PersistentModel, Int64)] = try store.write { connection in
            var results: [(any PersistentModel, Int64)] = []
            for model in models {
                try persistModel(
                    model, inserted: insertedIDs.contains(ObjectIdentifier(model)), connection: connection,
                    append: &results)
            }
            for model in pending.deleted {
                guard let pk = model.persistentModelID.primaryKey else { continue }
                try connection.execute(
                    "DELETE FROM Z\(model.persistentModelID.entityName.uppercased()) WHERE Z_PK = ?",
                    arguments: [.int(pk)])
                guard connection.changesCount() == 1 else {
                    throw SwiftDataError.unsupportedStore("Delete did not affect exactly one row.")
                }
            }
            return results
        }
        for model in pending.deleted {
            if let pk = model.persistentModelID.primaryKey {
                identityMap.remove(EntityPrimaryKey(entityName: model.persistentModelID.entityName, primaryKey: pk))
            }
        }
        for (model, pk) in persisted {
            let entityName = model.persistentModelID.entityName
            let originalIdentifier = state.snapshotIdentifier(for: model)
            model.markPersistedLifecycle(
                storeIdentifier: storeIdentifier, entityID: entityID(for: entityName), primaryKey: pk, version: 1)
            identityMap.register(model, for: EntityPrimaryKey(entityName: entityName, primaryKey: pk))
            if let old = originalIdentifier, old.isTemporary {
                temporaryIdentifiers[old] = model.persistentModelID
            }
        }
        finalizePendingChanges()
    }

    private func persistModel(
        _ model: any PersistentModel, inserted: Bool, connection: any RuntimeConnection,
        append: inout [(any PersistentModel, Int64)]
    ) throws {
        func typed<Model: PersistentModel>(_ model: Model) throws {
            guard let entity = container?.schema.entity(forName: String(describing: Model.self)) else { return }
            let adapters = Model.persistenceAdapters()
            var columns: [String] = []
            var values: [RuntimeValue] = []
            for attribute in canonicalAttributes(for: entity) {
                guard let adapter = adapters.first(where: { $0.name == attribute.name }) else { continue }
                columns.append("Z\(attribute.name.uppercased())")
                values.append(runtimeValue(try adapter.encoded(model)))
            }
            let table = "Z\(entity.name.uppercased())"
            if inserted {
                let names = (["Z_ENT", "Z_OPT"] + columns).joined(separator: ", ")
                let placeholders = Array(repeating: "?", count: columns.count + 2).joined(separator: ", ")
                try connection.execute(
                    "INSERT INTO \(table) (\(names)) VALUES (\(placeholders))",
                    arguments: [.int(Int64(entityID(for: entity.name))), .int(1)] + values)
                append.append((model, connection.lastInsertRowID()))
            } else if let pk = model.persistentModelID.primaryKey, !columns.isEmpty {
                let assignments = columns.map { "\($0) = ?" }.joined(separator: ", ")
                try connection.execute(
                    "UPDATE \(table) SET \(assignments), Z_OPT = Z_OPT + 1 WHERE Z_PK = ?",
                    arguments: values + [.int(pk)])
                guard connection.changesCount() == 1 else {
                    throw SwiftDataError.unsupportedStore("Update did not affect exactly one row.")
                }
                append.append((model, pk))
            }
        }
        func dispatch<Model: PersistentModel>(_ model: Model) throws { try typed(model) }
        try dispatch(model)
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
        state.willMutate(model, snapshot: model.snapshotLifecycle())
    }

    private func rollbackCurrentTransaction() {
        guard let frame = state.popTransactionSnapshot() else { return }
        let pending = state.pendingState()
        let currentModels = pending.inserted + pending.changed + pending.deleted
        let frameInsertions = frame.pending.inserted
        for (model, snapshot) in frame.modelSnapshots.values {
            if state.contains(model, in: frameInsertions) {
                model.restoreLifecycle(snapshot)
            } else {
                model.restoreValuesAndDetachLifecycle(snapshot)
            }
        }
        for model in currentModels
        where !state.contains(model, in: frame.pending.inserted)
            && !state.contains(model, in: frame.pending.changed)
            && !state.contains(model, in: frame.pending.deleted)
        {
            let identifier = ObjectIdentifier(model)
            if state.contains(model, in: pending.inserted), let insertionSnapshot = pending.snapshots[identifier] {
                model.restoreValuesAndDetachLifecycle(insertionSnapshot.1)
            } else if let entry = frame.snapshots[identifier] {
                model.restoreLifecycle(entry.1)
            } else if model.modelContext === self {
                detachModel(model)
            }
        }
        state.restorePendingState(frame.pending)
        state.restoreBaselineSnapshots(frame.baselineSnapshots)
    }

    private func finalizePendingChanges() {
        let pending = state.pendingState()
        for model in pending.inserted + pending.changed {
            model.markSavedLifecycle()
            state.setBaseline(model, snapshot: model.snapshotLifecycle())
        }
        for model in pending.deleted {
            model.detachDeletedLifecycle()
            model.markSavedLifecycle()
            state.removeBaseline(for: model)
        }
        state.clearPending()
    }

    private func cancelInsertion(_ model: any PersistentModel) {
        func cancelTyped<Model: PersistentModel>(_ model: Model) {
            model.persistentBackingData.cancelInsertion()
        }
        cancelTyped(model)
    }

    private func detachModel(_ model: any PersistentModel) {
        func detachTyped<Model: PersistentModel>(_ model: Model) {
            model.detachLifecycle()
        }
        detachTyped(model)
    }

}

/// Describes a model fetch request.
