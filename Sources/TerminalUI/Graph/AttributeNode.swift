/// Base class for all nodes in the attribute graph.
/// Persistent across frames — created once, updated in place.
///
/// Marked `@unchecked Sendable` so it can be carried by `@TaskLocal`
/// `GraphContext.currentNode`. A node belongs to its graph's thread — the
/// main actor for the runtime's graph, the caller's for `TerminalApp.print`
/// — and its mutable state is not safe to touch from any other. A change to
/// observed state on another thread reaches it only through the graph's
/// `InvalidationInbox`.
public class AttributeNode: @unchecked Sendable {
    /// Structural identity — stable across frames, the reconciler's match key.
    public let id: NodeID
    /// What this node is — primitive, layout, modifier, or composite body.
    /// The render and measure walks switch on it; nothing casts.
    public var kind: NodeKind
    /// Owning node; weak to break the cycle with ``children``. Nil at the root.
    public weak var parent: AttributeNode?
    /// Child nodes in declaration order.
    public var children: [AttributeNode] = []
    /// Whether this node needs re-evaluation on the next update. New nodes
    /// start dirty; ``markDirty()`` sets it, reconciliation clears it.
    public var isDirty: Bool = true

    /// Cached layout result — the rectangle this node occupies
    public var rect: Rect = Rect(x: 0, y: 0, width: 0, height: 0)

    /// Style inherited from parent + modifiers
    public var resolvedStyle: Style = .plain

    /// State storage slots — persisted across body re-evaluations.
    /// @TerminalState creates slots here during first body evaluation.
    /// Dictionary keyed by source location for O(1) lookup.
    public var stateSlots: [String: any AnyStateStorage] = [:]

    /// Cached intrinsic width — nil means needs recomputation.
    /// Invalidated when markDirty() is called (content changed).
    public var cachedWidth: Int?

    /// Cached intrinsic height — nil means needs recomputation.
    public var cachedHeight: Int?
    /// Proposed width the `cachedHeight` was computed at. Height is
    /// width-dependent whenever wrapping is involved, so the measurer must
    /// recompute when the width changes.
    public var cachedHeightWidth: Int?

    /// Whether this node can receive focus (set by .focusable() modifier).
    public var isFocusable: Bool = false
    /// Whether this node's `.foreground` gives way to one stated above it;
    /// see `ForegroundModifier.yieldsToStated`.
    var foregroundYieldsToStated = false

    /// Identifier of the nearest enclosing focus scope, or nil if not in one.
    /// Set during reconciliation by .focusScope(id) — the modifier propagates its id
    /// to every focusable descendant. FocusEngine uses it to clamp directional
    /// navigation: arrows stay within a scope, Tab still crosses scopes.
    public var scopeID: String?

    /// How many presented modals enclose this node: 0 outside any modal,
    /// 1 inside one, 2 inside a modal presented from within a modal.
    ///
    /// Distinct from `scopeID`: a scope GROUPS focusables so arrows stay
    /// local while Tab deliberately crosses it, whereas containment TRAPS
    /// Tab entirely. This is the terminal expression of the platform
    /// modality rule — a modal presentation "prevents interaction with the
    /// parent view and requires an explicit action to dismiss" (Apple HIG,
    /// Patterns → Modality). A panel that dims the background but lets Tab
    /// walk behind it is not modal.
    ///
    /// Read from the tree, so it is right the moment a node is linked, even
    /// one a reader rebuilt during layout. Which presentation contains focus
    /// is decided by `Presentations`, the order they are drawn in.
    public var containmentDepth: Int {
        var depth = 0
        var node = self
        while let parent = node.parent {
            if parent.presentedContent === node { depth += 1 }
            node = parent
        }
        return depth
    }

    /// Whether onAppear has already fired for this node.
    public var didAppear: Bool = false

