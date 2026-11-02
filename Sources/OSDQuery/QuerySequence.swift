import Foundation
import OpenSwiftData

/// A result change emitted after a relevant store change.
public struct QueryUpdate: Sendable, Equatable {
    /// The store change generation that triggered this refresh, or zero for the initial snapshot.
    public let generation: UInt64
    /// Whether `identifiers` is authoritative. A refresh may include commits newer than `generation`.
    public let isFullSnapshot: Bool
    /// Identifiers newly present in the refreshed query result.
    public let inserted: Set<PersistentIdentifier>
    /// Identifiers still present whose models changed in the store.
    public let updated: Set<PersistentIdentifier>
    /// Identifiers removed from the refreshed query result.
    public let deleted: Set<PersistentIdentifier>
    /// The complete identifiers in the refreshed query result.
    public let identifiers: [PersistentIdentifier]

    package init(
        generation: UInt64,
        isFullSnapshot: Bool,
        inserted: Set<PersistentIdentifier>,
        updated: Set<PersistentIdentifier>,
        deleted: Set<PersistentIdentifier>,
        identifiers: [PersistentIdentifier]
    ) {
        self.generation = generation
        self.isFullSnapshot = isFullSnapshot
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
        self.identifiers = identifiers
    }
}

/// An asynchronous sequence of identifier snapshots for a query.
///
/// The refresh closure runs in the iterator's execution context. Create and consume the sequence
/// on the executor that owns any context used by the closure. Each iterator observes changes
/// independently and should be cancelled or released when its consumer stops observing.
public struct QuerySequence: AsyncSequence {
    /// The identifier diff and refreshed identifier snapshot emitted after a relevant change.
    public typealias Element = QueryUpdate
    /// Errors thrown by the query refresh closure.
    public typealias Failure = any Error

    /// Advances through query updates, performing a refresh on the consuming executor.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private var changes: AsyncStream<ChangeSet>.Iterator
        private let storeIdentifier: ObjectIdentifier
        private let dependencyEntityNames: Set<String>
        private let resultEntityNames: Set<String>
        private let executor: ModelContextQueryExecutor?
        private let refresh: () throws -> [PersistentIdentifier]
        private var current: [PersistentIdentifier]?
        private var isTerminated = false

        fileprivate init(
            changes: ChangeInbox,
            storeIdentifier: ObjectIdentifier,
            dependencyEntityNames: Set<String>,
            resultEntityNames: Set<String>,
            executor: ModelContextQueryExecutor?,
            refresh: @escaping () throws -> [PersistentIdentifier]
        ) {
            self.changes = changes.updates().makeAsyncIterator()
            self.storeIdentifier = storeIdentifier
            self.dependencyEntityNames = dependencyEntityNames
            self.resultEntityNames = resultEntityNames
            self.executor = executor
            self.refresh = refresh
        }

        /// Returns the initial result snapshot or the next relevant identifier diff.
        public mutating func next(isolation actor: isolated (any Actor)? = #isolation) async throws -> QueryUpdate? {
            guard !isTerminated else { return nil }
            try Task.checkCancellation()
            if current == nil {
                do {
                    executor?.assertCurrent()
                    let identifiers = try refresh()
                    current = identifiers
                    return QueryUpdate(
                        generation: 0,
                        isFullSnapshot: true,
                        inserted: Set(identifiers),
                        updated: [],
                        deleted: [],
                        identifiers: identifiers)
                } catch {
                    isTerminated = true
                    throw error
                }
            }

            while let change = await changes.next(isolation: actor) {
                try Task.checkCancellation()
                guard change.storeIdentifier == storeIdentifier else { continue }
                let relevant =
                    change.allEntitiesChanged
                    || !changedEntityNames(in: change).isDisjoint(with: dependencyEntityNames)
                guard relevant else { continue }

                let identifiers: [PersistentIdentifier]
                do {
                    executor?.assertCurrent()
                    identifiers = try refresh()
                } catch {
                    isTerminated = true
                    throw error
                }
                let oldIdentifiers = Set(current ?? [])
                let newIdentifiers = Set(identifiers)
                let inserted = newIdentifiers.subtracting(oldIdentifiers)
                let deleted = oldIdentifiers.subtracting(newIdentifiers)
                let changedKeys = change.updated
                let changedResultKeys = Set(changedKeys.filter { resultEntityNames.contains($0.entityName) })
                let changedDependencyOnly = changedKeys.contains { !resultEntityNames.contains($0.entityName) }
                let fullSnapshot = true
                let updated =
                    change.allEntitiesChanged || changedDependencyOnly
                    ? newIdentifiers
                    : Set(
                        identifiers.filter { identifier in
                            guard let primaryKey = identifier.primaryKey else { return false }
                            return !inserted.contains(identifier)
                                && changedResultKeys.contains(
                                    StoreEntityKey(entityName: identifier.entityName, primaryKey: primaryKey))
                        })
                current = identifiers

                guard !inserted.isEmpty || !updated.isEmpty || !deleted.isEmpty || fullSnapshot else {
                    continue
                }
                return QueryUpdate(
                    generation: change.generation,
                    isFullSnapshot: fullSnapshot,
                    inserted: inserted,
                    updated: updated,
                    deleted: deleted,
                    identifiers: identifiers)
            }
            try Task.checkCancellation()
            isTerminated = true
            return nil
        }
    }

    private let changes: ChangeInbox
    private let storeIdentifier: ObjectIdentifier
    private let dependencyEntityNames: Set<String>
    private let resultEntityNames: Set<String>
    private let executor: ModelContextQueryExecutor?
    private let refresh: () throws -> [PersistentIdentifier]

    /// Creates a query sequence for a SQLite-backed context.
    /// Include the root entity and every entity whose changes can affect the predicate or ordering.
    public init(
        context: ModelContext,
        dependencyEntityNames: Set<String>,
        resultEntityNames: Set<String>,
        refresh: @escaping () throws -> [PersistentIdentifier]
    ) throws {
        let source = try context.queryChangeSource()
        self.init(
            changes: source.changes,
            storeIdentifier: source.storeIdentifier,
            dependencyEntityNames: dependencyEntityNames,
            resultEntityNames: resultEntityNames,
            executor: source.executor,
            refresh: refresh)
    }

    package init(
        changes: ChangeInbox,
        storeIdentifier: ObjectIdentifier,
        dependencyEntityNames: Set<String>,
        resultEntityNames: Set<String>,
        executor: ModelContextQueryExecutor? = nil,
        refresh: @escaping () throws -> [PersistentIdentifier]
    ) {
        self.changes = changes
        self.storeIdentifier = storeIdentifier
        self.dependencyEntityNames = dependencyEntityNames
        self.resultEntityNames = resultEntityNames
        self.executor = executor
        self.refresh = refresh
    }

    /// Creates an iterator with an independent subscription to the context's change source.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            changes: changes,
            storeIdentifier: storeIdentifier,
            dependencyEntityNames: dependencyEntityNames,
            resultEntityNames: resultEntityNames,
            executor: executor,
            refresh: refresh)
    }
}

private func changedEntityNames(in change: ChangeSet) -> Set<String> {
    Set((change.inserted.union(change.updated).union(change.deleted)).map(\.entityName))
}
