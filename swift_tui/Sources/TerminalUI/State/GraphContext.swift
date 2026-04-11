/// Context set by the graph during body evaluation.
/// @State property wrappers read this to connect to their graph-owned storage.
///
/// This is safe because all graph evaluation happens on @MainActor — single-threaded.
public enum GraphContext {
    /// The current node being evaluated.
    nonisolated(unsafe) public static var currentNode: AttributeNode?

    /// The current graph instance.
    nonisolated(unsafe) public static var currentGraph: AttributeGraph?

    /// Current environment values — propagated during rendering.
    nonisolated(unsafe) public static var currentEnvironment: EnvironmentValues?

    /// Current focus engine — set by runtime so modifiers can register handlers.
    nonisolated(unsafe) public static var currentFocusEngine: FocusEngine?
}