    /// Last observed value seen by an `.onChange(of:)` modifier on this node.
    /// Stored as `Any` because the `ModifierEffect` enum is generic-free; the
    /// modifier carries its own `Equatable` comparator that decides whether a
    /// stored-vs-current pair represents a change. Nil before the first probe.
    public var lastObservedValue: Any?

    /// Closure to invoke when this node is detached from the tree. Set by
    /// `_RemovalLifecycleModifier.captureDisappear` during construct/update;
    /// invoked from `AttributeGraph` whenever a node leaves the tree (layout
    /// rebuild, conditional flip, etc.). Nil for nodes without onDisappear.
    public var onDisappearAction: (() -> Void)?

    /// Async work owned by this node, started by `.task { }` when the node
    /// first appears and cancelled when it leaves the tree.
    ///
    /// The handle lives here rather than in the modifier because `body`
    /// rebuilds the modifier — and its closure — every frame: a handle held by
    /// the modifier would be a different one by the time anything came to
    /// cancel it, and the work would outlive the view that started it.
    public var lifecycleTask: Task<Void, Never>?

    /// The `.task(id:)` value this node's running task was started for. A new
    /// value cancels the old task and starts a fresh one; nil when the task
    /// carries no identity and so runs once for the node's lifetime.
    public var lifecycleTaskID: AnyHashable?

    /// Last `EquatableTerminalView` value cached for the user-Equatable
    /// fast path in `updateNode`. Stored as `Any` so the type-erased
    /// reconciler can compare new vs cached without naming the generic
    /// content type. Nil before the first build of a composite.
    public var lastEquatableInput: Any?

    /// Last raw view value cached for the Mirror-based reflective
    /// compare in `updateNode`. Stored for every composite — when a
    /// fresh value arrives and `Mirror`-walking it field-by-field shows
    /// equality with this cache, `evaluateBody` can be skipped exactly
    /// like the Equatable wrapper path. Closures and incomparable
    /// reference types defeat the compare (the documented parity
    /// ceiling — see `AttributeGraph.reflectiveEqual`). Nil before the
    /// first `updateNode` for this composite.
    public var lastInputView: Any?

    /// Closure that re-runs this node's body with the cached view value.
    /// Captured by `evaluateBody` / `constructComposite` where the
    /// generic view type `V` is still in scope; invoked by
    /// `AttributeGraph.drain()` to re-evaluate dirty nodes in place
    /// without reflecting over `V`. Nil for non-composite nodes.
    public var bodyReplay: ((AttributeGraph, AttributeNode) -> Void)?

    /// EnvironmentValues snapshot captured during the render walk. The
    /// renderer writes the in-flight `GraphContext.currentEnvironment`
    /// here at every node it visits, so handlers and tooling can read
    /// per-subtree resolved env between events without a replay walk.
    /// SwiftUI's `@Environment` reads target the same kind of cache;
    /// matching the shape unlocks future preview tooling that asks
    /// "what does this node see?" without re-running the world.
    /// Underscored: framework-internal access pending a deliberate
    /// public preview API. Cleared on `markDirty` so a stale env
    /// value cannot survive an env-modifier change.
    public var _resolvedEnv: EnvironmentValues?

    /// The environment values this node's body read the last time it ran,
    /// and what each was, recorded by `@TerminalEnvironment` as it is read.
    /// A change to a value that is not in here cannot change what the body
    /// produces, so it need not run again — this is what lets a focus change
    /// re-run only the bodies that asked whether they are focused, and a
    /// theme switch re-run only the bodies that drew with the theme.
    /// Each entry answers whether an environment still holds the value read.
    var environmentReads: [AnyKeyPath: (EnvironmentValues) -> Bool] = [:]

    /// Whether any value this body read is different in `environment`.
    func environmentReadsDiffer(from environment: EnvironmentValues) -> Bool {
        environmentReads.values.contains { holdsValueRead in !holdsValueRead(environment) }
    }

