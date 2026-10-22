/// The text an input edits, as the shared commands see it: its characters
/// and a cursor offset into them. TextInput holds exactly this; TextArea and
/// PromptInput convert their rows and columns to it and back.
struct TextEditingBuffer: Equatable {
    var text: [Character]
    var cursor: Int
    /// Ranges an edit takes whole or leaves alone, and the cursor never
    /// stops inside: PromptInput's collapsed paste markers, which stand for
    /// text the user never sees. Edits keep them in step with the text.
    var atomicRanges: [Range<Int>] = []
}

/// What a command did to a ``TextEditingBuffer``.
enum TextEditResult: Equatable {
    /// A movement command ran; the text did not change.
    case moved
    /// `replaced`, in the text as it was, now holds `insertedCount`
    /// characters, and the cursor moved with the edit.
    case edited(replaced: Range<Int>, insertedCount: Int)
    /// The cursor stood at an end and was asked past it.
    case hitWall(BoundaryHitReason)
    /// An edit with nothing to do — a delete past either end, a yank with
    /// nothing killed — so the key can mean something else to the app, as
    /// Ctrl+D on an empty line means end of input to readline.
    case unchanged
    /// Not a command the buffer performs: rows, pages, history, submit,
    /// undo and redo belong to the input, and a name no input declares to
    /// the app.
    case unsupported
}

extension TextEditingBuffer {
    private static let lineBreak: Character = "\n"

    mutating func perform(_ command: TextEditCommand, killBuffer: KillBuffer) -> TextEditResult {
        switch command {
        case .moveBackward:
            return cursor > 0 ? move(to: cursor - 1, forward: false) : .hitWall(.leftEdge)
        case .moveForward:
            return cursor < text.count ? move(to: cursor + 1, forward: true) : .hitWall(.rightEdge)
        case .moveWordBackward:
            return move(to: wordStart(before: cursor), forward: false)
        case .moveWordForward:
            return move(to: wordEnd(after: cursor), forward: true)
        case .moveToLineStart:
            return move(to: lineStart(of: cursor), forward: false)
        case .moveToLineEnd:
            return move(to: lineEnd(of: cursor), forward: true)
        case .moveToDocumentStart:
            return move(to: 0, forward: false)
        case .moveToDocumentEnd:
            return move(to: text.count, forward: true)
        case .deleteBackward:
            return delete(max(0, cursor - 1)..<cursor, killBuffer: nil)
        case .deleteForward:
            return delete(cursor..<min(text.count, cursor + 1), killBuffer: nil)
        case .deleteWordBackward:
            return delete(wordStart(before: cursor)..<cursor, killBuffer: killBuffer)
        case .deleteWordForward:
            return delete(cursor..<wordEnd(after: cursor), killBuffer: killBuffer)
        case .deleteToWhitespaceBackward:
            return delete(whitespaceStart(before: cursor)..<cursor, killBuffer: killBuffer)
        case .deleteToLineStart:
            let start = lineStart(of: cursor)
            return delete((start == cursor ? max(0, cursor - 1) : start)..<cursor, killBuffer: killBuffer)
        case .deleteToLineEnd:
            let end = lineEnd(of: cursor)
            return delete(cursor..<(end == cursor ? min(text.count, cursor + 1) : end), killBuffer: killBuffer)
        case .yank:
            return insert(killBuffer.lastKill)
        case .insertNewline:
            return insert([Self.lineBreak])
        default:
            return .unsupported
        }
    }

    /// Inserts `characters` at the cursor and moves the cursor past them —
    /// typing, a yank, a line break: one path, so whatever an input keeps
    /// over its text moves with it.
    mutating func insert(_ characters: [Character]) -> TextEditResult {
        guard !characters.isEmpty else { return .unchanged }
        let replaced = cursor..<cursor
        text.insert(contentsOf: characters, at: cursor)
        cursor += characters.count
        keepAtomicRanges(after: replaced, insertedCount: characters.count)
        return .edited(replaced: replaced, insertedCount: characters.count)
    }

