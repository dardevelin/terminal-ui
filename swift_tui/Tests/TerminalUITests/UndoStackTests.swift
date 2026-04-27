import Testing
@testable import TerminalUI

// HYP-65 — `UndoStack<Snapshot>` is the core data type for the
// TextArea undo/redo feature. Pure value type, generic over the
// snapshot shape so it's reusable beyond TextArea later.
//
// Behaviour pinned by these tests:
//   * push records a pre-mutation snapshot (caller's responsibility
//     to call BEFORE mutating their state).
//   * undo(now:) pops the latest pre-mutation snapshot AND saves
//     `now` into the redo buffer so the same edit can be re-applied.
//   * push after undo TRUNCATES the redo buffer.
//   * Bounded: oldest snapshot dropped on overflow past maxSize.

@Suite("UndoStack — push / undo(now:) / redo(now:) semantics")
struct UndoStackTests {

    @Test("Empty stack — neither undo nor redo is available")
    func emptyStackHasNoMoves() {
        let stack = UndoStack<String>(maxSize: 10)
        #expect(!stack.canUndo, "empty stack must not be undoable")
        #expect(!stack.canRedo, "empty stack must not be redoable")
    }

    @Test("push then undo returns the pre-mutation snapshot")
    func pushUndoRoundTrip() {
        var stack = UndoStack<String>(maxSize: 10)
        // Caller's mental model: state was "v0", they pushed it
        // BEFORE mutating to "v1".
        stack.push("v0")
        let snap = stack.undo(now: "v1")
        #expect(snap == "v0", "undo returns the pushed pre-state, restoring back to it")
        #expect(!stack.canUndo, "buffer empty after consuming the only push")
        #expect(stack.canRedo, "redo now available — the popped state ('v1') is preserved")
    }

    @Test("undo then redo restores the popped current state")
    func undoRedoRoundTrip() {
        var stack = UndoStack<String>(maxSize: 10)
        stack.push("v0")
        let undone = stack.undo(now: "v1")
        #expect(undone == "v0")
        // Caller is now at v0. Redo should bring back v1.
        let redone = stack.redo(now: "v0")
        #expect(redone == "v1", "redo returns what was 'now' at undo time")
        #expect(!stack.canRedo)
    }

    @Test("push after undo truncates the redo future")
    func pushAfterUndoTruncatesRedo() {
        var stack = UndoStack<String>(maxSize: 10)
        // Sequence: edits v0→v1→v2→v3. Push pre-state at each step.
        stack.push("v0")
        stack.push("v1")
        stack.push("v2")
        // Now at v3. Undo back to v2 then v1.
        _ = stack.undo(now: "v3")  // pops v2; now=v2
        _ = stack.undo(now: "v2")  // pops v1; now=v1
        #expect(stack.canRedo)
        // New edit at v1 — push pre-state v1, mutate to v4.
        // The redo future (v2, v3) must be discarded.
        stack.push("v1")
        #expect(!stack.canRedo, "redo future truncated by new push")
    }

    @Test("Bounded — oldest snapshot dropped when exceeding maxSize")
    func boundedDropsOldest() {
        var stack = UndoStack<Int>(maxSize: 3)
        stack.push(1)
        stack.push(2)
        stack.push(3)
        stack.push(4)  // overflow — 1 dropped
        // Undoing 3 times should yield 4, 3, 2 (1 was dropped).
        #expect(stack.undo(now: 5) == 4)
        #expect(stack.undo(now: 4) == 3)
        #expect(stack.undo(now: 3) == 2)
        #expect(!stack.canUndo, "bounded — only 3 snapshots retained")
    }

    @Test("Multiple pushes + multiple undos walk back in order")
    func walkBackInOrder() {
        var stack = UndoStack<String>(maxSize: 10)
        stack.push("a")
        stack.push("b")
        stack.push("c")
        // Caller is now at state "d" (after the last push).
        #expect(stack.undo(now: "d") == "c")
        #expect(stack.undo(now: "c") == "b")
        #expect(stack.undo(now: "b") == "a")
        #expect(!stack.canUndo)
    }

    @Test("Multiple undos then redos restore in reverse order")
    func undoRedoSymmetry() {
        var stack = UndoStack<String>(maxSize: 10)
        stack.push("a")
        stack.push("b")
        stack.push("c")
        _ = stack.undo(now: "d")  // back to c
        _ = stack.undo(now: "c")  // back to b
        // Redo back to c, d.
        #expect(stack.redo(now: "b") == "c")
        #expect(stack.redo(now: "c") == "d")
        #expect(!stack.canRedo)
    }
}
