#if canImport(ObjectiveC)
    /// Uses Foundation's undo manager on supported Apple platforms.
    public typealias UndoManager = Foundation.UndoManager
#else
    /// Keeps Linux-host builds type-checkable while Apple clients use Foundation's implementation.
    public final class UndoManager {
        private var undoActions: [() -> Void] = []
        private var redoActions: [() -> Void] = []
        private var isPerformingUndo = false
        /// Whether the manager has actions available to undo.
        public private(set) var canUndo = false
        /// Whether the manager has actions available to redo.
        public private(set) var canRedo = false

        /// Creates a host-only undo manager placeholder.
        public init() {}

        /// Does nothing because undo operations are unavailable on the Linux build host.
        public func undo() {
            guard let action = undoActions.popLast() else { return }
            isPerformingUndo = true
            action()
            isPerformingUndo = false
            canUndo = !undoActions.isEmpty
            canRedo = !redoActions.isEmpty
        }
        /// Does nothing because redo operations are unavailable on the Linux build host.
        public func redo() {
            guard let action = redoActions.popLast() else { return }
            isPerformingUndo = false
            action()
            canUndo = !undoActions.isEmpty
            canRedo = !redoActions.isEmpty
        }
        /// Clears the undo and redo state.
        public func removeAllActions() {
            undoActions.removeAll()
            redoActions.removeAll()
            canUndo = false
            canRedo = false
        }
        /// Registers a reversible action for the target object.
        public func registerUndo<Target: AnyObject>(withTarget target: Target, handler: @escaping (Target) -> Void) {
            let action = { handler(target) }
            if isPerformingUndo {
                redoActions.append(action)
                canRedo = true
            } else {
                undoActions.append(action)
                redoActions.removeAll()
                canUndo = true
                canRedo = false
            }
        }
        /// Accepts an action name without storing it.
        public func setActionName(_ actionName: String) {
            _ = actionName
        }
        /// Returns whether the current undo action can be discarded.
        public func undoActionIsDiscardable() -> Bool { false }
    }
#endif
