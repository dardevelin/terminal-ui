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
    /// Substring of the tokenized line this span covers. Indices are valid
    /// only against the exact `String` passed to `tokenize`.
    public let range: Range<String.Index>
    /// Classification a ``SyntaxTheme`` maps to a color.
    public let token: SyntaxToken

    /// Creates a span pairing a line range with its classification.
    public init(range: Range<String.Index>, token: SyntaxToken) {
        self.range = range
        self.token = token
    }
}

/// Carry-state for stateful tokenisation. A renderer threads the
/// same `TokenizerState` value across consecutive lines so a
/// tokenizer can remember it has an open block comment or an open
/// multiline string literal, and classify continuation lines that
/// have no opening marker on them.
///
/// Reset to a fresh `TokenizerState()` to start from the top of a
/// file. The struct is `Sendable + Equatable` so it can be cached
/// per-line (snapshot the state at the start of each line and
/// recover incremental rendering after edits).
public struct TokenizerState: Sendable, Equatable {
    /// `true` when the previous line ended inside an unclosed
    /// `/* … */` block comment.
    public var isInBlockComment: Bool
    /// `true` when the previous line ended inside an unclosed
    /// `"""…"""` multiline string literal.
    public var isInMultilineString: Bool

    /// Creates carry-state; the no-argument form is the top-of-file state
    /// (no open comment, no open multiline string).
    public init(isInBlockComment: Bool = false, isInMultilineString: Bool = false) {
        self.isInBlockComment = isInBlockComment
        self.isInMultilineString = isInMultilineString
    }
}

/// Tokenizer protocol — given a single source line, returns the
/// classified spans. The bare `tokenize(line:)` overload is
/// stateless; the `tokenize(line:state:)` overload threads a
/// `TokenizerState` so multi-line constructs (block comments,
/// multiline string literals) classify correctly on continuation
/// lines that contain no opening marker.
///
/// Implementations can override either method. The default
/// stateful implementation falls back to the stateless one and
/// leaves `state` untouched — fine for tokenizers (Markdown,
/// JSON) whose grammars have no multi-line carry. Tokenizers
/// that DO need carry (Swift, C-family languages with `/* */`
/// or triple-quoted strings) override `tokenize(line:state:)`
/// directly.
public protocol SyntaxHighlighter: Sendable {
    /// Classifies one source line with no cross-line context. Uncovered
    /// stretches of the line render as ``SyntaxToken/plain``; returning
    /// `[]` leaves the whole line plain.
    func tokenize(line: String) -> [SyntaxSpan]
    /// Classifies one source line, reading and updating cross-line carry
    /// (open block comment, open multiline string). The default
    /// implementation forwards to `tokenize(line:)` and leaves `state`
    /// untouched.
    func tokenize(line: String, state: inout TokenizerState) -> [SyntaxSpan]
}

extension SyntaxHighlighter {
    /// Default implementation forwards to the stateless overload
    /// and leaves `state` untouched. Tokenizers without multi-line
    /// constructs inherit this for free; tokenizers with carry
    /// (e.g. `SwiftSyntaxHighlighter`) override.
    public func tokenize(line: String, state: inout TokenizerState) -> [SyntaxSpan] {
        return tokenize(line: line)
    }
}

/// Maps each `SyntaxToken` to a foreground `Color`.
///
/// An app's code colours are part of its ``Theme``: state ``Theme/syntax`` and
/// every view that highlights code — ``CodeView``, ``MarkdownView``'s fenced
/// blocks, a highlighting ``TextArea`` — follows it. A view that takes a
/// `SyntaxTheme` argument directly overrides the theme for that view alone.
public struct SyntaxTheme: Sendable, Equatable {
    /// Foreground for ``SyntaxToken/keyword`` spans.
    public let keyword: Color
    /// Foreground for ``SyntaxToken/string`` spans (delimiters included).
    public let string: Color
    /// Foreground for ``SyntaxToken/comment`` spans.
    public let comment: Color
    /// Foreground for ``SyntaxToken/number`` spans.
    public let number: Color
    /// Foreground for ``SyntaxToken/type`` spans.
    public let type: Color
    /// Foreground for ``SyntaxToken/function`` spans.
    public let function: Color
    /// Foreground for ``SyntaxToken/operatorToken`` spans. Named
    /// `operatorColor` because `operator` is reserved in Swift.
    public let operatorColor: Color
    /// Foreground for unclassified text; `.default` keeps the terminal's
    /// own foreground.
    public let plain: Color

