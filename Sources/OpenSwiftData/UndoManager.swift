#if canImport(ObjectiveC)
    /// Uses Foundation's undo manager on supported Apple platforms.
    public typealias UndoManager = Foundation.UndoManager
#else
    /// Keeps Linux-host builds type-checkable while Apple clients use Foundation's implementation.
    public final class UndoManager {
        /// Whether the manager has actions available to undo.
        public private(set) var canUndo = false
        /// Whether the manager has actions available to redo.
        public private(set) var canRedo = false

        /// Creates a host-only undo manager placeholder.
        public init() {}

        /// Does nothing because undo operations are unavailable on the Linux build host.
        public func undo() {}
        /// Does nothing because redo operations are unavailable on the Linux build host.
        public func redo() {}
        /// Clears the undo and redo state.
        public func removeAllActions() {
            canUndo = false
            canRedo = false
        }
        /// Accepts an undo registration without retaining or invoking it.
        public func registerUndo<Target: AnyObject>(withTarget target: Target, handler: @escaping (Target) -> Void) {
            _ = (target, handler)
        }
        /// Accepts an action name without storing it.
        public func setActionName(_ actionName: String) {
            _ = actionName
        }
        /// Returns whether the current undo action can be discarded.
        public func undoActionIsDiscardable() -> Bool { false }
    }
#endif