    /// Focus granularity in force where this node was built, or nil when the
    /// author expressed no preference and the container's own shape decides.
    ///
    /// Captured at construction rather than read from `_resolvedEnv`, which is
    /// only written during render: the runtime rebuilds the focus index and
    /// auto-focuses *before* the first frame is drawn, so a render-time read
    /// would silently ignore the author's choice on the frame that picks the
    /// initially focused node.
    public var focusGranularity: FocusGranularity?

    /// Scroll offset for scroll layout nodes — persisted across frames.
    /// Positive values scroll content left (horizontal) or up (vertical).
    public var scrollOffset: Int = 0

    /// The offset a `.defaultScrollAnchor(_:)` put this scroll node at on the
    /// last render, nil before one has. While the offset is still there, the
    /// reader has not scrolled away from the anchor.
    var scrollAnchoredOffset: Int?

    /// For a scroll node under `.scrollPosition(id:anchor:)` with a binding:
    /// the position it last agreed with the app on — the id, and the offset
    /// that id meant. A bound id that differs is the app moving the view; an
    /// offset that differs is the reader moving it.
    var scrollPositionSeen: (id: AnyHashable?, offset: Int)?

    /// For a scroll node under `.onScrollTargetVisibilityChange`: the ids last
    /// reported as seen, so an unchanged set is not reported again.
    var scrollVisibleSeen: [AnyHashable]?

    /// How far the scroll content actually *draws* along its axis, as opposed
    /// to how tall it declares itself. Stamped each render, nil until then.
    ///
    /// Content padded out by a fixed frame or a trailing spacer measures taller
    /// than it draws, and an affordance derived from the measurement promises
    /// content that is not there: a list sitting on its last row still showed
    /// ▼ and still scrolled, into blank space, which reads as a stuck pane
    /// rather than as the end of the list.
    public var scrollDrawnExtent: Int?

    /// For a vertical scroll node: the width render last laid its content
    /// out at, and the viewport width it chose that for. The passes that
    /// place the offset before render measure at it.
    var scrollContentWidth: (viewport: Int, content: Int)?

    /// The cells this frame's render painted with a scrollbar and its edge
    /// indicators, or nil when the content fits and nothing was drawn.
    ///
    /// Stamped by the renderer rather than re-derived at click time so the
    /// cells that respond are exactly the cells the user can see. The two
    /// would have to agree on the viewport, the content extent and whether
    /// indicators are visible at all — three chances to drift apart.
    public var scrollAffordanceRect: Rect?

    /// Per-child ratios for SplitView (LayoutKind.split). Populated
    /// at graph construction; consumed by Layout.measureAndPlace to
    /// distribute width/height across siblings.
    /// Empty for any non-split layout.
    public var splitRatios: [Double] = []

    /// `ActionScope` attached to this node by the `.actions { ... }`
    /// modifier. The runtime's input dispatcher walks the focus chain
    /// to root collecting scopes and matches input bindings against
    /// the aggregate. Nil for nodes with no `.actions` modifier.
    /// Cleared and re-stamped during the modifier's lifecycle hook so
    /// reconciliation refreshes the bindings cleanly.
    public var _actionScope: ActionScope?

    /// Input handlers stamped by the `.onKeyPress` / `.onClick` / `.onPaste` /
    /// `.onHover` modifiers, kept on the node rather than only in the
    /// `FocusEngine`'s tables.
    ///
    /// The live run loop clears the engine's handler tables every frame and
    /// re-registers during graph update. A *cached* composite subtree is
    /// skipped by `evaluateBody`, so its handlers would never be re-registered
    /// and the control would go dead. Because the node object persists across a
    /// cached update, storing the handler here lets `FocusEngine.rebuildIndex`
    /// — which walks every node unconditionally — re-register it regardless of
    /// whether the body re-ran. Registration is thus a function of tree shape,
    /// the same principle containment stamping uses.
    public var _keyHandler: ((KeyEvent) -> KeyEventResult)?
    public var _clickHandler: ((Int, Int) -> Void)?