    /// Creates a theme from one explicit color per token kind.
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

    /// The theme's foreground for a token kind — total over
    /// ``SyntaxToken``, never falls back.
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

// MARK: - Highlighting

extension SyntaxHighlighter {
    /// Colours `lines` as one document, one run of spans per line.
    ///
    /// Tokenizer state carries from each line to the next, so a block comment
    /// opened on one line colours the lines after it. Stretches no span covers
    /// are drawn as ``SyntaxTheme/plain`` — the protocol's promise — so no text
    /// is ever dropped, whatever the tokenizer chose to classify. Spans carry a
    /// foreground only; background and weight belong to the view placing them.
    ///
    /// An empty line yields an empty run. A view that draws one row per line
    /// must still give that row its height.
    public func highlight(lines: [String], theme: SyntaxTheme) -> [[TextSpan]] {
        var state = TokenizerState()
        return lines.map { line in
            var runs: [TextSpan] = []
            var covered = line.startIndex
            let spans = tokenize(line: line, state: &state)
                .sorted { $0.range.lowerBound < $1.range.lowerBound }
            for span in spans where span.range.lowerBound >= covered {
                if covered < span.range.lowerBound {
                    runs.append(TextSpan(String(line[covered..<span.range.lowerBound]),
                                         foreground: theme.plain))
                }
                runs.append(TextSpan(String(line[span.range]), foreground: theme.color(for: span.token)))
                covered = span.range.upperBound
            }
            if covered < line.endIndex {
                runs.append(TextSpan(String(line[covered...]), foreground: theme.plain))
            }
            return runs
        }
    }
}

// MARK: - Language registry

/// The lexers a subtree can highlight with, looked up by language name.
///
/// Every view that is handed a language — a markdown fence's info string,
/// ``CodeView``'s `language:` — resolves it here, so a lexer an app registers
/// once reaches all of them. Names match case-insensitively; Swift is
/// registered as standard.
///
/// ```swift
/// MyApp()
///     .syntaxHighlighter(JSONHighlighter(), for: "json")
///     .syntaxHighlighter(ShellHighlighter(), for: "sh", "bash", "zsh")
/// ```
public struct SyntaxHighlighters: Sendable {
    private var byLanguage: [String: any SyntaxHighlighter] = [:]

    /// An empty registry — nothing highlights.
    public init() {}

    /// What every app starts with: Swift.
    public static let standard: SyntaxHighlighters = {
        var registry = SyntaxHighlighters()
        registry.register(SwiftSyntaxHighlighter(), for: "swift")
        return registry
    }()

    /// The lexer for `language`, or `nil` when none is registered — and for
    /// a `nil` language, which is what an unlabelled fence carries.
    public subscript(language: String?) -> (any SyntaxHighlighter)? {
        guard let language else { return nil }
        return byLanguage[language.lowercased()]
    }

    /// Register `highlighter` under each of `languages`, replacing whatever
    /// those names resolved to before.
    public mutating func register(_ highlighter: any SyntaxHighlighter, for languages: String...) {
        register(highlighter, for: languages)
    }

    mutating func register(_ highlighter: any SyntaxHighlighter, for languages: [String]) {
        for language in languages {
            byLanguage[language.lowercased()] = highlighter
        }
    }
}

extension TerminalView {
    /// Highlight `languages` with `highlighter` everywhere in this subtree,
    /// adding to the lexers inherited from above rather than replacing them.
    public func syntaxHighlighter(_ highlighter: any SyntaxHighlighter, for languages: String...)
        -> ModifiedView<Self, TransformEnvironmentModifier<SyntaxHighlighters>> {
        transformEnvironment(\.syntaxHighlighters) { $0.register(highlighter, for: languages) }
    }
}

// MARK: - SwiftSyntaxHighlighter

/// Naive Swift tokenizer — keyword recognition + string/comment/
/// number/type categorisation. Block comments (`/* … */`) and
/// multi-line string literals (`"""…"""`) carry across lines through
/// `tokenize(line:state:)`. Apps that need full Swift syntax can plug in a
/// heavier `SyntaxHighlighter` (e.g. one driven by SwiftSyntax) without
/// changing the protocol.
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

