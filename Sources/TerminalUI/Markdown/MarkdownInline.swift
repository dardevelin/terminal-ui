// Inline parsing: emphasis, code spans, links.
//
// CommonMark's emphasis rules are the hardest part of the spec — left- and
// right-flanking delimiter runs, the rule of three, intraword underscores.
// Implementing them in full would be most of this file's weight for cases a
// chat transcript never produces.
//
// What is implemented instead: a delimiter opens a run when the character
// after it is not a space, and closes when the character before it is not a
// space. That handles `**bold**`, `*italic*`, and `snake_case_name` (whose
// underscores are intraword and therefore never open), and it declines to
// pair across whitespace, which is the failure people actually notice. An
// unmatched delimiter stays as literal text rather than consuming the rest of
// the line — the property that keeps a half-typed message readable while an
// agent is still streaming it.

/// An inline element.
public indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    /// Content of a backtick span, verbatim — no nested parsing, per spec.
    case code(String)
    case link(content: [MarkdownInline], destination: String)
}

extension MarkdownInline {

    /// Parse one line's worth of inline markup.
    public static func parse(_ source: String) -> [MarkdownInline] {
        var characters = Array(source)
        return parse(&characters, from: 0, to: characters.count)
    }

    private static func parse(_ chars: inout [Character], from start: Int, to end: Int) -> [MarkdownInline] {
        var nodes: [MarkdownInline] = []
        var literal = ""
        var index = start

        func flush() {
            if !literal.isEmpty {
                nodes.append(.text(literal))
                literal = ""
            }
        }

        while index < end {
            let character = chars[index]

            // A backslash escapes the punctuation that would otherwise open a
            // run, so `\*` is an asterisk rather than a dangling delimiter.
            if character == "\\", index + 1 < end, chars[index + 1].isMarkdownPunctuation {
                literal.append(chars[index + 1])
                index += 2
                continue
            }

            if character == "`" {
                let fence = runLength(chars, at: index, of: "`", limit: end)
                if let close = findRun(chars, of: "`", length: fence, from: index + fence, to: end) {
                    flush()
                    // Per spec one leading and trailing space is stripped, so
                    // `` ` `` can hold a literal backtick.
                    var body = String(chars[(index + fence)..<close])
                    if body.hasPrefix(" ") && body.hasSuffix(" ") && body.trimmed.count < body.count {
                        body = String(body.dropFirst().dropLast())
                    }
                    nodes.append(.code(body))
                    index = close + fence
                    continue
                }
                literal.append(character)
                index += 1
                continue
            }

            if character == "[", let link = parseLink(&chars, from: index, to: end) {
                flush()
                nodes.append(link.node)
                index = link.next
                continue
            }

            if character == "*" || character == "_" {
                let run = runLength(chars, at: index, of: character, limit: end)
                let width = min(run, 2)
                // An underscore inside a word never opens (CommonMark §6.2),
                // which is the rule that keeps `snake_case_name` intact.
                // Asterisks have no such restriction: `a*b*c` is emphasis.
                let insideWord = index > start && chars[index - 1].isWordCharacter
                let mayOpen = canOpen(chars, at: index + run, to: end)
                    && !(character == "_" && insideWord)
                if mayOpen,
                   let close = findClosingDelimiter(chars, character, width: width,
                                                    from: index + width, to: end) {
                    flush()
                    let inner = parse(&chars, from: index + width, to: close)
                    nodes.append(width == 2 ? .strong(inner) : .emphasis(inner))
                    index = close + width
                    continue
                }
                literal.append(character)
                index += 1
                continue
            }

            literal.append(character)
            index += 1
        }

        flush()
        return nodes
    }

    // MARK: - Delimiters

    private static func runLength(_ chars: [Character], at index: Int,
                                  of character: Character, limit: Int) -> Int {
        var length = 0
        var cursor = index
        while cursor < limit, chars[cursor] == character {
            length += 1
            cursor += 1
        }
        return length
    }

    private static func findRun(_ chars: [Character], of character: Character,
                                length: Int, from start: Int, to end: Int) -> Int? {
        var index = start
        while index < end {
            if chars[index] == character, runLength(chars, at: index, of: character, limit: end) == length {
                return index
            }
            index += 1
        }
        return nil
    }

    /// A run opens only when something other than whitespace follows it, which
    /// is what stops `a * b * c` from becoming emphasis.
    private static func canOpen(_ chars: [Character], at index: Int, to end: Int) -> Bool {
        index < end && !chars[index].isWhitespace
    }

    /// Find the delimiter that closes this run: the same character, the same
    /// width, and preceded by something other than whitespace.
    private static func findClosingDelimiter(_ chars: [Character], _ character: Character,
                                             width: Int, from start: Int, to end: Int) -> Int? {
        var index = start
        while index < end {
            if chars[index] == "\\" { index += 2; continue }
            guard chars[index] == character else {
                index += 1
                continue
            }
            let run = runLength(chars, at: index, of: character, limit: end)
            let precededByText = index > start && !chars[index - 1].isWhitespace
            if run >= width && precededByText { return index }
            index += run
        }
        return nil
    }

    // MARK: - Links

    private static func parseLink(_ chars: inout [Character], from start: Int,
                                  to end: Int) -> (node: MarkdownInline, next: Int)? {
        // Balance brackets so `[a [b] c](url)` finds the right closer.
        var depth = 0
        var labelEnd: Int?
        var index = start
        while index < end {
            if chars[index] == "\\" { index += 2; continue }
            if chars[index] == "[" { depth += 1 }
            if chars[index] == "]" {
                depth -= 1
                if depth == 0 { labelEnd = index; break }
            }
            index += 1
        }
        guard let closeBracket = labelEnd,
              closeBracket + 1 < end,
              chars[closeBracket + 1] == "(" else { return nil }

        var parenDepth = 0
        var destinationEnd: Int?
        index = closeBracket + 1
        while index < end {
            if chars[index] == "(" { parenDepth += 1 }
            if chars[index] == ")" {
                parenDepth -= 1
                if parenDepth == 0 { destinationEnd = index; break }
            }
            index += 1
        }
        guard let closeParen = destinationEnd else { return nil }

        let content = parse(&chars, from: start + 1, to: closeBracket)
        let destination = String(chars[(closeBracket + 2)..<closeParen]).trimmed
        return (.link(content: content, destination: destination), closeParen + 1)
    }
}

extension Character {
    /// Letters, digits and the marks that bind into a word — what an
    /// underscore must not be sitting inside if it is to open emphasis.
    var isWordCharacter: Bool {
        isLetter || isNumber || self == "_"
    }

    /// The punctuation a backslash may escape (CommonMark §2.4).
    var isMarkdownPunctuation: Bool {
        "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".contains(self)
    }
}
