/// Token categories recognised by a `SyntaxHighlighter`. Finite enum
/// so a `SyntaxTheme` can map each kind to a foreground color
/// without runtime introspection.
public enum SyntaxToken: Sendable, Equatable {
    /// Reserved language word — `func`, `var`, `if`, `return`, etc.
    case keyword
    /// Quoted string literal (including its delimiters).
    case string
    /// Single-line `// …` comment OR multi-line `/* … */` comment.
    case comment
    /// Integer or floating-point literal.
    case number
    /// UpperCamelCase identifier — types, structs, classes, enums.
    case type
    /// Function-call identifier (lowerCamelCase followed by `(`).
    case function
    /// Operator characters — `+ - * / = < > !` etc.
    /// Named `operatorToken` (not `operator`) because `operator` is
    /// a reserved keyword in Swift and can't be a bare enum case name.
    case operatorToken
    /// Anything else — falls back to the editor's default color.
    case plain
}

/// One highlighted span produced by a `SyntaxHighlighter` —
/// `range` covers the substring of the source line, `token` is the
/// classification.
public struct SyntaxSpan: Sendable, Equatable {
    public let range: Range<String.Index>
    public let token: SyntaxToken

    public init(range: Range<String.Index>, token: SyntaxToken) {
        self.range = range
        self.token = token
    }
}

/// Tokenizer protocol — given a single source line, returns the
/// classified spans. Stateless across calls so the highlighter
/// can be shipped as a `Sendable` value type.
///
/// Per-line tokenisation only — multi-line constructs (block
/// comments, multiline string literals) are NOT carried across
/// lines, so a `/* … */` that spans two lines highlights only
/// its first line. Stateful tokenisation can be layered on later
/// via a `tokenize(line:state:)` overload without breaking the
/// stateless callers.
public protocol SyntaxHighlighter: Sendable {
    func tokenize(line: String) -> [SyntaxSpan]
}

/// Maps each `SyntaxToken` to a foreground `Color`. App authors
/// supply a custom theme via `.syntaxTheme(_:)` (Phase B); Phase A
/// ships `SyntaxTheme.defaultDark` as the only theme.
public struct SyntaxTheme: Sendable {
    public let keyword: Color
    public let string: Color
    public let comment: Color
    public let number: Color
    public let type: Color
    public let function: Color
    public let operatorColor: Color
    public let plain: Color

    public init(
        keyword: Color,
        string: Color,
        comment: Color,
        number: Color,
        type: Color,
        function: Color,
        operatorColor: Color,
        plain: Color
    ) {
        self.keyword = keyword
        self.string = string
        self.comment = comment
        self.number = number
        self.type = type
        self.function = function
        self.operatorColor = operatorColor
        self.plain = plain
    }

    public func color(for token: SyntaxToken) -> Color {
        switch token {
        case .keyword:       return keyword
        case .string:        return string
        case .comment:       return comment
        case .number:        return number
        case .type:          return type
        case .function:      return function
        case .operatorToken: return operatorColor
        case .plain:         return plain
        }
    }

    /// Default dark theme — terminal-friendly contrast on a dark
    /// background. Tuned to be distinguishable on 256-color and
    /// truecolor terminals; degrades sensibly on 16-color.
    public static let defaultDark = SyntaxTheme(
        keyword: .magenta,
        string: .red,
        comment: .ansi256(245),
        number: .yellow,
        type: .cyan,
        function: .blue,
        operatorColor: .ansi256(250),
        plain: .default
    )
}

// MARK: - SwiftSyntaxHighlighter

/// Naive Swift tokenizer — keyword recognition + string/comment/
/// number/type categorisation. Per-line stateless: block comments
/// (`/* … */`) and multi-line string literals (`"""…"""`) are NOT
/// tracked across lines in Phase A. Apps that need full Swift
/// syntax can plug in a heavier `SyntaxHighlighter` (e.g. one
/// driven by SwiftSyntax) without changing the protocol.
///
/// Recognises the canonical Swift reserved words plus the visual
/// 80% of source-code tokens (string literals with `\"` escapes,
/// `//` comments, integer + float literals, UpperCamelCase types,
/// `name(` function calls).
public struct SwiftSyntaxHighlighter: SyntaxHighlighter {
    /// Reserved Swift words. Set lookup is `O(1)`; the closed list
    /// is cheaper than a trie for an editor's tokenization budget.
    public static let keywords: Set<String> = [
        // Declarations
        "associatedtype", "class", "deinit", "enum", "extension",
        "fileprivate", "func", "import", "init", "inout",
        "internal", "let", "open", "operator", "private",
        "precedencegroup", "protocol", "public", "rethrows", "static",
        "struct", "subscript", "typealias", "var",
        // Statements
        "break", "case", "catch", "continue", "default", "defer",
        "do", "else", "fallthrough", "for", "guard", "if",
        "in", "repeat", "return", "switch", "throw", "throws",
        "where", "while",
        // Expressions / values
        "as", "Any", "false", "is", "nil", "self", "Self",
        "super", "throws", "true", "try",
        // Modifiers / attributes used in source
        "async", "await", "actor", "convenience", "dynamic", "final",
        "indirect", "lazy", "mutating", "nonmutating", "optional",
        "override", "required", "weak", "unowned",
        // Result builder / property wrapper helpers
        "some", "any",
    ]

