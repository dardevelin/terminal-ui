/// Base class for all nodes in the attribute graph.
/// Persistent across frames — created once, updated in place.
///
/// Marked `@unchecked Sendable` so it can be carried by `@TaskLocal`
/// `GraphContext.currentNode`. The runtime invariant is that all node
/// access happens on the MainActor body-eval/render call stack; the
/// `@TaskLocal` binding only crosses tasks when the runtime spawns a
/// structured child task on the same actor. The mutable state is not
/// safe to touch from arbitrary threads — see `GraphContext.swift`.
public class AttributeNode: @unchecked Sendable {
    public let id: NodeID
    public var kind: NodeKind
    public weak var parent: AttributeNode?
    public var children: [AttributeNode] = []
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
    /// Traversal selects the greatest depth present, so the topmost
    /// presentation owns focus without the engine holding its own stack —
    /// the graph already encodes the nesting, and a separate stack could
    /// drift out of sync with it.
    public var containmentDepth: Int = 0

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

    public init(id: NodeID, kind: NodeKind) {
        self.id = id
        self.kind = kind
        // The env-modifier walk binds `currentEnvironment` around the
        // construction of a modifier's children, so this reads the author's
        // preference for the subtree this node is being built into.
        self.focusGranularity = GraphContext.currentEnvironment?.focusGranularity
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
    case primitive(PrimitiveContent)
    case layout(LayoutInfo)
    case modifier(ModifierEffect)
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
            case .onKeyPress: "onKeyPress"
            case .onAppear: "onAppear"
            case .onChange: "onChange"
            case .onDisappear: "onDisappear"
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

public enum PrimitiveContent {
    case text([TextSpan])
    case spacer
    case divider
    case progressBar(value: Double, label: String?, filled: Character, empty: Character)
    case spinner(frame: Int, style: SpinnerStyle)
    case empty
    /// Pre-rasterized cell content. The renderer blits `source[x, y]`
    /// to `buffer[rect.x + x, rect.y + y]` for the intersection of
    /// the source's dimensions and the rect — including `.empty`
    /// source cells, which is the deliberate divergence from the
    /// ScrollView local-buffer pattern.
    case cellBuffer(CellBuffer)
}

// MARK: - Layout

public struct LayoutInfo {
    public var kind: LayoutKind
    public var childSizes: [Size] = []
    /// `true` when the layout node was synthesized by a result builder
    /// (TupleView) or by `ForEach`. Structural vstacks are transparent
    /// to focus navigation and measurement routing — they don't
    /// introduce a new axis the way a user-written `VStack` does. Set
    /// at construction time so the heuristic-based detector (which mis-
    /// classified user VStacks nested inside composite bodies) is
    /// replaced by a hard, reliable flag.
    public var isStructural: Bool = false

    public init(kind: LayoutKind, isStructural: Bool = false) {
        self.kind = kind
        self.isStructural = isStructural
    }
}

public enum LayoutKind: Equatable {
    case vstack
    case hstack
    case zstack
    case scroll(ScrollAxis)
    /// Resizable split container with explicit per-child ratios.
    /// Children laid side-by-side (`.horizontal`) or stacked
    /// (`.vertical`) with one cell of divider between siblings.
    /// Per-child ratios live on the AttributeNode itself
    /// (`splitRatios`); read by Layout to distribute width/height.
    case split(SplitAxis)
}

public struct Size: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let zero = Size(width: 0, height: 0)
}

// MARK: - Modifier

public enum ModifierEffect {
    case foreground(Color)
    case background(Color)
    case bold
    case italic
    case underline
    case padding(Int)
    case border(BorderStyle)
    case frame(width: Int?, height: Int?, minWidth: FrameDimension?, maxWidth: FrameDimension?, minHeight: FrameDimension?, maxHeight: FrameDimension?)
    /// `.flexible(_:grow:)` — opt-in flex distribution along `axes`.
    /// Inside a stack on the matching axis, the renderer treats this
    /// child like a `Spacer` for distribution purposes but renders the
    /// wrapped content into the allocated rect. `grow` weights the
    /// share when multiple flex siblings compete for the remainder.
    case flexible(axes: FrameAxes, grow: Int)
    case explicitID(AnyHashable)
    case overlay     // child[0] = base, child[1] = overlay content
    case backgroundView  // child[0] = background content, child[1] = base (render bg first)
    case modal(isPresented: Bool) // child[0] = base, child[1] = modal content (when presented)
    case focusable   // marks the child as able to receive focus
    case focusScope(String) // groups focusable descendants; arrows stay within
    case onKeyPress  // attaches a key handler (handler stored on FocusEngine, not here)
    case onAppear    // fires action on first graph construction (tracked on node)
    case onChange    // fires action when bound value changes (last value stored on node)
    case onDisappear // fires action when node is removed from the tree
    case onClick     // attaches click handler (handler stored on FocusEngine)
    case onHover     // attaches hover handler (handler stored on FocusEngine)
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
             .focusable, .focusScope, .onKeyPress, .onAppear, .onChange,
             .onDisappear, .onClick, .onHover, .onPaste, .actions,
             .environment:
            .opaque
        }
    }
}


// MARK: - View Body

/// Type-erased container for a view body node.
public final class ViewBodyInfo {
    /// Name for debugging
    public var viewTypeName: String

    public init(viewTypeName: String) {
        self.viewTypeName = viewTypeName
    }
}
