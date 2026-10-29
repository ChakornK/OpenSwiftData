import Foundation
import Synchronization

struct StoreEntityKey: Hashable, Sendable {
    let entityName: String
    let primaryKey: Int64
}

struct ChangeSet: Sendable, Equatable {
    let storeIdentifier: ObjectIdentifier
    let sourceSubscription: UUID
    let generation: UInt64
    let allEntitiesChanged: Bool
    let inserted: Set<StoreEntityKey>
    let updated: Set<StoreEntityKey>
    let deleted: Set<StoreEntityKey>
}

final class ChangeInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [ChangeSet] = []

    func enqueue(_ change: ChangeSet) {
        lock.lock()
        changes.append(change)
        lock.unlock()
    }

    func drain() -> [ChangeSet] {
        lock.lock()
        defer { lock.unlock() }
        let pending = changes
        changes.removeAll(keepingCapacity: true)
        return pending
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
        lock.unlock()
        live.forEach { $0.enqueue(change) }
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
