import Synchronization

/// How a view should react when the user hits an input boundary — cursor at
/// buffer start pressing left, at end pressing right, maxLength reached
/// typing a char.
///
/// TextInput, TextArea and PromptInput read it, through the environment's
/// ``EnvironmentValues/boundaryHit`` action, at every wall they hit. Set it
/// for a subtree with `.boundaryFeedback(_:)`.
public enum BoundaryFeedback: Sendable, Equatable {
    /// The default: the focused cursor lights for a moment in the theme's
    /// warning colour — see ``CursorFlash`` — and an app's
    /// ``BoundaryFeedbackEmitter/bounceSink``, if it installed one, is called.
    case bounce
    /// Rings the environment's ``BellAction`` — in a running app, BEL to
    /// the terminal, which beeps, flashes or ignores it as configured.
    case bell
    /// Programmatic handling — dispatches to `.onBoundaryHit { reason in ... }`
    /// so the host can present its own modal / toast.
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
    /// Cursor at column 0, user pressed Left.
    case leftEdge
    /// Cursor past the last column, user pressed Right.
    case rightEdge
    /// Cursor at row 0, user pressed Up.
    case topEdge
    /// Cursor at the last row, user pressed Down.
    case bottomEdge
    /// Fixed-length input full, user typed a character.
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

    /// Wraps a callback; prefer the `.onBoundaryHit { }` modifier at
    /// call sites.
    public init(_ action: @escaping @Sendable (BoundaryHitReason) -> Void) {
        self.action = action
    }

    /// Invokes the wrapped callback with the hit reason.
    public func callAsFunction(_ reason: BoundaryHitReason) {
        action(reason)
    }
}

// MARK: - Action

/// What an input does when it hits a wall: the subtree's ``BoundaryFeedback``
/// mode, its `.onBoundaryHit` callback and its ``BellAction``, read together.
///
/// Input views read it in `body` and call it from their handlers, which run
/// after the frame, when no environment is bound:
///
///     @TerminalEnvironment(\.boundaryHit) private var boundaryHit
///     // in a key handler, at the wall:
///     boundaryHit(.leftEdge)
public struct BoundaryHitAction: Sendable {
    private let callback: BoundaryHitCallback?
    private let bell: BellAction
    /// The subtree's own bounce hook, or nil for the shared emitter's, looked
    /// up when a hit comes. A closure made here would be a new one on every
    /// read, and the environment, comparing what an input read byte for
    /// byte, would see a change on every frame.
    private let bounce: (@Sendable (BoundaryHitReason) -> Void)?
    private let flash: CursorFlash?
    /// The feedback mode in effect where the action was read. Declared last:
    /// the environment compares what an input read byte for byte, and the
    /// padding after a one-byte field ahead of the others holds whatever the
    /// memory held, so two reads of one value would differ.
    public let mode: BoundaryFeedback

    init(mode: BoundaryFeedback,
         callback: BoundaryHitCallback?,
         bell: BellAction,
         bounce: (@Sendable (BoundaryHitReason) -> Void)? = nil,
         flash: CursorFlash? = nil) {
        self.mode = mode
        self.callback = callback
        self.bell = bell
        self.bounce = bounce
        self.flash = flash
    }

    /// Gives the feedback `mode` calls for.
    public func callAsFunction(_ reason: BoundaryHitReason) {
        switch mode {
        case .bell:
            bell()
        case .bounce:
            flash?.light()
            (bounce ?? BoundaryFeedbackEmitter.shared.bounceSink)(reason)
        case .modal:
            callback?(reason)
        case .none:
            break
        }
    }
}

extension EnvironmentValues {
    /// The boundary-hit action for this subtree, assembled from
    /// ``boundaryFeedback``, ``onBoundaryHit``, ``bell`` and its bounce hook.
    public var boundaryHit: BoundaryHitAction {
        BoundaryHitAction(mode: boundaryFeedback, callback: onBoundaryHit, bell: bell,
                          bounce: boundaryBounce, flash: cursorFlash)
    }
}

