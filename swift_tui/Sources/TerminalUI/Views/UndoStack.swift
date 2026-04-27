/// Bounded undo/redo history container generic over the snapshot type.
///
/// Operations:
///   * `push(_)`    — record a new snapshot. Truncates any redo future
///                    (snapshots after the current index that came from
///                    prior `undo()` calls).
///   * `undo()`     — move back one step, return the snapshot to apply.
///   * `redo()`     — move forward one step, return the snapshot to apply.
///   * `canUndo`    — `true` iff a prior snapshot exists at index-1.
///   * `canRedo`    — `true` iff a future snapshot exists at index+1.
///
/// `maxSize` caps the buffer; pushes past the cap drop the oldest
/// snapshot. Default size lives at the call site (TextArea uses 100).
///
/// Pure value type — `mutating` push/undo/redo so a `Binding`-backed
/// container struct (like `TextAreaState`) holds its own stack.
///
/// User design memo (HYP-65):
///   > *"Snapshot = (text: String, cursor: TextAreaCursor,
///   > selection: TextAreaSelection?). On each edit action push
///   > current state before mutation. New edits after undo truncate
///   > the redo future. Bounded: default 100 snapshots."*
public struct UndoStack<Snapshot>: Sendable where Snapshot: Sendable {
    /// Stack of "states-to-restore-via-undo." Each entry is a
    /// pre-mutation snapshot pushed at edit time. Top of stack is
    /// the most recent state — undo pops from here.
    private var undoBuffer: [Snapshot]
    /// Stack of "states-to-restore-via-redo." Filled by `undo(now:)`
    /// when the caller passes the current state to preserve. Cleared
    /// on the next `push` (new edit truncates the redo future).
    private var redoBuffer: [Snapshot]
    public let maxSize: Int

    public init(maxSize: Int = 100) {
        self.undoBuffer = []
        self.redoBuffer = []
        self.maxSize = max(1, maxSize)
    }

    public var canUndo: Bool { !undoBuffer.isEmpty }
    public var canRedo: Bool { !redoBuffer.isEmpty }

    /// Record a new snapshot of the pre-mutation state. Truncates
    /// the redo buffer (a fresh edit invalidates any prior
    /// undone-then-redoable future). Drops the oldest entry when
    /// the buffer would exceed `maxSize`.
    public mutating func push(_ snapshot: Snapshot) {
        redoBuffer.removeAll(keepingCapacity: true)
        undoBuffer.append(snapshot)
        if undoBuffer.count > maxSize {
            undoBuffer.removeFirst(undoBuffer.count - maxSize)
        }
    }

    /// Undo: pop the top of `undoBuffer` and return the snapshot
    /// the caller should restore. The caller passes its CURRENT
    /// state via `now` so it can be preserved for a subsequent
    /// `redo()`. Two-arg shape keeps the stack pure-data; the
    /// caller owns "what is the current state."
    public mutating func undo(now: Snapshot) -> Snapshot? {
        guard let snap = undoBuffer.popLast() else { return nil }
        redoBuffer.append(now)
        if redoBuffer.count > maxSize {
            redoBuffer.removeFirst(redoBuffer.count - maxSize)
        }
        return snap
    }

    /// Redo: pop the top of `redoBuffer` and return the snapshot
    /// the caller should restore. Mirrors `undo(now:)` — pushes
    /// the current state onto `undoBuffer` so the redo can be
    /// undone again.
    public mutating func redo(now: Snapshot) -> Snapshot? {
        guard let snap = redoBuffer.popLast() else { return nil }
        undoBuffer.append(now)
        if undoBuffer.count > maxSize {
            undoBuffer.removeFirst(undoBuffer.count - maxSize)
        }
        return snap
    }

    /// Drop all recorded snapshots. Used by callers that need to
    /// reset (e.g. document reload, programmatic content swap).
    public mutating func clear() {
        undoBuffer.removeAll(keepingCapacity: true)
        redoBuffer.removeAll(keepingCapacity: true)
    }
}
