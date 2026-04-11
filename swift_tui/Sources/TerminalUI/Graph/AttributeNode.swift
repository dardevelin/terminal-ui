/// Base class for all nodes in the attribute graph.
/// Persistent across frames — created once, updated in place.
public class AttributeNode {
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
    public var stateSlots: [AnyStateStorage] = []

    /// Whether this node can receive focus (set by .focusable() modifier).
    public var isFocusable: Bool = false

    /// Whether onAppear has already fired for this node.
    public var didAppear: Bool = false

    public init(id: NodeID, kind: NodeKind) {
        self.id = id
        self.kind = kind
    }

    /// Mark this node and its layout ancestors as needing re-evaluation.
    public func markDirty() {
        isDirty = true
        parent?.markLayoutDirty()
    }

    /// Mark layout dirty up the tree.
    func markLayoutDirty() {
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
}

// MARK: - Primitive

public enum PrimitiveContent {
    case text(String)
    case spacer
    case divider
    case progressBar(value: Double, label: String?, filled: Character, empty: Character)
    case spinner(frame: Int, style: SpinnerStyle)
    case empty
}

// MARK: - Layout

public struct LayoutInfo {
    public var kind: LayoutKind
    public var childSizes: [Size] = []

    public init(kind: LayoutKind) {
        self.kind = kind
    }
}

public enum LayoutKind {
    case vstack
    case hstack
    case zstack
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
    case frame(width: Int?, height: Int?)
    case explicitID(AnyHashable)
    case overlay     // child[0] = base, child[1] = overlay content
    case backgroundView  // child[0] = background content, child[1] = base (render bg first)
    case modal(isPresented: Bool) // child[0] = base, child[1] = modal content (when presented)
    case focusable   // marks the child as able to receive focus
    case onKeyPress  // attaches a key handler (handler stored on FocusEngine, not here)
    case onAppear    // fires action on first graph construction (tracked on node)
    case onClick     // attaches click handler (handler stored on FocusEngine)
}

// MARK: - View Body

/// Type-erased container for a view body node.
/// The generic concrete type is captured in the closure.
public final class ViewBodyInfo {
    /// Closure that re-evaluates the body and updates children in the graph.
    public var evaluate: ((AttributeNode, AttributeGraph) -> Void)?
    /// Name for debugging
    public var viewTypeName: String

    public init(viewTypeName: String) {
        self.viewTypeName = viewTypeName
    }
}