    /// Memoised: true iff this node OR any descendant has `.viewBody`
    /// kind. Filled bottom-up at the end of `AttributeGraph.update(from:)`
    /// so `GraphMeasurer.containsViewBody` is O(1) on the measurement
    /// hot path. Nil before the first stamp; the helper falls back to
    /// a lazy descendant walk that fills the cache and returns the
    /// correct answer either way.
    public var _containsViewBody: Bool?

    /// Memoised alongside `_containsViewBody`: true iff this node or a
    /// descendant read the environment, or might without the walk knowing —
    /// a reader's content is rebuilt during layout, after the stamp. Nil
    /// before the first stamp, which counts as true.
    var _readsEnvironmentBelow: Bool?

    /// Last `Size` `geometryRebuilder` was invoked at by the layout
    /// phase. Render reads this to confirm the GR's child subtree is
    /// already laid out at the rect's size; if not (the rare case of
    /// a renderer-only call path that bypassed `Layout.measureAndPlace`),
    /// render falls back to firing the rebuilder defensively. The
    /// runtime always calls Layout first so production render is pure.
    public var _lastLaidOutSize: Size?

    /// GeometryReader rebuild hook. When non-nil the renderer invokes this
    /// with the node's actual rect size each frame. The closure rebuilds the
    /// `geom.content(size)` view value and *updates* the existing child
    /// subtree in place — preserving NodeIDs, `@TerminalState` storage,
    /// focus registrations, and lifecycle bookkeeping. The
    /// previous implementation replaced `node.children` wholesale on every
    /// render, which destroyed identity.
    ///
    /// The closure receives the owning node so it can locate the existing
    /// child (`node.children.first`) before deciding whether to update or
    /// rebuild (e.g. on the very first render before any seed exists).
    public var geometryRebuilder: ((Size, AttributeNode) -> Void)?

    /// What a reader node takes from its container, or nil for any other
    /// node. Set alongside ``geometryRebuilder``; the passes read it to decide
    /// whether the reader is told its height or measures it.
    public var readerSizing: ReaderSizing?

    /// The width and graph update a reader's content was last built for —
    /// the memo `WidthReader` rebuilds consult.
    var _readerBuild: (width: Int, generation: Int)?

    /// Creates a node, dirty by default so the first update evaluates it,
    /// and snapshots the focus granularity in force at the construction
    /// site — see ``focusGranularity`` for why render-time reads are too late.
    public init(id: NodeID, kind: NodeKind) {
        self.id = id
        self.kind = kind
        // The env-modifier walk binds `currentEnvironment` around the
        // construction of a modifier's children, so this reads the author's
        // preference for the subtree this node is being built into.
        self.focusGranularity = GraphContext.currentEnvironment?.focusGranularity
    }

    /// Every node above this one, root first.
    var ancestors: [AttributeNode] {
        var chain: [AttributeNode] = []
        var current = parent
        while let ancestor = current {
            chain.append(ancestor)
            current = ancestor.parent
        }
        chain.reverse()
        return chain
    }

    /// The parent, unless this node is what a modal presents. A presentation
    /// owns the keyboard as it owns the screen, so a key — or an action's
    /// binding — that its content does not take must not climb out into the
    /// view that declared it: modality "prevents interaction with the parent
    /// view" (Apple HIG, Patterns → Modality).
    var parentWithinPresentation: AttributeNode? {
        guard let parent, parent.presentedContent !== self else { return nil }
        return parent
    }

    /// Whether this node is `subtree` or lies below it.
    func isWithin(_ subtree: AttributeNode) -> Bool {
        var current: AttributeNode? = self
        while let candidate = current {
            if candidate === subtree { return true }
            current = candidate.parent
        }
        return false
    }

