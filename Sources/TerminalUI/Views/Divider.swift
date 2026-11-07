/// A line separator that adapts to its enclosing stack.
///
/// Inside a `VStack`, it renders as a horizontal rule across the container width.
/// Inside an `HStack`, it renders as a vertical rule down the container height.
/// The nearest enclosing stack decides, wherever the divider is written in
/// it — in a `ForEach`, behind a condition, as a view's `body` — and in a
/// `ZStack`, or outside any stack, it rules across.
///
/// The rule is exactly one cell thick — drawn with box-drawing glyphs, so
/// it lines up with ``BorderStyle`` frames — and stretches edge to edge of
/// the container on its long axis without adding to it: a rule down an
/// `HStack` is as tall as the stack's other children make it. It inherits
/// the ambient text style, which means a dim or colored divider comes from
/// the same modifiers as any other view. Reach for `Divider` to separate
/// sections inside one container; when the two sides are independent
/// resizable panes, that is ``SplitView``'s job (it draws its own dividers
/// between panes).
///
/// ```swift
/// VStack {
///     Text("above")
///     Divider()
///     HStack {
///         Text("left")
///         Divider()
///         Text("right")
///     }
/// }
/// ```
public struct Divider: TerminalView {
    /// Creates a divider; orientation comes from the enclosing stack, not
    /// from any argument.
    public init() {}
    @_documentation(visibility: internal)
    public var body: Never { fatalError() }
}

/// Which way a ``Divider`` rules, set by its nearest enclosing stack for
/// the subtree under it: down an `HStack`, along a `VStack` or `ZStack`.
/// Carried in the environment rather than read off the divider's parent,
/// so a divider a `ForEach`, a condition or a view's `body` places is ruled
/// by the stack it actually lands in.
enum DividerOrientation: Sendable {
    case horizontal
    case vertical

    /// U+2500 BOX DRAWINGS LIGHT HORIZONTAL and U+2502 BOX DRAWINGS LIGHT
    /// VERTICAL: the light lines ``BorderStyle`` edges are drawn with, so a
    /// rule meets a frame without a change of weight.
    var glyph: Character {
        switch self {
        case .horizontal: "─"
        case .vertical: "│"
        }
    }
}