    public init() {}

    public func tokenize(line: String) -> [SyntaxSpan] {
        guard !line.isEmpty else { return [] }
        var spans: [SyntaxSpan] = []
        let chars = Array(line)
        var i = 0
        let n = chars.count

        while i < n {
            let c = chars[i]
            let startIdx = line.index(line.startIndex, offsetBy: i)

            // Whitespace — emit as plain (so consumers can render
            // background colors continuously without gaps). Skip
            // forward.
            if c.isWhitespace {
                let runStart = i
                while i < n && chars[i].isWhitespace { i += 1 }
                let endIdx = line.index(line.startIndex, offsetBy: i)
                let runStartIdx = line.index(line.startIndex, offsetBy: runStart)
                spans.append(SyntaxSpan(range: runStartIdx..<endIdx, token: .plain))
                continue
            }

            // Line comment `// …`
            if c == "/" && i + 1 < n && chars[i + 1] == "/" {
                let endIdx = line.endIndex
                spans.append(SyntaxSpan(range: startIdx..<endIdx, token: .comment))
                i = n
                continue
            }

            // Block comment `/* …` — terminate at `*/` if present on
            // same line, else extend to end of line (Phase A: no
            // multi-line carry).
            if c == "/" && i + 1 < n && chars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < n && !(chars[j] == "*" && chars[j + 1] == "/") {
                    j += 1
                }
                let stop = (j + 1 < n) ? j + 2 : n
                let endIdx = line.index(line.startIndex, offsetBy: stop)
                spans.append(SyntaxSpan(range: startIdx..<endIdx, token: .comment))
                i = stop
                continue
            }

            // String literal `"…"` with `\"` escapes.
            if c == "\"" {
                var j = i + 1
                while j < n {
                    if chars[j] == "\\" && j + 1 < n {
                        j += 2
                        continue
                    }
                    if chars[j] == "\"" {
                        j += 1
                        break
                    }
                    j += 1
                }
                let endIdx = line.index(line.startIndex, offsetBy: j)
                spans.append(SyntaxSpan(range: startIdx..<endIdx, token: .string))
                i = j
                continue
            }

            // Number — `[0-9][0-9._]*`. Permissive on `.` and `_`
            // so `1_000.5` and `3.14` both classify as a single
            // number.
            if c.isNumber {
                var j = i + 1
                while j < n {
                    let cj = chars[j]
                    if cj.isNumber || cj == "." || cj == "_" {
                        j += 1
                    } else {
                        break
                    }
                }
                let endIdx = line.index(line.startIndex, offsetBy: j)
                spans.append(SyntaxSpan(range: startIdx..<endIdx, token: .number))
                i = j
                continue
            }

            // Identifier — `[A-Za-z_][A-Za-z0-9_]*`. Classify via:
            //   - Set lookup → keyword
            //   - First char uppercase → type
            //   - Followed by `(` → function call
            //   - Otherwise → plain
            if c.isLetter || c == "_" {
                var j = i + 1
                while j < n {
                    let cj = chars[j]
                    if cj.isLetter || cj.isNumber || cj == "_" {
                        j += 1
                    } else {
                        break
                    }
                }
                let endIdx = line.index(line.startIndex, offsetBy: j)
                let word = String(chars[i..<j])
                let token: SyntaxToken
                if Self.keywords.contains(word) {
                    token = .keyword
                } else if c.isUppercase {
                    token = .type
                } else if j < n && chars[j] == "(" {
                    token = .function
                } else {
                    token = .plain
                }
                spans.append(SyntaxSpan(range: startIdx..<endIdx, token: token))
                i = j
                continue
            }

            // Operator characters — collected greedily so `==`, `->`
            // become single spans, not character-by-character.
            if Self.isOperatorChar(c) {
                var j = i + 1
                while j < n && Self.isOperatorChar(chars[j]) {
                    j += 1
                }
                let endIdx = line.index(line.startIndex, offsetBy: j)
                spans.append(SyntaxSpan(range: startIdx..<endIdx, token: .operatorToken))
                i = j
                continue
            }

            // Anything else (punctuation, brackets) — emit as plain.
            let endIdx = line.index(line.startIndex, offsetBy: i + 1)
            spans.append(SyntaxSpan(range: startIdx..<endIdx, token: .plain))
            i += 1
        }

        return spans
    }

    private static func isOperatorChar(_ c: Character) -> Bool {
        switch c {
        case "+", "-", "*", "/", "=", "<", ">", "!", "&", "|", "^", "~", "?":
            return true
        default:
            return false
        }
    }
}