    /// The content this node presents over the screen — the second child of
    /// a presented modal — or nil when it presents nothing.
    var presentedContent: AttributeNode? {
        guard case .modifier(.modal(let isPresented)) = kind, isPresented,
              children.count > 1 else { return nil }
        return children[1]
    }

    /// Mark this node and its layout ancestors as needing re-evaluation.
    /// Also invalidates cached measurements up the tree.
    public func markDirty() {
        isDirty = true
        cachedWidth = nil
        cachedHeight = nil
        cachedHeightWidth = nil
        _resolvedEnv = nil
        parent?.markLayoutDirty()
    }

    /// Writes what this node sets in the environment of the nodes below it:
    /// an environment modifier's values, and — for a focusable node — whether
    /// focus is on it, which is what `isFocused` reads in its content.
    func applyEnvironment(to env: inout EnvironmentValues) {
        switch kind {
        case .modifier(.environment(let apply)): apply(&env)
        case .modifier(.focusable): env.isFocused = env.focusedID == id
        default: break
        }
    }

    /// Whether ``applyEnvironment(to:)`` writes anything.
    var setsEnvironment: Bool {
        switch kind {
        case .modifier(.environment), .modifier(.focusable): true
        default: false
        }
    }

    /// Mark layout dirty up the tree and invalidate measurement caches.
    func markLayoutDirty() {
        cachedWidth = nil
        cachedHeight = nil
        cachedHeightWidth = nil
        if case .layout = kind {
            isDirty = true
        }
        parent?.markLayoutDirty()
    }
}

/// Discriminated node kind — switch on this, never `as?` cast.
public enum NodeKind {
    /// A leaf that draws cells directly; see ``PrimitiveContent``.
    case primitive(PrimitiveContent)
    /// A container that positions children (stack, scroll, split…).
    case layout(LayoutInfo)
    /// A modifier applied to the subtree beneath it.
    case modifier(ModifierEffect)
    /// A user view's evaluated `body` — one node per composite view.
    case viewBody(ViewBodyInfo)

    /// Quick kind checks for reconciliation type-safety.
    var isPrimitive: Bool {
        if case .primitive = self { return true }
        return false
    }

    func isLayout(_ kind: LayoutKind) -> Bool {
        if case .layout(let info) = self { return info.kind == kind }
        return false
    }

    var isModifier: Bool {
        if case .modifier = self { return true }
        return false
    }

    var isViewBody: Bool {
        if case .viewBody = self { return true }
        return false
    }
}

#if DEBUG
extension NodeKind {
    var debugName: String {
        switch self {
        case .primitive(let c):
            switch c {
            case .text: "Text"
            case .spacer: "Spacer"
            case .divider: "Divider"
            case .progressBar: "ProgressBar"
            case .spinner: "Spinner"
            case .empty: "Empty"
            case .cellBuffer: "BufferView"
            }
        case .layout(let info):
            switch info.kind {
            case .vstack: "VStack"
            case .hstack: "HStack"
            case .zstack: "ZStack"
            case .scroll(let axis):
                axis == .horizontal ? "ScrollView(H)" : "ScrollView(V)"
            case .split(let axis):
                axis == .horizontal ? "SplitView(H)" : "SplitView(V)"
            }
        case .modifier(let effect):
            switch effect {
            case .foreground: "fg"
            case .background: "bg"
            case .bold: "bold"
            case .italic: "italic"
            case .underline: "underline"
            case .padding: "padding"
            case .border: "border"
            case .frame: "frame"
            case .flexible: "flexible"
            case .explicitID: "id"
            case .overlay: "overlay"
            case .backgroundView: "bgView"
            case .modal: "modal"
            case .focusable: "focusable"
            case .focusScope: "focusScope"
            case .prefersDefaultFocus: "prefersDefaultFocus"
            case .onKeyPress: "onKeyPress"
            case .onAppear: "onAppear"
            case .onChange: "onChange"
            case .onDisappear: "onDisappear"
            case .task: "task"
            case .onClick: "onClick"
            case .onHover: "onHover"
            case .onPaste: "onPaste"
            case .environment: "environment"
            case .actions: "actions"
            }
        case .viewBody(let info):
            info.viewTypeName
        }
    }
}
#endif

