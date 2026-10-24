#if canImport(ObjectiveC)
    /// Uses Foundation's undo manager on platforms with Objective-C.
    public typealias UndoManager = Foundation.UndoManager
#else
    /// Provides a portable undo-manager interface on platforms without Objective-C.
    public final class UndoManager {
        /// Whether the manager has actions available to undo.
        public private(set) var canUndo = false
        /// Whether the manager has actions available to redo.
        public private(set) var canRedo = false

        /// Creates a portable undo manager.
        public init() {}

        /// Does nothing because undo operations are unavailable on this platform.
        public func undo() {}
        /// Does nothing because redo operations are unavailable on this platform.
        public func redo() {}
        /// Clears the manager's undo and redo state.
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
