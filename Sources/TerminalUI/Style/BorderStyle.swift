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