// MARK: - Primitive

/// What a `.primitive` leaf node draws — the closed set of contents the
/// renderer's enum dispatch understands.
public enum PrimitiveContent {
    /// Styled text runs; `\n` in a span starts a new row.
    case text([TextSpan])
    /// Elastic blank space along the enclosing stack's axis.
    case spacer
    /// A one-cell rule across the enclosing stack's cross axis.
    case divider
    /// A determinate progress row: `value` is the completed fraction in
    /// `0...1`, drawn with `filled`/`empty` glyphs.
    case progressBar(value: Double, label: String?, filled: Character, empty: Character)
    /// One animated glyph — frame `frame` of `style`'s cycle.
    case spinner(frame: Int, style: SpinnerStyle)
    /// Renders nothing and occupies no cells.
    case empty
    /// Pre-rasterized cell content. The renderer blits `source[x, y]`
    /// to `buffer[rect.x + x, rect.y + y]` for the intersection of
    /// the source's dimensions and the rect — including `.empty`
    /// source cells, which is the deliberate divergence from the
    /// ScrollView local-buffer pattern.
    case cellBuffer(CellBuffer)
}

// MARK: - Layout

/// Parameters a `.layout` node carries — which container algorithm runs,
/// plus the spacing and alignment the container was declared with.
public struct LayoutInfo {
    /// The container algorithm that positions this node's children.
    public var kind: LayoutKind
    /// Child sizes cached by the most recent measurement pass, in child order.
    public var childSizes: [Size] = []
    /// `true` when the layout node was synthesized by a result builder
    /// (TupleView) or by `ForEach`. Structural vstacks are transparent
    /// to focus navigation and measurement routing — they don't
    /// introduce a new axis the way a user-written `VStack` does. Set
    /// at construction time so the heuristic-based detector (which mis-
    /// classified user VStacks nested inside composite bodies) is
    /// replaced by a hard, reliable flag.
    public var isStructural: Bool = false

    /// Blank cells the stack leaves between children. Zero for structural
    /// stacks — a result builder's grouping is not a place the author asked
    /// for a gap.
    public var spacing: Int = 0

    /// Where a child narrower or shorter than the stack's cross axis sits.
    /// Both stacks and `ZStack` carry the pair; each reads the one it needs.
    public var alignment: Alignment = .topLeading

    /// Creates layout info for a container node; defaults describe an
    /// author-written, unspaced, top-leading-aligned container.
    public init(kind: LayoutKind, isStructural: Bool = false,
                spacing: Int = 0, alignment: Alignment = .topLeading) {
        self.kind = kind
        self.isStructural = isStructural
        self.spacing = spacing
        self.alignment = alignment
    }
}

/// The container algorithm a layout node runs — one case per layout
/// primitive the graph lays out natively.
public enum LayoutKind: Equatable {
    /// Children stacked top-to-bottom.
    case vstack
    /// Children laid side-by-side, left-to-right.
    case hstack
    /// Children overlaid in declaration order, later ones drawn on top.
    case zstack
    /// A viewport over content larger than the assigned rect, offset along
    /// the given axis by the node's persisted `scrollOffset`.
    case scroll(ScrollAxis)
    /// Resizable split container with explicit per-child ratios.
    /// Children laid side-by-side (`.horizontal`) or stacked
    /// (`.vertical`) with one cell of divider between siblings.
    /// Per-child ratios live on the AttributeNode itself
    /// (`splitRatios`); read by Layout to distribute width/height.
    case split(SplitAxis)
}

/// A two-dimensional extent in terminal cells — the currency of the
/// measurement pass, where every node reports how many columns and rows
/// it wants within the space it was offered.
public struct Size: Equatable, Sendable {
    /// Horizontal extent in cells (columns).
    public var width: Int
    /// Vertical extent in cells (rows).
    public var height: Int

