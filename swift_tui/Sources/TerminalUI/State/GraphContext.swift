/// Context set by the graph during body evaluation.
/// @State property wrappers read this to connect to their graph-owned storage.
///
/// These are thread-local-like: set before body evaluation, restored after.
/// All access happens on @MainActor (body evaluation, focus registration, rendering).
/// Marked nonisolated(unsafe) because enforcing @MainActor on the static properties
/// would require @MainActor on every view struct and modifier protocol, which is
/// architecturally infeasible. Safety is guaranteed by the runtime's single-threaded
/// graph evaluation on MainActor.
public enum GraphContext {
    /// The current node being evaluated.
    nonisolated(unsafe) public static var currentNode: AttributeNode?

    /// The current graph instance.
    nonisolated(unsafe) public static var currentGraph: AttributeGraph?

    /// Current environment values — propagated during rendering.
    nonisolated(unsafe) public static var currentEnvironment: EnvironmentValues?

    /// Current focus engine — set by runtime so modifiers can register handlers.
    nonisolated(unsafe) public static var currentFocusEngine: FocusEngine?

    /// Current proposed size — set by the renderer so GeometryReader can read
    /// the actual available space rather than the full terminal size.
    nonisolated(unsafe) public static var currentProposedSize: Size?
}
