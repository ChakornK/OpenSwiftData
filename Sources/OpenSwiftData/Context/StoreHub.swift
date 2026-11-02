import Foundation
import Synchronization

package struct StoreEntityKey: Hashable, Sendable {
    package let entityName: String
    package let primaryKey: Int64

    package init(entityName: String, primaryKey: Int64) {
        self.entityName = entityName
        self.primaryKey = primaryKey
    }
}

package struct ChangeSet: Sendable, Equatable {
    package let storeIdentifier: ObjectIdentifier
    package let sourceSubscription: UUID
    package let generation: UInt64
    package let allEntitiesChanged: Bool
    package let inserted: Set<StoreEntityKey>
    package let updated: Set<StoreEntityKey>
    package let deleted: Set<StoreEntityKey>

    package init(
        storeIdentifier: ObjectIdentifier,
        sourceSubscription: UUID,
        generation: UInt64,
        allEntitiesChanged: Bool = false,
        inserted: Set<StoreEntityKey> = [],
        updated: Set<StoreEntityKey> = [],
        deleted: Set<StoreEntityKey> = []
    ) {
        self.storeIdentifier = storeIdentifier
        self.sourceSubscription = sourceSubscription
        self.generation = generation
        self.allEntitiesChanged = allEntitiesChanged
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
    }
}

package final class ChangeInbox: @unchecked Sendable {
    private let bufferingLimit: Int
    private let lock = NSLock()
    private var changes: [ChangeSet] = []
    private var listeners: [UUID: AsyncStream<ChangeSet>.Continuation] = [:]
    private var listenersNeedingResync = Set<UUID>()
    private var isFinished = false

    package init(bufferingLimit: Int = 256) {
        precondition(bufferingLimit > 0)
        self.bufferingLimit = bufferingLimit
    }

    package func enqueue(_ change: ChangeSet) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        changes.append(change)
        for id in Array(listeners.keys) {
            guard let listener = listeners[id] else { continue }
            let event =
                listenersNeedingResync.contains(id)
                ? wildcard(for: change)
                : change
            switch listener.yield(event) {
            case .enqueued:
                listenersNeedingResync.remove(id)
            case .dropped:
                listenersNeedingResync.insert(id)
                let resync = listener.yield(wildcard(for: change))
                switch resync {
                case .enqueued, .dropped:
                    listenersNeedingResync.remove(id)
                case .terminated:
                    listeners.removeValue(forKey: id)
                    listenersNeedingResync.remove(id)
                @unknown default:
                    listenersNeedingResync.insert(id)
                }
            case .terminated:
                listeners.removeValue(forKey: id)
                listenersNeedingResync.remove(id)
            @unknown default:
                listenersNeedingResync.insert(id)
            }
        }
        lock.unlock()
    }

    private func wildcard(for change: ChangeSet) -> ChangeSet {
        ChangeSet(
            storeIdentifier: change.storeIdentifier,
            sourceSubscription: change.sourceSubscription,
            generation: change.generation,
            allEntitiesChanged: true)
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let listeners = Array(listeners.values)
        self.listeners.removeAll()
        listenersNeedingResync.removeAll()
        lock.unlock()
        for listener in listeners { listener.finish() }
    }

    func drain() -> [ChangeSet] {
        lock.lock()
        defer { lock.unlock() }
        let pending = changes
        changes.removeAll(keepingCapacity: true)
        return pending
    }

    package func updates() -> AsyncStream<ChangeSet> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferingLimit)) { continuation in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.finish()
                return
            }
            listeners[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeListener(id)
            }
        }
    }

    private func removeListener(_ id: UUID) {
        lock.lock()
        listeners.removeValue(forKey: id)
        listenersNeedingResync.remove(id)
        lock.unlock()
    }
}

final class StoreHub: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var subscribers: [UUID: WeakInbox] = [:]

    func subscribe(_ inbox: ChangeInbox) -> UUID {
        let id = UUID()
        lock.lock()
        subscribers[id] = WeakInbox(inbox)
        lock.unlock()
        return id
    }

    func unsubscribe(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }

    func publish(
        storeIdentifier: ObjectIdentifier,
        sourceSubscription: UUID,
        allEntitiesChanged: Bool = false,
        inserted: Set<StoreEntityKey>, updated: Set<StoreEntityKey>, deleted: Set<StoreEntityKey>
    ) {
        lock.lock()
        generation &+= 1
        let change = ChangeSet(
            storeIdentifier: storeIdentifier, sourceSubscription: sourceSubscription, generation: generation,
            allEntitiesChanged: allEntitiesChanged,
            inserted: inserted, updated: updated, deleted: deleted)
        var live: [ChangeInbox] = []
        subscribers = subscribers.filter { _, subscriber in
            guard let inbox = subscriber.value else { return false }
            live.append(inbox)
            return true
        }
        live.forEach { $0.enqueue(change) }
        lock.unlock()
    }

    private final class WeakInbox: @unchecked Sendable {
        weak var value: ChangeInbox?

        init(_ value: ChangeInbox) {
            self.value = value
        }
    }
}

enum StoreHubRegistry {
    private static let sharedHub = StoreHub()
    static func hub() -> StoreHub {
        sharedHub
    }
}

final class StoreIdentityHandle: @unchecked Sendable {
}
