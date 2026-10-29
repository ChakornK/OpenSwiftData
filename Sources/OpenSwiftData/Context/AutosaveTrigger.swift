import Foundation
import Dispatch

package protocol AutosaveScheduler: Sendable {
    func schedule(after delay: Duration, _ action: @escaping @Sendable () -> Void) -> AutosaveCancellation
}

package protocol AutosaveCancellation: Sendable {
    func cancel()
}

package struct DispatchAutosaveScheduler: AutosaveScheduler {
    package init() {}

    package func schedule(after delay: Duration, _ action: @escaping @Sendable () -> Void) -> AutosaveCancellation {
        let item = DispatchWorkItem(block: action)
        let nanoseconds = delay.components.seconds * 1_000_000_000 + delay.components.attoseconds / 1_000_000_000
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds)), execute: item)
        return DispatchAutosaveWorkItem(item: item)
    }
}

private final class DispatchAutosaveWorkItem: AutosaveCancellation, @unchecked Sendable {
    let item: DispatchWorkItem
    init(item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

package final class AutosaveTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private let scheduler: any AutosaveScheduler
    private let delay: Duration
    private var cancellation: (any AutosaveCancellation)?
    private var generation: UInt64 = 0

    package init(scheduler: any AutosaveScheduler, delay: Duration = .milliseconds(100)) {
        self.scheduler = scheduler
        self.delay = delay
    }

    package func scheduleIfNeeded(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        guard cancellation == nil else {
            lock.unlock()
            return
        }
        generation &+= 1
        let scheduledGeneration = generation
        cancellation = scheduler.schedule(after: delay) { [weak self] in
            self?.fired(generation: scheduledGeneration)
            action()
        }
        lock.unlock()
    }

    private func fired(generation scheduledGeneration: UInt64) {
        lock.lock()
        if generation == scheduledGeneration { cancellation = nil }
        lock.unlock()
    }

    package func cancel() {
        lock.lock()
        let pending = cancellation
        cancellation = nil
        generation &+= 1
        lock.unlock()
        pending?.cancel()
    }
}

package final class AutosaveHandle: @unchecked Sendable {
    private let trigger: AutosaveTrigger
    private let lock = NSLock()
    private var enabled: Bool
    private let schedule: @Sendable () -> Void

    package init(trigger: AutosaveTrigger, enabled: Bool, schedule: @escaping @Sendable () -> Void) {
        self.trigger = trigger
        self.enabled = enabled
        self.schedule = schedule
    }

    package func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        if !value { trigger.cancel() }
        lock.unlock()
    }

    package func changed() {
        lock.lock()
        if enabled { trigger.scheduleIfNeeded(schedule) }
        lock.unlock()
    }

    package func cancel() { trigger.cancel() }
}

package final class AutosaveContextReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var context: ModelContext?

    package func set(_ context: ModelContext) {
        lock.lock()
        self.context = context
        lock.unlock()
    }

    package func withContext(_ body: (ModelContext) -> Void) {
        lock.lock()
        let context = self.context
        lock.unlock()
        if let context { body(context) }
    }
}