// MARK: - Emitter

/// Holds ``bounceSink``, an app's own hook for `.bounce` hits, called after
/// the framework's ``CursorFlash`` lights.
///
/// It routed every boundary hit before the environment carried a
/// ``BoundaryHitAction``; ``emit(reason:env:callback:)`` and ``bellSink``
/// remain for code written against that, and no input uses them now. The
/// sinks sit behind a lock: an app may install one while a hit routes.
public final class BoundaryFeedbackEmitter: Sendable {
    /// The emitter whose ``bounceSink`` every `.bounce` hit calls.
    public static let shared = BoundaryFeedbackEmitter()

    private struct Sinks {
        var bell: @Sendable () -> Void = {}
        var bounce: @Sendable (BoundaryHitReason) -> Void = { _ in }
    }

    private let sinks = Mutex(Sinks())

    /// Creates an emitter with no-op sinks.
    public init() {}

    /// Called by ``emit(reason:env:callback:)`` under `.bell`. Inputs ring
    /// the environment's ``BellAction`` instead, which a running app wires
    /// to its terminal.
    @available(*, deprecated, message: "Ring the environment's bell: @TerminalEnvironment(\\.bell), or replace it with .environment(\\.bell, BellAction { ... }).")
    public var bellSink: @Sendable () -> Void {
        get { sinks.withLock { $0.bell } }
        set { sinks.withLock { $0.bell = newValue } }
    }

    /// Called for every hit under `.bounce`, the default mode, with its
    /// reason, after the cursor flash lights. No-op until an app installs
    /// one.
    public var bounceSink: @Sendable (BoundaryHitReason) -> Void {
        get { sinks.withLock { $0.bounce } }
        set { sinks.withLock { $0.bounce = newValue } }
    }

    /// Dispatch `reason` according to `env.boundaryFeedback`, ringing
    /// ``bellSink`` under `.bell`.
    @available(*, deprecated, message: "Call the environment's boundary-hit action: @TerminalEnvironment(\\.boundaryHit).")
    public func emit(reason: BoundaryHitReason,
                     env: EnvironmentValues,
                     callback: BoundaryHitCallback?) {
        let bell = sinks.withLock { $0.bell }
        BoundaryHitAction(mode: env.boundaryFeedback, callback: callback,
                          bell: BellAction(bell), bounce: bounceSink)(reason)
    }
}

#if DEBUG
/// Test seam: a boundary-hit action with counters attached, each probe
/// counting on its own.
@available(*, deprecated, message: "Read hits through the environment: give it a BellAction and an .onBoundaryHit callback, set the mode, and call its boundaryHit action.")
public final class BoundaryFeedbackProbe: @unchecked Sendable {
    /// Times `.bell` mode dispatched through this probe.
    public private(set) var bellCount = 0
    /// Times `.bounce` mode dispatched through this probe.
    public private(set) var bounceCount = 0
    /// Times the env was `.modal` at emit — counted whether or not a
    /// callback was registered.
    public private(set) var callbackCount = 0

    /// Creates a probe with all counts at zero.
    public init() {}

    /// Dispatches as the environment's ``BoundaryHitAction`` would,
    /// updating the counters.
    public func emit(reason: BoundaryHitReason,
                     env: EnvironmentValues,
                     callback: BoundaryHitCallback?) {
        // Counted at the probe so it reflects "the framework would have
        // invoked the callback under this env", registered or not.
        if env.boundaryFeedback == .modal { callbackCount += 1 }
        let action = BoundaryHitAction(
            mode: env.boundaryFeedback, callback: callback,
            bell: BellAction { [weak self] in self?.bellCount += 1 },
            bounce: { [weak self] _ in self?.bounceCount += 1 })
        action(reason)
    }
}
#endif
