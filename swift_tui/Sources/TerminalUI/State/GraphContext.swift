/// Context set by the graph during body evaluation.
/// @State property wrappers read this to connect to their graph-owned storage.
///
/// This is safe because all graph evaluation happens on @MainActor — single-threaded.
public enum GraphContext {
    /// The current node being evaluated.
    nonisolated(unsafe) public static var currentNode: AttributeNode?

    /// The current graph instance.
    nonisolated(unsafe) public static var currentGraph: AttributeGraph?
}
