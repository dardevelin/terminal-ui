public enum Color: Sendable {
    case `default`
    case black
    case red
    case green
    case yellow
    case blue
    case magenta
    case cyan
    case white
    case gray
    case brightRed
    case brightGreen
    case brightYellow
    case brightBlue
    case brightMagenta
    case brightCyan
    case brightWhite
    case ansi256(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    var foregroundCode: String {
        switch self {
        case .default: "\u{1B}[39m"
        case .black: "\u{1B}[30m"
        case .red: "\u{1B}[31m"
        case .green: "\u{1B}[32m"
        case .yellow: "\u{1B}[33m"
        case .blue: "\u{1B}[34m"
        case .magenta: "\u{1B}[35m"
        case .cyan: "\u{1B}[36m"
        case .white: "\u{1B}[37m"
        case .gray: "\u{1B}[90m"
        case .brightRed: "\u{1B}[91m"
        case .brightGreen: "\u{1B}[92m"
        case .brightYellow: "\u{1B}[93m"
        case .brightBlue: "\u{1B}[94m"
        case .brightMagenta: "\u{1B}[95m"
        case .brightCyan: "\u{1B}[96m"
        case .brightWhite: "\u{1B}[97m"
        case .ansi256(let n): "\u{1B}[38;5;\(n)m"
        case .rgb(let r, let g, let b): "\u{1B}[38;2;\(r);\(g);\(b)m"
        }
    }

    var backgroundCode: String {
        switch self {
        case .default: "\u{1B}[49m"
        case .black: "\u{1B}[40m"
        case .red: "\u{1B}[41m"
        case .green: "\u{1B}[42m"
        case .yellow: "\u{1B}[43m"
        case .blue: "\u{1B}[44m"
        case .magenta: "\u{1B}[45m"
        case .cyan: "\u{1B}[46m"
        case .white: "\u{1B}[47m"
        case .gray: "\u{1B}[100m"
        case .brightRed: "\u{1B}[101m"
        case .brightGreen: "\u{1B}[102m"
        case .brightYellow: "\u{1B}[103m"
        case .brightBlue: "\u{1B}[104m"
        case .brightMagenta: "\u{1B}[105m"
        case .brightCyan: "\u{1B}[106m"
        case .brightWhite: "\u{1B}[107m"
        case .ansi256(let n): "\u{1B}[48;5;\(n)m"
        case .rgb(let r, let g, let b): "\u{1B}[48;2;\(r);\(g);\(b)m"
        }
    }
}
