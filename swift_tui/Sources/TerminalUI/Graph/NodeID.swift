/// Stable identity for a node in the attribute graph.
/// Built from the structural path through the view tree.
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

public enum PathComponent: Hashable, @unchecked Sendable {
    /// Structural identity — nth child of parent
    case index(Int)
    /// Explicit identity — user-provided id (ForEach, .id())
    case explicit(AnyHashable)
    /// Conditional branch — true = first, false = second
    case conditional(Bool)
}
