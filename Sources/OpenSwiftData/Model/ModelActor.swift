import Dispatch
import Foundation

/// An executor that provides the serial execution context for a model actor.
public protocol ModelExecutor: AnyObject, Sendable {
    /// The context managed by this executor.
    var modelContext: ModelContext { get }
}

/// A serial executor that owns one model context.
public final class DefaultSerialModelExecutor: ModelExecutor, SerialExecutor, @unchecked Sendable {
    /// The context serialized by this executor.
    public var modelContext: ModelContext { contextHolder.context }
    private let queue: DispatchQueue
    private let affinityToken: ModelExecutorAffinityToken
    private let contextHolder: ModelExecutorContextHolder

    /// Creates a serial model executor for a context.
    package init(affinityToken: ModelExecutorAffinityToken, contextHolder: ModelExecutorContextHolder) {
        self.queue = affinityToken.queue
        self.affinityToken = affinityToken
        self.contextHolder = contextHolder
    }

    package static func make(container: ModelContainer) -> DefaultSerialModelExecutor {
        let queue = DispatchQueue(label: "OpenSwiftData.ModelActor.\(UUID().uuidString)")
        let token = ModelExecutorAffinityToken(queue: queue)
        let holder = ModelExecutorContextHolder()
        let executor = DefaultSerialModelExecutor(affinityToken: token, contextHolder: holder)
        let context = ModelContext(container: container, autosaveEnabled: false, affinityToken: token)
        holder.context = context
        return executor
    }

    /// Enqueues an actor job on the executor's serial queue.
    public func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        queue.async { [self] in
            unownedJob.runSynchronously(on: asUnownedSerialExecutor())
        }
    }

    /// Returns this executor in the representation required by Swift concurrency.
    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Traps if the current execution is not on this executor's serial queue.
    public func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

}

package final class ModelExecutorContextHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedContext: ModelContext?
    var context: ModelContext {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let storedContext else { preconditionFailure("ModelActor context is not initialized") }
            return storedContext
        }
        set {
            lock.lock()
            storedContext = newValue
            lock.unlock()
        }
    }
}

package final class ModelExecutorAffinityToken: @unchecked Sendable {
    let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: specificKey, value: identifier)
    }

    func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    var isCurrentExecutor: Bool {
        DispatchQueue.getSpecific(key: specificKey) == identifier
    }

    private let specificKey = DispatchSpecificKey<UUID>()
    private let identifier = UUID()
}

/// An actor whose isolated work is serialized alongside a model context.
public protocol ModelActor: Actor {
    /// The serial executor that owns this actor's model context.
    nonisolated var modelExecutor: DefaultSerialModelExecutor { get }
    /// The container used by this actor.
    nonisolated var modelContainer: ModelContainer { get }
    /// The context serialized by this actor's model executor.
    var modelContext: ModelContext { get }
}

public extension ModelActor where Self: Actor {
    var modelContext: ModelContext { modelExecutor.modelContext }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        modelExecutor.asUnownedSerialExecutor()
    }
}
