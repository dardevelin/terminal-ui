/// Implicit context available during view body evaluation.
///
/// Property wrappers (@TerminalState, @TerminalEnvironment) and modifiers
/// (.focusable, .onKeyPress) read these statics to connect to graph-owned
/// storage, focus registration, and layout constraints.
///
/// ## Why @TaskLocal
///
/// Originally five `nonisolated(unsafe)` `var` statics. That was unsafe by
/// construction: writes from one body evaluation leaked into every other
/// concurrent reader, including @Observable `onChange` callbacks firing on
/// arbitrary threads. The compiler could not enforce the runtime invariant
/// that all reads happen on the MainActor body-eval call stack.
///
/// `@TaskLocal` replaces the leak with a scoped contract:
///
/// - **Reads** are still synchronous and free at every call site —
///   `GraphContext.currentNode` works exactly as before.
/// - **Writes** must go through `withValue { ... }` which binds the value
///   for the duration of a closure and restores it on exit (regardless of
///   throw). The save/set/restore pattern is no longer hand-rolled.
/// - **Isolation** is per-task. Setting `currentNode` inside one body
///   evaluation cannot be observed by `Task.detached` running on another
///   thread — TaskLocal storage doesn't cross task-tree boundaries.
/// - **Inheritance** flows to structured child tasks (`Task { … }`,
///   `async let`, task groups) so a renderer that splits work across
///   structured children still sees the same bindings.
///
/// ## Lifecycle
///
/// `TerminalRuntime` and the graph wrap each body evaluation, layout pass,
/// and render walk in a `withValue` chain. Outside that chain (e.g., timer
/// callbacks, off-main `@Observable` mutations) all five values read as
/// nil — exactly what the old "implicitly cleared" contract intended, but
/// now compiler-enforced.
public enum GraphContext {
    /// The node whose body is currently being evaluated (or rendered); nil
    /// outside the runtime's `withValue` chain — notably in event handlers,
    /// which is why `@TerminalState` cannot resolve its slot there.
    @TaskLocal public static var currentNode: AttributeNode?
    /// The graph owning the current evaluation, so wrappers and modifiers
    /// can reach reconciliation services without threading a parameter.
    @TaskLocal public static var currentGraph: AttributeGraph?
    /// Environment in force for the subtree being evaluated, after every
    /// enclosing `.environment` override. `@TerminalEnvironment` reads it.
    @TaskLocal public static var currentEnvironment: EnvironmentValues?
    /// The runtime's focus engine, bound during graph update so focus
    /// modifiers can register focusables and handlers as they build.
    @TaskLocal public static var currentFocusEngine: FocusEngine?
    /// The size proposal the current measurement or layout pass is
    /// answering; nil outside layout.
    @TaskLocal public static var currentProposedSize: Size?
    /// The node ID the active key handler was dispatched to. Set by
    /// `FocusEngine.routeKeyEvent(...startingFrom:)` for the duration
    /// of the handler's invocation, nil otherwise. Lets handlers that
    /// would normally read `keyboardFocusID` (e.g. `.scrollable()`'s
    /// arrow handler) find their owning node when wheel routing
    /// dispatches them at a non-focused target.
    @TaskLocal public static var currentRoutingNodeID: NodeID?
}