    /// Creates the tokenizer. Stateless and trivially cheap — safe to
    /// construct per body evaluation.
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
            // same line, else extend to end of line. This overload is
            // per-line; `tokenize(line:state:)` carries it across lines.
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

    /// Stateful overload — handles `/* … */` block comments and
    /// `"""…"""` multiline string literals across line boundaries.
    /// The state struct is mutated in place to reflect what the
    /// caller should pass to the next line.
    ///
    /// Algorithm:
    ///
    /// 1. If `state.isInBlockComment`, scan forward for the closing
    ///    `*/`. Everything up to (and including) `*/` is `.comment`;
    ///    if no close is found, the whole line is `.comment` and the
    ///    flag stays set.
    /// 2. Else if `state.isInMultilineString`, scan forward for the
    ///    closing `"""`. Same treatment with `.string`.
    /// 3. Otherwise tokenise normally via the stateless overload —
    ///    BUT post-scan the line to detect an UNCLOSED `/*` or `"""`
    ///    that opens past this line's end, and set the corresponding
    ///    flag for the next call.
    public func tokenize(line: String, state: inout TokenizerState) -> [SyntaxSpan] {
        // 1) inside an open block comment from a previous line.
        if state.isInBlockComment {
            return continueBlockComment(line: line, state: &state)
        }
        // 2) inside an open multiline string literal from a previous
        //    line.
        if state.isInMultilineString {
            return continueMultilineString(line: line, state: &state)
        }
        // 3) clean state — tokenise normally, then look for an
        //    OPEN-but-unclosed `/*` or `"""` so the next line knows
        //    to continue in carry-mode.
        let spans = tokenize(line: line)
        updateStateForOpensInLine(line: line, state: &state)
        return spans
    }

    /// Line that begins inside an open block comment. Scan to `*/`
    /// or end-of-line. Everything is `.comment`; tokens after the
    /// close marker (if found) tokenise normally and are appended.
    private func continueBlockComment(
        line: String,
        state: inout TokenizerState
    ) -> [SyntaxSpan] {
        let chars = Array(line)
        let n = chars.count
        var spans: [SyntaxSpan] = []
        var j = 0
        while j + 1 < n && !(chars[j] == "*" && chars[j + 1] == "/") {
            j += 1
        }
        if j + 1 < n {
            // Found `*/` at index j..j+1. Comment span covers 0..<j+2.
            let close = j + 2
            let endIdx = line.index(line.startIndex, offsetBy: close)
            spans.append(SyntaxSpan(range: line.startIndex..<endIdx, token: .comment))
            state.isInBlockComment = false
            // Tokenise the remainder of the line normally.
            let rest = String(chars[close..<n])
            if !rest.isEmpty {
                let restSpans = tokenize(line: rest)
                // Shift the rest's String.Index ranges so they refer
                // to the ORIGINAL line, not the substring.
                for span in restSpans {
                    let lo = rest.distance(from: rest.startIndex, to: span.range.lowerBound) + close
                    let hi = rest.distance(from: rest.startIndex, to: span.range.upperBound) + close
                    let loIdx = line.index(line.startIndex, offsetBy: lo)
                    let hiIdx = line.index(line.startIndex, offsetBy: hi)
                    spans.append(SyntaxSpan(range: loIdx..<hiIdx, token: span.token))
                }
                // After consuming the rest, RE-CHECK for a NEW open
                // `/*` or `"""` so a comment-then-open pattern on
                // the same line carries to the next.
                updateStateForOpensInLine(line: rest, state: &state)
            }
        } else {
            // Whole line is still inside the comment.
            if n > 0 {
                spans.append(SyntaxSpan(range: line.startIndex..<line.endIndex, token: .comment))
            }
            state.isInBlockComment = true
        }
        return spans
    }

