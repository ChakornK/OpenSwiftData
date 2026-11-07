import Foundation
import Testing
@testable import OpenSwiftData

@Suite struct UndoActionStackTests {
    /// Runs one undo step, letting the action register its inverse the way a model context does.
    private func undo(_ stack: inout UndoActionStack) {
        guard let action = stack.beginUndo() else { return }
        action()
        stack.finishUndo()
    }

    private func redo(_ stack: inout UndoActionStack) {
        guard let action = stack.beginRedo() else { return }
        action()
        stack.finishRedo()
    }

    @Test func `registering outside undo and redo clears the redo stack`() {
        var stack = UndoActionStack()
        stack.register {}
        _ = stack.beginUndo()
        stack.register {}
        stack.finishUndo()
        #expect(stack.canRedo)

        stack.register {}
        #expect(!stack.canRedo)
        #expect(stack.canUndo)
    }

    @Test func `registering while redoing keeps remaining redo actions`() {
        var stack = UndoActionStack()
        stack.register {}
        stack.register {}
        // Two undos, each registering a redo action.
        for _ in 0..<2 {
            _ = stack.beginUndo()
            stack.register {}
            stack.finishUndo()
        }
        #expect(!stack.canUndo)

        _ = stack.beginRedo()
        stack.register {}
        stack.finishRedo()

        #expect(stack.canUndo)
        #expect(stack.canRedo)
    }

    @Test func `undo and redo alternate through registered inverses`() {
        final class Box { var value = 0 }
        let box = Box()
        var stack = UndoActionStack()

        func set(_ newValue: Int, on stack: inout UndoActionStack) {
            let old = box.value
            box.value = newValue
            stack.register { [old] in box.value = old }
        }
        set(1, on: &stack)

        // Each action restores the old value; the inverse is registered by the test loop below.
        guard let undoAction = stack.beginUndo() else { Issue.record("missing undo"); return }
        let beforeUndo = box.value
        undoAction()
        stack.register { box.value = beforeUndo }
        stack.finishUndo()
        #expect(box.value == 0)
        #expect(stack.canRedo)
        #expect(!stack.canUndo)

        redo(&stack)
        #expect(box.value == 1)
        #expect(!stack.canRedo)
    }

    @Test func `flags report the active direction only while an action runs`() {
        var stack = UndoActionStack()
        stack.register {}
        _ = stack.beginUndo()
        #expect(stack.isUndoing)
        #expect(!stack.isRedoing)
        stack.finishUndo()
        #expect(!stack.isUndoing)
        undo(&stack)
        #expect(!stack.canUndo)
    }

    @Test func `removing all actions empties both stacks`() {
        var stack = UndoActionStack()
        stack.register {}
        stack.register {}
        _ = stack.beginUndo()
        stack.register {}
        stack.finishUndo()
        stack.removeAll()
        #expect(!stack.canUndo)
        #expect(!stack.canRedo)
    }

    @Test func `removing actions for one target preserves other targets undo and redo`() {
        let firstTarget = NSObject()
        let secondTarget = NSObject()
        var stack = UndoActionStack()
        stack.register(target: ObjectIdentifier(firstTarget)) {}
        stack.register(target: ObjectIdentifier(secondTarget)) {}

        stack.removeAll(target: ObjectIdentifier(firstTarget))
        #expect(stack.canUndo)
        #expect(!stack.canRedo)

        _ = stack.beginUndo()
        stack.register(target: ObjectIdentifier(secondTarget)) {}
        stack.finishUndo()
        #expect(stack.canRedo)

        stack.removeAll(target: ObjectIdentifier(secondTarget))
        #expect(!stack.canUndo)
        #expect(!stack.canRedo)
    }
}