    /// Where `range` lies after `replaced` came to hold `insertedCount`
    /// characters, or nil when the edit took it: one rule for every range an
    /// input keeps over its text.
    static func range(_ range: Range<Int>, after replaced: Range<Int>, insertedCount: Int) -> Range<Int>? {
        if range.upperBound <= replaced.lowerBound && !(range.isEmpty && replaced.isEmpty) {
            return range
        }
        if range.lowerBound >= replaced.upperBound {
            let shift = insertedCount - replaced.count
            return (range.lowerBound + shift)..<(range.upperBound + shift)
        }
        return nil
    }

    /// Moves the cursor to `offset`, past the far side of any atomic range
    /// it would land inside.
    private mutating func move(to offset: Int, forward: Bool) -> TextEditResult {
        cursor = atomicRanges.first { $0.lowerBound < offset && offset < $0.upperBound }
            .map { forward ? $0.upperBound : $0.lowerBound } ?? offset
        return .moved
    }

    /// Removes `range`, widened to take whole any atomic range it touches,
    /// and leaves the cursor where it began. A kill keeps what it took.
    private mutating func delete(_ range: Range<Int>, killBuffer: KillBuffer?) -> TextEditResult {
        let widened = atomicRanges.reduce(range) { range, atomic in
            atomic.overlaps(range)
                ? min(range.lowerBound, atomic.lowerBound)..<max(range.upperBound, atomic.upperBound)
                : range
        }
        guard !widened.isEmpty else { return .unchanged }
        killBuffer?.kill(text[widened])
        text.removeSubrange(widened)
        cursor = widened.lowerBound
        keepAtomicRanges(after: widened, insertedCount: 0)
        return .edited(replaced: widened, insertedCount: 0)
    }

    private mutating func keepAtomicRanges(after replaced: Range<Int>, insertedCount: Int) {
        atomicRanges = atomicRanges.compactMap {
            Self.range($0, after: replaced, insertedCount: insertedCount)
        }
    }

    private func lineStart(of offset: Int) -> Int {
        text[..<offset].lastIndex(of: Self.lineBreak).map { $0 + 1 } ?? 0
    }

    private func lineEnd(of offset: Int) -> Int {
        text[offset...].firstIndex(of: Self.lineBreak) ?? text.count
    }

    /// Emacs's `forward-word`: past anything that is not a word character,
    /// then past the word.
    private func wordEnd(after offset: Int) -> Int {
        var end = offset
        while end < text.count && !Self.isWordCharacter(text[end]) { end += 1 }
        while end < text.count && Self.isWordCharacter(text[end]) { end += 1 }
        return end
    }

    /// Emacs's `backward-word`.
    private func wordStart(before offset: Int) -> Int {
        var start = offset
        while start > 0 && !Self.isWordCharacter(text[start - 1]) { start -= 1 }
        while start > 0 && Self.isWordCharacter(text[start - 1]) { start -= 1 }
        return start
    }

    /// readline's `unix-word-rubout`: back over whitespace, then over
    /// everything that is not whitespace.
    private func whitespaceStart(before offset: Int) -> Int {
        var start = offset
        while start > 0 && text[start - 1].isWhitespace { start -= 1 }
        while start > 0 && !text[start - 1].isWhitespace { start -= 1 }
        return start
    }

    /// Emacs's word syntax: letters and digits.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

/// Text held as lines, as TextArea and PromptInput keep it, against the one
/// string the editing commands see: a line break is one character between
/// two lines.
enum TextLines {
    static func split(_ text: String) -> [String] {
        text.isEmpty ? [""] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func join(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    /// The offset of `row`, `col` into the joined text.
    static func offset(row: Int, col: Int, in lines: [String]) -> Int {
        lines.prefix(row).reduce(0) { $0 + $1.count + 1 } + col
    }

    /// The row and column of `offset` into the joined text; past its end,
    /// the end.
    static func position(of offset: Int, in lines: [String]) -> (row: Int, col: Int) {
        var remaining = offset
        for (row, line) in lines.enumerated() {
            if remaining <= line.count { return (row, remaining) }
            remaining -= line.count + 1
        }
        let last = max(0, lines.count - 1)
        return (last, lines.isEmpty ? 0 : lines[last].count)
    }
}
