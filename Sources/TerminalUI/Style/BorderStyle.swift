/// The character set used to draw a border: corners, horizontals, and
/// verticals.
///
/// Each border occupies one cell of thickness on every edge — the glyphs
/// come from Unicode's Box Drawing block (except ``plain``, which is
/// pure ASCII for terminals or fonts without box-drawing coverage).
/// Applied via the `.border(_:)` modifier and, for themed components,
/// through ``Theme/border``.
///
/// ```swift
/// Text("hello").border(.rounded)   // ╭─╮ │ ╰─╯
/// Text("ascii").border(.plain)     // +-+ | +-+
/// ```
public enum BorderStyle: Sendable {
    /// ASCII-only border: `+` corners, `-` horizontals, `|` verticals.
    /// Safe under any font or encoding.
    case plain
    /// Light box-drawing lines with rounded corners: `╭─╮ │ ╰─╯`.
    /// The framework default (see ``DefaultTheme``).
    case rounded
    /// Heavy box-drawing lines, square corners: `┏━┓ ┃ ┗━┛`.
    case heavy
    /// Double-line box drawing, square corners: `╔═╗ ║ ╚═╝`.
    case double

    var topLeft: Character {
        switch self {
        case .plain: "+"
        case .rounded: "╭"
        case .heavy: "┏"
        case .double: "╔"
        }
    }

    var topRight: Character {
        switch self {
        case .plain: "+"
        case .rounded: "╮"
        case .heavy: "┓"
        case .double: "╗"
        }
    }

    var bottomLeft: Character {
        switch self {
        case .plain: "+"
        case .rounded: "╰"
        case .heavy: "┗"
        case .double: "╚"
        }
    }

    var bottomRight: Character {
        switch self {
        case .plain: "+"
        case .rounded: "╯"
        case .heavy: "┛"
        case .double: "╝"
        }
    }

    var horizontal: Character {
        switch self {
        case .plain: "-"
        case .rounded: "─"
        case .heavy: "━"
        case .double: "═"
        }
    }

    var vertical: Character {
        switch self {
        case .plain: "|"
        case .rounded: "│"
        case .heavy: "┃"
        case .double: "║"
        }
    }
}

/// Which sides of the box a `.border(_:)` actually draws.
///
/// A full ring is the common case and stays the default. Naming a subset is
/// for the frame that carries *meaning* rather than enclosure — the single
/// coloured rail down the left of a chat message or a log entry, marking
/// author and focus state without boxing the content in. That rail is one
/// column wide, so only the leading edge is drawn and only the leading edge
/// is inset.
///
/// ```swift
/// Text(message).border(.heavy, color: .cyan, edges: .leading)
/// ```
///
/// Corners resolve from what meets there: a glyph is used only where both of
/// its edges are present, and otherwise the surviving edge runs straight
/// through. `.top` alone draws an unbroken horizontal rule, not a rule with
/// two corner pieces stuck on its ends.
///
/// Matches SwiftUI's `Edge.Set` in both names and groupings, so `.horizontal`
/// is the leading/trailing pair and `.vertical` the top/bottom one.
public struct BorderEdges: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let top = BorderEdges(rawValue: 1 << 0)
    public static let leading = BorderEdges(rawValue: 1 << 1)
    public static let bottom = BorderEdges(rawValue: 1 << 2)
    public static let trailing = BorderEdges(rawValue: 1 << 3)

    /// The leading and trailing edges — the vertical pair, named for the axis
    /// they span, as in SwiftUI.
    public static let horizontal: BorderEdges = [.leading, .trailing]
    /// The top and bottom edges.
    public static let vertical: BorderEdges = [.top, .bottom]
    /// All four — the default, and a full box.
    public static let all: BorderEdges = [.top, .leading, .bottom, .trailing]

    /// Columns this edge set consumes: one per vertical edge drawn.
    var horizontalInset: Int {
        (contains(.leading) ? 1 : 0) + (contains(.trailing) ? 1 : 0)
    }

    /// Rows this edge set consumes: one per horizontal edge drawn.
    var verticalInset: Int {
        (contains(.top) ? 1 : 0) + (contains(.bottom) ? 1 : 0)
    }
}
