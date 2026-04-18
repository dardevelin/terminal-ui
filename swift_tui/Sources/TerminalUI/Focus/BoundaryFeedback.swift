/// How a view should react when the user hits an input boundary — cursor at
/// buffer start pressing left, at end pressing right, maxLength reached
/// typing a char, read-only region, etc. (HYP-87 / HYP-81).
///
/// Input components (TextInput, TextArea, PromptInput) read this environment
/// value and trigger the configured feedback on boundary-hit events. Default
/// `.bounce` — visible cursor animation, drop-in. Apps opt into `.bell` for
/// terminal beep, `.modal` for programmatic handling, `.none` for silent
/// boundaries.
///
/// The API ships as scaffolding: environment entry + modifier + enum. Full
/// animation wiring (frame-driven cursor bounce) lands when input components
/// adopt the value. Until then, components that haven't been updated simply
/// ignore boundary hits as before — no visual regression.
public enum BoundaryFeedback: Sendable, Equatable {
    /// Default — cursor animates briefly (half-block shift or color pulse)
    /// to signal the boundary. Implemented per-component.
    case bounce
    /// Emit ASCII bell (`\x07`). Terminal decides whether to audible-beep,
    /// flash, or ignore. Robust fallback that requires no animation engine.
    case bell
    /// Programmatic handling — dispatches to `.onBoundaryHit { ctx in ... }`
    /// at the app level so the host can present its own modal / toast.
    case modal
    /// Silence. No feedback; app handles the state itself (e.g. a dedicated
    /// status bar line reading `cursor.atEnd` directly).
    case none
}

extension TerminalView {
    /// Set the boundary-feedback mode for this subtree.
    public func boundaryFeedback(_ mode: BoundaryFeedback)
        -> ModifiedView<Self, EnvironmentModifier<BoundaryFeedback>> {
        environment(\.boundaryFeedback, mode)
    }
}
