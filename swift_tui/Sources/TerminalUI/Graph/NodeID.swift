/// Stable identity for a node in the attribute graph.
/// Built from the structural path through the view tree.
public struct NodeID: Hashable, Sendable {
    var path: [PathComponent]

    static let root = NodeID(path: [])

    func appending(_ component: PathComponent) -> NodeID {
        var copy = self
        copy.path.append(component)
        return copy
    }
}

public enum PathComponent: Hashable, @unchecked Sendable {
    /// Structural identity — nth child of parent
    case index(Int)
    /// Explicit identity — user-provided id (ForEach, .id())
    case explicit(AnyHashable)
    /// Conditional branch — true = first, false = second
    case conditional(Bool)
}