    /// Line that begins inside an open multiline string literal.
    /// Scan to `"""` or end-of-line. Same shape as block-comment
    /// continuation, but with `.string` and a 3-char close marker.
    private func continueMultilineString(
        line: String,
        state: inout TokenizerState
    ) -> [SyntaxSpan] {
        let chars = Array(line)
        let n = chars.count
        var spans: [SyntaxSpan] = []
        var j = 0
        // Bounds check: `j + 3 <= n` means three chars are available
        // starting at index j (j, j+1, j+2 all in-range).
        while j + 3 <= n && !(chars[j] == "\"" && chars[j + 1] == "\"" && chars[j + 2] == "\"") {
            j += 1
        }
        let closeFound = j + 3 <= n
            && chars[j] == "\"" && chars[j + 1] == "\"" && chars[j + 2] == "\""
        if closeFound {
            let close = j + 3
            let endIdx = line.index(line.startIndex, offsetBy: close)
            spans.append(SyntaxSpan(range: line.startIndex..<endIdx, token: .string))
            state.isInMultilineString = false
            let rest = String(chars[close..<n])
            if !rest.isEmpty {
                let restSpans = tokenize(line: rest)
                for span in restSpans {
                    let lo = rest.distance(from: rest.startIndex, to: span.range.lowerBound) + close
                    let hi = rest.distance(from: rest.startIndex, to: span.range.upperBound) + close
                    let loIdx = line.index(line.startIndex, offsetBy: lo)
                    let hiIdx = line.index(line.startIndex, offsetBy: hi)
                    spans.append(SyntaxSpan(range: loIdx..<hiIdx, token: span.token))
                }
                updateStateForOpensInLine(line: rest, state: &state)
            }
        } else {
            if n > 0 {
                spans.append(SyntaxSpan(range: line.startIndex..<line.endIndex, token: .string))
            }
            state.isInMultilineString = true
        }
        return spans
    }

    /// Walk `line` once and set `state.isInBlockComment` / `state
    /// .isInMultilineString` if the line opens one of those
    /// constructs without closing it. Mirrors the stateless
    /// scanner's lexer state machine but only tracks the carry
    /// markers; doesn't emit spans.
    private func updateStateForOpensInLine(
        line: String,
        state: inout TokenizerState
    ) {
        let chars = Array(line)
        let n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]
            // `//` line comments swallow the rest of the line — no
            // open carry possible after this point.
            if c == "/" && i + 1 < n && chars[i + 1] == "/" {
                return
            }
            // `/* …` — does it close on this line?
            if c == "/" && i + 1 < n && chars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < n && !(chars[j] == "*" && chars[j + 1] == "/") {
                    j += 1
                }
                if j + 1 < n {
                    i = j + 2  // closed — keep scanning.
                    continue
                } else {
                    state.isInBlockComment = true
                    return
                }
            }
            // `"""` opens (or closes inline). MUST be checked before
            // the single-quote string skip below — otherwise the
            // `"…"` branch consumes the first two quotes of a
            // triple-quote and we miss the open.
            if c == "\"" && i + 3 <= n && chars[i + 1] == "\"" && chars[i + 2] == "\"" {
                var j = i + 3
                while j + 3 <= n && !(chars[j] == "\"" && chars[j + 1] == "\"" && chars[j + 2] == "\"") {
                    j += 1
                }
                if j + 3 <= n && chars[j] == "\"" && chars[j + 1] == "\"" && chars[j + 2] == "\"" {
                    i = j + 3  // closed — keep scanning.
                    continue
                } else {
                    state.isInMultilineString = true
                    return
                }
            }
            // `"…"` single-line string — skip past the closer so a
            // `"` inside a `// comment marker"` isn't mistaken for
            // the start of a multiline.
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
                i = j
                continue
            }
            i += 1
        }
    }
}
