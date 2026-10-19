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
/// The same type as SwiftUI-named ``Edge/Set``, so a border and padding name
/// their sides alike.
public typealias BorderEdges = Edge.Set

extension Edge.Set {
    /// Columns this edge set consumes as a border: one per vertical edge drawn.
    var horizontalInset: Int {
        (contains(.leading) ? 1 : 0) + (contains(.trailing) ? 1 : 0)
    }

    /// Rows this edge set consumes as a border: one per horizontal edge drawn.
    var verticalInset: Int {
        (contains(.top) ? 1 : 0) + (contains(.bottom) ? 1 : 0)
    }
}
