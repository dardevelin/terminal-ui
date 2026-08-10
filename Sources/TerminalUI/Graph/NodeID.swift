/// Stable identity for a node in the attribute graph.
/// Built from the structural path through the view tree.
///
/// The path records how the node is reached from the root: child index for
/// plain structure, the user's id for `ForEach` / `.id()` elements, and the
/// branch taken for conditionals. Two frames that build the same structure
/// therefore mint the same IDs — which is what lets the reconciler match old
/// nodes to new view values and keep `@TerminalState` storage, focus, and
/// scroll offsets alive across body re-evaluation. `Hashable` and value-typed
/// so it keys the focus index and the engine's handler tables directly.
public struct NodeID: Hashable, Sendable, CustomStringConvertible {
    var path: [PathComponent]

    static let root = NodeID(path: [])

    func appending(_ component: PathComponent) -> NodeID {
        var copy = self
        copy.path.append(component)
        return copy
    }

    /// Human-readable form of the path. Used by DevTrace output and
    /// diagnostic logs to identify which node a dispatch / event
    /// touched without consumers needing to understand PathComponent.
    public var description: String {
        if path.isEmpty { return "root" }
        return path.map { component in
            switch component {
            case .index(let i):       return "\(i)"
            case .explicit(let id):   return "id(\(id))"
            case .conditional(let b): return b ? "T" : "F"
            }
        }.joined(separator: ".")
    }
}

/// One step in a `NodeID`'s root-to-node path — how a child is
/// identified within its parent.
public enum PathComponent: Hashable, @unchecked Sendable {
    /// Structural identity — nth child of parent
    case index(Int)
    /// Explicit identity — user-provided id (ForEach, .id())
    case explicit(AnyHashable)
    /// Conditional branch — true = first, false = second
    case conditional(Bool)
}
