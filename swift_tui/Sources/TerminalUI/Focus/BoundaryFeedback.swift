/// How a view should react when the user hits an input boundary — cursor at
/// buffer start pressing left, at end pressing right, maxLength reached
/// typing a char, read-only region, etc..
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

/// Why a boundary was hit. Five canonical reasons cover the input
/// surfaces TextInput / TextArea / PromptInput emit:
///
///   - `.leftEdge`  — cursor at column 0, user pressed Left.
///   - `.rightEdge` — cursor past the last column, user pressed Right.
///   - `.topEdge`   — cursor at row 0, user pressed Up.
///   - `.bottomEdge` — cursor at last row, user pressed Down.
///   - `.maxLength` — fixed-length input full, user typed a character.
///
/// Components that need finer reasons (Tab in a non-tab-aware field,
/// disallowed character) can model those at the app layer; the
/// framework only ships the universally-meaningful five.
public enum BoundaryHitReason: Sendable, Hashable {
    case leftEdge
    case rightEdge
    case topEdge
    case bottomEdge
    case maxLength
}

extension TerminalView {
    /// Register a callback invoked when an input component in this
    /// subtree hits a boundary AND the active `BoundaryFeedback` mode
    /// is `.modal`. Pairs with `.boundaryFeedback(.modal)` — the
    /// callback is what the modal mode dispatches into. For `.bell`
    /// or `.bounce`, the framework handles the feedback and the
    /// callback is not invoked.
    ///
    /// Example:
    ///
    ///     TextInput(text: $value, maxLength: 10)
    ///         .boundaryFeedback(.modal)
    ///         .onBoundaryHit { reason in
    ///             if reason == .maxLength { showToast("Limit reached") }
    ///         }
    public func onBoundaryHit(_ action: @escaping @Sendable (BoundaryHitReason) -> Void)
        -> ModifiedView<Self, EnvironmentModifier<BoundaryHitCallback?>> {
        environment(\.onBoundaryHit, BoundaryHitCallback(action))
    }
}

/// Type-erased boundary-hit callback. `Sendable` so the env value
/// can cross the @TaskLocal boundary into the runtime's render walk;
/// the underlying closure is captured `@Sendable` at the modifier
/// site to satisfy the strict-concurrency gate.
public struct BoundaryHitCallback: Sendable {
    private let action: @Sendable (BoundaryHitReason) -> Void

    public init(_ action: @escaping @Sendable (BoundaryHitReason) -> Void) {
        self.action = action
    }

    public func callAsFunction(_ reason: BoundaryHitReason) {
        action(reason)
    }
}

// MARK: - Emitter

/// Routes a boundary hit to the configured feedback channel.
///
/// Input components call `BoundaryFeedbackEmitter.shared.emit(...)`
/// at their boundary-hit sites — typically in `handleKey` when a
/// cursor move would push past the buffer extent or a character
/// would exceed `maxLength`. The emitter consults `env.boundaryFeedback`
/// to pick the route:
///
///   - `.bell`   → writes ASCII BEL via the registered bell sink
///   - `.bounce` → calls the registered bounce sink (per-component
///                 visual)
///   - `.modal`  → invokes the `.onBoundaryHit { ... }` callback
///                 if registered
///   - `.none`   → silent
///
/// The emitter is `final` per the Swift-dev guideline (classes
/// `final` unless designed for inheritance). Tests inject behavior
/// by swapping the shared instance's sink closures rather than
/// subclassing — same outcome, no inheritance hierarchy.
public final class BoundaryFeedbackEmitter: @unchecked Sendable {
    /// Shared instance. Production input components reach for this
    /// directly; tests swap the sinks before each case to observe
    /// dispatch.
    public static let shared = BoundaryFeedbackEmitter()

    public init() {}

    /// Hook for `.bell` mode. Default: no-op. Production runtime
    /// will swap in a writer that pushes BEL to OutputBuffer; tests
    /// swap in a counter sink.
    public var bellSink: @Sendable () -> Void = {}

    /// Hook for `.bounce` mode. Default: no-op (visual feedback is
    /// per-component). Components can register their own animator
    /// here at construction time.
    public var bounceSink: @Sendable (BoundaryHitReason) -> Void = { _ in }

    /// Dispatch `reason` according to `env.boundaryFeedback`.
    /// `callback` is the one registered by `.onBoundaryHit { ... }`.
    public func emit(reason: BoundaryHitReason,
                     env: EnvironmentValues,
                     callback: BoundaryHitCallback?) {
        switch env.boundaryFeedback {
        case .bell:
            bellSink()
        case .bounce:
            bounceSink(reason)
        case .modal:
            callback?(reason)
        case .none:
            break
        }
    }
}

#if DEBUG
/// Test seam: a fresh emitter instance with counter sinks attached.
/// Used by `BoundaryFeedbackEmitterTests` to assert dispatch
/// correctness without touching shared state. Hand-rolled so each
/// test gets isolated counts.
public final class BoundaryFeedbackProbe: @unchecked Sendable {
    public private(set) var bellCount = 0
    public private(set) var bounceCount = 0
    public private(set) var callbackCount = 0

    private let emitter = BoundaryFeedbackEmitter()

    public init() {
        // Wire counter sinks. Capturing self in @Sendable closures is
        // OK because the probe is class-typed (reference) — the
        // counters update via the instance, not a captured value.
        emitter.bellSink = { [weak self] in self?.bellCount += 1 }
        emitter.bounceSink = { [weak self] _ in self?.bounceCount += 1 }
    }

    public func emit(reason: BoundaryHitReason,
                     env: EnvironmentValues,
                     callback: BoundaryHitCallback?) {
        // Track callback hits at the probe level so the counter
        // reflects "the framework would have invoked the callback
        // under this env" — independent of whether one was registered.
        if env.boundaryFeedback == .modal { callbackCount += 1 }
        emitter.emit(reason: reason, env: env, callback: callback)
    }
}
#endif