    /// Create a size from cell counts.
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// The empty size (0 × 0) — what zero-content views measure to.
    public static let zero = Size(width: 0, height: 0)
}

// MARK: - Modifier

extension Optional where Wrapped == Color {
    /// A background effect's colour as the debug tools print it.
    var groundDescription: String { map { "\($0)" } ?? "inherited" }
}

/// The render/layout-time effect a modifier node applies to its child
/// subtree, carried in ``NodeKind/modifier(_:)``.
///
/// One enum rather than open dispatch keeps the render hot path a switch:
/// `GraphRenderer.renderModifier` gives every case its drawing meaning, and
/// layout consults the geometry-affecting cases (`.padding`, `.border`,
/// `.frame`, `.flexible`) when measuring. Handler-shaped cases carry no
/// payload — the closure lives on the node or on `FocusEngine`, keeping this
/// enum free of generic parameters.
public enum ModifierEffect {
    /// Sets the foreground (text) color for the subtree's styled cells.
    case foreground(Color)
    /// Sets the background color for the subtree's styled cells; `nil`
    /// leaves them on the ground they inherit.
    case background(Color?)
    /// Renders the subtree's text bold.
    case bold
    /// Renders the subtree's text italic.
    case italic
    /// Renders the subtree's text underlined.
    case underline
    /// Insets the child's rect by the given cell count on all four sides;
    /// layout stamps the inset rect, render passes it through unchanged.
    case padding(EdgeInsets)
    /// Draws the requested border edges at the node's outer rect and insets
    /// the child one cell per drawn edge. A nil colour inherits the
    /// surrounding foreground.
    case border(BorderStyle, Color?, BorderEdges)
    /// Clamps the child's rect to the given exact/min/max dimensions and
    /// places smaller content within the frame by `alignment`; `.infinity`
    /// maxima opt the axis into stack flex distribution.
    case frame(width: Int?, height: Int?, minWidth: FrameDimension?, maxWidth: FrameDimension?, minHeight: FrameDimension?, maxHeight: FrameDimension?, alignment: Alignment)
    /// `.flexible(_:grow:)` — opt-in flex distribution along `axes`.
    /// Inside a stack on the matching axis, the renderer treats this
    /// child like a `Spacer` for distribution purposes but renders the
    /// wrapped content into the allocated rect. `grow` weights the
    /// share when multiple flex siblings compete for the remainder.
    case flexible(axes: FrameAxes, grow: Int)
    /// Splices a user-provided identity (`.id(...)`) into the child's node
    /// path so state and focus follow the value, not the position. No
    /// visual effect.
    case explicitID(AnyHashable)
    /// Renders the base, then the second child on top of it, placed by
    /// `alignment` within the base view's own frame.
    case overlay(alignment: Alignment)     // child[0] = base, child[1] = overlay content
    /// Renders the background child first, then the base over it, so the
    /// base's cells win wherever both draw.
    case backgroundView(alignment: Alignment)  // child[0] = background content, child[1] = base (render bg first)
    /// Renders the base always; while presented, defers the panel child to
    /// composite over the full screen after the main walk, trapping focus
    /// inside it (containment).
    case modal(isPresented: Bool) // child[0] = base, child[1] = modal content (when presented)
    /// Marks the child able to receive keyboard focus; the focus indicator
    /// is drawn after the main render pass.
    case focusable   // marks the child as able to receive focus
    /// Groups focusable descendants under one scope id: arrow navigation
    /// stays inside the scope, Tab still crosses it. No visual effect.
    case focusScope(String) // groups focusable descendants; arrows stay within
    /// When true, marks the first focusable in the subtree as the one
    /// focused when nothing is. No visual effect; Tab order is unchanged.
    case prefersDefaultFocus(Bool)
    /// Attaches a key handler that fires while the subtree holds keyboard
    /// focus; render is a pass-through.
    case onKeyPress  // attaches a key handler (handler stored on FocusEngine, not here)
    /// Fires its action once, when the node first joins the tree.
    case onAppear    // fires action on first graph construction (tracked on node)
    /// Fires its action when the observed value differs from the last value
    /// stored on the node.
    case onChange    // fires action when bound value changes (last value stored on node)
    /// Fires its action when the node leaves the tree.
    case onDisappear // fires action when node is removed from the tree
    /// `.task { }` — async work owned by the node: started when the node
    /// first appears, cancelled when it leaves the tree. The handle lives on
    /// the node (`_lifecycleTask`) because `body` rebuilds the closure every
    /// frame, so a handle captured in the modifier would be a different one
    /// by the time anything came to cancel it.
    case task
    /// Attaches a mouse-click handler, dispatched with rect-relative
    /// coordinates when the click lands inside the child's rect.
    case onClick     // attaches click handler (handler stored on FocusEngine)
    /// Attaches a hover handler fired on cursor enter/leave transitions
    /// over the child's rect.
    case onHover     // attaches hover handler (handler stored on FocusEngine)
    /// Attaches a handler for bracketed-paste payloads routed to the
    /// keyboard-focused subtree.
    case onPaste     // attaches paste handler (handler stored on FocusEngine)
    /// `.actions { ... }` attaches an `ActionScope` to the modifier
    /// node. The runtime's input dispatcher walks the focus chain to
    /// root collecting these scopes and matches input bindings against
    /// the aggregate. Scope is stored on the node's `_actionScope`
    /// field so the walker reads it without re-deriving from the
    /// modifier value.
    case actions(ActionScope)
    /// Environment-value setter. The closure applies the modifier's keyPath
    /// and value to a mutable `EnvironmentValues` during render so descendants
    /// observe the new value via `GraphContext.currentEnvironment`. Boxing as
    /// a closure keeps the ModifierEffect enum free of generic parameters
    /// (the keypath/value pair is type-erased at construction time).
    case environment((inout EnvironmentValues) -> Void)
}
extension ModifierEffect {
    /// How a detached layer merges with the content it covers.
    ///
    /// Stated once, next to the effect it belongs to, so the renderer reads
    /// the decision instead of making it. The switch is exhaustive over the
    /// layering effects, so adding one forces an answer here rather than
    /// letting a call site copy whichever neighbour it was written beside.
    ///
    /// The distinction is not cosmetic: `.transparent` skips empty cells, so
    /// a *presentation's* own padding and inter-glyph gaps would let the
    /// background bleed through it, while *decoration* genuinely wants the
    /// content beneath to remain visible.
    var compositingStyle: Layer.LayerStyle {
        switch self {
        // Presentation — must occlude. Padding and inter-glyph gaps belong
        // to the panel, not to whatever it covers.
        case .modal: .opaque
        // Decoration — the content beneath is meant to stay visible.
        case .overlay, .backgroundView: .transparent
        // Every other effect is not a detached layer and never reaches the
        // compositor. Listed explicitly rather than via `default:` so adding
        // a layering effect is a compile error here instead of silently
        // inheriting whichever style happened to be the fallback.
        case .foreground, .background, .bold, .italic, .underline,
             .padding, .border, .frame, .flexible, .explicitID,
             .focusable, .focusScope, .prefersDefaultFocus, .onKeyPress, .onAppear, .onChange,
             .onDisappear, .onClick, .onHover, .onPaste, .actions,
             .environment, .task:
            .opaque
        }
    }
}


// MARK: - View Body

/// Type-erased container for a view body node.
public final class ViewBodyInfo {
    /// The composite view's Swift type name, for debug output and the
    /// inspector.
    public var viewTypeName: String

    /// Creates the container recording the view's type name.
    public init(viewTypeName: String) {
        self.viewTypeName = viewTypeName
    }
}
