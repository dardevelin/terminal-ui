/// Implicit context available during view body evaluation.
///
/// Property wrappers (@TerminalState, @TerminalEnvironment) and modifiers
/// (.focusable, .onKeyPress) read these statics to connect to graph-owned
/// storage, focus registration, and layout constraints.
///
/// ## Threading model
///
/// `nonisolated(unsafe)` tells Swift's concurrency checker to skip Sendability
/// enforcement on these statics. Without it, every TerminalView struct and
/// ViewModifier protocol would need @MainActor annotation — which Swift does
/// not allow on protocols with associated types.
///
/// Safety relies on a runtime invariant: body evaluation, focus registration,
/// and rendering all run on @MainActor. The compiler cannot verify this.
/// If any code path evaluates a view body off-MainActor, data races will
/// occur silently. Consider @TaskLocal migration for compiler
/// enforcement.
///
/// ## Lifecycle
///
/// Set by TerminalRuntime before `buildView()`, read during body evaluation,
/// cleared implicitly when the call returns. Analogous to thread-local storage
/// but scoped to the MainActor call stack.
public enum GraphContext {
    nonisolated(unsafe) public static var currentNode: AttributeNode?
    nonisolated(unsafe) public static var currentGraph: AttributeGraph?
    nonisolated(unsafe) public static var currentEnvironment: EnvironmentValues?
    nonisolated(unsafe) public static var currentFocusEngine: FocusEngine?
    nonisolated(unsafe) public static var currentProposedSize: Size?
}
