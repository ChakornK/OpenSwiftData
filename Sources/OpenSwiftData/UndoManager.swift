/// Undo and redo stacks with Foundation `UndoManager` semantics for registrations made during undo and redo.
///
/// Registering while undoing pushes onto the redo stack. Registering while redoing pushes onto the undo
/// stack and keeps the remaining redo actions. Any other registration clears the redo stack.
struct UndoActionStack {
    private struct Action {
        let target: ObjectIdentifier?
        let perform: () -> Void
    }

    private var undoActions: [Action] = []
    private var redoActions: [Action] = []
    private(set) var isUndoing = false
    private(set) var isRedoing = false

    var canUndo: Bool { !undoActions.isEmpty }
    var canRedo: Bool { !redoActions.isEmpty }

    mutating func register(target: ObjectIdentifier? = nil, _ action: @escaping () -> Void) {
        let action = Action(target: target, perform: action)
        if isUndoing {
            redoActions.append(action)
        } else {
            undoActions.append(action)
            if !isRedoing { redoActions.removeAll() }
        }
    }

    /// Removes the most recent undo action and returns it with the stack in undoing mode.
    ///
    /// Call `finishUndo()` after running the action.
    mutating func beginUndo() -> (() -> Void)? {
        guard let action = undoActions.popLast() else { return nil }
        isUndoing = true
        return action.perform
    }

    mutating func finishUndo() { isUndoing = false }

    /// Removes the most recent redo action and returns it with the stack in redoing mode.
    ///
    /// Call `finishRedo()` after running the action.
    mutating func beginRedo() -> (() -> Void)? {
        guard let action = redoActions.popLast() else { return nil }
        isRedoing = true
        return action.perform
    }

    mutating func finishRedo() { isRedoing = false }

    mutating func removeAll() {
        undoActions.removeAll()
        redoActions.removeAll()
    }

    mutating func removeAll(target: ObjectIdentifier) {
        undoActions.removeAll { $0.target == target }
        redoActions.removeAll { $0.target == target }
    }
}

#if canImport(ObjectiveC)
    /// Uses Foundation's undo manager on supported Apple platforms.
    public typealias UndoManager = Foundation.UndoManager
#else
    /// A minimal undo manager for platforms without Foundation's Objective-C implementation.
    ///
    /// Each registration is its own undo step; the model context groups related changes itself.
    public final class UndoManager {
        private var stack = UndoActionStack()

        /// Whether the manager has actions available to undo.
        public var canUndo: Bool { stack.canUndo }
        /// Whether the manager has actions available to redo.
        public var canRedo: Bool { stack.canRedo }
        /// Whether the manager is running an undo action.
        public var isUndoing: Bool { stack.isUndoing }
        /// Whether the manager is running a redo action.
        public var isRedoing: Bool { stack.isRedoing }

        /// Creates an empty undo manager.
        public init() {}

        /// Runs the most recent undo action; registrations it makes become redo actions.
        public func undo() {
            guard let action = stack.beginUndo() else { return }
            defer { stack.finishUndo() }
            action()
        }

        /// Runs the most recent redo action; registrations it makes become undo actions.
        public func redo() {
            guard let action = stack.beginRedo() else { return }
            defer { stack.finishRedo() }
            action()
        }

        /// Clears the undo and redo stacks.
        public func removeAllActions() {
            stack.removeAll()
        }

        /// Clears the undo and redo operations registered for a target.
        public func removeAllActions(withTarget target: AnyObject) {
            stack.removeAll(target: ObjectIdentifier(target))
        }

        /// Registers a reversible action for the target object.
        ///
        /// Retains `target` until the action runs or is removed.
        public func registerUndo<Target: AnyObject>(withTarget target: Target, handler: @escaping (Target) -> Void) {
            stack.register(target: ObjectIdentifier(target)) { handler(target) }
        }

        /// Accepts an action name without storing it.
        public func setActionName(_ actionName: String) {
            _ = actionName
        }

        /// Returns whether the current undo action can be discarded.
        public func undoActionIsDiscardable() -> Bool { false }
    }
#endif
