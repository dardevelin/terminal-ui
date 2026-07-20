public enum BorderStyle: Sendable {
    case plain
    case rounded
    case heavy
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
